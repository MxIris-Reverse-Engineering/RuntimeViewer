import Foundation
import FoundationToolbox
import RuntimeViewerArchitectures

/// A JSON-file-backed property wrapper that reports what it loses.
///
/// Written rather than reused because the alternative — `RxDefaultsPlus`'s
/// `@FileStorage` — swallows every read error, so a single malformed entry
/// silently empties the whole file and nothing anywhere says so. That is
/// tolerable for a cached window position; it is not tolerable for the only
/// copy of a user's bookmarks. Three behaviours are the point:
///
/// - **Entry-level tolerance.** A malformed entry costs that entry, logged.
/// - **Quarantine, not deletion.** A file that cannot be parsed at all is
///   *renamed* aside before anything starts writing over it, so the data is
///   still on disk and still recoverable by hand.
/// - **Diagnostics on every degraded path**, because the failure this replaces
///   was invisible.
///
/// The path layout matches `@FileStorage` exactly —
/// `<directory>/AppStorage/<key>.json` — so a file written by the old wrapper
/// is read by this one without moving anything.
@propertyWrapper
public final class ResilientFileStorage<Value: LenientlyDecodable & Encodable & Sendable>: @unchecked Sendable {
    private let key: String

    /// Resolved lazily rather than at init: the wrapper is a stored property of
    /// a singleton, so its initializer runs before anything has a chance to
    /// point it somewhere else, and a test needs to.
    private let directoryURLProvider: @Sendable () throws -> URL

    private let defaultValue: Value
    private let fileManager = FileManager.default

    private var cachedValue: Value?

    /// Concurrent reads, barriered writes — the same discipline `@FileStorage`
    /// uses, and the reason `AppDefaults` can call this from the background
    /// schedulers its Rx pipelines run on.
    private let queue = DispatchQueue(label: "com.JH.RuntimeViewer.ResilientFileStorage", attributes: .concurrent)

    private let relay = PublishRelay<Value>()

    public init(wrappedValue: Value, _ key: String, directory: FileManager.SearchPathDirectory = .documentDirectory) {
        self.defaultValue = wrappedValue
        self.key = key
        self.directoryURLProvider = {
            guard let baseURL = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            return baseURL.appendingPathComponent("AppStorage", isDirectory: true)
        }
    }

    /// Points the wrapper at an explicit directory.
    ///
    /// For tests only, and load-bearing: the real wrappers write into
    /// `Application Support/AppStorage`, which the running app also uses, so a
    /// test that took the default path would overwrite the user's bookmarks.
    init(wrappedValue: Value, _ key: String, directoryURL: URL) {
        self.defaultValue = wrappedValue
        self.key = key
        self.directoryURLProvider = { directoryURL }
    }

    public var wrappedValue: Value {
        get {
            var cached: Value?
            queue.sync { cached = cachedValue }
            if let cached { return cached }

            return queue.sync(flags: .barrier) {
                if let cached = cachedValue { return cached }
                let loaded = loadFromDisk()
                cachedValue = loaded
                return loaded
            }
        }
        set {
            queue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                cachedValue = newValue
                relay.accept(newValue)
                saveToDisk(newValue)
            }
        }
    }

    public var projectedValue: Observable<Value> {
        Observable.deferred { [weak self] in
            guard let self else { return .empty() }
            return relay.asObservable().startWith(wrappedValue)
        }
    }

    /// Replaces the stored value without going through the barrier queue.
    ///
    /// Exists for one caller: a migration running inside `AppDefaults.init`,
    /// which has to see its own write immediately afterwards. The asynchronous
    /// setter cannot promise that, and the previous migration worked around it
    /// by deferring its completion flag to the next main-queue turn — a
    /// workaround that is only correct as long as nothing reads in between.
    func setSynchronously(_ newValue: Value) {
        queue.sync(flags: .barrier) {
            cachedValue = newValue
            saveToDisk(newValue)
        }
        relay.accept(newValue)
    }

    private func fileURL() throws -> URL {
        let folderURL = try directoryURLProvider()
        if !fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        return folderURL.appendingPathComponent("\(key).json")
    }

    private func loadFromDisk() -> Value {
        let url: URL
        do {
            url = try fileURL()
        } catch {
            ResilientFileStorageDiagnostics.reportUnreachableDirectory(key: key, error: error)
            return defaultValue
        }

        guard fileManager.fileExists(atPath: url.path) else { return defaultValue }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            ResilientFileStorageDiagnostics.reportUnreadableFile(key: key, error: error)
            return defaultValue
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Unparseable as JSON at all. Move it aside *before* the first
            // write lands on top of it — this is the only moment the bytes can
            // still be saved.
            ResilientFileStorageDiagnostics.reportQuarantine(key: key, error: error, quarantinedTo: quarantineFile(at: url))
            return defaultValue
        }

        var diagnostics: [String] = []
        guard let value = Value.decodedLeniently(from: jsonObject, diagnostics: &diagnostics) else {
            // Valid JSON, wrong shape — an array where an object belongs, say.
            // Nothing can be salvaged entry by entry, so quarantine as above.
            ResilientFileStorageDiagnostics.reportShapeMismatch(key: key, quarantinedTo: quarantineFile(at: url))
            return defaultValue
        }

        if !diagnostics.isEmpty {
            ResilientFileStorageDiagnostics.reportSkippedEntries(key: key, diagnostics: diagnostics)
        }
        return value
    }

    /// Renames the unreadable file aside and answers where it went.
    ///
    /// Never deletes, and never overwrites an existing quarantine file: a
    /// second corruption must not destroy the evidence of the first.
    private func quarantineFile(at url: URL) -> URL? {
        let timestamp = QuarantineFileName.timestamp(for: Date())
        var destination = url.deletingPathExtension()
            .appendingPathExtension("corrupted-\(timestamp)")
            .appendingPathExtension("json")
        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = url.deletingPathExtension()
                .appendingPathExtension("corrupted-\(timestamp)-\(attempt)")
                .appendingPathExtension("json")
            attempt += 1
        }
        do {
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            ResilientFileStorageDiagnostics.reportFailedQuarantine(key: key, error: error)
            return nil
        }
    }

    private func saveToDisk(_ value: Value) {
        do {
            let url = try fileURL()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            ResilientFileStorageDiagnostics.reportFailedWrite(key: key, error: error)
        }
    }
}

/// Split out of ``ResilientFileStorage`` because a generic type cannot hold a
/// static stored property, and one shared formatter beats building a new one
/// per quarantine.
enum QuarantineFileName {
    static func timestamp(for date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Colons would be legal in a file name and illegal in half the places
        // this path gets pasted into, so the time uses hyphens.
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

/// The logging half of ``ResilientFileStorage``, split out because `@Loggable`
/// generates a `static let` and Swift does not allow stored type properties on
/// a generic type.
@Loggable(.private)
enum ResilientFileStorageDiagnostics {
    static func reportUnreachableDirectory(key: String, error: any Error) {
        #log(.error, "\(key, privacy: .public): storage directory is unreachable, using defaults: \(error, privacy: .public)")
    }

    static func reportUnreadableFile(key: String, error: any Error) {
        #log(.error, "\(key, privacy: .public): file exists but could not be read, using defaults: \(error, privacy: .public)")
    }

    static func reportQuarantine(key: String, error: any Error, quarantinedTo destination: URL?) {
        #log(.error, "\(key, privacy: .public): file is not valid JSON (\(error, privacy: .public)); quarantined to \(destination?.lastPathComponent ?? "<quarantine failed>", privacy: .public)")
    }

    static func reportShapeMismatch(key: String, quarantinedTo destination: URL?) {
        #log(.error, "\(key, privacy: .public): file parses as JSON but has the wrong top-level shape; quarantined to \(destination?.lastPathComponent ?? "<quarantine failed>", privacy: .public)")
    }

    static func reportFailedQuarantine(key: String, error: any Error) {
        #log(.error, "\(key, privacy: .public): could not quarantine the unreadable file, leaving it in place: \(error, privacy: .public)")
    }

    static func reportSkippedEntries(key: String, diagnostics: [String]) {
        #log(.error, "\(key, privacy: .public): skipped \(diagnostics.count, privacy: .public) unreadable entr\(diagnostics.count == 1 ? "y" : "ies", privacy: .public); the rest were loaded")
        for diagnostic in diagnostics {
            #log(.error, "\(key, privacy: .public): \(diagnostic, privacy: .public)")
        }
    }

    static func reportFailedWrite(key: String, error: any Error) {
        #log(.error, "\(key, privacy: .public): write failed: \(error, privacy: .public)")
    }
}

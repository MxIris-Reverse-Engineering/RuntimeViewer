public import Foundation
import FoundationToolbox

/// What keeps a derived data location from growing without end, and what
/// the app shows and deletes of it. Plain file system work, the same in the
/// serving processes and in the app.
///
/// The cleanup is the serving process's, at the first use of its store
/// (`RuntimeDerivedDataStore`): only it knows which system and producer it is,
/// and it refreshes its own `LastUsed` before it looks at anyone else's. Its
/// rules look only at names and dates, and it never deletes its own
/// directory, so processes cleaning up at once do not get in each other's
/// way:
///
/// 1. A system directory of another build goes whole. One of this build
///    with another shared cache — another architecture's — stays.
/// 2. Within this build, a producer directory whose `LastUsed` is older than
///    `producerRetention` goes; the directory's own date stands in for a
///    missing `LastUsed`. Builds of one configuration — several worktrees —
///    keep each other's data, and a running instance refreshes its own.
/// 3. Leftovers go: a root a deletion renamed aside, a temporary file older
///    than `leftoverRetention`, and a reading marker of the same age whose
///    process is gone, together with its container.
///
/// The app only measures and deletes. A deletion renames the root aside and
/// deletes it in the background; a process that quits halfway leaves the
/// renamed root to the next cleanup.
@Loggable(.private)
public enum RuntimeDerivedDataMaintenance {
    /// How long a producer directory nobody used is kept: 14 days.
    public static let producerRetention: TimeInterval = 14 * 24 * 60 * 60

    /// How long a temporary file, or a marker of a process that is gone, is
    /// left in place: a day.
    public static let leftoverRetention: TimeInterval = 24 * 60 * 60

    /// How often a running process refreshes its `LastUsed`: a day.
    public static let usageRefreshInterval: TimeInterval = 24 * 60 * 60

    /// What the name of a temporary file holds, after the name of the
    /// container it is about to become.
    static let temporaryFileMarker = "tmp-"

    // MARK: - App

    /// Bytes the derived data at `location` takes on disk.
    public static func allocatedByteCount(at location: RuntimeDerivedDataLocation) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: location.rootURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var byteCount: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            byteCount += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return byteCount
    }

    /// Deletes the derived data at `location`: renames the root aside, which
    /// makes it gone for every reader at once, then deletes it in the
    /// background. A serving process that writes later makes the root again.
    /// What is in memory in a running process is not affected.
    public static func deleteAll(at location: RuntimeDerivedDataLocation) throws {
        let fileManager = FileManager.default
        let parentURL = location.rootURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: location.rootURL.path) {
            let deletingURL = parentURL.appendingPathComponent(RuntimeDerivedDataLocation.deletingRootDirectoryNamePrefix + UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: location.rootURL, to: deletingURL)
            #log(.info, "Deleting the derived data at \(location.rootURL.path, privacy: .public)")
        }
        Task.detached(priority: .utility) {
            RuntimeDerivedDataMaintenance.removeRenamedRoots(in: parentURL)
        }
    }

    // MARK: - Serving process

    /// The cleanup; see the type's notes for the rules.
    static func cleanUp(
        rootURL: URL,
        currentSystemDirectoryName: String,
        currentOperatingSystemBuild: String,
        currentProducerDirectoryName: String,
        now: Date,
        isProcessRunning: (RuntimeDerivedDataReadingMarker) -> Bool
    ) {
        let fileManager = FileManager()
        removeRenamedRoots(in: rootURL.deletingLastPathComponent())
        for systemDirectoryURL in subdirectories(of: rootURL, fileManager: fileManager) {
            let systemDirectoryName = systemDirectoryURL.lastPathComponent
            if systemDirectoryName != currentSystemDirectoryName {
                guard RuntimeDerivedDataSystemIdentity.operatingSystemBuild(ofDirectoryNamed: systemDirectoryName) == currentOperatingSystemBuild else {
                    remove(systemDirectoryURL, reason: "another system", fileManager: fileManager)
                    continue
                }
            }
            for producerDirectoryURL in subdirectories(of: systemDirectoryURL, fileManager: fileManager) {
                if producerDirectoryURL.lastPathComponent != currentProducerDirectoryName || systemDirectoryName != currentSystemDirectoryName {
                    let lastUsedURL = producerDirectoryURL.appendingPathComponent(RuntimeDerivedDataStore.lastUsedFileName, isDirectory: false)
                    let lastUseDate = modificationDate(of: lastUsedURL, fileManager: fileManager) ?? modificationDate(of: producerDirectoryURL, fileManager: fileManager) ?? .distantPast
                    if now.timeIntervalSince(lastUseDate) > producerRetention {
                        remove(producerDirectoryURL, reason: "unused since \(lastUseDate)", fileManager: fileManager)
                        continue
                    }
                }
                removeLeftovers(in: producerDirectoryURL, now: now, isProcessRunning: isProcessRunning, fileManager: fileManager)
            }
        }
    }

    /// Temporary files and the markers of reads that died, in every image
    /// directory of a producer.
    private static func removeLeftovers(in producerDirectoryURL: URL, now: Date, isProcessRunning: (RuntimeDerivedDataReadingMarker) -> Bool, fileManager: FileManager) {
        let imagesDirectoryURL = producerDirectoryURL.appendingPathComponent(RuntimeDerivedDataStore.imagesDirectoryName, isDirectory: true)
        for imageDirectoryURL in subdirectories(of: imagesDirectoryURL, fileManager: fileManager) {
            guard let fileNames = try? fileManager.contentsOfDirectory(atPath: imageDirectoryURL.path) else { continue }
            for fileName in fileNames {
                let fileURL = imageDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
                guard let date = modificationDate(of: fileURL, fileManager: fileManager), now.timeIntervalSince(date) > leftoverRetention else { continue }
                if fileName.hasPrefix("."), fileName.contains("." + temporaryFileMarker) {
                    remove(fileURL, reason: "a temporary file left behind", fileManager: fileManager)
                } else if fileURL.pathExtension == RuntimeDerivedDataReadingMarker.fileExtension {
                    // A marker goes only with its container.
                    if let marker = RuntimeDerivedDataReadingMarker(contentsOf: fileURL), isProcessRunning(marker) { continue }
                    remove(fileURL.deletingPathExtension(), reason: "a read of it never finished", fileManager: fileManager)
                    remove(fileURL, reason: "its read never finished", fileManager: fileManager)
                }
            }
        }
    }

    private static func removeRenamedRoots(in parentURL: URL) {
        let fileManager = FileManager()
        guard let names = try? fileManager.contentsOfDirectory(atPath: parentURL.path) else { return }
        for name in names where name.hasPrefix(RuntimeDerivedDataLocation.deletingRootDirectoryNamePrefix) {
            remove(parentURL.appendingPathComponent(name, isDirectory: true), reason: "a deletion left it", fileManager: fileManager)
        }
    }

    private static func subdirectories(of directoryURL: URL, fileManager: FileManager) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func remove(_ url: URL, reason: String, fileManager: FileManager) {
        do {
            try fileManager.removeItem(at: url)
            #log(.info, "Removed \(url.path, privacy: .public): \(reason, privacy: .public)")
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            #log(.error, "Could not remove \(url.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}

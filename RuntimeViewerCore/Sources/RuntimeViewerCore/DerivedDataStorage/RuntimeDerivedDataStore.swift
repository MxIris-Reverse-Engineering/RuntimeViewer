public import Foundation
import FoundationToolbox
import Semaphore

/// Reads and writes the derived data of one system and one producer, under
/// one location:
///
/// ```
/// <root>/
///   <system directory name>/              RuntimeDerivedDataSystemIdentity
///     Info.plist                          for people
///     <producer directory name>/          RuntimeDerivedDataProducerIdentity
///       Info.plist                        for people
///       LastUsed                          its modification date is the last use
///       Images/
///         <file name>-<path digest>/      one image
///           <kind>-<variant>.rvdd         RuntimeDerivedDataContainer
/// ```
///
/// Only images of the dyld shared cache are kept: their contents are what
/// the system identity names. A read or write for any other image does
/// nothing.
///
/// The first read or write of a store refreshes `LastUsed` and then cleans
/// up, in the background, what is out of date (`RuntimeDerivedDataMaintenance`);
/// `LastUsed` is refreshed again at every write and once a day while the
/// process runs, so a running instance is never taken for one nobody uses.
///
/// Decoding — checksums, decompression, the caller's own `decode` — runs off
/// this actor, at most `maximumConcurrentReadCount` at a time, and reads of
/// one file at the same time are one read.
@Loggable(.private)
public actor RuntimeDerivedDataStore {
    public nonisolated let location: RuntimeDerivedDataLocation

    public nonisolated let system: RuntimeDerivedDataSystemIdentity

    public nonisolated let producer: RuntimeDerivedDataProducerIdentity

    static let containerFileExtension = "rvdd"

    static let maximumConcurrentReadCount = 4

    private nonisolated let isSharedCacheImage: @Sendable (String) -> Bool

    private nonisolated let isProcessRunning: @Sendable (RuntimeDerivedDataReadingMarker) -> Bool

    private nonisolated let currentReadingMarker: RuntimeDerivedDataReadingMarker

    private nonisolated let readSemaphore = AsyncSemaphore(value: RuntimeDerivedDataStore.maximumConcurrentReadCount)

    private nonisolated let cleansUpOnFirstUse: Bool

    /// Whether the first use — refresh, cleanup — happened.
    private var isPrepared = false

    private var lastUsageRefreshDate: Date?

    private var cleanupTask: Task<Void, Never>?

    private var usageRefreshTask: Task<Void, Never>?

    private var readsInFlight: [URL: Task<(any Sendable)?, Never>] = [:]

    private let fileManager = FileManager()

    public init(location: RuntimeDerivedDataLocation, system: RuntimeDerivedDataSystemIdentity, producer: RuntimeDerivedDataProducerIdentity) {
        self.init(location: location, system: system, producer: producer, isSharedCacheImage: { DyldUtilities.isInDyldSharedCache($0) })
    }

    /// - Parameters:
    ///   - isSharedCacheImage: Which images are kept.
    ///   - isProcessRunning: Whether the reader a marker names still runs.
    ///   - readingMarker: What this process's reads mark their files with.
    ///   - cleansUpOnFirstUse: Whether the first use cleans up the location;
    ///     a test of something else turns it off.
    init(
        location: RuntimeDerivedDataLocation,
        system: RuntimeDerivedDataSystemIdentity,
        producer: RuntimeDerivedDataProducerIdentity,
        isSharedCacheImage: @escaping @Sendable (String) -> Bool,
        isProcessRunning: @escaping @Sendable (RuntimeDerivedDataReadingMarker) -> Bool = { RuntimeDerivedDataReadingMarker.isProcessRunning($0) },
        readingMarker: RuntimeDerivedDataReadingMarker = .currentProcess(),
        cleansUpOnFirstUse: Bool = true
    ) {
        self.location = location
        self.system = system
        self.producer = producer
        self.isSharedCacheImage = isSharedCacheImage
        self.isProcessRunning = isProcessRunning
        currentReadingMarker = readingMarker
        self.cleansUpOnFirstUse = cleansUpOnFirstUse
    }

    deinit {
        cleanupTask?.cancel()
        usageRefreshTask?.cancel()
    }

    // MARK: - Places

    nonisolated var systemDirectoryURL: URL {
        location.rootURL.appendingPathComponent(system.directoryName, isDirectory: true)
    }

    nonisolated var producerDirectoryURL: URL {
        systemDirectoryURL.appendingPathComponent(producer.directoryName, isDirectory: true)
    }

    static let lastUsedFileName = "LastUsed"

    static let informationFileName = "Info.plist"

    static let imagesDirectoryName = "Images"

    /// The directory of the image at `imagePath` — the seam for caches of
    /// other libraries; `nil` for an image outside the shared cache.
    public nonisolated func imageDirectory(forImageAt imagePath: String) -> URL? {
        guard isSharedCacheImage(imagePath) else { return nil }
        // The digest of the whole path keeps apart images of one file name:
        // the shared cache carries Mac Catalyst variants of frameworks under
        // `/System/iOSSupport`.
        let pathDigest = RuntimeDerivedDataDigest.hexadecimalDigest(of: Data(imagePath.utf8)).prefix(12)
        let fileName = URL(fileURLWithPath: imagePath).lastPathComponent
        return producerDirectoryURL
            .appendingPathComponent(Self.imagesDirectoryName, isDirectory: true)
            .appendingPathComponent("\(fileName)-\(pathDigest)", isDirectory: true)
    }

    nonisolated func containerURL(_ kind: RuntimeDerivedDataKind, variant: String, forImageAt imagePath: String) -> URL? {
        imageDirectory(forImageAt: imagePath)?.appendingPathComponent("\(kind.rawValue)-\(variant).\(Self.containerFileExtension)", isDirectory: false)
    }

    private nonisolated func header(_ kind: RuntimeDerivedDataKind, variant: String, imagePath: String) -> RuntimeDerivedDataContainer.Header {
        RuntimeDerivedDataContainer.Header(
            kind: kind.rawValue,
            variant: variant,
            imagePath: imagePath,
            systemDirectoryName: system.directoryName,
            producerDigest: producer.digest
        )
    }

    // MARK: - Reading

    /// Reads, checks and decodes the container stored for `kind` and
    /// `variant` of the image at `imagePath`, off this actor; `nil` when it
    /// is not stored, not for an image of the shared cache, being read by
    /// another process that still runs, failing a check, or left behind by a
    /// read that never finished. A file that fails is deleted, and so is one
    /// a read never finished — its marker is still beside it.
    ///
    /// `decode` gets the checked sections and builds the value; whatever it
    /// does — checks of its own, a walk through what it built — happens
    /// while the reading marker is in place, so a trap in there leaves the
    /// file to be deleted unread next time. Throwing from it deletes the
    /// file now.
    public func read<Value: Sendable>(
        _ kind: RuntimeDerivedDataKind,
        variant: String,
        forImageAt imagePath: String,
        decode: @escaping @Sendable (RuntimeDerivedDataContainer) throws -> Value
    ) async -> Value? {
        guard let containerURL = containerURL(kind, variant: variant, forImageAt: imagePath) else { return nil }
        prepareIfNeeded()
        if let readInFlight = readsInFlight[containerURL] {
            return await readInFlight.value.flatMap { $0 as? Value }
        }
        let expectedHeader = header(kind, variant: variant, imagePath: imagePath)
        let read = Task<(any Sendable)?, Never> {
            guard let value = await self.performRead(containerURL: containerURL, expectedHeader: expectedHeader, decode: decode) else { return nil }
            return value
        }
        readsInFlight[containerURL] = read
        let value = await read.value
        readsInFlight[containerURL] = nil
        return value.flatMap { $0 as? Value }
    }

    private func performRead<Value: Sendable>(
        containerURL: URL,
        expectedHeader: RuntimeDerivedDataContainer.Header,
        decode: @escaping @Sendable (RuntimeDerivedDataContainer) throws -> Value
    ) async -> Value? {
        let markerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: containerURL)
        if let marker = RuntimeDerivedDataReadingMarker(contentsOf: markerURL) {
            if marker == currentReadingMarker {
                // Left by a read of this process whose marker could not be
                // removed; no read of this file is under way here.
                try? fileManager.removeItem(at: markerURL)
            } else if isProcessRunning(marker) {
                #log(.info, "Not reading \(containerURL.lastPathComponent, privacy: .public): process \(marker.processIdentifier, privacy: .public) is reading it")
                return nil
            } else {
                #log(.error, "A read of \(containerURL.path, privacy: .public) by process \(marker.processIdentifier, privacy: .public) never finished; deleting the file unread")
                removeContainer(at: containerURL)
                return nil
            }
        }
        guard fileManager.fileExists(atPath: containerURL.path) else { return nil }
        do {
            try currentReadingMarker.write(to: markerURL)
        } catch {
            #log(.error, "Not reading \(containerURL.lastPathComponent, privacy: .public): its reading marker could not be written: \(error, privacy: .public)")
            return nil
        }
        refreshUsageIfDue()
        let outcome = await Self.readContainer(at: containerURL, expectedHeader: expectedHeader, semaphore: readSemaphore, decode: decode)
        switch outcome {
        case .success(let value):
            try? fileManager.removeItem(at: markerURL)
            return value
        case .failure(let error):
            #log(.error, "Discarding \(containerURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            removeContainer(at: containerURL)
            return nil
        }
    }

    /// The file read and checked, then `decode`d, off the store's actor.
    @concurrent
    private static func readContainer<Value: Sendable>(
        at containerURL: URL,
        expectedHeader: RuntimeDerivedDataContainer.Header,
        semaphore: AsyncSemaphore,
        decode: @Sendable (RuntimeDerivedDataContainer) throws -> Value
    ) async -> Result<Value, any Swift.Error> {
        await semaphore.wait()
        defer { semaphore.signal() }
        do {
            // Read whole rather than mapped: a mapped file that another
            // process truncated would raise SIGBUS on the next page touched.
            let data = try Data(contentsOf: containerURL)
            let container = try RuntimeDerivedDataContainer(decoding: data, expecting: expectedHeader)
            return .success(try decode(container))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Writing

    /// Writes `builder` as the container of `kind` and `variant` for the
    /// image at `imagePath`: to a temporary file beside the place, renamed
    /// into it, after which the image's other variants of `kind` are
    /// deleted. Does nothing for an image outside the shared cache. Failures
    /// are logged and dropped — derived data is only ever an optimization.
    public func store(_ builder: RuntimeDerivedDataContainer.Builder, as kind: RuntimeDerivedDataKind, variant: String, forImageAt imagePath: String) async {
        guard let imageDirectoryURL = imageDirectory(forImageAt: imagePath),
              let containerURL = containerURL(kind, variant: variant, forImageAt: imagePath)
        else { return }
        prepareIfNeeded()
        let data = await Self.encodedContainer(builder, header: header(kind, variant: variant, imagePath: imagePath))
        let temporaryURL = imageDirectoryURL.appendingPathComponent(".\(containerURL.lastPathComponent).\(RuntimeDerivedDataMaintenance.temporaryFileMarker)\(UUID().uuidString)", isDirectory: false)
        do {
            try writeDirectoryInformationIfMissing()
            try fileManager.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: temporaryURL)
            if rename(temporaryURL.path, containerURL.path) != 0 {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: containerURL.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            #log(.error, "Could not write \(containerURL.path, privacy: .public): \(error, privacy: .public)")
            return
        }
        // A marker a dead read left beside the old file would make the next
        // read delete this one.
        let markerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: containerURL)
        if let marker = RuntimeDerivedDataReadingMarker(contentsOf: markerURL), marker != currentReadingMarker, !isProcessRunning(marker) {
            try? fileManager.removeItem(at: markerURL)
        }
        removeOtherVariants(of: kind, keeping: containerURL, in: imageDirectoryURL)
        refreshUsage()
        #log(.info, "Stored \(kind.rawValue, privacy: .public) of \(imagePath, privacy: .public): \(data.count, privacy: .public) bytes, \(builder.decodedByteCount, privacy: .public) decoded")
    }

    @concurrent
    private static func encodedContainer(_ builder: RuntimeDerivedDataContainer.Builder, header: RuntimeDerivedDataContainer.Header) async -> Data {
        RuntimeDerivedDataContainer.encoded(builder, header: header)
    }

    private func removeOtherVariants(of kind: RuntimeDerivedDataKind, keeping containerURL: URL, in imageDirectoryURL: URL) {
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: imageDirectoryURL.path) else { return }
        let prefix = "\(kind.rawValue)-"
        let suffix = ".\(Self.containerFileExtension)"
        for fileName in fileNames where fileName.hasPrefix(prefix) && fileName.hasSuffix(suffix) && fileName != containerURL.lastPathComponent {
            removeContainer(at: imageDirectoryURL.appendingPathComponent(fileName, isDirectory: false))
        }
    }

    /// A container and its marker, which never go one without the other.
    private func removeContainer(at containerURL: URL) {
        try? fileManager.removeItem(at: containerURL)
        try? fileManager.removeItem(at: RuntimeDerivedDataReadingMarker.url(forContainerAt: containerURL))
    }

    /// The two `Info.plist` files and `LastUsed`, for whichever is missing.
    private func writeDirectoryInformationIfMissing() throws {
        try fileManager.createDirectory(at: producerDirectoryURL, withIntermediateDirectories: true)
        let systemInformationURL = systemDirectoryURL.appendingPathComponent(Self.informationFileName, isDirectory: false)
        if !fileManager.fileExists(atPath: systemInformationURL.path) {
            let information: [String: String] = [
                "Platform": system.platform.rawValue,
                "OperatingSystemVersion": system.operatingSystemVersion,
                "OperatingSystemBuild": system.operatingSystemBuild,
                "SharedCacheUUID": system.sharedCacheUUID.uuidString,
            ]
            try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0).write(to: systemInformationURL, options: .atomic)
        }
        let producerInformationURL = producerDirectoryURL.appendingPathComponent(Self.informationFileName, isDirectory: false)
        if !fileManager.fileExists(atPath: producerInformationURL.path) {
            let information: [String: String] = [
                "ProducerDigest": producer.digest,
                "Application": location.applicationURL.path,
            ]
            try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0).write(to: producerInformationURL, options: .atomic)
        }
        let lastUsedURL = producerDirectoryURL.appendingPathComponent(Self.lastUsedFileName, isDirectory: false)
        if !fileManager.fileExists(atPath: lastUsedURL.path) {
            fileManager.createFile(atPath: lastUsedURL.path, contents: nil)
        }
    }

    // MARK: - Use and cleanup

    /// On the first read or write: `LastUsed` refreshed, the cleanup begun,
    /// and the daily refresh scheduled.
    private func prepareIfNeeded() {
        guard !isPrepared else { return }
        isPrepared = true
        refreshUsage()
        if cleansUpOnFirstUse {
            let rootURL = location.rootURL
            let systemDirectoryName = system.directoryName
            let operatingSystemBuild = system.operatingSystemBuild
            let producerDirectoryName = producer.directoryName
            let isProcessRunning = isProcessRunning
            cleanupTask = Task.detached(priority: .utility) {
                RuntimeDerivedDataMaintenance.cleanUp(
                    rootURL: rootURL,
                    currentSystemDirectoryName: systemDirectoryName,
                    currentOperatingSystemBuild: operatingSystemBuild,
                    currentProducerDirectoryName: producerDirectoryName,
                    now: Date(),
                    isProcessRunning: isProcessRunning
                )
            }
        }
        usageRefreshTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(RuntimeDerivedDataMaintenance.usageRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.refreshUsage()
            }
        }
    }

    /// The cleanup the first use began — what a test waits for.
    func waitForCleanup() async {
        await cleanupTask?.value
    }

    private func refreshUsageIfDue() {
        guard let lastUsageRefreshDate, Date().timeIntervalSince(lastUsageRefreshDate) < RuntimeDerivedDataMaintenance.usageRefreshInterval else {
            refreshUsage()
            return
        }
    }

    /// Sets `LastUsed`'s modification date to now, making the file — and the
    /// producer directory — when it is missing.
    private func refreshUsage() {
        let lastUsedURL = producerDirectoryURL.appendingPathComponent(Self.lastUsedFileName, isDirectory: false)
        do {
            if !fileManager.fileExists(atPath: lastUsedURL.path) {
                try fileManager.createDirectory(at: producerDirectoryURL, withIntermediateDirectories: true)
                fileManager.createFile(atPath: lastUsedURL.path, contents: nil)
            }
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: lastUsedURL.path)
            lastUsageRefreshDate = Date()
        } catch {
            #log(.error, "Could not refresh \(lastUsedURL.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}

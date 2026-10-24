import Foundation
@testable import RuntimeViewerCore

/// A directory of its own for one test, removed when the test lets go of
/// it. Every derived data test works in one of these: none may touch the
/// real `~/Library/Caches/<bundle identifier>/DerivedData`.
final class DerivedDataTestDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewerCoreTests-DerivedData-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A location rooted here, as `RuntimeDerivedDataLocation` would make
    /// for an application with this bundle identifier.
    func location(bundleIdentifier: String = "dev.RuntimeViewer.Tests") -> RuntimeDerivedDataLocation {
        RuntimeDerivedDataLocation(
            applicationURL: url.appendingPathComponent("RuntimeViewer.app", isDirectory: true),
            rootURL: url
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent(RuntimeDerivedDataLocation.rootDirectoryName, isDirectory: true)
        )
    }
}

enum DerivedDataTestIdentities {
    static let sharedCacheUUID = UUID(uuidString: "6C1A8B6E-3D3F-4C47-9A1F-6E2B7B0D9C11")!

    static let system = RuntimeDerivedDataSystemIdentity(
        platform: .macOS,
        operatingSystemVersion: "27.2",
        operatingSystemBuild: "26B5112a",
        sharedCacheUUID: sharedCacheUUID
    )

    static let producer = RuntimeDerivedDataProducerIdentity(
        digest: RuntimeDerivedDataProducerIdentity.digest(of: [(name: "RuntimeViewerLocalRuntimeService", uuid: UUID(uuidString: "0B7E3E2A-5C1D-4E8F-8A21-3F0C5D9E7B44")!)])
    )

    static let otherProducer = RuntimeDerivedDataProducerIdentity(
        digest: RuntimeDerivedDataProducerIdentity.digest(of: [(name: "RuntimeViewerLocalRuntimeService", uuid: UUID(uuidString: "9F1D2C3B-4A5E-4F60-8172-93A4B5C6D7E8")!)])
    )

    /// A store over `directory` that keeps every image, so a test can use
    /// paths that are not in the shared cache, and leaves cleaning up to the
    /// tests of the cleanup.
    static func store(
        in directory: DerivedDataTestDirectory,
        system: RuntimeDerivedDataSystemIdentity = system,
        producer: RuntimeDerivedDataProducerIdentity = producer,
        isSharedCacheImage: @escaping @Sendable (String) -> Bool = { _ in true },
        isProcessRunning: @escaping @Sendable (RuntimeDerivedDataReadingMarker) -> Bool = { RuntimeDerivedDataReadingMarker.isProcessRunning($0) },
        readingMarker: RuntimeDerivedDataReadingMarker = .currentProcess(),
        cleansUpOnFirstUse: Bool = false
    ) -> RuntimeDerivedDataStore {
        RuntimeDerivedDataStore(
            location: directory.location(),
            system: system,
            producer: producer,
            isSharedCacheImage: isSharedCacheImage,
            isProcessRunning: isProcessRunning,
            readingMarker: readingMarker,
            cleansUpOnFirstUse: cleansUpOnFirstUse
        )
    }
}

extension FileManager {
    func setModificationDate(_ date: Date, of url: URL) throws {
        try setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// A count several tasks add to.
final class DerivedDataCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

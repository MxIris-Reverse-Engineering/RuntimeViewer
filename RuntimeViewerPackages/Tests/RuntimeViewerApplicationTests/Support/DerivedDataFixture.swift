import Foundation
@testable import RuntimeViewerCore

/// Derived data in a directory of the test's own, removed when the test lets
/// go of it — never the real `~/Library/Caches/<bundle identifier>/DerivedData`.
/// Engines get it through `RuntimeEngine.useDerivedDataStore(_:)`, the seam the
/// app's services take `RuntimeDerivedData.enableInThisProcess()` for.
final class DerivedDataFixture: @unchecked Sendable {
    let directoryURL: URL

    let store: RuntimeDerivedDataStore

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewerApplicationTests-DerivedData-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        store = RuntimeDerivedDataStore(
            location: RuntimeDerivedDataLocation(
                applicationURL: directoryURL.appendingPathComponent("RuntimeViewer.app", isDirectory: true),
                rootURL: directoryURL.appendingPathComponent("DerivedData", isDirectory: true)
            ),
            system: RuntimeDerivedDataSystemIdentity(platform: .macOS, operatingSystemVersion: "27.2", operatingSystemBuild: "Tests", sharedCacheUUID: UUID()),
            producer: RuntimeDerivedDataProducerIdentity(digest: String(repeating: "0", count: 64)),
            isSharedCacheImage: { _ in true },
            cleansUpOnFirstUse: false
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// Prints the corpus of `imagePath` under `transformer` on an engine of
    /// its own, which writes it here — what an earlier launch left.
    func storeCorpus(of imagePath: String, transformer: Transformer.Configuration) async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataFixture.writer.\(UUID().uuidString)", loading: [imagePath])
        await engine.useDerivedDataStore(store)
        _ = try await engine.buildInterfaceCorpus(for: imagePath, transformer: transformer)
        await engine.stop()
    }

    /// A connected engine that reads and writes here and has indexed nothing:
    /// a launch on the same system with the same code.
    func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataFixture.\(label)")
        await engine.useDerivedDataStore(store)
        return engine
    }
}

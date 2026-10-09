import Combine
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What a batch's end costs the documents sharing its engine: one reload of the engine's data,
/// however many documents listen. Every document hears every batch event, and each one's indexing
/// coordinator used to ask the engine to reload when a batch ended; every reload broadcasts a
/// `.fullReload` to all of them — sidebar reload, interface cache flush — so N windows on one
/// engine paid N² of each per batch (PR121.58).
@Suite("RuntimeBackgroundIndexingReload", .serialized)
@MainActor
struct RuntimeBackgroundIndexingReloadTests {
    @Test("a batch's end reloads the engine once with two documents on it")
    func batchEndReloadsOnceForTwoDocuments() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeBackgroundIndexingReloadTests.twoDocuments")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Off, so neither coordinator starts batches of its own on opening.
        firstEnvironment.settings.indexing.isEnabled = false
        secondEnvironment.settings.indexing.isEnabled = false
        let firstCoordinator = firstEnvironment.make { firstEnvironment.documentState.backgroundIndexingCoordinator }
        let secondCoordinator = secondEnvironment.make { secondEnvironment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((firstCoordinator, secondCoordinator)) {} }
        let reloadCounter = ReloadCounter()
        let subscription = engine.reloadDataPublisher.sink { _ in reloadCounter.increment() }
        defer { subscription.cancel() }

        let batchIdentifier = await engine.backgroundIndexingManager.startBatch(rootImagePath: TestImages.libobjc, depth: 0, maxConcurrency: 1, reason: .manual)
        _ = try await nextValue(from: firstCoordinator.historyObservable, timeout: 60) { $0.contains { $0.id == batchIdentifier } }
        _ = try await nextValue(from: secondCoordinator.historyObservable, timeout: 60) { $0.contains { $0.id == batchIdentifier } }
        // Room for a second reload to arrive.
        try await Task.sleep(for: .milliseconds(500))

        #expect(reloadCounter.count == 1, "one batch's end reloaded the engine \(reloadCounter.count) times")
        await engine.stop()
    }
}

private final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reloadCount = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return reloadCount
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        reloadCount += 1
    }
}

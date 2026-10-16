#if canImport(Network)

import Combine
import Foundation
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerCore
@testable import RuntimeViewerSettings

/// The documents on one engine share its background indexing: one coordinator per engine, held by
/// every document on it (`RuntimeEngineBackgroundWork`). Each document used to have a coordinator
/// of its own and acted on the engine's batches as if they were its own: a second window turned
/// every row already indexed into a batch of 0 images in every window's Report, each one reloading
/// the engine, and closing it, or moving it to another engine, cancelled the batches the first
/// window was running.
/// `Documentations/ResolvedIssues/2026-10-16-second-document-disturbs-shared-indexing.md`. What
/// the windows show of it, one Report per engine, is `ReportSharedByEngineTests`.
@Suite("Background indexing shared by the documents on an engine", .serialized)
@MainActor
struct RuntimeBackgroundIndexingSharedEngineTests {
    private static let libobjc = "libobjc.A.dylib"

    /// Images only the scripted engines list; nothing loads them in this process.
    private static let sharedImagePath = "/Scripted/libShared.dylib"
    private static let firstQueriedImagePath = "/Scripted/libFirst.dylib"
    private static let secondQueriedImagePath = "/Scripted/libSecond.dylib"

    // MARK: - Opening a second document

    @Test("a second document on an engine dispatches nothing, adds nothing to the Report and does not reload the engine")
    func secondDocumentDispatchesNothing() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeBackgroundIndexingSharedEngineTests.secondDocument")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableAlwaysIndex(in: firstEnvironment, rows: [Self.libobjc])
        Self.enableAlwaysIndex(in: secondEnvironment, rows: [Self.libobjc])
        // Background indexing reloads the engine without its image nodes; the reload of the
        // engine's first connection, which may land late, reloads them too.
        let reloadCounter = SharedEngineReloadCounter()
        let reloadSubscription = engine.dataChangePublisher.sink { change in
            if change == .fullReload(isReloadImageNodes: false) { reloadCounter.increment() }
        }
        defer { reloadSubscription.cancel() }
        let firstCoordinator = firstEnvironment.make { firstEnvironment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((firstEnvironment, firstCoordinator)) {} }
        firstEnvironment.make { firstCoordinator.documentDidOpen() }
        let indexedBatch = try await Self.endedBatch(of: Self.libobjc, in: firstCoordinator)
        // A batch's end reaches the history before the reload that follows it.
        try await waitUntil { reloadCounter.count >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        let reloadCountBeforeSecondDocument = reloadCounter.count

        // Opened as `Document.makeWindowControllers` opens it.
        let secondCoordinator = secondEnvironment.make { secondEnvironment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((secondEnvironment, secondCoordinator)) {} }
        secondEnvironment.make { secondCoordinator.documentDidOpen() }
        // Time for whatever the second document would set off: a pass over its rows, the reload
        // after a batch's end.
        try await Task.sleep(for: .seconds(1))

        #expect(secondCoordinator === firstCoordinator, "the second document has a coordinator of its own")
        let history = try await nextValue(from: firstCoordinator.historyObservable)
        let batches = try await nextValue(from: firstCoordinator.batchesObservable)
        #expect(history.map(\.id) == [indexedBatch.id], "the second document put more in the Report: \(Self.describe(history))")
        #expect(batches.isEmpty, "the second document started \(Self.describe(batches))")
        #expect(reloadCounter.count == reloadCountBeforeSecondDocument, "the engine reloaded \(reloadCounter.count - reloadCountBeforeSecondDocument) times after the second document opened")
        await engine.stop()
    }

    // MARK: - A document leaving

    enum DocumentLeaving: String, CaseIterable, Sendable {
        /// `Document.close()`.
        case closes
        /// The toolbar's engine menu, to another engine.
        case switchesToAnotherEngine
    }

    @Test("a document leaving an engine other documents stay on cancels none of the engine's batches", arguments: DocumentLeaving.allCases)
    func documentLeavingCancelsNothingWhileOthersStay(leaving: DocumentLeaving) async throws {
        let label = "RuntimeBackgroundIndexingSharedEngineTests.leaving.\(leaving.rawValue)"
        let (peer, heldLoads) = try await Self.makePeerHoldingLoads(label: label, imagePaths: [Self.sharedImagePath])
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "\(label).other")
        let row = Self.imageName(of: Self.sharedImagePath)
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        Self.enableAlwaysIndex(in: firstEnvironment, rows: [row])
        Self.enableAlwaysIndex(in: secondEnvironment, rows: [row])
        let firstCoordinator = firstEnvironment.make { firstEnvironment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((firstEnvironment, firstCoordinator)) {} }
        firstEnvironment.make { firstCoordinator.documentDidOpen() }
        let batch = try await Self.runningBatch(of: row, in: firstCoordinator)
        let secondCoordinator = secondEnvironment.make { secondEnvironment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((secondEnvironment, secondCoordinator)) {} }
        secondEnvironment.make { secondCoordinator.documentDidOpen() }

        switch leaving {
        case .closes:
            secondEnvironment.make { secondEnvironment.documentState.documentWillClose() }
        case .switchesToAnotherEngine:
            secondEnvironment.make { secondEnvironment.documentState.selectionRouter.trigger(.switchEngine(otherEngine)) }
        }

        // A cancellation reaches the manager in a task of its own; give one the time to land.
        try await Task.sleep(for: .milliseconds(300))
        let isCancelled = await peer.client.backgroundIndexingManager.currentBatches().contains { $0.id == batch.id && $0.isCancelled }
        #expect(!isCancelled, "the second document \(leaving.rawValue) and cancelled the batch the first one shows")
        await heldLoads.release()

        let batchEnd = try await Self.endedBatch(batch.id, in: firstCoordinator)
        #expect(!batchEnd.isCancelled)
        #expect(batchEnd.items.allSatisfy { $0.state == .completed }, "\(batchEnd.items.map(\.state))")
        await peer.stop()
        await otherEngine.stop()
    }

    /// A batch the last document leaving cancelled can still be ending — a load on its way cannot
    /// be called back — when a document comes back onto the engine, and the engine replays it as
    /// under way to the new coordinator. The document used to keep one coordinator across the move
    /// and archive the batch as cancelled as it left; the replay then listed the batch as running
    /// and as ended at once, and its real end listed it a second time (PR121.57).
    @Test("a document moving to another engine and back lists each of the engine's batches once")
    func documentMovingAwayAndBackListsEachBatchOnce() async throws {
        let label = "RuntimeBackgroundIndexingSharedEngineTests.awayAndBack"
        let (peer, heldLoads) = try await Self.makePeerHoldingLoads(label: label, imagePaths: [Self.sharedImagePath])
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "\(label).other")
        let row = Self.imageName(of: Self.sharedImagePath)
        let environment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        Self.enableAlwaysIndex(in: environment, rows: [row])
        let firstCoordinator = environment.make { environment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((environment, firstCoordinator)) {} }
        environment.make { firstCoordinator.documentDidOpen() }
        let cancelledBatch = try await Self.runningBatch(of: row, in: firstCoordinator)

        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine)) }
        try await Self.poll {
            await peer.client.backgroundIndexingManager.currentBatches().contains { $0.id == cancelledBatch.id && $0.isCancelled }
        }
        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(peer.client)) }
        let returnedCoordinator = environment.make { environment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime(returnedCoordinator) {} }
        // Coming back dispatches the row again, a batch of its own beside the one ending.
        try await Self.poll {
            await peer.client.backgroundIndexingManager.currentBatches().contains { $0.reason == .alwaysIndex(identifier: row) && !$0.isCancelled }
        }
        await heldLoads.release()

        _ = try await nextValue(from: returnedCoordinator.historyObservable, timeout: 30) { history in
            history.count >= 2
        }
        try await settleMainQueue()
        let history = try await nextValue(from: returnedCoordinator.historyObservable)
        let batches = try await nextValue(from: returnedCoordinator.batchesObservable)
        #expect(returnedCoordinator !== firstCoordinator, "the engine kept its coordinator with no document on it")
        #expect(Set(history.map(\.id)).count == history.count, "a batch is listed twice: \(Self.describe(history))")
        #expect(history.first { $0.id == cancelledBatch.id }?.isCancelled == true, "\(Self.describe(history))")
        #expect(history.contains { $0.id != cancelledBatch.id && !$0.isCancelled }, "\(Self.describe(history))")
        #expect(batches.isEmpty, "still listed as running after their ends: \(Self.describe(batches))")
        await peer.stop()
        await otherEngine.stop()
    }

    // MARK: - The engine coming back

    /// The local runtime service relaunching, or a peer reconnecting, puts a new process behind the
    /// engine that has indexed none of the rows. The coordinator heard of it only when a document
    /// walked back to the image list through `.switchEngine`, which happens only when the document
    /// had something open; with nothing open the rows were never dispatched again. An in-process
    /// engine goes through the same edge with `stop()` and `connect()`, and stopping it drops what
    /// it indexed.
    @Test("the engine coming back with a new process behind it dispatches the rows again while its document has nothing open")
    func engineComingBackDispatchesTheRowsAgain() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeBackgroundIndexingSharedEngineTests.engineBack")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableAlwaysIndex(in: environment, rows: [Self.libobjc])
        let coordinator = environment.make { environment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((environment, coordinator)) {} }
        environment.make { coordinator.documentDidOpen() }
        let firstBatch = try await Self.endedBatch(of: Self.libobjc, in: coordinator)
        #expect(environment.documentState.currentImageNode == nil)

        await engine.stop()
        // Stopping drops the indexed sections in a task of its own; the new process must not find
        // libobjc indexed.
        try await Self.poll { (try? await engine.isImageIndexed(path: TestImages.libobjc)) == false }
        try await engine.connect()

        let history = try await nextValue(from: coordinator.historyObservable, timeout: 60) { history in
            history.contains { $0.reason == .alwaysIndex(identifier: Self.libobjc) && $0.id != firstBatch.id }
        }
        let secondBatch = try #require(history.first { $0.reason == .alwaysIndex(identifier: Self.libobjc) && $0.id != firstBatch.id })
        #expect(!secondBatch.isCancelled)
        #expect(secondBatch.items.allSatisfy { $0.state == .completed }, "\(secondBatch.items.map(\.state))")
        await engine.stop()
    }

    // MARK: - Reloads during a pass

    @Test("an engine reload while the rows are being dispatched does not dispatch them a second time")
    func reloadDuringPassDoesNotDispatchAgain() async throws {
        let peer = try await ScriptedPeer.make(label: "RuntimeBackgroundIndexingSharedEngineTests.reloadDuringPass")
        // Every row's image is indexed already, so a pass asks about each one and starts nothing.
        // The questions wait for the test, which keeps the pass under way.
        let heldQuestions = HeldRequests()
        peer.serve(.isImageIndexed) { () async -> Bool in
            await heldQuestions.hold()
            return true
        }
        try await Self.publishImageList([Self.firstQueriedImagePath, Self.secondQueriedImagePath], from: peer)
        let environment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        Self.enableAlwaysIndex(in: environment, rows: [Self.imageName(of: Self.firstQueriedImagePath), Self.imageName(of: Self.secondQueriedImagePath)])
        let coordinator = environment.make { environment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((environment, coordinator)) {} }
        environment.make { coordinator.documentDidOpen() }
        try await Self.poll { await heldQuestions.arrivedCount >= 1 }

        // The engine reloads while the pass waits on its first row.
        try await peer.connection.sendMessage(name: .dataDidChange, request: RuntimeDataChange.fullReload(isReloadImageNodes: false))
        try await Task.sleep(for: .milliseconds(500))
        #expect(await heldQuestions.arrivedCount == 1, "the reload started a second pass over rows the first had not finished")

        await heldQuestions.release()
        // The pass asks about its second row, and the retry the reload left behind finds every row
        // dispatched.
        try await Self.poll { await heldQuestions.arrivedCount >= 2 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await heldQuestions.arrivedCount == 2)
        await peer.stop()
    }

    // MARK: - Support

    /// Turns on Always Index alone, with `rows` for every engine.
    private static func enableAlwaysIndex(in environment: ViewModelTestEnvironment, rows: [String]) {
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.maxConcurrency = 10
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = rows.map { Settings.Indexing.AlwaysIndexEntry(identifier: $0) }
    }

    /// A scripted engine listing `imagePaths`, none of them indexed, whose every background load
    /// waits for the test to release it.
    private static func makePeerHoldingLoads(label: String, imagePaths: [String]) async throws -> (ScriptedPeer, HeldRequests) {
        let peer = try await ScriptedPeer.make(label: label)
        let heldLoads = HeldRequests()
        peer.serve(.isImageIndexed) { false }
        peer.serve(.loadImageForBackgroundIndexing) { () async -> RuntimeEngineEmpty in
            await heldLoads.hold()
            return RuntimeEngineEmpty()
        }
        try await publishImageList(imagePaths, from: peer)
        return (peer, heldLoads)
    }

    private static func imageName(of imagePath: String) -> String {
        (imagePath as NSString).lastPathComponent
    }

    /// Puts `imagePaths` in the scripted engine's image list, as a serving engine's push does, and
    /// waits until the engine has it.
    private static func publishImageList(_ imagePaths: [String], from peer: ScriptedPeer) async throws {
        try await peer.connection.sendMessage(name: .imageList, request: imagePaths)
        try await poll { await peer.client.imageList == imagePaths }
    }

    /// Waits until a batch for the row `identifier` has an image being loaded.
    private static func runningBatch(of identifier: String, in coordinator: RuntimeBackgroundIndexingCoordinator) async throws -> RuntimeIndexingBatch {
        let batches = try await nextValue(from: coordinator.batchesObservable, timeout: 30) { batches in
            batches.contains { $0.reason == .alwaysIndex(identifier: identifier) && $0.items.contains { $0.state == .running } }
        }
        return try #require(batches.first { $0.reason == .alwaysIndex(identifier: identifier) })
    }

    /// Waits until a batch for the row `identifier` has ended, and returns it as it ended.
    private static func endedBatch(of identifier: String, in coordinator: RuntimeBackgroundIndexingCoordinator) async throws -> RuntimeIndexingBatch {
        let history = try await nextValue(from: coordinator.historyObservable, timeout: 60) { history in
            history.contains { $0.reason == .alwaysIndex(identifier: identifier) }
        }
        return try #require(history.first { $0.reason == .alwaysIndex(identifier: identifier) })
    }

    /// Waits until the batch `identifier` has ended, and returns it as it ended.
    private static func endedBatch(_ identifier: RuntimeIndexingBatchID, in coordinator: RuntimeBackgroundIndexingCoordinator) async throws -> RuntimeIndexingBatch {
        let history = try await nextValue(from: coordinator.historyObservable, timeout: 30) { history in
            history.contains { $0.id == identifier }
        }
        return try #require(history.first { $0.id == identifier })
    }

    /// Polls `condition` until it holds, for state no observable reports.
    private static func poll(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw AwaitTimeout(seconds: Double(timeout.components.seconds)) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func describe(_ batches: [RuntimeIndexingBatch]) -> String {
        batches.map { batch in
            "\(batch.reason) · \(batch.items.count) images\(batch.isCancelled ? " · cancelled" : "")"
        }
        .joined(separator: ", ")
    }
}

private final class SharedEngineReloadCounter: @unchecked Sendable {
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

#endif

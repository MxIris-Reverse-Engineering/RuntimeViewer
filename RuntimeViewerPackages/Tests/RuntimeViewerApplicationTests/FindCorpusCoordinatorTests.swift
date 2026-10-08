import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The corpus coordinator against a private engine: a requested image gets
/// its corpus built, the switch going off drops every corpus, and a loaded
/// image is picked up from the engine's own notification.
@Suite("FindCorpusCoordinator", .serialized)
@MainActor
struct FindCorpusCoordinatorTests {
    private func waitForCoverage(
        of engine: RuntimeEngine,
        timeout: TimeInterval = 60,
        where predicate: @escaping (RuntimeInterfaceCorpusCoverage) -> Bool
    ) async throws -> RuntimeInterfaceCorpusCoverage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let coverage = try await engine.interfaceCorpusCoverage()
            if predicate(coverage) { return coverage }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await engine.interfaceCorpusCoverage()
    }

    @Test("a requested image gets its corpus built")
    func requestBuildsCorpus() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.request", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestBuild(of: TestImages.libobjc)

        let coverage = try await waitForCoverage(of: engine) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }
        #expect(coverage.statesByImagePath[TestImages.libobjc]?.isBuilt == true)
        #expect(coverage.residentByteCount > 0)
        await engine.stop()
    }

    /// The navigator's symptom as the app lives it: an image the background
    /// indexer finishes becomes searchable while the document's indexing
    /// coordinator listens to the same indexer.
    ///
    /// Both coordinators used to read one shared event stream, which hands
    /// each event to one reader only. The corpus coordinator never heard an
    /// image finish, so every search found nothing and reported every indexed
    /// image as not yet searchable, and the indexing coordinator never heard
    /// the batch finish, so the popover kept it under Active at 100%.
    @Test("an image the background indexer finishes becomes searchable while the indexing coordinator listens too")
    func backgroundIndexedImageBecomesSearchable() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.background")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        // In the order `Document.makeWindowControllers` creates them.
        let indexingCoordinator = environment.make { documentState.backgroundIndexingCoordinator }
        let corpusCoordinator = environment.make { documentState.findCorpusCoordinator }
        defer { withExtendedLifetime((indexingCoordinator, corpusCoordinator)) {} }

        // An "always index" entry that does not follow its dependencies is a
        // batch of one image.
        _ = await engine.backgroundIndexingManager.startBatch(
            rootImagePath: TestImages.libobjc,
            depth: 0,
            maxConcurrency: 1,
            reason: .alwaysIndex(identifier: "libobjc.A.dylib")
        )

        let coverage = try await waitForCoverage(of: engine, timeout: 20) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }
        #expect(coverage.statesByImagePath[TestImages.libobjc]?.isBuilt == true, "the corpus of the image the indexer finished was never built")

        let session = documentState.findSession
        session.run(FindQuery(mode: .text, text: "NSObject"))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 20) { !$0 }
        #expect(!session.results.nodes.isEmpty)
        #expect(session.results.unbuiltImagePaths.isEmpty)

        let history = try await nextValue(from: indexingCoordinator.historyObservable) { history in
            history.contains { $0.rootImagePath == TestImages.libobjc }
        }
        #expect(history.contains { $0.rootImagePath == TestImages.libobjc && $0.isFinished })
        #expect(try await nextValue(from: indexingCoordinator.batchesObservable).isEmpty, "a finished batch is still listed as active")
        await engine.stop()
    }

    @Test("turning the switch off drops every corpus; turning it on rebuilds the indexed images")
    func switchOffDropsCorpora() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.switch", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        // The coordinator queues every indexed image on creation.
        _ = try await waitForCoverage(of: engine) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }

        environment.settings.search.isCorpusEnabled = false
        let dropped = try await waitForCoverage(of: engine) { $0.statesByImagePath.isEmpty }
        #expect(dropped.statesByImagePath.isEmpty)

        environment.settings.search.isCorpusEnabled = true
        let rebuilt = try await waitForCoverage(of: engine) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }
        #expect(rebuilt.statesByImagePath[TestImages.libobjc]?.isBuilt == true)
        await engine.stop()
    }

    private func isBuilding(_ state: RuntimeInterfaceCorpusBuildState?) -> Bool {
        if case .building = state { return true }
        return false
    }

    @Test("a request is followed from queued to built and lands in the history")
    func requestFollowedToBuilt() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.states", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        // The coordinator asks for every indexed image as it starts.
        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }
        #expect(states[TestImages.libobjc]?.isBuilt == true)
        let finishedBuild = try #require(coordinator.finishedBuilds.first)
        #expect(finishedBuild.imagePath == TestImages.libobjc)
        #expect(finishedBuild.finishedAt != nil)
        guard case .built = finishedBuild.outcome else {
            Issue.record("expected a built outcome, got \(finishedBuild.outcome)")
            return
        }
        await engine.stop()
    }

    @Test("cancelling a build withdraws this document's request and records the cancellation")
    func cancelRecordsCancellation() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.cancel", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        // Foundation takes tens of seconds to print, so its progress shows.
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { self.isBuilding($0[TestImages.foundation]) }

        coordinator.cancelBuild(of: TestImages.foundation)

        #expect(coordinator.buildStatesByImagePath[TestImages.foundation] == nil)
        #expect(coordinator.finishedBuilds.first?.imagePath == TestImages.foundation)
        #expect(coordinator.finishedBuilds.first?.outcome == .cancelled)
        // This document was the build's only subscriber, so the engine gives
        // it up as well.
        let coverage = try await waitForCoverage(of: engine, timeout: 30) { $0.statesByImagePath[TestImages.foundation] == nil }
        #expect(coverage.statesByImagePath[TestImages.foundation] == nil)
        await engine.stop()
    }

    @Test("a corpus another document built is listed after this document's own builds, without a time")
    func corpusBuiltElsewhereIsLearned() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.learned", loading: [TestImages.libobjc])
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        firstEnvironment.settings.search.isCorpusEnabled = true
        let firstCoordinator = firstEnvironment.make { FindCorpusCoordinator(documentState: firstEnvironment.documentState) }
        defer { withExtendedLifetime(firstCoordinator) {} }
        _ = try await nextValue(from: firstCoordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }

        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        secondEnvironment.settings.search.isCorpusEnabled = true
        let secondCoordinator = secondEnvironment.make { FindCorpusCoordinator(documentState: secondEnvironment.documentState) }
        defer { withExtendedLifetime(secondCoordinator) {} }

        let history = try await nextValue(from: secondCoordinator.$finishedBuilds.asDriver(), timeout: 20) { !$0.isEmpty }
        #expect(history.map(\.imagePath) == [TestImages.libobjc])
        #expect(history.first?.finishedAt == nil)
        #expect(secondCoordinator.buildStatesByImagePath[TestImages.libobjc]?.isBuilt == true)
        await engine.stop()
    }

    /// Clear History used to last until the next coverage refresh — after the next build, or the
    /// next time the Report navigator appeared — which took every corpus still in the engine for
    /// one another document had built and listed it again.
    @Test("a cleared history stays cleared when the coverage is refreshed")
    func clearedHistoryStaysCleared() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.clearedHistory", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }
        _ = try await nextValue(from: coordinator.$finishedBuilds.asDriver(), timeout: 60) { !$0.isEmpty }

        coordinator.clearFinishedBuilds()
        coordinator.refreshCoverage()

        let histories = try await values(from: coordinator.$finishedBuilds.asDriver(), during: 1)
        let staysCleared = histories.allSatisfy(\.isEmpty)
        #expect(staysCleared, "a cleared corpus came back as one another document built")
        await engine.stop()
    }

    @Test("a corpus evicted behind the coordinator's back stops showing as built once the coverage is refreshed")
    func evictionNoticedOnRefresh() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.eviction", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { $0[TestImages.libobjc]?.isBuilt == true }

        // What the store's resident budget does: no event, no notice.
        try await engine.evictInterfaceCorpus(for: TestImages.libobjc)
        coordinator.refreshCoverage()

        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 10) { $0[TestImages.libobjc] == nil }
        #expect(states[TestImages.libobjc] == nil)
        await engine.stop()
    }

    @Test("the resident limit from Settings reaches the engine")
    func residentLimitReachesEngine() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.limit", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.residentByteLimitMegabytes = 96
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        let coverage = try await waitForCoverage(of: engine) { $0.residentByteLimit == 96 * 1024 * 1024 }
        #expect(coverage.residentByteLimit == 96 * 1024 * 1024)
        await engine.stop()
    }

    /// A scope can name an image the engine has not indexed — a scope kept
    /// across an engine switch, the sidebar's image before it is listed. The
    /// corpus used to index such an image itself, outside both indexing
    /// schedulers, and an image that is not loaded at all left a failed build
    /// behind (PR121.32).
    @Test("asking for the corpus of an image that is not indexed indexes nothing and records no failure")
    func unindexedImageIsLeftAlone() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.unindexed")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }
        // Loaded in the test process, but this engine has not indexed it.
        let loadedImagePath = TestImages.libobjc
        // Not loaded in the test process at all.
        let unloadedImagePath = "/System/Library/Frameworks/GameController.framework/GameController"

        coordinator.requestBuild(of: loadedImagePath)
        coordinator.requestBuild(of: unloadedImagePath)

        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 30) { states in
            states.values.allSatisfy { !$0.isActive }
        }
        #expect(states[loadedImagePath] == nil, "the corpus of an image nobody indexed was \(String(describing: states[loadedImagePath]))")
        #expect(states[unloadedImagePath] == nil, "an image that is not loaded was left as \(String(describing: states[unloadedImagePath]))")
        #expect(coordinator.finishedBuilds.isEmpty, "the history lists \(coordinator.finishedBuilds.map(\.outcome))")
        #expect(try await engine.isImageIndexed(path: loadedImagePath) == false, "asking for the corpus indexed the image")
        await engine.stop()
    }
}

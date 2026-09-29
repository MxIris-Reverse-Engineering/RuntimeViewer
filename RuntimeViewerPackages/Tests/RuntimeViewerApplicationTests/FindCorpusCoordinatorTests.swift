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
}

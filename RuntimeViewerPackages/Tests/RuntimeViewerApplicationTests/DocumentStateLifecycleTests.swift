import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// How a document joins its engine's background work, and what closing it
/// does to the members `DocumentState` brings into being (PR121.09).
///
/// A document joins only by starting its background work: reading a
/// coordinator used to join as a side effect, so whatever read one first
/// decided when the document joined. `DocumentState` can outlive its window,
/// and with it the Find session and the corpus coordinator it holds, so their
/// `deinit` is no place to let go of work. Closing has to stop what exists —
/// and only that: bringing a member into being in order to close it starts
/// the observation and the requests closing is meant to stop.
@Suite("DocumentState lifecycle", .serialized)
@MainActor
struct DocumentStateLifecycleTests {
    @Test("closing a document that never started its background work brings neither the work nor the Find session into being")
    func closingCreatesNothing() throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState

        environment.make { documentState.documentWillClose() }

        #expect(!documentState.hasCreatedFindSession, "closing the document created a Find session")
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: documentState.runtimeEngine) == nil, "closing the document joined its engine's background work")
        #expect(!documentState.hasCreatedBackgroundWorkProcessActivity, "closing the document created its background work activity")
    }

    // MARK: - Starting the background work

    /// On an engine of its own: the closed coordinators an unstarted document
    /// hands out are not the engine's, but closing the indexing one still
    /// cancels the batches of the engine it was made for.
    @Test("a document that has not started its background work reads its coordinators without joining the engine's work")
    func readingTheCoordinatorsJoinsNothing() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateLifecycleTests.unstarted")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let documentState = environment.documentState

        let unstartedCoordinators = environment.make {
            (
                indexing: documentState.backgroundIndexingCoordinator,
                corpus: documentState.findCorpusCoordinator,
                crossReferences: documentState.crossReferencePreparationCoordinator
            )
        }
        defer { withExtendedLifetime(unstartedCoordinators) {} }

        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) == nil, "reading a coordinator joined the engine's background work")
        #expect(!documentState.hasCreatedFindSession, "reading a coordinator hooked a Find session to it")
        #expect(!documentState.hasCreatedBackgroundWorkProcessActivity, "reading a coordinator brought the background work activity into being")
        #expect(documentState.backgroundIndexingCoordinator === unstartedCoordinators.indexing, "every read hands out other coordinators")

        // Started, the document hands out the coordinators of the work it joined.
        environment.startBackgroundWork()

        let backgroundWork = try #require(environment.backgroundWorkRegistry.backgroundWork(on: engine), "starting joined nothing")
        #expect(documentState.backgroundIndexingCoordinator === backgroundWork.indexingCoordinator)
        #expect(documentState.findCorpusCoordinator === backgroundWork.corpusCoordinator)
        #expect(documentState.crossReferencePreparationCoordinator === backgroundWork.crossReferencePreparationCoordinator)
        #expect(documentState.backgroundIndexingCoordinator !== unstartedCoordinators.indexing)
        environment.make { documentState.documentWillClose() }
        await engine.stop()
    }

    @Test("starting the background work again keeps the work the document joined, and starting it once the document has closed joins nothing")
    func startingAgainOrAfterClosingJoinsNothingMore() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateLifecycleTests.startAgain")
        let startedEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let registry = startedEnvironment.backgroundWorkRegistry
        startedEnvironment.startBackgroundWork()
        let backgroundWork = try #require(registry.backgroundWork(on: engine))

        startedEnvironment.startBackgroundWork()

        #expect(registry.backgroundWork(on: engine) === backgroundWork, "starting again replaced the engine's work")
        #expect(try startedEnvironment.documentState.joinedIndexingCoordinator() === backgroundWork.indexingCoordinator)
        // The only document on the engine leaves, and the engine's work goes with it.
        startedEnvironment.make { startedEnvironment.documentState.documentWillClose() }
        #expect(registry.backgroundWork(on: engine) == nil)

        let closedEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        closedEnvironment.make { closedEnvironment.documentState.documentWillClose() }

        closedEnvironment.startBackgroundWork()

        #expect(registry.backgroundWork(on: engine) == nil, "a closed document joined its engine's background work")
        #expect(!closedEnvironment.documentState.hasCreatedFindSession)
        #expect(!closedEnvironment.documentState.hasCreatedBackgroundWorkProcessActivity)
        await engine.stop()
    }

    @Test("closing a document withdraws its corpus builds, and nothing asks for one afterwards")
    func closingWithdrawsCorpusBuilds() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateLifecycleTests.withdraw", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        environment.startBackgroundWork()
        let coordinator = try documentState.joinedCorpusCoordinator()
        defer { withExtendedLifetime(coordinator) {} }
        // Foundation takes seconds to print, so its build is under way when
        // the document closes.
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) {
            if case .building = $0[TestImages.foundation] { return true }
            return false
        }

        environment.make { documentState.documentWillClose() }

        // This document was the build's only subscriber, so the engine gives
        // it up — well before the build could have finished on its own.
        let deadline = Date().addingTimeInterval(5)
        var coverage = try await engine.interfaceCorpusCoverage()
        while coverage.statesByImagePath[TestImages.foundation]?.isActive == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            coverage = try await engine.interfaceCorpusCoverage()
        }
        #expect(coverage.statesByImagePath[TestImages.foundation]?.isActive != true, "the engine kept building for a closed document: \(String(describing: coverage.statesByImagePath[TestImages.foundation]))")

        // A settings change made in another window reaches the closed
        // document's coordinator; it must not ask for anything.
        try await engine.evictInterfaceCorpus(for: nil)
        environment.settings.search.isCorpusEnabled = false
        try await settleMainQueue()
        environment.settings.search.isCorpusEnabled = true
        try await Task.sleep(for: .seconds(1))
        let coverageAfterSettingsChange = try await engine.interfaceCorpusCoverage()
        #expect(coverageAfterSettingsChange.statesByImagePath.isEmpty, "a closed document asked for corpora: \(coverageAfterSettingsChange.statesByImagePath)")
        await engine.stop()
    }
}

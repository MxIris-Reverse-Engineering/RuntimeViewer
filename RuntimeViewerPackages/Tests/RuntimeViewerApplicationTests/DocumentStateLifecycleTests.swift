import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// What closing a document does to the members `DocumentState` brings into
/// being on first use (PR121.09).
///
/// `DocumentState` can outlive its window, and with it the Find session and
/// the corpus coordinator it holds, so their `deinit` is no place to let go
/// of work. Closing has to stop what exists — and only that: bringing a
/// member into being in order to close it starts the observation and the
/// requests closing is meant to stop.
@Suite("DocumentState lifecycle", .serialized)
@MainActor
struct DocumentStateLifecycleTests {
    @Test("closing a document that never opened Find brings neither the session nor the corpus coordinator into being")
    func closingCreatesNothing() throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState

        environment.make { documentState.documentWillClose() }

        #expect(!documentState.hasCreatedFindSession, "closing the document created a Find session")
        #expect(!documentState.hasCreatedFindCorpusCoordinator, "closing the document created a corpus coordinator")
    }

    @Test("closing a document withdraws its corpus builds, and nothing asks for one afterwards")
    func closingWithdrawsCorpusBuilds() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateLifecycleTests.withdraw", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let coordinator = environment.make { documentState.findCorpusCoordinator }
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

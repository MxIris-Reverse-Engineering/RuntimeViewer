import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCommunication
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// What the summary bar says when a search could not give a full answer: a regular expression
/// the engine stopped because it took too long (PR121.06), and a source whose RuntimeViewer is
/// older than Find itself (PR121.37), said the way the Report navigator says it.
@Suite("FindSession summary notices", .serialized)
@MainActor
struct FindSessionSummaryNoticeTests {
    @Test("a regular expression stopped for taking too long says the results are incomplete")
    func regularExpressionTooExpensiveSaysResultsAreIncomplete() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionSummaryNoticeTests.tooExpensive", loading: [TestImages.libobjc])
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        // Nested repetition over identifiers that are not followed by `(`: the engine spends its
        // whole time budget backtracking and stops the search.
        session.run(FindQuery(mode: .regularExpression, text: #"(\w+)+\("#))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 120) { !$0 }

        let summary = try #require(session.summary)
        #expect(summary.contains(FindSession.regularExpressionTooExpensiveNotice), "the summary does not say the search stopped early: \(summary)")
        await engine.stop()
    }

    @Test("a stopped search's notice is the summary's last word, after the counts")
    func noticeFollowsTheCounts() {
        var results = FindSession.Results()
        results.summary = "3 results in 2 types"
        results.stopReason = .regularExpressionTooExpensive
        #expect(FindSession.summary(of: results, corpusBuildStates: [:]) == "3 results in 2 types · " + FindSession.regularExpressionTooExpensiveNotice)
    }

    #if canImport(Network)
    @Test("a source older than Find says it does not support it, as the Report navigator does")
    func sourceWithoutFindSaysItIsNotSupported() async throws {
        // A connection that serves no command at all: what a peer older than the Find
        // navigator is, as far as its commands go.
        let olderPeer = try await RuntimeCommunicator().connect(
            to: .directTCP(name: "FindSessionSummaryNoticeTests.peer", host: nil, port: 0, role: .server),
            waitForConnection: false
        )
        defer { olderPeer.stop() }
        let port = try #require(olderPeer.connectionInfo?.port)
        let engine = RuntimeEngine(
            source: .directTCP(name: "FindSessionSummaryNoticeTests.client", host: "127.0.0.1", port: port, role: .client),
            engineID: "FindSessionSummaryNoticeTests.client"
        )
        try await engine.connect()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        session.run(FindQuery(mode: .text, text: "NSObject"))
        let summary = try await nextValue(from: session.$summary.asDriver(), timeout: 20) { $0 != nil }

        #expect(summary == "Not supported by this source")
        await engine.stop()
    }
    #endif
}

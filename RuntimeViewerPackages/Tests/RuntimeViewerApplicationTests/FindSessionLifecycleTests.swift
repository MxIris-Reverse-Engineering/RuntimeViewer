import Foundation
import RuntimeViewerArchitectures
@testable import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The Find session against the life of its document and of the engine calls
/// it makes: a session may outlive its document, and must then neither read
/// the document nor start a search of its own; a search in flight must not
/// keep it alive; and what a replaced or failed call brings back must not
/// reach the results on screen.
@Suite("FindSession lifecycle", .serialized)
@MainActor
struct FindSessionLifecycleTests {
    @Test("a session that outlives its document ignores a Generation Options change")
    func sessionOutlivingItsDocumentIgnoresOptionsChange() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment()

        var documentState: DocumentState? = DocumentState(runtimeEngine: engine)
        weak let releasedDocumentState = documentState
        // Built inside `make` so the session's `@Dependency` takes the
        // environment's isolated `AppDefaults`.
        let session = try environment.make { try #require(documentState).findSession }
        session.run(FindQuery(mode: .text, text: "NSObject"))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        #expect(session.results.summary != nil, "a search on screen is what a Generation Options change runs again")

        // The session stays alive the way an engine call that cannot be
        // cancelled keeps it alive; the document goes.
        documentState = nil
        #expect(releasedDocumentState == nil)

        var changedOptions = environment.appDefaults.options
        changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
        environment.appDefaults.options = changedOptions
        try await settleMainQueue()

        // Before the fix the rerun read the freed document through `unowned`
        // and the process aborted here.
        #expect(session.isSearching == false)
    }

    @Test("after its document closes, a session starts no search on a Generation Options change")
    func closedSessionStartsNoSearch() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }
        session.run(FindQuery(mode: .text, text: "NSObject"))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        let resultsBeforeClose = session.results

        session.documentWillClose()

        var changedOptions = environment.appDefaults.options
        changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
        environment.appDefaults.options = changedOptions

        let searchingStates = try await values(from: session.$isSearching.asDriver(), during: 1)
        #expect(!searchingStates.contains(true), "a Generation Options change started a search after the document closed")
        #expect(session.results == resultsBeforeClose)
    }

    #if canImport(Network)
    /// The task making an engine call used to hold the session until the
    /// call returned, so a document that went away mid-search left its
    /// session behind — and a session whose `deinit` never runs never
    /// withdraws the call either (the third layer of PR121.02). The peer
    /// here holds the search for as long as the test runs.
    @Test("a session whose document goes away while its search is under way goes with it")
    func sessionGoesWithItsDocumentMidSearch() async throws {
        let peer = try await ScriptedPeer.make(label: "FindSessionLifecycleTests.documentGoesMidSearch")
        let heldSearches = HeldRequests()
        peer.serve(.searchInterfaces) { () async throws -> RuntimeInterfaceSearchSummary in
            await heldSearches.hold()
            throw CancellationError()
        }
        let environment = ViewModelTestEnvironment()
        var documentState: DocumentState? = DocumentState(runtimeEngine: peer.client)
        weak var releasedSession: FindSession?
        do {
            let session = try environment.make { try #require(documentState).findSession }
            releasedSession = session
            session.run(FindQuery(mode: .text, text: "NSObject"))
        }
        let searchArrived = await pollUntil(timeout: .seconds(10)) { await heldSearches.arrivedCount == 1 }
        #expect(searchArrived, "the search never reached the peer")

        documentState = nil

        #expect(releasedSession == nil, "the search under way kept the session of a document that is gone")
        await heldSearches.release()
        await peer.stop()
    }
    #endif

    // MARK: - A search replaced

    enum SearchReplacement: CaseIterable, Sendable, CustomTestStringConvertible {
        case newSearch
        case clearedField

        var testDescription: String {
            switch self {
            case .newSearch: "a new search"
            case .clearedField: "the field cleared"
            }
        }
    }

    /// Cancelling a search reaches the engine, which hands over no batch
    /// afterwards — but a batch it handed over just before waits for the main
    /// actor like any other work, behind whatever the window is busy with.
    /// Holding the main thread puts one there: the engine reads libobjc and
    /// hands its hits over while this test keeps the main thread, then the
    /// search is replaced. Before PR121.05 that batch landed in the results
    /// of the search that replaced it, or in a list just cleared.
    @Test("a batch a replaced search handed over just before does not reach the results", arguments: SearchReplacement.allCases)
    func replacedSearchBatchIsDropped(replacement: SearchReplacement) async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionLifecycleTests.replaced.\(replacement)", loading: [TestImages.libobjc])
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }

        session.run(FindQuery(mode: .text, text: "NSObject", isCaseSensitive: true))
        // The search's task starts and hands the query to the engine…
        await Task.yield()
        // …which reads libobjc and hands its batch over meanwhile.
        Self.holdMainThread(forSeconds: 1)
        switch replacement {
        case .newSearch:
            session.run(FindQuery(mode: .text, text: "zzzNoSuchToken", isCaseSensitive: true))
        case .clearedField:
            session.clear()
        }

        let emittedResults = try await values(from: session.$results.asDriver(), during: 2)
        let leakedResults = emittedResults.filter { !$0.nodes.isEmpty }
        #expect(leakedResults.isEmpty, "the replaced search's hits reached the results: \(leakedResults.map { $0.summary ?? "" })")
        #expect(session.results.nodes.isEmpty)
        #expect(session.isSearching == false)
        await engine.stop()
    }

    @Test("a source switch leaves nothing of the old engine on screen and runs the search on the new one")
    func sourceSwitchRunsTheSearchOnTheNewEngine() async throws {
        let oldEngine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionLifecycleTests.switch.old", loading: [TestImages.libobjc])
        _ = try await oldEngine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let newEngine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionLifecycleTests.switch.new")
        let environment = ViewModelTestEnvironment(runtimeEngine: oldEngine)
        let session = environment.make { environment.documentState.findSession }

        session.run(FindQuery(mode: .text, text: "NSObject", isCaseSensitive: true))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

        environment.documentState.selectionRouter.trigger(.switchEngine(newEngine))

        // Run again on the new engine, which has no corpus: nothing found. Before
        // the fix nothing ran, and the old engine's rows stayed.
        let rerunResults = try await nextValue(from: session.$results.asDriver(), timeout: 30) { results in
            results.summary?.hasPrefix("0 results") == true
        }
        #expect(!rerunResults.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc }, "the old engine's rows stayed on screen")
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 30) { !$0 }
        #expect(session.query.text == "NSObject", "the query on the page changed")
        await oldEngine.stop()
        await newEngine.stop()
    }

    /// The local-runtime service relaunching while the document sits at the
    /// image list with nothing open: `.switchEngine` has nothing to walk back
    /// there, so the engine never "changed", and the rows of the process that
    /// is gone stayed on screen (the gap PR121.05 left, closed with PR121.30).
    /// An in-process engine goes through the same edge with `stop()` and
    /// `connect()`.
    @Test("a search on screen runs again when the engine comes back while the document has nothing open")
    func engineComingBackAtTheImageListRunsTheSearchAgain() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindSessionLifecycleTests.engineBack", loading: [TestImages.libobjc])
        _ = try await engine.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }
        session.run(FindQuery(mode: .text, text: "NSObject", isCaseSensitive: true))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 30) { !$0 }
        #expect(environment.documentState.currentImageNode == nil)

        await engine.stop()
        try await engine.connect()

        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 10) { $0 }
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 30) { !$0 }
        #expect(session.query.text == "NSObject")
        await engine.stop()
    }

    // MARK: - A widening search that fails

    #if os(macOS)
    /// A search on screen reads each corpus built after it ran. When that
    /// widening search failed — the connection to the engine gone — it
    /// returned before clearing `isSearching`, so the spinner never stopped
    /// and every corpus built later waited on it (PR121.38).
    @Test("a widening search that fails leaves the session idle and keeps the results it would have merged into")
    func failedWideningSearchEndsTheSearch() async throws {
        let fixture = try await LocalRuntimeServiceFixture.make(label: "FindSessionLifecycleTests.failedWidening")
        try await fixture.serving.loadImage(at: TestImages.libobjc)
        _ = try await fixture.client.buildInterfaceCorpus(for: TestImages.libobjc, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: fixture.client)
        let session = environment.make { environment.documentState.findSession }

        session.run(FindQuery(mode: .text, text: "NSObject", isCaseSensitive: true))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc })

        // From here every request fails, and not with a cancellation: the
        // connection to the service is gone.
        await fixture.client.stop()
        session.corpusDidBuild(at: TestImages.foundation)
        #expect(session.isSearching, "the corpus built after the search was not read")

        let isSearching = try await nextValue(from: session.$isSearching.asDriver(), timeout: 10) { !$0 }
        #expect(!isSearching)
        #expect(session.results.nodes.contains { Self.imagePath(of: $0) == TestImages.libobjc }, "the failed widening emptied the results")
        await fixture.stop()
    }
    #endif

    // MARK: - Helpers

    /// Keeps the main thread busy, as drawing a large window does: work handed
    /// to the main actor meanwhile waits until it is free.
    private static func holdMainThread(forSeconds seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    static func imagePath(of node: FindResultNode) -> String? {
        if case .object(let object, _) = node.content {
            return object.imagePath
        }
        return nil
    }
}

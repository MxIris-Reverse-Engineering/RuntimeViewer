import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The engine a document is on and its hold on that engine's background work, as the one value
/// `DocumentState.runtimeEngineSession`. Whatever follows it finds the engine and the work that
/// goes with it together: a page bound before the document started finds the work once it does,
/// the first value after a move to another engine already holds that engine's work, the same
/// engine starting over puts the same session in place again, and the document leaving an
/// engine withdraws what it asked of the engine's work there.
///
/// The document used to keep the engine and the work as two things to keep in step — the work
/// moved before the engine was assigned, and a page had to bind after the document joined — and
/// each of these held only because every caller kept to that order.
@Suite("RuntimeEngineSession", .serialized)
@MainActor
struct RuntimeEngineSessionTests {
    @Test("a Report page and a Find session bound before the document starts find the engine's work once it does")
    func bindingBeforeStartingFindsTheWork() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.bindFirst")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Indexing off, so the page shows its row saying so as soon as it has the engine's work.
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let page = environment.make { ReportPage(documentState: documentState) }
        let session = environment.make { documentState.findSession }
        defer { withExtendedLifetime((page, session)) {} }
        #expect(try await values(from: page.nodes, during: 0.3).allSatisfy(\.isEmpty), "a document that has not started shows a Report")

        environment.startBackgroundWork()

        let nodes = try await nextValue(from: page.nodes) { !$0.isEmpty }
        #expect(nodes.first?.children.map(\.identifier) == [.turnedOff(.backgroundIndexing)])
        // The Find session asks the engine's corpus coordinator for the images it scopes to.
        session.update { $0.scope = .images([TestImages.libobjc]) }
        #expect(try documentState.joinedCorpusCoordinator().buildStatesByImagePath[TestImages.libobjc] != nil, "the Find session does not follow the corpus coordinator of the work the document started")
        environment.make { documentState.documentWillClose() }
        await engine.stop()
    }

    @Test("the first session after a move to another engine already holds that engine's work, and only one comes")
    func movingPutsOneSessionWithTheWorkInPlace() async throws {
        let firstEngine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.move.first")
        let secondEngine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.move.second")
        let environment = ViewModelTestEnvironment(runtimeEngine: firstEngine)
        environment.startBackgroundWork()
        var sessions: [RuntimeEngineSession] = []
        let subscription = environment.documentState.$runtimeEngineSession.asObservable().skip(1).subscribeOnNext { session in
            sessions.append(session)
        }
        defer { subscription.dispose() }

        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(secondEngine)) }

        #expect(sessions.count == 1, "the move put \(sessions.count) sessions in place")
        let session = try #require(sessions.first)
        #expect(session.engine === secondEngine)
        let secondEnginesWork = try #require(environment.backgroundWorkRegistry.backgroundWork(on: secondEngine), "the move joined nothing on the engine it went to")
        #expect(session.backgroundWork === secondEnginesWork, "the first session after the move does not hold the work of the engine it moved to")
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: firstEngine) == nil, "the engine the only document left kept its work")
        environment.make { environment.documentState.documentWillClose() }
        await firstEngine.stop()
        await secondEngine.stop()
    }

    /// Driven by the route itself, not by stopping and connecting the engine: an engine coming
    /// back reloads its data, which empties the cache on its own and would hide whether the session
    /// was put in place again.
    @Test("the same engine starting over while something is open keeps the session and puts it in place again, so the interface cache starts over")
    func sameEngineStartingOverPutsTheSessionInPlaceAgain() async throws {
        // The engine's first connection reloads its data once: over before the cache exists, or
        // it would empty the cache itself and hide whether the session was put in place again.
        let engine = try await TestRuntimeEngine.makeConnectedWithItsFirstReloadOver(engineID: "RuntimeEngineSessionTests.sameEngine")
        let documentState = DocumentState(runtimeEngine: engine)
        let fetchCounter = FetchCounter()
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchCounter.increment()
            return RuntimeObjectInterface(object: object, interfaceString: "class SessionFixture {}")
        }
        let object = Fixtures.runtimeObject(name: "SessionFixture")
        _ = try await interfaceCache.interface(for: object, options: .init())
        _ = try await interfaceCache.interface(for: object, options: .init())
        #expect(fetchCounter.count == 1)
        let imageTree = Fixtures.imageTree(rootName: "Images", imagePaths: [TestImages.libobjc])
        let imageNode = try #require(imageTree.leaf(forImagePath: TestImages.libobjc))
        documentState.selectionRouter.trigger(.switchImage(imageNode))
        let session = documentState.runtimeEngineSession

        documentState.selectionRouter.trigger(.switchEngine(engine))
        try await settleMainQueue()

        #expect(documentState.runtimeEngineSession === session, "the same engine starting over replaced the session")
        _ = try await interfaceCache.interface(for: object, options: .init())
        #expect(fetchCounter.count == 2, "the engine started over and the cache still served the interface it had")
        withExtendedLifetime(imageTree) {}
        await engine.stop()
    }

    /// Another document stays on the engine, so its work runs on and would go on favouring the
    /// image a sidebar no longer shows.
    @Test("a document moving to another engine withdraws the image its sidebar showed on the engine it left")
    func leavingWithdrawsTheSidebarsImage() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.leave")
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.leave.other")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let stayingEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.startBackgroundWork()
        stayingEnvironment.startBackgroundWork()
        let corpusCoordinator = try environment.documentState.joinedCorpusCoordinator()
        let document = ObjectIdentifier(environment.documentState)
        let imageTree = Fixtures.imageTree(rootName: "Images", imagePaths: [TestImages.libobjc])
        let imageNode = try #require(imageTree.leaf(forImagePath: TestImages.libobjc))
        environment.make { environment.documentState.selectionRouter.trigger(.switchImage(imageNode)) }
        #expect(corpusCoordinator.onScreenImagePath(ofDocument: document) == imageNode.path)

        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine)) }

        #expect(corpusCoordinator.onScreenImagePath(ofDocument: document) == nil, "the engine left behind still favours the image the document showed")
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) != nil, "the engine's work closed with a document still on it")
        withExtendedLifetime(imageTree) {}
        environment.make { environment.documentState.documentWillClose() }
        stayingEnvironment.make { stayingEnvironment.documentState.documentWillClose() }
        await engine.stop()
        await otherEngine.stop()
    }

    @Test("after a move to another engine the Find session follows that engine's corpus coordinator")
    func findSessionFollowsTheEngineMovedTo() async throws {
        let firstEngine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.find.first")
        let secondEngine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineSessionTests.find.second")
        let environment = ViewModelTestEnvironment(runtimeEngine: firstEngine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        environment.startBackgroundWork()
        let session = environment.make { documentState.findSession }

        environment.make { documentState.selectionRouter.trigger(.switchEngine(secondEngine)) }
        session.update { $0.scope = .images([TestImages.libobjc]) }

        #expect(try documentState.joinedCorpusCoordinator().buildStatesByImagePath[TestImages.libobjc] != nil, "the Find session asked the corpus coordinator of the engine it left")
        environment.make { documentState.documentWillClose() }
        await firstEngine.stop()
        await secondEngine.stop()
    }
}

/// A window's Report navigator page, on screen, its filter bar untouched.
@MainActor
private final class ReportPage {
    /// Held here because the ViewModel keeps its router `unowned`.
    let router = MockRouter<SidebarRootRoute>()
    let viewModel: ReportViewModel<SidebarRootRoute>
    let nodes: Driver<[ReportNode]>

    init(documentState: DocumentState) {
        viewModel = ReportViewModel(documentState: documentState, router: router)
        nodes = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
            isVisible: .just(true),
            cancel: .empty(),
            cancelAll: .empty(),
            clearHistory: .empty(),
            openSettings: .empty(),
            doubleClickedNode: .empty(),
            filter: .just(.empty),
            showsOnlyInProgress: .just(false)
        )).nodes
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fetchCount = 0

    var count: Int {
        lock.withLock { fetchCount }
    }

    func increment() {
        lock.withLock { fetchCount += 1 }
    }
}

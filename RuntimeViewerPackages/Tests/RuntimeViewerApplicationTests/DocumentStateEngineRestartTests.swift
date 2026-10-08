import Testing
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerApplication

/// A document walks back to the image list when its engine stops being
/// ready and becomes ready again — the local-runtime XPC service having been
/// relaunched, seen through the one edge an in-process engine can reproduce:
/// `stop()` followed by `connect()`.
@Suite("DocumentState engine restart")
@MainActor
struct DocumentStateEngineRestartTests {
    private static func makeImageNode() -> RuntimeImageNode {
        let rootImageNode = RuntimeImageNode.rootNode(for: [TestImages.libobjc], name: "Root")
        var leafImageNode = rootImageNode
        while let firstChild = leafImageNode.children.first {
            leafImageNode = firstChild
        }
        withExtendedLifetime(rootImageNode) {
            _ = leafImageNode.absolutePath
        }
        return leafImageNode
    }

    @Test("Browsing an image, then the engine restarting, lands back on the image list")
    func restartResetsToTheImageList() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.reset")
        let documentState = DocumentState(runtimeEngine: engine)
        defer { withExtendedLifetime(documentState) {} }

        documentState.selectionRouter.trigger(.switchImage(Self.makeImageNode()))
        documentState.selectionRouter.trigger(.newTab)
        #expect(documentState.currentImageNode != nil)
        #expect(documentState.tabs.count == 2)

        await engine.stop()
        try await engine.connect()

        let resetToRoot = await pollUntil(timeout: .seconds(5)) { documentState.currentImageNode == nil }
        #expect(resetToRoot, "the document kept the image after its engine came back")
        #expect(documentState.tabs.count == 1)
        #expect(documentState.runtimeEngine === engine)
    }

    @Test("The engine's first connection does not disturb a document that has nothing open")
    func firstConnectionIsNotARestart() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "DocumentStateEngineRestartTests.first")
        let documentState = DocumentState(runtimeEngine: engine)
        defer { withExtendedLifetime(documentState) {} }
        var routes: [SelectionRoute] = []
        let subscription = documentState.routeSignal.emit(onNext: { routes.append($0) })
        defer { subscription.dispose() }

        try await engine.connect()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(routes.isEmpty)
        #expect(documentState.currentImageNode == nil)
    }

    /// `.switchEngine` leaves a document with nothing open alone, so the
    /// engine coming back used to reach no one: whatever a member had learned
    /// from the old process — the Find results, the corpus states — stayed.
    @Test("The engine coming back while nothing is open announces a reset, and sends no route")
    func comingBackWithNothingOpenAnnouncesAReset() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.resetAtTheImageList")
        let documentState = DocumentState(runtimeEngine: engine)
        defer { withExtendedLifetime(documentState) {} }
        var routes: [SelectionRoute] = []
        var resetEngines: [RuntimeEngine] = []
        let routeSubscription = documentState.routeSignal.emit(onNext: { routes.append($0) })
        let resetSubscription = documentState.runtimeEngineDidReset.emit(onNext: { resetEngines.append($0) })
        defer {
            routeSubscription.dispose()
            resetSubscription.dispose()
        }

        await engine.stop()
        try await engine.connect()

        let isAnnounced = await pollUntil(timeout: .seconds(5)) { !resetEngines.isEmpty }
        #expect(isAnnounced, "the engine came back and nothing heard of it")
        #expect(resetEngines.count == 1)
        #expect(resetEngines.first === engine)
        #expect(routes.isEmpty)
    }

    @Test("The engine coming back while an image is open walks back through the route and announces the reset once")
    func comingBackWhileBrowsingAnnouncesTheResetOnce() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.resetWhileBrowsing")
        let documentState = DocumentState(runtimeEngine: engine)
        defer { withExtendedLifetime(documentState) {} }
        documentState.selectionRouter.trigger(.switchImage(Self.makeImageNode()))
        var resetEngines: [RuntimeEngine] = []
        let resetSubscription = documentState.runtimeEngineDidReset.emit(onNext: { resetEngines.append($0) })
        defer { resetSubscription.dispose() }

        await engine.stop()
        try await engine.connect()

        let resetToRoot = await pollUntil(timeout: .seconds(5)) { documentState.currentImageNode == nil }
        #expect(resetToRoot)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(resetEngines.count == 1, "the reset was announced \(resetEngines.count) times")
    }

    @Test("Switching to another engine announces the reset; putting back the engine in place with nothing open does not")
    func switchingEnginesAnnouncesTheReset() async throws {
        let firstEngine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.announce-first")
        let secondEngine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.announce-second")
        let documentState = DocumentState(runtimeEngine: firstEngine)
        defer { withExtendedLifetime(documentState) {} }
        var resetEngines: [RuntimeEngine] = []
        let resetSubscription = documentState.runtimeEngineDidReset.emit(onNext: { resetEngines.append($0) })
        defer { resetSubscription.dispose() }

        documentState.selectionRouter.trigger(.switchEngine(secondEngine))
        #expect(resetEngines.count == 1)
        #expect(resetEngines.first === secondEngine)

        // The route's own no-op: the same engine, nothing open.
        documentState.selectionRouter.trigger(.switchEngine(secondEngine))
        #expect(resetEngines.count == 1)
    }

    @Test("Switching to another engine moves the restart watch with it")
    func watchFollowsEngineSwitch() async throws {
        let firstEngine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.first-of-two")
        let secondEngine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentStateEngineRestartTests.second-of-two")
        let documentState = DocumentState(runtimeEngine: firstEngine)
        defer { withExtendedLifetime(documentState) {} }

        documentState.selectionRouter.trigger(.switchEngine(secondEngine))
        documentState.selectionRouter.trigger(.switchImage(Self.makeImageNode()))
        #expect(documentState.currentImageNode != nil)

        // The old engine restarting is nobody's business any more.
        await firstEngine.stop()
        try await firstEngine.connect()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(documentState.currentImageNode != nil)

        await secondEngine.stop()
        try await secondEngine.connect()
        let followedRestart = await pollUntil(timeout: .seconds(5)) { documentState.currentImageNode == nil }
        #expect(followedRestart, "the document did not follow its current engine's restart")
    }
}

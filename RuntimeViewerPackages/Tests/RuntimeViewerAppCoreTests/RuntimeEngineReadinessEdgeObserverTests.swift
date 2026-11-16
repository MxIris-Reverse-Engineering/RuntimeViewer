import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What the documents and the engine's coordinators hear through
/// `RuntimeEngineReadinessEdgeObserver`: an engine becoming ready again, once
/// per edge, and nothing for the state it is in when observing starts.
@Suite("RuntimeEngineReadinessEdgeObserver", .serialized)
@MainActor
struct RuntimeEngineReadinessEdgeObserverTests {
    @MainActor
    private final class EdgeCount {
        var value = 0
    }

    @Test("an engine already ready when observed reports nothing; stopping and connecting it again reports once")
    func reportsEachReturnOnce() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineReadinessEdgeObserverTests.reportsEachReturnOnce")
        let edgeCount = EdgeCount()
        let observer = RuntimeEngineReadinessEdgeObserver(engine: engine) { _ in
            edgeCount.value += 1
        }
        defer { withExtendedLifetime(observer) {} }

        try await Task.sleep(for: .milliseconds(100))
        #expect(edgeCount.value == 0)

        await engine.stop()
        try await engine.connect()

        #expect(await pollUntil(timeout: .seconds(5)) { edgeCount.value == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(edgeCount.value == 1)
        await engine.stop()
    }

    @Test("a released observer reports nothing")
    func releasedObserverIsSilent() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineReadinessEdgeObserverTests.releasedObserverIsSilent")
        let edgeCount = EdgeCount()
        var observer: RuntimeEngineReadinessEdgeObserver? = RuntimeEngineReadinessEdgeObserver(engine: engine) { _ in
            edgeCount.value += 1
        }
        _ = observer
        observer = nil

        await engine.stop()
        try await engine.connect()

        try await Task.sleep(for: .milliseconds(200))
        #expect(edgeCount.value == 0)
        await engine.stop()
    }
}

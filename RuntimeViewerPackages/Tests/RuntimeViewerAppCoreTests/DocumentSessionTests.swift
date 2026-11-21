import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The document session both front ends hold per window (proposal
/// `window-model-on-ios`): it joins the engine's background work when it
/// opens, leaves it when it closes, and does each once — the order the macOS
/// `Document` keeps and the iOS windows now keep through the same type.
@Suite("A document session")
@MainActor
struct DocumentSessionTests {
    @Test("opening joins the engine's background work, and opening again changes nothing")
    func openingJoinsTheWorkOnce() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentSessionTests.open")
        let environment = ViewModelTestEnvironment()
        let session = environment.make { DocumentSession(runtimeEngine: engine) }
        #expect(session.documentState.runtimeEngineSession.backgroundWork == nil, "a session that has not opened already holds the engine's work")

        environment.make { session.open() }
        let work = try #require(session.documentState.runtimeEngineSession.backgroundWork, "opening did not join the engine's work")
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) === work)

        environment.make { session.open() }
        #expect(session.documentState.runtimeEngineSession.backgroundWork === work, "opening again joined the work a second time")
    }

    @Test("closing leaves the engine's work, and the session does not open again")
    func closingLeavesTheWork() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentSessionTests.close")
        let environment = ViewModelTestEnvironment()
        let session = environment.make { DocumentSession(runtimeEngine: engine) }
        environment.make { session.open() }
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) != nil)

        session.close()
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) == nil, "the only document left and the engine's work stayed")

        environment.make { session.open() }
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) == nil, "a closed session joined the engine's work again")
    }

    @Test("a session closed before it opened never joins the engine's work")
    func closingBeforeOpening() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentSessionTests.closeFirst")
        let environment = ViewModelTestEnvironment()
        let session = environment.make { DocumentSession(runtimeEngine: engine) }

        session.close()
        environment.make { session.open() }
        #expect(session.documentState.runtimeEngineSession.backgroundWork == nil)
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) == nil)
    }

    @Test("sessions are numbered in the order they are made")
    func numbersCountUp() {
        let environment = ViewModelTestEnvironment()
        let first = environment.make { DocumentSession(runtimeEngine: .local) }
        let second = environment.make { DocumentSession(runtimeEngine: .local) }
        #expect(first.number >= 1)
        #expect(second.number == first.number + 1)
    }
}

import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The iOS-family apps' windows and their document sessions (proposal
/// `window-model-on-ios`): one session per window, kept while the process
/// lives, a reserved engine for a window opened on a file, this device for
/// any other, and the session closed when the user closes the window.
@Suite("The document sessions of an app's windows")
@MainActor
struct DocumentSessionRegistryTests {
    @Test("a window gets one session and keeps it")
    func aWindowKeepsItsSession() {
        let registry = DocumentSessionRegistry(makeDefaultRuntimeEngine: { TestRuntimeEngine.makeUnreachable() })
        let environment = ViewModelTestEnvironment()
        let first = environment.make { registry.session(forWindow: "window-1", requestIdentifier: nil) }
        let again = environment.make { registry.session(forWindow: "window-1", requestIdentifier: UUID()) }
        let other = environment.make { registry.session(forWindow: "window-2", requestIdentifier: nil) }

        #expect(again === first, "a window connecting again got a new session")
        #expect(other !== first)
    }

    @Test("a reserved engine goes to the window that asks for it, once")
    func aReservedEngineGoesToItsWindow() {
        let defaultEngine = TestRuntimeEngine.makeUnreachable()
        let reservedEngine = RuntimeEngine(
            source: .directTCP(name: "reserved", host: "127.0.0.1", port: 2, role: .client),
            engineID: "DocumentSessionRegistryTests.reserved"
        )
        let registry = DocumentSessionRegistry(makeDefaultRuntimeEngine: { defaultEngine })
        let environment = ViewModelTestEnvironment()
        let requestIdentifier = registry.reserveWindow(on: reservedEngine)

        let fileWindow = environment.make { registry.session(forWindow: "file-window", requestIdentifier: requestIdentifier) }
        #expect(fileWindow.documentState.runtimeEngine === reservedEngine)

        let laterWindow = environment.make { registry.session(forWindow: "later-window", requestIdentifier: requestIdentifier) }
        #expect(laterWindow.documentState.runtimeEngine === defaultEngine, "a reservation was handed out twice")
    }

    @Test("a window whose request is unknown or was cancelled starts on this device")
    func anUnknownRequestStartsOnThisDevice() {
        let defaultEngine = TestRuntimeEngine.makeUnreachable()
        let reservedEngine = RuntimeEngine(
            source: .directTCP(name: "cancelled", host: "127.0.0.1", port: 3, role: .client),
            engineID: "DocumentSessionRegistryTests.cancelled"
        )
        let registry = DocumentSessionRegistry(makeDefaultRuntimeEngine: { defaultEngine })
        let environment = ViewModelTestEnvironment()

        let restoredWindow = environment.make { registry.session(forWindow: "restored-window", requestIdentifier: UUID()) }
        #expect(restoredWindow.documentState.runtimeEngine === defaultEngine)

        let requestIdentifier = registry.reserveWindow(on: reservedEngine)
        registry.cancelReservation(requestIdentifier)
        let window = environment.make { registry.session(forWindow: "window-after-a-failed-request", requestIdentifier: requestIdentifier) }
        #expect(window.documentState.runtimeEngine === defaultEngine, "a cancelled reservation was still handed out")
    }

    @Test("closing a window closes its session, and the window identifier starts over")
    func discardingAWindowClosesItsSession() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DocumentSessionRegistryTests.discard")
        let registry = DocumentSessionRegistry(makeDefaultRuntimeEngine: { engine })
        let environment = ViewModelTestEnvironment()
        let session = environment.make { registry.session(forWindow: "window", requestIdentifier: nil) }
        environment.make { session.open() }
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) != nil)

        registry.discardSessions(forWindows: ["window", "a-window-never-connected"])
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: engine) == nil, "the closed window's session still holds the engine's work")

        let next = environment.make { registry.session(forWindow: "window", requestIdentifier: nil) }
        #expect(next !== session)
    }
}

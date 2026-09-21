#if os(macOS)

import Testing
import Foundation
import Combine
@testable import RuntimeViewerCommunication

/// Contract suite for the XPC-service connection pair, run with both ends in
/// this process: the listener side over an anonymous `XPCListener`, the client
/// side connected to its endpoint. Everything the embedded service relies on
/// — typed round trips, pushes from the service to the client, a handler
/// failure crossing the wire as a description, and the state each side
/// reports — is exercised here without launching a service.
@Suite("RuntimeXPCServiceConnection")
struct RuntimeXPCServiceConnectionTests {
    fileprivate struct Greeting: Codable, Equatable {
        let name: String
        let count: Int
    }

    private struct DeliberateFailure: LocalizedError {
        var errorDescription: String? { "the handler declined on purpose" }
    }

    /// One listener with an `echo` handler, activated, plus a client
    /// connected to it. `configureClient` runs before the client activates,
    /// which is where a push handler has to be installed.
    private static func makePair(
        configureClient: ((RuntimeXPCServiceClientConnection) -> Void)? = nil
    ) async throws -> (listener: RuntimeXPCServiceListenerConnection, client: RuntimeXPCServiceClientConnection) {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.setMessageHandler(name: "echo") { (greeting: Greeting) -> Greeting in
            Greeting(name: "echo:" + greeting.name, count: greeting.count + 1)
        }
        listener.setMessageHandler(name: "fail") { (_: Greeting) -> Greeting in
            throw DeliberateFailure()
        }
        listener.setMessageHandler(name: "ping") {}
        listener.activate()

        let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint)) { client in
            configureClient?(client)
        }
        return (listener, client)
    }

    @Test("A typed request round-trips through JSON payloads")
    func requestRoundTrips() async throws {
        let (listener, client) = try await Self.makePair()
        defer { client.stop(); listener.stop() }

        let reply: Greeting = try await client.sendMessage(name: "echo", request: Greeting(name: "runtime", count: 1))

        #expect(reply == Greeting(name: "echo:runtime", count: 2))
    }

    @Test("A handler that throws reaches the client as a remote failure carrying its description")
    func handlerFailureCrossesTheWire() async throws {
        let (listener, client) = try await Self.makePair()
        defer { client.stop(); listener.stop() }

        await #expect(throws: RuntimeXPCServiceConnectionError.remoteFailure(DeliberateFailure().localizedDescription)) {
            let _: Greeting = try await client.sendMessage(name: "fail", request: Greeting(name: "x", count: 0))
        }
    }

    @Test("A listener nobody has reached has no peer to push to")
    func listenerWithoutClientHasNoPeer() async throws {
        let (listener, _) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.activate()
        defer { listener.stop() }

        await #expect(throws: RuntimeXPCServiceConnectionError.noClientAttached) {
            try await listener.sendMessage(name: "push", request: Greeting(name: "early", count: 0))
        }
        #expect(!listener.state.isConnected)
    }

    @Test("The listener adopts the client on its hello and can push to it from then on")
    func listenerPushesToTheAttachedClient() async throws {
        let received = PushRecorder()
        let (listener, client) = try await Self.makePair { client in
            client.setMessageHandler(name: "push") { (greeting: Greeting) in
                await received.record(greeting)
            }
        }
        defer { client.stop(); listener.stop() }

        // The hello in the client's `init` is what got it adopted: no request
        // had to go first.
        #expect(listener.state.isConnected)
        #expect(client.state.isConnected)

        try await listener.sendMessage(name: "push", request: Greeting(name: "pushed", count: 7))

        let greetings = await received.greetings
        #expect(greetings == [Greeting(name: "pushed", count: 7)])
    }

    @Test("Stopping the client is terminal and reported without an error")
    func stopIsTerminal() async throws {
        let (listener, client) = try await Self.makePair()
        defer { listener.stop() }

        try await client.sendMessage(name: "ping")
        client.stop()

        #expect(client.state == .disconnected(error: nil))
        #expect(!client.isUsable)
        await #expect(throws: RuntimeXPCServiceConnectionError.connectionInvalid) {
            try await client.sendMessage(name: "ping")
        }
    }

    @Test("A handler-less message name is a remote failure, not a hang")
    func unknownMessageNameFails() async throws {
        let (listener, client) = try await Self.makePair()
        defer { client.stop(); listener.stop() }

        await #expect(throws: (any Error).self) {
            try await client.sendMessage(name: "no-such-handler")
        }
    }

    /// `.local` is an identity, not a transport: the factory hands out a
    /// connection for it only when told which service to reach.
    @Test("The communicator connects .local through the xpcService credential, and refuses it without one")
    func communicatorRoutesLocalThroughTheCredential() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.setMessageHandler(name: "ping") {}
        listener.activate()
        defer { listener.stop() }
        let communicator = RuntimeCommunicator()

        let connection = try await communicator.connect(to: .local, credential: .xpcService(.anonymousListener(endpoint)))
        defer { connection.stop() }
        try await connection.sendMessage(name: "ping")
        #expect(connection.state.isConnected)

        await #expect(throws: RuntimeCommunicatorError.localConnectionNotSupported) {
            _ = try await communicator.connect(to: .local)
        }
    }
}

/// The client reattaching on its own after the service went away, driven
/// through the interruption seam: a real XPC connection only reports an
/// interruption when the service process actually dies, and against an
/// anonymous listener in this process the reattach `hello` then simply lands.
@Suite("RuntimeXPCServiceClientConnection reattach")
struct RuntimeXPCServiceClientConnectionReattachTests {
    private struct ServiceStillDown: LocalizedError {
        var errorDescription: String? { "the service died again while relaunching" }
    }

    private static func makePair() async throws -> (listener: RuntimeXPCServiceListenerConnection, client: RuntimeXPCServiceClientConnection) {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.setMessageHandler(name: "ping") {}
        listener.activate()
        let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint))
        client.setReattachDelays(inNanoseconds: [20_000_000, 20_000_000, 20_000_000])
        return (listener, client)
    }

    @Test("Connecting says hello, so the connection is connected before anyone uses it")
    func connectingSaysHello() async throws {
        let (listener, client) = try await Self.makePair()
        defer { client.stop(); listener.stop() }

        #expect(client.state == .connected)
        #expect(listener.state == .connected)
    }

    @Test("After the service goes away the client reports the gap and comes back on its own")
    func reattachesAfterInterruption() async throws {
        let (listener, client) = try await Self.makePair()
        defer { client.stop(); listener.stop() }
        let recorder = StateRecorder()
        let subscription = client.statePublisher.sink { state in recorder.record(state) }
        defer { subscription.cancel() }

        client.simulateInterruptionForTesting()

        #expect(!client.state.isConnected)
        #expect(client.isUsable)
        let reattached = await pollUntil { client.state.isConnected && !client.isReattaching }
        #expect(reattached, "the client did not reattach")
        #expect(recorder.states.contains { !$0.isConnected })
        try await client.sendMessage(name: "ping")
    }

    @Test("Three failed hellos give up, and the next message tries once more")
    func exhaustedScheduleFallsBackToOnDemand() async throws {
        let (listener, client) = try await Self.makePair()
        defer { client.stop(); listener.stop() }

        client.setHelloFailureForTesting(ServiceStillDown())
        client.simulateInterruptionForTesting()

        let gaveUp = await pollUntil { !client.isReattaching }
        #expect(gaveUp)
        #expect(!client.state.isConnected)
        #expect(client.isUsable)

        // Still down: the on-demand hello fails, and so does the message.
        await #expect(throws: ServiceStillDown.self) {
            try await client.sendMessage(name: "ping")
        }
        #expect(!client.state.isConnected)

        // Back: the on-demand hello lands, then the message.
        client.setHelloFailureForTesting(nil)
        try await client.sendMessage(name: "ping")
        #expect(client.state.isConnected)
    }

    @Test("A stopped client does not reattach")
    func stopCancelsReattach() async throws {
        let (listener, client) = try await Self.makePair()
        defer { listener.stop() }

        client.stop()
        client.simulateInterruptionForTesting()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!client.isReattaching)
        #expect(client.state == .disconnected(error: nil))
    }
}

private actor PushRecorder {
    private(set) var greetings: [RuntimeXPCServiceConnectionTests.Greeting] = []

    func record(_ greeting: RuntimeXPCServiceConnectionTests.Greeting) {
        greetings.append(greeting)
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RuntimeConnectionState] = []

    var states: [RuntimeConnectionState] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ state: RuntimeConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(state)
    }
}

private func pollUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

#endif

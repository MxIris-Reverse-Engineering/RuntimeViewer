#if os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// A client reaching a dedicated instance of an embedded service, with both
/// ends in this process: an anonymous listener stands in for the instance,
/// and an endpoint carrying a launch payload makes the client behave as one
/// connected through `.dedicatedInstance` — its hellos carry the payload, and
/// it reattaches behind a new connection. Starting real instances needs the
/// app's embedded `_MultipleInstances` service; what is checked here is
/// everything around it.
@Suite("RuntimeXPCServiceClientConnection dedicated instance")
struct RuntimeXPCServiceDedicatedInstanceTests {
    private struct UnreadableFile: LocalizedError {
        var errorDescription: String? { "the file named in the payload cannot be read" }
    }

    private static let payload = Data("Foo.framework".utf8)

    private static func shortenReattach(_ client: RuntimeXPCServiceClientConnection) {
        client.setReattachDelays(inNanoseconds: [20_000_000, 20_000_000, 20_000_000])
    }

    @Test("The first hello hands its payload to the launch handler, once, before it is answered; a handler installed there answers at once")
    func launchPayloadArrivesWithTheFirstHello() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let launches = Recorder<Data>()
        listener.setLaunchHandler { [weak listener] payload in
            await launches.record(payload)
            // After the listener activated and the client attached.
            listener?.setMessageHandler(name: "echo") { (text: String) -> String in "echo:" + text }
        }
        listener.activate()

        let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint.carryingLaunchPayload(Self.payload)))
        defer { client.stop(); listener.stop() }

        #expect(await launches.values == [Self.payload])
        #expect(client.state.isConnected)
        let reply: String = try await client.sendMessage(name: "echo", request: "x")
        #expect(reply == "echo:x")
    }

    @Test("A launch that fails fails the client's connect, carrying the reason")
    func failedLaunchFailsTheConnect() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.setLaunchHandler { _ in throw UnreadableFile() }
        listener.activate()
        defer { listener.stop() }

        await #expect(throws: RuntimeXPCServiceConnectionError.remoteFailure(UnreadableFile().localizedDescription)) {
            _ = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint.carryingLaunchPayload(Self.payload)))
        }
    }

    @Test("After its instance went away the client starts another behind a new connection, where the handlers it installed answer")
    func instanceExitReplacesTheConnection() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let launches = Recorder<Data>()
        listener.setLaunchHandler { payload in await launches.record(payload) }
        listener.activate()
        let pushes = Recorder<String>()
        let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint.carryingLaunchPayload(Self.payload))) { client in
            client.setMessageHandler(name: "push") { (text: String) in await pushes.record(text) }
        }
        defer { client.stop(); listener.stop() }
        Self.shortenReattach(client)

        client.simulateInstanceExitForTesting()

        #expect(!client.state.isConnected)
        #expect(client.isUsable)
        let reattached = await pollUntil { client.state.isConnected && !client.isReattaching }
        #expect(reattached, "the client did not reattach")
        #expect(client.connectionReplacementCount == 1)
        // The new connection's hello made it the listener's peer, and the
        // handler installed before the exit answers on it.
        try await listener.sendMessage(name: "push", request: "after")
        #expect(await pushes.values == ["after"])
        // One listener stands in for both instances; a real new instance
        // would have run its own launch.
        #expect(await launches.values == [Self.payload])
    }

    @Test("Every hello an instance declines makes the next try start a fresh instance")
    func declinedHelloStartsAFreshInstance() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.setLaunchHandler { _ in }
        listener.setMessageHandler(name: "ping") {}
        listener.activate()
        let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint.carryingLaunchPayload(Self.payload)))
        defer { client.stop(); listener.stop() }
        Self.shortenReattach(client)

        client.setHelloFailureForTesting(RuntimeXPCServiceConnectionError.remoteFailure(UnreadableFile().localizedDescription))
        client.simulateInstanceExitForTesting()

        let gaveUp = await pollUntil { !client.isReattaching }
        #expect(gaveUp)
        #expect(!client.state.isConnected)
        #expect(client.connectionReplacementCount == 3, "each of the three tries should have started its own instance")

        client.setHelloFailureForTesting(nil)
        try await client.sendMessage(name: "ping")
        #expect(client.state.isConnected)
        #expect(client.connectionReplacementCount == 4)
    }

    @Test("A client of an embedded service keeps its connection when the service comes back")
    func embeddedServiceClientKeepsItsConnection() async throws {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        listener.setMessageHandler(name: "ping") {}
        listener.activate()
        let client = try await RuntimeXPCServiceClientConnection(target: .anonymousListener(endpoint))
        defer { client.stop(); listener.stop() }
        Self.shortenReattach(client)

        client.simulateInterruptionForTesting()

        let reattached = await pollUntil { client.state.isConnected && !client.isReattaching }
        #expect(reattached)
        #expect(client.connectionReplacementCount == 0)
        try await client.sendMessage(name: "ping")
    }
}

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
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

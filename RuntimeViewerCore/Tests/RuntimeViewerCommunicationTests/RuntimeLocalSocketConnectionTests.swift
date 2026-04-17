import Testing
import Foundation
@testable import RuntimeViewerCommunication

// MARK: - RuntimeLocalSocketConnectionTests

@Suite("RuntimeLocalSocketConnection Tests", .serialized)
struct RuntimeLocalSocketConnectionTests {

    @Test("Server starts and listens on auto-assigned port")
    func testServerStartsOnAutoPort() async throws {
        let identifier = "test-server-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        // Start server in background task
        let serverTask = Task {
            try await server.start()
        }

        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000)

        // Port should be assigned
        #expect(server.port > 0)

        // Clean up
        serverTask.cancel()
        server.stop()
    }

    @Test("Port discovery uses deterministic hash")
    func testPortDiscovery() async throws {
        let identifier = "test-discovery-\(UUID().uuidString)"

        // Compute port using deterministic hash
        let port1 = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
        let port2 = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)

        // Port should be the same for the same identifier
        #expect(port1 == port2)

        // Port should be in the valid dynamic port range (49152-65535)
        #expect(port1 >= 49152)
        #expect(port1 <= 65535)
    }

    @Test("Client connects to server via port discovery")
    func testClientServerConnection() async throws {
        let identifier = "test-connection-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        // Start server
        let serverTask = Task {
            try await server.start()
        }

        // Give server time to start and write port file
        try await Task.sleep(nanoseconds: 200_000_000)

        // Setup handler
        server.setMessageHandler(requestType: EchoRequest.self) { request in
            return EchoResponse(message: "Server received: \(request.message)")
        }

        // Connect client using port discovery
        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        // Send request
        let response = try await client.sendMessage(request: EchoRequest(message: "Hello"))

        #expect(response.message == "Server received: Hello")

        // Clean up
        serverTask.cancel()
        server.stop()
    }

    @Test("Client connects to server via direct port")
    func testDirectPortConnection() async throws {
        let identifier = "test-direct-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        // Start server
        let serverTask = Task {
            try await server.start()
        }

        // Give server time to start
        try await Task.sleep(nanoseconds: 200_000_000)

        let port = server.port
        #expect(port > 0)

        server.setMessageHandler(requestType: AddRequest.self) { request in
            return AddResponse(result: request.a + request.b)
        }

        // Connect client using direct port
        let client = try RuntimeLocalSocketClientConnection(port: port)

        // Send request
        let response = try await client.sendMessage(request: AddRequest(a: 100, b: 200))

        #expect(response.result == 300)

        // Clean up
        serverTask.cancel()
        server.stop()
    }

    @Test("Multiple sequential requests over socket")
    func testMultipleRequests() async throws {
        let identifier = "test-multi-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(requestType: AddRequest.self) { request in
            return AddResponse(result: request.a * request.b)
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        // Send multiple requests
        for i in 1...5 {
            let response = try await client.sendMessage(request: AddRequest(a: i, b: i))
            #expect(response.result == i * i)
        }

        serverTask.cancel()
        server.stop()
    }

    @Test("Large message over socket")
    func testLargeMessageOverSocket() async throws {
        let identifier = "test-large-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(requestType: EchoRequest.self) { request in
            return EchoResponse(message: request.message)
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        // Send large message (500KB)
        let largeString = String(repeating: "X", count: 500_000)
        let response = try await client.sendMessage(request: EchoRequest(message: largeString))

        #expect(response.message.count == 500_000)
        #expect(response.message == largeString)

        serverTask.cancel()
        server.stop()
    }

    @Test("Server on specific port")
    func testServerOnSpecificPort() async throws {
        let specificPort: UInt16 = 19876

        let server = RuntimeLocalSocketServerConnection(port: specificPort)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(server.port == specificPort)

        server.setMessageHandler(name: "ping") { (_: String) -> String in
            return "pong"
        }

        let client = try RuntimeLocalSocketClientConnection(port: specificPort)

        let response: String = try await client.sendMessage(name: "ping", request: "")
        #expect(response == "pong")

        serverTask.cancel()
        server.stop()
    }
}

// MARK: - RuntimeLocalSocketPortDiscoveryTests

@Suite("RuntimeLocalSocketPortDiscovery Tests", .serialized)
struct RuntimeLocalSocketPortDiscoveryTests {

    @Test("Deterministic port computation")
    func testDeterministicPortComputation() {
        // Same identifier should always produce the same port
        let identifier = "com.example.test.identifier"
        let port1 = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
        let port2 = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)

        #expect(port1 == port2)
    }

    @Test("Different identifiers produce different ports")
    func testDifferentIdentifiersDifferentPorts() {
        let identifiers = [
            "com.example.app1",
            "com.example.app2",
            "com.example.app3",
            "test-server-123",
            "test-server-456"
        ]

        var ports = Set<UInt16>()
        for identifier in identifiers {
            let port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
            ports.insert(port)
        }

        // All ports should be different (with high probability for different identifiers)
        #expect(ports.count == identifiers.count)
    }

    @Test("Port is in valid dynamic range")
    func testPortInValidRange() {
        let testIdentifiers = [
            "short",
            "a-very-long-identifier-that-might-overflow",
            "com.example.app.with.many.components",
            "special!@#$%^&*()characters",
            ""
        ]

        for identifier in testIdentifiers {
            let port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
            #expect(port >= 49152, "Port \(port) for '\(identifier)' is below minimum 49152")
            #expect(port <= 65535, "Port \(port) for '\(identifier)' is above maximum 65535")
        }
    }
}

// MARK: - RuntimeLocalSocket State & Lifecycle Tests

@Suite("RuntimeLocalSocket State & Lifecycle Tests", .serialized)
struct RuntimeLocalSocketStateTests {

    @Test("Server reports connected state after client connects")
    func testServerConnectedState() async throws {
        let identifier = "test-state-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(requestType: EchoRequest.self) { request in
            return EchoResponse(message: request.message)
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        // Send a message to ensure the connection is established
        let response = try await client.sendMessage(request: EchoRequest(message: "ping"))
        #expect(response.message == "ping")

        #expect(server.state == .connected)

        serverTask.cancel()
        server.stop()
    }

    @Test("Server stop is idempotent")
    func testServerStopIdempotent() async throws {
        let identifier = "test-idempotent-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        serverTask.cancel()

        // Calling stop multiple times should not crash
        server.stop()
        server.stop()
        server.stop()
    }

    @Test("Server transitions to disconnected after stop")
    func testServerDisconnectedAfterStop() async throws {
        let identifier = "test-disconnected-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        serverTask.cancel()
        server.stop()

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(server.state.isDisconnected)
    }

    /// Regression test for the recv() hang bug: when the server closes the connection,
    /// the injected client's blocking recv() must be unblocked so the state leaves
    /// `.connected`. Without `shutdown()` before `close()` the recv() can stay blocked
    /// indefinitely on BSD/macOS and the client never notices the server is gone.
    @Test("Server stop unblocks idle client recv loop")
    func testServerStopUnblocksIdleClient() async throws {
        let identifier = "test-stop-unblock-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        // Let the client's receiver thread block on recv() (no data flowing).
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(client.state == .connected)

        // Closing the server's accepted fd must unblock the client's recv() so its
        // state transitions away from `.connected`. The client may then flip to
        // `.connecting` via auto-reconnect — either is fine; what's NOT fine is
        // staying at `.connected` (meaning recv() is still blocked).
        server.stop()

        let deadline = Date().addingTimeInterval(1.0)
        while client.state == .connected, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(client.state != .connected, "client stayed .connected within 1s — recv() likely still blocked")

        serverTask.cancel()
        client.stop()
    }
}

// MARK: - RuntimeLocalSocket Fire-and-Forget Tests

@Suite("RuntimeLocalSocket Fire-and-Forget Tests", .serialized)
struct RuntimeLocalSocketFireAndForgetTests {

    @Test("Fire-and-forget message with no response")
    func testFireAndForget() async throws {
        let identifier = "test-fandf-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        var receivedMessage: String?

        server.setMessageHandler(name: "notify") { (message: String) in
            receivedMessage = message
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        try await client.sendMessage(name: "notify", request: "Hello Socket")

        // Give handler time to execute
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(receivedMessage == "Hello Socket")

        serverTask.cancel()
        server.stop()
    }

    @Test("Multiple handlers by different names")
    func testMultipleNamedHandlers() async throws {
        let identifier = "test-multihandler-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(name: "double") { (value: Int) -> Int in
            return value * 2
        }

        server.setMessageHandler(name: "negate") { (value: Int) -> Int in
            return -value
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        let doubleResult: Int = try await client.sendMessage(name: "double", request: 21)
        #expect(doubleResult == 42)

        let negateResult: Int = try await client.sendMessage(name: "negate", request: 5)
        #expect(negateResult == -5)

        serverTask.cancel()
        server.stop()
    }
}

// MARK: - RuntimeLocalSocket Rapid Request Tests

@Suite("RuntimeLocalSocket Rapid Request Tests", .serialized)
struct RuntimeLocalSocketRapidTests {

    @Test("Rapid sequential requests over socket")
    func testRapidRequests() async throws {
        let identifier = "test-rapid-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(requestType: AddRequest.self) { request in
            return AddResponse(result: request.a + request.b)
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        for requestIndex in 0 ..< 20 {
            let response = try await client.sendMessage(request: AddRequest(a: requestIndex, b: 100))
            #expect(response.result == requestIndex + 100)
        }

        serverTask.cancel()
        server.stop()
    }
}

// MARK: - RuntimeLocalSocket No-Response Handler Regression Tests

/// Regression tests for the `NullPayload` / `RuntimeMessageNull` sentinel mismatch
/// that caused the receive dispatch loop to echo bogus responses back to the
/// peer after handling any fire-and-forget message.
///
/// Before the fix, `RuntimeConnectionBase` (and `RuntimeLocalSocketServerConnection`
/// overrides) wrapped no-response handlers so they returned `NullPayload.null`,
/// while `observeIncomingMessages` used `RuntimeMessageNull.self` as its "don't
/// reply" sentinel. The two types were never equal, so every fire-and-forget
/// message triggered a `send(requestData:)` reply. In the
/// `runtimeObjectsInImage` → `objectsLoadingProgress` push scenario this
/// reply contended for the same `sendSemaphore` the in-flight `sendRequest`
/// was holding, permanently wedging the dispatch loop and the originating
/// request.
@Suite("RuntimeLocalSocket No-Response Handler Regression Tests", .serialized)
struct RuntimeLocalSocketNoResponseHandlerTests {

    /// Simple counter helper usable across tasks without pulling extra deps.
    private actor Counter {
        private(set) var value: Int = 0
        func increment() { value += 1 }
    }

    /// Core regression for the deadlock: the server pushes many fire-and-forget
    /// messages to the client while the client is still awaiting a response
    /// to its own request. With the sentinel bug, the bogus reply issued by
    /// the client's dispatch loop blocks on the semaphore held by the
    /// originating `sendRequest` and nothing makes progress.
    @Test("Fire-and-forget push during in-flight client request does not deadlock")
    func testNoDeadlockOnPushDuringInFlightRequest() async throws {
        let identifier = "test-push-inflight-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let pushCount = 50

        // Server "compute" handler pushes N fire-and-forget "progress" messages
        // back to the client *before* returning the real response, mirroring
        // `_serverObjectsWithProgress`.
        server.setMessageHandler(name: "compute") { [weak server] (_: String) -> String in
            guard let server else { return "cancelled" }
            for progressIndex in 0 ..< pushCount {
                try await server.sendMessage(name: "progress", request: progressIndex)
            }
            return "done"
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        let receivedProgress = Counter()
        client.setMessageHandler(name: "progress") { (_: Int) in
            await receivedProgress.increment()
        }

        // If the sentinel mismatch comes back, this await never returns.
        let response: String = try await client.sendMessage(name: "compute", request: "")
        #expect(response == "done")

        // Give any trailing push handlers a beat to finish; they are dispatched
        // sequentially through the same observe loop that also delivers
        // responses, so by the time the response returns they should all be in.
        try await Task.sleep(nanoseconds: 100_000_000)
        let delivered = await receivedProgress.value
        #expect(delivered == pushCount, "expected \(pushCount) progress pushes, got \(delivered)")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    /// A no-response handler on the receiving side must NOT bounce a response
    /// back. If it did, the sender would see an unknown request identifier
    /// for which there is no pending request and no registered handler. We
    /// detect that by installing a dummy response handler under the same
    /// identifier on the sender side and asserting it never fires.
    @Test("No-response handler on receiver does not echo a response back")
    func testNoResponseHandlerDoesNotEchoResponseBack() async throws {
        let identifier = "test-noecho-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // If the client erroneously echoes a response for "notify", the
        // message would arrive back at the server, get decoded as a
        // `RuntimeRequestData(identifier: "notify", ...)`, find no pending
        // request, then land in this server-side handler. If the fix is in
        // place, this handler must never run.
        let echoedBackCount = Counter()
        server.setMessageHandler(name: "notify") { (_: String) in
            await echoedBackCount.increment()
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)

        let receivedOnClient = Counter()
        client.setMessageHandler(name: "notify") { (_: String) in
            await receivedOnClient.increment()
        }

        // Wait for the server to finish accepting and wire its
        // `underlyingConnection` — the client's `connect()` can return before
        // the server-side accept loop finishes setting that up.
        let readyDeadline = Date().addingTimeInterval(2.0)
        while server.state != .connected, Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.state == .connected)

        // Push several fire-and-forget notifications from server → client.
        for notificationIndex in 0 ..< 10 {
            try await server.sendMessage(name: "notify", request: "msg-\(notificationIndex)")
        }

        // Allow pushes to propagate and (buggy) echoes to come back.
        try await Task.sleep(nanoseconds: 300_000_000)

        let delivered = await receivedOnClient.value
        #expect(delivered == 10, "client should receive all 10 notifications")

        let echoed = await echoedBackCount.value
        #expect(echoed == 0, "server must not receive any echoed-back response (got \(echoed))")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    /// Bidirectional push pressure: both ends continuously send fire-and-forget
    /// messages while the client runs a real request/response through the same
    /// dispatch loops. The assertion is that the real request completes — with
    /// the sentinel bug, it never would because the incoming pushes wedge the
    /// receive side waiting on `sendSemaphore`.
    @Test("Real request/response survives concurrent bidirectional push storm")
    func testRealRequestSurvivesBidirectionalPushStorm() async throws {
        let identifier = "test-bidir-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(requestType: AddRequest.self) { request in
            return AddResponse(result: request.a + request.b)
        }
        server.setMessageHandler(name: "client-progress") { (_: Int) in }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        client.setMessageHandler(name: "server-progress") { (_: Int) in }

        // Kick off pushes from both sides in the background.
        let serverPushTask = Task { [weak server] in
            guard let server else { return }
            for progressIndex in 0 ..< 20 {
                try? await server.sendMessage(name: "server-progress", request: progressIndex)
            }
        }
        let clientPushTask = Task { [weak client] in
            guard let client else { return }
            for progressIndex in 0 ..< 20 {
                try? await client.sendMessage(name: "client-progress", request: progressIndex)
            }
        }

        // Real request under push pressure — with the bug, this hangs forever.
        let response = try await client.sendMessage(request: AddRequest(a: 7, b: 35))
        #expect(response.result == 42)

        _ = await serverPushTask.value
        _ = await clientPushTask.value

        // A second request after the storm proves both dispatch loops recovered.
        let response2 = try await client.sendMessage(request: AddRequest(a: 100, b: 200))
        #expect(response2.result == 300)

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}

// MARK: - RuntimeLocalSocketError Tests

@Suite("RuntimeLocalSocketError Tests", .serialized)
struct RuntimeLocalSocketErrorTests {

    @Test("Error when connecting to non-existent server")
    func testConnectionRefused() throws {
        // Try to connect to a port that's not listening
        #expect(throws: RuntimeLocalSocketError.self) {
            _ = try RuntimeLocalSocketClientConnection(port: 59999)
        }
    }

    @Test("Error description is informative")
    func testErrorDescriptions() {
        let errors: [RuntimeLocalSocketError] = [
            .notConnected,
            .receiveFailed,
            .socketCreationFailed(errno: EMFILE),
            .bindFailed(errno: EADDRINUSE, port: 8080),
            .listenFailed(errno: EACCES),
            .acceptFailed(errno: EINTR),
            .connectFailed(errno: ECONNREFUSED, port: 9999),
            .sendFailed(errno: EPIPE),
        ]

        for error in errors {
            let description = error.description
            #expect(!description.isEmpty)
            #expect(description.contains("RuntimeLocalSocketError"))
        }
    }

    @Test("Error description contains errno details")
    func testErrorDescriptionDetails() {
        let error = RuntimeLocalSocketError.connectFailed(errno: ECONNREFUSED, port: 9999)
        let description = error.description
        #expect(description.contains("9999"))
        #expect(description.contains("connect"))
    }

    @Test("portFileNotFound and invalidPortFile error descriptions")
    func testPortFileErrors() {
        let portFileNotFound = RuntimeLocalSocketError.portFileNotFound(path: "/tmp/test.port", timeout: 5.0)
        #expect(!portFileNotFound.description.isEmpty)
        #expect(portFileNotFound.description.contains("/tmp/test.port"))

        let invalidPortFile = RuntimeLocalSocketError.invalidPortFile(path: "/tmp/test.port", content: "abc")
        #expect(!invalidPortFile.description.isEmpty)
        #expect(invalidPortFile.description.contains("abc"))
    }

    @Test("All error cases are LocalizedError")
    func testLocalizedError() {
        let errors: [any Error] = [
            RuntimeLocalSocketError.notConnected,
            RuntimeLocalSocketError.receiveFailed,
            RuntimeLocalSocketError.socketCreationFailed(errno: EMFILE),
        ]

        for error in errors {
            #expect(error.localizedDescription.isEmpty == false)
        }
    }
}

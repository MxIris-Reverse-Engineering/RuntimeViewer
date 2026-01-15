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
}

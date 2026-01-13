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

    @Test("Port discovery writes and reads port file")
    func testPortDiscovery() async throws {
        let identifier = "test-discovery-\(UUID().uuidString)"
        let testPort: UInt16 = 12345

        // Write port
        try RuntimeLocalSocketPortDiscovery.writePort(testPort, identifier: identifier)

        // Read port
        let readPort = try await RuntimeLocalSocketPortDiscovery.readPort(identifier: identifier, timeout: 1)

        #expect(readPort == testPort)

        // Clean up
        RuntimeLocalSocketPortDiscovery.removePortFile(identifier: identifier)

        // Verify file is removed
        let portFilePath = RuntimeLocalSocketPortDiscovery.portFilePath(for: identifier)
        #expect(!FileManager.default.fileExists(atPath: portFilePath.path))
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

    @Test("Port file path is sanitized")
    func testPortFilePathSanitization() {
        let identifier = "com.example/test/identifier"
        let path = RuntimeLocalSocketPortDiscovery.portFilePath(for: identifier)

        // Should not contain slashes in filename
        #expect(!path.lastPathComponent.contains("/"))
        #expect(path.lastPathComponent.contains("com.example_test_identifier"))
    }

    @Test("Port file timeout when file doesn't exist")
    func testPortFileTimeout() async throws {
        let identifier = "nonexistent-\(UUID().uuidString)"

        await #expect(throws: RuntimeLocalSocketError.self) {
            _ = try await RuntimeLocalSocketPortDiscovery.readPort(identifier: identifier, timeout: 0.5)
        }
    }

    @Test("Multiple write/read cycles")
    func testMultipleWriteReadCycles() async throws {
        let identifier = "test-cycles-\(UUID().uuidString)"

        for port: UInt16 in [1000, 2000, 3000, 4000, 5000] {
            try RuntimeLocalSocketPortDiscovery.writePort(port, identifier: identifier)
            let readPort = try await RuntimeLocalSocketPortDiscovery.readPort(identifier: identifier, timeout: 1)
            #expect(readPort == port)
        }

        RuntimeLocalSocketPortDiscovery.removePortFile(identifier: identifier)
    }
}

// MARK: - RuntimeLocalSocketError Tests

@Suite("RuntimeLocalSocketError Tests", .serialized)
struct RuntimeLocalSocketErrorTests {

    @Test("Error when base connection not established")
    func testNotConnectedError() async throws {
        let baseConnection = RuntimeLocalSocketBaseConnection()

        await #expect(throws: RuntimeLocalSocketError.self) {
            try await baseConnection.sendMessage(name: "test")
        }
    }

    @Test("Error when connecting to non-existent server")
    func testConnectionRefused() throws {
        // Try to connect to a port that's not listening
        #expect(throws: RuntimeLocalSocketError.self) {
            _ = try RuntimeLocalSocketClientConnection(port: 59999)
        }
    }
}

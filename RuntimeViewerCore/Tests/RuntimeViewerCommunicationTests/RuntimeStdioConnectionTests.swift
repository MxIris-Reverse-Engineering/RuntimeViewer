import Testing
import Foundation
@testable import RuntimeViewerCommunication

// MARK: - Test Request/Response Types

struct EchoRequest: RuntimeRequest {
    static let identifier = "EchoRequest"
    typealias Response = EchoResponse
    let message: String
}

struct EchoResponse: RuntimeResponse {
    let message: String
}

struct AddRequest: RuntimeRequest {
    static let identifier = "AddRequest"
    typealias Response = AddResponse
    let a: Int
    let b: Int
}

struct AddResponse: RuntimeResponse {
    let result: Int
}

// MARK: - RuntimeStdioConnectionTests

@Suite("RuntimeStdioConnection Tests", .serialized)
struct RuntimeStdioConnectionTests {

    @Test("Basic message roundtrip through pipes")
    func testBasicMessageRoundtrip() async throws {
        // Create pipes for bidirectional communication
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        // Server reads from clientToServer, writes to serverToClient
        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        // Client reads from serverToClient, writes to clientToServer
        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        // Setup echo handler on server
        server.setMessageHandler(requestType: EchoRequest.self) { request in
            return EchoResponse(message: "Echo: \(request.message)")
        }

        // Send request from client
        let response = try await client.sendMessage(request: EchoRequest(message: "Hello"))

        #expect(response.message == "Echo: Hello")
    }

    @Test("Multiple sequential requests")
    func testMultipleSequentialRequests() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        server.setMessageHandler(requestType: AddRequest.self) { request in
            return AddResponse(result: request.a + request.b)
        }

        // Send multiple requests sequentially
        let response1 = try await client.sendMessage(request: AddRequest(a: 1, b: 2))
        #expect(response1.result == 3)

        let response2 = try await client.sendMessage(request: AddRequest(a: 10, b: 20))
        #expect(response2.result == 30)

        let response3 = try await client.sendMessage(request: AddRequest(a: -5, b: 5))
        #expect(response3.result == 0)
    }

    @Test("Handler with name-based registration")
    func testNameBasedHandler() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        // Register handler by name
        server.setMessageHandler(name: "uppercase") { (input: String) -> String in
            return input.uppercased()
        }

        let result: String = try await client.sendMessage(name: "uppercase", request: "hello world")
        #expect(result == "HELLO WORLD")
    }

    @Test("Large message handling")
    func testLargeMessage() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        server.setMessageHandler(requestType: EchoRequest.self) { request in
            return EchoResponse(message: request.message)
        }

        // Create a large message (100KB)
        let largeString = String(repeating: "A", count: 100_000)
        let response = try await client.sendMessage(request: EchoRequest(message: largeString))

        #expect(response.message == largeString)
        #expect(response.message.count == 100_000)
    }

    @Test("Bidirectional communication - both sides can initiate")
    func testBidirectionalCommunication() async throws {
        let pipe1 = Pipe()
        let pipe2 = Pipe()

        // Connection A
        let connectionA = try RuntimeStdioClientConnection(
            inputHandle: pipe2.fileHandleForReading,
            outputHandle: pipe1.fileHandleForWriting
        )

        // Connection B
        let connectionB = try RuntimeStdioServerConnection(
            inputHandle: pipe1.fileHandleForReading,
            outputHandle: pipe2.fileHandleForWriting
        )

        defer {
            connectionA.stop()
            connectionB.stop()
            try? pipe1.fileHandleForWriting.close()
            try? pipe2.fileHandleForWriting.close()
        }

        // Both sides register handlers
        connectionA.setMessageHandler(name: "fromB") { (msg: String) -> String in
            return "A received: \(msg)"
        }

        connectionB.setMessageHandler(name: "fromA") { (msg: String) -> String in
            return "B received: \(msg)"
        }

        // A sends to B
        let responseFromB: String = try await connectionA.sendMessage(name: "fromA", request: "Hello from A")
        #expect(responseFromB == "B received: Hello from A")

        // B sends to A
        let responseFromA: String = try await connectionB.sendMessage(name: "fromB", request: "Hello from B")
        #expect(responseFromA == "A received: Hello from B")
    }
}

// MARK: - RuntimeStdio State & Lifecycle Tests

@Suite("RuntimeStdio State & Lifecycle Tests", .serialized)
struct RuntimeStdioStateTests {

    @Test("Connection starts in connected state")
    func testInitialState() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        #expect(server.state == .connected)

        server.stop()
    }

    @Test("Stop transitions to disconnected state")
    func testDisconnectedStateAfterStop() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        #expect(server.state == .connected)

        server.stop()

        // Allow read queue to settle
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(server.state.isDisconnected)
    }

    @Test("Stop is idempotent — calling multiple times does not crash")
    func testStopIdempotent() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        server.stop()
        server.stop()
        server.stop()

        #expect(server.state.isDisconnected)
    }

    @Test("Closing write end triggers peer-closed detection")
    func testPeerClosedDetection() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        defer { server.stop() }

        // Close the write end to signal EOF to the server's read loop
        try clientToServer.fileHandleForWriting.close()

        // Give the read loop time to detect EOF
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(server.state.isDisconnected)
    }

    @Test("State publisher emits connected then disconnected")
    func testStatePublisher() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        var observedStates: [RuntimeConnectionState] = []

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let cancellable = server.statePublisher
            .sink { state in
                observedStates.append(state)
            }

        // Allow subscription to settle
        try await Task.sleep(nanoseconds: 50_000_000)

        server.stop()

        try await Task.sleep(nanoseconds: 50_000_000)

        // Should have received connected and disconnected
        #expect(observedStates.contains(.connected))
        let hasDisconnected = observedStates.contains { $0.isDisconnected }
        #expect(hasDisconnected)

        _ = cancellable
    }
}

// MARK: - RuntimeStdio Fire-and-Forget Tests

@Suite("RuntimeStdio Fire-and-Forget Tests", .serialized)
struct RuntimeStdioFireAndForgetTests {

    @Test("Fire-and-forget message with no response")
    func testFireAndForgetMessage() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
        }

        var receivedMessage: String?

        server.setMessageHandler(name: "notify") { (message: String) in
            receivedMessage = message
        }

        // Send fire-and-forget (no response expected)
        try await client.sendMessage(name: "notify", request: "Hello")

        // Give handler time to execute
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(receivedMessage == "Hello")
    }

    @Test("Multiple handlers registered by different names")
    func testMultipleHandlers() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
        }

        server.setMessageHandler(name: "upper") { (input: String) -> String in
            return input.uppercased()
        }

        server.setMessageHandler(name: "lower") { (input: String) -> String in
            return input.lowercased()
        }

        server.setMessageHandler(name: "reverse") { (input: String) -> String in
            return String(input.reversed())
        }

        let upperResult: String = try await client.sendMessage(name: "upper", request: "hello")
        #expect(upperResult == "HELLO")

        let lowerResult: String = try await client.sendMessage(name: "lower", request: "WORLD")
        #expect(lowerResult == "world")

        let reverseResult: String = try await client.sendMessage(name: "reverse", request: "abc")
        #expect(reverseResult == "cba")
    }
}

// MARK: - RuntimeStdio Concurrent Request Tests

@Suite("RuntimeStdio Concurrent Request Tests", .serialized)
struct RuntimeStdioConcurrentTests {

    @Test("Multiple rapid sequential requests")
    func testRapidSequentialRequests() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )

        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
        }

        server.setMessageHandler(requestType: AddRequest.self) { request in
            return AddResponse(result: request.a + request.b)
        }

        // Send 20 requests rapidly
        for requestIndex in 0 ..< 20 {
            let response = try await client.sendMessage(request: AddRequest(a: requestIndex, b: requestIndex))
            #expect(response.result == requestIndex * 2)
        }
    }
}

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

// MARK: - RuntimeStdioError Tests

@Suite("RuntimeStdioError Tests", .serialized)
struct RuntimeStdioErrorTests {

    @Test("Error when connection not established")
    func testNotConnectedError() async throws {
        let baseConnection = RuntimeStdioBaseConnection()

        await #expect(throws: RuntimeStdioError.self) {
            try await baseConnection.sendMessage(name: "test")
        }
    }
}

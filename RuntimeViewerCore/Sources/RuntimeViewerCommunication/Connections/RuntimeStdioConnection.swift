import Foundation
import Logging
import Semaphore
import Asynchrone

// MARK: - RuntimeStdioConnection

/// A bidirectional communication channel over standard I/O (stdin/stdout).
///
/// `RuntimeStdioConnection` enables inter-process communication using file handles,
/// typically stdin and stdout. This is useful for CLI tools, language servers (LSP),
/// or any scenario where processes communicate via pipes.
///
/// ## Message Protocol
///
/// Messages are JSON-encoded and terminated with `\nOK` marker:
/// ```
/// {"identifier":"MyRequest","data":"..."}\nOK
/// ```
///
/// ## Architecture
///
/// ```
/// ┌─────────────────┐                    ┌─────────────────┐
/// │  Parent Process │                    │  Child Process  │
/// │                 │                    │                 │
/// │  outputHandle ──┼──── stdin ────────>│  inputHandle    │
/// │                 │                    │                 │
/// │  inputHandle  <─┼──── stdout ────────│  outputHandle   │
/// └─────────────────┘                    └─────────────────┘
/// ```
///
/// ## Example: Parent Process (Client)
///
/// ```swift
/// // Launch child process
/// let process = Process()
/// process.executableURL = URL(fileURLWithPath: "/path/to/server")
///
/// let stdinPipe = Pipe()
/// let stdoutPipe = Pipe()
/// process.standardInput = stdinPipe
/// process.standardOutput = stdoutPipe
///
/// try process.run()
///
/// // Create client connection
/// // Client writes to child's stdin, reads from child's stdout
/// let client = try RuntimeStdioClientConnection(
///     inputHandle: stdoutPipe.fileHandleForReading,   // Read from child's stdout
///     outputHandle: stdinPipe.fileHandleForWriting    // Write to child's stdin
/// )
///
/// // Send request and receive response
/// let response: MyResponse = try await client.sendMessage(request: MyRequest())
/// ```
///
/// ## Example: Child Process (Server)
///
/// ```swift
/// // Server uses standard stdin/stdout
/// let server = try RuntimeStdioServerConnection(
///     inputHandle: .standardInput,
///     outputHandle: .standardOutput
/// )
///
/// // Register message handler
/// server.setMessageHandler(requestType: MyRequest.self) { request in
///     return MyResponse(result: "Processed: \(request.value)")
/// }
///
/// // Keep the process running
/// RunLoop.main.run()
/// ```
///
/// ## Defining Request/Response Types
///
/// ```swift
/// struct MyRequest: RuntimeRequest {
///     static let identifier = "MyRequest"
///     typealias Response = MyResponse
///
///     let value: String
/// }
///
/// struct MyResponse: RuntimeResponse {
///     let result: String
/// }
/// ```
///
final class RuntimeStdioConnection {
    private class MessageHandler {
        typealias RawHandler = (Data) async throws -> Data
        let closure: RawHandler
        let requestType: Codable.Type
        let responseType: Codable.Type

        init<Request: Codable, Response: Codable>(closure: @escaping (Request) async throws -> Response) {
            self.requestType = Request.self
            self.responseType = Response.self

            self.closure = { request in
                let request = try JSONDecoder().decode(Request.self, from: request)
                let response = try await closure(request)
                return try JSONEncoder().encode(response)
            }
        }
    }

    let id = UUID()

    var didStop: ((RuntimeStdioConnection) -> Void)?

    private static let logger = Logger(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeStdioConnection")

    private static let endMarkerData = "\nOK".data(using: .utf8)!

    private var logger: Logger { Self.logger }

    private let inputHandle: FileHandle

    private let outputHandle: FileHandle

    private var receivedDataStream: SharedAsyncSequence<AsyncThrowingStream<Data, Error>>?

    private var receivedDataContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    private var isStarted = false

    private var receivingData = Data()

    private let semaphore = AsyncSemaphore(value: 1)

    private var messageHandlers: [String: MessageHandler] = [:]

    private let readQueue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeStdioConnection.readQueue")

    init(inputHandle: FileHandle, outputHandle: FileHandle) {
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
    }

    func start() throws {
        guard !isStarted else { return }
        isStarted = true
        Self.logger.info("Stdio connection will start")
        setupStreams()
        setupReceiver()
        observeIncomingMessages()
        Self.logger.info("Stdio connection did start")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        Self.logger.info("Stdio connection will stop")
        receivedDataContinuation?.finish()
        didStop?(self)
        didStop = nil
        Self.logger.info("Stdio connection did stop")
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping ((Request) async throws -> Response)) {
        messageHandlers[name] = .init(closure: handler)
    }

    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping ((Request) async throws -> Request.Response)) {
        messageHandlers[Request.identifier] = .init(closure: handler)
    }

    func send(requestData: RuntimeRequestData) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }
        logger.info("RuntimeStdioConnection send identifier: \(requestData.identifier)")
        try await send(content: requestData)
    }

    func send<Response: Codable>(requestData: RuntimeRequestData) async throws -> Response {
        await semaphore.wait()
        defer { semaphore.signal() }
        logger.info("RuntimeStdioConnection send identifier: \(requestData.identifier)")
        try await send(content: requestData)
        let receiveData = try await receiveData()
        let responseData = try JSONDecoder().decode(RuntimeRequestData.self, from: receiveData)
        logger.info("RuntimeStdioConnection received identifier: \(responseData.identifier)")
        return try JSONDecoder().decode(Response.self, from: responseData.data)
    }

    func send<Request: RuntimeRequest>(request: Request) async throws {
        let requestData = try RuntimeRequestData(request: request)
        try await send(requestData: requestData)
    }

    func send<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        let requestData = try RuntimeRequestData(request: request)
        return try await send(requestData: requestData)
    }

    private func observeIncomingMessages() {
        Task {
            do {
                guard let receivedDataStream else { return }
                for try await data in receivedDataStream {
                    do {
                        let requestData = try JSONDecoder().decode(RuntimeRequestData.self, from: data)
                        guard let messageHandler = messageHandlers[requestData.identifier] else { continue }
                        logger.info("RuntimeStdioConnection received identifier: \(requestData.identifier)")
                        let responseData = try await messageHandler.closure(requestData.data)
                        if messageHandler.responseType != MessageNull.self {
                            try await send(requestData: RuntimeRequestData(identifier: requestData.identifier, data: responseData))
                        }
                    } catch {
                        logger.error("\(error)")
                        let requestError = RuntimeNetworkRequestError(message: "\(error)")
                        do {
                            let commandErrorData = try JSONEncoder().encode(requestError)
                            try await send(data: commandErrorData)
                        } catch {
                            logger.error("\(error)")
                        }
                    }
                }

            } catch {
                logger.error("\(error)")
            }
        }
    }

    private func setupStreams() {
        let (receivedDataStream, receivedDataContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.receivedDataStream = receivedDataStream.shared()
        self.receivedDataContinuation = receivedDataContinuation
    }

    private func setupReceiver() {
        readQueue.async { [weak self] in
            guard let self else { return }
            while self.isStarted {
                let data = self.inputHandle.availableData
                if data.isEmpty {
                    self.receivedDataContinuation?.finish()
                    DispatchQueue.main.async {
                        self.stop()
                    }
                    break
                } else {
                    self.receivingData.append(data)
                    self.processReceivedData()
                }
            }
        }
    }

    private func processReceivedData() {
        guard let endMarker = "\nOK".data(using: .utf8) else { return }

        while true {
            guard let endRange = receivingData.range(of: endMarker) else {
                break
            }

            let messageData = receivingData.subdata(in: 0 ..< endRange.lowerBound)
            receivedDataContinuation?.yield(messageData)

            if endRange.upperBound < receivingData.count {
                receivingData = receivingData.subdata(in: endRange.upperBound ..< receivingData.count)
            } else {
                receivingData = Data()
                break
            }
        }
    }

    private func send<Content: Codable>(content: Content) async throws {
        let data = try JSONEncoder().encode(content)
        try await send(data: data)
    }

    private func send(data: Data) async throws {
        let dataToSend = data + Self.endMarkerData
        if #available(macOS 10.15.4, iOS 13.4, *) {
            try outputHandle.write(contentsOf: dataToSend)
        } else {
            outputHandle.write(dataToSend)
        }
        Self.logger.info("RuntimeStdioConnection send data: \(data)")
    }

    private func receiveData() async throws -> Data {
        guard let receivedDataStream else {
            throw RuntimeStdioError.notConnected
        }

        for try await data in receivedDataStream {
            if let error = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data) {
                throw error
            } else {
                return data
            }
        }

        throw RuntimeStdioError.receiveFailed
    }
}

// MARK: - RuntimeStdioError

/// Errors that can occur during stdio communication.
enum RuntimeStdioError: Error {
    /// The connection is not established or has been closed.
    case notConnected
    /// Failed to receive data from the input stream.
    case receiveFailed
}

// MARK: - MessageNull

private struct MessageNull: Codable {
    static let null = MessageNull()
}

// MARK: - RuntimeStdioBaseConnection

/// Base class implementing `RuntimeConnection` protocol for stdio communication.
///
/// This class provides the foundation for both client and server connections,
/// implementing all required protocol methods.
class RuntimeStdioBaseConnection: RuntimeConnection {
    var connection: RuntimeStdioConnection?

    init() {}

    func sendMessage(name: String) async throws {
        guard let connection = connection else { throw RuntimeStdioError.notConnected }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: MessageNull.null))
    }

    func sendMessage(name: String, request: some Codable) async throws {
        guard let connection = connection else { throw RuntimeStdioError.notConnected }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func sendMessage<Response>(name: String) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else { throw RuntimeStdioError.notConnected }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: MessageNull.null))
    }

    func sendMessage<Request>(request: Request) async throws -> Request.Response where Request: RuntimeRequest {
        guard let connection = connection else { throw RuntimeStdioError.notConnected }
        return try await connection.send(request: request)
    }

    func sendMessage<Response>(name: String, request: some Codable) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else { throw RuntimeStdioError.notConnected }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func setMessageHandler(name: String, handler: @escaping () async throws -> Void) {
        connection?.setMessageHandler(name: name, handler: { (_: MessageNull) in
            try await handler()
            return MessageNull.null
        })
    }

    func setMessageHandler<Request>(name: String, handler: @escaping (Request) async throws -> Void) where Request: Decodable, Request: Encodable {
        connection?.setMessageHandler(name: name, handler: { (request: Request) in
            try await handler(request)
            return MessageNull.null
        })
    }

    func setMessageHandler<Response>(name: String, handler: @escaping () async throws -> Response) where Response: Decodable, Response: Encodable {
        connection?.setMessageHandler(name: name, handler: { (_: MessageNull) in
            return try await handler()
        })
    }

    func setMessageHandler<Request>(requestType: Request.Type, handler: @escaping (Request) async throws -> Request.Response) where Request: RuntimeRequest {
        connection?.setMessageHandler { (request: Request) in
            return try await handler(request)
        }
    }

    func setMessageHandler<Request, Response>(name: String, handler: @escaping (Request) async throws -> Response) where Request: Decodable, Request: Encodable, Response: Decodable, Response: Encodable {
        connection?.setMessageHandler(name: name, handler: { (request: Request) in
            return try await handler(request)
        })
    }
}

// MARK: - RuntimeStdioClientConnection

/// Client-side stdio connection for sending requests to a child process.
///
/// Use this when your process launches another process and wants to communicate with it.
///
/// ## Usage
///
/// ```swift
/// let process = Process()
/// process.executableURL = URL(fileURLWithPath: "/path/to/server")
///
/// let stdinPipe = Pipe()
/// let stdoutPipe = Pipe()
/// process.standardInput = stdinPipe
/// process.standardOutput = stdoutPipe
///
/// try process.run()
///
/// let client = try RuntimeStdioClientConnection(
///     inputHandle: stdoutPipe.fileHandleForReading,
///     outputHandle: stdinPipe.fileHandleForWriting
/// )
///
/// // Send typed request
/// let response = try await client.sendMessage(request: MyRequest(value: "hello"))
///
/// // Or send by name
/// let result: String = try await client.sendMessage(name: "echo", request: "hello")
/// ```
final class RuntimeStdioClientConnection: RuntimeStdioBaseConnection {
    /// Creates a client connection with the specified file handles.
    ///
    /// - Parameters:
    ///   - inputHandle: File handle to read responses from (typically the child's stdout).
    ///   - outputHandle: File handle to write requests to (typically the child's stdin).
    /// - Throws: `RuntimeStdioError` if connection cannot be started.
    init(inputHandle: FileHandle, outputHandle: FileHandle) throws {
        super.init()
        let connection = RuntimeStdioConnection(inputHandle: inputHandle, outputHandle: outputHandle)
        self.connection = connection
        try connection.start()
    }
}

// MARK: - RuntimeStdioServerConnection

/// Server-side stdio connection for handling requests from a parent process.
///
/// Use this when your process is launched by another process and should respond to its requests.
///
/// ## Usage
///
/// ```swift
/// let server = try RuntimeStdioServerConnection(
///     inputHandle: .standardInput,
///     outputHandle: .standardOutput
/// )
///
/// // Register handler for typed requests
/// server.setMessageHandler(requestType: MyRequest.self) { request in
///     return MyResponse(result: "Received: \(request.value)")
/// }
///
/// // Register handler by name
/// server.setMessageHandler(name: "echo") { (input: String) -> String in
///     return "Echo: \(input)"
/// }
///
/// // Keep process alive
/// RunLoop.main.run()
/// ```
final class RuntimeStdioServerConnection: RuntimeStdioBaseConnection {
    /// Creates a server connection with the specified file handles.
    ///
    /// - Parameters:
    ///   - inputHandle: File handle to read requests from (typically `.standardInput`).
    ///   - outputHandle: File handle to write responses to (typically `.standardOutput`).
    /// - Throws: `RuntimeStdioError` if connection cannot be started.
    init(inputHandle: FileHandle, outputHandle: FileHandle) throws {
        super.init()
        let connection = RuntimeStdioConnection(inputHandle: inputHandle, outputHandle: outputHandle)
        self.connection = connection
        try connection.start()
    }
}

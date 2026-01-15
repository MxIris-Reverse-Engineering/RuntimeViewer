import Foundation
import os.log

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
final class RuntimeStdioConnection: RuntimeUnderlyingConnection, @unchecked Sendable, Loggable {
    let id = UUID()

    var didStop: ((RuntimeStdioConnection) -> Void)?

    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let messageChannel = RuntimeMessageChannel()

    private var isStarted = false

    private let readQueue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeStdioConnection.readQueue")

    // MARK: - Initialization

    init(inputHandle: FileHandle, outputHandle: FileHandle) {
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }
        isStarted = true

        setupReceiver()
        observeIncomingMessages()

        Self.logger.info("Connection started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        messageChannel.finishReceiving()
        didStop?(self)
        didStop = nil

        Self.logger.info("Connection stopped")
    }

    // MARK: - Receiving

    private func setupReceiver() {
        readQueue.async { [weak self] in
            guard let self else { return }

            while self.isStarted {
                let data = self.inputHandle.availableData
                if data.isEmpty {
                    self.logger.info("Input stream closed")
                    self.messageChannel.finishReceiving()
                    DispatchQueue.main.async {
                        self.stop()
                    }
                    break
                } else {
                    self.logger.debug("Received \(data.count, privacy: .public) bytes")
                    self.messageChannel.appendReceivedData(data)
                }
            }
        }
    }

    private func observeIncomingMessages() {
        Task {
            do {
                guard let stream = messageChannel.receivedMessages() else { return }
                for try await data in stream {
                    do {
                        let requestData = try JSONDecoder().decode(RuntimeRequestData.self, from: data)
                        guard let handler = messageChannel.handler(for: requestData.identifier) else {
                            logger.warning("No handler for: \(requestData.identifier, privacy: .public)")
                            continue
                        }

                        logger.debug("Handling request: \(requestData.identifier, privacy: .public)")
                        let responseData = try await handler.closure(requestData.data)

                        if handler.responseType != RuntimeMessageNull.self {
                            let response = RuntimeRequestData(identifier: requestData.identifier, data: responseData)
                            try await send(requestData: response)
                        }
                    } catch {
                        logger.error("Handler error: \(error, privacy: .public)")
                        let errorResponse = RuntimeNetworkRequestError(message: "\(error)")
                        if let errorData = try? JSONEncoder().encode(errorResponse) {
                            try? await sendRaw(data: errorData + RuntimeMessageChannel.endMarkerData)
                        }
                    }
                }
            } catch {
                logger.error("Message observation error: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - RuntimeUnderlyingConnection

    func send(requestData: RuntimeRequestData) async throws {
        let data = try JSONEncoder().encode(requestData)
        try await messageChannel.send(data: data) { [weak self] dataToSend in
            try await self?.sendRaw(data: dataToSend)
        }
        logger.debug("Sent request: \(requestData.identifier, privacy: .public)")
    }

    func send<Response: Codable>(requestData: RuntimeRequestData) async throws -> Response {
        try await messageChannel.sendRequest(requestData: requestData) { [weak self] data in
            try await self?.sendRaw(data: data)
        }
    }

    func send<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        let requestData = try RuntimeRequestData(request: request)
        return try await send(requestData: requestData)
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        messageChannel.setMessageHandler(name: name, handler: handler)
    }

    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        messageChannel.setMessageHandler(handler)
    }

    // MARK: - Private

    private func sendRaw(data: Data) async throws {
        if #available(macOS 10.15.4, iOS 13.4, *) {
            try outputHandle.write(contentsOf: data)
        } else {
            outputHandle.write(data)
        }
    }
}

// MARK: - RuntimeStdioError

/// Errors that can occur during stdio communication.
enum RuntimeStdioError: Error, LocalizedError, Sendable {
    /// The connection is not established or has been closed.
    case notConnected
    /// Failed to receive data from the input stream.
    case receiveFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Stdio connection is not established"
        case .receiveFailed:
            return "Failed to receive data from stdio"
        }
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
final class RuntimeStdioClientConnection: RuntimeConnectionBase<RuntimeStdioConnection>, @unchecked Sendable, Loggable {
    /// Creates a client connection with the specified file handles.
    ///
    /// - Parameters:
    ///   - inputHandle: File handle to read responses from (typically the child's stdout).
    ///   - outputHandle: File handle to write requests to (typically the child's stdin).
    /// - Throws: `RuntimeStdioError` if connection cannot be started.
    init(inputHandle: FileHandle, outputHandle: FileHandle) throws {
        super.init()
        let connection = RuntimeStdioConnection(inputHandle: inputHandle, outputHandle: outputHandle)
        self.underlyingConnection = connection
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
final class RuntimeStdioServerConnection: RuntimeConnectionBase<RuntimeStdioConnection>, @unchecked Sendable, Loggable {
    /// Creates a server connection with the specified file handles.
    ///
    /// - Parameters:
    ///   - inputHandle: File handle to read requests from (typically `.standardInput`).
    ///   - outputHandle: File handle to write responses to (typically `.standardOutput`).
    /// - Throws: `RuntimeStdioError` if connection cannot be started.
    init(inputHandle: FileHandle, outputHandle: FileHandle) throws {
        super.init()
        let connection = RuntimeStdioConnection(inputHandle: inputHandle, outputHandle: outputHandle)
        self.underlyingConnection = connection
        try connection.start()
    }
}

import Foundation
import Semaphore
import Asynchrone

// MARK: - RuntimeMessageHandler

/// Encapsulates a message handler that processes requests and returns responses.
///
/// This class handles the JSON encoding/decoding of requests and responses,
/// allowing handlers to work with typed Swift objects.
///
/// - Note: Uses `@unchecked Sendable` because the stored metatypes (`requestType`, `responseType`)
///   are immutable and inherently thread-safe, but `any Codable.Type` doesn't conform to `Sendable`.
final class RuntimeMessageHandler: @unchecked Sendable {
    typealias RawHandler = @Sendable (Data) async throws -> Data

    /// The wrapped handler that processes raw Data.
    let closure: RawHandler

    /// The type of the request this handler expects.
    let requestType: any Codable.Type

    /// The type of the response this handler returns.
    let responseType: any Codable.Type

    /// Creates a message handler with typed request and response.
    ///
    /// - Parameter closure: The handler closure that receives a typed request
    ///   and returns a typed response.
    init<Request: Codable, Response: Codable>(closure: @escaping @Sendable (Request) async throws -> Response) {
        self.requestType = Request.self
        self.responseType = Response.self

        self.closure = { request in
            let request = try JSONDecoder().decode(Request.self, from: request)
            let response = try await closure(request)
            return try JSONEncoder().encode(response)
        }
    }
}

// MARK: - RuntimeMessageNull

/// A null message type used when no payload is needed.
struct RuntimeMessageNull: Codable, Sendable {
    static let null = RuntimeMessageNull()
}

// MARK: - RuntimeMessageProtocol

/// Protocol defining the message framing and processing logic.
///
/// Implementations handle the low-level details of reading/writing data,
/// while the protocol provides the common message framing logic.
protocol RuntimeMessageProtocol: Sendable {
    /// The end marker used to delimit messages.
    static var endMarkerData: Data { get }
}

extension RuntimeMessageProtocol {
    /// Default end marker: `\nOK`
    static var endMarkerData: Data {
        "\nOK".data(using: .utf8)!
    }
}

// MARK: - RuntimeMessageChannel

/// A bidirectional message channel that handles framing, encoding, and dispatching.
///
/// `RuntimeMessageChannel` provides the common infrastructure for message-based
/// communication, including:
/// - Message framing with `\nOK` delimiter
/// - JSON encoding/decoding of requests and responses
/// - Async message handler registration and dispatch
/// - Thread-safe send/receive with semaphore
///
/// ## Usage
///
/// ```swift
/// let channel = RuntimeMessageChannel()
///
/// // Register handlers
/// channel.setMessageHandler(name: "echo") { (input: String) -> String in
///     return "Echo: \(input)"
/// }
///
/// // Process incoming data
/// channel.appendReceivedData(data)
///
/// // Send messages
/// try await channel.send(data: encodedMessage, writer: { data in
///     // Write data to underlying transport
/// })
/// ```
final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
    /// Unique identifier for this channel.
    let id = UUID()

    /// Called when a complete message is received.
    /// - Note: This callback is called from a locked context; avoid long-running operations.
    var onMessageReceived: (@Sendable (Data) -> Void)?

    /// Message handlers keyed by message identifier.
    private var messageHandlers: [String: RuntimeMessageHandler] = [:]

    /// Lock for thread-safe access to handlers.
    private let handlersLock = NSLock()

    /// Buffer for incoming data.
    private var receivingData = Data()

    /// Lock for thread-safe access to receiving buffer.
    private let receivingLock = NSLock()

    /// Stream for received messages.
    private var receivedDataStream: SharedAsyncSequence<AsyncThrowingStream<Data, Error>>?

    /// Continuation for yielding received messages.
    private var receivedDataContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    /// Semaphore for serializing send operations.
    private let sendSemaphore = AsyncSemaphore(value: 1)

    init() {
        setupStreams()
    }

    // MARK: - Stream Setup

    private func setupStreams() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.receivedDataStream = stream.shared()
        self.receivedDataContinuation = continuation
    }

    // MARK: - Handler Registration

    /// Registers a handler for messages with no payload and no response.
    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
            try await handler()
            return RuntimeMessageNull.null
        }
    }

    /// Registers a handler for messages with a payload but no response.
    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        setMessageHandler(name: name) { @Sendable (request: Request) in
            try await handler(request)
            return RuntimeMessageNull.null
        }
    }

    /// Registers a handler for messages with no payload but expecting a response.
    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
            return try await handler()
        }
    }

    /// Registers a handler for messages with both request payload and response.
    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        messageHandlers[name] = RuntimeMessageHandler(closure: handler)
    }

    /// Registers a handler for typed requests with associated responses.
    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        setMessageHandler(name: Request.identifier, handler: handler)
    }

    /// Returns the handler for the given message identifier.
    func handler(for identifier: String) -> RuntimeMessageHandler? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return messageHandlers[identifier]
    }

    // MARK: - Receiving Data

    /// Appends data to the receiving buffer and processes complete messages.
    func appendReceivedData(_ data: Data) {
        receivingLock.lock()
        receivingData.append(data)
        receivingLock.unlock()

        processReceivedData()
    }

    /// Processes the receiving buffer and extracts complete messages.
    private func processReceivedData() {
        receivingLock.lock()
        defer { receivingLock.unlock() }

        while true {
            guard let endRange = receivingData.range(of: Self.endMarkerData) else {
                break
            }

            let messageData = receivingData.subdata(in: 0 ..< endRange.lowerBound)
            receivedDataContinuation?.yield(messageData)
            onMessageReceived?(messageData)

            if endRange.upperBound < receivingData.count {
                receivingData = receivingData.subdata(in: endRange.upperBound ..< receivingData.count)
            } else {
                receivingData = Data()
                break
            }
        }
    }

    /// Finishes the received data stream.
    func finishReceiving(throwing error: (any Error)? = nil) {
        if let error {
            receivedDataContinuation?.finish(throwing: error)
        } else {
            receivedDataContinuation?.finish()
        }
    }

    /// Returns the current size of the receiving buffer.
    var receivingBufferSize: Int {
        receivingLock.lock()
        defer { receivingLock.unlock() }
        return receivingData.count
    }

    // MARK: - Sending Data

    /// Sends data using the provided writer closure.
    ///
    /// This method serializes send operations using a semaphore to prevent
    /// interleaving of messages.
    func send(data: Data, writer: @Sendable (Data) async throws -> Void) async throws {
        await sendSemaphore.wait()
        defer { sendSemaphore.signal() }

        let dataToSend = data + Self.endMarkerData
        try await writer(dataToSend)
    }

    /// Sends a request and waits for a response.
    func sendRequest<Response: Codable>(
        requestData: RuntimeRequestData,
        writer: @Sendable (Data) async throws -> Void
    ) async throws -> Response {
        await sendSemaphore.wait()
        defer { sendSemaphore.signal() }

        let data = try JSONEncoder().encode(requestData)
        let dataToSend = data + Self.endMarkerData
        try await writer(dataToSend)

        // Wait for response
        let responseData = try await receiveData()
        let response = try JSONDecoder().decode(RuntimeRequestData.self, from: responseData)
        return try JSONDecoder().decode(Response.self, from: response.data)
    }

    /// Sends a request with no expected response.
    func sendRequest(
        requestData: RuntimeRequestData,
        writer: @Sendable (Data) async throws -> Void
    ) async throws {
        await sendSemaphore.wait()
        defer { sendSemaphore.signal() }

        let data = try JSONEncoder().encode(requestData)
        let dataToSend = data + Self.endMarkerData
        try await writer(dataToSend)
    }

    /// Waits for and returns the next received message.
    func receiveData() async throws -> Data {
        guard let receivedDataStream else {
            throw RuntimeMessageChannelError.notConnected
        }

        for try await data in receivedDataStream {
            if let error = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data) {
                throw error
            } else {
                return data
            }
        }

        throw RuntimeMessageChannelError.receiveFailed
    }

    /// Returns an async sequence of received messages.
    func receivedMessages() -> SharedAsyncSequence<AsyncThrowingStream<Data, Error>>? {
        receivedDataStream
    }
}

// MARK: - RuntimeMessageChannelError

/// Errors that can occur during message channel operations.
enum RuntimeMessageChannelError: Error, LocalizedError, Sendable {
    case notConnected
    case receiveFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Message channel is not connected"
        case .receiveFailed:
            return "Failed to receive message"
        }
    }
}

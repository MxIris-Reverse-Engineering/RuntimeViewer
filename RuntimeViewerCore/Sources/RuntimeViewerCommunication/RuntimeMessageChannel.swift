import Foundation
import FoundationToolbox
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
@Loggable
final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
    /// Unique identifier for this channel.
    let id = UUID()

    /// Called when a complete message is received.
    /// - Note: This callback is called from a locked context; avoid long-running operations.
    var onMessageReceived: (@Sendable (Data) -> Void)?

    /// Message handlers keyed by message identifier.
    private let messageHandlers = Mutex<[String: RuntimeMessageHandler]>([:])

    /// Pending request continuations keyed by request identifier.
    private let pendingRequests = Mutex<[String: CheckedContinuation<Data, Error>]>([:])

    /// Buffer for incoming data.
    private let receivingData = Mutex<Data>(Data())

    /// Stream for received messages.
    private var receivedDataStream: SharedAsyncSequence<AsyncThrowingStream<Data, Error>>?

    /// Continuation for yielding received messages.
    private var receivedDataContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    /// Semaphore for serializing send operations.
    private let sendSemaphore = AsyncSemaphore(value: 1)

    init() {
        setupStreams()
        #log(.debug, "RuntimeMessageChannel initialized with id: \(self.id, privacy: .public)")
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
        messageHandlers.withLock { $0[name] = RuntimeMessageHandler(closure: handler) }
        #log(.debug, "Registered message handler for: \(name, privacy: .public)")
    }

    /// Registers a handler for typed requests with associated responses.
    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        setMessageHandler(name: Request.identifier, handler: handler)
    }

    /// Returns the handler for the given message identifier.
    func handler(for identifier: String) -> RuntimeMessageHandler? {
        messageHandlers.withLock { $0[identifier] }
    }

    /// Checks if there's a pending request waiting for a response with the given identifier.
    /// If found, delivers the data to the pending request and returns true.
    /// - Parameters:
    ///   - identifier: The request identifier to check.
    ///   - data: The response data to deliver.
    /// - Returns: `true` if the data was delivered to a pending request, `false` otherwise.
    func deliverToPendingRequest(identifier: String, data: Data) -> Bool {
        guard let continuation = pendingRequests.withLock({ $0.removeValue(forKey: identifier) }) else {
            return false
        }
        #log(.debug, "Delivered response to pending request: \(identifier, privacy: .public)")
        continuation.resume(returning: data)
        return true
    }

    // MARK: - Receiving Data

    /// Appends data to the receiving buffer and processes complete messages.
    func appendReceivedData(_ data: Data) {
        receivingData.withLock { $0.append(data) }
        processReceivedData()
    }

    /// Processes the receiving buffer and extracts complete messages.
    private func processReceivedData() {
        receivingData.withLock { buffer in
            while true {
                guard let endRange = buffer.range(of: Self.endMarkerData) else {
                    break
                }

                let messageData = buffer.subdata(in: 0 ..< endRange.lowerBound)
                receivedDataContinuation?.yield(messageData)
                onMessageReceived?(messageData)

                if endRange.upperBound < buffer.count {
                    buffer = buffer.subdata(in: endRange.upperBound ..< buffer.count)
                } else {
                    buffer = Data()
                    break
                }
            }
        }
    }

    /// Finishes the received data stream.
    func finishReceiving(throwing error: (any Error)? = nil) {
        if let error {
            #log(.default, "Finishing receiving with error: \(String(describing: error), privacy: .public)")
            receivedDataContinuation?.finish(throwing: error)
        } else {
            #log(.debug, "Finishing receiving stream normally")
            receivedDataContinuation?.finish()
        }
    }

    /// Returns the current size of the receiving buffer.
    var receivingBufferSize: Int {
        receivingData.withLock { $0.count }
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
        #log(.debug, "Sending \(dataToSend.count, privacy: .public) bytes")
        try await writer(dataToSend)
    }

    /// Sends a request and waits for a response.
    func sendRequest<Response: Codable>(
        requestData: RuntimeRequestData,
        writer: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Response {
        await sendSemaphore.wait()

        #log(.debug, "Sending request: \(requestData.identifier, privacy: .public)")
        let data = try JSONEncoder().encode(requestData)
        let dataToSend = data + Self.endMarkerData

        // Register pending request before sending
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingRequests.withLock { $0[requestData.identifier] = continuation }

            Task {
                do {
                    try await writer(dataToSend)
                } catch {
                    // Remove pending request and resume with error
                    _ = self.pendingRequests.withLock { $0.removeValue(forKey: requestData.identifier) }
                    #log(.error, "Failed to send request \(requestData.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }

        sendSemaphore.signal()

        #log(.debug, "Received response for: \(requestData.identifier, privacy: .public)")
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

        #log(.debug, "Sending fire-and-forget request: \(requestData.identifier, privacy: .public)")
        let data = try JSONEncoder().encode(requestData)
        let dataToSend = data + Self.endMarkerData
        try await writer(dataToSend)
    }

    /// Waits for and returns the next received message.
    func receiveData() async throws -> Data {
        guard let receivedDataStream else {
            #log(.error, "Attempted to receive data but channel is not connected")
            throw RuntimeMessageChannelError.notConnected
        }

        for try await data in receivedDataStream {
            if let error = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data) {
                #log(.default, "Received error response: \(String(describing: error), privacy: .public)")
                throw error
            } else {
                #log(.debug, "Received \(data.count, privacy: .public) bytes")
                return data
            }
        }

        #log(.error, "Receive failed - stream ended unexpectedly")
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

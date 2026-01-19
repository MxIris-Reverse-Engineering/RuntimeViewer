import Foundation
public import Combine

/// Protocol defining the unified interface for all runtime communication channels.
///
/// `RuntimeConnection` provides a consistent API for bidirectional message passing
/// regardless of the underlying transport mechanism (XPC, Network, TCP socket, or stdio).
///
/// ## Implementations
///
/// | Implementation | Transport | Use Case |
/// |----------------|-----------|----------|
/// | `RuntimeXPCConnection` | XPC Mach Service | Cross-process on macOS (requires privileged helper) |
/// | `RuntimeNetworkConnection` | Bonjour/TCP | iOS device to Mac via local network |
/// | `RuntimeLocalSocketConnection` | TCP localhost | Code injection into sandboxed apps |
/// | `RuntimeStdioConnection` | stdin/stdout | CLI tools, language servers |
///
/// ## Message Patterns
///
/// The protocol supports several messaging patterns:
///
/// ```swift
/// // Fire-and-forget (no response expected)
/// try await connection.sendMessage(name: "log", request: LogEntry(message: "Hello"))
///
/// // Request-response with typed request
/// let response = try await connection.sendMessage(request: GetClassListRequest())
///
/// // Request-response by name
/// let count: Int = try await connection.sendMessage(name: "getCount")
/// ```
///
/// ## Handler Registration
///
/// Register handlers to process incoming messages:
///
/// ```swift
/// // Typed request handler
/// connection.setMessageHandler(requestType: GetClassListRequest.self) { request in
///     return GetClassListResponse(classes: [...])
/// }
///
/// // Named handler with request and response
/// connection.setMessageHandler(name: "echo") { (input: String) -> String in
///     return "Echo: \(input)"
/// }
/// ```
public protocol RuntimeConnection: Sendable {
    /// Publisher that emits connection state changes.
    ///
    /// Subscribe to this publisher to observe connection lifecycle events.
    var statePublisher: AnyPublisher<RuntimeConnectionState, Never> { get }

    /// The current connection state.
    var state: RuntimeConnectionState { get }

    /// Stops the connection and releases resources.
    ///
    /// After calling this method, the connection will emit `.disconnected` state
    /// and should not be used for sending or receiving messages.
    func stop()

    /// Sends a message with no payload and no expected response.
    /// - Parameter name: The message identifier.
    func sendMessage(name: String) async throws

    /// Sends a message with a payload but no expected response.
    /// - Parameters:
    ///   - name: The message identifier.
    ///   - request: The request payload to send.
    func sendMessage<Request: Codable>(name: String, request: Request) async throws

    /// Sends a message and waits for a response.
    /// - Parameter name: The message identifier.
    /// - Returns: The decoded response.
    func sendMessage<Response: Codable>(name: String) async throws -> Response

    /// Sends a typed request and waits for its associated response.
    /// - Parameter request: The request conforming to `RuntimeRequest`.
    /// - Returns: The response type defined by the request.
    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response

    /// Sends a message with a payload and waits for a response.
    /// - Parameters:
    ///   - name: The message identifier.
    ///   - request: The request payload to send.
    /// - Returns: The decoded response.
    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response

    /// Registers a handler for messages with no payload and no response.
    /// - Parameters:
    ///   - name: The message identifier to handle.
    ///   - handler: The async closure to execute when the message is received.
    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void)

    /// Registers a handler for messages with a payload but no response.
    /// - Parameters:
    ///   - name: The message identifier to handle.
    ///   - handler: The async closure receiving the decoded request.
    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void)

    /// Registers a handler for messages with no payload but expecting a response.
    /// - Parameters:
    ///   - name: The message identifier to handle.
    ///   - handler: The async closure returning the response.
    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response)

    /// Registers a handler for typed requests with associated responses.
    /// - Parameters:
    ///   - requestType: The request type to handle.
    ///   - handler: The async closure processing the request and returning the response.
    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response)

    /// Registers a handler for messages with both request payload and response.
    /// - Parameters:
    ///   - name: The message identifier to handle.
    ///   - handler: The async closure receiving the request and returning the response.
    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response)
}

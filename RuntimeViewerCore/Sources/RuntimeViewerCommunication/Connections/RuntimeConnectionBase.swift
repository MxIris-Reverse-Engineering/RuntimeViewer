import Foundation
import FoundationToolbox
import Combine

// MARK: - RuntimeConnectionBase

/// Generic base class for RuntimeConnection implementations.
///
/// This class provides a common implementation of the `RuntimeConnection` protocol
/// by delegating to an underlying connection object that handles the actual
/// message sending and receiving.
///
/// ## Usage
///
/// Subclasses should set the `underlyingConnection` property and implement
/// any connection-specific initialization logic.
///
/// ## Type Parameters
///
/// - `Connection`: The underlying connection type that provides `send` and
///   `setMessageHandler` methods.
class RuntimeConnectionBase<Connection: RuntimeUnderlyingConnection>: RuntimeConnection, @unchecked Sendable {
    /// The underlying connection that handles actual communication.
    /// - Note: Thread-safety is managed by the underlying connection itself.
    var underlyingConnection: Connection?

    init() {}

    // MARK: - RuntimeConnection State Properties

    var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        underlyingConnection?.statePublisher ?? Just(.connecting).eraseToAnyPublisher()
    }

    var state: RuntimeConnectionState {
        underlyingConnection?.state ?? .connecting
    }

    var connectionInfo: RuntimeConnectionInfo? { nil }

    func stop() {
        underlyingConnection?.stop()
    }

    func sendMessage(name: String) async throws {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: RuntimeMessageNull.null))
    }

    func sendMessage(name: String, request: some Codable) async throws {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func sendMessage<Response: Codable>(name: String) async throws -> Response {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: RuntimeMessageNull.null))
    }

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        return try await connection.send(request: request)
    }

    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        underlyingConnection?.setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
            try await handler()
            return RuntimeMessageNull.null
        }
    }

    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        underlyingConnection?.setMessageHandler(name: name) { @Sendable (request: Request) in
            try await handler(request)
            return RuntimeMessageNull.null
        }
    }

    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        underlyingConnection?.setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
            return try await handler()
        }
    }

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        underlyingConnection?.setMessageHandler(handler)
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        underlyingConnection?.setMessageHandler(name: name, handler: handler)
    }
}

// MARK: - RuntimeUnderlyingConnection

/// Protocol for underlying connection types that can send and receive messages.
///
/// This protocol abstracts the common interface needed by `RuntimeConnectionBase`
/// to delegate message handling to different connection implementations.
protocol RuntimeUnderlyingConnection: Sendable {
    /// Publisher that emits connection state changes.
    var statePublisher: AnyPublisher<RuntimeConnectionState, Never> { get }

    /// The current connection state.
    var state: RuntimeConnectionState { get }

    /// Stops the connection and releases resources.
    func stop()

    /// Sends a request without expecting a response.
    func send(requestData: RuntimeRequestData) async throws

    /// Sends a request and returns the response.
    func send<Response: Codable>(requestData: RuntimeRequestData) async throws -> Response

    /// Sends a typed request and returns its response.
    func send<Request: RuntimeRequest>(request: Request) async throws -> Request.Response

    /// Registers a message handler for the given name.
    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response)

    /// Registers a message handler for a RuntimeRequest type.
    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response)
}



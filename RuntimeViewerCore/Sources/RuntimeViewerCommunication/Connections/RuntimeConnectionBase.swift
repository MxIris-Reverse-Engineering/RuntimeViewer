import Foundation
import FoundationToolbox
import os.log

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
class RuntimeConnectionBase<Connection: RuntimeUnderlyingConnection>: RuntimeConnection, @unchecked Sendable, Loggable {
    /// The underlying connection that handles actual communication.
    /// - Note: Thread-safety is managed by the underlying connection itself.
    var underlyingConnection: Connection?

    init() {}

    func sendMessage(name: String) async throws {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: NullPayload.null))
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
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: NullPayload.null))
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
        underlyingConnection?.setMessageHandler(name: name) { @Sendable (_: NullPayload) in
            try await handler()
            return NullPayload.null
        }
    }

    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        underlyingConnection?.setMessageHandler(name: name) { @Sendable (request: Request) in
            try await handler(request)
            return NullPayload.null
        }
    }

    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        underlyingConnection?.setMessageHandler(name: name) { @Sendable (_: NullPayload) in
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
protocol RuntimeUnderlyingConnection: Sendable, Loggable {
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

// MARK: - NullPayload

/// A null payload type used when no payload is needed.
///
/// This is used internally by `RuntimeConnectionBase` for messages
/// that don't require a request or response payload.
struct NullPayload: Codable, Sendable {
    static let null = NullPayload()
}

// MARK: - RuntimeConnectionError

/// Common errors for RuntimeConnection implementations.
enum RuntimeConnectionError: Error, LocalizedError, Sendable {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected"
        }
    }
}

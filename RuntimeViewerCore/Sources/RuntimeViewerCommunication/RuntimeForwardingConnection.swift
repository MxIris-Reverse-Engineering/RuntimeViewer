import Foundation
import FoundationToolbox
import Combine

/// Protocol for `RuntimeConnection` implementations backed by an underlying
/// transport connection.
///
/// Conforming types expose their transport via `underlyingConnection`; the
/// protocol extension forwards every messaging requirement to it, so a
/// conformer only implements connection-specific concerns: state publishing
/// (each conformer owns a private state subject and exposes it through its
/// `some Publisher` witness), lifecycle, and reconnection orchestration.
///
/// ## Associated Types
///
/// - `Connection`: The underlying connection type that provides `send` and
///   `setMessageHandler` methods.
protocol RuntimeForwardingConnection: RuntimeConnection {
    /// The underlying connection type that handles actual communication.
    associatedtype Connection: RuntimeUnderlyingConnection

    /// The underlying connection that handles actual communication.
    /// - Note: Thread-safety is managed by the underlying connection itself.
    var underlyingConnection: Connection? { get }
}

// MARK: - Default Forwarding Implementations

extension RuntimeForwardingConnection {
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
        try await sendMessage(name: name, timeout: nil)
    }

    func sendMessage<Response: Codable>(name: String, timeout: TimeInterval?) async throws -> Response {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: RuntimeMessageNull.null), timeout: timeout)
    }

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        try await sendMessage(request: request, timeout: nil)
    }

    func sendMessage<Request: RuntimeRequest>(request: Request, timeout: TimeInterval?) async throws -> Request.Response {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        return try await connection.send(request: request, timeout: timeout)
    }

    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        try await sendMessage(name: name, request: request, timeout: nil)
    }

    func sendMessage<Response: Codable>(name: String, request: some Codable, timeout: TimeInterval?) async throws -> Response {
        guard let connection = underlyingConnection else {
            throw RuntimeConnectionError.notConnected
        }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request), timeout: timeout)
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





import Foundation
import FoundationToolbox
import Combine

/// Protocol for underlying connection types that can send and receive messages.
///
/// This protocol abstracts the common interface needed by `RuntimeForwardingConnection`
/// to delegate message handling to different connection implementations.
protocol RuntimeUnderlyingConnection: Sendable {
    associatedtype StatePublisher: Publisher<RuntimeConnectionState, Never>
    
    /// Publisher that emits connection state changes.
    var statePublisher: StatePublisher { get }

    /// The current connection state.
    var state: RuntimeConnectionState { get }

    /// Stops the connection and releases resources.
    func stop()

    /// Sends a request without expecting a response.
    func send(requestData: RuntimeRequestData) async throws

    /// Sends a request and returns the response.
    /// - Parameter timeout: Optional deadline (seconds). Forwarded to the underlying message
    ///   channel; `nil` keeps the historical "wait until response or disconnect" behaviour.
    func send<Response: Codable>(requestData: RuntimeRequestData, timeout: TimeInterval?) async throws -> Response

    /// Sends a typed request and returns its response.
    func send<Request: RuntimeRequest>(request: Request, timeout: TimeInterval?) async throws -> Request.Response

    /// Registers a message handler for the given name.
    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response)

    /// Registers a message handler for a RuntimeRequest type.
    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response)
}

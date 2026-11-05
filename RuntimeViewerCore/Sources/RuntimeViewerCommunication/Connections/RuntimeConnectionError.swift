public import Foundation

/// Errors that can occur during connection operations.
///
/// This provides a unified error type that can represent errors from
/// any underlying transport (socket, network, XPC, etc.).
public enum RuntimeConnectionError: Error, Sendable, Equatable, LocalizedError {
    /// An error occurred in the local socket connection.
    case socketError(String)

    /// An error occurred in the network connection (NWConnection).
    case networkError(String)

    /// An error occurred in the XPC connection.
    case xpcError(String)

    /// The connection timed out while waiting.
    case timeout

    /// The remote peer closed the connection.
    case peerClosed

    /// The NWListener remained in `.waiting` state (e.g. during the local network permission prompt)
    /// and did not recover within the timeout. A retry with a new listener may succeed.
    case listenerWaiting

    /// An unknown or unexpected error occurred.
    case unknown(String)

    case notConnected
    
    public var errorDescription: String? {
        switch self {
        case .socketError(let message):
            return "Socket error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .xpcError(let message):
            return "XPC error: \(message)"
        case .timeout:
            return "Connection timed out"
        case .peerClosed:
            return "Connection closed by peer"
        case .unknown(let message):
            return "Unknown error: \(message)"
        case .notConnected:
            return "Not connected"
        case .listenerWaiting:
            return "Listener waiting (local network permission may be required)"
        }
    }
}

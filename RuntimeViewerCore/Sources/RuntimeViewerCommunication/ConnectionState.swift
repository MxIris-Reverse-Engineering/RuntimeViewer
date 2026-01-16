public import Foundation

// MARK: - ConnectionState

/// Represents the current state of a connection.
///
/// This enum provides a unified way to track connection lifecycle across
/// all connection types (XPC, Network, LocalSocket, Stdio, DirectTCP).
public enum ConnectionState: Sendable, Equatable {
    /// The connection is being established.
    case connecting

    /// The connection is established and ready to send/receive messages.
    case connected

    /// The connection has been terminated, either normally or due to an error.
    case disconnected(error: ConnectionError?)

    /// Returns `true` if the connection is currently connected and ready.
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Returns `true` if the connection is in the process of connecting.
    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Returns `true` if the connection has been disconnected.
    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

// MARK: - ConnectionError

/// Errors that can occur during connection operations.
///
/// This provides a unified error type that can represent errors from
/// any underlying transport (socket, network, XPC, etc.).
public enum ConnectionError: Error, Sendable, Equatable, LocalizedError {
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

    /// An unknown or unexpected error occurred.
    case unknown(String)

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
        }
    }
}

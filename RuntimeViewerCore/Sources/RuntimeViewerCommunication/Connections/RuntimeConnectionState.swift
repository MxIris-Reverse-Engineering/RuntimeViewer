import Foundation

// MARK: - RuntimeConnectionState

/// Represents the current state of a connection.
///
/// This enum provides a unified way to track connection lifecycle across
/// all connection types (XPC, Network, LocalSocket, Stdio, DirectTCP).
public enum RuntimeConnectionState: Sendable, Equatable {
    /// The connection is being established.
    case connecting

    /// The connection is established and ready to send/receive messages.
    case connected

    /// The connection has been terminated, either normally or due to an error.
    case disconnected(error: RuntimeConnectionError?)

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

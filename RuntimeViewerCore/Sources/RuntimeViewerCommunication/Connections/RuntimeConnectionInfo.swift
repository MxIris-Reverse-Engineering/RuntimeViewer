import Foundation
import Combine
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import HelperCommunication
#endif

/// Metadata about a connection's local endpoint.
///
/// Used to expose transport-specific details (e.g., TCP host/port) through
/// the generic `RuntimeConnection` interface without requiring downcasts.
public struct RuntimeConnectionInfo: Sendable {
    /// The local host address (e.g., IP address the server is listening on).
    public let host: String

    /// The local port number.
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

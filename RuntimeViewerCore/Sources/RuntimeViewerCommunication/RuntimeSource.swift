import Foundation

extension RuntimeSource {
    /// The business role in the communication.
    ///
    /// - Note: This represents the **business role**, not the socket role.
    ///   For local socket connections, socket roles are inverted due to sandbox restrictions.
    ///   See `RuntimeLocalSocketConnection` documentation for details.
    public enum Role: Sendable, Codable, Equatable {
        /// The client role: sends requests and receives responses.
        case client
        /// The server role: receives requests and sends responses.
        case server

        public var isClient: Bool { self == .client }
        public var isServer: Bool { self == .server }
    }

    /// A unique identifier for a runtime connection endpoint.
    public struct Identifier: Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, Equatable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: StringLiteralType) {
            self.init(rawValue: value)
        }
    }
}

/// Represents different sources for runtime inspection.
///
/// `RuntimeSource` defines the various ways to connect to a runtime environment
/// for inspection, whether it's local, remote via XPC, over the network via Bonjour,
/// or through local socket for code injection scenarios.
///
/// ## Source Types
///
/// | Source | Description | Use Case |
/// |--------|-------------|----------|
/// | `local` | Direct local access | Same process inspection |
/// | `remote` | XPC-based connection | Cross-process on same machine |
/// | `bonjourClient/Server` | Network discovery | iOS device to Mac |
/// | `localSocketClient/Server` | TCP localhost | Code injection into sandboxed apps |
///
/// ## Local Socket: Business Role vs Socket Role
///
/// For `localSocketClient` and `localSocketServer`, the naming refers to the
/// **business role** (who sends queries vs who handles them), NOT the socket role:
///
/// | Source | Business Role | Socket Role | Used By |
/// |--------|---------------|-------------|---------|
/// | `localSocketClient` | Client (queries) | **Server** (bind/listen) | Main app |
/// | `localSocketServer` | Server (handles) | **Client** (connect) | Injected code |
///
/// This inversion is necessary because sandboxed apps cannot call `bind()`.
/// See `RuntimeLocalSocketConnection` documentation for detailed explanation.
public enum RuntimeSource: Sendable, CustomStringConvertible, Codable, Equatable {
    /// Local runtime inspection (same process).
    case local

    /// Remote runtime via XPC Mach service.
    ///
    /// - Parameters:
    ///   - name: Display name for the connection.
    ///   - identifier: XPC service identifier.
    ///   - role: Whether this endpoint is client or server.
    case remote(name: String, identifier: Identifier, role: Role)

    /// Network client connecting via Bonjour-discovered endpoint.
    ///
    /// - Parameter endpoint: The discovered network endpoint to connect to.
    case bonjourClient(endpoint: RuntimeNetworkEndpoint)

    /// Network server advertising via Bonjour.
    ///
    /// - Parameters:
    ///   - name: The service name to advertise.
    ///   - identifier: Unique identifier for this server.
    case bonjourServer(name: String, identifier: Identifier)

    /// Local socket business client (main app side).
    ///
    /// Despite the name "client", this uses a **socket server** internally
    /// because the main app has network permissions to call `bind()`.
    /// The injected code (business server) connects to this socket server.
    ///
    /// - Parameters:
    ///   - name: Display name for the target process.
    ///   - identifier: Shared identifier for port calculation.
    case localSocketClient(name: String, identifier: Identifier)

    /// Local socket business server (injected code side).
    ///
    /// Despite the name "server", this uses a **socket client** internally
    /// because injected code runs in sandboxed apps that cannot call `bind()`.
    /// This connects to the socket server created by the main app.
    ///
    /// - Parameters:
    ///   - name: Display name for this service.
    ///   - identifier: Shared identifier for port calculation.
    case localSocketServer(name: String, identifier: Identifier)

    /// Direct TCP client connecting to a known host and port.
    ///
    /// Unlike Bonjour connections, this doesn't require `NSBonjourServices` or
    /// `NSLocalNetworkUsageDescription` - just the server's IP address and port.
    /// The host:port can be obtained via:
    /// - User input
    /// - QR code scan
    /// - Configuration file
    ///
    /// - Parameters:
    ///   - name: Display name for the connection.
    ///   - host: The hostname or IP address of the server.
    ///   - port: The port number the server is listening on.
    case directTCPClient(name: String, host: String, port: UInt16)

    /// Direct TCP server listening on a specified port.
    ///
    /// Creates a server that listens on the specified port. Use port 0 to let
    /// the system assign an available port automatically. After initialization,
    /// the actual host:port can be displayed to the user or encoded as a QR code.
    ///
    /// - Parameters:
    ///   - name: Display name for this server.
    ///   - port: The port to listen on (0 for auto-assign).
    case directTCPServer(name: String, port: UInt16)

    public var description: String {
        switch self {
        case .local: return "My Mac"
        case .remote(let name, _, _): return name
        case .bonjourClient(let endpoint): return endpoint.name
        case .bonjourServer(let name, _): return name
        case .localSocketClient(let name, _): return name
        case .localSocketServer(let name, _): return name
        case .directTCPClient(let name, _, _): return name
        case .directTCPServer(let name, _): return name
        }
    }

    public var isRemote: Bool {
        switch self {
        case .local: return false
        default: return true
        }
    }

    public var remoteRole: Role? {
        switch self {
        case .remote(_, _, let role): return role
        case .bonjourClient,
             .localSocketClient,
             .directTCPClient: return .client
        case .bonjourServer,
             .localSocketServer,
             .directTCPServer: return .server
        default: return nil
        }
    }

    /// Returns `true` if this source uses XPC for communication.
    /// XPC connections cannot be reconnected due to SwiftyXPC limitations,
    /// they must be destroyed and recreated instead.
    public var isXPC: Bool {
        switch self {
        case .remote: return true
        default: return false
        }
    }
}

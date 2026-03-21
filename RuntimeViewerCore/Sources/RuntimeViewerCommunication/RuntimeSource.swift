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
    public struct Identifier: Sendable, Hashable, Codable, RawRepresentable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
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
/// | `bonjour` | Network discovery | iOS device to Mac |
/// | `localSocket` | TCP localhost | Code injection into sandboxed apps |
/// | `directTCP` | Direct TCP connection | Known host:port connection |
///
/// ## Local Socket: Business Role vs Socket Role
///
/// For `localSocket`, the `role` refers to the **business role** (who sends queries
/// vs who handles them), NOT the socket role:
///
/// | Role | Business Role | Socket Role | Used By |
/// |------|---------------|-------------|---------|
/// | `.client` | Client (queries) | **Server** (bind/listen) | Main app |
/// | `.server` | Server (handles) | **Client** (connect) | Injected code |
///
/// This inversion is necessary because sandboxed apps cannot call `bind()`.
/// See `RuntimeLocalSocketConnection` documentation for detailed explanation.
public enum RuntimeSource: Sendable, CustomStringConvertible, Codable {
    /// Local runtime inspection (same process).
    case local

    /// Remote runtime via XPC Mach service.
    ///
    /// - Parameters:
    ///   - name: Display name for the connection.
    ///   - identifier: XPC service identifier.
    ///   - role: Whether this endpoint is client or server.
    case remote(name: String, identifier: Identifier, role: Role)

    /// Network connection via Bonjour discovery.
    ///
    /// - Parameters:
    ///   - name: Display name for the connection / service name to advertise.
    ///   - identifier: Unique identifier for this endpoint.
    ///   - role: Whether this endpoint is client or server.
    case bonjour(name: String, identifier: Identifier, role: Role)

    /// Local socket connection for code injection scenarios.
    ///
    /// The `role` represents the **business role**, not the socket role.
    /// Socket roles are inverted due to sandbox restrictions:
    /// - `.client` uses a socket **server** (main app has bind permission)
    /// - `.server` uses a socket **client** (injected code in sandboxed app)
    ///
    /// - Parameters:
    ///   - name: Display name for the connection.
    ///   - identifier: Shared identifier for port calculation.
    ///   - role: Whether this endpoint is client or server.
    case localSocket(name: String, identifier: Identifier, role: Role)

    /// Direct TCP connection to a known host and port.
    ///
    /// Unlike Bonjour connections, this doesn't require `NSBonjourServices` or
    /// `NSLocalNetworkUsageDescription` - just the server's IP address and port.
    ///
    /// - Parameters:
    ///   - name: Display name for the connection.
    ///   - host: The hostname or IP address (nil for server).
    ///   - port: The port number (0 for auto-assign on server).
    ///   - role: Whether this endpoint is client or server.
    case directTCP(name: String, host: String?, port: UInt16, role: Role)

    public var description: String {
        switch self {
        case .local: return "My Mac"
        case .remote(let name, _, _): return name
        case .bonjour(let name, _, _): return name
        case .localSocket(let name, _, _): return name
        case .directTCP(let name, _, _, _): return name
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
        case .local: return nil
        case .remote(_, _, let role),
             .bonjour(_, _, let role),
             .localSocket(_, _, let role),
             .directTCP(_, _, _, let role):
            return role
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

extension RuntimeSource: Equatable {
    public static func == (lhs: RuntimeSource, rhs: RuntimeSource) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local):
            return true
        case (.remote(_, let lId, let lRole), .remote(_, let rId, let rRole)):
            return lId == rId && lRole == rRole
        case (.bonjour(_, let lId, let lRole), .bonjour(_, let rId, let rRole)):
            return lId == rId && lRole == rRole
        case (.localSocket(_, let lId, let lRole), .localSocket(_, let rId, let rRole)):
            return lId == rId && lRole == rRole
        case (.directTCP(_, let lHost, let lPort, let lRole), .directTCP(_, let rHost, let rPort, let rRole)):
            return lHost == rHost && lPort == rPort && lRole == rRole
        default:
            return false
        }
    }
}

extension RuntimeSource: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .local:
            hasher.combine(0)
        case .remote(_, let identifier, let role):
            hasher.combine(1)
            hasher.combine(identifier)
            hasher.combine(role)
        case .bonjour(_, let identifier, let role):
            hasher.combine(2)
            hasher.combine(identifier)
            hasher.combine(role)
        case .localSocket(_, let identifier, let role):
            hasher.combine(3)
            hasher.combine(identifier)
            hasher.combine(role)
        case .directTCP(_, let host, let port, let role):
            hasher.combine(4)
            hasher.combine(host)
            hasher.combine(port)
            hasher.combine(role)
        }
    }
}

extension RuntimeSource {
    /// A stable string identifier for this runtime source, suitable for use as a notification or storage key.
    public var identifier: String {
        switch self {
        case .local:
            return "local"
        case .remote(_, let id, _):
            return id.rawValue
        case .bonjour(let name, let id, let role):
            return role.isClient ? "bonjour.\(name)" : "bonjourServer.\(id.rawValue)"
        case .localSocket(_, let id, let role):
            return role.isClient ? id.rawValue : "localSocketServer.\(id.rawValue)"
        case .directTCP(let name, let host, let port, let role):
            return role.isClient ? "tcp.\(name).\(host ?? "").\(port)" : "tcpServer.\(name).\(port)"
        }
    }
}

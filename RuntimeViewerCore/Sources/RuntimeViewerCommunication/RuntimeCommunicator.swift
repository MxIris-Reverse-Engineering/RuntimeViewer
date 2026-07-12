public import Foundation
public import FoundationToolbox

#if os(macOS)
import HelperCommunication
#endif

public enum RuntimeCommunicatorError: Error, LocalizedError, Sendable {
    case localConnectionNotSupported
    case remoteConnectionNotSupportedOnThisPlatform
    case bonjourClientRequiresEndpoint
    case directTCPClientRequiresHost
    case directTCPNotSupportedOnThisPlatform

    public var errorDescription: String? {
        switch self {
        case .localConnectionNotSupported:
            return "Local connection is not supported"
        case .remoteConnectionNotSupportedOnThisPlatform:
            return "Remote connection is not supported on this platform"
        case .bonjourClientRequiresEndpoint:
            return "Bonjour client connection requires an endpoint"
        case .directTCPClientRequiresHost:
            return "Direct TCP client connection requires a host"
        case .directTCPNotSupportedOnThisPlatform:
            return "Direct TCP connection is not supported on this platform"
        }
    }
}

/// Factory for creating runtime connections based on the specified source.
///
/// `RuntimeCommunicator` abstracts the complexity of establishing connections
/// to different runtime sources, whether local, remote via XPC, Bonjour, or
/// local socket for code injection scenarios.
///
/// ## Usage
///
/// ```swift
/// let communicator = RuntimeCommunicator()
/// let connection = try await communicator.connect(to: .localSocket(
///     name: "Target App",
///     identifier: "com.example.target",
///     role: .client
/// ))
/// ```
@Loggable
public final class RuntimeCommunicator {
    public init() {
        #log(.debug, "RuntimeCommunicator initialized")
    }

    /// Establishes a connection to the specified runtime source.
    ///
    /// - Parameters:
    ///   - source: The runtime source to connect to.
    ///   - credential: Session-scoped credential resolved at connect time. Required for
    ///     `.bonjour` + `.client` (the discovered `NWEndpoint`); optional for `.remote` + `.client`
    ///     (a previously-handshaked XPC peer endpoint enables direct reconnect). See
    ///     `RuntimeConnectionCredential` for the full matrix.
    ///   - waitForConnection: For `.directTCP` server only — whether to block until the first
    ///     client connects.
    ///   - modifier: Optional closure to configure the connection before use.
    /// - Returns: A configured `RuntimeConnection` ready for communication.
    /// - Throws: An error if the connection cannot be established.
    public func connect(
        to source: RuntimeSource,
        credential: RuntimeConnectionCredential? = nil,
        waitForConnection: Bool = true,
        modifier: ((any RuntimeConnection) async throws -> Void)? = nil
    ) async throws -> any RuntimeConnection {
        #log(.info, "Connecting to source: \(String(describing: source), privacy: .public)")
        switch source {
        case .local:
            #log(.error, "Local connection is not supported")
            throw RuntimeCommunicatorError.localConnectionNotSupported

        case .remote(_, let identifier, let role):
            #if os(macOS)
            if role.isServer {
                #log(.debug, "Creating XPC server connection with identifier: \(String(describing: identifier), privacy: .public)")
                let connection = try await RuntimeXPCServerConnection(identifier: identifier, modifier: modifier)
                #log(.info, "XPC server connection established")
                return connection
            } else {
                if case .xpcServer(let serverEndpoint) = credential {
                    #log(.debug, "Creating XPC client connection (direct reconnect) with identifier: \(String(describing: identifier), privacy: .public)")
                    let connection = try await RuntimeXPCClientConnection(identifier: identifier, serverEndpoint: serverEndpoint, modifier: modifier)
                    #log(.info, "XPC client direct reconnection established")
                    return connection
                } else {
                    #log(.debug, "Creating XPC client connection with identifier: \(String(describing: identifier), privacy: .public)")
                    let connection = try await RuntimeXPCClientConnection(identifier: identifier, modifier: modifier)
                    #log(.info, "XPC client connection established")
                    return connection
                }
            }
            #else
            #log(.error, "Remote connection is not supported on this platform")
            throw RuntimeCommunicatorError.remoteConnectionNotSupportedOnThisPlatform
            #endif

        case .bonjour(let name, _, let role):
            if role.isClient {
                guard case .bonjour(let bonjourEndpoint) = credential else {
                    #log(.error, "Bonjour client connection requires an endpoint")
                    throw RuntimeCommunicatorError.bonjourClientRequiresEndpoint
                }
                #log(.debug, "Creating Bonjour client connection to endpoint: \(String(describing: bonjourEndpoint), privacy: .public)")
                let runtimeConnection = try RuntimeNetworkClientConnection(endpoint: bonjourEndpoint)
                try await modifier?(runtimeConnection)
                #log(.info, "Bonjour client connection established")
                return runtimeConnection
            } else {
                #log(.debug, "Creating Bonjour server connection with name: \(name, privacy: .public)")
                let runtimeConnection = try await RuntimeNetworkServerConnection(name: name)
                try await modifier?(runtimeConnection)
                #log(.info, "Bonjour server connection established")
                return runtimeConnection
            }

        case .localSocket(_, let identifier, let role):
            if role.isClient {
                // IMPORTANT: Role Inversion for Sandbox Compatibility
                //
                // Despite being the "business client" (sends queries, receives responses),
                // we use RuntimeLocalSocketServerConnection (socket server) here because:
                //
                // 1. This code runs in the main RuntimeViewer app, which has network permissions
                // 2. The counterpart (injected code) runs in sandboxed apps that cannot bind()
                // 3. Socket server requires bind() - only allowed in non-sandboxed apps
                // 4. Socket client only needs connect() - allowed even in sandboxed apps
                //
                // See RuntimeLocalSocketConnection documentation for detailed explanation.
                #log(.debug, "Creating local socket server connection (business client) with identifier: \(identifier.rawValue, privacy: .public)")
                let runtimeConnection = RuntimeLocalSocketServerConnection(identifier: identifier.rawValue)
                try await runtimeConnection.start()
                try await modifier?(runtimeConnection)
                #log(.info, "Local socket server connection established")
                return runtimeConnection
            } else {
                // IMPORTANT: Role Inversion for Sandbox Compatibility
                //
                // Despite being the "business server" (handles queries, sends responses),
                // we use RuntimeLocalSocketClientConnection (socket client) here because:
                //
                // 1. This code runs inside the injected dylib in the target (sandboxed) app
                // 2. Sandboxed apps cannot call bind() - EPERM error
                // 3. Socket client only needs connect() - allowed in sandboxed apps
                //
                // See RuntimeLocalSocketConnection documentation for detailed explanation.
                #log(.debug, "Creating local socket client connection (business server) with identifier: \(identifier.rawValue, privacy: .public)")
                let runtimeConnection = try await RuntimeLocalSocketClientConnection(identifier: identifier.rawValue)
                try await modifier?(runtimeConnection)
                #log(.info, "Local socket client connection established")
                return runtimeConnection
            }

        case .directTCP(_, let host, let port, let role):
            #if canImport(Network)
            if role.isClient {
                guard let host else {
                    #log(.error, "Direct TCP client connection requires a host")
                    throw RuntimeCommunicatorError.directTCPClientRequiresHost
                }
                #log(.debug, "Creating direct TCP client connection to \(host, privacy: .public):\(port, privacy: .public)")
                let runtimeConnection = try await RuntimeDirectTCPClientConnection(host: host, port: port)
                try await modifier?(runtimeConnection)
                #log(.info, "Direct TCP client connection established")
                return runtimeConnection
            } else {
                #log(.debug, "Creating direct TCP server connection on port: \(port, privacy: .public)")
                let runtimeConnection = try await RuntimeDirectTCPServerConnection(port: port, waitForConnection: waitForConnection)
                try await modifier?(runtimeConnection)
                #log(.info, "Direct TCP server connection established")
                return runtimeConnection
            }
            #else
            #log(.error, "Direct TCP connection is not supported on this platform")
            throw RuntimeCommunicatorError.directTCPNotSupportedOnThisPlatform
            #endif
        }
    }
}

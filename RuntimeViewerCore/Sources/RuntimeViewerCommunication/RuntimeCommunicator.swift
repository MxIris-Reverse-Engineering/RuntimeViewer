import Foundation
public import FoundationToolbox

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
/// let connection = try await communicator.connect(to: .localSocketClient(
///     name: "Target App",
///     identifier: "com.example.target"
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
    ///   - modifier: Optional closure to configure the connection before use.
    /// - Returns: A configured `RuntimeConnection` ready for communication.
    /// - Throws: An error if the connection cannot be established.
    public func connect(to source: RuntimeSource, modifier: ((RuntimeConnection) async throws -> Void)? = nil) async throws -> RuntimeConnection {
        #log(.info, "Connecting to source: \(String(describing: source), privacy: .public)")
        switch source {
        case .local:
            #log(.error, "Local connection is not supported")
            throw NSError(domain: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeCommunicator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local connection is not supported"])

        case .remote(_, let identifier, let role):
            #if os(macOS)
            if role.isServer {
                #log(.debug, "Creating XPC server connection with identifier: \(String(describing: identifier), privacy: .public)")
                let connection = try await RuntimeXPCServerConnection(identifier: identifier, modifier: modifier)
                #log(.info, "XPC server connection established")
                return connection
            } else {
                #log(.debug, "Creating XPC client connection with identifier: \(String(describing: identifier), privacy: .public)")
                let connection = try await RuntimeXPCClientConnection(identifier: identifier, modifier: modifier)
                #log(.info, "XPC client connection established")
                return connection
            }
            #else
            #log(.error, "Remote connection is not supported on this platform")
            throw NSError(domain: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeCommunicator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Remote connection is not supported on this platform"])
            #endif

        case .bonjourClient(let endpoint):
            #log(.debug, "Creating Bonjour client connection to endpoint: \(String(describing: endpoint), privacy: .public)")
            let runtimeConnection = try RuntimeNetworkClientConnection(endpoint: endpoint)
            try await modifier?(runtimeConnection)
            #log(.info, "Bonjour client connection established")
            return runtimeConnection

        case .bonjourServer(let name, _):
            #log(.debug, "Creating Bonjour server connection with name: \(name, privacy: .public)")
            let runtimeConnection = try await RuntimeNetworkServerConnection(name: name)
            try await modifier?(runtimeConnection)
            #log(.info, "Bonjour server connection established")
            return runtimeConnection

        case .localSocketClient(_, let identifier):
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

        case .localSocketServer(_, let identifier):
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

        case .directTCPClient(_, let host, let port):
            #if canImport(Network)
            // Direct TCP connection to a known host:port.
            // Doesn't require NSBonjourServices or NSLocalNetworkUsageDescription.
            #log(.debug, "Creating direct TCP client connection to \(host, privacy: .public):\(port, privacy: .public)")
            let runtimeConnection = try await RuntimeDirectTCPClientConnection(host: host, port: port)
            try await modifier?(runtimeConnection)
            #log(.info, "Direct TCP client connection established")
            return runtimeConnection
            #else
            #log(.error, "Direct TCP connection is not supported on this platform")
            throw NSError(domain: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeCommunicator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Direct TCP connection is not supported on this platform"])
            #endif

        case .directTCPServer(_, let port):
            #if canImport(Network)
            // Direct TCP server listening on a port.
            // After initialization, server.host and server.port contain the actual address.
            #log(.debug, "Creating direct TCP server connection on port: \(port, privacy: .public)")
            let runtimeConnection = try await RuntimeDirectTCPServerConnection(port: port)
            try await modifier?(runtimeConnection)
            #log(.info, "Direct TCP server connection established")
            return runtimeConnection
            #else
            #log(.error, "Direct TCP connection is not supported on this platform")
            throw NSError(domain: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeCommunicator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Direct TCP connection is not supported on this platform"])
            #endif
        }
    }
}

#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
@preconcurrency public import SwiftyXPC

// MARK: - XPCListenerEndpointProviding

/// Protocol for connections that expose their XPC listener endpoint.
///
/// Used by `RuntimeEngine` to retrieve the server's listener endpoint
/// for registration with the Mach Service injected endpoint registry.
public protocol XPCListenerEndpointProviding: AnyObject {
    var xpcListenerEndpoint: SwiftyXPC.XPCEndpoint { get }
}

// MARK: - RuntimeXPCConnection

/// XPC-based connection for cross-process communication on macOS.
///
/// `RuntimeXPCConnection` uses XPC Mach services to establish secure, bidirectional
/// communication between processes. This is the recommended approach for communication
/// between an app and its privileged helper tool or XPC service.
///
/// ## Architecture
///
/// ### Initial Connection (Handshake via Mach Service Broker)
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Client App         │                    │  XPC Mach Service   │
/// │                     │   1. register      │  (Privileged Helper)│
/// │  XPCClientConnection│──────endpoint─────>│                     │
/// │                     │                    │  Endpoint Registry  │
/// └─────────────────────┘                    └─────────────────────┘
///                                                      │
///                                                      │ 2. broker
///                                                      ▼
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Server Process     │  3. fetch endpoint │                     │
/// │  (e.g., Injected)   │<───────────────────┤                     │
/// │  XPCServerConnection│  4. direct XPC     │                     │
/// │                     │──────────────────->│  Client App         │
/// └─────────────────────┘  5. serverLaunched └─────────────────────┘
/// ```
///
/// ### Reconnection (Direct Endpoint via Injected Endpoint Registry)
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Client App (new)   │                    │  Server Process     │
/// │                     │  1. connect to     │  (already running)  │
/// │  XPCClientConnection│─────server EP─────>│  XPCServerConnection│
/// │  (serverEndpoint:)  │                    │  (reused listener)  │
/// │                     │  2. ClientRecon-   │                     │
/// │                     │─────nected(EP)────>│  3. update          │
/// │                     │                    │     self.connection  │
/// │                     │<═══bidirectional═══│                     │
/// └─────────────────────┘                    └─────────────────────┘
/// ```
///
/// ## Requirements
///
/// - macOS only (XPC is not available on iOS)
/// - Requires a privileged helper tool installed as a Mach service
/// - Both processes must be properly code-signed
///
/// ## Use Cases
///
/// - Communication between main app and Mac Catalyst helper
/// - Privileged operations requiring elevated permissions
/// - Secure IPC with code signing validation
/// - Reconnection to already-injected apps after Host restart
///
/// - Note: For code injection into sandboxed apps, use `RuntimeLocalSocketConnection`
///   instead, as XPC requires the target process to explicitly participate.
@Loggable(.fileprivate)
class RuntimeXPCConnection: RuntimeConnection, @unchecked Sendable {
    fileprivate let identifier: RuntimeSource.Identifier

    fileprivate let listener: SwiftyXPC.XPCListener

    fileprivate let serviceConnection: SwiftyXPC.XPCConnection

    fileprivate var connection: SwiftyXPC.XPCConnection?

    fileprivate let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        self.identifier = identifier
        #log(.info, "Creating XPC connection with identifier: \(identifier.rawValue, privacy: .public)")
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        listener.setMessageHandler(requestType: PingRequest.self) { connection, request in
            return .empty
        }
        self.listener = listener
        #log(.info, "Connecting to XPC Mach service...")
        self.serviceConnection = try await Self.connectToMachService()
        #log(.info, "XPC Mach service connection established")
        self.listener.errorHandler = { [weak self] in
            guard let self else { return }
            handleListenerError(connection: $0, error: $1)
        }
        serviceConnection.errorHandler = { [weak self] in
            guard let self else { return }
            handleServiceConnectionError(connection: $0, error: $1)
        }
        try await modifier?(self)

        self.listener.activate()
        #log(.info, "XPC anonymous listener activated")
    }

    private static func connectToMachService() async throws -> SwiftyXPC.XPCConnection {
        let serviceConnection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
        serviceConnection.activate()
        try await serviceConnection.sendMessage(request: PingRequest())
        #log(.info, "Ping mach service successfully")
        return serviceConnection
    }

    func handleServiceConnectionError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        #log(.error, "\(String(describing: connection), privacy: .public) \(String(describing: error), privacy: .public)")
//        stateSubject.send(.disconnected(error: .xpcError("Service connection error: \(error.localizedDescription)")))
    }

    func handleListenerError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        #log(.error, "\(String(describing: connection), privacy: .public) \(String(describing: error), privacy: .public)")
        stateSubject.send(.disconnected(error: .xpcError("Listener error: \(error.localizedDescription)")))
    }

    func handleClientOrServerConnectionError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        #log(.error, "\(String(describing: connection), privacy: .public) \(String(describing: error), privacy: .public)")
        stateSubject.send(.disconnected(error: .xpcError("Connection error: \(error.localizedDescription)")))
    }

    func stop() {
        connection?.cancel()
        connection = nil
        serviceConnection.cancel()
        listener.cancel()
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "XPC connection stopped")
    }

    enum Error: Swift.Error {
        case connectionNotAvailable
    }

    func sendMessage(name: String) async throws {
        guard let connection = connection else {
            throw Error.connectionNotAvailable
        }
        try await connection.sendMessage(name: name)
    }

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        guard let connection = connection else {
            throw Error.connectionNotAvailable
        }
        return try await connection.sendMessage(request: request)
    }

    func sendMessage<Response>(name: String, request: some Codable) async throws -> Response where Response: Decodable, Response: Encodable, Response: Sendable {
        guard let connection = connection else {
            throw Error.connectionNotAvailable
        }
        return try await connection.sendMessage(name: name, request: request)
    }

    func sendMessage<Response>(name: String) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else {
            throw Error.connectionNotAvailable
        }
        return try await connection.sendMessage(name: name)
    }

    func sendMessage(name: String, request: some Codable) async throws {
        guard let connection = connection else {
            throw Error.connectionNotAvailable
        }
        try await connection.sendMessage(name: name, request: request)
    }

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type = Request.self, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        listener.setMessageHandler(name: Request.identifier) { connection, request in
            try await handler(request)
        }
    }

    func setMessageHandler<Request, Response>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) where Request: Decodable, Request: Encodable, Response: Decodable, Response: Encodable {
        listener.setMessageHandler(name: name) { (_: XPCConnection, request: Request) in
            try await handler(request)
        }
    }

    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        listener.setMessageHandler(name: name) { (_: XPCConnection) in
            try await handler()
        }
    }

    func setMessageHandler<Request>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) where Request: Decodable, Request: Encodable {
        listener.setMessageHandler(name: name) { (_: XPCConnection, request: Request) in
            try await handler(request)
        }
    }

    func setMessageHandler<Response>(name: String, handler: @escaping @Sendable () async throws -> Response) where Response: Decodable, Response: Encodable {
        listener.setMessageHandler(name: name) { (_: XPCConnection) in
            try await handler()
        }
    }
}

extension RuntimeXPCConnection: XPCListenerEndpointProviding {
    public var xpcListenerEndpoint: SwiftyXPC.XPCEndpoint { listener.endpoint }
}

private enum CommandIdentifiers {
    static let serverLaunched = command("ServerLaunched")

    static let clientConnected = command("ClientConnected")

    static let clientReconnected = command("ClientReconnected")

    static func command(_ command: String) -> String { "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeXPCConnection.\(command)" }
}

// MARK: - RuntimeXPCClientConnection

/// XPC client connection for the main application side.
///
/// Use this when your application needs to communicate with a server process
/// (such as a Mac Catalyst helper) through the XPC Mach service broker.
///
/// ## Initialization Flow
///
/// 1. Connects to the XPC Mach service (privileged helper)
/// 2. Registers its anonymous listener endpoint
/// 3. Optionally requests the helper to launch the Catalyst helper
/// 4. Waits for the server to connect back via `serverLaunched` message
///
/// ## Usage
///
/// ```swift
/// let client = try await RuntimeXPCClientConnection(
///     identifier: .macCatalyst,
///     modifier: { connection in
///         // Configure connection before activation
///     }
/// )
///
/// // Send request to server
/// let response = try await client.sendMessage(request: GetRuntimeInfoRequest())
/// ```
final class RuntimeXPCClientConnection: RuntimeXPCConnection, @unchecked Sendable {
    override init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modifier: modifier)
        #log(.info, "XPC client registering endpoint for identifier: \(identifier.rawValue, privacy: .public)")
        try await serviceConnection.sendMessage(request: RegisterEndpointRequest(identifier: identifier.rawValue, endpoint: listener.endpoint))
        #log(.info, "XPC client endpoint registered, waiting for server launch...")

        listener.setMessageHandler(name: CommandIdentifiers.serverLaunched) { [weak self] (_: XPCConnection, endpoint: SwiftyXPC.XPCEndpoint) in
            guard let self else { return }
            #log(.info, "XPC client received serverLaunched signal, establishing direct connection...")
            let connection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
            connection.activate()
            connection.errorHandler = { [weak self] in
                guard let self else { return }
                handleClientOrServerConnectionError(connection: $0, error: $1)
            }
            _ = try await connection.sendMessage(request: PingRequest())
            self.connection = connection
            self.stateSubject.send(.connected)
            #log(.info, "XPC client connected to server successfully (ping OK)")
        }
    }

    /// Creates a client connection by directly connecting to a known server endpoint.
    ///
    /// Used for reconnecting to an already-injected app whose endpoint was retrieved
    /// from the Mach Service injected endpoint registry. Bypasses the normal handshake
    /// (no `RegisterEndpointRequest` / `serverLaunched` exchange).
    ///
    /// - Parameters:
    ///   - identifier: The runtime source identifier (typically the injected app's PID string).
    ///   - serverEndpoint: The server's XPC listener endpoint from the injected endpoint registry.
    ///   - modifier: Optional closure to configure the connection before activation.
    init(identifier: RuntimeSource.Identifier, serverEndpoint: SwiftyXPC.XPCEndpoint, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modifier: modifier)
        #log(.info, "XPC client direct-connecting to server endpoint for identifier: \(identifier.rawValue, privacy: .public)")
        let serverConnection = try XPCConnection(type: .remoteServiceFromEndpoint(serverEndpoint))
        serverConnection.activate()
        serverConnection.errorHandler = { [weak self] in
            guard let self else { return }
            handleClientOrServerConnectionError(connection: $0, error: $1)
        }
        _ = try await serverConnection.sendMessage(request: PingRequest())
        #log(.info, "XPC client sending ClientReconnected to server with own listener endpoint...")
        try await serverConnection.sendMessage(name: CommandIdentifiers.clientReconnected, request: listener.endpoint)
        self.connection = serverConnection
        stateSubject.send(.connected)
        #log(.info, "XPC client direct-connected to server successfully")
    }
}

// MARK: - RuntimeXPCServerConnection

/// XPC server connection for the service provider side.
///
/// Use this in a separate process (such as injected code in a target app or
/// Mac Catalyst helper) that provides runtime inspection services to the main application.
///
/// ## Initialization Flow
///
/// 1. Connects to the XPC Mach service (privileged helper)
/// 2. Fetches the client's endpoint from the broker
/// 3. Establishes direct connection to the client
/// 4. Registers its own endpoint for bidirectional communication
/// 5. Notifies the client via `serverLaunched` message
///
/// ## Reconnection Support
///
/// After the initial connection, a `ClientReconnected` handler is registered on the
/// listener. When the Host app restarts and reconnects (via direct endpoint), it sends
/// `ClientReconnected` with its new listener endpoint. The server replaces its peer
/// connection and transitions back to `.connected` state, enabling the engine to
/// re-push runtime data to the new client.
final class RuntimeXPCServerConnection: RuntimeXPCConnection, @unchecked Sendable {
    override init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modifier: modifier)
        #log(.info, "XPC server fetching client endpoint for identifier: \(identifier.rawValue, privacy: .public)")
        let response = try await serviceConnection.sendMessage(request: FetchEndpointRequest(identifier: identifier.rawValue))
        #log(.info, "XPC server establishing direct connection to client...")
        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(response.endpoint))
        connection.activate()
        connection.errorHandler = { [weak self] in
            guard let self else { return }
            handleClientOrServerConnectionError(connection: $0, error: $1)
        }
        #log(.info, "XPC server registering own endpoint...")
        try await serviceConnection.sendMessage(request: RegisterEndpointRequest(identifier: identifier.rawValue, endpoint: listener.endpoint))
        #log(.info, "XPC server sending serverLaunched signal to client...")
        try await connection.sendMessage(name: CommandIdentifiers.serverLaunched, request: listener.endpoint)
        self.connection = connection
        stateSubject.send(.connected)
        #log(.info, "XPC server connected to client successfully")

        // Register reconnection handler for when the Host app restarts and reconnects
        // via the injected endpoint registry (bypassing the normal handshake).
        listener.setMessageHandler(name: CommandIdentifiers.clientReconnected) { [weak self] (_: XPCConnection, clientEndpoint: SwiftyXPC.XPCEndpoint) in
            guard let self else { return }
            #log(.info, "XPC server received ClientReconnected, establishing new connection to client...")
            let newConnection = try XPCConnection(type: .remoteServiceFromEndpoint(clientEndpoint))
            newConnection.activate()
            newConnection.errorHandler = { [weak self] in
                guard let self else { return }
                handleClientOrServerConnectionError(connection: $0, error: $1)
            }
            _ = try await newConnection.sendMessage(request: PingRequest())
            self.connection = newConnection
            self.stateSubject.send(.connected)
            #log(.info, "XPC server reconnected to new client successfully (ping OK)")
        }
    }
}

extension SwiftyXPC.XPCConnection {
    @discardableResult
    public func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: type(of: request).identifier, request: request)
    }
}

extension SwiftyXPC.XPCListener {
    public func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type = Request.self, handler: @escaping (XPCConnection, Request) async throws -> Request.Response) {
        setMessageHandler(name: requestType.identifier) { (connection: XPCConnection, request: Request) -> Request.Response in
            try await handler(connection, request)
        }
    }
}

#endif

#if os(macOS)

import Foundation
import FoundationToolbox
import OSLog
import Combine
@preconcurrency import SwiftyXPC

// MARK: - RuntimeXPCConnection

/// XPC-based connection for cross-process communication on macOS.
///
/// `RuntimeXPCConnection` uses XPC Mach services to establish secure, bidirectional
/// communication between processes. This is the recommended approach for communication
/// between an app and its privileged helper tool or XPC service.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Client App         │                    │  XPC Mach Service   │
/// │                     │                    │  (Privileged Helper)│
/// │                     │   1. connect       │                     │
/// │  XPCClientConnection├───────────────────>│                     │
/// │                     │                    │                     │
/// │                     │   2. register      │  Endpoint Registry  │
/// │                     │      endpoint      │                     │
/// │                     │<───────────────────┤                     │
/// └─────────────────────┘                    └─────────────────────┘
///                                                      │
///                                                      │ 3. broker
///                                                      │    connection
///                                                      ▼
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Server Process     │                    │                     │
/// │  (e.g., Catalyst)   │   4. direct XPC    │                     │
/// │                     │<───────────────────┤                     │
/// │  XPCServerConnection│                    │                     │
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
///
/// - Note: For code injection into sandboxed apps, use `RuntimeLocalSocketConnection`
///   instead, as XPC requires the target process to explicitly participate.
class RuntimeXPCConnection: RuntimeConnection, @unchecked Sendable, Loggable {
    fileprivate let identifier: RuntimeSource.Identifier

    fileprivate let listener: SwiftyXPC.XPCListener

    fileprivate let serviceConnection: SwiftyXPC.XPCConnection

    fileprivate var connection: SwiftyXPC.XPCConnection?

    fileprivate let stateSubject = CurrentValueSubject<ConnectionState, Never>(.connecting)

    var statePublisher: AnyPublisher<ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var state: ConnectionState {
        stateSubject.value
    }

    init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        self.identifier = identifier
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        listener.setMessageHandler(requestType: PingRequest.self) { connection, request in
            return .empty
        }
        self.listener = listener
        self.serviceConnection = try await Self.connectToMachService()
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
    }

    private static func connectToMachService() async throws -> SwiftyXPC.XPCConnection {
        let serviceConnection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
        serviceConnection.activate()
        try await serviceConnection.sendMessage(request: PingRequest())
        Self.logger.info("Ping mach service successfully")
        return serviceConnection
    }

    func handleServiceConnectionError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        logger.error("\(String(describing: connection), privacy: .public) \(String(describing: error), privacy: .public)")
//        stateSubject.send(.disconnected(error: .xpcError("Service connection error: \(error.localizedDescription)")))
    }

    func handleListenerError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        logger.error("\(String(describing: connection), privacy: .public) \(String(describing: error), privacy: .public)")
        stateSubject.send(.disconnected(error: .xpcError("Listener error: \(error.localizedDescription)")))
    }

    func handleClientOrServerConnectionError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        logger.error("\(String(describing: connection), privacy: .public) \(String(describing: error), privacy: .public)")
        stateSubject.send(.disconnected(error: .xpcError("Connection error: \(error.localizedDescription)")))
    }

    func stop() {
        connection?.cancel()
        connection = nil
        serviceConnection.cancel()
        listener.cancel()
        stateSubject.send(.disconnected(error: nil))
        logger.info("XPC connection stopped")
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

private enum CommandIdentifiers {
    static let serverLaunched = command("ServerLaunched")

    static let clientConnected = command("ClientConnected")

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
        try await serviceConnection.sendMessage(request: RegisterEndpointRequest(identifier: identifier.rawValue, endpoint: listener.endpoint))

        if identifier == .macCatalyst {
            try await serviceConnection.sendMessage(request: LaunchCatalystHelperRequest(helperURL: RuntimeViewerCatalystHelperLauncher.helperURL))
        }

        listener.setMessageHandler(name: CommandIdentifiers.serverLaunched) { [weak self] (_: XPCConnection, endpoint: SwiftyXPC.XPCEndpoint) in
            guard let self else { return }
            let connection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
            connection.activate()
            connection.errorHandler = { [weak self] in
                guard let self else { return }
                handleClientOrServerConnectionError(connection: $0, error: $1)
            }
            _ = try await connection.sendMessage(request: PingRequest())
            self.connection = connection
            self.stateSubject.send(.connected)
            Self.logger.info("Ping server successfully")
        }
    }
}

// MARK: - RuntimeXPCServerConnection

/// XPC server connection for the service provider side.
///
/// Use this in a separate process (such as Mac Catalyst helper) that provides
/// runtime inspection services to the main application.
///
/// ## Initialization Flow
///
/// 1. Connects to the XPC Mach service (privileged helper)
/// 2. Fetches the client's endpoint from the broker
/// 3. Establishes direct connection to the client
/// 4. Registers its own endpoint for bidirectional communication
/// 5. Notifies the client via `serverLaunched` message
///
/// ## Usage
///
/// ```swift
/// let server = try await RuntimeXPCServerConnection(
///     identifier: .macCatalyst,
///     modifier: { connection in
///         // Register message handlers
///         connection.setMessageHandler(requestType: GetRuntimeInfoRequest.self) { request in
///             return GetRuntimeInfoResponse(info: ...)
///         }
///     }
/// )
/// ```
final class RuntimeXPCServerConnection: RuntimeXPCConnection, @unchecked Sendable {
    override init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modifier: modifier)
        let response = try await serviceConnection.sendMessage(request: FetchEndpointRequest(identifier: identifier.rawValue))
        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(response.endpoint))
        connection.activate()
        connection.errorHandler = { [weak self] in
            guard let self else { return }
            handleClientOrServerConnectionError(connection: $0, error: $1)
        }
        try await serviceConnection.sendMessage(request: RegisterEndpointRequest(identifier: identifier.rawValue, endpoint: listener.endpoint))
        try await connection.sendMessage(name: CommandIdentifiers.serverLaunched, request: listener.endpoint)
        self.connection = connection
        stateSubject.send(.connected)
        Self.logger.info("Ping client successfully")
    }
}

#endif

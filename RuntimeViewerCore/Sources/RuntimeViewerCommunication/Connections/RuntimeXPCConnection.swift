#if os(macOS)

import Foundation
import SwiftyXPC
import Logging

class RuntimeXPCConnection: RuntimeConnection {
    fileprivate let identifier: RuntimeSource.Identifier

    fileprivate let listener: SwiftyXPC.XPCListener

    fileprivate let serviceConnection: SwiftyXPC.XPCConnection

    fileprivate var connection: SwiftyXPC.XPCConnection?

    fileprivate static let logger = Logger(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeXPCConnection")

    fileprivate var logger: Logger { Self.logger }
    
    init(identifier: RuntimeSource.Identifier, modify: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
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
        try await modify?(self)

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
        logger.error("\(connection) \(error)")
    }

    func handleListenerError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        logger.error("\(connection) \(error)")
    }

    func handleClientOrServerConnectionError(connection: SwiftyXPC.XPCConnection, error: any Swift.Error) {
        logger.error("\(connection) \(error)")
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

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type = Request.self, handler: @escaping (Request) async throws -> Request.Response) {
        listener.setMessageHandler(name: Request.identifier) { connection, request in
            try await handler(request)
        }
    }

    func setMessageHandler<Request, Response>(name: String, handler: @escaping (Request) async throws -> Response) where Request: Decodable, Request: Encodable, Response: Decodable, Response: Encodable {
        listener.setMessageHandler(name: name) { (_: XPCConnection, request: Request) in
            try await handler(request)
        }
    }

    func setMessageHandler(name: String, handler: @escaping () async throws -> Void) {
        listener.setMessageHandler(name: name) { (_: XPCConnection) in
            try await handler()
        }
    }

    func setMessageHandler<Request>(name: String, handler: @escaping (Request) async throws -> Void) where Request: Decodable, Request: Encodable {
        listener.setMessageHandler(name: name) { (_: XPCConnection, request: Request) in
            try await handler(request)
        }
    }

    func setMessageHandler<Response>(name: String, handler: @escaping () async throws -> Response) where Response: Decodable, Response: Encodable {
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

final class RuntimeXPCClientConnection: RuntimeXPCConnection {
    override init(identifier: RuntimeSource.Identifier, modify: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modify: modify)
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
            Self.logger.info("Ping server successfully")
        }
    }
}

final class RuntimeXPCServerConnection: RuntimeXPCConnection {
    override init(identifier: RuntimeSource.Identifier, modify: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        try await super.init(identifier: identifier, modify: modify)
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
        Self.logger.info("Ping client successfully")
    }
}

#endif

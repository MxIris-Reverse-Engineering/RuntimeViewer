import SwiftyXPC
import Foundation

public let RuntimeViewerMachServiceName = "com.JH.RuntimeViewerService"

public protocol RequestType: Codable {
    associatedtype Response: ResponseType

    static var identifier: String { get }
}

public protocol ResponseType: Codable {}

public struct VoidResponse: ResponseType, Codable {
    public init() {}

    public static var empty: VoidResponse { VoidResponse() }
}

public protocol RuntimeConnection {
    func sendMessage<Request: Codable, Response: Codable>(name: String, request: Request) async throws -> Response
}

public protocol RuntimeListener {
    func setMessageHandler<Request: Codable, Response: Codable>(
        name: String,
        handler: @escaping (Request) async throws -> Response
    )
}

public protocol RuntimeEndpoint {
    
}

extension XPCConnection {
    @discardableResult
    public func sendMessage<Request: RequestType>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: type(of: request).identifier, request: request)
    }
}

extension SwiftyXPC.XPCListener {
    public func setMessageHandler<Request: RequestType>(
        requestType: Request.Type = Request.self,
        handler: @escaping (XPCConnection, Request) async throws -> Request.Response
    ) {
        setMessageHandler(name: Request.identifier) { connection, request in
            try await handler(connection, request)
        }
    }
}

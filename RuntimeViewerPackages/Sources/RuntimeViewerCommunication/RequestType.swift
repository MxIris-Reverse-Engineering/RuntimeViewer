import Foundation
import SwiftyXPC

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

public struct RegisterEndpointRequest: Codable, RequestType {
    public static let identifier: String = "com.JH.RuntimeViewerService.RegisterEndpoint"

    public typealias Response = VoidResponse

    public let identifier: String

    public let endpoint: XPCEndpoint

    public init(identifier: String, endpoint: XPCEndpoint) {
        self.identifier = identifier
        self.endpoint = endpoint
    }
}

public struct FetchEndpointRequest: Codable, RequestType {
    public static let identifier: String = "com.JH.RuntimeViewerService.FetchEndpoint"

    public struct Response: ResponseType, Codable {
        public let endpoint: XPCEndpoint

        public init(endpoint: XPCEndpoint) {
            self.endpoint = endpoint
        }
    }

    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public struct LaunchCatalystHelperRequest: Codable, RequestType {
    public static let identifier: String = "com.JH.RuntimeViewerService.LaunchCatalystHelper"

    public typealias Response = VoidResponse

    public let helperURL: URL

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }
}

public struct PingRequest: Codable, RequestType {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.RuntimeViewerService.Ping"

    public init() {}
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
            return try await handler(connection, request)
        }
    }
}

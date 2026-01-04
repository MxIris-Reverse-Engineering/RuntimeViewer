import Foundation

public protocol RuntimeConnection {
    func sendMessage(name: String) async throws
    func sendMessage<Request: Codable>(name: String, request: Request) async throws
    func sendMessage<Response: Codable>(name: String) async throws -> Response
    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response
    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response

    func setMessageHandler(name: String, handler: @escaping () async throws -> Void)
    func setMessageHandler<Request: Codable>(name: String, handler: @escaping (Request) async throws -> Void)
    func setMessageHandler<Response: Codable>(name: String, handler: @escaping () async throws -> Response)
    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: @escaping (Request) async throws -> Request.Response)
    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping (Request) async throws -> Response)
}

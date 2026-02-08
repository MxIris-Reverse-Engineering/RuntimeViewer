import Foundation
import RuntimeViewerMCPShared

/// High-level typed API for calling MCP bridge commands.
final class MCPBridgeClient: Sendable {
    private let connection: MCPBridgeConnection

    init(connection: MCPBridgeConnection) {
        self.connection = connection
    }

    static func connectFromPortFile() async throws -> MCPBridgeClient {
        let connection = try await MCPBridgeConnection.connectFromPortFile()
        return MCPBridgeClient(connection: connection)
    }

    func listWindows() async throws -> MCPListWindowsResponse {
        struct Empty: Codable {}
        return try await connection.sendRequest(command: .listWindows, payload: Empty())
    }

    func selectedType(windowIdentifier: String) async throws -> MCPSelectedTypeResponse {
        let request = MCPSelectedTypeRequest(windowIdentifier: windowIdentifier)
        return try await connection.sendRequest(command: .selectedType, payload: request)
    }

    func typeInterface(windowIdentifier: String, imagePath: String, typeName: String) async throws -> MCPTypeInterfaceResponse {
        let request = MCPTypeInterfaceRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, typeName: typeName)
        return try await connection.sendRequest(command: .typeInterface, payload: request)
    }

    func listTypes(windowIdentifier: String, imagePath: String) async throws -> MCPListTypesResponse {
        let request = MCPListTypesRequest(windowIdentifier: windowIdentifier, imagePath: imagePath)
        return try await connection.sendRequest(command: .listTypes, payload: request)
    }

    func searchTypes(windowIdentifier: String, query: String, imagePath: String?) async throws -> MCPSearchTypesResponse {
        let request = MCPSearchTypesRequest(windowIdentifier: windowIdentifier, query: query, imagePath: imagePath)
        return try await connection.sendRequest(command: .searchTypes, payload: request)
    }

    func grepTypeInterface(windowIdentifier: String, imagePath: String, pattern: String) async throws -> MCPGrepTypeInterfaceResponse {
        let request = MCPGrepTypeInterfaceRequest(windowIdentifier: windowIdentifier, imagePath: imagePath, pattern: pattern)
        return try await connection.sendRequest(command: .grepTypeInterface, payload: request)
    }

    func stop() {
        connection.stop()
    }
}

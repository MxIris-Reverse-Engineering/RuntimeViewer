import Foundation
import Network
import RuntimeViewerMCPShared

final class MCPBridgeClient: Sendable {
    private let connection: NWConnection

    init(host: String, port: UInt16) async throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false

            connection.stateUpdateHandler = { state in
                guard !didResume else { return }
                switch state {
                case .ready:
                    didResume = true
                    continuation.resume()
                case .failed(let error):
                    didResume = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    didResume = true
                    continuation.resume(throwing: MCPBridgeTransportError.connectionClosed)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: MCPBridgeTransportError.timeout)
            }
        }
    }

    static func connectFromPortFile() async throws -> MCPBridgeClient {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let portFile = appSupportURL
            .appendingPathComponent("RuntimeViewer")
            .appendingPathComponent("mcp-bridge-port")

        guard FileManager.default.fileExists(atPath: portFile.path) else {
            throw MCPBridgeTransportError.serverNotRunning
        }

        let portString = try String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(portString) else {
            throw MCPBridgeTransportError.serverNotRunning
        }

        return try await MCPBridgeClient(host: "127.0.0.1", port: port)
    }

    func sendRequest<Response: Decodable>(
        command: MCPBridgeCommand,
        payload: some Encodable
    ) async throws -> Response {
        let envelope = try MCPBridgeEnvelope(identifier: command.rawValue, value: payload)
        let requestJSON = try JSONEncoder().encode(envelope)
        try await MCPBridgeFrame.send(requestJSON, on: connection)

        let responseData = try await MCPBridgeFrame.receive(from: connection)
        let responseEnvelope = try JSONDecoder().decode(MCPBridgeResponseEnvelope.self, from: responseData)
        return try JSONDecoder().decode(Response.self, from: responseEnvelope.payload)
    }

    func getSelectedType() async throws -> MCPGetSelectedTypeResponse {
        // Send an empty payload for getSelectedType
        struct Empty: Codable {}
        return try await sendRequest(command: .getSelectedType, payload: Empty())
    }

    func getTypeInterface(imagePath: String, typeName: String) async throws -> MCPGetTypeInterfaceResponse {
        let request = MCPGetTypeInterfaceRequest(imagePath: imagePath, typeName: typeName)
        return try await sendRequest(command: .getTypeInterface, payload: request)
    }

    func stop() {
        connection.cancel()
    }
}

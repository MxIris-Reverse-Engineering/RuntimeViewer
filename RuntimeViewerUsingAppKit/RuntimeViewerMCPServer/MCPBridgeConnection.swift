import Foundation
import Network
import os
import RuntimeViewerMCPShared

/// Handles TCP connection lifecycle, port file discovery, and frame-level I/O.
final class MCPBridgeConnection: Sendable {
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
            let didResume = OSAllocatedUnfairLock(initialState: false)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let alreadyResumed = didResume.withLock { resumed -> Bool in
                        if resumed { return true }
                        resumed = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume()
                case .failed(let error):
                    let alreadyResumed = didResume.withLock { resumed -> Bool in
                        if resumed { return true }
                        resumed = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    let alreadyResumed = didResume.withLock { resumed -> Bool in
                        if resumed { return true }
                        resumed = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    let alreadyResumed = didResume.withLock { resumed -> Bool in
                        if resumed { return true }
                        resumed = true
                        return false
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(throwing: MCPBridgeTransportError.connectionClosed)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                let alreadyResumed = didResume.withLock { resumed -> Bool in
                    if resumed { return true }
                    resumed = true
                    return false
                }
                guard !alreadyResumed else { return }
                continuation.resume(throwing: MCPBridgeTransportError.timeout)
            }
        }
    }

    static func connectFromPortFile() async throws -> MCPBridgeConnection {
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

        return try await MCPBridgeConnection(host: "127.0.0.1", port: port)
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

    func stop() {
        connection.cancel()
    }
}

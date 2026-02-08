import Foundation
import Network
import RuntimeViewerMCPShared
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Listener")

/// Handles TCP listener setup, connection management, and frame-level I/O.
/// Delegates request processing to a handler closure.
final class MCPBridgeListener: @unchecked Sendable {
    private let listener: NWListener
    private let portFilePath: String

    // Set once via start(), never mutated after
    private var requestHandler: (@Sendable (MCPBridgeEnvelope) async throws -> Data)?

    let port: UInt16

    init(port: UInt16 = 0) throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        if port == 0 {
            self.listener = try NWListener(using: parameters)
        } else {
            self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        }

        // Determine port file path
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeViewerDir = appSupportURL.appendingPathComponent("RuntimeViewer")
        try FileManager.default.createDirectory(at: runtimeViewerDir, withIntermediateDirectories: true)
        self.portFilePath = runtimeViewerDir.appendingPathComponent("mcp-bridge-port").path

        // Temporarily store 0, will be updated when listener becomes ready
        self.port = 0
    }

    func start(requestHandler: @escaping @Sendable (MCPBridgeEnvelope) async throws -> Data) {
        self.requestHandler = requestHandler
        setupListener()
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Listener Setup

    private func setupListener() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port {
                    logger.info("MCP Bridge server listening on port \(port.rawValue)")
                    self.writePortFile(port: port.rawValue)
                }
            case .failed(let error):
                logger.error("MCP Bridge server listener failed: \(error)")
            case .cancelled:
                logger.info("MCP Bridge server listener cancelled")
                self.removePortFile()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            logger.info("MCP Bridge accepted new connection")
            self.handleConnection(connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("MCP Bridge connection ready")
            case .failed(let error):
                logger.error("MCP Bridge connection failed: \(error)")
            case .cancelled:
                logger.info("MCP Bridge connection cancelled")
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(connection: connection)
    }

    private func receiveLoop(connection: NWConnection) {
        Task {
            do {
                while true {
                    let requestData = try await MCPBridgeFrame.receive(from: connection)
                    let envelope = try JSONDecoder().decode(MCPBridgeEnvelope.self, from: requestData)
                    let responseData = try await requestHandler!(envelope)
                    let responseEnvelope = MCPBridgeResponseEnvelope(payload: responseData)
                    let responseJSON = try JSONEncoder().encode(responseEnvelope)
                    try await MCPBridgeFrame.send(responseJSON, on: connection)
                }
            } catch {
                if case MCPBridgeTransportError.connectionClosed = error {
                    logger.info("MCP Bridge client disconnected")
                } else {
                    logger.error("MCP Bridge error: \(error)")
                }
                connection.cancel()
            }
        }
    }

    // MARK: - Port File

    private func writePortFile(port: UInt16) {
        do {
            try "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
            logger.info("Wrote MCP bridge port \(port) to \(self.portFilePath)")
        } catch {
            logger.error("Failed to write port file: \(error)")
        }
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    deinit {
        stop()
    }
}

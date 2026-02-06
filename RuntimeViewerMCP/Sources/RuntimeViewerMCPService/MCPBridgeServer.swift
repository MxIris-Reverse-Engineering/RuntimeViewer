import Foundation
import Network
import RuntimeViewerCore
import RuntimeViewerMCPShared
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Server")

public final class MCPBridgeServer: Sendable {
    private let listener: NWListener
    private let delegate: MCPBridgeDelegate
    private let portFilePath: String

    public let port: UInt16

    public init(delegate: MCPBridgeDelegate, port: UInt16 = 0) throws {
        self.delegate = delegate

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

        setupListener()
    }

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
            while connection.state == .ready || connection.state == .preparing {
                do {
                    let requestData = try await MCPBridgeFrame.receive(from: connection)
                    let envelope = try JSONDecoder().decode(MCPBridgeEnvelope.self, from: requestData)
                    let responseData = try await processRequest(envelope)
                    let responseEnvelope = MCPBridgeResponseEnvelope(payload: responseData)
                    let responseJSON = try JSONEncoder().encode(responseEnvelope)
                    try await MCPBridgeFrame.send(responseJSON, on: connection)
                } catch {
                    if case MCPBridgeTransportError.connectionClosed = error {
                        logger.info("MCP Bridge client disconnected")
                    } else {
                        logger.error("MCP Bridge error: \(error)")
                    }
                    return
                }
            }
        }
    }

    private func processRequest(_ envelope: MCPBridgeEnvelope) async throws -> Data {
        guard let command = MCPBridgeCommand(rawValue: envelope.identifier) else {
            throw MCPBridgeTransportError.decodingFailed
        }

        switch command {
        case .getSelectedType:
            let response = await handleGetSelectedType()
            return try JSONEncoder().encode(response)

        case .getTypeInterface:
            let request = try envelope.decode(MCPGetTypeInterfaceRequest.self)
            let response = await handleGetTypeInterface(request)
            return try JSONEncoder().encode(response)
        }
    }

    private func handleGetSelectedType() async -> MCPGetSelectedTypeResponse {
        guard let runtimeObject = await delegate.selectedRuntimeObject() else {
            return MCPGetSelectedTypeResponse(
                imagePath: nil,
                typeName: nil,
                displayName: nil,
                typeKind: nil,
                interfaceText: nil
            )
        }

        let engine = await delegate.runtimeEngine()
        let options = await delegate.generationOptions()

        do {
            let interface = try await engine.interface(for: runtimeObject, options: options)
            return MCPGetSelectedTypeResponse(
                imagePath: runtimeObject.imagePath,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: interface?.interfaceString.string
            )
        } catch {
            logger.error("Failed to generate interface for selected type: \(error)")
            return MCPGetSelectedTypeResponse(
                imagePath: runtimeObject.imagePath,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: nil
            )
        }
    }

    private func handleGetTypeInterface(_ request: MCPGetTypeInterfaceRequest) async -> MCPGetTypeInterfaceResponse {
        let engine = await delegate.runtimeEngine()
        let options = await delegate.generationOptions()

        do {
            let objects = try await engine.objects(in: request.imagePath)
            guard let runtimeObject = findObject(named: request.typeName, in: objects) else {
                return MCPGetTypeInterfaceResponse(
                    imagePath: request.imagePath,
                    typeName: request.typeName,
                    displayName: nil,
                    typeKind: nil,
                    interfaceText: nil,
                    error: "Type '\(request.typeName)' not found in image '\(request.imagePath)'"
                )
            }

            let interface = try await engine.interface(for: runtimeObject, options: options)
            return MCPGetTypeInterfaceResponse(
                imagePath: runtimeObject.imagePath,
                typeName: runtimeObject.name,
                displayName: runtimeObject.displayName,
                typeKind: runtimeObject.kind.description,
                interfaceText: interface?.interfaceString.string,
                error: nil
            )
        } catch {
            return MCPGetTypeInterfaceResponse(
                imagePath: request.imagePath,
                typeName: request.typeName,
                displayName: nil,
                typeKind: nil,
                interfaceText: nil,
                error: error.localizedDescription
            )
        }
    }

    private func findObject(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        for obj in objects {
            if obj.name == name || obj.displayName == name {
                return obj
            }
            if let found = findObject(named: name, in: obj.children) {
                return found
            }
        }
        return nil
    }

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

    public func stop() {
        listener.cancel()
    }

    deinit {
        stop()
    }
}

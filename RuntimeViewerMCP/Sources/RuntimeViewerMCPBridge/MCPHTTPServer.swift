import Foundation
import HTTPTypes
import Hummingbird
import MCP
import NIOCore
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "HTTPServer")

public actor MCPHTTPServer {
    private let bridgeServer: MCPBridgeServer
    private let toolRegistry: MCPToolRegistry
    private var serverTask: Task<Void, any Error>?
    private var cleanupTask: Task<Void, Never>?
    private var sessions: [String: SessionContext] = [:]
    private var port: UInt16 = 0

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    private let portFilePath: String

    public init(bridgeServer: MCPBridgeServer) throws {
        self.bridgeServer = bridgeServer
        self.toolRegistry = MCPToolRegistry(bridgeServer: bridgeServer)
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeViewerDir = appSupportURL.appendingPathComponent("RuntimeViewer")
        try FileManager.default.createDirectory(at: runtimeViewerDir, withIntermediateDirectories: true)
        self.portFilePath = runtimeViewerDir.appendingPathComponent("mcp-http-port").path
    }

    // MARK: - Lifecycle

    public func start(port requestedPort: UInt16 = 0) async throws {
        let router = Router()
        let httpServer = self

        router.post("/mcp") { request, _ -> Response in
            try await httpServer.handleMCPRoute(request)
        }

        router.get("/mcp") { request, _ -> Response in
            try await httpServer.handleMCPRoute(request)
        }

        router.delete("/mcp") { request, _ -> Response in
            try await httpServer.handleMCPRoute(request)
        }

        let (portStream, portContinuation) = AsyncStream<Int>.makeStream()

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: Int(requestedPort))),
            onServerRunning: { channel in
                let port = channel.localAddress?.port ?? 0
                portContinuation.yield(port)
                portContinuation.finish()
            }
        )

        self.serverTask = Task.detached {
            try await app.runService()
        }

        if let resolvedPort = await portStream.first(where: { _ in true }) {
            self.port = UInt16(resolvedPort)
            writePortFile(port: self.port)
            logger.info("MCP HTTP server listening on port \(self.port)")
        }

        cleanupTask = Task { await sessionCleanupLoop() }
    }

    public nonisolated func stop() {
        Task { await performStop() }
    }

    private func performStop() {
        serverTask?.cancel()
        serverTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        removePortFile()
        logger.info("MCP HTTP server stopped")
    }

    // MARK: - HTTP Route Handler

    private func handleMCPRoute(_ request: Request) async throws -> Response {
        let mcpRequest = try await convertToMCPRequest(request)
        let mcpResponse = await handleHTTPRequest(mcpRequest)
        return convertToHBResponse(mcpResponse)
    }

    // MARK: - Session Routing

    private func handleHTTPRequest(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        let sessionID = request.header(MCP.HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)

            // Clean up on successful DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }

        // No session and not initialize
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(MCP.HTTPHeaderName.sessionID) header")
        )
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID)
        )

        let server = Server(
            name: "RuntimeViewer",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await toolRegistry.registerTools(on: server)

        do {
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func sessionCleanupLoop() async {
        let timeout: TimeInterval = 3600
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            let expired = sessions.filter { now.timeIntervalSince($0.value.lastAccessedAt) > timeout }
            for (sessionID, session) in expired {
                logger.info("Session expired: \(sessionID)")
                await session.transport.disconnect()
                sessions.removeValue(forKey: sessionID)
            }
        }
    }

    // MARK: - Request/Response Conversion

    private func convertToMCPRequest(_ request: Request) async throws -> MCP.HTTPRequest {
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.rawName] = field.value
        }

        let bodyBuffer = try await request.body.collect(upTo: 10_000_000)
        let bodyData: Data?
        if bodyBuffer.readableBytes > 0 {
            bodyData = bodyBuffer.withUnsafeReadableBytes { Data($0) }
        } else {
            bodyData = nil
        }

        return MCP.HTTPRequest(
            method: request.method.rawValue,
            headers: headers,
            body: bodyData
        )
    }

    private func convertToHBResponse(_ mcpResponse: MCP.HTTPResponse) -> Response {
        var hbHeaders = HTTPFields()
        for (key, value) in mcpResponse.headers {
            guard let fieldName = HTTPField.Name(key) else { continue }
            hbHeaders.append(HTTPField(name: fieldName, value: value))
        }

        switch mcpResponse {
        case .stream(let sseStream, _):
            let mappedStream = sseStream.map { data -> ByteBuffer in
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                return buffer
            }
            return Response(
                status: .init(code: mcpResponse.statusCode),
                headers: hbHeaders,
                body: .init(asyncSequence: mappedStream)
            )

        default:
            if let bodyData = mcpResponse.bodyData {
                var buffer = ByteBufferAllocator().buffer(capacity: bodyData.count)
                buffer.writeBytes(bodyData)
                return Response(
                    status: .init(code: mcpResponse.statusCode),
                    headers: hbHeaders,
                    body: .init(byteBuffer: buffer)
                )
            } else {
                return Response(
                    status: .init(code: mcpResponse.statusCode),
                    headers: hbHeaders
                )
            }
        }
    }

    // MARK: - Helpers

    private func isInitializeRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else { return false }
        return method == "initialize"
    }

    private func writePortFile(port: UInt16) {
        do {
            try "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
            logger.info("Wrote MCP HTTP port \(port) to \(self.portFilePath)")
        } catch {
            logger.error("Failed to write port file: \(error)")
        }
    }

    private nonisolated func removePortFile() {
        try? FileManager.default.removeItem(atPath: portFilePath)
    }
}

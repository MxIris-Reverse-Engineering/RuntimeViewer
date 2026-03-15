import Foundation
import FoundationToolbox
import Dependencies
import SwiftNavigation
import RuntimeViewerSettings
import SwiftMCP
import OSLog

private let logger = Logger(subsystem: "com.RuntimeViewer.MCPBridge", category: "Service")

public enum MCPServerState: Equatable, Sendable {
    case disabled
    case stopped
    case running(port: UInt16)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var port: UInt16? {
        if case .running(let port) = self { return port }
        return nil
    }
}

@MainActor
public final class MCPService {
    public static let shared = MCPService()

    @Dependency(\.settings)
    private var settings

    public private(set) var serverState: MCPServerState = .stopped {
        didSet {
            guard oldValue != serverState else { return }
            onStateChange?(serverState)
        }
    }

    public var onStateChange: ((MCPServerState) -> Void)?

    private var transport: HTTPSSETransport?

    private var transportTask: Task<Void, Never>?

    private var startTask: Task<Void, Never>?

    private var observeToken: ObserveToken?

    private var previousMCPEnabled: Bool?

    private var previousMCPUsesFixedPort: Bool?

    private var previousMCPFixedPort: UInt16?

    private var documentProvider: MCPBridgeDocumentProvider?

    private var restartTask: Task<Void, Never>?

    private let portFilePath: String

    private init() {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeViewerDir = appSupportURL.appendingPathComponent("RuntimeViewer")
        do {
            try FileManager.default.createDirectory(at: runtimeViewerDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create app support directory: \(error)")
        }
        self.portFilePath = runtimeViewerDir.appendingPathComponent(Settings.MCP.portFileName).path
    }

    isolated deinit {
        stop()
    }

    public func start(for documentProvider: some MCPBridgeDocumentProvider) {
        let mcpSettings = settings.mcp
        guard mcpSettings.isEnabled else {
            serverState = .disabled
            return
        }
        startTask = Task {
            let mcpSettings = settings.mcp
            let port: UInt16 = mcpSettings.useFixedPort ? mcpSettings.fixedPort : 0
            do {
                let mcpServer = MCPBridgeServer(documentProvider: documentProvider)
                let transport = HTTPSSETransport(server: mcpServer, host: "127.0.0.1", port: Int(port))
                self.transport = transport
                self.documentProvider = documentProvider

                // Run transport in a detached task (run() blocks on the NIO event loop)
                self.transportTask = Task.detached {
                    do {
                        try await transport.run()
                    } catch {
                        logger.error("MCP transport run failed: \(error)")
                    }
                }

                // Wait for server to bind, then write port file
                try await Task.sleep(for: .milliseconds(500))
                let boundPort = UInt16(transport.port)
                writePortFile(port: boundPort)
                logger.info("MCP HTTP+SSE server listening on port \(boundPort)")
                self.serverState = .running(port: boundPort)
            } catch {
                logger.error("Failed to start MCP server: \(error)")
                self.serverState = .stopped
            }
            // Initialize previous values before observing to avoid a spurious restart
            let currentMCP = settings.mcp
            previousMCPEnabled = currentMCP.isEnabled
            previousMCPUsesFixedPort = currentMCP.useFixedPort
            previousMCPFixedPort = currentMCP.fixedPort
            observe()
        }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        restartTask?.cancel()
        restartTask = nil
        transportTask?.cancel()
        transportTask = nil
        if let transport {
            Task.detached {
                try? await transport.stop()
            }
        }
        transport = nil
        let isEnabled = settings.mcp.isEnabled
        serverState = isEnabled ? .stopped : .disabled
        removePortFile()
        observeToken?.cancel()
        observeToken = nil
    }

    private func observe() {
        observeToken = SwiftNavigation.observe { [weak self] in
            guard let self else { return }
            let mcpSettings = settings.mcp
            let isMCPEnabled = mcpSettings.isEnabled
            let isUsesFixedPort = mcpSettings.useFixedPort
            let fixedPort = mcpSettings.fixedPort

            let enabledChanged = isMCPEnabled != previousMCPEnabled
            let portChanged = isUsesFixedPort != previousMCPUsesFixedPort || fixedPort != previousMCPFixedPort

            previousMCPEnabled = isMCPEnabled
            previousMCPUsesFixedPort = isUsesFixedPort
            previousMCPFixedPort = fixedPort

            if enabledChanged || portChanged {
                if !isMCPEnabled {
                    serverState = .disabled
                }
                scheduleRestart(enabled: isMCPEnabled)
            }
        }
    }

    private func scheduleRestart(enabled: Bool) {
        restartTask?.cancel()
        restartTask = Task {
            // Debounce: wait for settings to stabilize (e.g. user typing port number)
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if enabled {
                stop()
                if let documentProvider {
                    start(for: documentProvider)
                }
            } else {
                stop()
            }
        }
    }

    // MARK: - Port File

    private func writePortFile(port: UInt16) {
        do {
            try "\(port)".write(toFile: portFilePath, atomically: true, encoding: .utf8)
            logger.info("Wrote MCP HTTP+SSE port \(port) to \(self.portFilePath)")
        } catch {
            logger.error("Failed to write port file: \(error)")
        }
    }

    private nonisolated func removePortFile() {
        do {
            try FileManager.default.removeItem(atPath: portFilePath)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File already removed, ignore
        } catch {
            logger.error("Failed to remove port file: \(error)")
        }
    }
}

import Foundation
import FoundationToolbox
import Dependencies
import SwiftNavigation
import RuntimeViewerSettings

@Loggable(.private)
@MainActor
public final class MCPService {
    @Dependency(\.settings)
    private var settings

    private var httpServer: MCPHTTPServer?

    private var observeToken: ObserveToken?

    private var previousMCPEnabled: Bool?

    private var previousMCPUsesFixedPort: Bool?

    private var previousMCPFixedPort: UInt16?

    private var windowProvider: MCPBridgeWindowProvider?
    
    public init() {}
    
    isolated deinit {
        stop()
    }

    public func start(for windowProvider: some MCPBridgeWindowProvider) {
        Task {
            let mcpSettings = settings.mcp
            let port: UInt16 = mcpSettings.useFixedPort ? mcpSettings.fixedPort : 0
            do {
                let bridgeServer = MCPBridgeServer(windowProvider: windowProvider)
                let httpServer = try MCPHTTPServer(bridgeServer: bridgeServer)
                self.httpServer = httpServer
                try await httpServer.start(port: port)
                self.windowProvider = windowProvider
            } catch {
                #log(.error, "Failed to start MCP HTTP Server: \(error, privacy: .public)")
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
        httpServer?.stop()
        httpServer = nil
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
                if isMCPEnabled {
                    stop()
                    if let windowProvider {
                        start(for: windowProvider)
                    }
                } else {
                    stop()
                }
            }
        }
    }
}

import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import RuntimeViewerSettingsUI
import RuntimeViewerArchitectures
import RuntimeViewerMCPBridge

@Loggable
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mcpHTTPServer: MCPHTTPServer?

    @Dependency(\.settings)
    private var settings

    private var previousMCPEnabled: Bool?
    private var previousMCPUseFixedPort: Bool?
    private var previousMCPFixedPort: UInt16?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        observe {
            switch self.settings.general.appearance {
            case .system:
                NSApp.appearance = nil
            case .dark:
                NSApp.appearance = .init(named: .darkAqua)
            case .light:
                NSApp.appearance = .init(named: .aqua)
            }
        }

        observe { [weak self] in
            guard let self else { return }
            let mcpSettings = settings.mcp
            let enabled = mcpSettings.isEnabled
            let useFixedPort = mcpSettings.useFixedPort
            let fixedPort = mcpSettings.fixedPort

            let enabledChanged = enabled != previousMCPEnabled
            let portChanged = useFixedPort != previousMCPUseFixedPort || fixedPort != previousMCPFixedPort

            previousMCPEnabled = enabled
            previousMCPUseFixedPort = useFixedPort
            previousMCPFixedPort = fixedPort

            if enabledChanged || portChanged {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if enabled {
                        stopMCPHTTPServer()
                        startMCPHTTPServer()
                    } else {
                        stopMCPHTTPServer()
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        stopMCPHTTPServer()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @IBAction func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    private func startMCPHTTPServer() {
        let mcpSettings = settings.mcp
        let port: UInt16 = mcpSettings.useFixedPort ? mcpSettings.fixedPort : 0
        Task { @MainActor in
            do {
                let windowProvider = AppMCPBridgeWindowProvider()
                let bridgeServer = MCPBridgeServer(windowProvider: windowProvider)
                let httpServer = try MCPHTTPServer(bridgeServer: bridgeServer)
                mcpHTTPServer = httpServer
                try await httpServer.start(port: port)
            } catch {
                #log(.error, "Failed to start MCP HTTP Server: \(error, privacy: .public)")
            }
        }
    }

    private func stopMCPHTTPServer() {
        mcpHTTPServer?.stop()
        mcpHTTPServer = nil
    }
}

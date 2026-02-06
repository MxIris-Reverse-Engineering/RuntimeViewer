import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import RuntimeViewerSettingsUI
import RuntimeViewerArchitectures

#if canImport(RuntimeViewerMCPService)
import RuntimeViewerMCPService
#endif

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if canImport(RuntimeViewerMCPService)
    private var mcpBridgeServer: MCPBridgeServer?
    #endif

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        @Dependency(\.settings)
        var settings

        observe {
            switch settings.general.appearance {
            case .system:
                NSApp.appearance = nil
            case .dark:
                NSApp.appearance = .init(named: .darkAqua)
            case .light:
                NSApp.appearance = .init(named: .aqua)
            }
        }

        #if canImport(RuntimeViewerMCPService)
        startMCPBridgeServer()
        #endif
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        #if canImport(RuntimeViewerMCPService)
        mcpBridgeServer?.stop()
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @IBAction func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    #if canImport(RuntimeViewerMCPService)
    private func startMCPBridgeServer() {
        do {
            let bridgeDelegate = AppMCPBridgeDelegate()
            let server = try MCPBridgeServer(delegate: bridgeDelegate)
            self.mcpBridgeServer = server
        } catch {
            NSLog("Failed to start MCP Bridge Server: \(error)")
        }
    }
    #endif
}

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
    private var mcpBridgeServer: MCPBridgeServer?

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

        startMCPBridgeServer()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        mcpBridgeServer?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @IBAction func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    private func startMCPBridgeServer() {
        Task { @MainActor in
            do {
                let windowProvider = AppMCPBridgeWindowProvider()
                let server = try MCPBridgeServer(windowProvider: windowProvider)
                mcpBridgeServer = server
                await server.start()
            } catch {
                #log(.error, "Failed to start MCP Bridge Server: \(error, privacy: .public)")
            }
        }
    }
}

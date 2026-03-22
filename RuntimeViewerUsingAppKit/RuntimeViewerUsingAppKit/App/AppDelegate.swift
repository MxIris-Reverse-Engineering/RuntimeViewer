import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import RuntimeViewerSettingsUI
import RuntimeViewerArchitectures
import RuntimeViewerMCPBridge

@Loggable(.private)
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    @Dependency(\.settings)
    private var settings

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        observe { [weak self] in
            guard let self else { return }
            switch settings.general.appearance {
            case .system:
                NSApp.appearance = nil
            case .dark:
                NSApp.appearance = .init(named: .darkAqua)
            case .light:
                NSApp.appearance = .init(named: .aqua)
            }
        }

        MCPService.shared.start(for: AppMCPBridgeDocumentProvider())
        installDebugMenu()
    }

    private func installDebugMenu() {
        let debugMenu = NSMenu(title: "Debug")
        let exportLogsItem = NSMenuItem(title: "Export Logs…", action: #selector(exportLogs), keyEquivalent: "")
        exportLogsItem.target = self
        debugMenu.addItem(exportLogsItem)

        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = debugMenu
        NSApp.mainMenu?.addItem(debugMenuItem)
    }

    @objc private func exportLogs() {
        RuntimeEngineManager.shared.exportLogs()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPService.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @IBAction func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }
}

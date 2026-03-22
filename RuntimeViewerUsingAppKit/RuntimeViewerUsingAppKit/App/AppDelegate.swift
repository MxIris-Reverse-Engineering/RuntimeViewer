import AppKit
import FoundationToolbox
import OSLog
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
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceEnd: -3600)
            let entries = try store.getEntries(at: position)

            var content = ""
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"

            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                content.append("[\(formatter.string(from: logEntry.date))] [\(logEntry.subsystem)/\(logEntry.category)] \(logEntry.composedMessage)\n")
            }

            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/RuntimeViewer")
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logFile = logDir.appendingPathComponent("mirror-debug.log")
            try content.write(to: logFile, atomically: true, encoding: .utf8)
            NSWorkspace.shared.selectFile(logFile.path, inFileViewerRootedAtPath: logDir.path)
        } catch {
            #log(.error, "Failed to export logs: \(error, privacy: .public)")
        }
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

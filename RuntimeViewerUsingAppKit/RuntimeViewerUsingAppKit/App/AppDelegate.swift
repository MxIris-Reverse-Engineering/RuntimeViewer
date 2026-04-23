import AppKit
import FoundationToolbox
import OSLog
import ServiceManagement
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import RuntimeViewerSettingsUI
import RuntimeViewerArchitectures
import RuntimeViewerMCPBridge
import RuntimeViewerHelperClient

@Loggable(.private)
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    @Dependency(\.settings)
    private var settings

    static let launchDate = Date()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        _ = Self.launchDate
        
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
        UpdaterService.shared.start()
        installDebugMenu()
        checkHelperServiceVersion()
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
        let key = "ExportLogsLastFileName"
        let savePanel = NSSavePanel()
        if let fileName = UserDefaults.standard.string(forKey: key) {
            savePanel.nameFieldStringValue = fileName
        }
        let result = savePanel.runModal()
        guard result == .OK, let url = savePanel.url else { return }
        UserDefaults.standard.set(savePanel.nameFieldStringValue, forKey: key)
        Task.detached {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(date: Self.launchDate)
                let entries = try store.getEntries(at: position)

                var content = ""
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"

                for entry in entries {
                    guard let logEntry = entry as? OSLogEntryLog, logEntry.subsystem.contains("RuntimeViewer") else { continue }
                    content.append("[\(formatter.string(from: logEntry.date))] [\(logEntry.subsystem)/\(logEntry.category)] \(logEntry.composedMessage)\n")
                }

                try content.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                #log(.error, "Failed to export logs: \(error, privacy: .public)")
            }
        }
    }

    private func checkHelperServiceVersion() {
        Task { @MainActor in
            let result = await HelperServiceManager.shared.checkServiceVersionAndReinstallIfNeeded()
            switch result {
            case .reinstalled:
                let alert = NSAlert()
                alert.messageText = "Helper Service Updated"
                alert.informativeText = "The helper service has been reinstalled due to a version mismatch. Please restart the application for the changes to take effect."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Restart Now")
                alert.addButton(withTitle: "Later")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    relaunchApplication()
                }
            case .reinstallFailed(let error):
                let alert = NSAlert()
                alert.messageText = "Helper Service Reinstall Failed"
                alert.informativeText = "The helper service needs to be reinstalled due to a version mismatch, but the reinstall failed: \(error.localizedDescription)\n\nYou can try again from Settings > Helper Service."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Dismiss")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    SMAppService.openSystemSettingsLoginItems()
                }
            case .versionQueryFailed(let error):
                // Transient XPC error — do NOT unregister/reinstall. Just log and move on;
                // the next launch (or a user-initiated reinstall from Settings) can retry.
                #log(.info, "Helper service version query failed transiently, skipping automatic reinstall: \(error.localizedDescription, privacy: .public)")
            case .upToDate, .mismatchButNotEnabled:
                break
            }
        }
    }

    private func relaunchApplication() {
        let executableURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: executableURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdaterService.shared.stop()
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

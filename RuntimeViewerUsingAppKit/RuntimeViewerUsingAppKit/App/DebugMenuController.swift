import AppKit
import FoundationToolbox
import OSLog
import RuntimeViewerArchitectures

@MainActor
@Loggable(.private)
final class DebugMenuController: NSObject {
    fileprivate static let shared = DebugMenuController()

    /// Captured the first time the controller is touched (typically `install()`),
    /// then used by the Export Logs flow to bound the OSLogStore query window
    /// to this app session.
    static let launchDate = Date()

    private static let exportLogsLastFileNameDefaultsKey = "ExportLogsLastFileName"

    private override init() { super.init() }

    func install() {
        _ = Self.launchDate

        let debugMenu = NSMenu(title: "Debug")
        let exportLogsItem = NSMenuItem(title: "Export Logs…", action: #selector(exportLogs), keyEquivalent: "")
        exportLogsItem.target = self
        debugMenu.addItem(exportLogsItem)

        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = debugMenu
        NSApp.mainMenu?.addItem(debugMenuItem)
    }

    @objc private func exportLogs() {
        let savePanel = NSSavePanel()
        if let fileName = UserDefaults.standard.string(forKey: Self.exportLogsLastFileNameDefaultsKey) {
            savePanel.nameFieldStringValue = fileName
        }
        let result = savePanel.runModal()
        guard result == .OK, let url = savePanel.url else { return }
        UserDefaults.standard.set(savePanel.nameFieldStringValue, forKey: Self.exportLogsLastFileNameDefaultsKey)
        Task.detached {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = await store.position(date: Self.launchDate)
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
}

// MARK: - Dependencies

private enum DebugMenuControllerKey: @preconcurrency DependencyKey {
    @MainActor static let liveValue = DebugMenuController.shared
}

extension DependencyValues {
    var debugMenuController: DebugMenuController {
        get { self[DebugMenuControllerKey.self] }
        set { self[DebugMenuControllerKey.self] = newValue }
    }
}

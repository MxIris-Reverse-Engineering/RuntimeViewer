import AppKit
import FoundationToolbox
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import DependenciesMacros

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
                let content = try await ApplicationLogs.formattedEntries(since: Self.launchDate)
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

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { DebugMenuController.shared })
    var debugMenuController: DebugMenuController
}

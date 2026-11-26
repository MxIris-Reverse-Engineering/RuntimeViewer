import AppKit
import AppKitPlus
import FoundationToolbox
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import DependenciesMacros

/// The Debug menu: Export Logs… in every build, and in a Debug build also Responder Debugger,
/// which shows AppKitPlus's responder debug panel.
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

        #if DEBUG
        debugMenu.addItem(.separator())
        // No key equivalent: ⌥⌘D, the one AppKitPlus's example app gives it, is the system's
        // shortcut for turning Dock hiding on and off and never reaches the app.
        let responderDebuggerItem = NSMenuItem(title: "Responder Debugger", action: #selector(toggleResponderDebugPanel(_:)), keyEquivalent: "")
        responderDebuggerItem.target = self
        debugMenu.addItem(responderDebuggerItem)
        #endif

        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = debugMenu
        NSApp.mainMenu?.addItem(debugMenuItem)
    }

    #if DEBUG
    /// Shows or hides the panel that traces the responder chain, the key view loop and the view
    /// under the mouse. It never becomes the key or the main window, so it can be shown over the
    /// window it describes without changing that window's first responder.
    @objc private func toggleResponderDebugPanel(_ sender: Any?) {
        let panel = NSResponderDebugPanel.shared
        if panel.isVisible {
            panel.orderOut(sender)
        } else {
            panel.orderFront(sender)
        }
    }
    #endif

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

#if DEBUG
extension DebugMenuController: NSMenuItemValidation {
    /// Ticks Responder Debugger while the panel is on screen. Reads `sharedPanelExists` first,
    /// so that opening the menu does not create the panel.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleResponderDebugPanel(_:)) {
            menuItem.state = NSResponderDebugPanel.sharedPanelExists && NSResponderDebugPanel.shared.isVisible ? .on : .off
        }
        return true
    }
}
#endif

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { DebugMenuController.shared })
    var debugMenuController: DebugMenuController
}

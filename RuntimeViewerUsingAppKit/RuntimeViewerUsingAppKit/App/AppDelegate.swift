import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerSettings
import RuntimeViewerSettingsUI
import RuntimeViewerArchitectures

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
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
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @IBAction func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }
}


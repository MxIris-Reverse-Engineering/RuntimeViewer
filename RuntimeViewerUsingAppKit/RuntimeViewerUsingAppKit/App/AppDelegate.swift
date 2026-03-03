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

    private var mcpService: MCPService?

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

        mcpService = MCPService().then {
            $0.start(for: AppMCPBridgeWindowProvider())
        }
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

extension MCPService: Then {}

import Dependencies
import DependenciesMacros
import UIFoundationSettingsUI

package final class SettingsWindowController: UIFoundationSettingsUI.SettingsWindowController {
    fileprivate static let shared = SettingsWindowController()

    private init() {
        super.init(configuration: SettingsConfiguration(sidebarIconSize: 15)) {
            SettingsPage("General", id: "general", plainSymbol: "gearshape") {
                GeneralSettingsView()
            }
            SettingsPage("Theme", id: "theme", plainSymbol: "paintpalette") {
                ThemeSettingsView()
            }
            SettingsPage("Notifications", id: "notifications", plainSymbol: "bell.badge") {
                NotificationSettingsView()
            }
            SettingsPage("Transformer", id: "transformer", plainSymbol: "arrow.triangle.2.circlepath") {
                TransformerSettingsView()
            }
            SettingsPage("Indexing", id: "indexing", plainSymbol: "square.stack.3d.down.right") {
                IndexingSettingsView()
            }
            SettingsPage("MCP", id: "mcp", plainSymbol: "network") {
                MCPSettingsView()
            }
            SettingsPage("Updates", id: "updates", plainSymbol: "arrow.down.circle") {
                UpdateSettingsView()
            }
            SettingsPage("Helper", id: "helper", plainSymbol: "wrench.and.screwdriver") {
                HelperServiceSettingsView()
            }
        }
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SettingsWindowController.shared })
    package var settingsWindowController: SettingsWindowController
}

import Foundation
import Testing

@testable import RuntimeViewerSettings

@Suite("Settings.ToolbarActivityStyle")
struct SettingsToolbarActivityStyleTests {
    @Test("a chosen style stands for itself")
    func chosenStyleResolvesToItself() {
        #expect(Settings.ToolbarActivityStyle.capsule.resolved == .capsule)
        #expect(Settings.ToolbarActivityStyle.windowTitle.resolved == .windowTitle)
    }

    @Test("automatic stands for one of the two styles")
    func automaticResolvesToAStyle() {
        #expect(Settings.ToolbarActivityStyle.automatic.resolved != .automatic)
    }

    @Test("a stored style reads back as itself", arguments: Settings.ToolbarActivityStyle.allCases)
    func storedStyleReadsBack(style: Settings.ToolbarActivityStyle) throws {
        var general = Settings.General.default
        general.toolbarActivityStyle = style
        let data = try JSONEncoder().encode(general)
        let decoded = try JSONDecoder().decode(Settings.General.self, from: data)
        #expect(decoded.toolbarActivityStyle == style)
    }

    @Test("the names written to the settings file stay the same")
    func storedNamesAreStable() {
        #expect(Settings.ToolbarActivityStyle.allCases.map(\.rawValue) == ["automatic", "capsule", "windowTitle"])
    }
}

import Foundation
import Testing

@testable import RuntimeViewerSettings

@Suite("Settings.ToolbarActivityStyle")
struct SettingsToolbarActivityStyleTests {
    @Test("a chosen style stands for itself")
    func chosenStyleResolvesToItself() {
        #expect(Settings.ToolbarActivityStyle.capsule.resolved == .capsule)
        #expect(Settings.ToolbarActivityStyle.windowTitle.resolved == .windowTitle)
        #expect(Settings.ToolbarActivityStyle.classic.resolved == .classic)
    }

    @Test("automatic stands for one of Xcode's two styles, never the classic toolbar")
    func automaticResolvesToAnXcodeStyle() {
        let resolved = Settings.ToolbarActivityStyle.automatic.resolved
        #expect(resolved == .capsule || resolved == .windowTitle)
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
        #expect(Settings.ToolbarActivityStyle.allCases.map(\.rawValue) == ["automatic", "capsule", "windowTitle", "classic"])
    }
}

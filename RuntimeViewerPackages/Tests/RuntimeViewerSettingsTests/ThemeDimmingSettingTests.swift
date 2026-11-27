import Testing
import Foundation
@testable import RuntimeViewerSettings

/// Settings › Theme's Dim Unfocused Editor Panes (proposal `dim-unfocused-editor-panes`): on by default,
/// as in Xcode, including for the settings files written before the switch existed.
@Suite("Settings.Theme dimsUnfocusedEditorPanes")
struct ThemeDimmingSettingTests {
    @Test("a theme saved before the switch existed decodes with the switch on")
    func dimsUnfocusedEditorPanesIsOnForSettingsWrittenBeforeIt() throws {
        let data = Data(
            """
            {
              "theme": {
                "selectedPresetID": "builtin.xcode",
                "fontSize": 15,
                "customPresets": []
              }
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(Settings.self, from: data)

        #expect(settings.theme.dimsUnfocusedEditorPanes)
        #expect(settings.theme.fontSize == 15, "the stored values around it are kept")
    }

    @Test("the switch turned off is saved and read back off")
    func dimsUnfocusedEditorPanesRoundTripsThroughTheSettingsFile() throws {
        var theme = Settings.Theme.default
        theme.dimsUnfocusedEditorPanes = false

        let decodedTheme = try JSONDecoder().decode(Settings.Theme.self, from: JSONEncoder().encode(theme))

        #expect(decodedTheme.dimsUnfocusedEditorPanes == false)
    }
}

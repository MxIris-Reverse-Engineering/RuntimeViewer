import Testing
import Foundation
@testable import RuntimeViewerSettings

/// The macro slot was added after presets were first saved, so a preset written before it has to
/// keep decoding — with Xcode's macro colours — and the built-in preset has to carry the colours
/// Xcode's Default themes give an SDK header's `NS_SWIFT_NAME` and `NS_REFINED_FOR_SWIFT`.
@Suite("Settings.Theme.Preset macro slot")
struct ThemePresetMacroSlotTests {
    @Test("a preset saved before the macro slot decodes, with Xcode's macro colours in it")
    func presetSavedBeforeTheSlotDecodesWithXcodesMacroColours() throws {
        var customPreset = Settings.Theme.Preset.xcode
        customPreset.macro = .solid(.rgb(0, 1, 0))
        customPreset.keyword = .solid(.rgb(1, 0, 0), bold: true)
        let encodedPreset = try JSONEncoder().encode(customPreset)
        var presetObject = try #require(JSONSerialization.jsonObject(with: encodedPreset) as? [String: Any])
        #expect(presetObject["macro"] != nil, "the slot is saved with the preset")

        presetObject.removeValue(forKey: "macro")
        let presetSavedBeforeTheSlot = try JSONSerialization.data(withJSONObject: presetObject)
        let decodedPreset = try JSONDecoder().decode(Settings.Theme.Preset.self, from: presetSavedBeforeTheSlot)

        #expect(decodedPreset.macro == .xcodeMacro)
        #expect(decodedPreset.keyword == customPreset.keyword)
    }

    /// `xcode.syntax.identifier.macro.system` in Xcode 27.2's `Default (Light).xccolortheme` and
    /// `Default (Dark).xccolortheme`, in SF Mono Regular / Medium — not the keyword's bold.
    @Test("the Xcode preset's macro slot is Xcode's macro colour pair, not bold")
    func xcodePresetCarriesXcodesMacroColours() {
        let macroStyle = Settings.Theme.Preset.xcode.macro
        #expect(macroStyle.light == .rgb(0.391471, 0.220311, 0.124457))
        #expect(macroStyle.dark == .rgb(0.991311, 0.560764, 0.246107))
        #expect(!macroStyle.isBold)
        #expect(macroStyle != Settings.Theme.Preset.xcode.keyword)
    }
}

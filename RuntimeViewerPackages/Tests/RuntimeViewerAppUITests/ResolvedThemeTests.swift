import AppKit
import Testing
import Semantic
import RuntimeViewerSettings
@testable import RuntimeViewerAppUI

/// What colour and font each semantic type is drawn in.
@Suite("ResolvedTheme")
struct ResolvedThemeTests {
    /// `NS_SWIFT_NAME` and `NS_REFINED_FOR_SWIFT` arrive as `.macro` runs; drawn in the keyword's
    /// colour they looked like `@interface` and `@end`, where Xcode draws them in its macro colour.
    @Test("a macro takes the preset's macro slot, not the keyword's")
    func macroTakesTheMacroSlot() {
        var preset = Settings.Theme.Preset.xcode
        preset.macro = .solid(.rgb(0, 0.5, 0))
        preset.keyword = .solid(.rgb(0.5, 0, 0), bold: true)
        let theme = ResolvedTheme(preset: preset, fontSize: 13)

        #expect(theme.color(for: .macro) == preset.macro.nsuiColor)
        #expect(theme.color(for: .macro) != theme.color(for: .keyword))
        #expect(theme.font(for: .macro) == theme.font(for: .standard), "regular weight, as the slot says")
    }
}

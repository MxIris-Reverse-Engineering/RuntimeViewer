import AppKit
import Foundation
import Testing
import RuntimeViewerSettings
@testable import RuntimeViewerAppUI

/// The colours an editor pane without the focus draws in: Xcode 27.2's "Dim unfocused editor panes",
/// recomputed in OKLCH (proposal `dim-unfocused-editor-panes`).
///
/// The expected components are worked out by hand from the published OKLab definition and Xcode's factors
/// (RE notes "Dimmed unfocused editor panes"): a grey `v` has OKLab lightness `∛linear(v)`, so dimming it
/// gives the grey whose linear value is `(∛linear(v) × kL)³`.
@Suite("Unfocused editor pane dimming")
struct UnfocusedEditorPaneDimmingTests {
    private static let tolerance = 1e-4

    private static func isClose(_ value: Double, to expectedValue: Double, within tolerance: Double = tolerance) -> Bool {
        abs(value - expectedValue) <= tolerance
    }

    private static func isGrey(_ color: Settings.Theme.ColorValue, of expectedComponent: Double) -> Bool {
        isClose(color.red, to: expectedComponent) && isClose(color.green, to: expectedComponent) && isClose(color.blue, to: expectedComponent)
    }

    // MARK: - OKLCH

    @Test("sRGB red has the published OKLab coordinates")
    func oklabMatchesTheReferenceValuesForSRGBRed() {
        let red = OklchColor(.rgb(1, 0, 0))

        #expect(Self.isClose(red.lightness, to: 0.627955))
        #expect(Self.isClose(red.chroma, to: 0.257683), "√(0.224863² + 0.125846²)")
        #expect(Self.isClose(red.hue, to: 0.510228), "atan2(0.125846, 0.224863)")
    }

    @Test("a colour converted to OKLCH and back is the same colour", arguments: [
        Settings.Theme.ColorValue.rgb(1, 1, 1),
        .rgb(0, 0, 0),
        .rgb(0.7660875916, 0.1342913806, 0.4595085979),
        .rgb(0.1251632571, 0.1258862913, 0.1465735137),
        .rgb(0.2426597476, 0.7430019975, 0.8773110509),
    ])
    func oklabRoundTripReturnsTheSameSRGBColor(color: Settings.Theme.ColorValue) {
        let roundTripped = OklchColor(color).colorValue(opacity: color.alpha)

        #expect(Self.isClose(roundTripped.red, to: color.red, within: 1e-6))
        #expect(Self.isClose(roundTripped.green, to: color.green, within: 1e-6))
        #expect(Self.isClose(roundTripped.blue, to: color.blue, within: 1e-6))
    }

    // MARK: - Factors

    @Test("a background loses 6 % of its lightness in a dark theme and 2 % in a light one")
    func backgroundLightnessScalesByPointNineFourInDarkAndPointNineEightInLight() {
        let grey = Settings.Theme.ColorValue.rgb(0.5, 0.5, 0.5)

        #expect(Self.isGrey(UnfocusedEditorPaneDimming.dimmed(grey, level: .background, colorScheme: .dark), of: 0.458692))
        #expect(Self.isGrey(UnfocusedEditorPaneDimming.dimmed(grey, level: .background, colorScheme: .light), of: 0.486160))
    }

    @Test("a fill loses 5 % of its lightness in a dark theme and 2.5 % in a light one")
    func fillLightnessScalesByPointNineFiveInDarkAndPointNineSevenFiveInLight() {
        let grey = Settings.Theme.ColorValue.rgb(0.5, 0.5, 0.5)

        #expect(Self.isGrey(UnfocusedEditorPaneDimming.dimmed(grey, level: .fill, colorScheme: .dark), of: 0.465532))
        #expect(Self.isGrey(UnfocusedEditorPaneDimming.dimmed(grey, level: .fill, colorScheme: .light), of: 0.482711))
    }

    @Test("text loses 10 % of its lightness in either scheme")
    func textLightnessScalesByPointNine() {
        let grey = Settings.Theme.ColorValue.rgb(0.2, 0.2, 0.2)

        #expect(Self.isGrey(UnfocusedEditorPaneDimming.dimmed(grey, level: .text, colorScheme: .dark), of: 0.168534))
        #expect(Self.isGrey(UnfocusedEditorPaneDimming.dimmed(grey, level: .text, colorScheme: .light), of: 0.168534))
    }

    @Test("chroma is multiplied by 0.85 for a background and 0.9 for fills and text", arguments: [
        (UnfocusedEditorPaneDimming.ContrastLevel.background, 0.85),
        (.fill, 0.90),
        (.text, 0.90),
    ])
    func chromaScalesByTheLevelsFactor(level: UnfocusedEditorPaneDimming.ContrastLevel, chromaFactor: Double) throws {
        // A muted blue, well inside the gamut at the lower lightness, so nothing is clipped first.
        let color = Settings.Theme.ColorValue.rgb(0.35, 0.45, 0.6)
        let original = OklchColor(color)
        let dimmed = OklchColor(UnfocusedEditorPaneDimming.dimmed(color, level: level, colorScheme: .dark))
        try #require(OklchColor.maximumChroma(lightness: dimmed.lightness, hue: original.hue) > original.chroma)

        #expect(Self.isClose(dimmed.chroma, to: original.chroma * chromaFactor, within: 1e-6))
    }

    @Test("dimming keeps the hue and the opacity")
    func hueAndOpacityAreKept() {
        let color = Settings.Theme.ColorValue.rgb(0.35, 0.45, 0.6, 0.4)
        let dimmed = UnfocusedEditorPaneDimming.dimmed(color, level: .fill, colorScheme: .light)

        #expect(Self.isClose(OklchColor(dimmed).hue, to: OklchColor(color).hue, within: 1e-6))
        #expect(dimmed.alpha == 0.4)
    }

    @Test("a saturated colour has its chroma clipped to the sRGB gamut at the new lightness before it is scaled")
    func chromaIsClippedToTheSRGBGamutAtTheNewLightness() {
        let red = Settings.Theme.ColorValue.rgb(1, 0, 0)
        let original = OklchColor(red)
        let dimmedRed = UnfocusedEditorPaneDimming.dimmed(red, level: .text, colorScheme: .dark)
        let dimmed = OklchColor(dimmedRed)

        #expect(dimmed.chroma < original.chroma * 0.9, "sRGB red cannot keep its chroma at 90 % of its lightness")
        #expect([dimmedRed.red, dimmedRed.green, dimmedRed.blue].allSatisfy { (0 ... 1).contains($0) })
        #expect(Self.isClose(dimmed.lightness, to: 0.627955 * 0.9))
    }

    @Test("a translucent colour is composited over the background into an opaque one")
    func flattenedComposesOverTheBackground() {
        let flattened = UnfocusedEditorPaneDimming.flattened(.rgb(1, 0, 0, 0.5), over: .rgb(0, 0, 1))

        #expect(flattened == .rgb(0.5, 0, 0.5, 1))
    }

    // MARK: - Presets

    @Test("an opaque selection and current-line highlight take the fill factors")
    func opaqueSelectionAndCurrentLineTakeTheFillFactors() {
        var preset = Settings.Theme.Preset.xcode
        preset.selection = .solid(.rgb(0.5, 0.5, 0.5))
        preset.currentLineHighlight = .solid(.rgb(0.5, 0.5, 0.5))
        let dimmedPreset = preset.dimmedForUnfocusedEditorPane()

        #expect(Self.isGrey(dimmedPreset.selection.light, of: 0.482711))
        #expect(Self.isGrey(dimmedPreset.selection.dark, of: 0.465532))
        #expect(Self.isGrey(dimmedPreset.currentLineHighlight.light, of: 0.482711))
        #expect(Self.isGrey(dimmedPreset.currentLineHighlight.dark, of: 0.465532))
    }

    @Test("a translucent selection and current-line highlight are kept as they are")
    func translucentSelectionAndCurrentLineStayUnchanged() {
        var preset = Settings.Theme.Preset.xcode
        preset.selection = .adaptive(light: .rgb(0.5, 0.5, 1, 0.5), dark: .rgb(0.3, 0.3, 0.8, 0.6))
        preset.currentLineHighlight = .adaptive(light: .rgb(0, 0, 0, 0.05), dark: .rgb(1, 1, 1, 0.04))
        let dimmedPreset = preset.dimmedForUnfocusedEditorPane()

        #expect(dimmedPreset.selection == preset.selection)
        #expect(dimmedPreset.currentLineHighlight == preset.currentLineHighlight)
    }

    @Test("the background takes the background factors in each variant")
    func presetBackgroundTakesTheBackgroundFactors() {
        var preset = Settings.Theme.Preset.xcode
        preset.background = .solid(.rgb(0.5, 0.5, 0.5))
        let dimmedPreset = preset.dimmedForUnfocusedEditorPane()

        #expect(Self.isGrey(dimmedPreset.background.light, of: 0.486160))
        #expect(Self.isGrey(dimmedPreset.background.dark, of: 0.458692))
    }

    @Test("a translucent text colour is flattened over the undimmed background, then dimmed as text")
    func translucentTextIsFlattenedOverTheUndimmedBackgroundFirst() {
        var preset = Settings.Theme.Preset.xcode
        // Black at 50 % over white is the grey 0.5; dimmed as text it is the grey 0.431515.
        preset.background = .adaptive(light: .rgb(1, 1, 1), dark: .rgb(0, 0, 0))
        preset.keyword = .adaptive(light: .rgb(0, 0, 0, 0.5), dark: .rgb(1, 1, 1, 0.5))
        let dimmedPreset = preset.dimmedForUnfocusedEditorPane()

        #expect(Self.isGrey(dimmedPreset.keyword.light, of: 0.431515))
        #expect(Self.isGrey(dimmedPreset.keyword.dark, of: 0.431515))
        #expect(dimmedPreset.keyword.light.alpha == 1)
        #expect(dimmedPreset.keyword.dark.alpha == 1)
    }

    @Test("every text slot is dimmed")
    func everyTextSlotIsDimmed() {
        let preset = Settings.Theme.Preset.xcode
        let dimmedPreset = preset.dimmedForUnfocusedEditorPane()
        let textSlots: [KeyPath<Settings.Theme.Preset, Settings.Theme.Style>] = [
            \.text, \.keyword, \.typeName, \.declaration, \.comment, \.number, \.error, \.macro,
        ]

        for textSlot in textSlots {
            let originalLightness = OklchColor(UnfocusedEditorPaneDimming.flattened(preset[keyPath: textSlot].dark, over: preset.background.dark)).lightness
            let dimmedLightness = OklchColor(dimmedPreset[keyPath: textSlot].dark).lightness
            #expect(Self.isClose(dimmedLightness, to: originalLightness * 0.9), "\(textSlot)")
        }
    }

    @Test("dimming keeps the font traits, the identifier and the name")
    func fontTraitsIdentifierAndNameAreKept() {
        var preset = Settings.Theme.Preset.xcode
        preset.keyword.isBold = true
        preset.comment.isItalic = true
        let dimmedPreset = preset.dimmedForUnfocusedEditorPane()

        #expect(dimmedPreset.keyword.isBold)
        #expect(dimmedPreset.comment.isItalic)
        #expect(dimmedPreset.id == preset.id)
        #expect(dimmedPreset.name == preset.name)
        #expect(dimmedPreset.isBuiltin == preset.isBuiltin)
    }

    // MARK: - ResolvedTheme

    @Test("a dimmed theme is not equal to the theme it was made from")
    func dimmedThemeIsNotEqualToTheUndimmedOne() {
        let theme = ResolvedTheme(preset: .xcode, fontSize: 13)
        let dimmedTheme = theme.dimmedForUnfocusedEditorPane()

        #expect(dimmedTheme != theme)
        #expect(dimmedTheme.isDimmedForUnfocusedEditorPane)
        #expect(!theme.isDimmedForUnfocusedEditorPane)
    }

    @Test("dimming a dimmed theme returns it unchanged")
    func dimmingADimmedThemeReturnsItUnchanged() {
        let dimmedTheme = ResolvedTheme(preset: .xcode, fontSize: 13).dimmedForUnfocusedEditorPane()

        #expect(dimmedTheme.dimmedForUnfocusedEditorPane() == dimmedTheme)
        #expect(dimmedTheme.preset == Settings.Theme.Preset.xcode.dimmedForUnfocusedEditorPane())
    }

    @Test("a dimmed theme draws in the dimmed preset's colours and keeps its fonts")
    func dimmedThemeDrawsTheDimmedPresetsColors() throws {
        let theme = ResolvedTheme(preset: .xcode, fontSize: 15)
        let dimmedTheme = theme.dimmedForUnfocusedEditorPane()
        let dimmedPreset = Settings.Theme.Preset.xcode.dimmedForUnfocusedEditorPane()

        let background = try Self.sRGBComponents(of: dimmedTheme.backgroundColor, in: .darkAqua)
        #expect(Self.isClose(background.red, to: dimmedPreset.background.dark.red, within: 1e-6))
        #expect(Self.isClose(background.green, to: dimmedPreset.background.dark.green, within: 1e-6))
        #expect(Self.isClose(background.blue, to: dimmedPreset.background.dark.blue, within: 1e-6))
        let keyword = try Self.sRGBComponents(of: dimmedTheme.color(for: .keyword), in: .darkAqua)
        #expect(Self.isClose(keyword.red, to: dimmedPreset.keyword.dark.red, within: 1e-6))
        #expect(dimmedTheme.font(for: .keyword) == theme.font(for: .keyword))
        #expect(dimmedTheme.fontSize == 15)
    }

    /// `color` resolved under `appearanceName` — the theme's colours follow the appearance.
    private static func sRGBComponents(of color: NSColor, in appearanceName: NSAppearance.Name) throws -> Settings.Theme.ColorValue {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB)
        }
        let sRGBColor = try #require(resolvedColor)
        return .rgb(Double(sRGBColor.redComponent), Double(sRGBColor.greenComponent), Double(sRGBColor.blueComponent), Double(sRGBColor.alphaComponent))
    }
}

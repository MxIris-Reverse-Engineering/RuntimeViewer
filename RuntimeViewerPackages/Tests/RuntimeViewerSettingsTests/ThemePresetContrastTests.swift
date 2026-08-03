import Testing
import Foundation
@testable import RuntimeViewerSettings

/// Guards the built-in presets against color slots that are legible in one
/// appearance but not the other.
///
/// The Xcode preset originally declared `selection` as a `.solid` slot, so the
/// shade picked for the dark background was reused verbatim in light mode.
/// Selected comments landed at a 1.06:1 contrast ratio there — visually
/// identical to the selection fill — which made selected text unreadable.
@Suite("Settings.Theme.Preset contrast")
struct ThemePresetContrastTests {
    private let preset = Settings.Theme.Preset.xcode

    @Test("selection resolves to distinct colors per appearance")
    func selectionIsAppearanceAdaptive() {
        #expect(
            preset.selection.light != preset.selection.dark,
            "A solid selection slot reuses one shade for both appearances, which cannot suit two opposite backgrounds."
        )
    }

    @Test("body text stays readable when selected in light appearance")
    func lightSelectionContrastForBodyText() {
        let ratio = preset.text.light.contrastRatio(against: preset.selection.light)
        #expect(ratio >= WCAGContrast.normalTextMinimum, "Got \(ratio.rounded(toPlaces: 2)):1")
    }

    @Test("comments stay readable when selected in light appearance")
    func lightSelectionContrastForComments() {
        let ratio = preset.comment.light.contrastRatio(against: preset.selection.light)
        #expect(ratio >= WCAGContrast.largeTextMinimum, "Got \(ratio.rounded(toPlaces: 2)):1")
    }

    @Test("body text stays readable when selected in dark appearance")
    func darkSelectionContrastForBodyText() {
        let ratio = preset.text.dark.contrastRatio(against: preset.selection.dark)
        #expect(ratio >= WCAGContrast.normalTextMinimum, "Got \(ratio.rounded(toPlaces: 2)):1")
    }

    @Test("body text stays readable on the unselected background")
    func backgroundContrastForBodyText() {
        let lightRatio = preset.text.light.contrastRatio(against: preset.background.light)
        let darkRatio = preset.text.dark.contrastRatio(against: preset.background.dark)
        #expect(lightRatio >= WCAGContrast.normalTextMinimum, "Light: \(lightRatio.rounded(toPlaces: 2)):1")
        #expect(darkRatio >= WCAGContrast.normalTextMinimum, "Dark: \(darkRatio.rounded(toPlaces: 2)):1")
    }
}

// MARK: - WCAG Contrast

private enum WCAGContrast {
    /// WCAG 2.1 AA threshold for body-sized text.
    static let normalTextMinimum: Double = 4.5

    /// WCAG 2.1 AA threshold for large or de-emphasized text. Comments are
    /// intentionally low-emphasis, so they are held to this looser bar.
    static let largeTextMinimum: Double = 3.0
}

extension Settings.Theme.ColorValue {
    /// WCAG 2.1 relative luminance. Assumes an opaque color; the slots under
    /// test (`background`, `selection`, `text`, `comment`) all store alpha 1.
    fileprivate var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
    }

    /// WCAG 2.1 contrast ratio between two opaque colors, in `1...21`.
    fileprivate func contrastRatio(against other: Self) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

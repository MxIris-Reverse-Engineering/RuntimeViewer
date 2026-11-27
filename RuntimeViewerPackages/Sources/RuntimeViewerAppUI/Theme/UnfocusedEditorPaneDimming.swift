import Foundation
import RuntimeViewerSettings

/// Xcode 27.2's "Dim unfocused editor panes": the colours an editor pane without the focus draws its
/// interface in (proposal `dim-unfocused-editor-panes`).
///
/// Nothing is composited over the pane. Every colour of the theme is recomputed in OKLCH, as
/// `DVTOpaqueColor.applyingStateAppearance(as:in:)` does for the theme state `.inactive` (DVTUserInterfaceKit
/// 27B52 0x1DC590; RE notes "Dimmed unfocused editor panes" §1): the lightness is multiplied by a factor and
/// clamped to 0…1, the chroma is clipped to the gamut at the new lightness and then multiplied by a factor,
/// and the hue and the opacity are kept. The factors depend on the colour's contrast level and on whether it
/// belongs to the light or the dark variant of the theme.
public enum UnfocusedEditorPaneDimming {
    /// Which of Xcode's contrast levels a colour is dimmed at; its factors depend on it.
    public enum ContrastLevel: Sendable {
        /// The editor background (Xcode's level 0).
        case background
        /// Fills drawn over the background, such as the current line and the selection (levels 1–5).
        case fill
        /// Text and every syntax colour (levels 6–10).
        case text
    }

    /// The scheme of the theme a colour belongs to — the light or the dark variant of a slot — which picks
    /// the lightness factor: Xcode reads the theme's own scheme, not the view's appearance.
    public enum ColorScheme: Sendable {
        case light
        case dark
    }

    /// `color` as an editor pane without the focus draws it.
    ///
    /// The opacity is kept as it is; a translucent text colour is flattened (`flattened(_:over:)`) before it
    /// is dimmed, as Xcode's conversion of a classic theme stores it.
    public static func dimmed(_ color: Settings.Theme.ColorValue, level: ContrastLevel, colorScheme: ColorScheme) -> Settings.Theme.ColorValue {
        var oklchColor = OklchColor(color)
        oklchColor.lightness = min(max(oklchColor.lightness * lightnessFactor(for: level, colorScheme: colorScheme), 0), 1)
        oklchColor.chroma = min(oklchColor.chroma, OklchColor.maximumChroma(lightness: oklchColor.lightness, hue: oklchColor.hue))
        oklchColor.chroma = max(oklchColor.chroma * chromaFactor(for: level), 0)
        return oklchColor.colorValue(opacity: color.alpha)
    }

    /// `color` composited over the opaque `background`, with opacity 1: how a translucent colour looks once
    /// drawn. The blend is AppKit's own for text over an opaque fill — in gamma-encoded sRGB — so a pane with
    /// the focus looks the same with either colour.
    public static func flattened(_ color: Settings.Theme.ColorValue, over background: Settings.Theme.ColorValue) -> Settings.Theme.ColorValue {
        let opacity = min(max(color.alpha, 0), 1)
        func composite(_ foreground: Double, over backdrop: Double) -> Double {
            foreground * opacity + backdrop * (1 - opacity)
        }
        return Settings.Theme.ColorValue(
            red: composite(color.red, over: background.red),
            green: composite(color.green, over: background.green),
            blue: composite(color.blue, over: background.blue),
            alpha: 1
        )
    }

    /// Xcode's `kL` for the theme state `.inactive` (tables at 0x342C80 dark and 0x342CD8 light).
    static func lightnessFactor(for level: ContrastLevel, colorScheme: ColorScheme) -> Double {
        switch (level, colorScheme) {
        case (.background, .light): 0.98
        case (.background, .dark): 0.94
        case (.fill, .light): 0.975
        case (.fill, .dark): 0.95
        case (.text, _): 0.90
        }
    }

    /// Xcode's `kC` for the theme state `.inactive` (table at 0x342C28), the same in both schemes.
    static func chromaFactor(for level: ContrastLevel) -> Double {
        switch level {
        case .background: 0.85
        case .fill: 0.90
        case .text: 0.90
        }
    }
}

// MARK: - Presets

extension Settings.Theme.Preset {
    /// The preset an editor pane without the focus draws in, by the rules Xcode 27.2 applies to a classic
    /// theme (RE notes "Dimmed unfocused editor panes" §2): the background at the background level; the
    /// selection and the current-line highlight at the fill level, only while opaque — a translucent one is
    /// kept as it is; every text slot flattened over the undimmed background, then at the text level. Font
    /// traits, the identifier and the name are kept.
    package func dimmedForUnfocusedEditorPane() -> Settings.Theme.Preset {
        let undimmedBackground = background
        func dimmedText(_ style: Settings.Theme.Style) -> Settings.Theme.Style {
            style.mappingColors { color, colorScheme in
                let backdrop = colorScheme == .light ? undimmedBackground.light : undimmedBackground.dark
                return UnfocusedEditorPaneDimming.dimmed(
                    UnfocusedEditorPaneDimming.flattened(color, over: backdrop),
                    level: .text,
                    colorScheme: colorScheme
                )
            }
        }
        func dimmedFill(_ style: Settings.Theme.Style) -> Settings.Theme.Style {
            style.mappingColors { color, colorScheme in
                guard color.alpha >= 1 else { return color }
                return UnfocusedEditorPaneDimming.dimmed(color, level: .fill, colorScheme: colorScheme)
            }
        }

        var dimmedPreset = self
        dimmedPreset.background = background.mappingColors { color, colorScheme in
            UnfocusedEditorPaneDimming.dimmed(color, level: .background, colorScheme: colorScheme)
        }
        dimmedPreset.selection = dimmedFill(selection)
        dimmedPreset.currentLineHighlight = dimmedFill(currentLineHighlight)
        dimmedPreset.text = dimmedText(text)
        dimmedPreset.keyword = dimmedText(keyword)
        dimmedPreset.typeName = dimmedText(typeName)
        dimmedPreset.declaration = dimmedText(declaration)
        dimmedPreset.comment = dimmedText(comment)
        dimmedPreset.number = dimmedText(number)
        dimmedPreset.error = dimmedText(error)
        dimmedPreset.macro = dimmedText(macro)
        return dimmedPreset
    }
}

extension Settings.Theme.Style {
    /// The slot with both of its colours transformed, each told which variant it is; the font traits stay.
    fileprivate func mappingColors(_ transform: (Settings.Theme.ColorValue, UnfocusedEditorPaneDimming.ColorScheme) -> Settings.Theme.ColorValue) -> Settings.Theme.Style {
        var style = self
        style.light = transform(light, .light)
        style.dark = transform(dark, .dark)
        return style
    }
}

// MARK: - OKLCH

/// A colour in OKLCH: OKLab (Björn Ottosson's perceptual colour space) in polar form, for the sRGB colours
/// the theme stores. Xcode's `DVTOklchColor` is the same space; which matrices it uses was not decompiled,
/// and these are the published ones.
struct OklchColor: Equatable {
    /// Perceived lightness, 0 (black) … 1 (white).
    var lightness: Double
    /// Distance from the grey of the same lightness; 0 for a grey.
    var chroma: Double
    /// Hue angle in radians.
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    /// The colour's sRGB components in OKLCH; the opacity is not part of it.
    init(_ color: Settings.Theme.ColorValue) {
        let oklab = Self.oklab(
            linearRed: Self.linearized(color.red),
            linearGreen: Self.linearized(color.green),
            linearBlue: Self.linearized(color.blue)
        )
        self.init(
            lightness: oklab.lightness,
            chroma: (oklab.greenRed * oklab.greenRed + oklab.blueYellow * oklab.blueYellow).squareRoot(),
            hue: atan2(oklab.blueYellow, oklab.greenRed)
        )
    }

    /// The colour in sRGB with `opacity`; components rounding a hair outside 0…1 are clamped.
    func colorValue(opacity: Double) -> Settings.Theme.ColorValue {
        let linearComponents = linearSRGBComponents()
        return Settings.Theme.ColorValue(
            red: Self.gammaEncoded(linearComponents.red),
            green: Self.gammaEncoded(linearComponents.green),
            blue: Self.gammaEncoded(linearComponents.blue),
            alpha: opacity
        )
    }

    /// The largest chroma at `lightness` and `hue` that sRGB can show, found by bisection.
    static func maximumChroma(lightness: Double, hue: Double) -> Double {
        let upperBound = 0.5
        if OklchColor(lightness: lightness, chroma: upperBound, hue: hue).isInsideSRGBGamut {
            return upperBound
        }
        var insideChroma = 0.0
        var outsideChroma = upperBound
        for _ in 0 ..< 40 {
            let middleChroma = (insideChroma + outsideChroma) / 2
            if OklchColor(lightness: lightness, chroma: middleChroma, hue: hue).isInsideSRGBGamut {
                insideChroma = middleChroma
            } else {
                outsideChroma = middleChroma
            }
        }
        return insideChroma
    }

    var isInsideSRGBGamut: Bool {
        let tolerance = 1e-9
        let linearComponents = linearSRGBComponents()
        return [linearComponents.red, linearComponents.green, linearComponents.blue].allSatisfy {
            $0 >= -tolerance && $0 <= 1 + tolerance
        }
    }

    private func linearSRGBComponents() -> (red: Double, green: Double, blue: Double) {
        let greenRed = chroma * cos(hue)
        let blueYellow = chroma * sin(hue)
        let longCone = cube(lightness + 0.3963377774 * greenRed + 0.2158037573 * blueYellow)
        let mediumCone = cube(lightness - 0.1055613458 * greenRed - 0.0638541728 * blueYellow)
        let shortCone = cube(lightness - 0.0894841775 * greenRed - 1.2914855480 * blueYellow)
        return (
            red: 4.0767416621 * longCone - 3.3077115913 * mediumCone + 0.2309699292 * shortCone,
            green: -1.2684380046 * longCone + 2.6097574011 * mediumCone - 0.3413193965 * shortCone,
            blue: -0.0041960863 * longCone - 0.7034186147 * mediumCone + 1.7076147010 * shortCone
        )
    }

    private static func oklab(linearRed: Double, linearGreen: Double, linearBlue: Double) -> (lightness: Double, greenRed: Double, blueYellow: Double) {
        let longCone = cbrt(0.4122214708 * linearRed + 0.5363325363 * linearGreen + 0.0514459929 * linearBlue)
        let mediumCone = cbrt(0.2119034982 * linearRed + 0.6806995451 * linearGreen + 0.1073969566 * linearBlue)
        let shortCone = cbrt(0.0883024619 * linearRed + 0.2817188376 * linearGreen + 0.6299787005 * linearBlue)
        return (
            lightness: 0.2104542553 * longCone + 0.7936177850 * mediumCone - 0.0040720468 * shortCone,
            greenRed: 1.9779984951 * longCone - 2.4285922050 * mediumCone + 0.4505937099 * shortCone,
            blueYellow: 0.0259040371 * longCone + 0.7827717662 * mediumCone - 0.8086757660 * shortCone
        )
    }

    /// The sRGB transfer function, inverted.
    private static func linearized(_ component: Double) -> Double {
        let clampedComponent = min(max(component, 0), 1)
        return clampedComponent <= 0.04045 ? clampedComponent / 12.92 : pow((clampedComponent + 0.055) / 1.055, 2.4)
    }

    /// The sRGB transfer function, for a linear component clamped to 0…1.
    private static func gammaEncoded(_ linearComponent: Double) -> Double {
        let clampedComponent = min(max(linearComponent, 0), 1)
        return clampedComponent <= 0.0031308 ? 12.92 * clampedComponent : 1.055 * pow(clampedComponent, 1 / 2.4) - 0.055
    }
}

private func cube(_ value: Double) -> Double {
    value * value * value
}

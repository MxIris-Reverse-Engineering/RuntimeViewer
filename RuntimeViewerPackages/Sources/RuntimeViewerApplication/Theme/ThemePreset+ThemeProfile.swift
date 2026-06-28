#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Foundation
import Semantic
import UIFoundation
import RuntimeViewerCore
import RuntimeViewerSettings

/// A render-ready theme resolved from a stored ``Settings/Theme/Preset`` plus
/// the global font size. Conforms to ``ThemeProfile`` so the existing
/// `SemanticString.attributedString(for:)` rendering path is unchanged.
///
/// Color and font resolutions are precomputed at init time and looked up by
/// ``Settings/Theme/Style`` so the per-token render path on large interfaces
/// stays allocation-free.
public struct ResolvedTheme: ThemeProfile, @unchecked Sendable {
    public let preset: Settings.Theme.Preset
    public let fontSize: CGFloat

    public let backgroundColor: NSUIColor
    public let selectionBackgroundColor: NSUIColor

    private let colorByStyle: [Settings.Theme.Style: NSUIColor]
    private let fontByStyle: [Settings.Theme.Style: NSUIFont]

    public init(preset: Settings.Theme.Preset, fontSize: CGFloat) {
        self.preset = preset
        self.fontSize = fontSize
        self.backgroundColor = preset.background.nsuiColor
        self.selectionBackgroundColor = preset.selection.nsuiColor

        let textStyles: [Settings.Theme.Style] = [
            preset.text,
            preset.keyword,
            preset.declaration,
            preset.typeName,
            preset.comment,
            preset.number,
            preset.error,
        ]
        var colorByStyle: [Settings.Theme.Style: NSUIColor] = [:]
        var fontByStyle: [Settings.Theme.Style: NSUIFont] = [:]
        colorByStyle.reserveCapacity(textStyles.count)
        fontByStyle.reserveCapacity(textStyles.count)
        for style in textStyles {
            if colorByStyle[style] == nil {
                colorByStyle[style] = style.nsuiColor
            }
            if fontByStyle[style] == nil {
                fontByStyle[style] = Self.font(for: style, fontSize: fontSize)
            }
        }
        self.colorByStyle = colorByStyle
        self.fontByStyle = fontByStyle
    }

    /// Resolves the currently-selected preset and global font size from the
    /// given settings.
    public init(settings: Settings) {
        self.init(
            preset: settings.theme.selectedPreset,
            fontSize: CGFloat(settings.theme.fontSize)
        )
    }

    /// The built-in Xcode preset at the default font size. Used as the initial
    /// value and on platforms without a live `Settings` feed.
    public static var fallback: ResolvedTheme {
        .init(preset: .xcode, fontSize: 13)
    }

    public func color(for type: SemanticType) -> NSUIColor {
        let style = style(for: type)
        return colorByStyle[style] ?? style.nsuiColor
    }

    public func font(for type: SemanticType) -> NSUIFont {
        let style = style(for: type)
        return fontByStyle[style] ?? Self.font(for: style, fontSize: fontSize)
    }

    /// Maps a semantic token type onto the preset's editable color slots,
    /// preserving the grouping the previous hard-coded theme used.
    private func style(for type: SemanticType) -> Settings.Theme.Style {
        switch type {
        case .comment:
            return preset.comment
        case .keyword:
            return preset.keyword
        case .variable,
             .function(.declaration),
             .member(.declaration),
             .type(_, .declaration):
            return preset.declaration
        case .type(_, .name),
             .function(.name),
             .member(.name):
            return preset.typeName
        case .numeric:
            return preset.number
        case .error:
            return preset.error
        default:
            return preset.text
        }
    }

    private static func font(for style: Settings.Theme.Style, fontSize: CGFloat) -> NSUIFont {
        let weight: NSUIFont.Weight = style.isBold ? .semibold : .regular
        let baseFont = NSUIFont.monospacedSystemFont(ofSize: fontSize, weight: weight)

        guard style.isItalic else { return baseFont }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSUIFont(descriptor: italicDescriptor, size: fontSize) ?? baseFont
        #else
        guard let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) else {
            return baseFont
        }
        return NSUIFont(descriptor: italicDescriptor, size: fontSize)
        #endif
    }
}

// MARK: - Equatable

extension ResolvedTheme: Equatable {
    /// Identity is fully determined by the source `preset` and `fontSize`;
    /// the precomputed color/font caches are derived state.
    public static func == (lhs: ResolvedTheme, rhs: ResolvedTheme) -> Bool {
        lhs.preset == rhs.preset && lhs.fontSize == rhs.fontSize
    }
}

// MARK: - Color Resolution

extension Settings.Theme.ColorValue {
    /// Resolves the stored sRGB component values into a platform color.
    public var nsuiColor: NSUIColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSUIColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        #else
        return NSUIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        #endif
    }
}

extension Settings.Theme.Style {
    /// An appearance-adaptive color built from the light and dark variants.
    ///
    /// Solid slots (`light == dark`) short-circuit to a single static color so
    /// they do not pay for a dynamic appearance-resolving wrapper that would
    /// otherwise re-evaluate `effectiveAppearance` on every CGColor
    /// materialization.
    public var nsuiColor: NSUIColor {
        if light == dark {
            return light.nsuiColor
        }
        return NSUIColor(light: light.nsuiColor, dark: dark.nsuiColor)
    }
}

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
public struct ResolvedTheme: ThemeProfile, Sendable {
    public let preset: Settings.Theme.Preset
    public let fontSize: CGFloat

    public init(preset: Settings.Theme.Preset, fontSize: CGFloat) {
        self.preset = preset
        self.fontSize = fontSize
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

    public var backgroundColor: NSUIColor {
        preset.background.nsuiColor
    }

    public var selectionBackgroundColor: NSUIColor {
        preset.selection.nsuiColor
    }

    public func color(for type: SemanticType) -> NSUIColor {
        style(for: type).nsuiColor
    }

    public func font(for type: SemanticType) -> NSUIFont {
        font(for: style(for: type))
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

    private func font(for style: Settings.Theme.Style) -> NSUIFont {
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
    public var nsuiColor: NSUIColor {
        NSUIColor(light: light.nsuiColor, dark: dark.nsuiColor)
    }
}

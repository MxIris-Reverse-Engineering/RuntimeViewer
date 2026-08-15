import AppKit
import RuntimeViewerApplication
import Semantic

/// Renders a RuntimeViewer `ThemeProfile` into the `.xccolortheme` dictionary that
/// `SourceEditorTheme` consumes, so the Xcode-backed content view uses the colors configured
/// in Settings rather than the theme Xcode ships.
///
/// **It overwrites a copy of the framework's own theme instead of building one from nothing.**
/// The format has around fifty keys — console colors, markup fonts, scrollbar markers — and
/// most of them have no counterpart in `ThemeProfile`. Starting from a complete, valid
/// dictionary means the unmapped keys keep working, and a future Xcode adding a key does not
/// produce a theme with a hole in it.
enum SourceEditorThemeConversion {
    /// Maps `SemanticType` onto the syntax categories Xcode's theme defines.
    ///
    /// The mapping is lossy in both directions and deliberately so:
    ///
    /// - Xcode distinguishes project symbols from SDK ones (`identifier.type` versus
    ///   `identifier.type.system`); `SemanticType` does not, so both get the project color.
    /// - `SemanticType.error` has no Xcode counterpart and falls back to plain text.
    /// - Declaration context maps onto `declaration.type` / `declaration.other`, which is what
    ///   Xcode uses to color the name in a declaration differently from a use of it.
    ///
    /// It exists as a table rather than a `switch` because the syntax-token injection work
    /// tracked in proposal 0009 needs the same mapping in the other direction.
    static func syntaxColorKey(for semanticType: SemanticType) -> String {
        switch semanticType {
        case .standard, .other:
            "xcode.syntax.plain"
        case .comment:
            "xcode.syntax.comment"
        case .keyword:
            "xcode.syntax.keyword"
        case .variable:
            "xcode.syntax.identifier.variable"
        case .numeric:
            "xcode.syntax.number"
        case .argument:
            "xcode.syntax.identifier.variable"
        case .error:
            "xcode.syntax.plain"
        case .type(let typeKind, let context):
            switch context {
            case .declaration:
                "xcode.syntax.declaration.type"
            case .name:
                typeKind == .class ? "xcode.syntax.identifier.class" : "xcode.syntax.identifier.type"
            }
        case .member(let context):
            context == .declaration ? "xcode.syntax.declaration.other" : "xcode.syntax.identifier.variable"
        case .function(let context):
            context == .declaration ? "xcode.syntax.declaration.other" : "xcode.syntax.identifier.function"
        }
    }

    /// Every `SemanticType` that carries a distinct color, so the conversion covers the whole
    /// enum rather than whichever cases happened to come to mind. `SemanticType` is not
    /// `CaseIterable` — it has associated values — so the product is spelled out here.
    private static let allSemanticTypes: [SemanticType] = {
        var types: [SemanticType] = [.standard, .comment, .keyword, .variable, .numeric, .argument, .error, .other]
        for typeKind in SemanticType.TypeKind.allCases {
            for context in SemanticType.Context.allCases {
                types.append(.type(typeKind, context))
            }
        }
        for context in SemanticType.Context.allCases {
            types.append(.member(context))
            types.append(.function(context))
        }
        return types
    }()

    /// - Parameter baseTheme: one of the framework's own `.xccolortheme` dictionaries.
    /// - Returns: `nil` if `baseTheme` is not shaped like a theme, in which case the caller
    ///   should keep using it unmodified rather than hand the editor something malformed.
    static func themeDictionary(from themeProfile: ThemeProfile, basedOn baseTheme: NSDictionary) -> NSDictionary? {
        guard let converted = baseTheme.mutableCopy() as? NSMutableDictionary,
              let baseSyntaxColors = baseTheme["DVTSourceTextSyntaxColors"] as? NSDictionary,
              let syntaxColors = baseSyntaxColors.mutableCopy() as? NSMutableDictionary,
              let baseSyntaxFonts = baseTheme["DVTSourceTextSyntaxFonts"] as? NSDictionary,
              let syntaxFonts = baseSyntaxFonts.mutableCopy() as? NSMutableDictionary
        else { return nil }

        for semanticType in allSemanticTypes {
            let key = syntaxColorKey(for: semanticType)
            syntaxColors[key] = themeString(for: themeProfile.color(for: semanticType))
            syntaxFonts[key] = themeString(for: themeProfile.font(for: semanticType))
        }

        converted["DVTSourceTextSyntaxColors"] = syntaxColors
        converted["DVTSourceTextSyntaxFonts"] = syntaxFonts
        converted["DVTSourceTextBackground"] = themeString(for: themeProfile.backgroundColor)
        converted["DVTSourceTextSelectionColor"] = themeString(for: themeProfile.selectionBackgroundColor)

        return converted
    }

    /// `"red green blue alpha"`, components in 0…1.
    ///
    /// **Components must be in generic (calibrated) RGB, not sRGB.** The framework builds its
    /// color with the equivalent of `NSColor(calibratedRed:green:blue:alpha:)`, so writing
    /// sRGB components here would land on a different color than the one configured —
    /// measurably, not theoretically: sRGB 0.1/0.9/0.4 renders as 0.420/0.886/0.459 while the
    /// same triple read as calibrated renders as 0.404/0.886/0.518.
    ///
    /// Converting the color space is also required rather than defensive: a color from a named
    /// asset or a system color lives in a catalog color space, and reading `redComponent` off
    /// one of those traps.
    private static func themeString(for color: NSColor) -> String {
        guard let genericRGBColor = color.usingColorSpace(.genericRGB) else { return "0 0 0 1" }
        return "\(genericRGBColor.redComponent) \(genericRGBColor.greenComponent) \(genericRGBColor.blueComponent) \(genericRGBColor.alphaComponent)"
    }

    /// `"PostScriptName - Size"`.
    private static func themeString(for font: NSFont) -> String {
        "\(font.fontName) - \(font.pointSize)"
    }
}

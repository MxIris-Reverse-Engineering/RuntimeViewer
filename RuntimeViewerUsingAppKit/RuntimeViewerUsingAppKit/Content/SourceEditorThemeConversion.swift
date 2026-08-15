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
    /// The app's theme resolves every `SemanticType` to one of seven text styles, so seven
    /// colors are all there are to distribute. The editor's theme has twenty-eight syntax keys.
    ///
    /// **Every one of the twenty-eight is written.** A key left unset keeps its color from
    /// Xcode's own theme, and the result reads as two themes at once — that is what made
    /// SDK classes purple while classes from the inspected image followed the configured theme.
    /// Each key is listed here against the `SemanticType` that stands for its style; several
    /// keys share a style, which is correct, because the app's theme genuinely cannot tell
    /// those cases apart.
    private static let styleRepresentativeByThemeKey: [String: SemanticType] = [
        // Plain text and things the app's theme has no opinion about.
        "xcode.syntax.plain": .standard,
        "xcode.syntax.string": .standard,
        "xcode.syntax.url": .standard,

        "xcode.syntax.keyword": .keyword,
        "xcode.syntax.attribute": .keyword,
        "xcode.syntax.preprocessor": .keyword,

        "xcode.syntax.comment": .comment,
        "xcode.syntax.comment.doc": .comment,
        "xcode.syntax.comment.doc.keyword": .comment,
        "xcode.syntax.mark": .comment,
        "xcode.syntax.markup.aside.kind": .comment,
        "xcode.syntax.markup.code": .comment,

        "xcode.syntax.number": .numeric,
        "xcode.syntax.character": .numeric,

        // Names of things, as used rather than declared.
        "xcode.syntax.identifier.class": .type(.class, .name),
        "xcode.syntax.identifier.class.system": .type(.class, .name),
        "xcode.syntax.identifier.type": .type(.class, .name),
        "xcode.syntax.identifier.type.system": .type(.class, .name),

        // Declarations, which is also where the app's theme files plain variables.
        "xcode.syntax.declaration.type": .variable,
        "xcode.syntax.declaration.other": .variable,
        "xcode.syntax.identifier.variable": .variable,
        "xcode.syntax.identifier.variable.system": .variable,
        "xcode.syntax.identifier.constant": .variable,
        "xcode.syntax.identifier.constant.system": .variable,
        "xcode.syntax.identifier.function": .variable,
        "xcode.syntax.identifier.function.system": .variable,

        // Nothing this app renders is a macro, so the pair is free to carry the error color —
        // which otherwise has no key of its own.
        "xcode.syntax.identifier.macro": .error,
        "xcode.syntax.identifier.macro.system": .error,
    ]

    /// The key a range of a given semantic type should be *assigned*.
    ///
    /// One key per style, deliberately: assigning two types that share a style to two different
    /// keys would be indistinguishable on screen while making the node types disagree with what
    /// the theme says. The name is also the framework's node type name, so this same table
    /// tells `SemanticNodeTypeAdjuster` what to retype a node to — that is the point of it being
    /// a table rather than a `switch`.
    static func syntaxColorKey(for semanticType: SemanticType) -> String {
        switch semanticType {
        case .comment:
            "xcode.syntax.comment"
        case .keyword:
            "xcode.syntax.keyword"
        case .numeric:
            "xcode.syntax.number"
        case .error:
            "xcode.syntax.identifier.macro"
        case .variable, .function(.declaration), .member(.declaration), .type(_, .declaration):
            "xcode.syntax.declaration.other"
        case .type(_, .name), .function(.name), .member(.name):
            "xcode.syntax.identifier.class"
        case .standard, .argument, .other:
            "xcode.syntax.plain"
        }
    }

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

        for (key, semanticType) in styleRepresentativeByThemeKey {
            syntaxColors[key] = themeString(for: themeProfile.color(for: semanticType))
            syntaxFonts[key] = themeString(for: themeProfile.font(for: semanticType))
        }

        converted["DVTSourceTextSyntaxColors"] = syntaxColors
        converted["DVTSourceTextSyntaxFonts"] = syntaxFonts
        converted["DVTSourceTextBackground"] = themeString(for: themeProfile.backgroundColor)
        converted["DVTSourceTextSelectionColor"] = themeString(for: themeProfile.selectionBackgroundColor)
        converted["DVTSourceTextInsertionPointColor"] = themeString(for: themeProfile.color(for: .standard))

        // `ThemeProfile` has no current-line color, and leaving the base theme's would put an
        // Xcode-coloured band across a differently-coloured background. Deriving it from the
        // background keeps the band subtle and in-family whatever the preset.
        if let currentLineColor = currentLineHighlightColor(basedOn: themeProfile.backgroundColor) {
            converted["DVTSourceTextCurrentLineHighlightColor"] = themeString(for: currentLineColor)
        }

        return converted
    }

    /// A slightly lifted (or, on a light background, slightly dropped) version of the editor
    /// background — the same relationship Xcode's own themes use between the two.
    private static func currentLineHighlightColor(basedOn backgroundColor: NSColor) -> NSColor? {
        guard let genericRGBColor = backgroundColor.usingColorSpace(.genericRGB) else { return nil }
        let brightness = 0.299 * genericRGBColor.redComponent
            + 0.587 * genericRGBColor.greenComponent
            + 0.114 * genericRGBColor.blueComponent
        let delta: CGFloat = brightness < 0.5 ? 0.05 : -0.05
        return NSColor(
            calibratedRed: min(max(genericRGBColor.redComponent + delta, 0), 1),
            green: min(max(genericRGBColor.greenComponent + delta, 0), 1),
            blue: min(max(genericRGBColor.blueComponent + delta, 0), 1),
            alpha: genericRGBColor.alphaComponent
        )
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

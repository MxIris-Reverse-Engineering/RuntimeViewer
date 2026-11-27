#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RuntimeViewerSettings

extension UnfocusedEditorPaneDimming {
    /// `colorTheme` — an `.xccolortheme` dictionary, the form the SourceEditor pane hands the framework —
    /// with each of its colours dimmed as an editor pane without the focus draws it.
    ///
    /// For the colours the app's theme does not overwrite: the insertion point, the invisibles, markup,
    /// the scrollbar markers and the rest of the framework's own theme. A colour is a value of four numbers,
    /// `"red green blue alpha"` in generic (calibrated) RGB, at the top level or in `DVTSourceTextSyntaxColors`;
    /// fonts, `DVTLineSpacing` and `DVTFontAndColorVersion` are left alone. Its level comes from its key:
    /// - background: `DVTSourceTextBackground`, `DVTConsoleTextBackgroundColor`;
    /// - fill, only while opaque, as Xcode keeps a classic theme's translucent selection and current
    ///   line: the selections, the current line, `DVTSourceTextBlockDimBackgroundColor`, the markup
    ///   background and border, `DVTDebuggerInstructionPointerColor`;
    /// - text, flattened over the theme's own undimmed `DVTSourceTextBackground` first: every other colour.
    ///
    /// Xcode's conversion of a classic theme gives the insertion point, the invisibles and the syntax
    /// colours the text level and the selection and the current line the fill level; the other keys are
    /// filed by whether they are drawn under or over the text (proposal `dim-unfocused-editor-panes`).
    public static func dimmedColorTheme(_ colorTheme: NSDictionary, colorScheme: ColorScheme) -> NSDictionary {
        guard let dimmedTheme = colorTheme.mutableCopy() as? NSMutableDictionary else { return colorTheme }
        let background = (colorTheme[sourceTextBackgroundKey] as? String).flatMap(colorValue(fromThemeString:))

        func dimmedThemeString(_ themeString: String, level: ContrastLevel) -> String? {
            guard let color = colorValue(fromThemeString: themeString) else { return nil }
            switch level {
            case .background:
                return self.themeString(for: dimmed(color, level: .background, colorScheme: colorScheme))
            case .fill:
                guard color.alpha >= 1 else { return nil }
                return self.themeString(for: dimmed(color, level: .fill, colorScheme: colorScheme))
            case .text:
                let opaqueColor = background.map { flattened(color, over: $0) } ?? color
                return self.themeString(for: dimmed(opaqueColor, level: .text, colorScheme: colorScheme))
            }
        }

        for case let key as String in colorTheme.allKeys {
            guard let themeString = colorTheme[key] as? String else { continue }
            if let dimmedString = dimmedThemeString(themeString, level: colorThemeLevel(forKey: key)) {
                dimmedTheme[key] = dimmedString
            }
        }
        if let syntaxColors = colorTheme[syntaxColorsKey] as? NSDictionary,
           let dimmedSyntaxColors = syntaxColors.mutableCopy() as? NSMutableDictionary {
            for case let key as String in syntaxColors.allKeys {
                guard let themeString = syntaxColors[key] as? String else { continue }
                if let dimmedString = dimmedThemeString(themeString, level: .text) {
                    dimmedSyntaxColors[key] = dimmedString
                }
            }
            dimmedTheme[syntaxColorsKey] = dimmedSyntaxColors
        }
        return dimmedTheme
    }

    private static let sourceTextBackgroundKey = "DVTSourceTextBackground"
    private static let syntaxColorsKey = "DVTSourceTextSyntaxColors"

    private static let colorThemeBackgroundKeys: Set<String> = [
        sourceTextBackgroundKey,
        "DVTConsoleTextBackgroundColor",
    ]

    private static let colorThemeFillKeys: Set<String> = [
        "DVTSourceTextCurrentLineHighlightColor",
        "DVTSourceTextSelectionColor",
        "DVTConsoleTextSelectionColor",
        "DVTSourceTextBlockDimBackgroundColor",
        "DVTMarkupTextBackgroundColor",
        "DVTMarkupTextBorderColor",
        "DVTDebuggerInstructionPointerColor",
    ]

    private static func colorThemeLevel(forKey key: String) -> ContrastLevel {
        if colorThemeBackgroundKeys.contains(key) { return .background }
        if colorThemeFillKeys.contains(key) { return .fill }
        return .text
    }

    /// The sRGB colour of a theme value of four numbers, which the framework reads as generic RGB;
    /// `nil` for any other value, such as a font.
    private static func colorValue(fromThemeString themeString: String) -> Settings.Theme.ColorValue? {
        let components = themeString.split(separator: " ").compactMap { Double($0) }
        guard components.count == 4, themeString.split(separator: " ").count == 4 else { return nil }
        let genericRGBColor = NSColor(calibratedRed: components[0], green: components[1], blue: components[2], alpha: components[3])
        guard let sRGBColor = genericRGBColor.usingColorSpace(.sRGB) else { return nil }
        return .rgb(Double(sRGBColor.redComponent), Double(sRGBColor.greenComponent), Double(sRGBColor.blueComponent), Double(sRGBColor.alphaComponent))
    }

    /// `"red green blue alpha"` in generic RGB, the form the framework reads.
    private static func themeString(for color: Settings.Theme.ColorValue) -> String {
        let sRGBColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        guard let genericRGBColor = sRGBColor.usingColorSpace(.genericRGB) else { return "0 0 0 1" }
        return "\(genericRGBColor.redComponent) \(genericRGBColor.greenComponent) \(genericRGBColor.blueComponent) \(genericRGBColor.alphaComponent)"
    }
}
#endif

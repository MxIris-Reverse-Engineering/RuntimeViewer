import AppKit
import Foundation
import Testing
import RuntimeViewerSettings
@testable import RuntimeViewerAppUI

/// The SourceEditor theme dictionary of an editor pane without the focus (proposal
/// `dim-unfocused-editor-panes`): the colours the app's theme does not overwrite — the insertion point,
/// the invisibles, markup, the scrollbar markers — dim with the rest, each at its key's level.
@Suite("Unfocused editor pane colour theme dimming")
struct UnfocusedEditorPaneColorThemeDimmingTests {
    private static let colorTheme: NSDictionary = [
        "DVTSourceTextBackground": "0.5 0.5 0.5 1",
        "DVTSourceTextSelectionColor": "0.5 0.5 0.5 1",
        "DVTSourceTextCurrentLineHighlightColor": "0.3 0.3 0.4 0.5",
        "DVTSourceTextInvisiblesColor": "0.2 0.2 0.2 1",
        "DVTMarkupTextInlineCodeColor": "1 1 1 0.5",
        "DVTSourceTextSyntaxColors": ["xcode.syntax.plain": "0.2 0.2 0.2 1"],
        "DVTSourceTextSyntaxFonts": ["xcode.syntax.plain": "SFMono-Medium - 12.0"],
        "DVTMarkupTextNormalFont": "SFMono-Regular - 10.0",
        "DVTLineSpacing": "1.100000023841858",
        "DVTFontAndColorVersion": "1",
    ]

    /// A theme value read back as the framework reads it — generic RGB — in sRGB.
    private static func sRGBColor(of themeString: Any?) throws -> Settings.Theme.ColorValue {
        let components = try #require(themeString as? String).split(separator: " ").compactMap { Double($0) }
        try #require(components.count == 4)
        let color = try #require(NSColor(calibratedRed: components[0], green: components[1], blue: components[2], alpha: components[3]).usingColorSpace(.sRGB))
        return .rgb(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent))
    }

    private static func isClose(_ color: Settings.Theme.ColorValue, to expectedColor: Settings.Theme.ColorValue) -> Bool {
        let tolerance = 1e-5
        return abs(color.red - expectedColor.red) <= tolerance
            && abs(color.green - expectedColor.green) <= tolerance
            && abs(color.blue - expectedColor.blue) <= tolerance
            && abs(color.alpha - expectedColor.alpha) <= tolerance
    }

    @Test("the background takes the background factors and the selection the fill factors")
    func colorThemeColorsAreDimmedByTheirKeysLevel() throws {
        let dimmedTheme = UnfocusedEditorPaneDimming.dimmedColorTheme(Self.colorTheme, colorScheme: .dark)

        let background = try Self.sRGBColor(of: Self.colorTheme["DVTSourceTextBackground"])
        let dimmedBackground = try Self.sRGBColor(of: dimmedTheme["DVTSourceTextBackground"])
        #expect(Self.isClose(dimmedBackground, to: UnfocusedEditorPaneDimming.dimmed(background, level: .background, colorScheme: .dark)))
        let selection = try Self.sRGBColor(of: Self.colorTheme["DVTSourceTextSelectionColor"])
        let dimmedSelection = try Self.sRGBColor(of: dimmedTheme["DVTSourceTextSelectionColor"])
        #expect(Self.isClose(dimmedSelection, to: UnfocusedEditorPaneDimming.dimmed(selection, level: .fill, colorScheme: .dark)))
    }

    @Test("every other colour, the syntax colours too, is dimmed as text")
    func otherColorsAreDimmedAsText() throws {
        let dimmedTheme = UnfocusedEditorPaneDimming.dimmedColorTheme(Self.colorTheme, colorScheme: .light)

        let invisibles = try Self.sRGBColor(of: Self.colorTheme["DVTSourceTextInvisiblesColor"])
        let expectedColor = UnfocusedEditorPaneDimming.dimmed(invisibles, level: .text, colorScheme: .light)
        let dimmedInvisibles = try Self.sRGBColor(of: dimmedTheme["DVTSourceTextInvisiblesColor"])
        #expect(Self.isClose(dimmedInvisibles, to: expectedColor))
        let syntaxColors = try #require(dimmedTheme["DVTSourceTextSyntaxColors"] as? NSDictionary)
        let dimmedPlainText = try Self.sRGBColor(of: syntaxColors["xcode.syntax.plain"])
        #expect(Self.isClose(dimmedPlainText, to: expectedColor), "the same colour as the invisibles, at the same level")
    }

    @Test("a translucent text colour is flattened over the theme's undimmed background first")
    func translucentColorThemeTextIsFlattenedOverTheBackground() throws {
        let dimmedTheme = UnfocusedEditorPaneDimming.dimmedColorTheme(Self.colorTheme, colorScheme: .dark)

        let inlineCode = try Self.sRGBColor(of: Self.colorTheme["DVTMarkupTextInlineCodeColor"])
        let background = try Self.sRGBColor(of: Self.colorTheme["DVTSourceTextBackground"])
        let expectedColor = UnfocusedEditorPaneDimming.dimmed(UnfocusedEditorPaneDimming.flattened(inlineCode, over: background), level: .text, colorScheme: .dark)
        let dimmedInlineCode = try Self.sRGBColor(of: dimmedTheme["DVTMarkupTextInlineCodeColor"])
        #expect(Self.isClose(dimmedInlineCode, to: expectedColor))
        #expect(dimmedInlineCode.alpha == 1)
    }

    @Test("a translucent fill, such as this current-line highlight, is kept as it is")
    func translucentColorThemeFillsStayUnchanged() {
        let dimmedTheme = UnfocusedEditorPaneDimming.dimmedColorTheme(Self.colorTheme, colorScheme: .dark)

        #expect(dimmedTheme["DVTSourceTextCurrentLineHighlightColor"] as? String == "0.3 0.3 0.4 0.5")
    }

    @Test("fonts, the line spacing and the format version are left alone")
    func fontsLineSpacingAndVersionAreLeftAlone() {
        let dimmedTheme = UnfocusedEditorPaneDimming.dimmedColorTheme(Self.colorTheme, colorScheme: .dark)

        #expect(dimmedTheme["DVTMarkupTextNormalFont"] as? String == "SFMono-Regular - 10.0")
        #expect(dimmedTheme["DVTLineSpacing"] as? String == "1.100000023841858")
        #expect(dimmedTheme["DVTFontAndColorVersion"] as? String == "1")
        #expect((dimmedTheme["DVTSourceTextSyntaxFonts"] as? NSDictionary)?["xcode.syntax.plain"] as? String == "SFMono-Medium - 12.0")
    }
}

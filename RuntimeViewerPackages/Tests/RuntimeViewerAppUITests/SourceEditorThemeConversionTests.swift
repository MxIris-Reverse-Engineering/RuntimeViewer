import AppKit
import Foundation
import Testing
import Semantic
@testable import RuntimeViewerAppUI

/// `SourceEditorThemeConversion`, which both content panes now take from RuntimeViewerAppUI: the
/// theme dictionary the editor is handed, and the Menlo face the UIKit build gets for the system
/// font it cannot look up by name.
@Suite("SourceEditorThemeConversion")
struct SourceEditorThemeConversionTests {
    /// Keywords in one colour, everything else in another, all in the monospaced system font.
    private struct TwoColourThemeProfile: ThemeProfile {
        static let keywordColor = NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.2, alpha: 1)
        static let otherColor = NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.3, alpha: 1)

        var selectionBackgroundColor: NSUIColor { NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1) }
        var backgroundColor: NSUIColor { NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1) }
        var currentLineHighlightColor: NSUIColor { NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1) }
        var fontSize: CGFloat { 13 }

        func font(for type: SemanticType) -> NSUIFont {
            .monospacedSystemFont(ofSize: 13, weight: .regular)
        }

        func color(for type: SemanticType) -> NSUIColor {
            if case .keyword = type { return Self.keywordColor }
            return Self.otherColor
        }
    }

    private static func baseTheme() -> NSDictionary {
        [
            "DVTSourceTextSyntaxColors": ["xcode.syntax.keyword": "0 0 0 1", "xcode.syntax.url": "0 0 0 1"],
            "DVTSourceTextSyntaxFonts": ["xcode.syntax.keyword": "SFMono-Regular - 12.0"],
            "DVTConsoleTextBackgroundColor": "1 1 1 1",
        ]
    }

    @Test("every syntax key is written in the profile's colour for its style, and keys the profile has no say in stay")
    func themeDictionaryWritesTheProfileOverTheBaseTheme() throws {
        let dictionary = try #require(SourceEditorThemeConversion.themeDictionary(
            from: TwoColourThemeProfile(),
            basedOn: Self.baseTheme(),
            baseThemeDimming: nil
        ))
        let syntaxColors = try #require(dictionary["DVTSourceTextSyntaxColors"] as? [String: String])
        let syntaxFonts = try #require(dictionary["DVTSourceTextSyntaxFonts"] as? [String: String])

        #expect(syntaxColors["xcode.syntax.keyword"] == "0.8 0.1 0.2 1.0")
        #expect(syntaxColors["xcode.syntax.attribute"] == "0.8 0.1 0.2 1.0")
        #expect(syntaxColors["xcode.syntax.identifier.class"] == "0.1 0.5 0.3 1.0")
        #expect(syntaxColors.count == 28)
        #expect(syntaxFonts["xcode.syntax.keyword"]?.hasSuffix(" - 13.0") == true)
        #expect(dictionary["DVTSourceTextBackground"] as? String == "0.1 0.1 0.1 1.0")
        #expect(dictionary["DVTConsoleTextBackgroundColor"] as? String == "1 1 1 1")
    }

    @Test("a base theme without the syntax tables gives no dictionary")
    func malformedBaseThemeGivesNothing() {
        #expect(SourceEditorThemeConversion.themeDictionary(
            from: TwoColourThemeProfile(),
            basedOn: ["DVTSourceTextBackground": "0 0 0 1"],
            baseThemeDimming: nil
        ) == nil)
    }

    @Test("the system font stands in as the Menlo face of the same weight and slant")
    func systemFontStandInFollowsWeightAndSlant() {
        #expect(SourceEditorThemeConversion.systemFontStandInName(isBold: false, isItalic: false) == "Menlo-Regular")
        #expect(SourceEditorThemeConversion.systemFontStandInName(isBold: true, isItalic: false) == "Menlo-Bold")
        #expect(SourceEditorThemeConversion.systemFontStandInName(isBold: false, isItalic: true) == "Menlo-Italic")
        #expect(SourceEditorThemeConversion.systemFontStandInName(isBold: true, isItalic: true) == "Menlo-BoldItalic")
    }
}

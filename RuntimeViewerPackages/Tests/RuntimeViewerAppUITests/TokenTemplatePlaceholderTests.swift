import Foundation
import Testing

@testable import RuntimeViewerSettingsUI

/// The UIKit template editor finds and restores `${name}` placeholders through
/// `TokenTemplatePlaceholder`; the AppKit editor applies the same rules on its
/// own. These pin the rules both must follow — a template typed on one
/// platform has to read back identically on the other.
@Suite("Transformer template placeholders")
struct TokenTemplatePlaceholderTests {
    @Test("every placeholder is found in order, with its range and name")
    func findsEveryPlaceholder() {
        let template = "Offset ${offset} of ${name}"
        let matches = TokenTemplatePlaceholder.matches(in: template)

        #expect(matches == [
            .init(range: NSRange(location: 7, length: 9), name: "offset"),
            .init(range: NSRange(location: 20, length: 7), name: "name"),
        ])
    }

    @Test("a token already shown is not a placeholder")
    func objectReplacementCharacterIsSkipped() {
        let matches = TokenTemplatePlaceholder.matches(in: "\u{FFFC} + ${size}")

        #expect(matches.map(\.name) == ["size"])
        #expect(matches.first?.range == NSRange(location: 4, length: 7))
    }

    @Test("a name is the placeholder without every ${ and }, as the AppKit editor reads it")
    func nameDropsEveryBraceMarker() {
        #expect(TokenTemplatePlaceholder.matches(in: "${${x}").map(\.name) == ["x"])
    }

    @Test("a placeholder round-trips through its name")
    func placeholderRoundTrips() {
        let template = "${offset}"
        let name = TokenTemplatePlaceholder.matches(in: template).first?.name

        #expect(name.map(TokenTemplatePlaceholder.placeholder(forName:)) == template)
    }

    @Test("the caret moves back by what the placeholders before it shrink by")
    func caretFollowsReplacements() {
        // "ab${x}cd": the placeholder becomes one character, four fewer.
        let matches = TokenTemplatePlaceholder.matches(in: "ab${x}cd")

        #expect(TokenTemplatePlaceholder.caretLocation(8, afterReplacing: matches) == 5)
        #expect(TokenTemplatePlaceholder.caretLocation(6, afterReplacing: matches) == 3)
        #expect(TokenTemplatePlaceholder.caretLocation(2, afterReplacing: matches) == 2)
    }
}

import AppKit
import Foundation
import Testing
import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
import RuntimeViewerAppUI

/// A recent query's title in the query field's menu, its find patterns drawn as the field draws
/// them (`FindRecentQueries.attributedTitle(for:font:)`, RuntimeViewerAppUI). The plain title and
/// the recording rules are RuntimeViewerAppCore's, tested in `FindRecentQueriesTests`.
@Suite("FindRecentQueries attributed title")
@MainActor
struct FindRecentQueriesAttributedTitleTests {
    @Test("the menu's title draws the patterns between the quotes as tokens, in the menu's font")
    func attributedTitleDrawsTokens() {
        let digits = FindPattern.digits(identifier: "digits")
        let query = FindQuery(term: FindQueryTerm(components: [.text("build "), .pattern(digits)]))
        let font = NSFont.menuFont(ofSize: 10)
        let attributedTitle = FindRecentQueries.attributedTitle(for: query, font: font)
        #expect(attributedTitle.string == "In Indexed Images, text containing “build \u{FFFC}”, ignore case")
        #expect(FindRecentQueries.title(for: query) == "In Indexed Images, text containing “build ”, ignore case")

        var attachmentCount = 0
        attributedTitle.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedTitle.length)) { attachment, _, _ in
            if attachment != nil { attachmentCount += 1 }
        }
        #expect(attachmentCount == 1)
        #expect(attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        #expect(attributedTitle.attribute(.font, at: attributedTitle.length - 1, effectiveRange: nil) as? NSFont == font)
    }
}

import AppKit
import Testing
import RuntimeViewerUI
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// `NSAttributedString(rowText:fontSize:color:)` replaced UIFoundation's attributed string builder in
/// the rows' cell view models (proposal `app-core-ui-split`): a row's title has to come out
/// attribute for attribute as the builder made it.
@Suite("Row text")
struct RowTextAttributedStringTests {
    @Test("A coloured row text has the attributes the builder gave it")
    func colouredRowTextMatchesTheBuilder() {
        let rowText = NSAttributedString(rowText: "NSObject", fontSize: 12, color: .secondaryLabelColor)

        let builtText = NSAttributedString {
            AText("NSObject")
                .foregroundColor(.secondaryLabelColor)
                .font(.systemFont(ofSize: 12))
                .alignment(.left)
                .lineBreakeMode(.byTruncatingTail)
        }

        #expect(rowText.isEqual(to: builtText))
    }

    @Test("A row text without a colour has the attributes the builder gave it, and no colour")
    func uncolouredRowTextMatchesTheBuilder() {
        let rowText = NSAttributedString(rowText: "Foundation", fontSize: 13)

        let builtText = NSAttributedString {
            AText("Foundation")
                .font(.systemFont(ofSize: 13))
                .alignment(.left)
                .lineBreakeMode(.byTruncatingTail)
        }

        #expect(rowText.isEqual(to: builtText))
        #expect(rowText.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }

    // MARK: - RowText in a list

    /// A row's `RowText` replaced the attributed strings its cell view model built (proposal
    /// `app-core-without-ui-models`): drawn in a list, each role comes out as the old title did.
    @Test("A list draws each role of a row's text as the old row titles were made", arguments: [
        (RowText.Role.primary, NSColor.labelColor),
        (.secondary, .secondaryLabelColor),
        (.tertiary, .tertiaryLabelColor),
    ])
    func listDrawsEachRoleAsTheOldRowTextInitializerDid(role: RowText.Role, color: NSColor) {
        let drawnText = RowText("NSObject", role: role, fontSize: 12).attributedString(in: .list)

        #expect(drawnText.isEqual(to: NSAttributedString(rowText: "NSObject", fontSize: 12, color: color)))
    }

    @Test("A list draws a filter's matches in the label colour, semibold, as the sidebar did")
    func listDrawsEmphasisAsTheSidebarDid() {
        let drawnText = RowText("NSViewController", role: .tertiary, fontSize: 13)
            .marking([NSRange(location: 2, length: 4)], as: .emphasized)
            .attributedString(in: .list)

        let expectedText = NSMutableAttributedString(attributedString: NSAttributedString(rowText: "NSViewController", fontSize: 13, color: .tertiaryLabelColor))
        expectedText.addAttributes([
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ], range: NSRange(location: 2, length: 4))

        #expect(drawnText.isEqual(to: expectedText))
    }

    @Test("A row's text that names no size is drawn at 13 points")
    func listDrawsTextWithoutASizeAtThirteenPoints() {
        let drawnText = RowText("Foundation").attributedString(in: .list)

        #expect((drawnText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 13)
    }
}

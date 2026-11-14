import AppKit
import Testing
import RuntimeViewerUI
@testable import RuntimeViewerAppCore

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
}

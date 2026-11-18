import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// How a Find result row is drawn: RuntimeViewerAppCore describes the row (`FindResultNodeTests`), and
/// the cell view draws it at its list's sizes (proposal `app-core-without-ui-models`).
@Suite("Find result row style")
@MainActor
struct FindResultCellStyleTests {
    /// The Inspector's References tab lists the same rows beside text of its own set in the small
    /// system font, so it draws them a size down; the Find navigator keeps Xcode's sizes.
    @Test("the Inspector draws a cross-reference row a size down, and the Find navigator keeps its size")
    func inspectorRowsAreASizeDown() {
        let function = RuntimeFunctionReference(
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            address: 0x1_8B49_DB50,
            displayName: "-[NSWindow _windowNumber]",
            symbolName: "-[NSWindow _windowNumber]",
            member: nil,
            foldedSymbolCount: 0
        )
        // Two references, so the title has a subtitle, `AppKit · 2 references`, in the second font.
        let row = FindCrossReferenceRow(item: .function(function), direction: .typeReferences, referenceCount: 2, precision: .exact)
        let appearance = FindResultNode.crossReference(row, identifier: "row", children: []).appearance

        #expect(Self.fontSizes(in: appearance.title.attributedString(in: .findResult(.navigator))) == [13])
        #expect(Self.fontSizes(in: appearance.title.attributedString(in: .findResult(.inspector))) == [NSFont.smallSystemFontSize])
        #expect(appearance.icon?.image(size: FindResultCellStyle.Metrics.navigator.iconSize).size == NSSize(width: 16, height: 16))
        #expect(appearance.icon?.image(size: FindResultCellStyle.Metrics.inspector.iconSize).size == NSSize(width: 14, height: 14))
    }

    @Test("a hit is drawn in bold in the matching colour, and the rest of its line in the hit-line font and colour")
    func hitIsBoldInTheMatchingColour() {
        let drawnText = RowText("- (void)didSelect;", role: .hitLine)
            .marking([NSRange(location: 8, length: 9)], as: .emphasized)
            .attributedString(in: .findResult(.navigator))

        #expect(drawnText.attribute(.font, at: 8, effectiveRange: nil) as? NSFont == FindResultCellStyle.emphasisFont)
        #expect(drawnText.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == FindResultCellStyle.emphasisColor)
        #expect(drawnText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == FindResultCellStyle.hitLineFont)
        #expect(drawnText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == FindResultCellStyle.hitLineColor)
    }

    /// Every point size the title is set in.
    private static func fontSizes(in title: NSAttributedString) -> Set<CGFloat> {
        var pointSizes: Set<CGFloat> = []
        title.enumerateAttribute(.font, in: NSRange(location: 0, length: title.length)) { font, _, _ in
            if let font = font as? NSFont {
                pointSizes.insert(font.pointSize)
            }
        }
        return pointSizes
    }
}

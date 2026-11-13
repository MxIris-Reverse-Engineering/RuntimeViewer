import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerUI
import Testing
@testable import RuntimeViewerAppCore

/// A Find result row's title drawn in the label `FindResultCellView` sets it in. What the row holds
/// is `FindResultNodeTests`'.
@Suite("Find result row drawing")
@MainActor
struct FindResultRowDrawingTests {
    /// A row's title is an attributed string, which AppKit breaks by its own paragraph style, not
    /// by the label's `lineBreakMode` (`NSCell.wraps`). Without one the title wrapped by word and
    /// the one-line label drew its first line alone: `-` for an Objective-C method in the
    /// Inspector's References tab, the first piece of a long Swift name.
    @Test("a title too long for its row runs on one line to the row's end, rather than stopping at its first line break")
    func longTitlesTruncateOnOneLine() throws {
        let function = RuntimeFunctionReference(
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            address: 0x1_8B49_DB50,
            displayName: "-[NSDebugTDTextViewInspectorPanel _panelDidOrderOnScreen]",
            symbolName: "-[NSDebugTDTextViewInspectorPanel _panelDidOrderOnScreen]",
            member: nil,
            foldedSymbolCount: 0
        )
        let row = FindCrossReferenceRow(item: .function(function), direction: .typeReferences, referenceCount: 1, precision: .exact)
        let node = FindResultNode.crossReference(row, identifier: "row", children: [])
        // The title as `FindResultCellView` sets it up, at about the Inspector's width.
        let label = Label(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = node.appearance.title
        label.frame = NSRect(x: 0, y: 0, width: 240, height: 18)

        // The `-` alone ends a few points in.
        let drawnWidth = try Self.drawnWidth(of: label)
        #expect(drawnWidth > 200)
    }

    /// How far right a view draws, in points: the trailing edge of its last column with ink.
    private static func drawnWidth(of view: NSView) throws -> CGFloat {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var lastInkedColumn = -1
        for column in 0 ..< bitmap.pixelsWide {
            for pixelRow in 0 ..< bitmap.pixelsHigh where (bitmap.colorAt(x: column, y: pixelRow)?.alphaComponent ?? 0) > 0.1 {
                lastInkedColumn = column
                break
            }
        }
        return CGFloat(lastInkedColumn + 1) * view.bounds.width / CGFloat(bitmap.pixelsWide)
    }
}

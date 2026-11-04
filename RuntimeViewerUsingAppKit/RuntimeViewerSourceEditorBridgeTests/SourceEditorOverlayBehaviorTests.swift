// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if canImport(SourceEditor)

import AppKit
import CoreText
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Pins the behaviour of Xcode's layout machinery that the comment decorations are built on —
/// the parts the decompilation of 27.2 could not settle — against whichever Xcode the bundle runs
/// under.
///
/// Every test registers providers of its own on the bridge's editor, so what it measures is the
/// framework, not the bridge. They are the evidence the proposal
/// `source-editor-comment-annotations` cites: when one fails on a new Xcode, whatever the
/// decorations build on that behaviour needs another look.
@Suite("SourceEditorOverlayBehavior", .serialized)
@MainActor
struct SourceEditorOverlayBehaviorTests {
    /// Line 0 is 19 columns: the 3-column `// ` marker, then the 16 columns of `Address: 0x135DC`.
    private static let addressSource = """
    // Address: 0x135DC
    let a = 1
    """

    private static let fieldLayoutSource = """
    // Field offset: 0x8
    // ├── origin (__C.CGPoint): 0x8
    // │   └── x (CoreGraphics.CGFloat): 0x8
    // └── size (__C.CGSize): 0x18
    let rect: CGRect
    """

    // MARK: - Hidden Columns

    @Test
    func hiddenColumnsCloseUp() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let hider = ColumnHider()
        hider.visibleColumnsByLine[0] = [3 ..< 19]
        harness.editorView.layoutManager.addLayoutOverrideProvider(hider)
        Self.rebuildLines(in: harness)

        let rendered = try Self.renderedLine(0, in: harness)
        #expect(rendered.string.hasPrefix("Address: 0x135DC"), "rendered as \(rendered.string.debugDescription)")
    }

    /// The trap the decompilation found: an empty answer is read as "hide nothing", not as
    /// "hide everything", and the only way to hide a whole line is an empty range.
    @Test
    func anEmptyAnswerShowsTheWholeLine() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let hider = ColumnHider()
        harness.editorView.layoutManager.addLayoutOverrideProvider(hider)

        hider.visibleColumnsByLine[0] = []
        Self.rebuildLines(in: harness)
        let showingEverything = try Self.renderedLine(0, in: harness).string
        #expect(showingEverything.hasPrefix("// Address"), "rendered as \(showingEverything.debugDescription)")

        hider.visibleColumnsByLine[0] = [0 ..< 0]
        Self.rebuildLines(in: harness)
        let showingNothing = try Self.renderedLine(0, in: harness).string
        #expect(
            showingNothing.trimmingCharacters(in: .newlines).isEmpty,
            "rendered as \(showingNothing.debugDescription)"
        )
    }

    // MARK: - Attribute Overrides

    /// Whether an override's columns count the source line or what is left of it once columns are
    /// hidden. A decoration hides the marker and colours the word after it, so the two have to agree.
    @Test
    func attributeOverridesCountSourceColumns() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let hider = ColumnHider()
        hider.visibleColumnsByLine[0] = [3 ..< 19]
        let colorer = AttributeColorer()
        colorer.overridesByLine[0] = [
            SourceEditorTextAttributeOverride(range: 3 ..< 10, attr: [.foregroundColor: NSColor.systemRed]),
        ]
        harness.editorView.layoutManager.addLayoutOverrideProvider(hider)
        harness.editorView.layoutManager.addLayoutOverrideProvider(colorer)
        Self.rebuildLines(in: harness)

        let rendered = try Self.renderedLine(0, in: harness)
        let redRuns = Self.runs(of: NSColor.systemRed, in: rendered)
        #expect(
            redRuns == [NSRange(location: 0, length: 7)],
            "red runs \(redRuns) in \(rendered.string.debugDescription) — `Address` is columns 3..<10 of the source and 0..<7 of the rendering"
        )
    }

    // MARK: - Column Shifts

    @Test
    func aColumnShiftMovesTheTextFromItsColumnOn() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let before = try Self.columnOrigins([1, 5], onLine: 0, in: harness)

        let shifter = ColumnShifter()
        shifter.shiftsByLine[0] = [3: 20]
        harness.editorView.layoutManager.addLayoutOverrideProvider(shifter)
        Self.rebuildLines(in: harness)
        let after = try Self.columnOrigins([1, 5], onLine: 0, in: harness)

        #expect(abs(after[1]! - before[1]!) < 0.5, "column 1, before the shift, moved from \(before[1]!) to \(after[1]!)")
        #expect(abs(after[5]! - before[5]! - 20) < 0.5, "column 5 moved from \(before[5]!) to \(after[5]!), not by 20")
    }

    @Test
    func columnShiftsOnOneLineAddUp() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let before = try Self.columnOrigins([5, 12], onLine: 0, in: harness)

        let shifter = ColumnShifter()
        shifter.shiftsByLine[0] = [3: 20, 10: 10]
        harness.editorView.layoutManager.addLayoutOverrideProvider(shifter)
        Self.rebuildLines(in: harness)
        let after = try Self.columnOrigins([5, 12], onLine: 0, in: harness)

        #expect(abs(after[5]! - before[5]! - 20) < 0.5, "column 5 moved from \(before[5]!) to \(after[5]!)")
        #expect(abs(after[12]! - before[12]! - 30) < 0.5, "column 12 moved from \(before[12]!) to \(after[12]!), not by 20 + 10")
    }

    /// With the marker hidden, a shift keyed by the first visible source column has to move that
    /// column — the decorations pad a tag by shifting the column its text starts at.
    @Test
    func aColumnShiftCountsSourceColumnsWhenColumnsAreHidden() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let hider = ColumnHider()
        hider.visibleColumnsByLine[0] = [3 ..< 19]
        harness.editorView.layoutManager.addLayoutOverrideProvider(hider)
        Self.rebuildLines(in: harness)
        let before = try Self.columnOrigins([3, 6], onLine: 0, in: harness)

        let shifter = ColumnShifter()
        shifter.shiftsByLine[0] = [3: 20]
        harness.editorView.layoutManager.addLayoutOverrideProvider(shifter)
        Self.rebuildLines(in: harness)
        let after = try Self.columnOrigins([3, 6], onLine: 0, in: harness)

        #expect(
            abs(after[3]! - before[3]! - 20) < 0.5,
            "source column 3 moved from \(before[3]!) to \(after[3]!); source column 6 from \(before[6]!) to \(after[6]!)"
        )
    }

    // MARK: - Line Height

    /// What raises a line that holds tags: a run that takes no width but reaches further above
    /// and below the baseline than the font does. 26.6's `CoreTextLineLayout.layout(boundsWidth:minLineHeight:)`
    /// measures each line with `CTLineGetTypographicBounds` (0xF878), so the line grows by what
    /// the run adds, the next line moves down by as much, the text keeps its columns, and the
    /// baseline goes where the run's ascent puts it — with equal halves, the text sits in the
    /// middle.
    ///
    /// The editor itself offers no taller line: `setLineExpansionEffectForLine(_:height:)` is read
    /// only in `layoutContentForLine` (26.6, 0x750C4) and only for a height under the line's
    /// own, which it cuts the line down to — the animation that reveals inserted lines.
    @Test
    func aTallerZeroWidthRunRaisesItsLineAroundItsText() throws {
        let harness = try Self.harness(showing: Self.addressSource)
        // `//` hidden and the space after it drawn: the space is what carries the run.
        let hider = ColumnHider()
        hider.visibleColumnsByLine[0] = [2 ..< 19]
        harness.editorView.layoutManager.addLayoutOverrideProvider(hider)
        Self.rebuildLines(in: harness)
        let font = try Self.font(of: "Address", onLine: 0, in: harness)
        let plain = try Self.measureFirstLine(in: harness)

        let spacing: CGFloat = 6
        let runDelegate = try #require(ZeroWidthRunDelegate.make(ascent: font.ascender + spacing / 2, descent: -font.descender + spacing / 2))
        let raiser = AttributeColorer()
        raiser.overridesByLine[0] = [
            SourceEditorTextAttributeOverride(range: 2 ..< 3, attr: [NSAttributedString.Key(kCTRunDelegateAttributeName as String): runDelegate]),
        ]
        harness.editorView.layoutManager.addLayoutOverrideProvider(raiser)
        Self.rebuildLines(in: harness)
        let raised = try Self.measureFirstLine(in: harness)

        #expect(abs(raised.row.height - plain.row.height - spacing) < 0.5, "row \(plain.row) → \(raised.row)")
        #expect(abs(raised.distanceToNextRow - plain.distanceToNextRow - spacing) < 0.5, "next row \(plain.distanceToNextRow) → \(raised.distanceToNextRow) points away")
        let plainCarrierMinX = try #require(plain.carrierMinX, "no selection rect for the space before it carried the run")
        #expect(abs(raised.addressMinX - plainCarrierMinX) < 0.5, "`Address` starts at \(raised.addressMinX), the space started at \(plainCarrierMinX)")
        #expect(abs(raised.ink.top - plain.ink.top - spacing / 2) < 0.75, "ink \(plain.ink) → \(raised.ink)")
        #expect(abs(raised.ink.bottom - plain.ink.bottom - spacing / 2) < 0.75, "ink \(plain.ink) → \(raised.ink)")
    }

    /// How tall the editor makes a line: its font's ascent plus descent, rounded up as a whole —
    /// not the two rounded up one by one, which comes out a point taller for most sizes of SF
    /// Mono. A tag on a raised line is drawn that tall, so the bridge has to round the same way.
    @Test(arguments: [CGFloat(12), 13, 14, 16, 18])
    func aLineIsAsTallAsItsFontsAscentPlusDescentRoundedUp(pointSize: CGFloat) throws {
        let harness = try Self.harness(showing: Self.addressSource)
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let sizer = AttributeColorer()
        sizer.overridesByLine[0] = [SourceEditorTextAttributeOverride(range: 0 ..< 19, attr: [.font: font])]
        harness.editorView.layoutManager.addLayoutOverrideProvider(sizer)
        Self.rebuildLines(in: harness)

        let range = SourceEditorPosition(line: 0, col: 0) ..< SourceEditorPosition(line: 0, col: 19)
        let rects = harness.editorView.contentView.selectionRects(for: range, coalesceInteriorRects: true, includeLineSpacing: false)
        let row = try #require(rects.first?.rect, "no selection rect for line 0")
        #expect(
            row.height == ceil(font.ascender - font.descender),
            "a \(pointSize)-point line is \(row.height) tall; its font reaches \(font.ascender) above and \(-font.descender) below"
        )
    }

    // MARK: - Folding

    /// Folding a run of `//` lines, which no language service reports as foldable, and keeping the
    /// first line: the fold starts at the end of line 0 instead of at its first column.
    @Test
    func anyRunOfCommentLinesFolds() throws {
        let harness = try Self.harness(showing: Self.fieldLayoutSource)
        let foldedRange = Self.position(endOf: 0, in: Self.fieldLayoutSource) ..< Self.position(endOf: 3, in: Self.fieldLayoutSource)

        harness.foldingController.fold(foldedRange, animate: false, completion: nil)
        harness.layout()

        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 4)) == foldedRange)
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 4, col: 0)) == nil)
        let rendered = try Self.renderedLine(0, in: harness)
        #expect(rendered.string.hasPrefix("// Field offset: 0x8"), "rendered as \(rendered.string.debugDescription)")

        let state = harness.foldingController.stateDictionaryForSaving
        let folds = try #require(state["folds"] as? [Any], "no folds in \(state)")
        #expect(folds.count == 1)
    }

    /// What expanding one level of an outline needs: unfold the outer fold and get the inner one
    /// back, still folded.
    @Test
    func unfoldingAnOuterFoldCanKeepTheFoldsInsideIt() throws {
        let harness = try Self.harness(showing: Self.fieldLayoutSource)
        let source = Self.fieldLayoutSource
        let innerRange = Self.position(endOf: 1, in: source) ..< Self.position(endOf: 2, in: source)
        let outerRange = Self.position(endOf: 0, in: source) ..< Self.position(endOf: 3, in: source)

        harness.foldingController.fold(innerRange, animate: false, completion: nil)
        harness.foldingController.fold(outerRange, animate: false, completion: nil)
        harness.layout()
        try #require(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 3, col: 4)) == outerRange)

        harness.foldingController.unfold(outerRange, restoreNestedFolds: true, animate: false)
        harness.layout()

        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 4)) == innerRange)
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 3, col: 4)) == nil)
    }

    // MARK: - Helpers

    private static func harness(showing source: String) throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness()
        harness.setSource(source)
        harness.layout()
        return harness
    }

    /// Hidden columns, shifts and attribute overrides are asked only while a line layer is built.
    ///
    /// The range has to stay inside the document: a line past its end is a `fatalError` in
    /// `SourceEditorDataSource` ("Invalid line 3 of 3"), not a no-op.
    private static func rebuildLines(in harness: SourceEditorTestHarness) {
        harness.editorView.layoutManager.evictLineLayersForLineRange(0 ..< harness.lineCount, relayout: true)
        harness.layout()
    }

    private static func renderedLine(_ line: Int, in harness: SourceEditorTestHarness) throws -> NSAttributedString {
        try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(line), "line \(line) has no layer").attributedString
    }

    private static func font(of text: String, onLine line: Int, in harness: SourceEditorTestHarness) throws -> NSFont {
        let rendered = try renderedLine(line, in: harness)
        let range = (rendered.string as NSString).range(of: text)
        try #require(range.location != NSNotFound, "\(text.debugDescription) is not in \(rendered.string.debugDescription)")
        return try #require(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private struct FirstLineMeasurement {
        /// Line 0's row, as a selection of its `Address` covers it.
        let row: CGRect
        /// From the top of line 0's row to the top of line 1's.
        let distanceToNextRow: CGFloat
        /// Where the space at column 2 starts.
        let carrierMinX: CGFloat?
        let addressMinX: CGFloat
        /// How far line 0's drawn text stays from the top and the bottom of its layer.
        let ink: (top: CGFloat, bottom: CGFloat)
    }

    /// `addressSource`'s first line, with `//` hidden: where its row and its text are.
    private static func measureFirstLine(in harness: SourceEditorTestHarness) throws -> FirstLineMeasurement {
        let contentView = harness.editorView.contentView
        func rect(line: Int, columns: Range<Int>) throws -> CGRect {
            let range = SourceEditorPosition(line: line, col: columns.lowerBound) ..< SourceEditorPosition(line: line, col: columns.upperBound)
            let rects = contentView.selectionRects(for: range, coalesceInteriorRects: true, includeLineSpacing: false).map(\.rect)
            return try #require(rects.first, "no selection rect for columns \(columns) of line \(line)")
        }
        let row = try rect(line: 0, columns: 3 ..< 10)
        let nextRow = try rect(line: 1, columns: 0 ..< 3)
        let lineLayer = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(0), "line 0 has no layer")
        let ink = try #require(inkMargins(of: lineLayer), "nothing drawn in line 0's layer \(lineLayer)")
        return FirstLineMeasurement(
            row: row,
            distanceToNextRow: contentView.isFlipped ? nextRow.minY - row.minY : row.maxY - nextRow.maxY,
            carrierMinX: (try? rect(line: 0, columns: 2 ..< 3))?.minX,
            addressMinX: row.minX,
            ink: ink
        )
    }

    /// How far what a layer draws stays from its top and its bottom edge, in points: the rows of
    /// a rendering of it that differ from its first pixel. Which edge is which does not matter to
    /// a comparison of two renderings of the same line.
    private static func inkMargins(of layer: CALayer) -> (top: CGFloat, bottom: CGFloat)? {
        let scale: CGFloat = 4
        let width = Int((layer.bounds.width * scale).rounded(.up))
        let height = Int((layer.bounds.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        let background = pixels[0]
        var inkRows: [Int] = []
        for row in 0 ..< height where (0 ..< width).contains(where: { pixels[row * width + $0] != background }) {
            inkRows.append(row)
        }
        guard let firstRow = inkRows.first, let lastRow = inkRows.last else { return nil }
        return (CGFloat(firstRow) / scale, CGFloat(height - 1 - lastRow) / scale)
    }

    /// The left edge of each column's selection rect, in the content view's coordinates.
    private static func columnOrigins(_ columns: [Int], onLine line: Int, in harness: SourceEditorTestHarness) throws -> [Int: CGFloat] {
        var origins: [Int: CGFloat] = [:]
        for column in columns {
            let range = SourceEditorPosition(line: line, col: column) ..< SourceEditorPosition(line: line, col: column + 1)
            let rects = harness.editorView.contentView.selectionRects(for: range, coalesceInteriorRects: true, includeLineSpacing: false)
            origins[column] = try #require(rects.first, "no selection rect for column \(column)").rect.minX
        }
        return origins
    }

    private static func position(endOf line: Int, in source: String) -> SourceEditorPosition {
        SourceEditorPosition(line: line, col: source.components(separatedBy: "\n")[line].utf16.count)
    }

    private static func runs(of color: NSColor, in attributedString: NSAttributedString) -> [NSRange] {
        var runs: [NSRange] = []
        attributedString.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributedString.length)) { value, range, _ in
            guard let runColor = value as? NSColor, runColor == color else { return }
            runs.append(range)
        }
        return runs
    }
}

// MARK: - Providers

private final class ColumnHider: HiddenTextOverrideProvider {
    var visibleColumnsByLine: [Int: [Range<Int>]] = [:]

    var priority: LayoutOverrideProviderPriority { .high }

    func visibleColumnRanges(for line: Int, in layoutManager: SourceEditorLayoutManager) -> [Range<Int>]? {
        visibleColumnsByLine[line]
    }

    func hiddenTextRange(enclosing position: SourceEditorPosition, in layoutManager: SourceEditorLayoutManager) -> Range<SourceEditorPosition>? {
        nil
    }
}

private final class ColumnShifter: ColumnShiftOverrideProvider {
    var shiftsByLine: [Int: [Int: CGFloat]] = [:]

    var priority: LayoutOverrideProviderPriority { .high }

    func columnShiftEffectsForLine(_ line: Int, in layoutManager: SourceEditorLayoutManager) -> [Int: CGFloat] {
        shiftsByLine[line] ?? [:]
    }
}

/// A CoreText run delegate that takes no width, with the ascent and descent it is made with.
private enum ZeroWidthRunDelegate {
    private struct Metrics {
        let ascent: CGFloat
        let descent: CGFloat
    }

    static func make(ascent: CGFloat, descent: CGFloat) -> CTRunDelegate? {
        let metrics = UnsafeMutablePointer<Metrics>.allocate(capacity: 1)
        metrics.initialize(to: Metrics(ascent: ascent, descent: descent))
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { reference in
                let metrics = reference.assumingMemoryBound(to: Metrics.self)
                metrics.deinitialize(count: 1)
                metrics.deallocate()
            },
            getAscent: { reference in reference.assumingMemoryBound(to: Metrics.self).pointee.ascent },
            getDescent: { reference in reference.assumingMemoryBound(to: Metrics.self).pointee.descent },
            getWidth: { _ in 0 }
        )
        guard let runDelegate = CTRunDelegateCreate(&callbacks, metrics) else {
            metrics.deinitialize(count: 1)
            metrics.deallocate()
            return nil
        }
        return runDelegate
    }
}

private final class AttributeColorer: TextAttributeOverrideProvider {
    var overridesByLine: [Int: [SourceEditorTextAttributeOverride]] = [:]

    var priority: LayoutOverrideProviderPriority { .high }

    func textAttributeOverridesForLine(_ line: Int, in layoutManager: SourceEditorLayoutManager) -> [SourceEditorTextAttributeOverride] {
        overridesByLine[line] ?? []
    }
}

#endif

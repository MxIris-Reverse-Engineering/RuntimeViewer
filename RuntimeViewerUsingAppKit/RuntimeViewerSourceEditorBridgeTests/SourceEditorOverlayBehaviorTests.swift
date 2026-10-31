import AppKit
import SourceEditor
import Testing

/// Pins the behaviour of Xcode's layout machinery that the comment decorations are built on —
/// the parts the decompilation of 27.2 could not settle — against whichever Xcode the bundle runs
/// under.
///
/// Every test registers providers of its own on the bridge's editor, so what it measures is the
/// framework, not the bridge. They are the evidence the proposal
/// `draft-source-editor-comment-annotations` cites: when one fails on a new Xcode, whatever the
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

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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

    // MARK: - Folding

    /// Folding a run of `//` lines, which no language service reports as foldable, and keeping the
    /// first line: the fold starts at the end of line 0 instead of at its first column.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
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

private final class AttributeColorer: TextAttributeOverrideProvider {
    var overridesByLine: [Int: [SourceEditorTextAttributeOverride]] = [:]

    var priority: LayoutOverrideProviderPriority { .high }

    func textAttributeOverridesForLine(_ line: Int, in layoutManager: SourceEditorLayoutManager) -> [SourceEditorTextAttributeOverride] {
        overridesByLine[line] ?? []
    }
}

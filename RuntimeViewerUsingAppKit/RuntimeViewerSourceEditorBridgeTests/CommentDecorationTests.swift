import AppKit
import QuartzCore
import SourceEditor
import Testing

/// Covers `CommentDecorationController` through the bridge: what a decorated comment renders as,
/// the rows that start collapsed, the disclosure triangle's click, and how decorations and folds
/// survive a change of source.
@Suite("CommentDecoration", .serialized)
@MainActor
struct CommentDecorationTests {
    /// Line 1 is the root of a field-offset tree, lines 2–4 its rows; `origin` (line 2) has a child.
    private static let fieldLayoutSource = """
    struct Probe {
        // Field offset: 0x8
        // ├── origin (__C.CGPoint): 0x8
        // │   └── x (CoreGraphics.CGFloat): 0x8
        // └── size (__C.CGSize): 0x18
        let rect: CGRect
    }
    """

    private static let otherSource = """
    struct Other {
        let value: Int
    }
    """

    // MARK: - Rendering

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aDecoratedCommentRendersWithoutItsMarkerOrColon() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: false))
        harness.layout()

        let rendered = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(1)).attributedString.string
        #expect(rendered.hasPrefix("    Field offset 0x8"), "rendered as \(rendered.debugDescription)")
    }

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func tagsAndTrianglesAreDrawnBehindTheText() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: false))
        harness.layout()

        let shown = Self.shownShapeLayers(in: harness)
        // One tag (the root), and a triangle for each of the two rows that collapse.
        #expect(shown.count == 3, "\(shown.count) shape layers shown in the underlay layer")
    }

    // MARK: - Collapsing

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func rowsThatStartCollapsedAreCollapsedTheFirstTime() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: true))
        harness.layout()

        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 0)) == Self.rootFoldRange)
        // The root's line stays on screen, and the declaration after the tree is untouched.
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 1, col: 0)) == nil)
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 5, col: 0)) == nil)

        // Expanding the root one level finds `origin` still collapsed: it was folded first.
        harness.foldingController.unfold(Self.rootFoldRange, restoreNestedFolds: true, animate: false)
        harness.layout()
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 3, col: 0)) == Self.originFoldRange)
    }

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func clickingATriangleTogglesItsRow() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: true))
        harness.layout()
        try #require(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 0)) == Self.rootFoldRange)

        // The root's triangle sits in the indentation in front of its line — the leftmost shape.
        let triangle = try #require(Self.shownShapeLayers(in: harness).min { $0.frame.minX < $1.frame.minX })
        Self.click(at: CGPoint(x: triangle.frame.midX, y: triangle.frame.midY), in: harness)
        harness.layout()

        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 0)) == nil, "the root did not expand")

        Self.click(at: CGPoint(x: triangle.frame.midX, y: triangle.frame.midY), in: harness)
        harness.layout()
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 0)) == Self.rootFoldRange, "the root did not collapse again")
    }

    // MARK: - Changing Source

    /// A source that comes back gets the folds it was left with, not its defaults again.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aSourceShownAgainKeepsItsFoldsRatherThanItsDefaults() throws {
        let harness = try SourceEditorTestHarness()
        let decorations = Self.fieldLayoutDecorations(startsCollapsed: true)
        harness.setSource(Self.fieldLayoutSource, commentDecorations: decorations)
        harness.layout()
        harness.foldingController.unfold(Self.rootFoldRange, restoreNestedFolds: true, animate: false)
        harness.layout()

        harness.setSource(Self.otherSource)
        harness.layout()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: decorations)
        harness.layout()

        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 0)) == nil, "the root came back collapsed")
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 3, col: 0)) == Self.originFoldRange)
    }

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aPlainSourceShowsNoDecorations() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: true))
        harness.layout()

        harness.setSource(Self.fieldLayoutSource)
        harness.layout()

        #expect(Self.shownShapeLayers(in: harness).isEmpty)
        // The same text without decorations has its own fold state, and no rows to collapse.
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2, col: 0)) == nil)
        let rendered = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(1)).attributedString.string
        #expect(rendered.hasPrefix("    // Field offset: 0x8"), "rendered as \(rendered.debugDescription)")
    }

    /// A text with thousands of rows that start collapsed — the size of a large framework's
    /// interface — must not turn showing it into a pause.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func collapsingThousandsOfRowsStaysQuick() throws {
        let rowCount = 2000
        var source = "struct Probe {\n"
        for index in 0 ..< rowCount {
            source += "    // Field offset: 0x\(String(index * 8, radix: 16))\n"
            source += "    // └── value (Swift.Int): 0x\(String(index * 8, radix: 16))\n"
        }
        source += "}"
        let builder = DecorationsBuilder()
        builder.source = source
        for index in 0 ..< rowCount {
            let line = 1 + index * 2
            builder.collapsible(disclosureColumns: 2 ..< 4, onLine: line, foldingThrough: line + 1, startsCollapsed: true)
        }

        let harness = try SourceEditorTestHarness()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            harness.setSource(source, commentDecorations: builder.build())
            harness.layout()
        }
        #expect(harness.foldingController.foldedRange(enclosing: SourceEditorPosition(line: 2 * rowCount, col: 0)) != nil)
        #expect(elapsed < .seconds(5), "showing \(rowCount) collapsed rows took \(elapsed)")
    }

    // MARK: - Fixtures

    private static var rootFoldRange: Range<SourceEditorPosition> {
        position(endOf: 1) ..< position(endOf: 4)
    }

    private static var originFoldRange: Range<SourceEditorPosition> {
        position(endOf: 2) ..< position(endOf: 3)
    }

    private static func position(endOf line: Int) -> SourceEditorPosition {
        SourceEditorPosition(line: line, col: fieldLayoutSource.components(separatedBy: "\n")[line].utf16.count)
    }

    /// What the app hands over for `fieldLayoutSource`: every marker hidden and the root's colon,
    /// a tag over the root, the tree prefixes concealed, and the root and `origin` collapsible.
    private static func fieldLayoutDecorations(startsCollapsed: Bool) -> SourceEditorBridgingCommentDecorations {
        let builder = DecorationsBuilder()
        builder.source = fieldLayoutSource
        for line in 1 ... 4 {
            builder.hide("// ", onLine: line)
        }
        builder.hide(":", onLine: 1)
        builder.tag("Field offset: 0x8", onLine: 1)
        builder.run("Field offset", onLine: 1, style: .label)
        builder.run("0x8", onLine: 1, style: .value)
        builder.run("├── ", onLine: 2, style: .concealed)
        builder.run("│   └── ", onLine: 3, style: .concealed)
        builder.run("└── ", onLine: 4, style: .concealed)
        builder.collapsible(disclosureColumns: 2 ..< 4, onLine: 1, foldingThrough: 4, startsCollapsed: startsCollapsed)
        builder.collapsible(disclosureColumns: 7 ..< 11, onLine: 2, foldingThrough: 3, startsCollapsed: startsCollapsed)
        return builder.build()
    }

    // MARK: - Helpers

    private static func shownShapeLayers(in harness: SourceEditorTestHarness) -> [CAShapeLayer] {
        (harness.editorView.contentView.underlayLayer.sublayers ?? [])
            .compactMap { $0 as? CAShapeLayer }
            .filter { !$0.isHidden && $0.path != nil }
    }

    /// A left click at `point` in the content view, sent the way AppKit sends one.
    private static func click(at point: CGPoint, in harness: SourceEditorTestHarness) {
        let contentView = harness.editorView.contentView
        guard let window = contentView.window else { return }
        let windowPoint = contentView.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        harness.editorView.mouseDown(with: event)
    }
}

// MARK: - Building Decorations

/// Builds decorations by naming text on a line rather than counting offsets.
private final class DecorationsBuilder {
    var source = "" {
        didSet {
            lines = source.components(separatedBy: "\n")
            var start = 0
            lineStarts = lines.map { line in
                defer { start += line.utf16.count + 1 }
                return start
            }
        }
    }

    private var lines: [String] = []
    private var lineStarts: [Int] = []

    private var tagRanges: [NSValue] = []
    private var tagStyles: [NSNumber] = []
    private var runRanges: [NSValue] = []
    private var runStyles: [NSNumber] = []
    private var hiddenRanges: [NSValue] = []
    private var collapsibleDisclosureRanges: [NSValue] = []
    private var collapsibleFoldRanges: [NSValue] = []
    private var collapsibleStartsCollapsed: [NSNumber] = []

    func hide(_ text: String, onLine line: Int) {
        hiddenRanges.append(NSValue(range: range(of: text, onLine: line)))
    }

    func tag(_ text: String, onLine line: Int, style: SourceEditorBridgingCommentTagStyle = .standard) {
        tagRanges.append(NSValue(range: range(of: text, onLine: line)))
        tagStyles.append(NSNumber(value: style.rawValue))
    }

    func run(_ text: String, onLine line: Int, style: SourceEditorBridgingCommentRunStyle) {
        runRanges.append(NSValue(range: range(of: text, onLine: line)))
        runStyles.append(NSNumber(value: style.rawValue))
    }

    /// A row on `line` whose descendants run to the end of `lastLine`.
    func collapsible(disclosureColumns: Range<Int>, onLine line: Int, foldingThrough lastLine: Int, startsCollapsed: Bool) {
        let rowLineStart = lineStart(of: line)
        collapsibleDisclosureRanges.append(NSValue(range: NSRange(location: rowLineStart + disclosureColumns.lowerBound, length: disclosureColumns.count)))
        let foldStart = rowLineStart + length(ofLine: line)
        let foldEnd = lineStart(of: lastLine) + length(ofLine: lastLine)
        collapsibleFoldRanges.append(NSValue(range: NSRange(location: foldStart, length: foldEnd - foldStart)))
        collapsibleStartsCollapsed.append(NSNumber(value: startsCollapsed))
    }

    func build() -> SourceEditorBridgingCommentDecorations {
        TestCommentDecorations(
            tagRanges: tagRanges,
            tagStyles: tagStyles,
            runRanges: runRanges,
            runStyles: runStyles,
            hiddenRanges: hiddenRanges,
            collapsibleDisclosureRanges: collapsibleDisclosureRanges,
            collapsibleFoldRanges: collapsibleFoldRanges,
            collapsibleStartsCollapsed: collapsibleStartsCollapsed
        )
    }

    private func lineStart(of line: Int) -> Int {
        lineStarts[line]
    }

    private func length(ofLine line: Int) -> Int {
        lines[line].utf16.count
    }

    private func range(of text: String, onLine line: Int) -> NSRange {
        let found = (lines[line] as NSString).range(of: text)
        precondition(found.location != NSNotFound, "\(text.debugDescription) is not on line \(line)")
        return NSRange(location: lineStart(of: line) + found.location, length: found.length)
    }
}

private final class TestCommentDecorations: NSObject, SourceEditorBridgingCommentDecorations {
    let tagRanges: [NSValue]
    let tagStyles: [NSNumber]
    let runRanges: [NSValue]
    let runStyles: [NSNumber]
    let hiddenRanges: [NSValue]
    let collapsibleDisclosureRanges: [NSValue]
    let collapsibleFoldRanges: [NSValue]
    let collapsibleStartsCollapsed: [NSNumber]

    init(
        tagRanges: [NSValue],
        tagStyles: [NSNumber],
        runRanges: [NSValue],
        runStyles: [NSNumber],
        hiddenRanges: [NSValue],
        collapsibleDisclosureRanges: [NSValue],
        collapsibleFoldRanges: [NSValue],
        collapsibleStartsCollapsed: [NSNumber]
    ) {
        self.tagRanges = tagRanges
        self.tagStyles = tagStyles
        self.runRanges = runRanges
        self.runStyles = runStyles
        self.hiddenRanges = hiddenRanges
        self.collapsibleDisclosureRanges = collapsibleDisclosureRanges
        self.collapsibleFoldRanges = collapsibleFoldRanges
        self.collapsibleStartsCollapsed = collapsibleStartsCollapsed
    }
}

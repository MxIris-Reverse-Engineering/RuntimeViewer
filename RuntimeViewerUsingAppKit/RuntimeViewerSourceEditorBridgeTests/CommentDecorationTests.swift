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

    /// Line 2's tag is far wider than a narrow editor.
    private static let wrappingSource = """
    struct Probe {
        // Address: 0x135DC
        // Type Layout: (size: 16, stride: 16, alignment: 8, extraInhabitantCount: 0)
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

    /// The editor wraps a line longer than its width, and a tag wraps with it. Each row the tag
    /// lands on gets a shape of its own, one row high: a single shape around all of them covered
    /// the whole line.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aTagTheEditorWrapsIsDrawnRowByRow() throws {
        let harness = try SourceEditorTestHarness()
        harness.resize(width: 320)
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations())
        harness.layout()

        let shapes = Self.shownShapeLayers(in: harness)
        // The address tag fits on its row; the type layout tag is far wider than the view.
        #expect(shapes.count >= 3, "\(shapes.count) shape layers shown in the underlay layer")
        let heights = shapes.map(\.frame.height)
        let rowHeight = try #require(heights.min())
        #expect(heights.allSatisfy { $0 - rowHeight < 1 }, "shape heights \(heights)")
    }

    // MARK: - Triangles

    /// Over a triangle the pointer is the arrow, not the I-beam: a click there toggles a row. The
    /// editor adds its I-beam and then what each provider answers, all on itself, so the arrows
    /// are read back where it adds them.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func theTrianglesTakeTheArrowPointer() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: false))
        harness.layout()

        let added = CursorRectRecorder.cursorRects(addedBy: harness.editorView) {
            harness.editorView.resetCursorRects()
        }
        let arrowRects = added.filter { $0.cursor === NSCursor.arrow }.map(\.rect)
        let triangleCenters = Self.shownTriangleLayers(in: harness).map {
            harness.editorView.convert($0.position, from: harness.editorView.contentView)
        }
        #expect(triangleCenters.count == 2)
        #expect(arrowRects.count == triangleCenters.count, "\(arrowRects)")
        for center in triangleCenters {
            #expect(arrowRects.contains { $0.contains(center) }, "no arrow over the triangle at \(center): \(arrowRects)")
        }
    }

    /// A click turns the triangle a quarter, animated, and leaves a round press behind it that
    /// fades away.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func clickingATriangleTurnsItAndShowsThePress() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: true))
        harness.layout()
        let triangle = try #require(Self.shownTriangleLayers(in: harness).min { $0.position.x < $1.position.x })
        #expect(triangle.affineTransform().isIdentity, "a collapsed row's triangle points right")

        Self.click(at: triangle.position, in: harness)

        #expect(!triangle.affineTransform().isIdentity, "an expanded row's triangle is turned to point down")
        #expect(Self.hasAnimation(on: "transform.rotation.z", in: triangle), "the turn is animated")
        let pressLayers = (harness.editorView.contentView.underlayLayer.sublayers ?? []).filter { Self.hasAnimation(on: "opacity", in: $0) }
        #expect(pressLayers.count == 1, "\(pressLayers.count) fading layers")
    }

    // MARK: - Copying

    /// What a copy writes is the source, not what the editor draws: the markers and punctuation
    /// the decorations hide come back, and so do the rows a fold hides, so a copied comment is a
    /// comment again — as plain text and as rich text alike. A raised line copies as it was
    /// printed too: its carrier is a space of the source. Written to a pasteboard of the test's
    /// own, never the one the user copies with.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded), arguments: [false, true], [false, true])
    func aCopyIsTheSourceAsPrinted(startingCollapsed: Bool, raisingTagLines: Bool) throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.fieldLayoutSource, commentDecorations: Self.fieldLayoutDecorations(startsCollapsed: startingCollapsed))
        harness.layout()
        if raisingTagLines {
            let commentFont = try Self.renderedFont(of: "Field offset", onLine: 1, in: harness)
            harness.applyCommentTagAppearance(TestCommentTagAppearance(tagLineSpacing: 4, commentFont: commentFont))
            harness.layout()
        }

        #expect(NSApplication.shared.sendAction(#selector(NSText.selectAll(_:)), to: harness.editorView, from: nil))
        let requestor = try #require(harness.editorView as? NSServicesMenuRequestor)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RuntimeViewerSourceEditorBridgeTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(requestor.writeSelection?(to: pasteboard, types: [.string, .rtf]) == true)

        // Selecting all takes in the line break the editor ends its text with.
        let plainText = try #require(pasteboard.string(forType: .string))
        #expect(plainText == Self.fieldLayoutSource + "\n")
        let richTextData = try #require(pasteboard.data(forType: .rtf))
        let richText = try #require(NSAttributedString(rtf: richTextData, documentAttributes: nil))
        #expect(richText.string == plainText)
    }

    // MARK: - Appearance

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aLabelTakesTheColourOfItsTagsStyle() throws {
        let harness = try SourceEditorTestHarness()
        harness.applyCommentTagAppearance(TestCommentTagAppearance(labelColors: [.address: .systemBlue, .layout: .systemPurple]))
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations(labellingThem: true))
        harness.layout()

        let addressLine = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(1)).attributedString
        let layoutLine = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(2)).attributedString
        #expect(Self.foregroundColor(of: "Address", in: addressLine) == .systemBlue)
        #expect(Self.foregroundColor(of: "Type Layout", in: layoutLine) == .systemPurple)
    }

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aTagIsOutlinedOnlyWhileTheStrokeHasAWidth() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations())
        harness.applyCommentTagAppearance(TestCommentTagAppearance(strokeWidth: 1))
        harness.layout()
        let outlined = Self.shownShapeLayers(in: harness)
        #expect(!outlined.isEmpty && outlined.allSatisfy { $0.lineWidth == 1 && $0.strokeColor != nil })

        harness.applyCommentTagAppearance(TestCommentTagAppearance(strokeWidth: 0))
        harness.layout()
        let plain = Self.shownShapeLayers(in: harness)
        #expect(!plain.isEmpty && plain.allSatisfy { $0.lineWidth == 0 && $0.strokeColor == nil })
    }

    /// The padding is a column shift baked into the tables, so a new one has to rebuild them
    /// for the text that is already shown.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aChangeOfPaddingWidensTheTagsOfTheTextShown() throws {
        let harness = try SourceEditorTestHarness()
        harness.applyCommentTagAppearance(TestCommentTagAppearance(horizontalPadding: 4))
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations())
        harness.layout()
        let narrowWidths = Self.shownShapeLayers(in: harness).map(\.frame.width).sorted()

        harness.applyCommentTagAppearance(TestCommentTagAppearance(horizontalPadding: 6))
        harness.layout()
        let wideWidths = Self.shownShapeLayers(in: harness).map(\.frame.width).sorted()

        #expect(narrowWidths.count == 2 && wideWidths.count == 2, "\(narrowWidths) → \(wideWidths)")
        for (narrowWidth, wideWidth) in zip(narrowWidths, wideWidths) {
            #expect(abs(wideWidth - narrowWidth - 4) < 0.5, "\(narrowWidth) → \(wideWidth)")
        }
    }

    // MARK: - Raised Lines

    /// A line that holds tags is taller than its text by the spacing, and the lines below it move
    /// down by as much; a code line keeps its height. Without spacing the lines are as they were.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aLineThatHoldsTagsIsTallerByTheSpacing() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations())
        harness.layout()
        let commentFont = try Self.renderedFont(of: "Address", onLine: 1, in: harness)
        let plainRows = try (0 ... 4).map { try Self.rowFrame(ofLine: $0, in: harness) }

        harness.applyCommentTagAppearance(TestCommentTagAppearance(tagLineSpacing: 4, commentFont: commentFont))
        harness.layout()
        let raisedRows = try (0 ... 4).map { try Self.rowFrame(ofLine: $0, in: harness) }

        for line in [0, 3, 4] {
            #expect(abs(raisedRows[line].height - plainRows[line].height) < 0.5, "code line \(line): \(plainRows[line]) → \(raisedRows[line])")
        }
        for line in [1, 2] {
            #expect(abs(raisedRows[line].height - plainRows[line].height - 4) < 0.5, "tag line \(line): \(plainRows[line]) → \(raisedRows[line])")
        }
        let plainDrop = abs(plainRows[3].midY - plainRows[0].midY)
        let raisedDrop = abs(raisedRows[3].midY - raisedRows[0].midY)
        #expect(abs(raisedDrop - plainDrop - 8) < 0.5, "the line under both tag lines moved \(raisedDrop - plainDrop), not 8")

        harness.applyCommentTagAppearance(TestCommentTagAppearance(tagLineSpacing: 0, commentFont: commentFont))
        harness.layout()
        let restoredRows = try (0 ... 4).map { try Self.rowFrame(ofLine: $0, in: harness) }
        for (restoredRow, plainRow) in zip(restoredRows, plainRows) {
            #expect(abs(restoredRow.height - plainRow.height) < 0.5 && abs(restoredRow.minY - plainRow.minY) < 0.5, "\(plainRow) → \(restoredRow)")
        }
    }

    /// The spacing goes around a tag, not into it: on a raised line a tag is as tall and as wide
    /// as on a plain one, sits in the middle of its line, and keeps the spacing from the tag on
    /// the next line.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aTagOnARaisedLineKeepsTheSizeAndPlaceOfItsText() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations())
        harness.layout()
        let commentFont = try Self.renderedFont(of: "Address", onLine: 1, in: harness)
        harness.applyCommentTagAppearance(TestCommentTagAppearance(commentFont: commentFont))
        harness.layout()
        let plainTags = Self.shownShapeLayers(in: harness).map(\.frame).sorted { $0.midY < $1.midY }

        harness.applyCommentTagAppearance(TestCommentTagAppearance(tagLineSpacing: 4, commentFont: commentFont))
        harness.layout()
        let raisedTags = Self.shownShapeLayers(in: harness).map(\.frame).sorted { $0.midY < $1.midY }
        let raisedRows = try [1, 2].map { try Self.rowFrame(ofLine: $0, in: harness) }

        try #require(plainTags.count == 2 && raisedTags.count == 2, "\(plainTags) → \(raisedTags)")
        for (plainTag, raisedTag) in zip(plainTags, raisedTags) {
            #expect(abs(raisedTag.height - plainTag.height) < 0.5 && abs(raisedTag.width - plainTag.width) < 0.5, "\(plainTag) → \(raisedTag)")
            #expect(abs(raisedTag.minX - plainTag.minX) < 0.5, "the raise took width: \(plainTag) → \(raisedTag)")
            let row = try #require(raisedRows.first { $0.minY <= raisedTag.midY && raisedTag.midY <= $0.maxY }, "no row under \(raisedTag)")
            #expect(abs(raisedTag.midY - row.midY) < 0.5, "\(raisedTag) is off the middle of its row \(row)")
        }
        let plainGap = plainTags[1].minY - plainTags[0].maxY
        let raisedGap = raisedTags[1].minY - raisedTags[0].maxY
        #expect(abs(raisedGap - plainGap - 4) < 0.5, "the gap between the tags went from \(plainGap) to \(raisedGap)")
    }

    /// A line number stays level with its text when its line is raised. The gutter centres each
    /// number on the first row of its line — 26.6's `SourceEditorGutterMarginContentView.layoutLineNumberForLine(_:with:)`
    /// (0x1D069C) places it at the middle of `layoutFrameForFirstFragmentOfVisibleLine(_:includeLineSpacing:)`
    /// (closure at 0x1D7B28) — and the raise is carried at the start of the line and splits evenly
    /// around the text, so the middle of the row is still the middle of the text.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aRaisedLineKeepsItsNumberLevelWithItsText() throws {
        let harness = try SourceEditorTestHarness()
        harness.showLineNumbers()
        harness.setSource(Self.wrappingSource, commentDecorations: Self.wrappingDecorations())
        harness.layout()
        let commentFont = try Self.renderedFont(of: "Address", onLine: 1, in: harness)
        harness.applyCommentTagAppearance(TestCommentTagAppearance(tagLineSpacing: 4, commentFont: commentFont))
        harness.layout()

        let rootLayer = try #require(harness.editorView.layer, "the editor view has no layer")
        let contentLayer = try #require(harness.editorView.contentView.layer, "the content view has no layer")
        let numberLayers = Self.lineNumberLayers(in: harness.editorView)
        try #require(numberLayers.count >= 5, "\(numberLayers.count) line number layers")
        let numberMidYs = numberLayers.map { $0.convert($0.bounds, to: rootLayer).midY }
        for line in 0 ... 4 {
            let rowMidY = contentLayer.convert(try Self.rowFrame(ofLine: line, in: harness), to: rootLayer).midY
            #expect(numberMidYs.contains { abs($0 - rowMidY) <= 1 }, "no number level with line \(line) at \(rowMidY): \(numberMidYs.sorted())")
        }
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

    /// The markers hidden, and a tag over each comment, the second one a single long tag; with
    /// `labellingThem`, the first words of each a label run.
    private static func wrappingDecorations(labellingThem: Bool = false) -> SourceEditorBridgingCommentDecorations {
        let builder = DecorationsBuilder()
        builder.source = wrappingSource
        for line in 1 ... 2 {
            builder.hide("// ", onLine: line)
        }
        builder.tag("Address: 0x135DC", onLine: 1)
        builder.tag("Type Layout: (size: 16, stride: 16, alignment: 8, extraInhabitantCount: 0)", onLine: 2, style: .layout)
        if labellingThem {
            builder.run("Address", onLine: 1, style: .label)
            builder.run("Type Layout", onLine: 2, style: .label)
        }
        return builder.build()
    }

    // MARK: - Helpers

    /// The font the editor draws the first occurrence of `text` in, on a rendered line — what a
    /// raise has to be measured against.
    private static func renderedFont(of text: String, onLine line: Int, in harness: SourceEditorTestHarness) throws -> NSFont {
        let renderedLine = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(line)).attributedString
        let range = (renderedLine.string as NSString).range(of: text)
        try #require(range.location != NSNotFound, "\(text.debugDescription) is not in \(renderedLine.string.debugDescription)")
        return try #require(renderedLine.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    /// A line's row as a selection of its first column covers it, in the content view's
    /// coordinates. Every line of the fixtures starts with a drawn column.
    private static func rowFrame(ofLine line: Int, in harness: SourceEditorTestHarness) throws -> CGRect {
        let range = SourceEditorPosition(line: line, col: 0) ..< SourceEditorPosition(line: line, col: 1)
        let rects = harness.editorView.contentView.selectionRects(for: range, coalesceInteriorRects: true, includeLineSpacing: false)
        return try #require(rects.first?.rect, "no selection rect on line \(line)")
    }

    /// The colour the editor draws the first occurrence of `text` in, on a rendered line.
    private static func foregroundColor(of text: String, in renderedLine: NSAttributedString) -> NSColor? {
        let range = (renderedLine.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return renderedLine.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    /// The layers the gutter draws its numbers in: the text layers under its margin content view.
    private static func lineNumberLayers(in editorView: NSView) -> [CALayer] {
        func gutterContentViews(in view: NSView) -> [NSView] {
            let own = String(describing: type(of: view)).contains("GutterMarginContentView") ? [view] : []
            return own + view.subviews.flatMap(gutterContentViews(in:))
        }
        func textLayers(in layer: CALayer) -> [CALayer] {
            let own = !layer.isHidden && String(describing: type(of: layer)).contains("TextLayer") ? [layer] : []
            return own + (layer.sublayers ?? []).flatMap(textLayers(in:))
        }
        return gutterContentViews(in: editorView).compactMap(\.layer).flatMap(textLayers(in:))
    }

    private static func shownShapeLayers(in harness: SourceEditorTestHarness) -> [CAShapeLayer] {
        (harness.editorView.contentView.underlayLayer.sublayers ?? [])
            .compactMap { $0 as? CAShapeLayer }
            .filter { !$0.isHidden && $0.path != nil }
    }

    /// The triangles among them: the only square shapes, a few points across.
    private static func shownTriangleLayers(in harness: SourceEditorTestHarness) -> [CAShapeLayer] {
        shownShapeLayers(in: harness).filter { $0.bounds.width == $0.bounds.height && $0.bounds.width < 12 }
    }

    private static func hasAnimation(on keyPath: String, in layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { (layer.animation(forKey: $0) as? CABasicAnimation)?.keyPath == keyPath }
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

    func tag(_ text: String, onLine line: Int, style: SourceEditorBridgingCommentTagStyle = .address) {
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

/// A tag appearance with plain fills, so a test sets only what it looks at. No line is raised
/// unless a test asks for it, and then against the font the editor actually draws comments in.
private final class TestCommentTagAppearance: NSObject, SourceEditorBridgingCommentTagAppearance {
    let valueColor = NSColor.textColor
    let typeColor = NSColor.textColor
    let nameColor = NSColor.textColor
    let disclosureColor = NSColor.secondaryLabelColor
    let cornerRadius: CGFloat = 100
    let strokeWidth: CGFloat
    let horizontalPadding: CGFloat
    let tagLineSpacing: CGFloat
    let commentFont: NSFont

    private let labelColors: [SourceEditorBridgingCommentTagStyle: NSColor]

    init(
        labelColors: [SourceEditorBridgingCommentTagStyle: NSColor] = [:],
        strokeWidth: CGFloat = 0,
        horizontalPadding: CGFloat = 4,
        tagLineSpacing: CGFloat = 0,
        commentFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    ) {
        self.labelColors = labelColors
        self.strokeWidth = strokeWidth
        self.horizontalPadding = horizontalPadding
        self.tagLineSpacing = tagLineSpacing
        self.commentFont = commentFont
    }

    func fillColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
        .quaternaryLabelColor
    }

    func strokeColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor? {
        .tertiaryLabelColor
    }

    func labelColor(for style: SourceEditorBridgingCommentTagStyle) -> NSColor {
        labelColors[style] ?? .secondaryLabelColor
    }
}

/// Reads back the cursor rects a view adds, which AppKit offers no way to do: for the length of
/// `body`, the view's class answers `addCursorRect(_:cursor:)` by noting the rect and then adding
/// it as `NSView` would. The class is left answering it exactly as `NSView` does.
private enum CursorRectRecorder {
    static func cursorRects(addedBy view: NSView, during body: () -> Void) -> [(rect: CGRect, cursor: NSCursor)] {
        let selector = #selector(NSView.addCursorRect(_:cursor:))
        guard let inheritedMethod = class_getInstanceMethod(NSView.self, selector) else { return [] }
        let inheritedImplementation = method_getImplementation(inheritedMethod)
        typealias AddCursorRect = @convention(c) (NSView, Selector, NSRect, NSCursor) -> Void
        let addAsNSViewDoes = unsafeBitCast(inheritedImplementation, to: AddCursorRect.self)

        var added: [(rect: CGRect, cursor: NSCursor)] = []
        let recording: @convention(block) (NSView, NSRect, NSCursor) -> Void = { receiver, rect, cursor in
            added.append((rect, cursor))
            addAsNSViewDoes(receiver, selector, rect, cursor)
        }
        let viewClass: AnyClass = type(of: view)
        let typeEncoding = method_getTypeEncoding(inheritedMethod)
        let previousImplementation = class_replaceMethod(viewClass, selector, imp_implementationWithBlock(recording), typeEncoding)
        defer { class_replaceMethod(viewClass, selector, previousImplementation ?? inheritedImplementation, typeEncoding) }
        body()
        return added
    }
}

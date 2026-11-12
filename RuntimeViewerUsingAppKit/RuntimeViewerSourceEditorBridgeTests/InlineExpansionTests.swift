// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers the bridge's inline expansions, which the content pane uses to show an attached macro's
/// expansion inside the type, the way Xcode does: gaps of the editor's own `editorGapController`,
/// one for each part of the expansion, each holding a read-only editor with the part's text.
@Suite("InlineExpansion", .serialized)
@MainActor
struct InlineExpansionTests {
    private static let source = """
    @Observation.Observable
    final class Model {
        var count: Int
    }
    """

    /// What `@Observable` generated for `count`: its accessors, then its storage.
    private static let trackedPropertyPart = """
    {
        get
        set
    }
    final var _count: Swift.Int
    """

    private static let membersPart = """
    let _$observationRegistrar: Observation.ObservationRegistrar
    func access<A>(keyPath: Swift.KeyPath<Model, A>)
    """

    private static let conformancePart = "extension Model: Observation.Observable {}"

    /// `var count: Int`, on the third line.
    private static let propertyRange = NSRange(location: ("@Observation.Observable\nfinal class Model {\n    " as NSString).length,
                                               length: "var count: Int".utf16.count)

    /// The type's closing brace, on the last line.
    private static let closingBraceRange = NSRange(location: (source as NSString).length - 1, length: 1)

    /// The three places `@Observable` puts its expansion: after the tracked property, inside the
    /// body above its closing brace, and after the type.
    private static let parts: [(String, NSRange, SourceEditorBridgingInlineExpansionPlacement)] = [
        (trackedPropertyPart, propertyRange, .belowLine),
        (membersPart, closingBraceRange, .aboveLine),
        (conformancePart, closingBraceRange, .belowLine),
    ]

    private static func harnessShowingExpansion() throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness()
        harness.setSource(source)
        harness.layout()
        harness.showInlineExpansion(parts, title: "Observable", identifier: "Model")
        harness.layout()
        return harness
    }

    /// The gaps of the expansion, ordered by the line they open at and above before below.
    private static func gapItems(of harness: SourceEditorTestHarness) -> [SourceEditorGapItem] {
        harness.editorView.editorGapController.allGapItems.sorted { firstItem, secondItem in
            let firstLine = firstItem.managedRange.originalRange.upperBound.line
            let secondLine = secondItem.managedRange.originalRange.upperBound.line
            return firstLine != secondLine ? firstLine < secondLine : firstItem.position < secondItem.position
        }
    }

    @Test("each part is a gap at its anchor's line, above or below it, with its text in an editor of its own")
    func eachPartIsAGapAtItsAnchorLine() throws {
        let harness = try Self.harnessShowingExpansion()

        #expect(harness.isInlineExpansionShown(identifier: "Model"))
        let gapItems = Self.gapItems(of: harness)
        try #require(gapItems.count == 3)
        #expect(gapItems.map { $0.managedRange.originalRange.upperBound.line } == [2, 3, 3])
        #expect(gapItems.map(\.position) == [.belowLine, .aboveLine, .belowLine])
        let texts = gapItems.map { gapItem in
            (gapItem.contentView as? any SourceEditorGapWithEmbeddedSourceEditor)?.embeddedEditorView.dataSource.string
        }
        #expect(texts == [Self.trackedPropertyPart, Self.membersPart, Self.conformancePart])
        for gapItem in gapItems {
            #expect(gapItem.contentView.title == "Observable")
            let embeddedEditor = try #require(gapItem.contentView as? any SourceEditorGapWithEmbeddedSourceEditor)
            #expect(!embeddedEditor.embeddedEditorView.isEditingEnabled)
        }
    }

    @Test("showing an identifier that is shown already adds nothing")
    func showingTwiceAddsNothing() throws {
        let harness = try Self.harnessShowingExpansion()

        harness.showInlineExpansion(Self.parts, title: "Observable", identifier: "Model")
        #expect(harness.editorView.editorGapController.allGapItems.count == 3)
    }

    @Test("hiding an expansion removes every part of it")
    func hidingRemovesEveryPart() throws {
        let harness = try Self.harnessShowingExpansion()

        harness.hideInlineExpansion(identifier: "Model")
        #expect(!harness.isInlineExpansionShown(identifier: "Model"))
        #expect(harness.editorView.editorGapController.allGapItems.isEmpty)
    }

    /// The parts are one expansion: the dismiss button of any of them closes them all, as hiding
    /// does. The action is called directly, since a click a test delivers does not reach the
    /// button (see `dismissButtonTracksWithItsOwnMouseDown()`).
    @Test("the dismiss button of one part closes every part")
    func dismissingOnePartClosesEveryPart() throws {
        let harness = try Self.harnessShowingExpansion()
        let gapViews = Self.descendants(of: harness.editorView, ofType: SourceEditorGapView.self)
        try #require(gapViews.count >= 2)

        // The action reads `NSApp.currentEvent`, which a test process has no application for.
        _ = NSApplication.shared
        try #require(gapViews.first).dismissButtonAction(nil)
        #expect(!harness.isInlineExpansionShown(identifier: "Model"))
        #expect(harness.editorView.editorGapController.allGapItems.isEmpty)
    }

    /// The gap's dismiss button sits in the expansion's own gutter, under the editor's line-number
    /// column, which floats above the text and is what the window's hit-test finds there. The press
    /// reaches the button only as the mouse-down the column leaves unhandled, which AppKit passes on
    /// to the view below. Under the macOS 27 SDK the app links, a plain `NSButton` tracks with a
    /// gesture recognizer and ignores such a press, so the SourceEditor release the app pins has to
    /// give the button its own `mouseDown(with:)`, as Xcode 27.2 does: AppKit keeps a control whose
    /// class overrides it on the tracking loop, which takes the forwarded press.
    ///
    /// A click delivered by the test does not show the difference: in this test process, which is
    /// never the active application, it closed the expansion neither with 26.6.4 nor with
    /// 27.2.0-alpha.1. So the test checks what AppKit decides by.
    @Test("the dismiss button tracks with its own mouseDown, so a press the gutter passes on reaches it")
    func dismissButtonTracksWithItsOwnMouseDown() throws {
        let harness = try Self.harnessShowingExpansion()
        let gapView = try #require(Self.descendants(of: harness.editorView, ofType: SourceEditorGapView.self).first)
        let dismissButton = try #require(gapView.subviews.compactMap { $0 as? NSButton }.first { button in
            button.action == #selector(SourceEditorGapView.dismissButtonAction(_:))
        })

        let buttonClass: AnyClass = type(of: dismissButton)
        #expect(ObjectIdentifier(buttonClass) != ObjectIdentifier(NSButton.self))
        var methodCount: UInt32 = 0
        let methods = class_copyMethodList(buttonClass, &methodCount)
        defer { free(methods) }
        let ownSelectors = (0..<Int(methodCount)).compactMap { methodIndex in
            methods.map { methodList in method_getName(methodList[methodIndex]) }
        }
        #expect(ownSelectors.contains(#selector(NSResponder.mouseDown(with:))))
    }

    private static func descendants<DescendantView: NSView>(
        of view: NSView, ofType descendantType: DescendantView.Type
    ) -> [DescendantView] {
        var matchingViews: [DescendantView] = []
        var pendingViews = view.subviews
        while let pendingView = pendingViews.popLast() {
            if let matchingView = pendingView as? DescendantView {
                matchingViews.append(matchingView)
            }
            pendingViews.append(contentsOf: pendingView.subviews)
        }
        return matchingViews
    }

    /// A gap hangs under a line identifier of the data source it was inserted into, which the next
    /// text does not have.
    @Test("a new source closes every expansion")
    func newSourceClosesTheExpansions() throws {
        let harness = try Self.harnessShowingExpansion()

        harness.setSource("struct Other {}")
        harness.layout()
        #expect(!harness.isInlineExpansionShown(identifier: "Model"))
        #expect(harness.editorView.editorGapController.allGapItems.isEmpty)
    }

    /// Where each part's text starts: at its anchor's column, as the indent rule counts it, on the
    /// host's columns. The host here shows two-digit line numbers and the folding ribbon, the
    /// expansion's editor one-digit numbers and no ribbon, and SourceEditor pads the host's text
    /// only while its gutter shows certain annotations — so the two editors' left margins differ,
    /// and padding the expansion by Xcode's formula left its text a dozen points short.
    @Test("each part's text starts on the host's columns")
    func partsLineUpWithTheHostColumns() throws {
        let commentLines = (1 ... 8).map { "// line \($0)\n" }.joined()
        let source = commentLines + Self.source
        let sourceText = source as NSString
        let propertyRange = sourceText.range(of: "var count: Int")
        let closingBraceRange = NSRange(location: sourceText.length - 1, length: 1)
        let harness = try SourceEditorTestHarness()
        harness.showLineNumbersAndFoldingRibbon()
        harness.setSource(source)
        harness.layout()
        harness.showInlineExpansion([
            (Self.trackedPropertyPart, propertyRange, .belowLine),
            (Self.membersPart, closingBraceRange, .aboveLine),
            (Self.conformancePart, closingBraceRange, .belowLine),
        ], title: "Observable", identifier: "Model")
        harness.layout()
        harness.layout()

        let hostEditor = harness.editorView
        let hostFirstLine = try #require(hostEditor.layoutManager.layoutFrameForFirstFragmentOfVisibleLine(0, includeLineSpacing: false))
        let hostColumnZero = hostEditor.contentView.convert(hostFirstLine, to: nil).minX
        let spaceWidth = hostEditor.layoutManager.spaceWidth
        let gapItems = hostEditor.editorGapController.allGapItems
        try #require(gapItems.count == 3)
        for gapItem in gapItems {
            let indent = SourceEditorBridge.inlineExpansionIndent(for: gapItem.managedRange.originalRange, position: gapItem.position,
                                                                  in: hostEditor.dataSource)
            let embeddedEditor = try #require((gapItem.contentView as? any SourceEditorGapWithEmbeddedSourceEditor)?.embeddedEditorView)
            let embeddedFirstLine = try #require(embeddedEditor.layoutManager.layoutFrameForFirstFragmentOfVisibleLine(0, includeLineSpacing: false))
            let textStart = embeddedEditor.contentView.convert(embeddedFirstLine, to: nil).minX
            let expectedTextStart = hostColumnZero + CGFloat(indent) * spaceWidth
            #expect(abs(textStart - expectedTextStart) < 1,
                    "the part at line \(gapItem.managedRange.originalRange.upperBound.line), \(gapItem.position), starts at \(textStart), not \(expectedTextStart)")
        }
    }

    /// Xcode's rule for an expanded macro: the line's own indentation, one level deeper when the gap
    /// opens above a body's closing brace, below a line that opens a body, or when the range ends
    /// inside its line.
    @Test("each part is indented as Xcode indents an expanded macro")
    func expansionIndent() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.source)
        let dataSource = harness.editorView.dataSource
        let indentWidth = dataSource.formattingOptions.indentWidth
        func indent(line: Int, columns: Range<Int>, _ position: SourceEditorGapItem.Position) -> Int {
            SourceEditorBridge.inlineExpansionIndent(
                for: SourceEditorPosition(line: line, col: columns.lowerBound) ..< SourceEditorPosition(line: line, col: columns.upperBound),
                position: position,
                in: dataSource
            )
        }
        // The attribute's whole line, and the closing brace's: the line's own indentation.
        #expect(indent(line: 0, columns: 0 ..< 23, .belowLine) == 0)
        #expect(indent(line: 3, columns: 0 ..< 1, .belowLine) == 0)
        // The tracked property's declaration: its own indentation, the member's.
        #expect(indent(line: 2, columns: 4 ..< 18, .belowLine) == 4)
        // Above the closing brace, the body's end: one level in, where the members are.
        #expect(indent(line: 3, columns: 0 ..< 1, .aboveLine) == indentWidth)
        // Below the line that opens the body, and a range that ends inside its line.
        #expect(indent(line: 1, columns: 0 ..< 19, .belowLine) == indentWidth)
        #expect(indent(line: 1, columns: 12 ..< 17, .belowLine) == indentWidth)
    }
}

#endif

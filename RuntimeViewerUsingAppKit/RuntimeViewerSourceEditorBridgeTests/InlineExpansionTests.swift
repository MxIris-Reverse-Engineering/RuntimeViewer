// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers the bridge's inline expansions, which the content pane uses to show a macro's expansion
/// below the line of its attribute, the way Xcode does: a gap of the editor's own
/// `editorGapController` holding a read-only editor with the expansion's text.
@Suite("InlineExpansion", .serialized)
@MainActor
struct InlineExpansionTests {
    private static let source = """
    @Observation.Observable
    final class Model {
        var count: Int
    }
    """

    private static let expansion = """
    @Observation.ObservationIgnored private let _$observationRegistrar: Observation.ObservationRegistrar
    private var _count: Int
    """

    /// The attribute on the first line, which the expansions hang under.
    private static let anchorRange = NSRange(location: 0, length: "@Observation.Observable".utf16.count)

    private static func harnessShowingExpansion() throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness()
        harness.setSource(source)
        harness.layout()
        harness.showInlineExpansion(expansion, title: "Observable", identifier: "Model", belowLineContaining: anchorRange)
        harness.layout()
        return harness
    }

    @Test("an expansion is a gap below the anchor's line, with the text in an editor of its own")
    func expansionIsAGapBelowTheAnchorLine() throws {
        let harness = try Self.harnessShowingExpansion()

        #expect(harness.isInlineExpansionShown(identifier: "Model"))
        let gapItems = harness.editorView.editorGapController.allGapItems
        try #require(gapItems.count == 1)
        let gapItem = gapItems[0]
        #expect(gapItem.position == .belowLine)
        #expect(gapItem.managedRange.originalRange.lowerBound.line == 0)
        #expect(gapItem.contentView.title == "Observable")
        let embeddedEditor = try #require(gapItem.contentView as? any SourceEditorGapWithEmbeddedSourceEditor)
        #expect(embeddedEditor.embeddedEditorView.dataSource.string == Self.expansion)
        #expect(!embeddedEditor.embeddedEditorView.isEditingEnabled)
    }

    @Test("showing an identifier that is shown already adds nothing")
    func showingTwiceAddsNothing() throws {
        let harness = try Self.harnessShowingExpansion()

        harness.showInlineExpansion(Self.expansion, title: "Observable", identifier: "Model",
                                    belowLineContaining: Self.anchorRange)
        #expect(harness.editorView.editorGapController.allGapItems.count == 1)
    }

    @Test("hiding an expansion removes its gap")
    func hidingRemovesTheGap() throws {
        let harness = try Self.harnessShowingExpansion()

        harness.hideInlineExpansion(identifier: "Model")
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

    /// Xcode's rule for an expanded macro: the line's own indentation when the range reaches the
    /// end of a line that does not open a body, one level deeper otherwise.
    @Test("the expansion is indented as Xcode indents an expanded macro")
    func expansionIndent() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.source)
        let dataSource = harness.editorView.dataSource
        let attributeLine = SourceEditorPosition(line: 0, col: 0) ..< SourceEditorPosition(line: 0, col: 23)
        #expect(SourceEditorBridge.inlineExpansionIndent(for: attributeLine, in: dataSource) == 0)
        let typeName = SourceEditorPosition(line: 1, col: 12) ..< SourceEditorPosition(line: 1, col: 17)
        #expect(SourceEditorBridge.inlineExpansionIndent(for: typeName, in: dataSource)
            == dataSource.formattingOptions.indentWidth)
    }
}

#endif

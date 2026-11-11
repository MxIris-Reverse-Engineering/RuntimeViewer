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

// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import QuartzCore
import SourceEditor
import SourceModelSupport
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers the highlight of the other occurrences of a clicked identifier.
///
/// The editor draws it (`SelectedSymbolHighlight`) once the bridge has given it a delay, from the
/// references the language service reports; `SourceModelLanguageService` hands that question to
/// its host, and `SymbolOccurrenceProvider` is the host the bridge installs. The first tests ask
/// the language service directly, the way the editor does; the last one watches the highlight
/// appear.
@Suite("SymbolOccurrence", .serialized)
@MainActor
struct SymbolOccurrenceTests {
    private static let source = """
    class Widget {
        var count: Int
        func reset(count: Int)
        // count, in a comment
        var counter: Int
    }
    """

    /// `count` in `var count: Int`.
    private static let propertyName = SourceEditorPosition(line: 1, col: 8) ..< SourceEditorPosition(line: 1, col: 13)

    /// `count` as the label in `reset(count:)`.
    private static let argumentLabel = SourceEditorPosition(line: 2, col: 15) ..< SourceEditorPosition(line: 2, col: 20)

    private static func references(at position: SourceEditorPosition, in harness: SourceEditorTestHarness) throws -> [Range<SourceEditorPosition>] {
        let languageService = try #require(harness.editorView.dataSource.languageService as? SourceModelLanguageService)
        var references: [Range<SourceEditorPosition>]?
        languageService.referencesToSymbolAtPosition(position, cancelledBlock: nil) { references = $0 }
        return try #require(references, "the language service did not answer")
    }

    /// The whole identifiers spelled the same — not the one in the comment, nor `counter`.
    @Test
    func everyWholeIdentifierWithTheSameNameIsReported() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.source)
        harness.layout()

        let references = try Self.references(at: SourceEditorPosition(line: 1, col: 10), in: harness)

        #expect(references == [Self.propertyName, Self.argumentLabel])
    }

    /// A click on the right half of a name's last letter leaves the insertion point after the
    /// name, where the character that follows is punctuation.
    @Test
    func anInsertionPointJustAfterTheNameCountsAsOnIt() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.source)
        harness.layout()

        let references = try Self.references(at: Self.propertyName.upperBound, in: harness)

        #expect(references == [Self.propertyName, Self.argumentLabel])
    }

    @Test
    func aKeywordHasNoOccurrences() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.source)
        harness.layout()

        let references = try Self.references(at: SourceEditorPosition(line: 1, col: 5), in: harness)

        #expect(references.isEmpty)
    }

    /// The editor asks only after the insertion point has rested, then draws the occurrences
    /// behind the text in a highlight layer of its own.
    @Test
    func restingOnAnIdentifierHighlightsItsOccurrences() async throws {
        let harness = try SourceEditorTestHarness(actsAsKeyWindow: true)
        harness.setSource(Self.source)
        harness.focusEditor()
        harness.layout()

        let insertionPoint = SourceEditorPosition(line: 1, col: 10)
        harness.select(insertionPoint ..< insertionPoint)

        let didHighlight = await harness.layout(until: {
            harness.layers(ofClassNamed: "SourceEditorRangeHighlightLayer").contains { layer in
                guard let shapeLayer = layer as? CAShapeLayer, let path = shapeLayer.path else { return false }
                return !shapeLayer.isHidden && !path.boundingBoxOfPath.isEmpty
            }
        })
        #expect(didHighlight, "no occurrence of `count` was highlighted")
    }
}

#endif

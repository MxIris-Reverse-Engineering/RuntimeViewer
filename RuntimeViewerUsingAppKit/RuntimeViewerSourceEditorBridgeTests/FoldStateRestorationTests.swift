import AppKit
import SourceEditor
import Testing

/// Covers the half of `SourceEditorBridge.setSource` that puts folds back.
///
/// The crash fix has to unfold before every source swap (see `SourceEditorStaleFoldTests`),
/// which on its own would mean leaving a class and returning to it always arrives fully
/// expanded. The bridge therefore saves the fold state under a key derived from the text, and
/// restores it when that same text comes back.
///
/// The framework guards its own restore — a `documentLength` that disagrees is discarded whole,
/// and a position outside the new text is dropped — but those are a safety net. What makes the
/// restore *correct* is the key, and that is what the last test here pins.
@Suite("FoldStateRestoration", .serialized)
@MainActor
struct FoldStateRestorationTests {
    private static let widgetSource = """
    class Widget {
        func first() {
            let a = 1
            let b = 2
            let averyLongIdentifierThatOutrunsAnythingInTheReplacement = "\(String(repeating: "x", count: 120))"
        }
        func second() {
            let d = 4
        }
    }
    """

    private static let gadgetSource = """
    class Gadget {
        func only() {
            let a = 1
        }
    }
    """

    /// A different interface that is character-for-character the same length as `widgetSource`
    /// **and has the same line structure** — only the type name differs, and `Gadget` is as long
    /// as `Widget`.
    ///
    /// Both halves matter. Equal length alone gets past the framework's `documentLength` check
    /// but not past its position validation, so a text that merely happens to be the same size
    /// (a reversed copy, say) is still refused and proves nothing about the key. Matching the
    /// line structure means the saved fold is *valid* here too — the framework would happily
    /// apply it — which leaves the cache key as the only thing standing between this interface
    /// and someone else's folds. Verified: with the key degraded to length alone, this test
    /// fails and the other two still pass.
    private static let widgetLookalike = widgetSource.replacingOccurrences(of: "class Widget {", with: "class Gadget {")

    private static let foldedLineRange = 1 ..< 5

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func foldsComeBackWhenTheSameSourceReturns() throws {
        let harness = try SourceEditorTestHarness()

        harness.setSource(Self.widgetSource)
        harness.layout()
        harness.foldingController.fold(lineRanges: [Self.foldedLineRange], animate: false, completion: nil)
        harness.layout()

        let foldsWhenMade = harness.foldingController.foldedRanges(containing: 4)
        try #require(!foldsWhenMade.isEmpty)

        harness.setSource(Self.gadgetSource)
        harness.layout()
        #expect(
            harness.foldingController.foldedRanges(containing: 4).isEmpty,
            "the other interface must not inherit these folds — that is the crash this all started with"
        )

        harness.setSource(Self.widgetSource)
        harness.layout()

        #expect(
            harness.foldingController.foldedRanges(containing: 4) == foldsWhenMade,
            "coming back to the same interface should restore exactly the fold that was made in it"
        )
    }

    /// An interface that was never folded must come back unfolded, rather than inheriting
    /// whatever the previous occupant of its cache slot had.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func anUnfoldedSourceStaysUnfolded() throws {
        let harness = try SourceEditorTestHarness()

        harness.setSource(Self.widgetSource)
        harness.layout()
        harness.foldingController.fold(lineRanges: [Self.foldedLineRange], animate: false, completion: nil)
        harness.layout()

        harness.setSource(Self.gadgetSource)
        harness.layout()
        harness.setSource(Self.gadgetSource)
        harness.layout()

        #expect(harness.foldingController.foldedRanges(containing: 2).isEmpty)
        #expect(harness.foldingController.foldedRanges(containing: 4).isEmpty)
    }

    /// The key has to identify the text, not merely its size. Two interfaces of identical
    /// length get separate entries, so the second never receives the first's folds.
    ///
    /// Without a content-derived key this is exactly the case that would slip past the
    /// framework's `documentLength` check.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func aDifferentSourceOfTheSameLengthGetsItsOwnState() throws {
        try #require(Self.widgetLookalike.count == Self.widgetSource.count)

        let harness = try SourceEditorTestHarness()

        harness.setSource(Self.widgetSource)
        harness.layout()
        harness.foldingController.fold(lineRanges: [Self.foldedLineRange], animate: false, completion: nil)
        harness.layout()
        try #require(!harness.foldingController.foldedRanges(containing: 4).isEmpty)

        harness.setSource(Self.widgetLookalike)
        harness.layout()

        #expect(
            harness.foldingController.foldedRanges(containing: 4).isEmpty,
            "a same-length but different interface must not pick up the previous one's folds"
        )
    }
}

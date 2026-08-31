import AppKit
import QuartzCore
import SourceEditor
import Testing

/// Pins the ordering in `SourceEditorBridge.setSource` that keeps a fold made in one interface
/// from reaching the next one.
///
/// Folds live on the view, not on the data source: assigning `SourceEditorView.dataSource`
/// runs `FoldingController`'s own `dataSource` didSet, which rebuilds the delimiter data and
/// leaves the fold list alone. Xcode never notices because it gives every document its own
/// editor; this bridge shows every interface in one view. A fold carried across then makes
/// `FoldedRegionDisplay.visibleColumnRanges` build `foldEnd.column ..< lineLength` with the
/// bounds reversed, and the Swift precondition takes the process down — inside the sidebar
/// click's own event tracking, so it reads as if the click itself crashed.
///
/// **`layoutSurvivesASwapToShorterTextWhileFolded` fails by killing the test runner**, not by
/// recording an issue: the failure mode under test is `EXC_BREAKPOINT`, which no test framework
/// can catch. That is why `swappingTheSourceClearsTheFolds` comes first and asserts the same
/// invariant the readable way — when the fix is reverted it fails with a legible message, and
/// only then does the runner die. Both were confirmed to fail before the fix and pass after.
///
/// See `Documentations/ResolvedIssues/2026-08-31-source-editor-stale-folds-crash.md`.
@Suite("SourceEditorStaleFolds", .serialized)
@MainActor
struct SourceEditorStaleFoldTests {
    /// Line 5 runs past 200 characters here and is 4 characters long in `shorterSource`, so a
    /// fold ending on it records a column far beyond where that line ends in the replacement.
    /// That gap is the whole test: an equally long replacement cannot reproduce anything.
    private static let longerSource = """
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

    private static let shorterSource = """
    class W {
        func f() {
            let a = 1
        }
        func g() {
        }
        func h() {
        }
        func i() {
        }
    }
    """

    /// The line the fold ends on, and the line whose length collapses between the two sources.
    private static let foldedLineRange = 1 ..< 5

    // MARK: - Tests

    /// The readable half. Asserts the state the fix produces rather than waiting for the trap,
    /// so a regression says what broke instead of just taking the runner down.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func swappingTheSourceClearsTheFolds() throws {
        let harness = try SourceEditorTestHarness()

        harness.setSource(Self.longerSource)
        harness.layout()

        harness.foldingController.fold(lineRanges: [Self.foldedLineRange], animate: false, completion: nil)
        harness.layout()

        let foldsBefore = harness.foldingController.foldedRanges(containing: Self.foldedLineRange.upperBound - 1)
        try #require(!foldsBefore.isEmpty, "the fold never took, so the swap below proves nothing")

        harness.setSource(Self.shorterSource)

        let foldsAfter = harness.foldingController.foldedRanges(containing: Self.foldedLineRange.upperBound - 1)
        #expect(
            foldsAfter.isEmpty,
            """
            A fold from the previous source survived into the new one. The layout pass that \
            follows will build a reversed Range and trap. Check that setSource still calls \
            unfoldAll(animate: false) *before* assigning the data source.
            """
        )
    }

    /// The end-to-end reproduction: the same sequence a user performs, driven through the
    /// bridge, ending in the layout pass that traps. Reaching the end is the assertion.
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func layoutSurvivesASwapToShorterTextWhileFolded() throws {
        let harness = try SourceEditorTestHarness()

        harness.setSource(Self.longerSource)
        harness.layout()

        harness.foldingController.fold(lineRanges: [Self.foldedLineRange], animate: false, completion: nil)
        harness.layout()
        try #require(
            !harness.foldingController.foldedRanges(containing: Self.foldedLineRange.upperBound - 1).isEmpty,
            "the fold never took, so the layout below never reaches the folded-region path"
        )

        harness.setSource(Self.shorterSource)

        // Without the fix this is where the process dies, in
        // FoldedRegionDisplay.visibleColumnRanges(for:in:) reached from layoutSublayers(of:).
        harness.layout()

        #expect(Bool(true), "laid out the shorter source with a fold outstanding")
    }
}

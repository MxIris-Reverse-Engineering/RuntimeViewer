// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers the scroll half of the reading state `SourceEditorBridge.setSource` saves and restores.
///
/// Every swap installs a new data source, which starts at the top; the bridge saves the scroll
/// position with the folds and, when the same text comes back, has the view scroll to it once the
/// next layout finishes. A swap the content pane is about to follow with a reveal asks for no
/// restore, and the last test pins that it gets none.
@Suite("ScrollPositionRestoration", .serialized)
@MainActor
struct ScrollPositionRestorationTests {
    /// Long enough to scroll well past the first screen of the harness's 600-point window.
    private static let longSource: String = {
        let members = (0 ..< 300).map { "    func member\($0)() -> Int" }
        return (["class Widget {"] + members + ["}"]).joined(separator: "\n")
    }()

    private static let shortSource = """
    class Gadget {
        func only()
    }
    """

    private static let scrolledLine = 150

    /// The line at the top of the visible area.
    private static func topLine(in harness: SourceEditorTestHarness) -> Int {
        harness.editorView.currentScrollState().0
    }

    private static func scroll(_ harness: SourceEditorTestHarness, toLine line: Int) {
        harness.editorView.scrollTo(
            position: SourceEditorPosition(line: line, col: 0),
            placement: .topIgnoringObstructions,
            offset: 0,
            onlyVertically: true,
            animated: false,
            completion: nil
        )
        harness.layout()
    }

    @Test
    func theScrollPositionComesBackWithTheSameSource() async throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.longSource)
        harness.layout()
        Self.scroll(harness, toLine: Self.scrolledLine)
        let scrolledTopLine = Self.topLine(in: harness)
        try #require(scrolledTopLine >= Self.scrolledLine - 1, "the harness did not scroll; top line \(scrolledTopLine)")

        harness.setSource(Self.shortSource)
        harness.layout()
        try #require(Self.topLine(in: harness) == 0, "the other interface should start at the top")

        harness.setSource(Self.longSource)
        let didRestore = await harness.layout(until: { Self.topLine(in: harness) == scrolledTopLine })
        #expect(didRestore, "came back at line \(Self.topLine(in: harness)), not \(scrolledTopLine)")
    }

    /// A source shown for the first time has nothing to come back to and starts at the top. The view
    /// itself keeps the scroll offset across a swap, so without the bridge's own scroll this one
    /// would open as far down as the last.
    @Test
    func aNewSourceStartsAtTheTop() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.longSource)
        harness.layout()
        Self.scroll(harness, toLine: Self.scrolledLine)

        let otherLongSource = Self.longSource.replacingOccurrences(of: "class Widget {", with: "class Gizmo {")
        harness.setSource(otherLongSource)
        harness.layout()

        #expect(Self.topLine(in: harness) == 0)
    }

    /// What the content pane does when a Find navigator hit is to be revealed after the render:
    /// no restore, so the reveal decides where the text is. A restore would wait for the next
    /// layout and could land after the reveal, scrolling the hit away.
    @Test
    func aSwapThatSkipsTheRestoreLeavesThePositionToTheReveal() throws {
        let harness = try SourceEditorTestHarness()
        harness.setSource(Self.longSource)
        harness.layout()
        Self.scroll(harness, toLine: Self.scrolledLine)
        harness.setSource(Self.shortSource)
        harness.layout()

        harness.setSource(Self.longSource, restoresScrollPosition: false)
        harness.layout()
        #expect(Self.topLine(in: harness) == 0, "restored to line \(Self.topLine(in: harness)) although asked not to")

        let revealedLine = 40
        let revealedLocation = (Self.longSource as NSString).range(of: "member\(revealedLine - 1)()").location
        harness.revealCharacterRange(NSRange(location: revealedLocation, length: 6))
        harness.layout()
        let topLineAfterReveal = Self.topLine(in: harness)
        #expect(
            topLineAfterReveal > 0 && topLineAfterReveal <= revealedLine,
            "the revealed line \(revealedLine) should be on screen, centred; top line \(topLineAfterReveal)"
        )
    }
}

#endif

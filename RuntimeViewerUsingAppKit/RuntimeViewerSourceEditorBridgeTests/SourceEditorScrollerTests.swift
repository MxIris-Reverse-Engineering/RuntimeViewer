import AppKit
import Testing

/// Pins the scroller setting `SourceEditorBridge.init` makes on the editor's own scroll view.
///
/// `NSScrollView` leaves `autohidesScrollers` off, which under the legacy scroller style
/// (Show scroll bars: Always) keeps an empty vertical track beside an interface that fits the
/// pane. The bridge turns it on once, and that only holds because the framework never writes it
/// back: in Xcode 26.6 its sole `setAutohidesScrollers:` call is in
/// `SourceEditorGoToListView.init(session:theme:)`, and the `NSPreferredScrollerStyleDidChange`
/// observer `installScrollView()` registers only recomputes the line-annotation inset. The second
/// test is what re-checks that claim against whichever Xcode the bundle runs under.
@Suite("SourceEditorScroller", .serialized)
@MainActor
struct SourceEditorScrollerTests {
    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func scrollersAutohideOnceTheBridgeIsUp() throws {
        let harness = try SourceEditorTestHarness()

        #expect(harness.scrollView.autohidesScrollers)
    }

    @Test(.enabled(if: SourceEditorTestHarness.isFrameworkLoaded))
    func autohidingSurvivesASourceSwapAndAScrollerStyleChange() throws {
        let harness = try SourceEditorTestHarness()

        harness.setSource("class Widget {\n    func first() {}\n}\n")
        harness.layout()
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        harness.layout()

        #expect(harness.scrollView.autohidesScrollers)
    }
}

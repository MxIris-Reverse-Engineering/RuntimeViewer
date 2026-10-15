#if os(macOS)

import AppKit

/// Hands the height of a bar floating over the top edge of a view to that view as safe area, so that everything inside
/// it keeps clear of the bar: a list starts below the bar, a placeholder centres in what the bar leaves.
///
/// Made for the tab switcher's bar under `TabViewController.PageLayout.underSegmentedControl`: the tab view fills its
/// superview, and the bar floats over it right below the toolbar, on the top edge of the safe area the tab view already
/// has — so the bar's height is exactly the depth it adds. The layout writes it into the covered view's
/// `additionalSafeAreaInsets.top` whenever the bar's frame changes.
///
/// **Never from the owning view controller's `viewDidLayout`.** AppKit lays a view tree out from the top: for each view
/// it runs the controller's `viewWillLayout`, the view's `layout` and the controller's `viewDidLayout`, and only then
/// moves on to the view's subviews (AppKit 26.7: `___NSViewLayout_block_invoke`, 0x185728E08;
/// `-[NSView _layoutSubtreeWithOldSize:]`, 0x18571EBF8). `-[NSView layout]` sets the frames of the view's direct
/// subviews only (0x184A3AE54), so a bar one level further down still has the frame of the pass before when
/// `viewDidLayout` reads it — no height at all on the first pass — and a page pushed onto the sidebar may never get a
/// second pass. The bar and the covered view are siblings instead: their superview's `layout` sets both frames, the bar's
/// frame change is posted from inside it (`-[NSView _postFrameChangeNotification]`, 0x184A25524), and AppKit lays out
/// the covered view's subtree only afterwards, so the pages see the bar in the same pass. Background:
/// `Documentations/ResolvedIssues/2026-10-15-sidebar-list-starts-under-the-tab-switcher-bar.md`.
@MainActor
public final class FloatingBarSafeAreaLayout: NSObject {
    /// The bar floating over the top edge of `coveredView`.
    public let barView: NSView

    /// The view under the bar, whose top safe area grows by the bar's height.
    public let coveredView: NSView

    public init(barView: NSView, coveredView: NSView) {
        self.barView = barView
        self.coveredView = coveredView
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(barViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: barView)
        update()
    }

    @objc private func barViewFrameDidChange(_ notification: Notification) {
        update()
    }

    private func update() {
        let barHeight = barView.frame.height
        guard coveredView.additionalSafeAreaInsets.top != barHeight else { return }
        coveredView.additionalSafeAreaInsets.top = barHeight
    }
}

#endif

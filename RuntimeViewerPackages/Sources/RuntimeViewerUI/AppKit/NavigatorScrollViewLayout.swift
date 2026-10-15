#if os(macOS)

import AppKit
import UIFoundation

/// Lays a navigator page's list out the way Xcode lays out its navigators from macOS 26 on: the list
/// runs the full height of the page, and the bars along its edges float over it instead of sitting
/// above and below it. The rows scroll under the bars and fade out there, in the scroll edge effect
/// AppKit draws along an edge of a scroll view — its *scroll pocket*.
///
/// This does what Xcode does in `IDEExplorableNavigatorView` and `IDENavigatorArea` (IDEKit 27.2;
/// the addresses and the AppKit side are in `/Volumes/RE/Xcode/27.2/README.md`, "Navigator chooser
/// and scroll pockets"):
///
/// - **The views floating over an edge become safe area.** They are added to the scroll view's own
///   `additionalSafeAreaInsets`, on top of the safe area that reaches it from outside — the toolbar's,
///   and that of the tab switcher's segmented control bar, which floats over the pages too.
/// - **The clip view's insets are set, not adjusted.** The clip view stops adjusting its insets on its
///   own; its `contentInsets` are the safe area, with `topContentInsetBeyondSafeArea` more at the top,
///   so the first row starts a little below the bars and the last one scrolls clear of the filter
///   bar. A change keeps the rows where they were: a list at its top stays at its top. The scroll view
///   keeps adjusting its own insets, which keeps the scroller clear of the bars.
/// - **Both edges always show their pocket.** AppKit sizes the top pocket by the safe area and the
///   bottom one by the bottom content inset, so the rows fade out under exactly the views that float
///   over them. Xcode also registers those views with the scroll view as the pockets' containers; the
///   private call for that is not in the UIFoundation release this app builds against yet.
///
/// The layout keeps itself up to date: it follows the scroll view's safe area and the frames of the
/// scroll view and of every overlay view, so nothing has to call it from a layout pass. Before macOS 26
/// it does nothing at all, and the page keeps its stacked layout.
@MainActor
public final class NavigatorScrollViewLayout: NSObject {
    /// How far below the safe area the first row starts: 8 points, as in Xcode, whose navigator clip view
    /// gets `safeAreaInsets.top + 8` (`IDENavigatorArea.ContentView`,
    /// `dvt_positionSubviewsAndSizeSelfAfterSubviewLayout`, 0x840A40).
    public static let topContentInsetBeyondSafeArea: CGFloat = 8

    /// One bit per edge, the top edge's first, the way `alwaysShownPocketEdges` takes them. Xcode passes 3
    /// (`-[IDENavigatorArea replacementView:didInstallViewController:]`, 0x2924A0).
    private static let topAndBottomPocketEdges: Int64 = 0b11

    public let scrollView: NSScrollView

    /// The views floating over the scroll view's top edge, such as the Find page's query area.
    public let topOverlayViews: [NSView]

    /// The views floating over its bottom edge: the filter bar.
    public let bottomOverlayViews: [NSView]

    private var safeAreaInsetsObservation: NSKeyValueObservation?

    public init(scrollView: NSScrollView, topOverlayViews: [NSView] = [], bottomOverlayViews: [NSView] = []) {
        self.scrollView = scrollView
        self.topOverlayViews = topOverlayViews
        self.bottomOverlayViews = bottomOverlayViews
        super.init()

        guard #available(macOS 26.0, *) else { return }

        scrollView.contentView.automaticallyAdjustsContentInsets = false
        if scrollView.responds(to: #selector(setter: NSScrollView.alwaysShownPocketEdges)) {
            scrollView.alwaysShownPocketEdges = Self.topAndBottomPocketEdges
        }

        safeAreaInsetsObservation = scrollView.observe(\.safeAreaInsets) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        }
        for view in [scrollView] + topOverlayViews + bottomOverlayViews {
            NotificationCenter.default.addObserver(self, selector: #selector(viewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: view)
        }

        update()
    }

    /// Brings the scroll view's safe area and its clip view's insets up to date with the overlay views'
    /// frames and the safe area that reaches the scroll view from outside. Runs on its own whenever either
    /// changes; before macOS 26 it does nothing.
    public func update() {
        guard #available(macOS 26.0, *) else { return }
        updateAdditionalSafeAreaInsets()
        updateContentInsets()
    }

    @objc private func viewFrameDidChange(_ notification: Notification) {
        update()
    }

    private func updateAdditionalSafeAreaInsets() {
        let additionalSafeAreaInsets = scrollView.additionalSafeAreaInsets
        let safeAreaInsets = scrollView.safeAreaInsets
        // What reaches the scroll view from outside: an overlay laid out below the toolbar only adds
        // the part of it that the toolbar does not already cover.
        let inheritedTopInset = safeAreaInsets.top - additionalSafeAreaInsets.top
        let inheritedBottomInset = safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
        let topInset = max(0, depth(coveredBy: topOverlayViews, from: .top) - inheritedTopInset)
        let bottomInset = max(0, depth(coveredBy: bottomOverlayViews, from: .bottom) - inheritedBottomInset)
        guard topInset != additionalSafeAreaInsets.top || bottomInset != additionalSafeAreaInsets.bottom else { return }
        scrollView.additionalSafeAreaInsets = NSEdgeInsets(
            top: topInset,
            left: additionalSafeAreaInsets.left,
            bottom: bottomInset,
            right: additionalSafeAreaInsets.right
        )
    }

    private func updateContentInsets() {
        let clipView = scrollView.contentView
        let safeAreaInsets = scrollView.safeAreaInsets
        let contentInsets = NSEdgeInsets(
            top: safeAreaInsets.top + Self.topContentInsetBeyondSafeArea,
            left: 0,
            bottom: safeAreaInsets.bottom,
            right: 0
        )
        let previousContentInsets = clipView.contentInsets
        guard !NSEdgeInsetsEqual(previousContentInsets, contentInsets) else { return }
        // How far the rows are scrolled past the top of the content area, which the change keeps. Only a
        // flipped document — every list — measures that from its top.
        let scrolledDistance = clipView.bounds.minY + previousContentInsets.top
        clipView.contentInsets = contentInsets
        guard clipView.isFlipped else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: scrolledDistance - contentInsets.top))
        scrollView.reflectScrolledClipView(clipView)
    }

    private enum Edge {
        case top
        case bottom
    }

    /// How far the views reach into the scroll view from one of its edges: the distance from that edge to
    /// the farthest of their opposite edges, or 0 when there are none.
    private func depth(coveredBy overlayViews: [NSView], from edge: Edge) -> CGFloat {
        let bounds = scrollView.bounds
        // The top edge is the scroll view's minimum Y only when it is flipped, the bottom edge only when
        // it is not.
        let edgeIsAtMinimumY = (edge == .top) == scrollView.isFlipped
        return overlayViews.reduce(0) { deepestDepth, overlayView in
            let overlayFrame = scrollView.convert(overlayView.bounds, from: overlayView)
            let depth = edgeIsAtMinimumY ? overlayFrame.maxY - bounds.minY : bounds.maxY - overlayFrame.minY
            return max(deepestDepth, depth)
        }
    }
}

#endif

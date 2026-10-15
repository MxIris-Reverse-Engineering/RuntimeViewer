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
/// - **The views floating over an edge are registered as the containers of that edge's pocket**, and
///   both edges always show their pocket. AppKit sizes the top pocket by the safe area and the bottom
///   one by the bottom content inset, each united with the containers registered there, so the rows fade
///   out under exactly the views that float over them. A container tells the pocket what it is through
///   `_scrollPocketElementStyle`; Xcode's bars answer as bars, and so do `ScrollPocketBarView` and
///   `NavigatorFilterControlBar`. The tab switcher's bar, which lives outside the page, is registered too
///   while the page is the one on screen (`inheritedTopOverlayViews`).
/// - **On macOS 26 both pockets get style 2**, as Xcode's navigators do there. On macOS 27 Xcode sets
///   the top pocket's style to 2 only under a chooser showing a second level of tabs, which the tab
///   switcher never has, and leaves both at 0, the default.
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

    public let scrollView: NSScrollView

    /// The views of the page floating over the scroll view's top edge, such as the Find page's query area.
    public let topOverlayViews: [NSView]

    /// The views floating over its bottom edge: the filter bar.
    public let bottomOverlayViews: [NSView]

    /// Views from outside the page that float over the scroll view's top edge: the tab switcher's bar, while
    /// the page is the one on screen under it. They are registered as containers of the top pocket, as
    /// `topOverlayViews` are, but add no safe area: their depth already reaches the scroll view from outside,
    /// as the safe area of the tab view.
    public var inheritedTopOverlayViews: [NSView] = [] {
        didSet {
            updateTopPocketContainers()
        }
    }

    /// The views registered as containers of the top pocket. Kept here so that a view is registered once and
    /// unregistered when it goes: how AppKit stores its containers was never worked out, so nothing relies on
    /// it ignoring a second registration of the same view.
    private var registeredTopPocketContainers: [NSView] = []

    private var safeAreaInsetsObservation: NSKeyValueObservation?

    public init(scrollView: NSScrollView, topOverlayViews: [NSView] = [], bottomOverlayViews: [NSView] = []) {
        self.scrollView = scrollView
        self.topOverlayViews = topOverlayViews
        self.bottomOverlayViews = bottomOverlayViews
        super.init()

        guard #available(macOS 26.0, *) else { return }

        scrollView.contentView.automaticallyAdjustsContentInsets = false
        // What Xcode's navigator area does to each navigator it installs (`-[IDENavigatorArea
        // replacementView:didInstallViewController:]`, 0x2924A0): both edges always shown, the bars
        // registered, and on macOS 26 style 2 on both edges. The bars of the navigators themselves are
        // registered by the navigators (`-[IDEFindNavigator viewDidLoad]`, 0x1B42C0;
        // `-[IDEExplorableNavigatorView viewDidMoveToWindow]`, 0x76344C).
        scrollView.box.alwaysShownScrollPocketEdges = [.top, .bottom]
        for bottomOverlayView in bottomOverlayViews {
            scrollView.box.registerScrollPocketContainer(bottomOverlayView, on: .bottom)
        }
        updateTopPocketContainers()
        if #unavailable(macOS 27.0) {
            scrollView.box.setScrollPocketStyle(2, on: .top)
            scrollView.box.setScrollPocketStyle(2, on: .bottom)
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

    /// Unregisters the top containers that went and registers the ones that came, the page's own overlays
    /// first. A view listed twice is registered once.
    private func updateTopPocketContainers() {
        guard #available(macOS 26.0, *) else { return }
        var topPocketContainers: [NSView] = []
        for view in topOverlayViews + inheritedTopOverlayViews where !topPocketContainers.contains(where: { $0 === view }) {
            topPocketContainers.append(view)
        }
        for view in registeredTopPocketContainers where !topPocketContainers.contains(where: { $0 === view }) {
            scrollView.box.unregisterScrollPocketContainer(view, on: .top)
        }
        for view in topPocketContainers where !registeredTopPocketContainers.contains(where: { $0 === view }) {
            scrollView.box.registerScrollPocketContainer(view, on: .top)
        }
        registeredTopPocketContainers = topPocketContainers
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

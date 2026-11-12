#if os(macOS)

import AppKit
import UIFoundation

/// Keeps a bar registered as a container of one edge's scroll pocket on one scroll view at a time, for a
/// bar floating over whichever scroll view is shown under it: an editor pane's tab bar, over the content
/// of the pane's active tab.
///
/// Registered, the bar is part of the pocket — AppKit's scroll edge effect, which shows the content
/// scrolled under the bar blurred — and tells the pocket what it is through its
/// `_scrollPocketElementStyle`. Setting `scrollView` unregisters the bar from the scroll view before and
/// registers it with the new one; `nil` leaves it registered nowhere, for a bar that is hidden. Before
/// macOS 26, which has no scroll pockets, it only remembers the scroll view.
///
/// `NavigatorScrollViewLayout` registers the bars of a navigator page itself, whose scroll view never
/// changes.
@MainActor
public final class ScrollPocketContainerRegistration {
    /// The bar registered as a container.
    public let containerView: NSView

    /// The edge of the scroll view the bar floats over.
    public let edge: NSScrollView.ScrollPocketEdge

    /// The scroll view the bar is registered with. Held weakly: the content it belongs to may go
    /// first, and a scroll view that is gone shows no pocket to unregister from.
    public var scrollView: NSScrollView? {
        get { registeredScrollView }
        set {
            guard newValue !== registeredScrollView else { return }
            if #available(macOS 26.0, *) {
                registeredScrollView?.box.unregisterScrollPocketContainer(containerView, on: edge)
                newValue?.box.registerScrollPocketContainer(containerView, on: edge)
            }
            registeredScrollView = newValue
        }
    }

    private weak var registeredScrollView: NSScrollView?

    public init(containerView: NSView, edge: NSScrollView.ScrollPocketEdge) {
        self.containerView = containerView
        self.edge = edge
    }
}

#endif

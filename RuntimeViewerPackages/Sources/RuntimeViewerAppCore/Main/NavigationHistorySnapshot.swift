#if os(macOS)

import Foundation
import RxAppKit

/// One row of a navigation-history menu.
///
/// `RxMenuItemRepresentable` lets `NSMenu.rx.items(source:)` build the
/// rows: it stores the item in `representedObject`, which
/// `rx.itemSelected(_:)` hands back on click.
public struct NavigationHistoryItem: RxMenuItemRepresentable, Hashable, Sendable {
    /// Index into the focused tab's `NavigationHistory.entries`, translated
    /// straight into `SelectionRoute.jump(toIndex:)` on click.
    public let index: Int

    public let displayName: String

    /// The step's icon: the object's glyph, or for an image the kind of what it is part of. The
    /// menu draws an image kind as it is, coloured, as every menu of images does.
    public let icon: IconDescriptor

    public var title: String { displayName }

    public init(index: Int, displayName: String, icon: IconDescriptor) {
        self.index = index
        self.displayName = displayName
        self.icon = icon
    }
}

/// Immutable projection of the focused editor pane's active tab's
/// `NavigationHistory` for the toolbar's back / forward history menus.
///
/// Built in `MainViewModel` and drawn by the window controller's history menus.
public struct NavigationHistorySnapshot: Hashable, Sendable {
    /// Same order as the history's entries — oldest entry first.
    public let items: [NavigationHistoryItem]

    /// The history's `currentIndex`, `-1` when the tab has shown nothing.
    public let currentIndex: Int

    /// Icon edge length for menu rows. Deliberately smaller than
    /// `RuntimeObjectIcon.defaultIconSize` (18, what the sidebar uses):
    /// an 18pt image forces AppKit to grow the menu row beyond the
    /// standard height. 16 keeps the same NSIcon look at the size
    /// menus are designed around.
    public static let iconSize: CGFloat = 16

    public init(items: [NavigationHistoryItem], currentIndex: Int) {
        self.items = items
        self.currentIndex = currentIndex
    }

    /// Entries reachable by going back, nearest first — the first row is
    /// where a single click of the back button would land (Safari
    /// ordering).
    public var backwardItems: [NavigationHistoryItem] {
        guard currentIndex > 0 else { return [] }
        return Array(items.prefix(currentIndex).reversed())
    }

    /// Entries reachable by going forward, nearest first.
    public var forwardItems: [NavigationHistoryItem] {
        guard currentIndex >= 0, currentIndex < items.count - 1 else { return [] }
        return Array(items[(currentIndex + 1)...])
    }
}

#endif

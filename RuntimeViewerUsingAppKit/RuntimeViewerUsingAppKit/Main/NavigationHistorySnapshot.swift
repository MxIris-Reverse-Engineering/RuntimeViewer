import AppKit
import RxAppKit

/// One row of a navigation-history menu.
///
/// `RxMenuItemRepresentable` lets `NSMenu.rx.items(source:)` build the
/// rows: it stores the item in `representedObject`, which
/// `rx.itemSelected(_:)` hands back on click.
struct NavigationHistoryItem: RxMenuItemRepresentable {
    /// Index into `DocumentState.selectionStack`, translated straight
    /// into `SelectionRoute.jump(toIndex:)` on click.
    let index: Int

    let displayName: String

    let icon: NSImage

    var title: String { displayName }
}

/// Immutable projection of `DocumentState.selectionStack` +
/// `selectionIndex` for the toolbar's back / forward history menus.
///
/// Built in `MainViewModel` (icon resolution included, mirroring
/// `resolveEngineIcon(for:)`) and rendered by
/// `NavigationHistoryMenuBuilder`.
struct NavigationHistorySnapshot {
    /// Same order as `selectionStack` — oldest entry first.
    let items: [NavigationHistoryItem]

    /// Mirrors `DocumentState.selectionIndex`. `-1` when the history is
    /// empty. `items.count` (one past the last entry) encodes an empty tab
    /// hovering above the timeline: nothing is shown, and the cursor entry
    /// itself is the nearest backward row.
    let currentIndex: Int

    /// Icon edge length for menu rows. Deliberately smaller than
    /// `RuntimeObjectIcon.defaultIconSize` (18, what the sidebar uses):
    /// an 18pt image forces AppKit to grow the menu row beyond the
    /// standard height. 16 keeps the same IDEIcon look at the size
    /// menus are designed around.
    static let iconSize: CGFloat = 16

    /// Entries reachable by going back, nearest first — the first row is
    /// where a single click of the back button would land (Safari
    /// ordering).
    var backwardItems: [NavigationHistoryItem] {
        guard currentIndex > 0 else { return [] }
        return Array(items.prefix(currentIndex).reversed())
    }

    /// Entries reachable by going forward, nearest first.
    var forwardItems: [NavigationHistoryItem] {
        guard currentIndex >= 0, currentIndex < items.count - 1 else { return [] }
        return Array(items[(currentIndex + 1)...])
    }
}

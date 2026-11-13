import Foundation

/// The heights of an editor pane's two bars — the tab bar and, under it, the jump bar — and where
/// the jump bar's row of controls sits (proposals `editor-panes` and `editor-jump-bar`). The pane's
/// view controller lays its bars out by these numbers; they live here so they can be tested.
///
/// The heights are Xcode 27.2's (`/Volumes/RE/Xcode/27.2-27B52/README.md`, "Editor panes — visuals"
/// §3 and "Editor jump bar" §2): each bar is a 28-point row with 4 points under it and 4 above, none
/// above in a pane right under the toolbar, and the jump bar none above under the tab bar either,
/// plus a 1-point border along its bottom — a tab bar of 32 or 36 points, and a jump bar of 33, or
/// 37 in a pane further down without a tab bar.
///
/// One departure from Xcode, which keeps the jump bar's row at the top of a bar right under the
/// toolbar, 2 points above its middle: wherever the tab bar is hidden, the row sits midway between
/// the bar's top and its border. Under the tab bar it stays at the top, where the 4 points under the
/// tab bar's row are the room above it, as many as below it.
public struct EditorPaneBarMetrics: Hashable, Sendable {
    /// The height of either bar's row of controls.
    public static let rowHeight: CGFloat = 28

    /// The room under either bar's row, and above it where the bar has room above.
    public static let padding: CGFloat = 4

    /// The border along the jump bar's bottom.
    public static let jumpBarBorderWidth: CGFloat = 1

    /// Whether the pane's top is under the toolbar — a pane of the layout's top row — which leaves no
    /// room above the first bar's row.
    public var isToolbarAdjacent: Bool

    /// Whether the tab bar is hidden: no pane has a second tab.
    public var isTabBarHidden: Bool

    /// Whether the jump bar is hidden: the pane's active tab shows nothing.
    public var isJumpBarHidden: Bool

    public init(isToolbarAdjacent: Bool, isTabBarHidden: Bool, isJumpBarHidden: Bool) {
        self.isToolbarAdjacent = isToolbarAdjacent
        self.isTabBarHidden = isTabBarHidden
        self.isJumpBarHidden = isJumpBarHidden
    }

    /// The room above the tab bar's row: none under the toolbar.
    public var tabBarTopPadding: CGFloat {
        isToolbarAdjacent ? 0 : Self.padding
    }

    /// The tab bar's height, whether it shows or not.
    public var tabBarHeight: CGFloat {
        tabBarTopPadding + Self.rowHeight + Self.padding
    }

    /// How far below the pane's top the jump bar starts: under the tab bar while that shows.
    public var jumpBarTopOffset: CGFloat {
        isTabBarHidden ? 0 : tabBarHeight
    }

    /// The jump bar's height, border included, whether it shows or not: Xcode's, which has no room
    /// above the row under the toolbar or under the tab bar.
    public var jumpBarHeight: CGFloat {
        let roomAboveRow = isToolbarAdjacent || !isTabBarHidden ? 0 : Self.padding
        return roomAboveRow + Self.rowHeight + Self.padding + Self.jumpBarBorderWidth
    }

    /// The room above the jump bar's row: half of what the row leaves above the border while the
    /// tab bar is hidden, so the row is midway between the bar's top and its border; none under the
    /// tab bar.
    public var jumpBarTopPadding: CGFloat {
        isTabBarHidden ? (jumpBarHeight - Self.jumpBarBorderWidth - Self.rowHeight) / 2 : 0
    }

    /// The depth of the bars on show, which the content's safe area makes room for.
    public var barsHeight: CGFloat {
        jumpBarTopOffset + (isJumpBarHidden ? 0 : jumpBarHeight)
    }
}

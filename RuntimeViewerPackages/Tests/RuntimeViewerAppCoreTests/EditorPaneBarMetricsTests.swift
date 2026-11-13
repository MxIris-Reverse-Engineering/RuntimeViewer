import CoreGraphics
import Testing
@testable import RuntimeViewerAppCore

/// The numbers an editor pane lays its two bars out by (proposal `editor-jump-bar`): Xcode 27.2's
/// heights, the jump bar's row as far from what is above it — the bar's top, or the tab bar's row —
/// as from its border, and no room kept for a jump bar that is hidden.
@Suite("EditorPaneBarMetrics")
struct EditorPaneBarMetricsTests {
    /// The room between the jump bar's row and its border.
    private static func roomBelowJumpBarRow(in metrics: EditorPaneBarMetrics) -> CGFloat {
        metrics.jumpBarHeight - EditorPaneBarMetrics.jumpBarBorderWidth - EditorPaneBarMetrics.rowHeight - metrics.jumpBarTopPadding
    }

    @Test(
        "the bars keep Xcode's heights",
        arguments: [
            // Under the toolbar, with and without the tab bar; further down, with and without it.
            (true, true, 32, 33),
            (true, false, 32, 33),
            (false, true, 36, 37),
            (false, false, 36, 33),
        ] as [(Bool, Bool, CGFloat, CGFloat)]
    )
    func xcodeHeights(isToolbarAdjacent: Bool, isTabBarHidden: Bool, tabBarHeight: CGFloat, jumpBarHeight: CGFloat) {
        let metrics = EditorPaneBarMetrics(isToolbarAdjacent: isToolbarAdjacent, isTabBarHidden: isTabBarHidden, isJumpBarHidden: false)

        #expect(metrics.tabBarHeight == tabBarHeight)
        #expect(metrics.jumpBarHeight == jumpBarHeight)
    }

    @Test("without the tab bar, the jump bar's row is as far from the bar's top as from its border", arguments: [true, false])
    func jumpBarRowCentredWithoutTabBar(isToolbarAdjacent: Bool) {
        let metrics = EditorPaneBarMetrics(isToolbarAdjacent: isToolbarAdjacent, isTabBarHidden: true, isJumpBarHidden: false)

        #expect(metrics.jumpBarTopPadding == Self.roomBelowJumpBarRow(in: metrics))
    }

    @Test("under the tab bar, the jump bar's row is as far from the tab bar's row as from its border", arguments: [true, false])
    func jumpBarRowCentredUnderTabBar(isToolbarAdjacent: Bool) {
        let metrics = EditorPaneBarMetrics(isToolbarAdjacent: isToolbarAdjacent, isTabBarHidden: false, isJumpBarHidden: false)
        let roomUnderTabBarRow = metrics.tabBarHeight - metrics.tabBarTopPadding - EditorPaneBarMetrics.rowHeight

        #expect(roomUnderTabBarRow + metrics.jumpBarTopPadding == Self.roomBelowJumpBarRow(in: metrics))
    }

    @Test("a hidden jump bar keeps no room: the content starts under the tab bar, or right at the top")
    func hiddenJumpBarKeepsNoRoom() {
        let noRoom: CGFloat = 0
        let bothHidden = EditorPaneBarMetrics(isToolbarAdjacent: true, isTabBarHidden: true, isJumpBarHidden: true)
        let tabBarAlone = EditorPaneBarMetrics(isToolbarAdjacent: true, isTabBarHidden: false, isJumpBarHidden: true)
        let jumpBarAlone = EditorPaneBarMetrics(isToolbarAdjacent: true, isTabBarHidden: true, isJumpBarHidden: false)
        let bothShown = EditorPaneBarMetrics(isToolbarAdjacent: true, isTabBarHidden: false, isJumpBarHidden: false)

        #expect(bothHidden.barsHeight == noRoom)
        #expect(tabBarAlone.barsHeight == tabBarAlone.tabBarHeight)
        #expect(jumpBarAlone.barsHeight == jumpBarAlone.jumpBarHeight)
        #expect(bothShown.barsHeight == bothShown.tabBarHeight + bothShown.jumpBarHeight)
    }
}

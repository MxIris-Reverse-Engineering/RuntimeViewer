# Draft - 编辑区内容从工具栏与标签栏下滚过并透出模糊

- **状态**: Accepted
- **创建日期**: 2026-11-12
- **最后更新**: 2026-11-12
- **实现分支**: `feature/editor-content-under-toolbar-scroll-pocket`

## 摘要

macOS 26 起，把编辑区顶部改成 Xcode 27.2 的样子：每一栏的内容铺满整栏，从工具栏和分栏标签栏下面滚过，两处都由 AppKit 的滚动边缘效果（scroll pocket，内容滚到栏下时画出的模糊层）透出模糊的内容。现在标签栏一显示，内容就从栏的上沿开始，工具栏下那一条只剩窗口底色，还会漏出 Gutter 画到滚动视图外的行号；标签栏本身是不透明的窗口背景色。这是 [0076 编辑器分栏](0076-editor-panes.md)「非目标」里「滚动口袋做标签栏的底」那一项。

## 方案

Xcode 的做法（`/Volumes/RE/Xcode/27.2-27B52/README.md`「Editor panes — visuals」§6，只在公司那台 Mac 的 RE 卷上）：编辑器视图铺满整栏，标签栏放在安全区顶部，内容的安全区加上栏高，栏的底是一个 `DVTEdgeOcclusionView`，里面是 style 2 的 `NSScrollPocket`。本提案改走侧栏已经在用的另一条路（`NavigatorScrollViewLayout`，把浮在列表上的栏登记为列表滚动视图的 pocket 容器），效果相同，不新增私有 API：

1. **内容铺满整栏。** macOS 26 起，`EditorPaneViewController` 的内容不论标签栏显示与否都铺满整栏，撤掉 11-06 加的「内容顶边跟标签栏顶边」那组约束切换。顶行栏的滚动视图碰到标题栏，AppKit 会自动把标题栏容器登记为它的顶部 pocket 容器，工具栏那一条就有了模糊。标签栏的高度照旧经内容的 `additionalSafeAreaInsets` 让出。
2. **标签栏变成「栏」。** macOS 26 起，`EditorPaneTabBarView` 不再画不透明背景，`_scrollPocketElementStyle` 回答 `NSView.barScrollPocketElementStyle`（与 `ScrollPocketBarView` 同一个值），并经 UIFoundation 的 `NSScrollView.box.registerScrollPocketContainer(_:on: .top)` 登记为当前内容滚动视图的顶部容器。内容换了，先从旧的滚动视图撤销，再登记到新的；栏隐藏时撤销。
3. **内容交出滚动视图。** `EditorPaneContent` 加 `var contentScrollView: NSScrollView? { get }`（先例是 UIKit 的 `UIViewController.contentScrollView(for:)`；这里只用到顶边，所以写成属性）。`ContentTextViewController` 交出它的 `scrollView`；`ContentSourceEditorViewController` 交出桥接层新加的 `SourceEditorBridging.scrollView: NSScrollView`，也就是 `SourceEditorView.scrollView`（重建版里本来就是 public），以 `NSScrollView` 交出，桥接层的公开接口仍不出现 SourceEditor 的类型；占位页没有，返回 `nil`。窗格做自己 `ContentNavigationController` 的 delegate，在 `navigationController(_:didShow:)` 里跟上当前显示的内容。
4. **macOS 15 不变**：内容仍从标签栏上沿开始，标签栏仍用窗口背景色。
5. **测试**：量内容滚动视图顶部 pocket 的几何，确认它盖住标签栏，且换内容之后跟着新的滚动视图走。
6. **文档**：0076 的「外观」「非目标」与决策日志，提案索引「暂缓的后续项」里那一行，`EditorPaneViewController` 的文档注释，`RuntimeViewerUsingAppKit/AGENTS.md` 补一条：编辑栏也是登记给内容滚动视图的 pocket 容器。

**落地步骤**（每步各自能构建通过）

1. 先量风险：测试里量 Minimap 与 AppKit 顶部 pocket 视图在 SourceEditor 滚动视图子视图里的先后。
2. 桥接层的 `SourceEditorBridging.scrollView`、`EditorPaneContent.contentScrollView`，三个内容控制器各自交出滚动视图。
3. 窗格：内容铺满整栏（macOS 26 起），标签栏去底色、回答 Bar 样式、登记为当前内容滚动视图的顶部 pocket 容器并随内容切换，附测试。
4. 文档：0076、提案索引、`EditorPaneViewController` 的文档注释与 `RuntimeViewerUsingAppKit/AGENTS.md`。

**没有询问就采用的假设**

- 模糊由内容滚动视图自己的 pocket 来画，样式用 AppKit 默认值，不像侧栏那样在 macOS 26 上设 style 2；目视和 Xcode 差得明显再调。
- 栏与栏之间的分隔线仍不画进工具栏区。
- 空标签的占位页没有滚动视图，标签栏下面直接透明，和 Xcode 的空编辑器一样。
- Gutter 行号画到滚动视图外的问题不另修：内容铺满后它落在工具栏的模糊区里。

**风险**

- 11-06 让内容避开工具栏，是因为 Minimap 的竖线穿过了工具栏。重建版把 Minimap 当作 `marginOverlayView` 加进滚动视图、铺满整个高度（27.2.0-alpha.1 的 `ContentViewLayoutContainer.layoutMarginAccessories`）。如果 AppKit 的 pocket 视图排在它下面，工具栏下的 Minimap 和竖线就依旧清晰。实现第一步先写测试，量出两者在滚动视图子视图里的先后；如果 Minimap 在上面，要改的是重建版 SourceEditor 仓库，到时再定。
- 最终观感只能目视验收。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-12 | Created as Draft | 用户要编辑区的工具栏像 Xcode 一样透出模糊的内容；现在只要标签栏显示，工具栏下那一条就只有窗口底色 |
| 2026-11-12 | 把标签栏登记为内容滚动视图的 pocket 容器，不照 Xcode 在栏里单独放一块 `NSScrollPocket` | 复用侧栏已有的登记机制，不用为私有类新写封装，也不必先发 UIFoundation 再抬 pin；用户选定 |
| 2026-11-12 | 走轻量档 | 用户选定 |
| 2026-11-12 | 状态改为 Accepted，开始实现 | 用户批准 |

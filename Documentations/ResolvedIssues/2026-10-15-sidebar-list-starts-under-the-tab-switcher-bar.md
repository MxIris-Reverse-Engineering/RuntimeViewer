# 2026-10-15 侧栏推进来的页面，列表顶在分段控件栏底下

**调查日期：** 2026-10-15
**修复落地：** 本日，`next`
**Severity：** Medium —— 列表开头的分组头和第一行压在分段控件栏底下，滚到最顶也露不出来；拖一下侧栏宽度就恢复
**触发场景：** macOS 26 起，在侧栏选中一个镜像、推进到它的对象列表页（[0052](../Evolutions/0052-xcode-navigator-overlay-bars.md) 落地之后）

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 列表滚到最顶时，「C Struct」分组头和第一行仍在分段控件栏底下。截图（2x，窗口 1321 × 861 pt）里第一行从窗口顶往下约 60 pt 开始，等于工具栏 52 + 8；按设计应是 52 + 28（栏高）+ 8 = 88 |
| **影响范围** | 两个侧栏 tab 切换器（`SidebarRootTabViewController`、`SidebarRuntimeObjectTabViewController`）下的全部页面——对象列表、书签、Find、Reports、根页的镜像列表——只要切换器的根视图在最终尺寸上只排过一次版。Inspector（`.belowSegmentedControl`）不受影响 |
| **根因** | `TabViewController.viewDidLayout` 读分段控件栏的 frame，来设 `tabView.additionalSafeAreaInsets.top`。栏是控制器根视图的孙子（根视图 → `contentView` → 栏），而 AppKit 调 `viewDidLayout` 时只排好了根视图的直接子视图，栏的 frame 还是上一轮的，第一轮是 0 高。之后只有根视图的尺寸再变，才会再走一次 `viewDidLayout` |
| **Status** | **Fixed** —— 新增 `FloatingBarSafeAreaLayout`（RuntimeViewerUI），跟随栏的 frame 变化写入 safe area；`TabViewController` 不再覆写 `viewDidLayout` |

---

## 根因

AppKit 26.7 的排版顺序（反编译 `/Volumes/DyldSharedCaches/macOS/26.7/AppKit+UIKitCore+UIKitMacHelper+UpdateCycle.i64` 的副本）：

- `-[NSView _layoutSubtreeWithOldSize:]` 的块（0x18571EBF8）先排这个视图自己，再递归进它的子视图。
- 「排这个视图自己」是 `___NSViewLayout_block_invoke`（0x185728E08）：依次调控制器的 `viewWillLayout`、视图的 `layout`、控制器的 `viewDidLayout`。
- `-[NSView layout]`（0x184A3AE54）的默认实现只对**直接子视图**调 `NSViewUpdateFrameFromLayoutEngine`，也就是只给直接子视图设 frame。

所以在 `TabViewController.viewDidLayout` 里，`contentView` 的 frame 是新的，`contentView` 里的分段控件栏还没轮到。第一次排版时栏还是初始的零矩形，读到的高度是 0，`guard` 判定没有变化，tab view 的额外 safe area 停在 0。栏的 frame 随后在 `contentView.layout` 里设成 28 高，但这不会让根视图再次需要排版；只有根视图的尺寸再变（拖侧栏宽度、改窗口大小），`viewDidLayout` 才会再跑，读到上一轮留下的 28。推进来的页面在最终尺寸上只排一次，于是一直缺这 28 点。用户拖了一下侧栏即恢复，与此吻合。

结果：页面里列表的 `safeAreaInsets.top` 只有工具栏的 52，`NavigatorScrollViewLayout` 据此把 clip view 的 `contentInsets.top` 设成 52 + 8 = 60，第一行落在栏下。

## 修复

`FloatingBarSafeAreaLayout(barView:coveredView:)` 监听栏的 `NSView.frameDidChangeNotification`，把栏高写进被盖住的视图的 `additionalSafeAreaInsets.top`。它落在正确的时机：栏与 tab view 是兄弟视图，两者的 frame 都在 `contentView.layout` 里设定；`-[NSView _postFrameChangeNotification]`（0x184A25524）在设 frame 时同步发通知（只在 `setFrame:` 这类合并修改期间暂缓到修改结束），AppKit 之后才递归去排 tab view 的子树，所以页面在同一轮里就看到了栏。

`TabViewController` 在 `layOutSegmentedControlBar()` 里（`.underSegmentedControl` 时）创建它，删掉了 `viewDidLayout` 覆写。写入的仍是栏高，与原来的语义一致：栏贴在 tab view 已有 safe area 的上沿，栏高就是它多盖住的深度。

没有采用的写法：

- **在 `viewDidLayout` 里先 `contentView.layoutSubtreeIfNeeded()` 再读**：会在排版中途把整棵页面树多排一遍。
- **改读栏的 `fittingSize`**：第一轮也能拿到 28，但算的是假设值而不是栏的实际 frame，栏以后被别的约束撑高就对不上了。
- **把栏挪成根视图的直接子视图**：`viewDidLayout` 就能读到新 frame，但正确性压在「栏必须是直接子视图」这个看不见的前提上，谁调整层级谁就会把它弄坏。

## 验证

- **复现测试**：`RuntimeViewerApplicationTests` 的 `TabSwitcherBarSafeAreaTests`，三个用例。fixture 照 `TabViewController` 的层级搭：根视图 → `contentView` → tab view 加栏；页面 → 容器 → 镜像状态的 tab view → 列表与过滤栏，由 `NavigatorScrollViewLayout` 管。工具栏的 52 点用根视图的 `additionalSafeAreaInsets` 代替。
  - 修复前（fixture 用原来的 `viewDidLayout` 写法），三个全红，原始退出码 1：tab view 的额外 safe area 为 0（栏高 28），列表的 safe area 为 52（应为 80），clip view 顶部内边距为 60（应为 88），与截图一致；第一轮排版之后才选中的页面同样是 60；把分段控件改成 `.small`、栏高变成 20 之后，仍是 0 和 60。
  - 修复后三个全绿；第三个用例同时证实，栏高变化经 tab view 的 safe area 穿过页面里那层 tab view，一路传到了列表。
  - `NavigatorScrollViewLayoutTests` 的 12 个用例照常全过。两个套件合计 15 个，原始退出码 0（JHs-Mac-Studio，macOS 26.7，Xcode 27.0 的 `swift build` / `swift test`）。
- App 没有完整构建：`TabViewController.swift` 连同提供 `.then` 的 `Utils/Then.swift`，用同一次编出的包模块做了 `swiftc -typecheck`，0 错误 0 警告。
- 修复后的外观由用户在 App 里目视确认。

## 局限

- 测试测的是 RuntimeViewerUI 的 `FloatingBarSafeAreaLayout` 与照抄的层级，不是 App target 里的 `TabViewController` 本身：App 没有测试 target。`TabViewController` 里只剩创建这一行，层级一旦改了，fixture 要跟着改。

## 同类

- 全工程只有 `TabViewController` 在 `viewDidLayout` 里读孙子视图的 frame。另一处 `ContentSourceEditorViewController.viewDidLayout` 读的是控制器自己根视图的 `safeAreaInsets`，根视图的 frame 在父视图排版时已经设好，不受这个顺序影响。
- 规则写进了 `AGENTS.md` 的「Navigator pages run under their bars」。

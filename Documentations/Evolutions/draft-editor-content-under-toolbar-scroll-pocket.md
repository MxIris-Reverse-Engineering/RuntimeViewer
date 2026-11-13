# Draft - 编辑区内容从工具栏与标签栏下滚过并透出模糊

- **状态**: In Progress
- **创建日期**: 2026-11-12
- **最后更新**: 2026-11-13
- **实现分支**: `feature/editor-content-under-toolbar-scroll-pocket`

## 摘要

macOS 26 起，把编辑区顶部改成 Xcode 27.2 的样子：每一栏的内容铺满整栏，从工具栏和分栏标签栏下面滚过，两处都由 AppKit 的滚动边缘效果（scroll pocket，内容滚到栏下时画出的模糊层）透出模糊的内容。现在标签栏一显示，内容就从栏的上沿开始，工具栏下那一条只剩窗口底色，还会漏出 Gutter 画到滚动视图外的行号；标签栏本身是不透明的窗口背景色。这是 [0076 编辑器分栏](0076-editor-panes.md)「非目标」里「滚动口袋做标签栏的底」那一项。

## 方案

照 Xcode 27.2 编辑区的做法（`/Volumes/RE/Xcode/27.2-27B52/README.md`「Editor panes — visuals」§6 与「Content under the toolbar」§8，只在公司那台 Mac 的 RE 卷上）：编辑器视图铺满整栏，标签栏放在安全区顶部，内容的安全区加上栏高；工具栏那一条和每个标签栏的底，各是一块独立的 `NSScrollPocket`（Xcode 的 `DVTEdgeOcclusionView`，style 2），排在所有正文之前。

1. **内容铺满整栏。** macOS 26 起，`EditorPaneViewController` 的内容不论标签栏显示与否都铺满整栏，撤掉 11-06 加的「内容顶边跟标签栏顶边」那组约束切换。标签栏的高度照旧经内容的 `additionalSafeAreaInsets` 让出。
2. **工具栏那一条：编辑区最前面一块 pocket。** `EditorAreaViewController` 把根分栏视图放进 RuntimeViewerUI 新增的 `ToolbarScrollPocketContainerView`：最前面一块 UIFoundation 的 `ScrollPocketView`（style 2、不画分隔线、自己的 backdrop 分组），从容器顶边到安全区顶边、横跨所有分栏；它的 capture view 放在最底层同一位置，供它重放内容后面的底色。所有分栏的正文、Minimap、AppKit 给滚动视图自带的 pocket 都在它后面，一次截全。
3. **标签栏：各自背后一块 pocket。** `EditorPaneTabBarView` 在最底层放一块 `ScrollPocketView`（同样 style 2），capture view 由窗格放在内容后面、与标签栏重合；标签栏隐藏时一起隐藏。标签栏不再登记给内容的滚动视图，也不再回答 Bar 样式。
4. **内容自带的 pocket 单独分组。** AppKit 仍给伸到标题栏下的内容滚动视图各加一个顶部 pocket（软模糊），它们压在上面两种 pocket 下面。窗格在内容容器上设 `NSView.box.titlebarBackdropGroupName`（UIFoundation），让每栏的这一层各自截图，而不是共用窗口的分组、在第二栏绘制前就截好。
5. **macOS 15 不变**：内容仍从标签栏上沿开始，标签栏仍用窗口背景色，没有 pocket。
6. **依赖**：`ScrollPocketView` 与 `titlebarBackdropGroupName` 是 UIFoundation 0.47.0 新增的（UIFoundation 提案 0038），UIFoundation 的下限与四份锁文件（Debug、Distribution 两个 workspace，`RuntimeViewerPackages`、`RuntimeViewerCommandLine`）的 pin 抬到 0.47.0。
7. **测试**：`ToolbarScrollPocketContainerViewTests`（RuntimeViewerApplicationTests）：两个滚动视图并排在工具栏下，容器最前面有一块盖住整条工具栏的 pocket、capture view 在最底层同一位置、它的分组和各栏自带 pocket 的不同、工具栏隐藏后高度跟着变；修复前四条全红。`ScrollPocketUnderToolbarTests`（桥接测试）确认 SourceEditor 的滚动视图伸到工具栏下时，自带的顶部 pocket 正好与工具栏一样高，并把 Minimap 排在它之上记成已知问题。App target 没有单元测试 target，窗格与标签栏的接线靠构建与目视验收。
8. **文档**：0076 的「外观」「非目标」与决策日志，提案索引的暂缓后续项，`EditorPaneViewController` 与 `EditorAreaViewController` 的文档注释，`RuntimeViewerUsingAppKit/AGENTS.md`，根 `AGENTS.md` 的依赖下限。

**落地步骤**（每步各自能构建通过）

1. ✅ 先量风险：测试里量 Minimap 与 AppKit 顶部 pocket 视图在 SourceEditor 滚动视图子视图里的先后（结论见「风险」）。
2. ✅ 第一版：内容铺满整栏，标签栏登记为内容滚动视图的 pocket 容器（11-12 合进本地 next）。
3. ✅ 定位用户目视发现的问题：两栏时只有左栏正文上方的工具栏是模糊的，从左栏 Minimap 往右都是平的窗口底色（原因见「风险」）。
4. ✅ UIFoundation：`ScrollPocketView` 与 `titlebarBackdropGroupName`，附测试；随 0.47.0 发布（UIFoundation 提案 0038）。
5. ✅ RV：编辑区前置 pocket（`ToolbarScrollPocketContainerView`，附测试）、标签栏各自的 pocket、内容单独分组；撤掉第一版的 `ScrollPocketContainerRegistration`、`EditorPaneContent.contentScrollView` 与 `SourceEditorBridging.scrollView`。
6. ✅ 抬 UIFoundation 到 0.47.0，编译、测试、文档。

**没有询问就采用的假设**

- 前置 pocket 与标签栏的 pocket 都用 style 2，照抄 Xcode：底色重放近乎不透明（实测非 key 窗口 0.85），内容只透出很少一点。
- 前置 pocket 只盖工具栏那一条，宽度取整个编辑区；标签栏那一条由各自的 pocket 盖。
- 栏与栏之间的分隔线仍不画进工具栏区。
- 空标签的占位页没有滚动视图，标签栏下只有那块 pocket 重放的底色。

**风险**

- 11-06 让内容避开工具栏，是因为 Minimap 的竖线穿过了工具栏。重建版把 Minimap 当作 `marginOverlayView` 加进滚动视图、铺满整个高度，排在滚动视图自带的 pocket 之上（2026-11-12 实测，27.2.0-alpha.2），所以只靠自带的 pocket 时，工具栏下的 Minimap 是清晰的。现在前置 pocket 和标签栏的 pocket 排在它前面，App 里看不到这个问题；编辑器单独放在工具栏下时问题仍在，修复属于重建版仓库，`ScrollPocketUnderToolbarTests` 记成已知问题。
- **第一版目视发现的问题（2026-11-13，macOS 27.2）**：两栏时只有左栏正文上方的工具栏是模糊的，从左栏 Minimap 往右（连同整个右栏）是一块平的窗口底色。原因在 AppKit：一个窗口里所有伸到标题栏下的 pocket 共用一个 backdrop 分组（`TitlebarGroup-<窗口>`），只截一次图，在第一个 pocket 绘制时截，之后才绘制的左栏 Minimap 和整个右栏都不在截图里。纯 AppKit 两个并排滚动视图也复现，与焦点、Minimap、文件长短无关。证据：运行中的 App 里两栏 pocket 模糊内容的 `CABackdropLayer` 分组同名；逆向见 UIFoundation 的 `Researchs/AppKit-NSScrollView-ScrollPocket-Internals.md` 第 5 节。
- 最终观感只能目视验收；这一版的效果没有截图核对过（验证用的那台 Mac 锁着屏）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-12 | Created as Draft | 用户要编辑区的工具栏像 Xcode 一样透出模糊的内容；现在只要标签栏显示，工具栏下那一条就只有窗口底色 |
| 2026-11-12 | 把标签栏登记为内容滚动视图的 pocket 容器，不照 Xcode 在栏里单独放一块 `NSScrollPocket` | 复用侧栏已有的登记机制，不用为私有类新写封装，也不必先发 UIFoundation 再抬 pin；用户选定 |
| 2026-11-12 | 走轻量档 | 用户选定 |
| 2026-11-12 | 状态改为 Accepted，开始实现 | 用户批准 |
| 2026-11-12 | Minimap 盖在模糊层上面已实测证实；RV 这一侧照方案做完，Minimap 列为重建版 SourceEditor 的后续项 | Minimap 默认关闭，单栏时 8 月起就是这样，这次没有让它更糟；修复属于重建版仓库，按 SourceEditor 模块的规矩不在 RV 里绕过 |
| 2026-11-12 | 登记逻辑做成 RuntimeViewerUI 的 `ScrollPocketContainerRegistration`，不直接写在窗格里 | App target 没有单元测试 target，放进包里才能测；侧栏的 `NavigatorScrollViewLayout` 也在那里 |
| 2026-11-12 | 窗格除了 `navigationController(_:didShow:)`，在 `viewDidLayout` 里也对一次当前内容的滚动视图 | AppKitPlus 的头文件只说转场完成时与视图出现时会发 didShow，没写明不带动画的 `set` 算不算转场，窗格又没有测试能证明；重复登记同一个滚动视图什么也不做，代价只是一次比较 |
| 2026-11-12 | 实现完成，待用户目视验收后收尾 | 整个 App 在 Debug 下编译通过；桥接测试 71 条中只有 `SourceEditorScrollerTests` 两条既有红；RuntimeViewerPackages 全量 939 条里满载下红的几组单独重跑都过，只剩 `TitleActivityIndicatorTests` 的悬停一条，它测的 `TitleToolbarItem` 与基线逐字相同，属基线既有。不另写实现说明与使用指南：规则写进了 `RuntimeViewerUsingAppKit/AGENTS.md`，没有 App 之外的调用方；没有新术语 |
| 2026-11-13 | 两栏时工具栏只有左栏一段是模糊的，查明是 AppKit 让所有贴着标题栏的 pocket 共用一个只截一次的 backdrop 分组 | 截图量出右边是均匀的平色；运行中的 App 里两栏 pocket 同组；纯 AppKit 复现；逆向确认分组名的来源 |
| 2026-11-13 | 改走 Xcode 的做法：编辑区最前面一块横跨所有分栏的 style 2 pocket，标签栏各自背后一块，不再把标签栏登记给内容滚动视图 | 用户比较了「每栏单独分组」与「Xcode 式前置 pocket」后选定后者：一块前置 pocket 一次截全所有分栏，也把画在工具栏上的 Minimap 盖住；代价是观感近乎实色，照抄 Xcode |
| 2026-11-13 | 前置 pocket 与标签栏 pocket 封装进 UIFoundation（`ScrollPocketView`），与 `titlebarBackdropGroupName` 同发 0.47.0 | 私有 API 一律放 UIFoundationAppleInternal；两样同一个版本，RV 只抬一次 pin |
| 2026-11-13 | 内容自带的 pocket 也按栏单独分组 | 它们压在前置 pocket 下面，不透明度 0.85 到 0.95 时仍会透出一点；单独分组后每栏透出的都是模糊的内容，而不是右栏一块平色 |
| 2026-11-13 | 撤掉第一版的 `ScrollPocketContainerRegistration`、`EditorPaneContent.contentScrollView`、`SourceEditorBridging.scrollView` | 新做法用不到；桥接测试改为从 `editorView` 取 `SourceEditorView.scrollView`，与已有的测试辅助一致 |
| 2026-11-13 | UIFoundation 0.47.0 发布；四份锁文件只改 UIFoundation 一条，手改后用全新构建目录核验 | 用户批准发版。全新构建目录下两个 workspace 与两个包重新解析，锁文件字节不变；不用会推进所有 pin 的 `UpdatePackagesScript.sh`。Tuist 工作区的锁文件不进仓库，本地要 `./TuistScript.sh install` 之后才用上新版 |
| 2026-11-13 | 实现完成，待用户目视验收后收尾 | Debug workspace 对着发布的 UIFoundation 0.47.0 编译通过，`ToolbarScrollPocketContainerViewTests` 四条通过。对着本地 UIFoundation 跑过全量：桥接测试 71 条只有 `SourceEditorScrollerTests` 两条既有的红；包测试 939 条只剩 `TitleActivityIndicatorTests` 悬停一条基线既有的红，满载下红的两组单独重跑都通过。观感没有截图核对过，交给用户目视 |

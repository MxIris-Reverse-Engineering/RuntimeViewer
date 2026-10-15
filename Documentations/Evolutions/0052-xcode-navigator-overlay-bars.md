# 0052 - 侧栏照 Xcode 导航区布局：浮在列表上的栏与滚动边缘效果

- **状态**: In Progress
- **创建日期**: 2026-10-14
- **最后更新**: 2026-10-15
- **所属愿景**: 无
- **配套文档**: 无。逆向证据与全部地址在本机资料卷 `/Volumes/RE/Xcode/27.2/README.md` 的「Navigator chooser and scroll pockets (2026-10-14)」一节（IDEKit 27.2 的头文件、Swift dump 与 IDA 库在同目录 `IDEKit/`，AppKit 27.0 的库是 `/Volumes/DyldSharedCaches/macOS/27.0/AppKit-20261014.i64`）

## 摘要

侧栏原来是上下堆叠的：tab 切换器的分段控件在上、页面在下，页面里又是「列表 → 1 点分隔线 → 过滤栏」。列表在两头都被截断，滚到控件底下的内容没有 macOS 26 的滚动边缘效果（内容滑到栏下面时的模糊与变暗，AppKit 内部叫 scroll pocket）。Xcode 的导航区不是这样搭的：列表全高，一直伸到工具栏底下；顶部的分段控件栏和底部的过滤栏都是浮在列表上的兄弟视图，靠安全区（safe area）让列表内容让开，滚动时从栏底下穿过，AppKit 在栏下画边缘效果。本次在 macOS 26 起照搬这套结构，macOS 15 保持堆叠。分两期：第一期只用已发布的依赖，第二期补上 Xcode 额外用的私有登记，要等 UIFoundation 发版。

## 方案

### Xcode 的做法

- **结构**：`IDENavigatorAreaContentView` 用手算 frame 摆放三个子视图：铺满整块的导航器（`DVTReplacementView`）、紧贴工具栏下沿的分段控件栏 `IDETwoLevelChooserView`（高 28，控件左右各内缩 8），以及过滤栏。导航器的滚动视图全高。Inspector 不一样：`IDEUtilityAreaContentView` 从工具栏下沿开始，分段控件在顶部，内容从 y = 28 往下，是堆叠的。
- **让出空间**：内容视图给自己设 `additionalSafeAreaInsets.top = 28`。导航器滚动视图的 clip view 关掉自动内边距，`contentInsets = (safeAreaInsets.top + 8, 0, safeAreaInsets.bottom, 0)`，并 KVO 安全区重排。抓图里顶部安全区 80 = 工具栏 52 + 栏 28，clip view 的 bounds 原点是 −88。底部由导航器视图（`IDEExplorableNavigatorView`）直接给滚动视图设 `additionalSafeAreaInsets.bottom = 过滤栏高（44）`。
- **边缘效果**：AppKit 27.0 里，顶部 pocket 的高度是滚动视图的 `safeAreaInsets.top`，再并上登记在顶边的容器；底部 pocket 是高为**滚动视图自己的** `contentInsets.bottom` 的一条（不是 clip view 的），再并上底边的容器。27.2 上实测相同：只给 clip view 设内边距、滚动视图自己的为 0 时，底部 pocket 是 0 高；滚动视图 `contentInsets.top = 80` 而安全区为 0 时，顶部 pocket 也是 0 高。显示与否的规则是：这条边在 `alwaysShownPocketEdges` 里，或者边上登记了容器，pocket 才出现。滚动视图顶到标题栏时，窗口会自动把标题栏登记上去；底边只有 split view item 的底部附件会被自动登记。Xcode 在安装导航器时对滚动视图调用私有的 `setAlwaysShownPocketEdges:3`、`registerPocketContainer:<分段控件栏> onEdge:0`、`registerPocketContainer:<过滤栏> onEdge:1`，27 上再设 `setScrollPocketStyle:(有第二级 ? 2 : 0) onEdge:0`。分段控件栏（`IDETwoLevelChooserView`，IDEKit 27.2 `0x2A3268`）和过滤栏（`DVTFilterExpressionControlBar`，DVTUserInterfaceKit 27.2 `0xA3A38`）都覆写私有的 `_scrollPocketElementStyle` 返回 2，与 AppKit 给 split view item 附件包装视图的值相同；DVT 把这个值叫作「Bar」，见它的 `NSViewWithScrollPocketElementStyleBar`。Find 导航器把查询区、summary 行、load-more 行三个视图都登记在结果列表的顶边。
- **分段控件本身**：`.large`，选中段用强调色（`selectedSegmentBezelColor`），spring-loaded，27 上 `role = .tabs`、`clipsToBounds = false`。控件里的 `_NSCoreHostingView<AppKitSegmentedControl>` 是 AppKit 26 起自己的渲染方式，不是 Xcode 加的。

### 第一期（本次落地，只用已发布的依赖）

1. **`TabViewController.PageLayout`**：`underSegmentedControl` 给两个侧栏 tab 切换器，`belowSegmentedControl`（默认）给 Inspector。26 起分段控件放进一个全宽的栏 `segmentedControlBarView`，左右各内缩 8。浮层模式下 tab view 铺满、栏在其上，`viewDidLayout` 里把栏的实际高度写进 `tabView.additionalSafeAreaInsets.top`。控件配置补齐 Xcode 的几项。
2. **底部过滤栏与页面**：见下一节。

### 第一期：页面与底部过滤栏

- **`NavigatorScrollViewLayout`**（`RuntimeViewerUI/AppKit/NavigatorScrollViewLayout.swift`）：每个页面持有一个，传入列表的滚动视图，以及浮在它顶边、底边上的视图。macOS 26 起它做 Xcode 的三件事：
  - 把浮层压住滚动视图的深度，减去从外面继承来的安全区，写进滚动视图自己的 `additionalSafeAreaInsets`。
  - 关掉 clip view 的自动内边距，设 `contentInsets = (safeAreaInsets.top + 8, 0, safeAreaInsets.bottom, 0)`，改的时候保持可见位置不跳。滚动视图自己的自动内边距不关，滚动条仍排在栏以内。AppKit 27.0 里 `-[NSScrollView setContentInsets:]` 只改滚动视图自己存的那份，clip view 另存一份，所以 +8 不会被覆盖；Xcode 的抓图也是这样。
  - 设 `alwaysShownPocketEdges = top|bottom`。

  它自己 KVO 滚动视图的 `safeAreaInsets`，并监听滚动视图与各浮层的 frame 变化，所以 `TabViewController` 晚一轮才设好的 28 点也跟得上。macOS 26 以前它什么都不做。测试是 `NavigatorScrollViewLayoutTests`（在 `RuntimeViewerApplicationTests` 里，共 7 条），做过变异检验：去掉 KVO，两条「外部安全区变化」的测试变红；去掉 frame 通知，三条浮层测试变红。
- **四个页面基类**：`SidebarRootViewController`（镜像层的目录页与书签页）、`SidebarRuntimeObjectViewController`（对象层的列表页与书签页）、`FindViewController`、`ReportViewController`，覆盖了两层 tab 切换器里全部带过滤栏的页面。macOS 26 起：
  - `contentInsets` 归零，不再用 `BaseViewController` 默认的上边 10 点；Find 与 Report 的 `containerViewUsingSafeArea` 改为 `false`。
  - 列表的滚动视图四边贴满页面，过滤栏仍贴底，浮在列表上。
  - 1 点分隔线隐藏，由边缘效果取代。
  - 空列表文字与「加载中 / 未加载」占位改为在安全区内居中。
- **Find 页**照 `-[IDEFindNavigator viewDidLoad]`：结果列表全高；查询区钉在 `containerView` 的安全区顶边，也就是工具栏与分段控件栏之下，它和 summary 行浮在列表上，作为 `topOverlayViews` 交给 `NavigatorScrollViewLayout`。层级改成列表最先加，这样浮层画在上面，也先接到点击。Xcode 还把 load-more 行登记为顶边容器，本仓库没有这一行。
- **过滤栏本身不用改**：AppKitPlus 的 `NSFilterControlBar` 不画背景也不描边。large 且 macOS 27 起，框与每个 item 各套一个可交互的 `NSGlassEffectView`，`NSFilterControlBarItemGroup` 的子项共用一个胶囊。几何已与 Xcode 一致：栏高 44，首个 item 离边 7，玻璃圆 28，到框 8，框从 x = 43 起。
- **macOS 15** 全部保持原来的堆叠布局。

### 验证

- App 以 `RuntimeViewer-Debug.xcworkspace`、`RuntimeViewer macOS`、Debug 编译通过：只有顶部改动时冷编 101 秒，两边合起来增量 41 秒，没有新警告，两个 workspace 的锁文件没被改写。`NavigatorScrollViewLayoutTests` 7 条全过，原始退出码为 0。
- 第一期的前提在 macOS 27.2（26B5101f）上实测成立：屏幕外窗口里 300 × 600 的滚动视图，用第一期的配置（`additionalSafeAreaInsets` 为上 80、下 44，滚动视图自动内边距开着，`alwaysShownPocketEdges = 3`），顶部 pocket 是 (0, 0, 300, 80)，底部是 (0, 556, 300, 44)，与 Xcode 抓图的 80 和 44 一致。pocket 视图本身始终 `hidden = false`、`alpha = 1`，「显不显示」只能从几何看。两条边的 `scrollPocketStyle` 默认都是 0。
- 没有运行 App 目视比对。第一期没有私有登记时，边缘效果与 Xcode 有多少差别，还没有看过。

### 第二期（待 UIFoundation 发版）

- **封装已写好、未提交**：UIFoundation 的 worktree `.worktrees/UIFoundation-ScrollPocket`（分支 `feature/scroll-pocket`，从 main `17cdd81` 切出），自成一体，可以直接 cherry-pick。
  - 声明：`UIFoundationAppleInternalObjC/include/NSScrollView_Private.h` 加了 `registerPocketContainer:onEdge:`、`unregisterPocketContainer:onEdge:`、`scrollPocketStyleOnEdge:`、`setScrollPocketStyle:onEdge:`、`_pocketForEdge:makeIfNeeded:`，都标 macOS 26。`NSView_Private.h` 加了 `_scrollPocketElementStyle`，Swift 子类可以写 `override var _scrollPocketElementStyle: Int { 2 }`。
  - Swift 封装在 `UIFoundationAppleInternal/ScrollView/NSScrollView+ScrollPocket.swift`：`NSScrollView.ScrollPocketEdge`（`.top = 0`、`.bottom = 1`）、`ScrollPocketEdges`（OptionSet），以及 `scrollView.box` 上的 `registerScrollPocketContainer(_:on:)`、`unregisterScrollPocketContainer(_:on:)`、`alwaysShownScrollPocketEdges`、`scrollPocketStyle(on:)`、`setScrollPocketStyle(_:on:)`、只读不创建的 `scrollPocket(on:)`。每个方法先查 `respondsToSelector`，方法不存在时什么都不做。
  - 27.0 导出里的 `_registeredPocketContainersOnEdge:` 在 27.2 上已经不存在，调用会抛 unrecognized selector，所以没有封装它。
  - 「Bar」样式的值有了具名常量 `NSView.barScrollPocketElementStyle`（= 2，名字照 DVT 的叫法）。
  - UIFoundation 那边的文档（路径相对 UIFoundation 仓库，在 `feature/scroll-pocket` 上）：提案 `Documentations/Evolutions/draft-scroll-view-scroll-pockets.md`（「Scroll pocket 封装：让浮在列表上的栏也有滚动边缘效果」），指南 `Documentations/ScrollPockets.md`，逆向报告 `Researchs/AppKit-NSScrollView-ScrollPocket-Internals.md`，以及它 AGENTS.md 里的「Scroll pockets (AppleInternal trait)」一节。测试是 `ScrollPocketTests`，10 条全过；AppleInternal trait 单独开、13 个 trait 全开两种构建都通过。
- **接入方式**：侧栏照 Xcode 把分段控件栏登记到顶边、过滤栏登记到底边，27 上顶边样式设 0。两个栏都返回 `NSView.barScrollPocketElementStyle`：Xcode 的分段控件栏（`IDETwoLevelChooserView`）与过滤栏（`DVTFilterExpressionControlBar`）都是 2，写法是 `@available(macOS 26.0, *) override var _scrollPocketElementStyle: Int { NSView.barScrollPocketElementStyle }`。分段控件栏现在是普通的 `NSView`，届时要换成能覆写这个属性的子类；`NSFilterControlBar` 是 AppKitPlus 的类，覆写放在页面里的子类上，或者由 AppKitPlus 自己提供。登记要拿到当前页的滚动视图，届时给页面加一个提供它的小协议。
- **阻塞（已由用户裁决）**：UIFoundation main 自 `45e493d` 起把 FrameworkToolbox 的下限抬到 0.15.0，而 RuntimeViewerCore 钉的是 `exact: "0.12.0"`。所以 UIFoundation 从 main 发出的新版本，RuntimeViewer 接不上；`USING_LOCAL_DEPENDENCIES=1` 的本地构建也同样解析不过。用户选了抬 Core：FrameworkToolbox 不再钉死版本，封装从 UIFoundation main 正常发版。

### 没有询问就采用的假设

- 列表顶部比安全区再往下 8 点，用 Xcode 的值，不沿用此前 tab view 与分段控件之间的 10 点。
- Inspector 不做浮层，因为 Xcode 的 Inspector 本来就是堆叠的。
- `BaseViewController` 默认的 `contentInsets.top = 10` 不动，堆叠的页面靠它留空隙。侧栏页面在 26 起改回 0。
- 不做 Xcode 在工具栏隐藏时加的 8 点上边距（`topMargin`），本 App 没有隐藏工具栏的入口。
- 第一期没有私有登记，两条边的 pocket 靠 `alwaysShownPocketEdges`（UIFoundation 0.38.0 已声明）保持显示。栏作为「元素」参与边缘效果的样子要到第二期才有，与 Xcode 的差别没有目视比对过。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-14 | 以 Draft 创建，直接进入 In Progress | 用户先问「我们的 TabViewController 怎么做到像 Xcode 那样」，随后要求与负责底部过滤栏的会话协商后「直接改」，按规矩为豁免档，不经审批；文档照常与代码同批落地 |
| 2026-10-14 | 照 Xcode 的结构做，不改用 split view item 附件 | 公开的附件路线挂在 split view item 上，不随侧栏的 push / pop 一起滑动，而两层 tab 切换器各有一套栏；Xcode 自己也是把栏放在导航区内部 |
| 2026-10-14 | 分两期，第一期只用已发布依赖 | 私有登记的封装要进 UIFoundation，而 UIFoundation main 要求 FrameworkToolbox ≥ 0.15.0，与 Core 钉的 0.12.0 冲突，RuntimeViewer 暂时接不上 |
| 2026-10-14 | Inspector 保持堆叠 | Xcode 抓图：`IDEUtilityAreaContentView` 从工具栏下沿开始，内容在分段控件下方 |
| 2026-10-14 | 顶部额外下移 8 点 | Xcode 的值（`IDENavigatorArea.ContentView` 布局与 `-[IDENavigator _adjustNavigatorScrollViewInsets]`） |
| 2026-10-15 | 第一期直接提交到 `next`，落地编号 0052 | 用户：「提交推送」「弄完直接提交推送就行」 |
| 2026-10-15 | 第二期走「抬 Core 的 FrameworkToolbox」：不再 `exact` 钉死，UIFoundation 从 main 发版 | 用户：「FrameworkToolbox 可以升级，不用写死，直接继续推进」 |

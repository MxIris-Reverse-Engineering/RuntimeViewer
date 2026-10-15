# 0052 - 侧栏照 Xcode 导航区布局：浮在列表上的栏与滚动边缘效果

- **状态**: Implemented
- **创建日期**: 2026-10-14
- **最后更新**: 2026-10-15
- **所属愿景**: 无
- **配套文档**: 给贡献者的规则在 `AGENTS.md` 的「Navigator pages run under their bars (macOS 26 and later)」一节。逆向证据与全部地址在本机资料卷 `/Volumes/RE/Xcode/27.2/README.md` 的「Navigator chooser and scroll pockets (2026-10-14)」一节（IDEKit 27.2 的头文件、Swift dump 与 IDA 库在同目录 `IDEKit/`，AppKit 27.0 的库是 `/Volumes/DyldSharedCaches/macOS/27.0/AppKit-20261014.i64`）

## 摘要

侧栏原来是上下堆叠的：tab 切换器的分段控件在上、页面在下，页面里又是「列表 → 1 点分隔线 → 过滤栏」。列表在两头都被截断，滚到控件底下的内容没有 macOS 26 的滚动边缘效果（内容滑到栏下面时的模糊与变暗，AppKit 内部叫 scroll pocket）。Xcode 的导航区不是这样搭的：列表全高，一直伸到工具栏底下；顶部的分段控件栏和底部的过滤栏都是浮在列表上的兄弟视图，靠安全区（safe area）让列表内容让开，滚动时从栏底下穿过，AppKit 在栏下画边缘效果。本次在 macOS 26 起照搬这套结构，macOS 15 保持堆叠。分两期：第一期只用已发布的依赖，第二期补上 Xcode 额外用的私有登记，随 UIFoundation 0.39.0 接入。

## 方案

### Xcode 的做法

- **结构**：`IDENavigatorAreaContentView` 用手算 frame 摆放三个子视图：铺满整块的导航器（`DVTReplacementView`）、紧贴工具栏下沿的分段控件栏 `IDETwoLevelChooserView`（高 28，控件左右各内缩 8），以及过滤栏。导航器的滚动视图全高。Inspector 不一样：`IDEUtilityAreaContentView` 从工具栏下沿开始，分段控件在顶部，内容从 y = 28 往下，是堆叠的。
- **让出空间**：内容视图给自己设 `additionalSafeAreaInsets.top = 28`。导航器滚动视图的 clip view 关掉自动内边距，`contentInsets = (safeAreaInsets.top + 8, 0, safeAreaInsets.bottom, 0)`，并 KVO 安全区重排。抓图里顶部安全区 80 = 工具栏 52 + 栏 28，clip view 的 bounds 原点是 −88。底部由导航器视图（`IDEExplorableNavigatorView`）直接给滚动视图设 `additionalSafeAreaInsets.bottom = 过滤栏高（44）`。
- **边缘效果**：AppKit 27.0 里，顶部 pocket 的高度是滚动视图的 `safeAreaInsets.top`，再并上登记在顶边的容器；底部 pocket 是高为**滚动视图自己的** `contentInsets.bottom` 的一条（不是 clip view 的），再并上底边的容器。27.2 上实测相同：只给 clip view 设内边距、滚动视图自己的为 0 时，底部 pocket 是 0 高；滚动视图 `contentInsets.top = 80` 而安全区为 0 时，顶部 pocket 也是 0 高。显示与否的规则是：这条边在 `alwaysShownPocketEdges` 里，或者边上登记了容器，pocket 才出现。滚动视图顶到标题栏时，窗口会自动把标题栏登记上去；底边只有 split view item 的底部附件会被自动登记。Xcode 在安装导航器时对滚动视图调用私有的 `setAlwaysShownPocketEdges:3`、`registerPocketContainer:<分段控件栏> onEdge:0`、`registerPocketContainer:<过滤栏> onEdge:1`，27 上再设 `setScrollPocketStyle:(有第二级 ? 2 : 0) onEdge:0`。分段控件栏（`IDETwoLevelChooserView`，IDEKit 27.2 `0x2A3268`）和过滤栏（`DVTFilterExpressionControlBar`，DVTUserInterfaceKit 27.2 `0xA3A38`）都覆写私有的 `_scrollPocketElementStyle` 返回 2，与 AppKit 给 split view item 附件包装视图的值相同；DVT 把这个值叫作「Bar」，见它的 `NSViewWithScrollPocketElementStyleBar`。Find 导航器把查询区、summary 行、load-more 行三个视图都登记在结果列表的顶边。
- **分段控件本身**：`.large`，选中段用强调色（`selectedSegmentBezelColor`），spring-loaded，27 上 `role = .tabs`、`clipsToBounds = false`。控件里的 `_NSCoreHostingView<AppKitSegmentedControl>` 是 AppKit 26 起自己的渲染方式，不是 Xcode 加的。

### 第一期（只用已发布的依赖）

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

### 第二期：私有登记（UIFoundation 0.39.0）

- **依赖**：UIFoundation 的下限从 0.37.0 抬到 0.39.0，它带来 scroll pocket 的封装（UIFoundation 的提案 0029「Scroll pocket 封装：让浮在列表上的栏也有滚动边缘效果」，指南 `Documentations/ScrollPockets.md`，逆向报告 `Researchs/AppKit-NSScrollView-ScrollPocket-Internals.md`）。0.39.0 要求 FrameworkToolbox ≥ 0.15.0，所以 RuntimeViewerCore 把 FrameworkToolbox 从 `exact: "0.12.0"` 改成 `from: "0.15.0"`，CLI 包的下限跟着改成 0.15.0。五份锁文件（两个 workspace、Core、Packages、CommandLine）只有 FrameworkToolbox 与 UIFoundation 两条 pin 变了；`RuntimeViewerServer.xcodeproj` 自带的那份本来就过期（`UpdatePackagesScript.sh` 不管它，XCFramework 脚本走的是 workspace），重新解析会连带十几条无关的 pin，没有动。
- **当年为什么钉死**：FrameworkToolbox 0.10.0 让它唯一的动态库产品 ObjCRuntimeToolbox 依赖 OSToolbox，Xcode 于是把 OSToolbox 和 FrameworkToolbox 也编成动态 framework，而 helper daemon 没有指向 App `Frameworks` 目录的 run path，在 dyld 阶段崩溃循环（v3.0.0-beta.2）。0.11.0 起 ObjCRuntimeToolbox 重新只依赖宏 target，0.15.0 仍是如此，由 FrameworkToolbox 自己的 `PackageTopologyGuardTests` 守着；Core 的 `Package.swift` 在这条依赖旁写了以后要查什么。Release 构建的实测见「验证」。
- **FrameworkToolbox 0.14 的一处源码不兼容**：0.14.0 起 `@FrameworkToolboxExtension` 生成的 `box` setter 会给 `self` 赋值（a2bf5cb，修 `mutating` 方法经 `.box` 调用时改动被丢掉的问题），而用在只能由类遵循的协议上时，编译器不报错、直接在 SILGen 崩溃。`RuntimeSwiftSection.swift` 里 `extension SwiftDeclaration.Definition` 正是这种情况（`Definition: AnyObject`），改成 `@FrameworkToolboxExtension(.internal, referenceSemantics: true)`；全仓库只有这一处。
- **`NavigatorScrollViewLayout` 包揽所有 pocket 调用**，`TabViewController` 不碰页面的滚动视图：
  - `topOverlayViews` 登记到顶边、`bottomOverlayViews` 登记到底边，与 Xcode 一样由页面登记自己的栏（`-[IDEFindNavigator viewDidLoad]` 0x1B42C0，`-[IDEExplorableNavigatorView viewDidMoveToWindow]` 0x76344C）。
  - 新增只登记、不计深度的 `inheritedTopOverlayViews`，给页面之外的栏用：tab 切换器的栏的 28 点已经经 `tabView.additionalSafeAreaInsets` 作为安全区传进来了。登记由布局自己记账，同一个视图只登记一次、离开时撤销——AppKit 怎么存容器没逆向过，不指望它去重。
  - `alwaysShownPocketEdges` 改用封装，仍是上下两边（3）。只在 macOS 26 上把两条边的样式设为 2；27 上 Xcode 只在分段控件有第二级时把顶边设 2，我们没有第二级，保持默认 0，底边不碰。
- **栏回答 `_scrollPocketElementStyle` = 2**（RuntimeViewerUI 新增两个类）：
  - `ScrollPocketBarView`，对应 DVT 的 `NSViewWithScrollPocketElementStyleBar`。tab 切换器的分段控件栏、Find 页的查询区与 summary 行都换成它：Xcode 27.2 的 `IDEFindNavigator.nib` 用的是 `NSViewWithScrollPocketElementStyleBar`，`IDEFindNavigatorQueryParametersController.nib` 用的是 `DVTStackViewWithScrollPocketElementStyleBar`（nib 里的类名）。
  - `NavigatorFilterControlBar`，AppKitPlus `NSFilterControlBar` 的子类，对应 `DVTFilterExpressionControlBar`。四个页面基类的过滤栏都换成它。覆写放在本仓库的子类里而不进 AppKitPlus：私有声明只从 UIFoundation 的 `NSView_Private.h` 来。
- **tab 切换器的栏经 `NavigatorTabPage` 交给页面**：`TabViewController` 在每条改变选中项的路径末尾（`selectedTabViewItemIndex` 的 setter——`setTabViewItems` 最后也走它——、`autosaveName` 的 didSet、分段控件的 action），把当前页的 `tabSwitcherOverlayViews` 设为栏、把上一页的清空；页面把它转交给布局的 `inheritedTopOverlayViews`。只认最终状态：`setTabViewItems` 中途的选中、`NSTabView` 在删掉选中项时自己退到的邻居都不算。
  - 同一时刻只有一个滚动视图登记着这个栏。AppKit 容器一侧（`-[NSView _registerWithPocket:]`）怎么记没逆向过，不依赖一个视图同时做几个滚动视图的容器；这也是 Xcode 的「安装导航器时登记」（`-[IDENavigatorArea replacementView:didInstallViewController:]`）。
  - 不靠 `tabView(_:didSelect:)`：`TabViewController` 从没给 tab view 设过 delegate，那段代码从未运行过，一旦设上，它会在程序化选中时也改写自动保存的 tab。
  - `NSTabViewItem(viewController:)` 第一次显示时才加载页面的视图，而四个页面里有三个在 `viewDidLoad` 建布局，所以页面先把值存着，建布局时再交过去。`SidebarRuntimeObjectViewController` 的布局在 `ImageLoadedView` 的 `init` 里建，一开始就在。
  - Inspector 的切换器（`.belowSegmentedControl`）不参与。

### 验证

第一期：

- App 以 `RuntimeViewer-Debug.xcworkspace`、`RuntimeViewer macOS`、Debug 编译通过：只有顶部改动时冷编 101 秒，两边合起来增量 41 秒，没有新警告，两个 workspace 的锁文件没被改写。`NavigatorScrollViewLayoutTests` 7 条全过，原始退出码为 0。
- 第一期的前提在 macOS 27.2（26B5101f）上实测成立：屏幕外窗口里 300 × 600 的滚动视图，用第一期的配置（`additionalSafeAreaInsets` 为上 80、下 44，滚动视图自动内边距开着，`alwaysShownPocketEdges = 3`），顶部 pocket 是 (0, 0, 300, 80)，底部是 (0, 556, 300, 44)，与 Xcode 抓图的 80 和 44 一致。pocket 视图本身始终 `hidden = false`、`alpha = 1`，「显不显示」只能从几何看。两条边的 `scrollPocketStyle` 默认都是 0。
- 没有运行 App 目视比对。第一期没有私有登记时，边缘效果与 Xcode 有多少差别，还没有看过。

第二期（macOS 27.2，JHs-Mac-Studio-Ultra，Xcode 27.2）：

- RuntimeViewerPackages 用远程依赖、全新 scratch 编译通过。`NavigatorScrollViewLayoutTests` 共 12 条，新增 5 条：过滤栏登记为底边容器（以及它的对照：没有栏时，去掉常显后底部 pocket 消失）、页面外的栏登记与撤销、两种栏回答 Bar、两条边的样式。全过，原始退出码 0。变异检验：去掉底边与顶边的登记，两条登记测试变红，对照测试仍绿。
- RuntimeViewerPackages 的全部测试（516 + 73 + 9 条）在新 pin 下全过，原始退出码 0；跑之前备份、跑完比对过 Debug 版的 `settings.json` 与 `AppStorage`，没有被改动。
- App 用 `RuntimeViewer-Debug.xcworkspace`、Debug 冷编通过：103 秒，0 错误，6 条警告都是原有的，锁文件没被改写。
- 用 `RuntimeViewer-Distribution.xcworkspace`、Release、`-IDEEnableNewPackagePIFBuilder=NO`（与 `ArchiveScript.sh` 相同）、只编 arm64，构建通过：201 秒，0 错误。`otool -L` 逐个查了 App 包里 `Contents/Frameworks` 之外的全部可执行文件——App 本体、`Library/LaunchServices/com.mxiris.runtimeviewer.service`（helper daemon）、`Applications/runtime-viewer-cli`、两个 XPC service、Catalyst helper 与插件、`Resources` 里的两份注入载荷、SourceEditor 桥接：只有 App 本体链接 `@rpath/ObjCRuntimeToolbox.framework`，其余都不链接任何 toolbox framework；`Contents/Frameworks` 里的 toolbox framework 只有 `ObjCRuntimeToolbox.framework`。与 v3.0.0-beta.3 修好之后的状态一致。
- 仍然没有运行 App 目视比对。登记与样式都照 Xcode 设好，但 pocket 视图始终可见、不透明，画出来是什么样只能看屏幕。

### 没有询问就采用的假设

- 列表顶部比安全区再往下 8 点，用 Xcode 的值，不沿用此前 tab view 与分段控件之间的 10 点。
- Inspector 不做浮层，因为 Xcode 的 Inspector 本来就是堆叠的。
- `BaseViewController` 默认的 `contentInsets.top = 10` 不动，堆叠的页面靠它留空隙。侧栏页面在 26 起改回 0。
- 不做 Xcode 在工具栏隐藏时加的 8 点上边距（`topMargin`），本 App 没有隐藏工具栏的入口。
- 第一期没有私有登记，两条边的 pocket 靠 `alwaysShownPocketEdges` 保持显示（UIFoundation 自 0.3.1 起就声明了它，0.37.0 的下限够用）。第二期补上登记与样式，与 Xcode 的差别没有目视比对过。
- FrameworkToolbox 写 `from: "0.15.0"`，下限取 UIFoundation 0.39.0 要求的版本，即实际编译、测试过的版本。

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
| 2026-10-15 | 第二期落地：UIFoundation 0.39.0，栏登记为 pocket 容器并回答 Bar，macOS 26 上两条边样式为 2 | 照 Xcode 做，地址见方案；所有 pocket 调用都在 `NavigatorScrollViewLayout` 里，`TabViewController` 不碰页面的滚动视图（与另一会话 runtimeviewer-04 商定） |
| 2026-10-15 | tab 切换器的栏只交给当前显示的页，换页时先撤销再登记 | AppKit 容器一侧怎么记没逆向过，不依赖一个视图同时做几个滚动视图的容器；也是 Xcode「安装导航器时登记」的语义。另一会话最初提议在 `setTabViewItems` 里交给全部页面，讨论后改为只交给当前页 |
| 2026-10-15 | Find 页的查询区与 summary 行也回答 Bar | Xcode 27.2 的 `IDEFindNavigator.nib` 与 `IDEFindNavigatorQueryParametersController.nib` 里，这两处用的就是 Bar 样式的类 |
| 2026-10-15 | `SwiftDeclaration.Definition` 的 `@FrameworkToolboxExtension` 加 `referenceSemantics: true` | FrameworkToolbox 0.14.0 起不加，编译器在 SILGen 崩溃（a2bf5cb 的提交说明里写了这个陷阱）；全仓库只有这一处 |
| 2026-10-15 | 状态改为 Implemented | 两期都已落地。不另写使用指南与实现说明：给贡献者的规则在 `AGENTS.md` 的「Navigator pages run under their bars」，实现细节在本提案。不新增术语：scroll pocket 是 AppKit 自己的名字，摘要与 `AGENTS.md` 都解释了。目视验收仍待用户 |
| 2026-10-15 | 栏高改由 `FloatingBarSafeAreaLayout`（RuntimeViewerUI）跟随栏的 frame 写入 tab view 的 safe area，不再在 `viewDidLayout` 里读 | 目视验收发现推进来的对象列表页第一行压在栏下。`viewDidLayout` 执行时 AppKit 只排好了根视图的直接子视图，栏的 frame 是上一轮的，第一轮为 0；推进来的页面只排一次版，这 28 点就一直没加上。见 [ResolvedIssues/2026-10-15-sidebar-list-starts-under-the-tab-switcher-bar.md](../ResolvedIssues/2026-10-15-sidebar-list-starts-under-the-tab-switcher-bar.md)；方案一节里「`viewDidLayout` 里把栏的实际高度写进…」是原先的做法，保留原文 |

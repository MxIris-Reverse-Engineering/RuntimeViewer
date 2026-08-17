# 0012 - 用 UIFoundation 的 NavigationController 取代 UXKit

- **状态**: In Progress
- **作者**: JH
- **日期**: 2026-08-17
- **最后更新**: 2026-08-17

## 摘要

把导航容器从 Apple 私有的 `UXKit.framework` 换成 UIFoundation 的
`NavigationController`，并把 `Base/ViewControllers.swift` 里那三个以 `UX` 开头的基类
改为直接继承 `NSViewController`。随后从 `RuntimeViewerPackages/Package.swift` 删掉
`OpenUXKit` 与 `UXKitCoordinator` 两个依赖，以及 `USING_SYSTEM_UXKIT` 这个编译开关。

## 动机

### 一、导航栏明明是隐藏的，UXKit 每次 push 还是把它重新布局一遍

这是本提案的直接起因，有实测数据。

`UXKitNavigationController.viewDidLoad()` 里写着：

```swift
isToolbarHidden = true
isNavigationBarHidden = true
interactivePopGestureRecognizer?.isEnabled = false
```

也就是说，本项目从来不用 UXKit 的导航栏、工具栏和交互式返回手势——三个能力全部关掉，
只用它的「一个 push/pop 栈 + 转场动画」。

但冷启动 `sample`（21360 样本 / 21.4 秒）显示，隐藏不等于不干活。点一个 RuntimeObject
会触发 `MainCoordinator.fanOut` 的 `.push` 分支，向内容面板和 Inspector **各 push 一次**，
两次的栈完全一样：

```
UXNavigationController.setViewControllers / pushViewController
 → _performOrEnqueueNavigationRequest → _dequeueNavigationRequest
   → _beginTransitionWithContext
     → __runAlongsideAnimations
       → UXNavigationBar._pushNavigationItem        ← 已隐藏的导航栏
         → UXBar._transitionToContainer
           → UXBar._updateTrailingViewWithItemContainer
             → NSView.layoutSubtreeIfNeeded          ← 仍然整棵子树重新布局
```

`.push` 分支主线程共 **100 个样本**（内容 43 + Inspector 57），其中约 **50 个**落在这两次
push 转场机制里，导航栏那一段每次约 10 个。**这部分开销对用户没有产生任何像素**。

（同一份采样里，SourceEditor 首开的 Metal 管线编译已由提案 0009 的预热解决，从 137 降到 0；
剩下的就是这里说的这一块，`main` 分支同样存在——`MainCoordinator.swift` 与整个 `Inspector/`
目录在两条分支上逐字节相同。）

### 二、依赖 Apple 私有框架

采样确认加载的是 `/System/Library/PrivateFrameworks/UXKit.framework`
（`com.apple.swe.UXKit 11.0 - 851.0.103`），不是 OpenUXKit。它是 Apple 内部框架，
没有兼容性承诺：`isNavigationBarHidden`、`interactivePopGestureRecognizer`、
`transitionCoordinator` 这些都是私有 API，每个 macOS 大版本都可能变。

现有代码里已经有一处为它打的版本补丁——`SidebarNavigationController` 在 macOS 26 上要
在转场期间强行把前后两个视图的背景改成 `windowBackgroundColor` 再改回来，否则会露出
错误的底色。这类补丁只会越积越多。

### 三、`USING_SYSTEM_UXKIT` 这个开关一直没有第二条路被验证

`Package.swift` 里 `usingSystemUXKit` 默认 `true`，关掉时切到 OpenUXKit（社区重写版）。
实际上只有 `true` 这一条路在用、在测。保留一个从不走的分支，等于保留一份不会被发现的坏代码。

## 提议方案

### 换成什么

UIFoundation 的 `UIFoundationAppKit/Navigation/NavigationController`（约 1800 行，
`Navigation` trait 下），据其文件头说明是从 macOS App Store 自己的导航栈移植的。
关键差异：

| | UXKit | UIFoundation |
|---|---|---|
| 栈元素类型 | `UXViewController` | `NSViewController` |
| 导航栏 / 工具栏 | 有（本项目全部隐藏） | **没有**，chrome 由宿主自己挂 |
| 子视图定位 | 内部机制 | **按 frame 定位**，禁止外部约束 |
| 交互式返回 | 手势识别器（本项目已禁用） | `allowsInteractivePop`（设 false） |
| 自定义转场 | `UXViewControllerAnimatedTransitioning` | `NavigationControllerTransitionDelegate` |
| 转场协调器 | `transitionCoordinator` | **没有对应物** |
| 来源 | Apple 私有框架 | 本人维护的开源包 |

「没有导航栏」正是动机一想要的结果：不存在的东西不会被布局。

### 改动清单

项目里 `UX` 前缀符号的全部出现（已逐个数过，不含 `.build/checkouts`）：

| 符号 | 处数 | 处理 |
|---|---|---|
| `UXKitViewController<VM>` | 27 | 基类改继承 `NSViewController`，并改名（见下） |
| `UXViewController` | 7 | → `NSViewController` |
| `UXEffectViewController<VM>` | 5 | 跟随基类，改名 |
| `UXView` | 5 | → `UIFoundationAppKit.LayerBackedView` |
| `UXKitNavigationController` | 4 | → 继承 `NavigationController` 的项目基类 |
| `UXNavigationController(Delegate)` | 4 | → `NavigationController(Delegate)` |
| `UXKit` / `UXKitCoordinator` import | 5 | 删除 |
| `UXPopoverController` | 3 | **只在注释里**，早已迁走，顺手改文字 |

外加两处包级改动：

- `RuntimeViewerPackages/Package.swift`：`uiFoundationTraits` 加 `"Navigation"`；
  删除 `OpenUXKit`、`UXKitCoordinator` 两个 `.package(...)` 与对应 `.product(...)`；
  删除 `usingSystemUXKit` 与 `USING_SYSTEM_UXKIT` define。
- `RuntimeViewerUI.swift` / `RuntimeViewerArchitectures.swift`：删掉两处
  `#if USING_SYSTEM_UXKIT` 的 `@_exported import`。

### 命名

基类名里的 `UXKit` 迁移后就是误导。改为：

- `UXKitViewController<VM>` → **`AppKitViewController<VM>`**，同时**删除现有的同名薄壳**。
  现有 `AppKitViewController<VM>` 只有 `viewModel` 与 init，没有 `contentView` / loading /
  skeleton，**当前调用点为 0**（全项目搜索仅命中自身声明），删掉不影响任何代码。
  合并之后，AppKit 侧只剩一个带 ViewModel 的基类，不必再让人分辨「要 contentView 的用哪个」。
- `UXEffectViewController<VM>` → `EffectViewController<VM>`
- `UXKitNavigationController` → `BaseNavigationController`（沿用「项目基类」的定位）

改名会碰 27 + 5 处调用点，但都是机械替换。

### CocoaCoordinator 的转场层要重写

现在 push/pop/set 是靠 `UXKitCoordinator` 提供的
`extension Transition where ViewController: UXNavigationController` 拿到的。
换掉容器后这一层失效，需要写等价的
`extension Transition where ViewController: NavigationController`，提供
`push` / `pop` / `pop(to:)` / `popToRoot` / `set`。

代码量不大（对照现有实现约 100 行），但**放哪里是个决定**：

- **A. 放进 `RuntimeViewerArchitectures`**——本仓库内解决，不用等上游发版，改起来快。
- **B. 提到 CocoaCoordinator 上游**——是本人维护的库，天然属于那里，其他项目也能用；
  代价是要发一个版本，且 `main` 分支必须等 `exact:` pin 更新后才能合。

倾向 **A 先落地、B 后搬**：先在本仓库把它跑通、跑对，稳定之后再作为独立改动提到上游。

### 有三处需要实测，不能靠读代码断定

1. **子视图定位方式变了。** UIFoundation 的 `NavigationController` 明确写着
   「子视图按 frame 定位，**不要**把子视图约束到导航控制器之外的任何东西」。
   三个面板的视图控制器是否有跨出自身的约束，必须逐个确认。已知
   `ContentSourceEditorViewController` 把编辑器视图约束到 `view.safeAreaLayoutGuide`
   ——那是**自身内部**的，不受影响；但其余面板要逐个看。

2. **子视图会被强制 `wantsLayer = true`。** 转场靠 `allowsImplicitAnimation` 赋值动画，
   参与转场的视图全部图层化。这对已经图层化的面板没影响，但要确认没有依赖非图层绘制路径的视图
   （`SourceEditorView` 自带图层，`NSVisualEffectView` 需要确认）。

3. **`transitionCoordinator` 没有对应物。** `SidebarNavigationController` 那个 macOS 26
   背景色补丁用的是 `coordinator.animate(alongsideTransition:completion:)`。UIFoundation 只有
   `willShow` / `didShow` 两个回调和 `NavigationControllerTransitionDelegate`。
   **需要先确认换掉容器后那个底色问题是否还存在**——它很可能是 UXKit 自己的问题，
   换掉就消失了，那样补丁直接删。若仍存在，用 `willShow` + `didShow` 重写。

## 替代方案考量

### 保留 UXKit，只把导航栏的开销绕过去

试过的思路：既然 `isNavigationBarHidden = true`，能不能让它别再走 `_pushNavigationItem`。
不行——那是 `_beginTransitionWithContext` 内部无条件调用的，没有导出的开关，
唯一的入口就是不要用这个容器。而且这条路不解决动机二和动机三。

### 自己写一个导航容器

代价与收益都不划算：UIFoundation 那份已经存在、有文档、有交互式返回和可替换转场，
而且是自己维护的库——遇到问题能直接改上游，不像私有框架只能打补丁绕过。

### 只换导航控制器，保留 `UXViewController` 基类

不成立。UIFoundation 的栈接受 `NSViewController`，而 `UXViewController` 是 `NSViewController`
的子类，技术上塞得进去；但那样就为了三个导航控制器继续链接整个 UXKit 私有框架，
动机二和三一条都没解决。

## 影响

### 用户可见变化

- **转场动画会变。** UXKit 的 push 与 UIFoundation 的视差（parallax）转场观感不同。
  `NavigationConfiguration` 可调时长、视差系数、遮罩色，需要调到接近现状，
  或者干脆借这次统一成 UIFoundation 的默认观感——**待定，见「未决问题」**。
- **交互式返回**：两边都关着，无变化。
- **导航栏**：本来就隐藏，无变化。`SidebarRuntimeObjectViewController` 里那句
  `self.title = title` 因此本来也没有显示效果，迁移后仍然只是个未被渲染的属性。
- 预期收益：每次选中对象少掉约 50 个样本（≈50 ms）的主线程开销，卡顿变短。
  **这是按采样推算的上界，落地后必须复测。**

### 可发现性

无新增 UI，无新增设置项。

### 数据与配置兼容

不涉及持久化数据。

### 平台与最低版本

不变（macOS 15+）。UIFoundation 的 `Navigation` trait 内部是 `#if Navigation && os(macOS)`，
只影响 macOS 目标；iOS 变体（`RuntimeViewerUsingUIKit`）不受影响。

### 发布

- 删掉两个包依赖会改动 `Package.resolved`，Debug 与 Distribution 两个 workspace 都要重新解析。
- **摆脱对 Apple 私有框架的链接**，对公证与未来 macOS 版本的稳健性都是净收益。

## 已定方向（2026-08-17）

1. **一次性换完三个面板**，不分批。中途两套容器并存的代价被判定高于风险集中暴露的代价。
2. **转场先用 UIFoundation 的默认值**，实机看过再决定要不要调
   `NavigationConfiguration`。理由：对着两套动画参数凭空猜不如看一眼。
3. **转场层先写在 `RuntimeViewerArchitectures`**，稳定后再作为独立改动搬到 CocoaCoordinator 上游。
4. **基类命名：删掉现有的 `AppKitViewController<VM>`，把 `UXKitViewController<VM>` 改名占用这个名字。**
   现有那个薄壳（只有 `viewModel` 与 init，没有 contentView / loading）**当前调用点为 0**，
   删掉不影响任何代码；改名后全项目只剩一个 AppKit 侧的 ViewModel 基类，不必再让人分辨
   「要 contentView 的用哪个」。配套：`UXEffectViewController<VM>` → `EffectViewController<VM>`，
   `UXKitNavigationController` → `BaseNavigationController`。

## 落地步骤

### 已完成

1. **`Package.swift`** —— `uiFoundationTraits` 加 `"Navigation"`；删除 `OpenUXKit` 与
   `UXKitCoordinator` 两个 `.package` 及其 `.product`；删除 `usingSystemUXKit` 与
   `USING_SYSTEM_UXKIT` define；给 `RuntimeViewerArchitectures` 加 `UIFoundation` 依赖
   （转场层要用 `NavigationController`）。
2. **两个 umbrella 模块** —— `RuntimeViewerUI.swift` / `RuntimeViewerArchitectures.swift`
   删掉 `#if USING_SYSTEM_UXKIT` 的 `@_exported import`。
3. **转场层** —— 新增
   `RuntimeViewerArchitectures/Transition+Navigation.swift`，提供 `push` / `pop` /
   `pop(to:)` / `popToRoot` / `set` 五个 CocoaCoordinator transition。
   **completion 是同步调的**：`NavigationController` 的栈 API 不收 completion，
   唯一的「落定」信号是 delegate 的 `didShow`，为它排队会和子类想用的 delegate 打架。
   completion 最终只到达 `Presentable.presented(from:)`，其默认实现为空、
   CocoaCoordinator 与本项目**都没有覆写**，所以今天没人观察得到差别。文件里记了这条前提。
4. **基类** —— `Base/ViewControllers.swift`：删掉原 `AppKitViewController<VM>` 薄壳；
   `UXKitViewController<VM>` 改名 `AppKitViewController<VM>` 并改继承 `NSViewController`；
   `contentView` 由 `UXView()` 换成 `LayerBackedView()`；
   `UXEffectViewController` → `EffectViewController`；
   `UXKitNavigationController` → `BaseNavigationController: NavigationController`，
   只留 `allowsInteractivePop = false`。
   **补回了 `loadView()`** —— 原先由 `UXViewController` 提供，`NSViewController` 会去找同名
   nib，本项目不发 nib，漏掉会让每个子类在首次访问 view 时 trap。`TabViewController`
   同理（它也直接继承 `UXViewController`）。
5. **调用点** —— 28 个文件的机械改名；两处 `as? UXView` → `as? LayerBackedView`；
   `TabViewController` 改继承 `NSViewController`。
6. **`SidebarNavigationController` 的 macOS 26 背景色补丁已删除**，理由与复查方式写在文件注释里。

### 未完成

- **A. 实机验证。** 三个面板的转场观感、`SidebarNavigationController` 那个背景色伪影是否
  真的随 UXKit 一起消失、以及是否有面板因「子视图按 frame 定位」而错位。
- **B. 复测收益。** 需要一份与提案 0009 同法的 `sample`：点一个 RuntimeObject，
  看 `MainCoordinator.fanOut` 的 `.push` 分支是否从 100 个样本降下来。
- **C. 转场层搬到 CocoaCoordinator 上游**（按已定方向第 3 条，稳定之后再做）。
- **D. `Documentations/` 里其余提到 UXKit 的文字**尚未清理。

## 决策日志

| 日期 | 事件 | 说明 |
|---|---|---|
| 2026-08-17 | Accepted → In Progress | 四个未决问题全部拍板（见「已定方向」），开始实现。 |
| 2026-08-17 | Created as Draft | 起因是提案 0009 的 SourceEditor 预热落地后复测，发现剩余卡顿与 SourceEditor 无关：`sample` 显示每次选中对象要向两个面板各 push 一次，约一半开销花在**已被隐藏的** UXKit 导航栏重新布局上。顺带解决对 Apple 私有框架 `UXKit.framework` 的依赖。 |

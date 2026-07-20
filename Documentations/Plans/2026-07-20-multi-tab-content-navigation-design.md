# 多 Tab 内容导航 — 设计与实现方案

- 状态：待实现
- 日期：2026-07-20
- 目标平台：macOS（AppKit，`RuntimeViewerUsingAppKit`）

## 背景与动机

用户反馈：当前仅靠 toolbar 的前进/后退 + 历史菜单来导航"正在查看的 runtime object"不够用。核心痛点是——**想保留当前查看位置、同时去看另一个类型时，唯一手段是 back/forward 来回跳**，无法把多个查看位置并列摆开。

现状（一次调研已确认）：

- 一个 `Document`（`NSDocument`）= 一个 `DocumentState` = 一个 `MainCoordinator` = 一个窗口。
- "正在查看的对象"由 `DocumentState.selectionStack: [RuntimeObject]` + 游标 `selectionIndex: Int` 单游标模型表达（浏览器式历史）。所有跳转（sidebar 点击、⌘-click 类型跳转、inspector relationship 点击、content 链接点击）都是往同一个栈 `.push`。
- 所有跨面板导航都经由唯一枢纽 `DocumentState.selectionRouter`（`SelectionRoute`）→ `routeSignal` → `MainCoordinator.fanOut`，再分发到 sidebar / content / inspector 三个子 coordinator。
- content 面板由 `ContentCoordinator`（root 为 `ContentNavigationController`）承载，通过复用单个 `ContentTextViewController` 并 rebind 到 `selectedRuntimeObject` 来显示，避免 push 转场闪烁。

## 方案选型（已定）

评估过三条路径：

1. **NSWindow 原生 tabbing（方案 A）** — 每个 tab 是一个完整 `Document`。被否：过重，且用户在系统设置里开"打开文稿时首选标签页"即可获得，无增量价值。
2. **窗口内轻量 tab（方案 B）** — tab 是窗口内的轻量浏览会话，共享同一 `Document` / 窗口。**已选定。**
3. tab 条控件实现方式，逐一评估：
   - 私有 `NSTabBar`：可行但脆弱。它是 NSWindow 原生 tabbing 的内部件（全系统仅 `NSWindowStackController` / `_NSFullScreenModalCollapsedTabWindow` 实例化它），delegate 有 ~15 个窗口分离语义的 required 方法要桩掉，且假定活在 titlebar / Liquid Glass 上下文；项目最低支持 macOS 15，私有 API 跨版本无兼容保证、无 fallback。**否。**
   - 自绘：可行但要手写等宽收缩 / hover 关闭 / 拖拽排序。
   - **复用 `UIFoundationAppKit.TabsControl`（KPCTabsControl 移植版）。已选定。** 公开 `open class TabsControl: NSControl`，`DataSource` / `Delegate` 驱动，自带关闭按钮、拖拽排序、双击重命名、横向滚动、状态恢复，以及 Default / Safari / Chrome 三套主题。无私有 API、跨版本无风险、项目自有依赖。

### 用户明确的两个约束

- **导航历史整个文档共享**：不是每 tab 一套独立历史，而是所有 tab 共享 `DocumentState` 的单游标历史模型。
- **tab 条在 toolbar 下方、Xcode 式**：只覆盖 content 分栏顶部（不横跨 sidebar / inspector），与截图一致。

## 核心设计：镜像式状态模型

关键决策——**不把顶层状态搬进 tab 对象，而是反过来**：`DocumentState` 现有的 `selectionStack` / `selectionIndex` / `currentImageNode` 继续作为"活动 tab"的唯一事实源、一行不动；新增的 tab 集合只保存**非活动** tab 的冻结快照。

- 一个 tab = 一个打开的 `RuntimeObject`（Xcode 里"一个打开的文件"）。活动 tab 的 `object` 恒等于 `selectedRuntimeObject`（导航时写穿）；非活动 tab 冻结。
- 切 tab 的语义 = 把该 tab 的 `object` 按浏览器式 `.push` 进共享历史 → sidebar 高亮、toolbar 历史菜单/前进后退、inspector 全部自动跟随，**现有订阅者零改动**（它们只看到"状态变了 + 一条路由"，和现在的 `.jump` / `.switchImage` 无差别）。
- tab 不携带 image（image 是 document 级共享的），因此 sidebar 在切 tab 时**完全不用动**。

### 不变量

始终维持"content / inspector 显示的对象 = `selectionStack[selectionIndex]`"。tab 层不引入第二个"当前对象"事实源。

## 分层改动清单

### 1. 依赖层 —— 启用 TabsControl trait

`TabsControl` 是 UIFoundation 的 opt-in SwiftPM trait（默认不启用）。启用后 SPM 自动定义编译条件 `-D TabsControl`，`#if TabsControl` 包裹的源码才参与编译。

- 文件：`RuntimeViewerPackages/Package.swift`
- 改动：`UIFoundationTraits`（约第 123 行）的 set 中加入 `"TabsControl"`。
  - 当前：`["AppleInternal", "FilterUI", "IDEIcons", "QuickActionBar", "NSAttributedStringBuilder"]`
  - 之后：追加 `"TabsControl"`。
- `RuntimeViewerUI` 已 `@_exported import UIFoundation`，app 侧无需新增 import。

### 2. 状态层（`RuntimeViewerApplication`）

**新文件 `DocumentTab.swift`**：

```swift
public struct DocumentTab: Hashable, Identifiable, Sendable {
    public let id: UUID              // 稳定身份，供 DifferenceKit / TabsControl 复用
    public var object: RuntimeObject?  // nil = 空 tab（显示 placeholder）
}
```

**`DocumentState.swift` 新增可观察状态**（沿用现有 `@Observed fileprivate(set)` 模式）：

```swift
@Observed public fileprivate(set) var tabs: [DocumentTab] = [DocumentTab(id: <fixed-initial>, object: nil)]
@Observed public fileprivate(set) var activeTabIndex: Int = 0
```

- 初始一个空 tab；`activeTabIndex` 指向活动 tab。
- 派生便捷属性：`activeTab: DocumentTab?`。

> 注意：`DocumentState.init()` 目前为空，且状态层禁止 `Date.now()`/随机数破坏可复现性的问题不适用（这是 UI，非 workflow）。初始 tab 的 `id` 用一个固定 sentinel 或允许 `UUID()`（UI 层无复现约束）。

**`SelectionRoute.swift` 新增 case**：

```swift
case newTab                       // 追加一个空 tab（继承当前 image），并激活
case switchTab(index: Int)        // 切到指定 tab
case closeTab(index: Int)         // 关闭指定 tab
case moveTab(from: Int, to: Int)  // 拖拽排序（Phase 2）
case openInNewTab(RuntimeObject)  // 新 tab 直接显示某对象，并激活
```

**`SelectionRouter.contextTrigger` 扩展状态机**（关键点）：

- **写穿活动 tab**：`.push` / `.selectAtRoot` / `.backward` / `.forward` / `.jump` / `.pop` 等改变 `selectedRuntimeObject` 的路由，在应用完毕后同步把 `tabs[activeTabIndex].object = selectedRuntimeObject`。这样活动 tab 标题实时跟随导航。
- `.newTab`：`tabs.append(DocumentTab(object: nil))`；`activeTabIndex = tabs.count - 1`；清空共享历史（`selectionStack = []`, `selectionIndex = -1`）以显示 placeholder。保留 `currentImageNode`（image 共享）。
- `.openInNewTab(object)`：`tabs.append(DocumentTab(object: object))`；`activeTabIndex = tabs.count - 1`；把共享历史重置为 `[object]`（等价 `.selectAtRoot` 效果），令 content/inspector 立即显示该对象。
- `.switchTab(index)`：`guard index != activeTabIndex`；`activeTabIndex = index`；按目标 tab 的 `object` 恢复共享历史——非 nil 时重置 `selectionStack = [object]`、`selectionIndex = 0`（单条历史即可，够用；如需保留每 tab 的多级历史属于后续增强，见"未来增强"）；nil 时清空历史显示 placeholder。
- `.closeTab(index)`：从 `tabs` 移除；若关的是活动 tab，激活右邻（无右邻取左邻），并按新活动 tab 恢复历史；关闭最后一个 tab 由菜单层拦截为关窗口，router 内 `guard tabs.count > 1`。
- `.moveTab(from:to:)`：数组内移动，维护 `activeTabIndex` 跟随。

> 所有新 case 同样在末尾 `routeRelay.accept(route)`，保持"先应用状态、再发射路由"的既有契约。

### 3. `MainCoordinator.fanOut` 扩展

给新路由加分支，复用 content/inspector 既有词汇（`.back` / `.next` / `.root` / `.placeholder`），sidebar 不参与：

- `.newTab` → content/inspector `.placeholder`（image 不变，sidebar 不动，高亮随空栈自动清除）。
- `.openInNewTab(object)` → content `.root(object)` + inspector `.root(.object(object))`（同 `.selectAtRoot` 分支）。
- `.switchTab` / 关闭了活动 tab 的 `.closeTab`：按新的 `selectedRuntimeObject` 有无 → content/inspector `.back`（有）或 `.placeholder`（无）。
- `.moveTab` → 无面板影响（仅 tab 条重排），不触发 content/inspector 路由。

### 4. UI 层（`RuntimeViewerUsingAppKit`）

**挂载策略：`NSTitlebarAccessoryViewController`（Safari 式，全宽，toolbar 下方）**

tab 条作为窗口的 titlebar accessory 挂在 toolbar 下方、横跨整窗宽度（非仅 content 分栏）。这与 `MainToolbarController` 同构——都是 `MainWindowController` 持有、由 `MainViewModel.Output` 驱动的窗口 chrome，无需自己的 ViewModel、不触碰 `ContentCoordinator` / split view 装配。

- 新建 `TabBarAccessoryController: NSTitlebarAccessoryViewController`（`Main/`）：`layoutAttribute = .bottom`，`view` 承载 `TabsControl`（`DefaultStyle(tabButtonWidth: .full)`，等宽带图标）+ 尾部 "+" 按钮。自身充当 `TabsControl` 的 `DataSource` / `Delegate`（命令式 `reloadTabs()` / `selectItemAtIndex(_:)` 由 snapshot 驱动，`isApplyingSnapshot` 标志防选中回环）。是"哑视图"，无业务逻辑。
  - 对外暴露 `tabSelectedRelay` / `tabClosedRelay` / `newTabClicked`（Signal）与 `applySnapshot(_:)`。
  - 单 tab 时用 accessory 自带的 `isHidden = true` 收起整条，UI 与现状一致（无感默认开启）。
- `MainWindowController`：持有 `tabBarAccessoryController`，`windowDidLoad` 里 `contentWindow.addTitlebarAccessoryViewController(...)`；`setupBindings(for: MainViewModel)` 里把 accessory 的三个信号接入 `MainViewModel.Input`，并用 `output.tabBarSnapshot` 驱动 `applySnapshot`、`output.isTabBarHidden` 驱动 `isHidden`。
- `MainCoordinator` / `ContentCoordinator` / split view **完全不改**。

**`MainViewModel` 承载 tab 业务逻辑**（tab 条是窗口级 chrome，与 toolbar 标题/历史同源，故并入 MainViewModel 而非独立 VM）：

- Input 增 `tabSelected: Signal<Int>` / `tabClosed: Signal<Int>` / `newTabClicked: Signal<Void>`，分别 trigger `.switchTab` / `.closeTab` / `.newTab`。
- Output 增 `tabBarSnapshot: Driver<TabBarSnapshot>`（由 `combineLatest($tabs, $activeTabIndex)` 构建）与 `isTabBarHidden: Driver<Bool>`（`items.count <= 1`）。
- `didReorderItems → .moveTab`（Phase 2，`canReorderItem` 暂返回 false）。

**`TabBarSnapshot.swift`**（`RuntimeViewerApplication/Content/`）：不可变投影，`TabBarItem { title, kind }`（图标 kind 由 VC 侧 `RuntimeObjectIcon` 解析，VM 保持平台无关）。

**`TabMenuController.swift`**（新文件，`App/`，遵循 `DebugMenuController` 模式 + `@Dependency` 注册）：

- 注入 File / Window 菜单项，走 responder chain 落到 `MainWindowController` → `selectionRouter`：
  - New Tab ⌘T → `.newTab`
  - Close Tab ⌘W（多 tab 时）/ Close Window ⌘⇧W；单 tab 时 ⌘W 还原为 Close（menu validation 按 key window 的 tab 数动态切换）
  - Show Next Tab ⌃Tab / Show Previous Tab ⌃⇧Tab → `.switchTab`
- 遵循 AppDelegate Convention：AppDelegate 仅 `tabMenuController.install()` 一行。

### 5. 痛点交互 —— Open in New Tab（Phase 2）

真正解决"保留位置、同时看别的类型"的关键入口，全部只是 `selectionRouter.trigger(.openInNewTab(object))`（route 枢纽在 package 内，无需 app 层桥接）：

- Content 类型链接：`⌘⇧-click` = Open in New Tab（现有 `⌘-click` 原地跳转不变，对齐 Safari 语义）；右键菜单 "Jump to Definition" 旁加 "Open in New Tab"。
- Sidebar 行右键菜单加 "Open in New Tab"。
- Inspector relationships 右键（可选，随 Phase 2）。

## 分期

| 阶段 | 内容 | 涉及文件（约） |
|---|---|---|
| Phase 1（核心） | trait 开启；`DocumentTab` + `DocumentState` tab 状态；`SelectionRoute` 新 case + router 状态机；`fanOut` 扩展；`ContentContainerViewController` + VM 接 `TabsControl`；`TabMenuController` 快捷键；单 tab 自动隐藏 | Package.swift、DocumentTab.swift、DocumentState.swift、SelectionRoute.swift、MainCoordinator.swift、ContentContainerViewController.swift、ContentContainerViewModel.swift、TabBarSnapshot.swift、TabMenuController.swift、AppDelegate.swift |
| Phase 2（交互） | Open in New Tab 三处入口；Duplicate Tab；拖拽排序 / 重命名接 delegate（TabsControl 自带） | ContentTextViewModel/Controller、SidebarRuntimeObjectViewModel、右键菜单处 |
| Phase 3（打磨，可选） | ⌘1…⌘9 直达；Settings 里 tab 条开关；每 tab 独立多级历史 | Settings、DocumentState |

## 关键取舍与风险

- **每 tab 独立多级历史**：本方案首版每个非活动 tab 只冻结单个 `object`，切回时重置为单条历史。若用户需要"每个 tab 各自的完整 back/forward 栈"，属 Phase 3 增强——届时 `DocumentTab` 扩为持有 `{stack, index}`，切 tab 时整体换入换出，`fanOut` 逻辑不变。首版单 object 已解决核心痛点。
- **`TabsControl` 主题**：先用 `SafariStyle`（最贴近截图与 Xcode 观感），落地后可随时切 `ChromeStyle` / `DefaultStyle` 或调参。
- **engine 归属**：所有 tab 共享 document 级 engine（`switchEngine` 重置所有 tab 为单个空 tab），`backgroundIndexingCoordinator` 零改动。每 tab 独立 engine 不在本方案范围。
- **挂载不破坏 content**：`ContentCoordinator` 及其 `ContentNavigationController` 转场逻辑 100% 保留；tab 条通过 `Transition.embed` 包在外层容器，`fanOut` 对 content 的调用不变。

## 实现说明与相对本设计的偏差（Phase 1）

落地时相对上文有以下几处调整，记录备查：

1. **`TabsControl` trait 需要 UIFoundation ≥ 0.13.0**：`TabsControl` trait 在 UIFoundation **0.13.0** 才引入。三个 workspace 原本 pin 的是 0.11.0（无该 trait）。Debug 构建已把 `RuntimeViewer-Debug.xcworkspace/xcshareddata/swiftpm/Package.resolved` 的 UIFoundation 升到 0.13.0（commit `8cd36fb2aa1dac8dfa714c5868aa4c9a6aac35d2`）。**发布构建前，`RuntimeViewer.xcworkspace` 与 `RuntimeViewer-Distribution.xcworkspace` 的 UIFoundation pin 也需同步升到 0.13.0**，否则 release 构建会因缺少该 trait 而解析失败。`RuntimeViewerPackages/Package.resolved` 已是 0.13.0。

2. **挂载最终定为 `NSTitlebarAccessoryViewController`（全宽，toolbar 下方）**：初版曾用「容器 coordinator + `Transition.embed` 把 tab 条嵌进 content 分栏」，后按用户要求改为 titlebar accessory——tab 条横跨整窗、Safari 式，与 `MainToolbarController` 同构（`MainWindowController` 持有、`MainViewModel` 驱动）。`MainCoordinator` / `ContentCoordinator` / split view 全部不改，比容器方案更简单。`ContentContainer*` 四个文件（Route / VM / VC / Coordinator）已删除。

3. **`TabBarSnapshot` 由 `MainViewModel` 构建**（与本设计原意一致）：tab 条现为窗口级 chrome，snapshot 与输入处理并入 `MainViewModel`（Input 加三个 tab 信号、Output 加 `tabBarSnapshot` / `isTabBarHidden`）。`TabBarItem` 只携带 `title` + `kind`，图标由 `TabBarAccessoryController` 侧 `RuntimeObjectIcon` 解析，保持 VM 平台无关。

4. **`.switchImage` 重置 tabs**：tab 持有的对象属于当前 image，切换 image 视为全新浏览上下文，故 `.switchImage` 像 `.switchEngine` 一样把 tabs 收敛为单个空 tab。跨 image 保留 tab（每 tab 记住其 image）留作后续增强。

5. **TabsControl 主题定为 `DefaultStyle(tabButtonWidth: .full)`**：等宽填充 + 带类型图标 + 左侧关闭按钮，贴近截图里的 Xcode 编辑器 tab（`SafariStyle` 强制无图标，不合适）。

6. **快捷键**：New Tab ⌘T；Close Tab ⌘W（单 tab 时回退为关窗口）；Close Window ⌘⇧W（把标准「Close」项改键并改名）；Show Next/Previous Tab ⌘⇧] / ⌘⇧[（Xcode 式）。动作实现在 `MainWindowController`，经 responder chain 到达 key 窗口。

7. **单 tab 自动隐藏 tab 条**：`isTabBarHidden` 由 `tabs.count <= 1` 驱动，隐藏时高度约束归零。UI 与现状一致，等于功能默认「无感开启」；⌘T / 右键 Open in New Tab（Phase 2）是入口。

## 文档维护

- 本设计文档：`Documentations/Plans/2026-07-20-multi-tab-content-navigation-design.md`（本文件）。
- 实现完成后按需更新项目 `CLAUDE.md`（若引入新约定，如 tab 状态模型、TabsControl 使用规范）。

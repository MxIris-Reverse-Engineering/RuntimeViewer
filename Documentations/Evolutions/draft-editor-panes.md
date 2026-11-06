# Draft - 编辑器分栏：照 Xcode 把内容区分成多个编辑器窗格

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-06
- **最后更新**: 2026-11-06
- **所属愿景**: 无（[《自建代码视图引擎》](../Visions/CodeViewEngine.md)只管文本怎么显示，窗口里摆几个内容区不在它的范围内）
- **关联提案**: [多 Tab 内容导航设计](../Plans/2026-07-20-multi-tab-content-navigation-design.md)（本提案改掉它的两条约定：整窗一条标签栏、全文档共用一条历史）、[0021](0021-runtime-object-identity.md)（历史条目按身份比较、按内容替换）、[0022](0022-reveal-in-sidebar-navigator.md)、[0029](0029-find-navigator.md)（Find 结果 ⌥-点击开新标签）、[0048](0048-routes-carry-no-views.md)
- **实现分支 / PR**: `feature/editor-panes`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

内容区照 Xcode 27.2 的 editor pane 分成多个**分栏**。File 菜单和工具栏新增的「加一栏」菜单可以在焦点栏的右侧或下方再开一栏，行列最多嵌套两层，规则照 Xcode。每一栏有自己的标签页，每个标签有自己的前进/后退历史；同一时刻只有一栏是**焦点栏**，侧栏的点击、Inspector、工具栏的标题与前进后退、MCP 报告的「当前类型」都跟着它。工具栏下方那条横跨整窗的标签栏取消，标签栏挪进各栏顶部，有两栏以上时每栏都显示。两处既有行为随之改变：切换镜像不再清空已打开的标签和历史；侧栏与 Find 的 ⌥-点击开新标签、⇧⌥-点击开到下一栏，照 Xcode 的默认。第一批只做核心，最大化单栏（Focus Editor Pane）、⌘J 选栏浮层、在分栏之间拖动标签留到以后。

## 动机

**内容区只有一个，两个类型没法同时看。** `DocumentState.selectedRuntimeObject` 在注释里就写明是「显示层唯一的事实源」（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift:169-175`），`MainCoordinator` 只有一个 `ContentCoordinator`（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift:18`），`fanOut` 把每条路由都发给它（同文件 `:187-274`）。7 月加的标签页解决了「保留当前位置去看别的」，没有解决「同时看」：对照 NSView 和 UIView、一个类和它遵循的协议、同一个类的 Objective-C 头文件和 Swift 接口，都只能在标签之间来回切。

**跨镜像对照现在根本做不到。** 在侧栏切换镜像（或退回镜像列表）会把所有标签清成一个空标签、清空历史（`DocumentState.swift:439-448`，注释称之为「全新的浏览上下文」）。而跨镜像对照——AppKit 对 UIKit、一个框架对它的私有实现框架——恰恰是并排看最常见的用途。分栏如果沿用这条规则，切一次镜像所有分栏就都空了。

用户提出要 Xcode 那样的编辑器分栏。

## 前期调研

### 现状代码怎么走的

- **导航状态**（`DocumentState.swift`）：`selectionStack` / `selectionIndex` 是全文档共用的一条历史（`:136-167`）；`selectedRuntimeObject` 是正在显示的对象（`:169-175`）；`tabs` / `activeTabIndex` 是标签，活动标签的对象由路由器写穿成 `selectedRuntimeObject`（`:192-207`、`:625-642`）。`cursorMember` 是内容区插入点所在的成员，Inspector 的 References 页和 Find Call Hierarchy 跟着它（`:177-190`）。
- **路由**（`SelectionRoute.swift:72-92`）：所有改变上面状态的操作都是 `SelectionRoute`，由 `SelectionRouter` 先改状态、再发出路由（`DocumentState.swift:419-556`）。标签路由用下标定位标签（`switchTab(index:)`、`closeTab(index:)`、`moveTab(from:to:)`）。`.pop` 与 `.clear` 在整个仓库里没有调用方。
- **分发**（`MainCoordinator.fanOut`）：把路由翻译成内容区与 Inspector 的 `.root` / `.next` / `.back` / `.placeholder`。`ContentCoordinator` 和 `InspectorCoordinator` 的 `.back` 都直接读 `documentState.selectedRuntimeObject`（`ContentCoordinator.swift:94-100`、`InspectorCoordinator.swift:71-76`）。
- **标签栏**：`TabBarAccessoryController` 是窗口的 titlebar accessory，横跨整窗（`MainWindowController.swift:73`），只有一个标签时隐藏；`MainViewModel` 收它的点击、产出快照（`MainViewModel.swift:654-682`）；标签动作在 `MainWindowController.swift:343-372`；`TabMenuController` 往 File 菜单插 New Tab ⌘T、Close Tab ⌘W，把 Close Window 改成 ⇧⌘W，往 Window 菜单插 Show Next/Previous Tab ⇧⌘] / ⇧⌘[。
- **跟着 `selectedRuntimeObject` 走的地方**：侧栏高亮（`SidebarRuntimeObjectListViewModel.swift:579`）、工具栏标题与 Save / Share（`MainViewModel.swift:435-466`、`:512-539`、`:709-713`）、前进后退与历史菜单（`MainViewModel.swift:715-748`）、Reveal in Sidebar Navigator（`DocumentState.isSelectedRuntimeObjectInCurrentImage`）、交叉引用命令（`FindCrossReferences.swift:378-382`）、MCP 的当前类型（`AppMCPBridgeDocumentProvider.swift:35`）。
- **打开对象的入口与修饰键**：侧栏点击 `.push`、右键 Open in New Tab（`SidebarRuntimeObjectViewModel.swift:310-321`）；内容区 ⌘-点击原地跳，⇧⌘ / ⌥⌘-点击开新标签（`ContentSourceEditorViewController.swift:292-299`，`NSTextView` 那一版相同）；Find 结果 ⌥-点击开新标签（`FindResultsOutline.swift:95`，提案 0029 §4），落到 `FindCrossReferenceNavigation.open(_:highlighting:inNewTab:in:)` 的四种路由（`FindCrossReferences.swift:395-405`）；Inspector 的关系、层级、特化列表点击 `.push`。
- **不跨启动恢复**：`Document` 没有任何 restorable state，标签与历史本来就不跨启动保存。
- **工具栏**：`allowsUserCustomization = false`（`MainToolbarController.swift:239`），项目只来自 `defaultItemIdentifiers`（`:281-306`），用户没有自定义过的工具栏需要迁移。
- **内容区最小宽度** 300 点（`MainSplitViewController.swift:24`）。

### Xcode 27.2（27B52）怎么做的

逆向 IDEKit（UUID 443917F3-EEF8-3ED5-AB2F-30D51C54231C），完整记录与地址在 `/Volumes/RE/Xcode/27.2-27B52/README.md` 的「Editor panes」一节（只在公司那台 Mac 的 RE 卷上）。命令、快捷键与菜单位置取自 `IDEKit.xcplugindata`。

- **模型**：`IDEEditorArea` 持有一个根 `IDEEditorMultipleSplit`；split 的子项是窗格（`IDEEditorAreaSplit`）或子 split。每个窗格有自己的标签栏（`tabViewController`、`documentTabBar`）。新窗口是左右排（`-[IDEEditorArea loadView]` 0xFB7A0）。
- **最多两层**：只有根能把窗格包进一个方向相反的子 split（0x13BA60 断言 `parent == nil`），子 split 里只放窗格。
- **新建窗格**（`_newEditorAreaSplitWithLayout:sender:` 0x1085BC），P 为来源窗格：方向与 P 所在 split 相同 → 插在 P 后面；方向不同且全区只有一个窗格 → 先把根转向再插；方向不同、P 在根里 → 把 P 包进一个新子 split [P, 新]；方向不同、P 在子 split 里 → 新窗格插进根、放在整个子 split 后面。新窗格随即取得焦点。
- **数量与尺寸**：不设上限（`canCreateAdditionalEditorAreaSplitsAtIndex:layout:` 0x13BCD4 恒为 YES）。新建后整棵树（插在子 split 里时只是那个子 split）重新均分（`resetEditorSizes` 0x13C6BC → `equalizePaneSizes` 0x148E1C），Reset Editor Sizes 做同一件事。拖分隔线到下一项的最小尺寸就停，不挤别的窗格（0x13E454）。
- **关闭**：子 split 只剩一个窗格时折叠回根（0x1023B8、0x13B7DC）。只剩一个窗格时 Close Editor Pane 禁用（0x102B2C）。关掉活跃窗格后，它后面的兄弟成为活跃窗格，没有就取前面的（0x104688）。⌘W 依次尝试关标签、关窗格、关窗口（0x3B9330 / 0x3B9544）。
- **Change Editor Orientation** 是转置：结构不变、尺寸不重置（0x1001DC）。
- **新窗格显示什么**：来源窗格当前标签的那个文档，只这一项，不带前进后退（0x13D0E0）；新标签是空白的起始页（0x14ECDC）。
- **点击打开在哪**（四个设置键的默认值，0x14F160、表 0xBEBDF0）：点击 → 焦点窗格；⌥ → 焦点窗格的新标签；⇧⌥ → 下一个窗格，只有一个时在它后面同方向新建一个（0x14A8F0）；双击同点击。Open in… ⌥⌘, 走 ⌥ 那一档，只有把 ⌥ 设成 Ask 才弹选择浮层。
- **历史**：每个窗格一份历史栈，按标签标识过滤出各标签自己的前进后退（0x113E04 → 0x717A70）；用户看到的就是每个标签各走各的。前进后退命令作用于活跃窗格。
- **焦点**：first responder 进入窗格（0x114FC4）、`takeFocus`（0x130438）、点它的标签（0x720AD8）都让它成为活跃窗格；活跃窗格的内容视图 `dvt_activeState` 为 1，其余为 2（0x106BB0）。Move Focus to Next / Previous Editor Pane 按树的深度优先顺序循环（0x3B60B0）。
- **标签栏**：所有窗格共用一个开关——设置 `IDEAlwaysShowEditorTabBar` 打开（默认 NO），或任一窗格有两个以上标签，就每个窗格都显示。窗格自己的按钮（加窗格、聚焦、前进后退）默认不放在窗格栏上，交给窗口工具栏（`IDEShowAllEditorBarControls` 默认 NO，0xFC780）；窗格栏上只留两栏以上时的关闭按钮。默认工具栏里 `CustomToolbarItem.AddEditor` 排在编辑区那一段的末尾，后面只剩 EditorOptions、EditorMode 两项，再往后是 Inspector 分隔线；它的菜单 `MenuDefinition.EditorContext.AddEditor` 是 Tab、分隔线、Editor Pane On Right、Editor Pane Below。
- **命令**：

  | 菜单 | 标题 | 快捷键 | selector |
  |------|------|--------|----------|
  | File ▸ New | Tab | ⌘T | `newTab:` |
  | File ▸ New | Editor Pane On Right | ⌃⌘T | `newEditorAreaSplitOnRight:` |
  | File ▸ New | Editor Pane Below | ⌃⌥⌘T | `newEditorAreaSplitBelow:` |
  | File | Close Tab, Editor Pane, Window Tab, or Window | ⌘W | `dvt_closeActiveEditorTab:` |
  | File | Close Editor Pane | ⌃⇧⌘W | `_closeActiveEditor:` |
  | File | Close Other Editor Panes | ⌃⌥⇧⌘W | `closeOtherEditors:` |
  | Navigate | Move Focus to Next Editor Pane | ⌃` | `moveKeyboardFocusToNextEditor:` |
  | Navigate | Move Focus to Previous Editor Pane | ⌃⇧` | `moveKeyboardFocusToPreviousEditor:` |
  | Navigate | Move Focus to Editor Pane… | ⌘J | `moveFocusToEditor:` |
  | Navigate | Show Previous Tab / Show Next Tab | ⇧⌘{ / ⇧⌘} | `_showPreviousEditorTab:` / `_showNextEditorTab:` |
  | View ▸ Editor | Focus Editor Pane | ⌃⇧⌘↩ | `_toggleMaximizeEditor:` |
  | View | Change Editor Orientation | 无 | `toggleEditorOrientation:` |
  | View | Reset Editor Sizes | 无 | `resetEditorSizes:` |

- **最大化（Focus Editor Pane）**：不是隐藏，而是记下整棵树后真的关掉其他窗格，取消时按记录重建（0x103CC0 / 0x102F30）。本提案不做。

### 依赖是否已具备能力

- UIFoundation 的 `TabBar`（现在整窗标签栏用的控件）支持栏内拖动排序，不支持跨栏拖动；没有「所在窗格不是焦点」的外观。焦点栏与其余栏要画得不同，要么在 RuntimeViewer 这边给两种状态各配一套 style，要么在 UIFoundation 加接口、发版、抬 pin——实现第 6 步逆向完 Xcode 的样子再定。
- `RuntimeViewerArchitectures` 的 coordinator 可以把子 coordinator 的根视图控制器嵌进任意容器，内容区的 `ContentCoordinator` 不需要改成别的形态就能一栏一个。

### 要实际运行才知道、或 Xcode 里没有对应物的

- Xcode 关掉一个窗格后空出的空间给谁，代码里没写，交给 `NSSplitView` 默认处理；本提案定为与 Xcode 新建时一样：所在 split 重新均分。
- `dvt_activeState` 到底改了哪些视图的外观、点跳转栏算不算让窗格取得焦点、⇧⌥ 开到下一栏后焦点是否跟过去：实现时实际运行 Xcode 核对。
- 一个窗格最后一个标签被关掉后显示什么：Xcode 没定论；本提案定为关掉这一栏（只剩这一栏时关窗口）。
- RuntimeViewer 没有跳转栏（Xcode 每栏顶部的文件路径条），Xcode 靠它标出焦点窗格、放关闭按钮。这是本提案在标签栏显示规则上不照搬 Xcode 的原因（见决策日志）。

## 提议方案

### 用户看到的

**布局。** 新窗口只有一栏，看起来和现在一样（只有一个标签时没有标签栏）。File ▸ New Editor Pane On Right（⌃⌘T）/ Below（⌃⌥⌘T），或工具栏「加一栏」按钮的菜单，从焦点栏旁边开一栏。新的一栏显示焦点栏当前的对象（历史只有这一条），焦点移过去。行列怎么插、何时转向、何时包成子 split、何时折叠，全部照上面的 Xcode 规则：左右排的两栏里对右边那栏选 Below，得到「左一栏、右边上下两栏」；最多两层；栏数不设上限。新建或关闭后所在 split 重新均分；拖动的分隔线只在下一次增删前保留。

**标签。** 每一栏有自己的标签，⌘T 在焦点栏开一个空白标签。标签栏在各栏顶部：只有一栏时和现在一样，两个以上标签才显示；有两栏以上时每一栏都显示，只有一个标签也显示，焦点栏的画成活跃样式，左端有关闭这一栏的 ×。标签栏不再带「+」，新标签用 ⌘T 或工具栏菜单里的 Tab。

**历史。** 每个标签记自己看过的对象。工具栏的前进/后退和长按出的历史菜单，作用于焦点栏的当前标签；切标签、切分栏，历史跟着换。新标签从空历史开始。

**焦点。** 点一栏的内容或它的标签，这一栏就成为焦点栏（键盘焦点进入哪一栏，哪一栏就是焦点栏）。Navigate ▸ Move Focus to Next / Previous Editor Pane（⌃` / ⌃⇧`）按从左到右、从上到下的顺序循环切换。

**打开对象。** 在哪打开，按修饰键分三档（`SelectionRoute.Destination`）：

| 入口 | 焦点栏当前标签 | 焦点栏新标签 | 下一栏 |
|------|----------------|--------------|--------|
| 侧栏对象列表 | 点击 | ⌥-点击（新增），右键 Open in New Tab | ⇧⌥-点击（新增），右键 Open in Next Editor Pane（新增） |
| 内容区的类型链接 | ⌘-点击 | ⌥⌘-点击、⇧⌘-点击（都是现有的），右键 Open in New Tab | ⇧⌥⌘-点击（新增），右键 Open in Next Editor Pane（新增） |
| Find 导航结果、Inspector 的 References 页 | 点击 | ⌥-点击（现有） | ⇧⌥-点击（新增） |
| Inspector 的关系、层级、特化列表 | 点击 | — | — |

「下一栏」：只有一栏时在它旁边（沿根的方向）新开一栏；有多栏时是焦点栏在上面那个顺序里的下一栏，到头绕回第一栏。打开后焦点到对象所在的那一栏。

**关闭。** ⌘W：焦点栏有两个以上标签时关当前标签；否则有两栏以上时关这一栏；否则关窗口。点某一栏最后一个标签的 ×（只有两栏以上时才看得到）也是关这一栏。File ▸ Close Editor Pane（⌃⇧⌘W）关焦点栏，Close Other Editor Panes（⌃⌥⇧⌘W）只留焦点栏，两者都在只剩一栏时置灰。关掉焦点栏后，焦点给它后面的兄弟，没有就给前面的。

**跟着焦点栏走的**：侧栏的高亮（对象属于侧栏当前镜像时）、Inspector、工具栏的副标题、Save 与 Share、前进后退、Reveal in Sidebar Navigator、Find Call Hierarchy 等交叉引用命令、MCP 报告的当前类型。

**切换镜像与引擎。** 在侧栏切换镜像或退回镜像列表，所有分栏、标签、历史都不动，别的镜像的对象照样开着。切换引擎（以及引擎重启时文档重新开始）回到一栏、一个空白标签。

**命令与快捷键**：

| 位置 | 标题 | 快捷键 | 何时可用 |
|------|------|--------|----------|
| File | New Tab（现有） | ⌘T | 文档窗口 |
| File | New Editor Pane On Right | ⌃⌘T | 文档窗口 |
| File | New Editor Pane Below | ⌃⌥⌘T | 文档窗口 |
| File | Close Tab（现有，行为见「关闭」） | ⌘W | 文档窗口 |
| File | Close Editor Pane | ⌃⇧⌘W | 两栏以上 |
| File | Close Other Editor Panes | ⌃⌥⇧⌘W | 两栏以上 |
| File | Close Window（现有） | ⇧⌘W | 任何窗口 |
| Navigate | Move Focus to Next Editor Pane | ⌃` | 两栏以上 |
| Navigate | Move Focus to Previous Editor Pane | ⌃⇧` | 两栏以上 |
| Navigate | Show Previous Tab（从 Window 菜单挪来） | ⇧⌘[ | 焦点栏两个以上标签 |
| Navigate | Show Next Tab（从 Window 菜单挪来） | ⇧⌘] | 焦点栏两个以上标签 |
| View | Change Editor Orientation | 无 | 两栏以上 |
| View | Reset Editor Sizes | 无 | 两栏以上 |
| 工具栏 | 加一栏（菜单：Tab、Editor Pane On Right、Editor Pane Below） | 菜单里不显示快捷键 | 文档窗口 |

RuntimeViewer 的 File 菜单没有 New 子菜单，所以 Xcode 子菜单里的「Editor Pane On Right」在这里写成「New Editor Pane On Right」，与现有的 New Tab 并列。工具栏按钮放在 MCP 状态按钮之后、Inspector 分隔线之前：Xcode 27.2 默认工具栏里 AddEditor 之后只有 RuntimeViewer 没有的 EditorOptions、EditorMode，所以这就是同一个位置；它的图标与标签照 Xcode 的 `CustomToolbarItem.AddEditor`，实现时逆向。⌘W 菜单项的标题暂保持 Close Tab，Xcode 的标题是否随状态变化，实现时核对。

### 非目标

- 最大化单栏（View ▸ Editor ▸ Focus Editor Pane ⌃⇧⌘↩）。
- Move Focus to Editor Pane…（⌘J）的选栏浮层，以及 Open in…（⌥⌘,）与把 ⌥ 设成 Ask 时的选择浮层。
- 在分栏之间拖动标签；栏内拖动排序也维持现状（关闭）。
- View ▸ Show Editor Tab Bar 开关、Close Other Tabs、Duplicate Tab、固定标签（pin）。
- 跳转栏（每栏顶部的路径条）。
- 分栏布局、标签、历史跨启动保存；Xcode 的 assistant editor。
- Inspector 的关系、层级、特化列表认修饰键。
- iOS 版：`RuntimeViewerUsingUIKit` 只有一栏，只做随类型改名的编译修改。

## 详细设计

### 状态模型（`RuntimeViewerApplication`）

新文件放在 `RuntimeViewerApplication/EditorArea/` 下，都是值类型；可变方法 `internal`，只有路由器调用，测试经 `@testable import` 直接调。

```swift
/// Where the editor area puts a new pane, relative to the pane it is made from.
public enum EditorPanePlacement: Hashable, Sendable {
    case onRight
    case below
}

/// How the panes of one split sit next to each other.
public enum EditorPaneOrientation: Hashable, Sendable {
    /// Side by side, divided by vertical lines.
    case sideBySide
    /// On top of each other, divided by horizontal lines.
    case stacked

    public var opposite: EditorPaneOrientation { get }
}

/// How the editor area arranges its panes, by Xcode's rules: a root split whose items are panes or
/// child splits running across it. A child split holds panes only, at least two of them, so the
/// arrangement never goes deeper than two levels.
public struct EditorLayout: Hashable, Sendable {
    public enum Item: Hashable, Sendable {
        case pane(EditorPane.ID)
        /// Panes arranged in `orientation.opposite`; never fewer than two.
        case split([EditorPane.ID])
    }

    public private(set) var orientation: EditorPaneOrientation
    public private(set) var items: [Item]

    /// One pane, side by side — how a window starts.
    public init(pane paneID: EditorPane.ID)

    /// Every pane depth first: the order focus moves in.
    public var paneIDs: [EditorPane.ID] { get }

    /// The pane after `paneID` in `paneIDs`, wrapping around to the first.
    public func paneID(after paneID: EditorPane.ID) -> EditorPane.ID
    public func paneID(before paneID: EditorPane.ID) -> EditorPane.ID

    /// New Editor Pane: the four cases of `-[IDEEditorAreaSplit _newEditorAreaSplitWithLayout:sender:]`.
    mutating func insert(_ newPaneID: EditorPane.ID, placed placement: EditorPanePlacement, relativeTo sourcePaneID: EditorPane.ID)
    /// A child split left with one pane gives way to that pane, in the child split's place.
    mutating func remove(_ paneID: EditorPane.ID)
    /// Change Editor Orientation: every split turns across, the arrangement stays.
    mutating func changeOrientation()
}

/// What one tab has shown, oldest first, and which entry is on screen.
public struct NavigationHistory: Hashable, Sendable {
    public private(set) var entries: [RuntimeObject]
    /// `nil` while the tab has shown nothing.
    public private(set) var currentIndex: Int?

    public var currentEntry: RuntimeObject? { get }
    public var canGoBackward: Bool { get }
    public var canGoForward: Bool { get }

    /// Drops the entries after the current one, then appends `object` — or, when the last entry is
    /// already `object` (identity, 0021), only moves there and takes on the form just reached.
    mutating func record(_ object: RuntimeObject)
    mutating func goBackward()
    mutating func goForward()
    mutating func go(to index: Int)
    /// Specialization completion: the history becomes `object` alone.
    mutating func reset(to object: RuntimeObject)
}

public struct DocumentTab: Hashable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        let rawValue: UUID
    }

    public let id: ID
    public internal(set) var history: NavigationHistory
    /// The object on screen, or `nil` for an empty tab.
    public var object: RuntimeObject? { history.currentEntry }
    public var title: String { get }
}

public struct EditorPane: Hashable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        let rawValue: UUID
    }

    public let id: ID
    /// Never empty.
    public internal(set) var tabs: [DocumentTab]
    public internal(set) var activeTabID: DocumentTab.ID
    public var activeTab: DocumentTab { get }
}

/// Everything the editor area shows, as one value: its panes, how they are arranged and which one
/// has the focus — so that no reader ever sees a layout naming a pane that is not there yet, or a
/// focus on a pane that has gone.
public struct EditorArea: Hashable, Sendable {
    public internal(set) var layout: EditorLayout
    public internal(set) var panes: [EditorPane.ID: EditorPane]
    public internal(set) var focusedPaneID: EditorPane.ID

    /// One pane holding one empty tab.
    public init()

    public var focusedPane: EditorPane { get }
    /// The panes in `layout.paneIDs` order.
    public var orderedPanes: [EditorPane] { get }
    public subscript(paneID: EditorPane.ID) -> EditorPane? { get }
    public func paneID(containing tabID: DocumentTab.ID) -> EditorPane.ID?

    /// What ⌘W closes: the focused tab while its pane has another, else the focused pane while
    /// there is another, else the window.
    public var closeTarget: CloseTarget { get }

    public enum CloseTarget: Hashable, Sendable {
        case tab(DocumentTab.ID)
        case pane(EditorPane.ID)
        case window
    }
}
```

`DocumentTab.ID` 与 `EditorPane.ID` 是两个类型，不直接用 `UUID`：两者都要在路由和视图层之间传来传去，同一个 `UUID` 类型会让「拿标签的标识去关窗格」照样编译通过。

`DocumentState` 的变化：

```swift
/// The editor area: panes, their tabs and histories, the arrangement and the focus. Read-only
/// externally; mutated only through `selectionRouter`.
@RxObserved
public fileprivate(set) var editorArea: EditorArea = EditorArea()

/// What the focused pane's active tab shows, or `nil` for an empty tab. Every route keeps it equal
/// to `editorArea.focusedPane.activeTab.object`; it stays a property of its own because the
/// sidebar, the Inspector, the toolbar, Find and MCP follow it.
@RxObserved
public fileprivate(set) var selectedRuntimeObject: RuntimeObject?

/// The member at the insertion point of the focused pane.
@RxObserved
public private(set) var cursorMember: RuntimeMemberReference?

/// Each pane reports its own insertion point; the focused pane's becomes `cursorMember`.
public func updateCursorMember(_ member: RuntimeMemberReference?, inEditorPane paneID: EditorPane.ID)
```

去掉 `selectionStack`、`selectionIndex`、`tabs`、`activeTabIndex`、`activeTab`、`canGoPrevious`、`canGoNext`；读它们的地方改读 `editorArea.focusedPane.activeTab.history`。`currentImageNode`、`isSelectedRuntimeObjectInCurrentImage`、引擎会话与后台工作不变。插入点按栏分开存（各栏一格，焦点栏的那一格映射成 `cursorMember`），不放进 `EditorArea`：插入点每次移动都会变，放进去就让每个订阅 `$editorArea` 的分栏都跟着重算。

### 路由（`SelectionRoute`）

```swift
public enum SelectionRoute: Routable {
    case switchEngine(RuntimeEngine)
    /// Only moves the sidebar: panes, tabs and histories stay.
    case switchImage(RuntimeImageNode?)
    case open(RuntimeObject, in: Destination, highlighting: ContentHighlightRequest? = nil)
    /// Specialization completion: the focused tab's history becomes `object` alone.
    case selectAtRoot(RuntimeObject)
    case backward
    case forward
    case jump(toIndex: Int)
    case newTab
    /// Also makes the tab's pane the focused one.
    case switchTab(DocumentTab.ID)
    /// The last tab of a pane closes the pane, when there is another.
    case closeTab(DocumentTab.ID)
    case moveTab(DocumentTab.ID, toIndex: Int)
    case newEditorPane(EditorPanePlacement)
    case closeEditorPane(EditorPane.ID)
    case closeOtherEditorPanes
    case focusEditorPane(EditorPane.ID)
    case changeEditorOrientation

    /// Where `open` shows an object.
    public enum Destination: Hashable, Sendable {
        /// The focused pane's active tab, recorded on its history.
        case focusedTab
        /// A new tab in the focused pane.
        case newTab
        /// The next pane after the focused one, made beside it when it is the only one.
        case nextEditorPane
    }
}
```

- `open(_:in:highlighting:)` 取代 `push`、`pushHighlighting`、`openInNewTab`、`openInNewTabHighlighting` 四个 case：加上「下一栏」之后，旧写法要变成六个 case，而它们只差去处和有没有定位。`highlighting:` 的默认值若 `@AssociatedValue` / `@CaseCheckable` 宏不支持，就去掉默认值，调用点写 `highlighting: nil`。
- 标签路由改用标签标识，不再用下标：多栏后下标只在一栏内有意义，7 月关标签的竞态也是下标描述了一组已经不存在的标签。
- `backward` / `forward` / `jump(toIndex:)` / `newTab` / `selectAtRoot` 作用于焦点栏的当前标签；`jump` 的下标是那个标签历史里的下标。
- 删掉 `.pop` 与 `.clear`：仓库里没有任何调用方（含测试）。
- 「先改状态、再发路由」的契约不变。路由器在每条路由末尾按 `editorArea` 重算 `selectedRuntimeObject` 与 `cursorMember`，值没变就不赋值，避免多余的发射。
- 修饰键到去处的换算放在一处：`SelectionRoute.Destination(clickModifierFlags:)`（AppKit 下），无修饰 → `.focusedTab`，⌥ → `.newTab`，⇧⌥ → `.nextEditorPane`；内容区的链接先去掉 ⌘ 再换算，⇧⌘ 另外映射到 `.newTab` 以保留现有习惯。`FindResultActivation.opensInNewTab(for:)` 换成它，`FindCrossReferenceNavigation.open(_:highlighting:inNewTab:in:)` 的 `inNewTab:` 换成 `in destination:`。

`MainCoordinator.fanOut` 只做两件事：把路由交给编辑区的 coordinator，让 Inspector 重新进入 `selectedRuntimeObject`（`.back`，同一对象时它本来就不重建）。编辑区按路由找到受影响的栏：

| 路由 | 状态变化 | 内容区 |
|------|----------|--------|
| `open(_, .focusedTab, h)` | 焦点栏当前标签 `record` | 焦点栏 `.next` / `.nextHighlighting` |
| `open(_, .newTab, h)` | 焦点栏新标签，历史只有这一条 | 焦点栏 `.root` / `.rootHighlighting` |
| `open(_, .nextEditorPane, h)` | 必要时新建一栏；目标栏当前标签 `record`；焦点移过去 | 目标栏 `.next` / `.nextHighlighting`，新栏 `.root` |
| `backward` / `forward` / `jump` / `selectAtRoot` | 焦点栏当前标签 | 焦点栏 `.back` |
| `newTab` | 焦点栏新空白标签 | 焦点栏 `.placeholder` |
| `switchTab` / `closeTab` / `moveTab` | 标签所在栏；`switchTab` 同时移焦点 | 那一栏 `.back`（对象没变就不重建），关掉整栏时撤掉它 |
| `newEditorPane` | 按 Xcode 规则插入，显示焦点栏当前对象，焦点移到新栏 | 新栏 `.root` 或 `.placeholder` |
| `closeEditorPane` / `closeOtherEditorPanes` | 删栏、折叠子 split、移焦点 | 撤掉被关的栏 |
| `focusEditorPane` / `changeEditorOrientation` | 只改焦点 / 只转置 | 无 |
| `switchImage` | 只改 `currentImageNode` | 无（侧栏照旧进入新镜像） |
| `switchEngine` | 回到 `EditorArea()` | 由 `MainRoute.main` 重建，同现在 |

### 界面层（`RuntimeViewerUsingAppKit`）

```
MainSplitViewController 第 1 项
└─ EditorAreaViewController + EditorAreaViewModel        EditorAreaCoordinator 的根
   └─ 嵌套的 NSSplitView：根一个，每个子 split 一个
      └─ EditorPaneViewController + EditorPaneViewModel  每栏一个
         ├─ TabBar（从 TabBarAccessoryController 搬来）与左端的关栏 ×
         └─ 这一栏的 ContentCoordinator 的 ContentNavigationController
```

- **`EditorAreaCoordinator`** 取代 `MainCoordinator` 里的 `ContentCoordinator`：按 `editorArea.layout` 增删各栏的 coordinator，接收 `fanOut` 交来的路由并分到具体的栏。`ContentCoordinator` 多一个 `paneID`，`.back` 改读自己那一栏的当前标签，其余逻辑（同一对象不重建、换编辑器种类）不变。
- **`EditorAreaViewController`** 把布局画成嵌套的 split view。结构变了才重建视图树，栏的视图控制器按 `EditorPane.ID` 复用，不随布局变化重建；新增或关闭后均分所在的 split，与 Xcode 相同；最小尺寸在 split view 的代理里拦分隔线（照 Xcode 0x13E454：拖到下一项的最小尺寸就停），不加 Auto Layout 约束，以免把 `MainSplitViewController` 的内容区撑宽。Reset Editor Sizes 只动视图，不经 `SelectionRoute`。
- **焦点同步**：`EditorAreaViewController` 用 KVO 观察窗口的 `firstResponder`，first responder 落在哪一栏的视图树里，就经 view model 发 `.focusEditorPane`（已经是焦点栏就不发）；反过来，焦点栏因为菜单命令、新建、关闭而变化时，把那一栏的内容视图设为 first responder（Xcode 的 `takeFocus`）。两个方向都先比较再动作，不会互相触发。
- **`EditorPaneViewModel`**（`RuntimeViewerApplication`）：Output 有标签栏快照（沿用 `TabBarSnapshot`，标识换成 `DocumentTab.ID`）、标签栏是否隐藏（只有一栏且不足两个标签时隐藏）、是否焦点栏、关栏按钮是否隐藏（不足两栏时隐藏）；Input 有选中标签、关闭标签、点关栏按钮。`TabBarAccessoryController` 里对 `TabBar` 合成事件的两个防护（`isApplyingSnapshot`、`isHandlingClose`）原样搬到每栏的标签栏上。
- **内容区**：`ContentTextViewModel` 多一个 `paneID`。它发出任何 `.open` 之前先发 `.focusEditorPane(paneID)`（已是焦点栏时什么也不变），插入点经 `updateCursorMember(_:inEditorPane:)` 上报。链接点击与右键菜单按上面的表换成 `Destination`。
- **工具栏**：`MainToolbarController` 加 `.Main.addEditor`，一个只挂菜单的按钮（Xcode 的 AddEditor 也没有点击动作，只有菜单），三种活动样式的默认项里都放在 `.Main.mcpStatus` 之后、`.inspectorTrackingSeparator` 之前。菜单项与 File 菜单发同样的动作，经 responder chain 到 `MainWindowController`。它位于居中项之后，不改变居中项前面那一组的宽度，`ToolbarCenteredItemTests` 照常覆盖。
- **窗口与菜单**：删掉 `TabBarAccessoryController` 和 `MainViewModel` 里的标签输入输出；前进后退与历史菜单改读焦点栏当前标签的 `NavigationHistory`。`MainWindowController` 的标签动作改为作用于焦点栏，新增各分栏动作与 `responds(to:)` 里的启用条件；`closeTab(_:)` 按 `editorArea.closeTarget` 决定关什么。File 菜单项沿用 `TabMenuController` 插入 New Tab 的位置，Navigate 与 View 菜单项由 `MainMenuController` 构建；Show Next/Previous Tab 从 Window 菜单挪到 Navigate，快捷键不变。
- **外观**：焦点栏与其余栏的标签栏外观、左端关栏按钮、分隔线粗细、每栏最小尺寸、工具栏按钮的图标，都照 Xcode 27.2 逆向后实现（落地第 6 步）。macOS 26 以上标签栏是否像侧栏的栏那样浮在内容上、带滚动边缘效果，也以 Xcode 为准；macOS 15 照现在的堆叠方式。

### 测试

- `EditorLayoutTests`：新建的四种情形（含只有一栏时转向），根里只剩一个子 split 的情形，删除与折叠，转置，`paneIDs` 顺序，前后循环。
- `NavigationHistoryTests`：记录（截断前进分支、末项是同一对象时只替换形态）、前进后退与跳转的边界、重置。
- `DocumentState` 的路由测试：新栏显示当前对象且历史只有一条、焦点移到新栏；三种去处（含只有一栏时开到下一栏会新建）；各标签的历史互不影响；焦点变化带动 `selectedRuntimeObject` 与 `cursorMember`；`closeTarget` 与关栏后焦点的去向；切镜像不动 `editorArea`；切引擎回到一栏。
- `EditorPaneViewModelTests`：标签栏与关栏按钮何时显示、是否焦点栏。
- 改用新路由的现有测试（`ContentTextViewModelTests`、`SidebarRuntimeObjectViewModelTests`、`FindCrossReferenceTests`、`FindResultsOutlineTests` 等）随调用点一起改。
- App target 没有测试 target，嵌套 split view 的搭建保持薄薄一层，靠模型测试加手工验收。

## 替代方案考量

- **保留整窗标签栏，每个标签各有一套分栏布局**（像 iTerm）：切标签就切换整套布局，分栏里每栏只显示一个对象。否：一条整窗标签栏表达不了几栏各自的标签，Xcode 也是每栏一条。
- **只能朝一个方向排**（全部并排成一行或一列，可整体转向）：实现更简单，但排不出「左一栏、右边上下两栏」。否，照 Xcode 行列嵌套。
- **切换镜像时保留布局、清空各栏**，或**照现在全部清掉**：都会让跨镜像对照做不成。否。
- **历史每栏一条**（同栏几个标签共用）或**全文档共用一条**（现状）：后者在多栏下后退会跳到在别的栏看过的对象。否，照 Xcode 每个标签各记各的。
- **标签栏完全照 Xcode 的显示规则**（任一栏有两个以上标签时每栏都显示，否则都不显示）：多栏但各只有一个标签时，看不出焦点在哪一栏，也没有关栏按钮——Xcode 靠跳转栏补上，RuntimeViewer 没有跳转栏。否。
- **加栏按钮放在每栏标签栏右端**：标签栏不显示时就没有按钮。**只用菜单和快捷键**：不好发现。否，照 Xcode 27.2 的默认放工具栏。
- **保留标签栏右端的「+」**：Xcode 没有，⌘T 与工具栏菜单都能开新标签。否。
- **布局、各栏、焦点分成三个可观察属性**：一条新建分栏的路由会依次发三次，订阅者可能看到引用了尚不存在的栏的布局。否，合成一个 `EditorArea`。
- **布局用任意深度的树**：要靠运行时检查守住 Xcode 的两层限制。否，两层写进类型：子 split 只能装栏。
- **保留 `push` / `openInNewTab` 等 case，再加 `openInNextEditorPane` 两个**：六个 case 只差去处和有没有定位。否，合成 `open(_:in:highlighting:)`。
- **跨启动保存布局**：RuntimeViewer 目前什么都不恢复，标签也不保存，单为分栏做恢复没有依托。否，列为非目标。

## 影响

### 用户可见变化

- **新增**：编辑器分栏；工具栏的「加一栏」菜单按钮；File 菜单的 New Editor Pane On Right / Below、Close Editor Pane、Close Other Editor Panes；Navigate 菜单的 Move Focus to Next / Previous Editor Pane；View 菜单的 Change Editor Orientation、Reset Editor Sizes；侧栏的 ⌥-点击与 ⇧⌥-点击、内容区的 ⇧⌥⌘-点击、Find 的 ⇧⌥-点击；右键菜单的 Open in Next Editor Pane。
- **改变**：标签栏从工具栏下方挪进各栏顶部；前进/后退只在当前标签看过的对象之间走，不再跨标签——要回到别的标签看过的对象，切到那个标签即可；切换镜像不再清空标签与历史；Show Next/Previous Tab 从 Window 菜单挪到 Navigate 菜单，快捷键不变；⌘W 在一栏只剩一个标签、还有别的栏时关掉这一栏。
- **移除**：标签栏右端的「+」。替代：⌘T，或工具栏菜单里的 Tab。

### 可发现性

工具栏按钮默认就在，File、Navigate、View 菜单都有对应项并标出快捷键，右键菜单新增 Open in Next Editor Pane。没有开关：只有一栏时界面与现在相同，分栏只在用户主动加栏时出现。

### 数据与配置兼容

不新增任何存盘的东西，`settings.json`、书签、派生数据都不受影响。工具栏不允许用户自定义，新按钮对所有人直接出现，没有旧配置要迁移。

### 平台与最低版本

最低系统版本不变（macOS 15）。macOS 26 以上与 macOS 15 的标签栏样式按 Xcode 与现有的堆叠方式分别处理（见「外观」）。iOS 版只有一栏，界面不变。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。发版说明写进新功能与上面三处行为变化。

## 落地步骤

1. **模型**：`EditorPaneOrientation`、`EditorPanePlacement`、`EditorLayout`、`NavigationHistory`、`EditorPane`、`EditorArea`，以及它们的测试。只加类型，不接线。
2. **DocumentState 与路由**：`editorArea` 取代 `selectionStack` / `selectionIndex` / `tabs` / `activeTabIndex`；`SelectionRoute` 改成上面的形状；切镜像不再清空；插入点按栏存；改全部调用点（侧栏、内容区、Inspector、Find、Main、iOS）与现有测试，补路由测试。这一步仍只有一栏，整窗标签栏临时改读焦点栏的标签；用户能察觉的只有「切镜像不清空」和「历史按标签」。
3. **编辑区界面**：`EditorAreaCoordinator` / `ViewController` / `ViewModel`、`EditorPaneViewController` / `ViewModel`、嵌套 split view、各栏标签栏、焦点同步；删掉 `TabBarAccessoryController`；`fanOut` 改为交给编辑区。
4. **命令**：工具栏按钮、File / Navigate / View 菜单项与快捷键、⌘W 的关闭顺序、启用条件。
5. **打开去处**：`Destination(clickModifierFlags:)`，侧栏、内容区、Find 与 Inspector References 的修饰键，右键菜单的 Open in Next Editor Pane。
6. **外观照 Xcode**：逆向 27.2 的分栏标签栏活跃与非活跃样式、左端关栏按钮、分隔线、每栏最小尺寸、工具栏按钮图标，以及 macOS 26 上标签栏与内容的叠放方式；本机没有 27B52 的 DVTUserInterfaceKit 导出，要先生成。需要 UIFoundation 的 `TabBar` 加接口的，先在 UIFoundation 发版、再抬 pin。
7. **文档与验收**：根 `AGENTS.md` 的架构要点与 `RuntimeViewerUsingAppKit/AGENTS.md` 的 coordinator 一节写进新约定（路由作用于焦点栏；内容区先取焦点再打开；标签与栏只按标识定位）；术语表登记「分栏」「焦点栏」「打开去处」；在 7 月的多 Tab 设计文档开头注明两条约定已被本提案取代；README 的功能列表加上编辑器分栏；全部测试通过后，交一份手工验收清单（加栏的四种情形、焦点与 Inspector 联动、三种打开去处、⌘W 的三种结果、切镜像与切引擎）。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、代码本身看不出来的决策」就写实现说明。焦点同步的双向规则、`selectedRuntimeObject` 只是 `editorArea` 的镜像这两点可能值得一份实现说明，落地时判断。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 有就同批次登记进术语表（项目级 `Documentations/Glossary.md`，跨项目通用的登记到全局术语表）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-06 | Created as Draft | 用户要求实现 Xcode 的编辑器分栏。它改动文档的导航核心——单一的 `selectedRuntimeObject`、整窗标签栏、全文档共用的历史——按完整档走：先问两轮、确认共识后写提案，提案批准前不写代码。Xcode 一侧的行为规则先逆向 27.2 取得 |
| 2026-11-06 | 标签栏跟着分栏走，取消整窗标签栏 | 一条整窗标签栏表达不了几栏各自的标签，Xcode 也是每栏一条。否掉「保留整窗标签栏、每个标签各有一套布局」 |
| 2026-11-06 | 行列嵌套，规则照 Xcode | 能排出「左一栏、右边上下两栏」。否掉「只能朝一个方向排」 |
| 2026-11-06 | 切换镜像时分栏、标签、历史全部保留，标签页一并改 | 跨镜像对照是分栏最主要的用途。否掉「保留布局、清空各栏」与「照现在全部清掉」 |
| 2026-11-06 | 第一批只做核心 | 加栏、关栏、切换焦点、每栏独立显示，命令与快捷键照 Xcode。最大化单栏、⌘J 选栏浮层、跨栏拖动标签留到以后 |
| 2026-11-06 | 前进后退按标签各记 | 照 Xcode。否掉「每栏一条」与「全文档共用一条」（7 月的约定），后者在多栏下会跳到别的栏看过的对象 |
| 2026-11-06 | 两栏以上时每栏都显示标签栏 | RuntimeViewer 没有跳转栏，完全照 Xcode 的显示规则会让「多栏但各只有一个标签」时看不出焦点、也没有关栏按钮。只有一栏时维持现状 |
| 2026-11-06 | 加栏按钮放工具栏 | 照 Xcode 27.2 默认：编辑区那一段的末尾、Inspector 分隔线之前。否掉「放每栏标签栏右端」与「只用菜单和快捷键」 |
| 2026-11-06 | 确认其余默认做法 | 新栏显示焦点栏当前对象、新标签空白；⌥ 开新标签、⇧⌥ 开到下一栏；右键加 Open in Next Editor Pane；侧栏、Inspector、工具栏、MCP 跟着焦点栏；⌘W 依次关标签、关栏、关窗口；分栏菜单照 Xcode；标签栏去掉「+」；切引擎回到一栏；布局不跨启动保存。否掉「保留标签栏的『+』」 |
| 2026-11-06 | Accepted | 用户批准，开始实现，分支 `feature/editor-panes` |

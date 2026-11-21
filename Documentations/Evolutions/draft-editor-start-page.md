# Draft - 空编辑栏的起始页：Open Quickly 与最近打开的对象

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-21
- **所属愿景**: 无
- **关联提案**: [0076 编辑器分栏](0076-editor-panes.md)（空标签与「唯一一栏的关闭按钮清空编辑区」）、[0092 编辑栏的路径栏](0092-editor-jump-bar.md)（镜像页与 `.openImage`）、[0069 文件模式](0069-file-mode.md)（读文件时的占位）、[0085 Filter Scope 按 Engine 与 Image 记住](0085-filter-scope-memory.md)（按 Engine 记忆的键）
- **实现分支 / PR**: `feature/editor-start-page`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

编辑栏里一个空标签（新窗口、⌘T 新开的标签、用关闭按钮清空的唯一一栏）现在只显示一行灰字「Select a runtime object」。本提案照 Xcode 27.2 空编辑器显示的初始页（IDEKit 的 `IDEInitialEditor`）把它换成一张起始页：顶部一个大号的 **Open Quickly** 搜索框，输入即在框下列出匹配的镜像与对象，回车或点击打开；下面是 **Recent Objects**，列出这个 Engine 上最近在编辑栏里看过的对象（图标、名字，下面一行是「Engine 〉 镜像」的路径），默认显示前几行、可 Show All 展开，点击打开。最近列表按 Engine 存盘、跨启动保留。读文件时的「Reading …」占位不变。另一个会话在做的 App 级欢迎窗口（启动时、没有文档时出现的窗口）不在本提案范围内。

## 动机

- **空标签什么也做不了**：`ContentPlaceholderViewController`（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentPlaceholderViewController.swift`）在没有对象时只摆一个 `Label("Select a runtime object")`。新开一个窗口、⌘T、或用唯一一栏的关闭按钮清空编辑区之后（0076 定下的清空办法），用户必须回到侧栏重新找镜像、再找对象，刚看过的东西没有任何回去的入口。
- **Open Quickly 在最常见的空状态下不可用**：现有的 Open Quickly（⇧⌘O，`SidebarRuntimeObjectListViewController.openQuickly(_:)`，UIFoundation 的 `QuickActionBar`）只搜侧栏当前镜像的对象，`responds(to:)` 在侧栏没有列出某个镜像的对象时返回 `false`。新窗口的侧栏停在镜像列表根上，这时菜单项是灰的。
- **用户点名要照 Xcode 做**：Xcode 27.2 关掉所有编辑器后，编辑区显示 Open Quickly 搜索框和 Recent Files 列表（用户给的截图）；RV 的编辑区已经照 Xcode 27.2 做了分栏、标签栏与路径栏（0076、0092），空标签是剩下没跟上的一块。
- **另一会话做的是 App 级欢迎窗口**（接入 UIFoundation 的 `WelcomePanelController`），列最近的文档与打开动作；本提案只管文档窗口之内、编辑栏里那一页，两者不重叠。

## 前期调研

### 现状代码

- **空标签显示什么**：`ContentCoordinator`（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift`）的 `prepareTransition` 在路由为 `.placeholder`、或 `.back` 时当前标签没有条目，走 `enterPlaceholderScene()`：文档的 `frameworkLoader.showsPageInEmptyPanes` 为真时显示 Load Frameworks 页，否则 `.set([placeholderViewController])`。`placeholderViewController` 是懒建的 `ContentPlaceholderViewController` + `ContentPlaceholderViewModel(documentState:router:)`，每栏一份（每栏一个 `ContentCoordinator`，`editorPaneID` 在协调器上）。
- **占位的状态**：`ContentPlaceholderViewModel`（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentPlaceholderViewModel.swift`）只有一个 `Placeholder`：`.noSelection` 或 `.readingFile(named:)`（文件引擎还没连上读文件的进程时，经 `withLoadingPlaceholder` 节流）。iOS 不用它（只在 macOS 协调器与两份测试里出现：`ContentPlaceholderViewModelTests`、`ViewModelBaseTests`）。
- **栏里的内容打开东西的写法**：先 `selectionRouter.trigger(.focusEditorPane(editorPaneID))`，再 `.open(object, in: destination, …)`，见 `ContentTextViewModel.swift:604`。目的地由点击修饰键决定：`SelectionRoute.Destination(listClickModifierFlags:)`（AppUI 的 `SelectionRouteDestination+ModifierFlags.swift`）——普通点击在焦点栏当前标签、⌥ 下一栏、⇧⌥ 新标签。镜像用 `.openImage(path, in:)`，显示镜像页并先索引（0092）。
- **当前显示的对象**：`DocumentState.selectedRuntimeObject` 始终等于焦点栏当前标签的对象（`syncWithEditorArea()`），切标签、切栏、前进后退都会更新它。
- **打开一个未索引镜像里的对象**：`ContentTextViewModel` 在取接口前对未索引的镜像调 `documentState.indexImageForUser(at:)`（`ContentTextViewModel.swift:167`），所以重启后从最近列表打开对象、镜像还没加载也能显示，并记进 Report 的 Manual Loading。
- **按 Engine 记东西的键**：`Settings.Indexing.EngineReference.key(for:)`（`RuntimeViewerSettings/Settings+IndexingEngineReference.swift`），本机附加的进程按进程名、其余按 bookmark scope；0085 的 Filter Scope 记忆（`RuntimeObjectScopeMemory`、`AppDefaults.runtimeObjectScopesByEngineAndImagePath`）用的就是它。`AppDefaults` 里按 scope 存的东西都是 `@ResilientFileStorage`，测试有隔离目录（`AppDefaults(storageDirectoryURL:userDefaultsNamespace:)`）。
- **Open Quickly 的匹配与排序**：`SidebarRuntimeObjectListViewModel.scheduleOpenQuicklyRefilter(query:)` 用 `FilterEngine.match(FilterContext(query:isCaseInsensitive:false, mode: .fuzzySearch), haystacks:)`，再由私有的 `rankByRelevance(_:runtimeObjects:limit:)` 按权重、是否命中自身名字、首个命中位置、名字长度、名字排序，截到 `openQuicklyMaximumMaterializedRows`（500）。
- **Engine 上能便宜读到的东西**：`RuntimeEngine.imageNodes`（镜像树，nonisolated）；`indexedImagePathList()`（两个 section 都建好的镜像，与 `isImageIndexed(path:)` 同一判据）；对已索引的镜像 `objects(in:)` 直接从索引答，不触发索引（路径栏的 `EditorJumpBarItemStore` 就是这样只读已索引镜像的对象，见其 300–343 行）。后台索引默认关闭（`Settings.Indexing.isEnabled` 默认 `false`），所以一般会话里已索引的只有用户打开过的镜像。
- **图标**：对象用 `IconDescriptor.runtimeObject(kind, size:)`，镜像用 `.imageKind(RuntimeImageKind(ofImageAt:))`，Engine 用 `.runtimeEngine(engineID:)`，都由 AppUI 画（`RuntimeViewerPackages/Sources/AGENTS.md`）。

### Xcode 27.2 的做法（逆向）

IDEKit（`/Applications/Xcode.app`，27.2 27B52，Swift 接口导出在 `/Volumes/RE/Xcode/27.2-27B52/IDEKit/`）里的 `IDEInitialEditor`（`IDEEditor` 子类）就是这一页，SwiftUI 写的：

- `DisplayStyle`：`.suggestedContent`（搜索框 + 最近列表）或 `.empty(message:)`。
- `InitialEditorView<A>`：`body`、`resultsOverlayView`、`shouldShowResultsOverlay`、`@FocusState searchFieldFocused`、`errorBanner`。
- 搜索框是内嵌的 `IDESearchWindowQueryView`（`OpenQuicklyQueryView`，`NSViewRepresentable`），协调器实现 `controlTextDidChange`、`doCommandBy`（方向键、回车、Esc）与 `queryViewSearchAction`；`OpenQuicklyQueryViewModel.minimumInstantQueryLength` 决定输几个字才开始即时搜索。结果由 `OpenQuicklyResultsView` 托管 Open Quickly 窗口同一个 `IDEOpenQuicklyContentViewController`，浮在框下（`resultsOverlayView`），高度随内容（`contentHeight`）。也就是说，这个框就是内嵌的 Open Quickly，范围与 Open Quickly 窗口相同。
- `RecentItemsSection<A>(recentItems:defaultRowCount:selectedRecentAction:)`：`@State showAll`，`SectionHeaderView(title:canShowMore:showAll:)` 与 `ShowAllButtonStyle`；`selection` 一变就调 `selectedRecentAction` 打开。行是 `RecentItemView`：`displayIcon`、`displayName`、`itemPath`（`ItemPath`：一个图标加 `pathComponents`，`ItemPathView.combinedPathComponents` 把各段用 〉 连成一个 `Text`）；行可拖出（`RecentItemDragPayload(url:)`）。
- 最近列表来自工作区的最近文档（`IDEInitialEditorModel._recentItems`，`getRecents()` / `IDERecentDocumentInfo`），按工作区记、跨启动保留。

具体的尺寸、字号、颜色、`defaultRowCount` 与 `minimumInstantQueryLength` 的数值见下文「Xcode 27.2 的度量」，由逆向填入。

### Xcode 27.2 的度量

（逆向完成后填入：地址与数值，`[D]` 为反编译 / 反汇编所得。）

## 提议方案

空标签的那一页（`ContentPlaceholderViewController` 的 `.noSelection` 状态）换成起始页，分三块：

1. **Open Quickly 搜索框**：页面顶部、水平居中的大号圆角框，左边放大镜、占位文字「Open Quickly」。输入达到 Xcode 的最小长度后，框下列出匹配项（盖住最近列表的位置）：
   - **搜什么**：这个 Engine 的**全部镜像（按文件名）**，加上**已索引镜像里的对象**（顶层对象及其嵌套的子对象，按 `displayName`）。镜像相当于 Xcode 的文件，对象相当于符号；只读已索引的镜像，不为搜索触发任何索引。
   - **何时读**：框从空变为非空时开始读一次（`imageNodes` 与 `indexedImagePathList()`，再对已索引的镜像并发 `objects(in:)`），读完之前显示进度、读完后匹配；同一次输入期间复用，框清空或打开了结果就丢掉，不常驻内存。
   - **怎么排**：与现有 Open Quickly 相同的模糊匹配与排序（排序抽成共用的函数，侧栏的 Open Quickly 改用它、行为不变），截到前若干条。
   - **键盘**：↑ / ↓ 在结果里移动选中，回车打开选中的一项（默认第一项），Esc 清空输入；点击一项打开。修饰键同列表点击：⌥ 下一栏、⇧⌥ 新标签。打开对象走 `.open`，打开镜像走 `.openImage`（镜像页，会先索引）。
2. **Recent Objects**：标题行左边「Recent Objects」、右边「Show All」（多于默认行数时才有）。每行：对象的图标、`displayName`，下面一行小字是 Engine 的图标加「Engine 名 〉 镜像名」，照 Xcode 的「SDK 〉 框架」。默认显示前 `defaultRowCount` 行（Xcode 的值），Show All 展开全部。点击打开，修饰键同上。
3. **读文件时**：仍是转圈加「Reading “…”…」，与现在相同；读完回到起始页。

**最近列表怎么记**：每个文档在 `DocumentSession.open()` 里起一个记录器，跟着 `DocumentState.$selectedRuntimeObject`（焦点栏当前标签的对象）：每出现一个非空对象，就把它移到这个 Engine 的列表最前面（按身份去重），最多留 50 个，写进 `AppDefaults.recentRuntimeObjectsByEngine`（键为 `Settings.Indexing.EngineReference.key(for:)`）。同一 Engine 上的几个窗口共用一份，起始页跟着这份存储实时刷新。只在 macOS 记，iOS 不变。

**没有询问就采用的假设**（用户看效果时可以推翻）：

- **只记对象，不记镜像页**；标题因此叫「Recent Objects」而不是 Xcode 的「Recent Files」。重开时按对象自己的语言显示（看过的 Generated Interface 不单独记）。
- **最近列表按 Engine 记**，相当于 Xcode 按工作区记；切到别的 Engine 的窗口看到的是那个 Engine 的列表。上限 50 个，没有清空按钮。
- **路径行写「Engine 名 〉 镜像名」**，图标是 Engine 的图标，照 Xcode 路径行「第一段的图标 + 各段名字」的形状。
- **存下来的对象带着记录时的 `children`**：打开时内容区按身份重新取接口，不受影响；Inspector 的 Specialization 页列的是记录时的特化，与 Find 结果打开的对象一样。
- **Open Quickly 框的范围是整个 Engine（镜像 + 已索引镜像的对象）**，不跟着侧栏当前镜像走，所以新窗口里也能用；⇧⌘O 的浮动 Open Quickly 不变，仍只搜侧栏当前镜像。
- **结果列表盖在最近列表的位置上**，而不是做成浮出的窗口；Xcode 也是在页面里浮在框下。
- **页面背景沿用内容区现在的背景**，起始页不另画背景。

### 非目标

- App 级的欢迎窗口（另一会话在做）。
- 改 ⇧⌘O 的浮动 Open Quickly 的范围或外观。
- 为搜索建 Engine 端的名字索引、或为搜索触发索引；没索引的镜像里的对象搜不到，打开镜像页后（会先索引）再搜就有。
- 最近列表的右键菜单、移除单条、清空、拖出；Xcode 的 `.empty(message:)` 样式与错误横幅（`errorBanner`，缺文件时用）。
- iOS、visionOS 的起始页。
- 搜索 C++ 对象（`objects(in:includesCPlusPlusObjects:)` 默认不含，与 Find 一致）。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentPlaceholderViewController.swift` · `ContentPlaceholderViewController` | 修改 | `.noSelection` 时显示起始页：搜索框、标题行、列表；`.readingFile` 时照旧转圈，并让出起始页里的键盘焦点 | 空标签的页面就是它 | 1、3、4 |
| 同上 · 私有嵌套的 `OpenQuicklyField`、`FocusReportingTextField`、`ItemCellView` | 新增 | 起始页的大号圆角搜索框（放大镜 + 无边框文本框，光环只在 key 窗口里输入时亮）与列表行 | 只有这一个控制器用，按 `RuntimeViewerUsingAppKit/AGENTS.md` 作它的私有嵌套类型 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentPlaceholderViewModel.swift` · `ContentPlaceholderViewModel` | 修改 | 加 `editorPaneID`（第 1 步起由协调器传入）与 `recentItems` 输出（第 1 步为空）；之后加最近列表、Show All、搜索文本、结果、选中、打开；`.readingFile` 逻辑不变 | 空标签那一页的 VM | 1–4 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentStartPageItemCellViewModel.swift` · `ContentStartPageItemCellViewModel` | 新增 | 一行（对象或镜像）的 `Appearance`：图标、名字、路径图标与路径各段；镜像行的路径段是装着它最近那个 bundle 的文件夹 | 最近列表与搜索结果共用的行 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/RuntimeImage/RuntimeImageKind.swift` · `RuntimeImageKind` | 修改 | 加内部的 `isBundleDirectoryName(_:)`，复用按扩展名认 bundle 的规则 | 镜像行的路径段要跳过 bundle 内部的目录 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/RecentRuntimeObjects.swift` · `RecentRuntimeObjects` | 新增 | 纯逻辑：把一个对象记到列表最前、按身份去重、截到上限 | 可单测的记录规则 | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/RecentRuntimeObjectsRecorder.swift` · `RecentRuntimeObjectsRecorder` | 新增 | 跟着文档的 `$selectedRuntimeObject` 与 Engine，写 `AppDefaults` | 一个文档一个记录器 | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Document/DocumentSession.swift` · `DocumentSession` | 修改 | `open()` 里启动记录器（macOS） | 每个窗口都记 | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Storage/AppDefaults.swift` · `AppDefaults` | 修改 | 新增 `recentRuntimeObjectsByEngine: [String: [RuntimeObject]]`（`@ResilientFileStorage`） | 按 Engine 存盘 | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/OpenQuicklyCatalog.swift` · `OpenQuicklyCatalog` | 新增 | 一次搜索会话的条目（镜像 + 已索引镜像的对象）、从 Engine 读、匹配与截断 | 起始页搜索框的范围与匹配 | 4 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Filtering/OpenQuicklyRanking.swift` · `OpenQuicklyRanking` | 新增 | 从 `SidebarRuntimeObjectListViewModel.rankByRelevance` 抽出的排序 | 两处 Open Quickly 同一排序 | 4 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectListViewModel.swift` | 修改 | 改调 `OpenQuicklyRanking`，行为不变 | 去重 | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift` · `ContentCoordinator` | 修改 | 建占位 VM 时传 `editorPaneID` | 打开前聚焦这一栏 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/…` | 新增 | `RecentRuntimeObjectsTests`、`RecentRuntimeObjectsRecorderTests`、`ContentStartPageViewModelTests`、`OpenQuicklyCatalogTests` | 每步的行为清单 | 2–4 |
| `RuntimeViewerUsingAppKit/AGENTS.md` | 修改 | 编辑区一节加一句：空标签显示起始页、最近列表按 Engine 记 | 规则随代码 | 5 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记草案 | 索引 | 0 |

## 架构图

改了什么：

```text
RuntimeViewerAppCore
├── Content/
│   ├── ContentPlaceholderViewModel        ~ + editorPaneID, recents, search, open
│   ├── ContentStartPageItemCellViewModel  + row appearance (object | image)
│   └── OpenQuicklyCatalog                 + images + objects of indexed images, match
├── EditorArea/
│   ├── RecentRuntimeObjects               + record / dedupe / cap
│   └── RecentRuntimeObjectsRecorder       + follows $selectedRuntimeObject
├── Filtering/OpenQuicklyRanking           + shared ranking
├── Sidebar/RuntimeObject/SidebarRuntimeObjectListViewModel  ~ uses OpenQuicklyRanking
├── Document/DocumentSession               ~ open() starts the recorder (macOS)
└── Storage/AppDefaults                    ~ + recentRuntimeObjectsByEngine
RuntimeViewerUsingAppKit (app)
├── Content/ContentPlaceholderViewController  ~ start page layout and bindings
│   ├── OpenQuicklyField                      + Xcode-sized rounded query field (private)
│   └── ItemCellView                          + icon, name, path row (private)
└── Content/ContentCoordinator                ~ passes editorPaneID
```

数据流：

```text
any pane shows an object
  → DocumentState.$selectedRuntimeObject
  → RecentRuntimeObjectsRecorder → RecentRuntimeObjects.recording(_:in:)
  → AppDefaults.recentRuntimeObjectsByEngine[engineKey]
  → ContentPlaceholderViewModel (every empty pane of every window on the engine)
  → rows → ContentPlaceholderViewController

typing in the field
  → ContentPlaceholderViewModel.searchText (count ≥ minimumInstantQueryLength)
  → OpenQuicklyCatalog.load(from: engine)   [once per search session]
       imageNodes + indexedImagePathList() + objects(in:) per indexed image
  → OpenQuicklyCatalog.matches(for:limit:) → FilterEngine + OpenQuicklyRanking
  → results → Return / click
  → .focusEditorPane(paneID) → .open(object, in:) | .openImage(path, in:)
```

## 详细设计

### 最近列表

```swift
/// The objects a runtime engine's editor panes showed, most recent first.
public enum RecentRuntimeObjects {
    /// How many objects an engine keeps.
    public static let maximumCount = 50

    /// `objects` with `object` first: an object already in the list moves to the front, matched by
    /// identity (`RuntimeObject.==`), and the entry is replaced by the form just shown.
    public static func recording(_ object: RuntimeObject, in objects: [RuntimeObject]) -> [RuntimeObject]
}

/// Records every object the document's focused pane shows into its engine's recent objects.
@MainActor
public final class RecentRuntimeObjectsRecorder {
    public init(documentState: DocumentState)
}
```

`AppDefaults`：

```swift
/// The objects each engine's editor panes showed, most recent first, keyed by
/// `Settings.Indexing.EngineReference.key(for:)`. Written by `RecentRuntimeObjectsRecorder`.
@ResilientFileStorage
public var recentRuntimeObjectsByEngine: [String: [RuntimeObject]]
```

记录器订阅 `documentState.$runtimeEngineSession` 取 Engine 键，配上 `$selectedRuntimeObject.compactMap { $0 }`，每个值读当前存储、`recording` 之后写回（只有变了才写）。存储用 `@ResilientFileStorage` 的 `$` 投影观察，起始页的 VM 订阅同一个投影，所以同一 Engine 上别的窗口新看的对象也会出现。

### 行

```swift
public final class ContentStartPageItemCellViewModel: NSObject, @unchecked Sendable {
    public enum Item: Hashable, Sendable {
        case object(RuntimeObject)
        case image(path: String)
    }

    public struct Appearance: Hashable, Sendable {
        public var icon: IconDescriptor
        public var title: String
        public var pathIcon: IconDescriptor?
        public var pathComponents: [String]
    }

    public let item: Item
    public let appearance: Appearance
}
```

对象行：图标 `IconDescriptor.runtimeObject(kind, size:)`，标题 `displayName`，路径图标 `.runtimeEngine(engineID:)`，路径 `[engine.source.description, 镜像文件名]`。镜像行（只出现在搜索结果里）：图标 `.imageKind(RuntimeImageKind(ofImageAt:))`，标题镜像文件名，路径 `[engine 名, 上级目录名]`。行在创建后不变，没有 `@RxObserved`，按 `item` 判断是否同一行（`Differentiable`）。

### ViewModel

`ContentPlaceholderViewModel(documentState:router:editorPaneID:)`，`editorPaneID` 为 `nil` 时用焦点栏（与 `ContentTextViewModel` 一致，旧调用点与测试不用改）。

```swift
public struct Input {
    public let showAllClicked: Signal<Void>
    public let recentItemChosen: Signal<(ContentStartPageItemCellViewModel, SelectionRoute.Destination)>
    public let searchText: Signal<String>
    public let searchSelectionMoved: Signal<Int>          // −1 up, +1 down
    public let searchCommitted: Signal<SelectionRoute.Destination>   // Return
    public let searchResultChosen: Signal<(ContentStartPageItemCellViewModel, SelectionRoute.Destination)>
}

public struct Output {
    public let placeholder: Driver<Placeholder>
    public let recentItems: Driver<[ContentStartPageItemCellViewModel]>   // already cut to the default count unless shown all
    public let showAllButton: Driver<ShowAllButton>                       // hidden / showAll / showLess
    public let search: Driver<SearchState>                                // idle / loading / results([…], selectedIndex)
    public let clearSearchField: Signal<Void>
}
```

打开：`selectionRouter.trigger(.focusEditorPane(editorPaneID))`，再 `.open(object, in: destination)` 或 `.openImage(path, in: destination)`。打开搜索结果后清空搜索状态并让视图清空输入框。

### 搜索

```swift
/// What the start page's Open Quickly field searches during one search: the engine's images by
/// name and the objects of the images it has indexed. Reading it indexes nothing.
public struct OpenQuicklyCatalog: Sendable {
    public struct Entry: Sendable {
        public let item: ContentStartPageItemCellViewModel.Item
        public let name: String
    }
    public let entries: [Entry]

    public static func load(from engine: RuntimeEngine) async -> OpenQuicklyCatalog
    public func matches(for query: String, limit: Int) -> [Entry]
}
```

`load`：镜像取自 `engine.imageNodes` 的叶子（`RuntimeImageNode.path`，与 `.openImage` 要的路径同一来源）；对象取 `indexedImagePathList()` 里每个镜像的 `objects(in:)`（`TaskGroup`，读失败的镜像跳过），连同嵌套的 `children` 拍平。`matches` 用 `FilterEngine` 的模糊匹配，排序交给 `OpenQuicklyRanking`，截到 `limit`。

## 替代方案考量

- **框只是一个入口，点一下弹出现有的浮动 Open Quickly**：最省事，但现有的只搜侧栏当前镜像，新窗口里是灰的——起始页最常出现的时候恰好不能用；也不像 Xcode（内嵌、结果浮在框下）。否。
- **只搜侧栏当前镜像（与 ⇧⌘O 同范围）**：同上，新窗口里什么也搜不到。否。
- **为搜索给 Engine 加按名字找对象的命令、或者先索引全部镜像**：范围大，还要改 Core 与线上命令；后台索引默认关闭，用户没要的索引不该因为打字而发生。列为后续项。
- **最近列表放在 `DocumentState` 里、只记本窗口**：Xcode 按工作区记、跨启动保留；只记本窗口的话新窗口永远是空的，起始页最需要它的时候没有内容。否。
- **新建一对 `ContentStartPage…ViewController / ViewModel`，占位留给读文件**：要在协调器里多一个场景、在两个页面之间切换，读文件结束时还得跨场景切回；占位 VM 本来就是「空标签这一页」的 VM，扩展它改动更小。否。

## 影响

### 用户可见变化

- 空标签不再显示「Select a runtime object」，改为起始页：Open Quickly 搜索框、Recent Objects 列表（有记录时）。
- 新增：在起始页的搜索框里可以按名字找镜像与已索引镜像里的对象，回车或点击打开；最近看过的对象出现在列表里，点击回到它。
- 不变：⇧⌘O 的浮动 Open Quickly、侧栏、读文件时的占位、Load Frameworks 页。

### 可发现性

起始页就是空标签的页面，新窗口与 ⌘T 一打开就看到，不需要设置项；默认开启。

### 数据与配置兼容

新增一个存储文件 `AppStorage/recentRuntimeObjectsByEngine.json`（`@ResilientFileStorage`，读不出就当空）；不碰已有文件。降级到旧版本时这个文件被忽略。

### 平台与最低版本

只在 macOS（15+）上有起始页与记录；iOS、visionOS 不变。

### 发布

不需要新的权限或 entitlement，不影响公证与 Sparkle。

## 落地步骤

1. **起始页骨架**（已完成） —— `ContentPlaceholderViewController`（含嵌套的 `OpenQuicklyField`、`ItemCellView`）、`ContentPlaceholderViewModel` 的 `editorPaneID` 与空的 `recentItems`、`ContentStartPageItemCellViewModel`、`RuntimeImageKind.isBundleDirectoryName(_:)`、`ContentCoordinator` 传 `editorPaneID`
   - 行为：没有对象的标签显示 Open Quickly 搜索框，占位文字为「Open Quickly」（目视）
   - 行为：读文件时仍显示转圈与「Reading “…”…」，读完回到起始页（`ContentPlaceholderViewModelTests` 照旧通过）
   - 行为：切到读文件的转圈时，起始页里的键盘焦点被让出（目视）
   - 行为：搜索框的光环只在 key 窗口里输入时亮；输入时点框体空白处不动已输入的文字（目视）
   - 行为：没有最近对象时不显示 Recent Objects 标题（目视）
   - 行为：对象行的标题为 displayName、路径为「Engine 名 〉 镜像名」
   - 行为：镜像行的路径是「Engine 名 〉 装着它最近那个 bundle 的文件夹」，bundle 外的镜像是它自己所在的文件夹
2. **记录最近对象并列出** —— `RecentRuntimeObjects`、`RecentRuntimeObjectsRecorder`、`AppDefaults.recentRuntimeObjectsByEngine`、`DocumentSession.open()`、VM 的 `recentItems` 跟随存储
   - 行为：焦点栏显示一个对象时它被记到这个 Engine 的列表最前
   - 行为：再次显示列表里已有的对象时它移到最前、不重复
   - 行为：列表最多保留 50 个，最旧的先丢
   - 行为：空标签不记任何东西
   - 行为：不同 Engine 各有各的列表
   - 行为：起始页列出这个 Engine 的最近对象
   - 行为：同一 Engine 上另一个窗口看了新对象，这一页的列表随之更新
3. **Show All 与打开最近对象** —— VM 的 `showAllClicked`、`recentItemChosen`
   - 行为：多于默认行数时只显示前几行，标题行有 Show All（照 Xcode 的 `defaultRowCount`）
   - 行为：不多于默认行数时没有 Show All
   - 行为：按 Show All 显示全部，再按收回（照 Xcode 的按钮文字）
   - 行为：点一行先聚焦这一栏、再在这一栏的当前标签打开该对象
   - 行为：⌥ 点一行在下一栏打开，⇧⌥ 在新标签打开
4. **Open Quickly 搜索框** —— `OpenQuicklyCatalog`、`OpenQuicklyRanking`、侧栏改用共用排序、VM 的搜索输入输出、视图的键盘处理
   - 行为：输入少于最小长度时不显示结果
   - 行为：结果包含名字匹配的镜像与已索引镜像里的对象
   - 行为：未索引镜像里的对象不在结果里，搜索也不触发索引
   - 行为：排序与侧栏的 Open Quickly 相同（命中自身名字、位置靠前、名字短的在前）
   - 行为：读取条目期间显示进度，读完显示结果
   - 行为：回车打开第一项；↓ / ↑ 移动选中后回车打开选中项
   - 行为：打开镜像结果显示该镜像的镜像页
   - 行为：打开结果或按 Esc 后输入框清空、结果消失，回到最近列表
   - 行为：起始页所在的栏取得焦点（⌘T 新标签、切到这一栏）时，键盘焦点落进搜索框（`EditorPaneContent.focusableView`，照 Xcode 的 `shouldFocusSearchField`；目视）
   - 行为：侧栏 Open Quickly 的排序不变（既有测试照旧通过）
5. **文档** —— `RuntimeViewerUsingAppKit/AGENTS.md`、索引、本提案的决策日志

只能在界面上看到的行为（布局、尺寸、颜色、焦点环、结果浮层的位置）在 ViewModel 层测不到，列为目视验证。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、
  代码本身看不出来的决策」就写实现说明。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 有就同批次登记进术语表。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-21 | Created as Draft | 用户要求照 Xcode 的空编辑器初始页（Open Quickly 搜索框加最近文件）给 RuntimeViewer 做一个文档内的欢迎页；App 级欢迎窗口由另一会话负责。 |
| 2026-11-21 | 批准方式 | 用户调用 `implement-feature` 即批准，提案由 agent 起草、用户事前未审阅。 |
| 2026-11-21 | 开始实现 | 状态 In Progress，分支 `feature/editor-start-page`。 |
| 2026-11-21 | 搜索范围定为「全部镜像 + 已索引镜像的对象」 | 起始页最常出现在新窗口，此时侧栏没有选镜像，按现有 Open Quickly 的范围什么都搜不到；镜像相当于 Xcode 的文件、对象相当于符号，只读已索引的镜像不会因为打字触发索引。 |
| 2026-11-21 | 最近列表按 Engine 记、只记对象、上限 50 | 相当于 Xcode 按工作区记最近文件；镜像页是对象的入口而非内容，记进去会挤掉对象；上限取一个够用又不让存储变大的值。 |
| 2026-11-21 | 扩展 `ContentPlaceholderViewModel` 而不是另起一页 | 它本来就是「空标签这一页」的 VM，读文件的占位与起始页互斥地出现在同一位置，扩展比在协调器里多一个场景改动小。 |
| 2026-11-21 | 第 1 步审查后调整 | 两位审查者指出：搜索框只有这一个控制器用，按规则改为它的私有嵌套类型（原计划放进 `RuntimeViewerUI`）；行模型与 `editorPaneID` 的传入提前到第 1 步作骨架，改动地图随之更新；镜像行的路径段原取上一级目录，框架会显示成 `Versions` 下的「C」，改为装着最近那个 bundle 的文件夹；另补了切到读文件时让出焦点、光环只在 key 窗口亮、输入时点框体不全选、文本框不抢宽度。 |
| 2026-11-21 | 读文件开头的一瞬仍显示起始页，不另处理 | `.readingFile` 照旧按 `LoadingPlaceholderTiming.appearsAfter` 节流，读得快的文件不闪转圈；代价是慢的文件在出现转圈前先显示起始页，与原先先显示提示文字、再换成「Reading…」相同。 |

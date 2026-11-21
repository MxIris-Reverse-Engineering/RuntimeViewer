# Draft - 空编辑栏的起始页：Open Quickly 与最近打开的对象

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-22
- **所属愿景**: 无
- **关联提案**: [0076 编辑器分栏](0076-editor-panes.md)（空标签与「唯一一栏的关闭按钮清空编辑区」）、[0092 编辑栏的路径栏](0092-editor-jump-bar.md)（镜像页与 `.openImage`）、[0069 文件模式](0069-file-mode.md)（读文件时的占位）、[0085 Filter Scope 按 Engine 与 Image 记住](0085-filter-scope-memory.md)（按 Engine 记忆的键）
- **实现分支 / PR**: `feature/editor-start-page`
- **配套文档**: 不另写；规则在 `RuntimeViewerUsingAppKit/AGENTS.md` 编辑区一节，Xcode 的度量在 `/Volumes/RE/Xcode/27.2-27B52/README.md`「Initial editor (IDEInitialEditor)」，自审裁决在 [`KnownIssues/2026-11-21-editor-start-page-review-findings.md`](../KnownIssues/2026-11-21-editor-start-page-review-findings.md)
- **网页版**: 同目录同名的 `.html`

## 摘要

编辑栏里一个空标签（新窗口、⌘T 新开的标签、用关闭按钮清空的唯一一栏）现在只显示一行灰字「Select a runtime object」。本提案照 Xcode 27.2 空编辑器显示的初始页（IDEKit 的 `IDEInitialEditor`）把它换成一张起始页：顶部一个大号的 **Open Quickly** 搜索框，输入满 3 个字符即在框下浮出匹配的镜像与对象，回车或点击打开；下面是最近列表，跟着侧栏走（第 8 步，用户看过后要求）：侧栏停在镜像列表时是 **Recent Images**，列这个 Engine 最近用过的镜像；侧栏进到某个镜像后是 **Recent Objects**，只列这个镜像里最近在编辑栏看过的对象（图标、名字，下面一行是「Engine 〉 镜像」的路径）。每个 Engine 记 10 个镜像、每个镜像记 10 个对象，默认显示 8 行、可 Show All 展开，双击或回车打开。最近列表按 Engine 存盘、跨启动保留。读文件时的「Reading …」占位不变。File › Open Quickly…（⇧⌘O）的浮动条改成与起始页同一个搜索（第 6 步，用户看过初版后要求），从 1 个字符起就搜，有文档窗口时总可用；侧栏原来只搜当前镜像的那一份 Open Quickly 删掉（第 7 步）。另一个会话在做的 App 级欢迎窗口（启动时、没有文档时出现的窗口）不在本提案范围内。

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

全部出自 IDEKit 27B52（UUID 443917F3-EEF8-3ED5-AB2F-30D51C54231C），完整记录与地址在
`/Volumes/RE/Xcode/27.2-27B52/README.md` 的「Initial editor (IDEInitialEditor)」一节；下面只摘实现要用的数值，标 `[D]`
的为反编译 / 反汇编所得，`[R]` 为需要运行时观察、此处按截图估的。

- **页面**（`InitialEditorView.body` 0x6E432C）：可滚动；内容列水平居中，最窄 200、最宽 700，两侧留 32，顶部留 80；搜索框与
  最近一节之间 65。页面背景是工作区背景样式 3（随主题，画廊 / 对比编辑器用的那种）。点页面空白处让搜索框失去焦点。[D]
- **搜索框**（`OpenQuicklyQueryUI.body` 0x6F6B00、`IDESearchWindowQueryView`）：高 47，连续圆角 24。没聚焦、或窗口不是 key 时
  填 `WelcomeListCellBackground`（浅色 sRGB 0.373 灰、α 0.12；深色白、α 0.04），没有描边；聚焦且窗口为 key 时去掉底色，画一圈
  3pt 的强调色描边（不透明度 0.6，描边居中，1.5pt 在外）。放大镜是 23 × 23 的模板图，居中在 x = 16 起的 32 × 32 框里；文字列
  从 x = 62 到右边留 20；字体 20pt medium，占位文字「Open Quickly」，颜色用系统默认。[D]
- **输入**（`queryView(_:controlTextDidChange:)` 0x6F7EB8 等）：满 3 个字符才搜索（写死的 3）；少于 3 个字符时不更新查询，留着
  上一次的结果。↑ / ↓ 移动结果里的选中，回车打开选中项，Esc 清空输入。[D]
- **结果浮层**（`resultsOverlayView` 0x6E64E0、`OpenQuicklyResultsUI.body` 0x6FA284、`resizeForContent` 0x6FA970）：浮在
  最近列表上，顶在搜索框下 5pt，同宽；连续圆角 24 的 Liquid Glass；高度 = min(行数 × 56, 420) + 20，有结果才出现，高度变化
  0.25 秒缓动；只在搜索框聚焦且窗口为 key 时显示。行就是 Open Quickly 窗口的行（56 高）。[D]
- **最近一节**（`RecentItemsSection` 0x6EE9C0、`SectionHeaderView` 0x6FCBA0、`ShowAllButtonStyle` 0x6FD260）：标题「Recent
  Files」用 `.title` 字体；多于 `defaultRowCount`（**8**）条时右侧有按钮，11pt、强调色，未展开时「Show All」、展开后「Show
  Less」，没有按下与悬停样式；标题与列表间 12，整节左右各缩 4、列表再缩 4。没有最近条目时整节不显示。[D]
- **行**（`RecentItemView` 0x6FBF8C、`ItemPathView` 0x6F6538）：图标 32 × 32，与文字间 4；名字 13pt、中间截断；下一行路径
  11pt 次要色、中间截断、最多两行：12 × 12 的图标（占 12 × 14），间 2，各段之间是 SF Symbol `chevron.compact.right`，两侧各一个
  空格。行高、内边距、分隔线与选中色是 SwiftUI `List` 在 macOS 上的默认值。[D；行高 R]
- **打开**：单击只选中；双击或回车打开（`contextAction(forSelectionType:)` 的主动作）；列表取得焦点而没有选中时选中第一行。
  失败时响一声。[D；双击与回车的触发 I]
- **最近条目从哪来**（`updateRecentItems` 0x6DE468、`-[IDEWorkspaceDocument recentEditorDocumentURLs]` 0x38F140）：按工作区
  记，最近的在前，再打开同一文档就移到最前；最多 **10** 条（用户默认 `IDERecentEditorDocumentsLimit`，≤ 0 时取 10，上限
  200）；当前打开的文档不排除。所以默认显示 8 条，Show All 最多再露出 2 条。页面出现时读一次，之后不跟随变化。[D]

## 提议方案

空标签的那一页（`ContentPlaceholderViewController` 的 `.noSelection` 状态）换成起始页，分三块：

1. **Open Quickly 搜索框**：页面顶部、水平居中的大号圆角框，左边放大镜、占位文字「Open Quickly」，尺寸、底色与光环照 Xcode（见上文度量）。输入满 3 个字符后，框下 5pt 浮出一块圆角的结果板（盖在最近列表上，Liquid Glass，macOS 26 之前用半透明材质），只在搜索框聚焦且窗口为 key 时显示：
   - **搜什么**：这个 Engine 的**全部镜像（按文件名）**，加上**已索引镜像里的对象**（顶层对象及其嵌套的子对象，按 `displayName`）。镜像相当于 Xcode 的文件，对象相当于符号；只读已索引的镜像，不为搜索触发任何索引。
   - **何时读**：第一次满 3 个字符时读一次（`imageNodes` 与 `indexedImagePathList()`，再对已索引的镜像并发 `objects(in:)`，同时最多 8 个），读完之前显示进度、读完后匹配；同一次输入期间复用，框清空或打开了结果就丢掉，不常驻内存。少于 3 个字符时照 Xcode 不更新查询、留着上一次的结果；框被清空时结果一并清掉。
   - **怎么排**：与现有 Open Quickly 相同的模糊匹配与排序（排序抽成共用的函数，侧栏的 Open Quickly 改用它、行为不变），截到前若干条。
   - **键盘**：↑ / ↓ 在结果里移动选中，回车打开选中的一项（默认第一项），Esc 清空输入；点击一项打开。修饰键同列表点击：⌥ 下一栏、⇧⌥ 新标签。打开对象走 `.open`，打开镜像走 `.openImage`（镜像页，会先索引）。打开之后清空输入：Xcode 用新页面替换这一页，RV 的这一页留在栏里给下一个空标签用。
2. **最近列表**（第 8 步起跟着侧栏分层）：侧栏停在镜像列表时标题是「Recent Images」，列这个 Engine 最近用过的镜像（行同搜索结果里的镜像行，打开是镜像页）；侧栏进到某个镜像后标题是「Recent Objects」，只列这个镜像的最近对象。标题行左边是标题（Xcode 的 `.title` 字体）、右边 11pt 强调色的「Show All」，展开后变「Show Less」，多于 8 行时才有；侧栏换层级或换镜像时 Show All 关掉。对象行：对象的图标、`displayName`，下面一行小字是 Engine 的图标加「Engine 名 〉 镜像名」，照 Xcode 的「SDK 〉 框架」。默认显示前 8 行（Xcode 的 `defaultRowCount`）。照 Xcode 单击只选中，双击或回车打开；修饰键同上。列表取得焦点而没有选中时选中第一行。
3. **读文件时**：仍是转圈加「Reading “…”…」，与现在相同；读完回到起始页。

**最近列表怎么记**（第 8 步改为按镜像分组）：每个文档在 `DocumentSession.open()` 里起一个记录器。用到一个镜像——侧栏进到它（`DocumentState.$currentImageNode`）、焦点栏显示它的镜像页、或焦点栏显示它的一个对象——就把它移到这个 Engine 的镜像列表最前；焦点栏每出现一个非空对象（`$selectedRuntimeObject`），还把这个对象移到它所在镜像的对象列表最前（按身份去重）。镜像最多 10 个、每个镜像的对象最多 10 个（都照 Xcode 的默认），镜像被挤出时连同它的对象一起丢；镜像路径一律按 `canonicalImagePath(_:)` 的形式记，与对象的 `imagePath` 一致；Engine 连上后才知道这个形式，之前按另一种写法记下的同一镜像，在下一次记录它时合并进来，别的项不改写。写进 `AppDefaults.recentRuntimeImagesByEngine`（键为 `Settings.Indexing.EngineReference.key(for:)`）。同一 Engine 上的几个窗口共用一份，起始页跟着这份存储与侧栏所在层级实时刷新。只在 macOS 记，iOS 不变。

**没有询问就采用的假设**（用户看效果时可以推翻）：

- **列表跟着侧栏分层**（第 8 步，用户定的）：侧栏的镜像列表相当于 Xcode 欢迎窗口那一层（最近的项目），进到一个镜像相当于打开一个项目（它的最近文件）。标题因此是「Recent Images」与「Recent Objects」，而不是 Xcode 的「Recent Files」。重开对象时按对象自己的语言显示（看过的 Generated Interface 不单独记）。
- **什么算「用过一个镜像」**（第 8 步，agent 定的）：侧栏进到它、在镜像页看它、看它的一个对象，三种都算。打开最近镜像显示镜像页（与搜索结果里的镜像行一致），不移动侧栏。
- **最近列表按 Engine 记**；切到别的 Engine 的窗口看到的是那个 Engine 的列表。镜像与每个镜像的对象各以 10 个为上限，没有清空按钮。Xcode 的页面只在出现时读一次，RV 的跟着存储实时刷新（另一窗口刚看的对象立刻出现）。
- **路径行写「Engine 名 〉 镜像名」**，图标是 Engine 的图标，照 Xcode 路径行「第一段的图标 + 各段名字」的形状。
- **存下来的对象不带 `children`**：列表只按身份列出与打开对象，子树可能有成千上万个节点，而存储每次变化都整文件重写。打开时内容区按身份重新取接口，不受影响；Inspector 的 Specialization 页对这样打开的泛型类型不列出本次会话里做过的特化，直到从侧栏重新选中它。
- **Open Quickly 框的范围是整个 Engine（镜像 + 已索引镜像的对象）**，不跟着侧栏当前镜像走，所以新窗口里也能用。⇧⌘O 的浮动 Open Quickly 也改成同一个范围（第 6 步，用户看过初版后要求）：Xcode 里两者是同一套搜索。
- **结果列表盖在最近列表的位置上**，而不是做成浮出的窗口；Xcode 也是在页面里浮在框下。结果行用起始页同一种行，56 高，与 Xcode Open Quickly 的行同高。
- **已知、不在本提案处理**：`AppDefaults` 的文件存储放在不分版本的 `Application Support/AppStorage`，Debug 版与发布版同时开着时会互相覆盖最近列表（书签与 Filter Scope 记忆同样如此）；每个用过的 Engine 键都会留下一份最多 10 个镜像、100 个对象的列表，不清理。两者列入后续项。
- **页面背景沿用内容区现在的背景**，起始页不另画背景。

### 非目标

- App 级的欢迎窗口（另一会话在做）。
- 改 ⇧⌘O 浮动 Open Quickly 的外观（范围在第 6 步改成与起始页相同）。
- 为搜索建 Engine 端的名字索引、或为搜索触发索引；没索引的镜像里的对象搜不到，打开镜像页后（会先索引）再搜就有。
- 最近列表的右键菜单、移除单条、清空、拖出；Xcode 的 `.empty(message:)` 样式与错误横幅（`errorBanner`，缺文件时用）。
- iOS、visionOS 的起始页。
- 搜索 C++ 对象（`objects(in:includesCPlusPlusObjects:)` 默认不含，与 Find 一致）。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentPlaceholderViewController.swift` · `ContentPlaceholderViewController` | 修改 | `.noSelection` 时显示起始页：搜索框、标题行、列表；`.readingFile` 时照旧转圈，并让出起始页里的键盘焦点；第 8 步标题跟着 `recentItemsTitle` | 空标签的页面就是它 | 1、3、4、8 |
| 同上 · 私有嵌套的 `OpenQuicklyField`、`FocusReportingTextField`、`ItemCellView` | 新增 | 起始页的大号圆角搜索框（放大镜 + 无边框文本框，光环只在 key 窗口里输入时亮）与列表行 | 只有这一个控制器用，按 `RuntimeViewerUsingAppKit/AGENTS.md` 作它的私有嵌套类型 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentPlaceholderViewModel.swift` · `ContentPlaceholderViewModel` | 修改 | 加 `editorPaneID`（第 1 步起由协调器传入）与 `recentItems` 输出（第 1 步为空）；之后加最近列表、Show All、搜索文本、结果、选中、打开；第 8 步列表跟着 `$currentImageNode` 取镜像或这个镜像的对象，加 `recentItemsTitle`；`.readingFile` 逻辑不变 | 空标签那一页的 VM | 1–4、8 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentStartPageItemCellViewModel.swift` · `ContentStartPageItemCellViewModel` | 新增 | 一行（对象或镜像）的 `Appearance`：图标、名字、路径图标与路径各段；镜像行的路径段是装着它最近那个 bundle 的文件夹 | 最近列表与搜索结果共用的行 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/RuntimeImage/RuntimeImageKind.swift` · `RuntimeImageKind` | 修改 | 加内部的 `isBundleDirectoryName(_:)`，复用按扩展名认 bundle 的规则 | 镜像行的路径段要跳过 bundle 内部的目录 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/RecentRuntimeImages.swift`（第 8 步由 `RecentRuntimeObjects.swift` 改名） · `RecentRuntimeImages` | 新增 | 纯逻辑：把一个镜像记到列表最前、把一个对象记到它镜像的列表最前、按身份去重、截到上限、镜像被挤出时连同对象、合并同一镜像的另一种写法、空路径不记 | 可单测的记录规则 | 2、8 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/RecentRuntimeImage.swift` · `RecentRuntimeImage` | 新增 | 存储里的一项：镜像的规范路径与它的最近对象 | 按镜像分组存 | 8 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/RecentRuntimeImagesRecorder.swift`（第 8 步由 `RecentRuntimeObjectsRecorder.swift` 改名） · `RecentRuntimeImagesRecorder` | 新增 | 跟着文档的 `$selectedRuntimeObject`、`$currentImageNode`、焦点栏的镜像页与 Engine，写 `AppDefaults` | 一个文档一个记录器 | 2、8 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Document/DocumentSession.swift` · `DocumentSession` | 修改 | `open()` 里启动记录器（macOS） | 每个窗口都记 | 2 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Objects/RuntimeObject.swift` · `RuntimeObject.withChildren(_:)` | 新增 | 换掉 `children` 的拷贝，与 `withImagePath(_:)` 并列 | 存最近对象时去掉子树，不在 App 一侧逐字段复制（以后加字段不会悄悄丢） | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Storage/AppDefaults.swift` · `AppDefaults` | 修改 | 新增 `recentRuntimeImagesByEngine: [String: [RecentRuntimeImage]]`（`@ResilientFileStorage`；第 2 步时是 `recentRuntimeObjectsByEngine`，第 8 步换掉） | 按 Engine 存盘 | 2、8 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/OpenQuickly/OpenQuicklyCatalog.swift`（第 6 步从 `Content/` 挪来） · `OpenQuicklyCatalog`、`RuntimeImageNode.leafImagePaths` | 新增 | 一次搜索的条目（镜像 + 已索引镜像的对象，连同嵌套的）、从 Engine 读（同时最多 8 个镜像）、匹配与截断 | 起始页搜索框的范围与匹配 | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentPlaceholderViewController.swift` · `OpenQuicklyField`、`SearchResultsTableView`、`EmphasizedTableRowView`、`StartPageView`，`NSTextFieldDelegate`、`NSTableViewDelegate`、`EditorPaneContent` 的一致性 | 新增 / 修改 | 搜索框照 Xcode 重画（胶囊加外扩的光环）；结果板是 `FloatingPlatterView` 里不取焦点、选中照常着色的表；框的按键经文本框委托；编辑栏取得焦点时进搜索框；点页面空白处取焦点 | 第 4 步的界面 | 4 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/OpenQuickly/OpenQuicklySearch.swift` · `OpenQuicklySearch` | 新增 | 一次搜索：第一次匹配时读目录、`end()` 丢掉，匹配在主线程之外 | 起始页与 ⇧⌘O 共用一套搜索 | 6 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/OpenQuickly/OpenQuicklyViewModel.swift` · `OpenQuicklyViewModel` | 新增 | ⇧⌘O 浮动条的 VM：每个词的匹配连同这个词一起输出，打开、关掉即结束搜索、换 Engine 结束搜索 | 窗口一层的 Open Quickly | 6 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/EditorArea.swift` · `shownForm(of:)` | 新增 | 按身份找正显示某对象的标签、取它的形态 | 起始页与 ⇧⌘O 打开对象时共用 | 6 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentStartPageItemCellViewModel.swift` · `ContentStartPageItemOpening` | 新增 | 原 `ContentPlaceholderViewModel.ItemOpening` 提为顶层类型 | 两个 VM 共用 | 6 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentStartPageItemCellView.swift` · `ContentStartPageItemCellView` | 新增 | 原起始页控制器的私有 `ItemCellView` 提为 App 里的共用视图 | 起始页与 ⇧⌘O 浮动条两处用 | 6 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift`、`MainCoordinator.swift`、`App/MainMenuController.swift` | 修改 | ⇧⌘O 的命令、浮动条与绑定挪到窗口；协调器创建 `OpenQuicklyViewModel`；菜单项指向窗口的命令 | 有文档窗口时总可用 | 6 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Sidebar/RuntimeObject/SidebarRuntimeObjectListViewController.swift` | 修改 | 去掉它自己的 `QuickActionBar` 与 `openQuickly(_:)` | 命令归窗口 | 6 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/OpenQuickly/OpenQuicklyRanking.swift`（第 7 步从 `Filtering/` 挪来） · `OpenQuicklyRanking` | 新增 | 从 `SidebarRuntimeObjectListViewModel.rankByRelevance` 抽出的排序 | 两处 Open Quickly 同一排序 | 4、7 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectListViewModel.swift` | 修改 | 第 4 步改调 `OpenQuicklyRanking`；第 7 步删掉 Open Quickly 的输入输出（`runtimeObjectClickedForOpenQuickly`、`searchStringForOpenQuickly`、`runtimeObjectsForOpenQuickly`、`selectRuntimeObject`）与按需物化机制（字符串索引、物化表、过滤任务、`HaystackBuilder`） | 侧栏不再有自己的 Open Quickly | 4、7 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectViewModel.swift` | 修改 | 删掉只为 Open Quickly 存在的 `invalidateNodeDerivedState()` 钩子；重载失败或镜像未加载时照旧清空 `nodes`；「镜像是否已加载」抽成可覆写的 `isImageLoaded()`，供测试走 `.notLoaded` | 同上 | 7 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppTestingSupport/TestRuntimeEngine.swift` · `makeUnconnected(engineID:)` | 新增 | 还没连接的私有本地 Engine | 测「Engine 还没列出镜像时」的搜索 | 7 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectCellViewModel.swift` | 修改 | 删掉 `forOpenQuickly`（16 pt 字号、24 pt 图标、不可点的 Private tag）与 `haystack(for:)` | 同上 | 7 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/RuntimeObject/RuntimeObjectCellTag.swift` | 修改 | `privateDeclaration(isClickable:)` 收成 `privateDeclaration`（只剩可点的一种） | 同上 | 7 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/OpenQuicklyMaterializationBoundsTests.swift`、`OpenQuicklyLazyConstructionTests.swift` | 删除 | 只测侧栏 Open Quickly 的物化 | 被测的代码已删 | 7 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/SidebarRuntimeObjectListViewModelTests.swift`、`SidebarReloadInvalidationTests.swift`、`SidebarPrivateDeclarationTagTests.swift`、`SidebarFilterPerformanceBaselineTests.swift`、`SidebarCellAppearanceTests.swift` | 修改 | 去掉 Open Quickly 的用例与实参；重载失败的那条改为直接断言 `nodes` 被清空；单元格「模糊模式」的性能基线删掉（侧栏没有模糊匹配） | 同上 | 7 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift` · `ContentCoordinator` | 修改 | 建占位 VM 时传 `editorPaneID` | 打开前聚焦这一栏 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/…` | 新增 | `ContentStartPageItemCellViewModelTests.swift`（第 1 步）、`RecentRuntimeImagesTests.swift`（第 8 步由 `RecentRuntimeObjectsTests.swift` 改名，含记录器一组）、`ContentStartPageViewModelTests.swift`（第 8 步加分层一组，列对象的用例先让侧栏进到镜像）、`OpenQuicklyCatalogTests.swift`（含加载一组） | 每步的行为清单 | 1–4、8 |
| `RuntimeViewerUsingAppKit/AGENTS.md` | 修改 | 编辑区一节加一句：空标签显示起始页、最近列表按 Engine 记（第 5 步；第 8 步改述为跟着侧栏分层、按镜像分组）；「大数据集的惰性 cell ViewModel」一节去掉侧栏 Open Quickly 的物化写法，改述「先搜值索引、只为列出的行建 cell ViewModel」，cell 复用的示例换成现行代码（第 7 步） | 规则随代码 | 5、7 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记草案 | 索引 | 0 |

## 架构图

改了什么：

```text
RuntimeViewerAppCore
├── Content/
│   ├── ContentPlaceholderViewModel        ~ + editorPaneID, recents by sidebar level, search, open
│   └── ContentStartPageItemCellViewModel  + row appearance (object | image), ContentStartPageItemOpening
├── OpenQuickly/
│   ├── OpenQuicklyCatalog                 + images + objects of indexed images, match
│   ├── OpenQuicklyRanking                 + ranking (taken from the sidebar)
│   ├── OpenQuicklySearch                  + one search: catalog on first match, end()
│   └── OpenQuicklyViewModel               + ⇧⌘O bar: matches per term, open, dismiss (macOS)
├── EditorArea/
│   ├── EditorArea                         ~ + shownForm(of:)
│   ├── RecentRuntimeImage                 + an image's canonical path and its recent objects
│   ├── RecentRuntimeImages                + record images and objects / dedupe / cap 10 × 10
│   └── RecentRuntimeImagesRecorder        + follows $selectedRuntimeObject, $currentImageNode, image pages
├── Sidebar/RuntimeObject/
│   ├── SidebarRuntimeObjectListViewModel  − its own Open Quickly (inputs, outputs, materialization)
│   ├── SidebarRuntimeObjectViewModel      − invalidateNodeDerivedState()
│   └── SidebarRuntimeObjectCellViewModel  − forOpenQuickly, haystack(for:)
├── RuntimeObject/RuntimeObjectCellTag     ~ privateDeclaration(isClickable:) → privateDeclaration
├── Document/DocumentSession               ~ open() starts the recorder (macOS)
└── Storage/AppDefaults                    ~ + recentRuntimeImagesByEngine
RuntimeViewerUsingAppKit (app)
├── Content/ContentPlaceholderViewController  ~ start page layout and bindings
│   └── OpenQuicklyField                      + Xcode-sized rounded query field (private)
├── Content/ContentStartPageItemCellView      + icon, name, path row (start page and ⇧⌘O bar)
├── Content/ContentCoordinator                ~ passes editorPaneID
├── Main/MainWindowController                 ~ + ⇧⌘O command and QuickActionBar
├── Main/MainCoordinator                      ~ + OpenQuicklyViewModel
├── App/MainMenuController                    ~ Open Quickly… targets the window
└── Sidebar/RuntimeObject/SidebarRuntimeObjectListViewController  − QuickActionBar, openQuickly(_:)
```

数据流：

```text
the focused pane shows an object or an image page, the sidebar goes into an image
  → DocumentState.$selectedRuntimeObject / $editorArea / $currentImageNode
  → RecentRuntimeImagesRecorder → RecentRuntimeImages.recording(_:in:) / recordingImage(at:in:)
  → AppDefaults.recentRuntimeImagesByEngine[engineKey]     [canonical image paths]
  → ContentPlaceholderViewModel (every empty pane of every window on the engine)
       + DocumentState.$currentImageNode: nil → Recent Images; an image → that image's Recent Objects
  → rows → ContentPlaceholderViewController

typing in the start page's field (3 characters or more)      typing in the ⇧⌘O bar (1 character or more)
  → ContentPlaceholderViewModel                                → OpenQuicklyViewModel (MainWindowController's QuickActionBar)
                      ↘                                      ↙
                        OpenQuicklySearch.matches(for:limit:)   [one per page / bar; nothing read while the engine lists no image]
                          → OpenQuicklyCatalog.load(imagePaths:from:)   [once per search, 8 images at a time]
                               imageNodes + indexedImagePathList() + objects(in:) per indexed image
                          → OpenQuicklyCatalog.matches(for:limit:) → FilterEngine + OpenQuicklyRanking
  → results → Return / click                                   → matches of the bar's current term → Return / click
  → .focusEditorPane(paneID) → .open(shownForm ?? object, in:) | .openImage(path, in:)
search ends (field emptied, page starts over / bar closed, item opened, engine switched) → OpenQuicklySearch.end()
```

## 详细设计

### 最近列表

第 8 步起按镜像分组（第 2 步时是每个 Engine 一列对象，`RecentRuntimeObjects` / `recentRuntimeObjectsByEngine`）：

```swift
/// An image an engine's windows worked in, and the objects of it their editor panes showed.
public struct RecentRuntimeImage: Codable, Hashable, Sendable {
    public let imagePath: String                      // RuntimeEngine.canonicalImagePath(_:) form
    public let objects: [RuntimeObject]               // most recent first, without children
}

/// One engine's recent images, each with its recent objects, kept in
/// `AppDefaults.recentRuntimeImagesByEngine` under the engine's key; the same keying as the
/// Filter Scope memory (`RuntimeObjectScopeMemory`).
struct RecentRuntimeImages: Hashable, Sendable {
    static let maximumImageCount = 10                 // NSDocumentController's default
    static let maximumObjectCountPerImage = 10        // Xcode's recent files of a workspace
    let engineKey: String
    init(engineKey: String)
    init(engine: RuntimeEngine)                       // Settings.Indexing.EngineReference.key(for:)

    func images(in imagesByEngine: [String: [RecentRuntimeImage]]) -> [RecentRuntimeImage]
    func objects(ofImageAt imagePath: String, in imagesByEngine: [String: [RecentRuntimeImage]]) -> [RuntimeObject]

    /// `object` first in its image and its image first, or `nil` when both are first already, the
    /// object in that form: `==` on objects is identity only, so the caller cannot compare dictionaries.
    func recording(_ object: RuntimeObject, in imagesByEngine: [String: [RecentRuntimeImage]]) -> [String: [RecentRuntimeImage]]?
    /// The image first, keeping its objects, or `nil` when it is first already.
    func recordingImage(at imagePath: String, in imagesByEngine: [String: [RecentRuntimeImage]]) -> [String: [RecentRuntimeImage]]?
    /// The entries a path `canonicalImagePath` turns into `imagePath` folded into the image's
    /// entry, or `nil` when none is filed; no other entry is touched.
    func foldingOtherSpellings(of imagePath: String, in imagesByEngine: [String: [RecentRuntimeImage]],
                               canonicalImagePath: (String) -> String) -> [String: [RecentRuntimeImage]]?

    /// Everything but `children`.
    static func listedForm(of object: RuntimeObject) -> RuntimeObject
    /// Same objects in the same forms (`hasSameContent(as:)` element by element).
    static func listsAreAlike(_ firstObjects: [RuntimeObject], _ secondObjects: [RuntimeObject]) -> Bool
}

/// Records every image the document uses and every object its focused pane shows.
@MainActor
final class RecentRuntimeImagesRecorder {
    init(documentState: DocumentState)
}
```

`AppDefaults`：

```swift
/// The images each engine's windows used, most recent first, each with the objects of it their
/// editor panes showed, keyed by `Settings.Indexing.EngineReference.key(for:)`.
@ResilientFileStorage
public var recentRuntimeImagesByEngine: [String: [RecentRuntimeImage]]
```

记录器订阅三处：`$selectedRuntimeObject`，先按身份 `distinctUntilChanged()`（同一对象换了形态——比如加了特化——不算再看一次，不移到最前），再去掉 `nil`，交给 `recording`；`$currentImageNode` 的路径与焦点栏当前标签的镜像页路径（`$editorArea` 的 `focusedPane.activeTab.imagePath`），各自去重、去掉 `nil`，转成规范路径交给 `recordingImage`。每来一个，**当时**读 `documentState.runtimeEngine` 取键，读存储，先用 `foldingOtherSpellings` 把这个镜像的另一种写法合并进来，再交给 `recording` / `recordingImage`，两者有一处变了才写回。不预先把 Engine 与对象配对：`.switchEngine` 先换 session、再清空编辑区并把侧栏退回镜像列表，配对的写法会把旧对象记到新 Engine 下。存储的写是排在队列上的异步 barrier，读会等前面的写完成，所以路由一触发、紧接着读就能看到结果（测试的否定断言靠这一点，不用固定等待）。

起始页的 VM 把 Engine 与 `$currentImageNode` 的路径 `combineLatest`，再 `flatMapLatest` 订阅存储的 `$` 投影：侧栏在镜像列表时取本 Engine 的镜像路径，在一个镜像里时按它的规范路径取这个镜像的对象，按内容去重（对象按 `listsAreAlike`），别的 Engine 的写入不会让它重建。侧栏的路径与对象的 `imagePath` 写法可能不同（模拟器进程的路径要加 `DYLD_ROOT_PATH`），所以两边都按规范路径比；侧栏路径的规范形式在存储每次变化时重算（Engine 连上后才知道这个形式，又没有「问到了」的通知，所以要到下一次记录才赶上），读的时候不改写存储。路径栏也是这样把规范路径对回镜像树的节点，所以用规范路径打开镜像页没有问题。列表的来源（Engine、镜像）一变就关掉 Show All；标题跟着来源变（`recentItemsTitle`）。

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

对象行：图标 `IconDescriptor.runtimeObject(kind, size:)`，标题 `displayName`，路径图标 `.runtimeEngine(engineID:)`，路径 `[engine.source.description, 镜像文件名]`。镜像行（搜索结果里，以及第 8 步起侧栏停在镜像列表时的 Recent Images）：图标 `.imageKind(RuntimeImageKind(ofImageAt:))`，标题镜像文件名，路径 `[engine 名, 上级目录名]`。行在创建后不变，没有 `@RxObserved`，按 `item` 判断是否同一行（`Differentiable`）。

### ViewModel

`ContentPlaceholderViewModel(documentState:router:editorPaneID:)`，`editorPaneID` 为 `nil` 时用焦点栏（与 `ContentTextViewModel` 一致，旧调用点与测试不用改）。

```swift
public struct ItemOpening {                      // a row opened, and where
    public let item: ContentStartPageItemCellViewModel
    public let destination: SelectionRoute.Destination
}

@MemberwiseInit(.public)
public struct Input {                            // every signal defaults to .empty()
    public let pageWillAppear: Signal<Void>      // the pane's one page shows again: Show All off, search cleared
    public let showAllClicked: Signal<Void>
    public let recentItemOpened: Signal<ItemOpening>            // double-click or Return
    public let searchText: Signal<String>                       // every change of the field
    public let searchSelectionMoved: Signal<Int>                // −1 up, +1 down
    public let searchCommitted: Signal<SelectionRoute.Destination>   // Return, ⌥↩
    public let searchResultOpened: Signal<ItemOpening>          // a click on a result
    public let searchCancelled: Signal<Void>                    // Escape
}

public struct Output {
    public let placeholder: Driver<Placeholder>
    public let recentItems: Driver<[ContentStartPageItemCellViewModel]>   // cut to defaultRecentRowCount unless Show All
    public let showAllButton: Driver<ShowAllButton>                       // hidden / showAll / showLess
    public let search: Driver<Search>                                     // inactive / loading / results([…], selectedIndex:)
    public let clearSearchField: Signal<Void>
}
```

打开：`selectionRouter.trigger(.focusEditorPane(editorPaneID))`，再 `.open(formOnScreen(of: object), in: destination)` 或 `.openImage(path, in: destination)`。`formOnScreen(of:)` 用 `EditorArea.tabID(showing:)`（先焦点栏、再按布局顺序，与「新标签前先切到已显示它的标签」同一个查找）找到正显示这个对象的标签，取那里的形态。打开搜索结果后清空搜索状态并让视图清空输入框。

一栏只有一个起始页（`ContentCoordinator` 懒建、所有空标签共用），Xcode 则每个空编辑器一个新页面。所以页面每次「重新开始」都复位：Show All 关掉、列表不选中、搜索清空。重新开始有两种：页面重新放进这一栏（`viewWillAppear` → `pageWillAppear`），以及这一栏换了当前标签（VM 跟着 `$editorArea` 里这一栏的 `activeTabID`）——后者覆盖两个空标签之间切换，那时栏里的内容场景不变，`viewWillAppear` 不会触发。列表的选中跟着对象走：视图记着每行代表的对象，列表变化前后按对象恢复选中。

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

- 空标签不再显示「Select a runtime object」，改为起始页：Open Quickly 搜索框、最近列表（有记录时）。侧栏停在镜像列表时列 Recent Images，进到某个镜像后列这个镜像的 Recent Objects。
- 新增：在起始页的搜索框里可以按名字找镜像与已索引镜像里的对象，回车或点击打开；最近用过的镜像、这个镜像里最近看过的对象出现在列表里，打开回到它。
- 改变：⇧⌘O 的浮动 Open Quickly 搜整个 Engine（镜像 + 已索引镜像的对象）、从 1 个字符起，有文档窗口时总可用，不再只搜侧栏当前镜像；它的行与起始页的相同（图标、名字、路径行）。
- 不变：侧栏（除了不再有自己的 Open Quickly）、读文件时的占位、Load Frameworks 页。

### 可发现性

起始页就是空标签的页面，新窗口与 ⌘T 一打开就看到，不需要设置项；默认开启。

### 数据与配置兼容

新增一个存储文件 `AppStorage/recentRuntimeImagesByEngine.json`（`@ResilientFileStorage`，读不出就当空）；不碰已有文件。降级到旧版本时这个文件被忽略。第 2–7 步写的 `recentRuntimeObjectsByEngine.json` 只在本功能分支的构建里出现过、从未发布，第 8 步不迁移它：用过那些构建的机器上会留一个没人读的旧文件，起始页的最近列表从空开始。

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
2. **记录最近对象并列出**（已完成） —— `RecentRuntimeObjects`、`RecentRuntimeObjectsRecorder`、`AppDefaults.recentRuntimeObjectsByEngine`、`DocumentSession.open()`、VM 的 `recentItems` 跟随存储
   - 行为：焦点栏显示一个对象时它被记到这个 Engine 的列表最前
   - 行为：再次显示列表里已有的对象时它移到最前、不重复
   - 行为：列表最多保留 10 个（Xcode 的默认），最旧的先丢
   - 行为：对象不带子树存下，只是子树变了的同一对象不重写
   - 行为：焦点栏的对象换了形态（加了特化）不移到最前
   - 行为：空标签不记任何东西
   - 行为：不同 Engine 各有各的列表
   - 行为：起始页列出这个 Engine 的最近对象
   - 行为：同一 Engine 上另一个窗口看了新对象，这一页的列表随之更新
   - 行为：同一 Engine 上的两个窗口记进同一份列表
   - 行为：别的 Engine 上的记录不让这一页的列表重建
   - 行为：窗口换到别的 Engine 后列出那个 Engine 的最近对象
   - 行为：文档会话打开后开始记录、关闭后停止
3. **Show All 与打开最近对象**（已完成） —— VM 的 `pageWillAppear`、`showAllClicked`、`recentItemOpened`、`formOnScreen(of:)`，视图的标题行与按钮、`RecentItemsTableView`（双击与回车、点击取焦点、键盘取焦点时选第一行）、按 Xcode 度量排版
   - 行为：多于 8 个时只显示前 8 行，标题行有「Show All」
   - 行为：不多于 8 个时没有按钮
   - 行为：按「Show All」显示全部、按钮变「Show Less」，再按收回
   - 行为：打开一行（双击或回车）先聚焦这一栏、再在这一栏的当前标签打开该对象
   - 行为：⌥ 打开在下一栏，⇧⌥ 在新标签
   - 行为：已有标签显示着同一对象时，用那个标签里的形态打开（不把它换成存下的无子树形态）
   - 行为：单击只选中、不打开（目视）
   - 行为：Show All 在列表变化时保持，页面再次出现、或这一栏换到另一个空标签时关掉
   - 行为：已有标签以别的语言（Generated Interface）显示同一对象时，也用那个标签里的形态打开
   - 行为：列表被别的窗口重排时，选中跟着对象走（目视）
   - 行为：macOS 27 上单击一行后列表取得焦点、回车打开它（目视；`mouseDown` 覆写，同 `StatefulOutlineView`）
   - 行为：用键盘把焦点移进列表且没有选中时选中第一行；点击取焦点不先闪第一行（目视）
   - 行为：Show Less 收掉了选中行时，取得焦点的列表选中第一行（目视）
4. **Open Quickly 搜索框**（已完成） —— `OpenQuicklyCatalog`、`OpenQuicklyRanking`、侧栏改用共用排序、VM 的搜索输入输出、视图的键盘处理、照 Xcode 重画的搜索框、浮在框下的结果板、`EditorPaneContent` 的焦点、点空白处取焦点
   - 行为：输入少于 3 个字符时不搜索；已有结果时留着上一次的结果
   - 行为：搜索中删到不足 3 个字符时，那次搜索照常完成（不会一直停在读取中）
   - 行为：窗口换到别的 Engine 时结束搜索
   - 行为：清空输入时结果消失
   - 行为：结果包含名字匹配的镜像与已索引镜像里的对象
   - 行为：未索引镜像里的对象不在结果里，搜索也不触发索引
   - 行为：排序与侧栏的 Open Quickly 相同（命中自身名字、位置靠前、名字短的在前）
   - 行为：读取条目期间搜索框尾部转圈，读完显示结果（转圈要读得慢的目录才出现，没有测试，目视）
   - 行为：回车打开第一项；↓ / ↑ 移动选中后回车打开选中项
   - 行为：最新查询的结果还没到时按回车（包括第一次读目录期间），等结果到了打开其中选中的一项，不打开旧查询的结果
   - 行为：打开镜像结果显示该镜像的镜像页
   - 行为：打开结果或按 Esc 后输入框清空、结果消失，回到最近列表
   - 行为：起始页所在的栏取得焦点（⌘T 新标签、切到这一栏）时，键盘焦点落进搜索框（`EditorPaneContent.focusableView`，照 Xcode 的 `shouldFocusSearchField`；目视）
   - 行为：点页面空白处让搜索框失去焦点，焦点留在这一栏、这一栏成为焦点栏（目视）
   - 行为：没有结果时 ↑ / ↓ 照常移动输入框里的光标（目视）
   - 行为：焦点在页面空白处时打字，字进搜索框接在原有文字后面；Tab 不停在页面空白处（目视）
   - 行为：搜索框照 Xcode 的度量：高 47、连续圆角 24、没聚焦时的底色、聚焦且窗口为 key 时去底色加 3pt 强调色光环（不透明度 0.6，一半在框外）、20pt medium、放大镜框在 x = 16、文字从 62 起（目视）
   - 行为：侧栏 Open Quickly 的排序不变（既有测试照旧通过）
5. **文档**（已完成） —— `RuntimeViewerUsingAppKit/AGENTS.md`、索引、本提案的决策日志

6. **⇧⌘O 与起始页同一个搜索**（已完成） —— 搜索逻辑抽成共用的 `OpenQuicklySearch`（`RuntimeViewerAppCore/OpenQuickly/`，`OpenQuicklyCatalog` 一并挪过去），起始页 VM 改用它；新增窗口一层的 `OpenQuicklyViewModel`；⇧⌘O 的命令从侧栏对象列表挪到 `MainWindowController`，浮动条（UIFoundation 的 `QuickActionBar`）列出与起始页相同的行（共用的 `ContentStartPageItemCellView`）；`ItemOpening` 改为顶层的 `ContentStartPageItemOpening`
   - 行为：⇧⌘O 在有文档窗口时总是可用，不再要求侧栏列着某个镜像的对象
   - 行为：浮动条搜这个 Engine 的镜像名与已索引镜像里的对象，与起始页相同，不为搜索触发索引
   - 行为：一个字符起就搜（Xcode 只给起始页写死了 3 个字符）；空输入不列任何东西
   - 行为：浮动条只收下与当前输入对应的结果，不用旧输入的结果顶替
   - 行为：选中一项在焦点栏的当前标签打开（⌥ 下一栏、⇧⌥ 新标签），镜像打开镜像页
   - 行为：浮动条关掉、打开了一项或窗口换到别的 Engine 时结束这次搜索：还在作答的那个词一并丢掉，目录不会被重新读起来
   - 行为：从别的 Engine 读来的结果不会标成当前 Engine 的
   - 行为：Engine 还没列出任何镜像时什么也不读、没有匹配，之后的输入再读
   - 行为：浮动条只把与它当前这个词对应的结果交给 `QuickActionBar`（窗口控制器里按词核对，目视）
   - 行为：起始页的搜索照旧（既有测试照旧通过）
7. **删掉侧栏自己的 Open Quickly**（已完成） —— `SidebarRuntimeObjectListViewController` 的 `QuickActionBar` 与命令、`SidebarRuntimeObjectListViewModel` 的 Open Quickly 输入输出与按需物化机制、只为它存在的测试与文档段落
   - 行为：侧栏对象列表的其余行为不变（既有测试照旧通过）
8. **最近列表跟着侧栏分层**（已完成） —— 用户看过第 1–7 步后要求：侧栏停在镜像列表时只列镜像，进到镜像里才列对象，且只列这个镜像的；搜索框不分层。存储改为按 Engine 记最近镜像、每个镜像带最近对象（`RecentRuntimeImage`、`RecentRuntimeImages`、`AppDefaults.recentRuntimeImagesByEngine`，记录器改名 `RecentRuntimeImagesRecorder`、多跟两处）；VM 跟着 `$currentImageNode` 取列表、出标题；视图的标题绑定 `recentItemsTitle`
   - 行为：焦点栏显示一个对象时，它的镜像移到最前、它在这个镜像的列表里移到最前
   - 行为：侧栏进到一个镜像时，这个镜像移到最前，原有的对象留着
   - 行为：焦点栏显示一个镜像页时，这个镜像移到最前
   - 行为：已在最前的镜像再记一次不重写；对象与镜像都在最前、对象形态相同时不重写
   - 行为：最前的对象所在镜像不在最前时，再看它会把镜像移到最前
   - 行为：不同镜像的对象分开记
   - 行为：每个 Engine 最多 10 个镜像，每个镜像最多 10 个对象；镜像被挤出时连同它的对象一起丢
   - 行为：侧栏停在镜像列表时，起始页列这个 Engine 的最近镜像，标题「Recent Images」
   - 行为：侧栏进到一个镜像时，起始页只列这个镜像的最近对象，标题「Recent Objects」
   - 行为：侧栏换到另一个镜像或回到镜像列表时，列表与标题随之换掉，Show All 关掉（从镜像 A 换到镜像 B 也关）
   - 行为：窗口在一个镜像里换到别的 Engine 后，列那个 Engine 的最近镜像、标题回到 Recent Images（换 Engine 时侧栏回到镜像列表）
   - 行为：打开一个最近镜像显示它的镜像页，侧栏不动
   - 行为：镜像路径按规范形式记与比较：模拟器进程的侧栏路径与对象的 `imagePath` 写法不同时也记成同一个镜像、列出它的对象
   - 行为：Engine 连上后才知道路径写法，之前按另一种写法记下的同一镜像，在下一次记录它时合并进来；别的项一概不改写（共用一个键、根路径不同的两个 Engine 互不改坏对方的记录）
   - 行为：侧栏在问到写法之前进的镜像，起始页在下一次记录之后列出它的对象（没有「问到了」的通知，赶不上更早）
   - 行为：路径为空的对象或镜像不记（会列成一个没有名字的镜像）
   - 行为：在镜像里换 Engine 时，旧 Engine 的镜像与对象不会记到新 Engine 下
   - 行为：搜索框不分层，两层都搜镜像与已索引镜像里的对象（既有搜索测试照旧通过）
   - 行为：第 2 步的其余记录规则照旧（去掉子树、换形态不移到最前、空标签不记、两个窗口同一份、会话开着才记）

只能在界面上看到的行为（布局、尺寸、颜色、焦点环、结果浮层的位置）在 ViewModel 层测不到，列为目视验证。

### 后续项

- `AppDefaults` 的文件存储按版本分目录（Debug 版与发布版现在共用 `Application Support/AppStorage`，同时开着会互相覆盖最近列表、书签与 Filter Scope 记忆）。
- 不再用的 Engine 键的最近列表清理（每个用过的文件、设备、进程名各留一份，最多 10 个镜像、100 个对象）。
- 最近列表变空而焦点在列表上时，焦点留在被隐藏的列表上（SP.18）。
- 路径栏的镜像节点表在 Engine 问到 `DYLD_ROOT_PATH` 之前建好时不会重算，模拟器进程的对象找不到镜像节点（基线上就有，见已裁决清单「同类排查」）。
- Engine 问到 `DYLD_ROOT_PATH` 时发一个通知（Core 一侧），起始页与路径栏据此立即重算，不必等下一次记录（SP.17）。
- 搜索没索引的镜像里的对象：需要 Engine 端按名字找对象的命令，或用户同意的索引。
- 最近列表的右键菜单、移除单条、清空、拖出；Xcode 的错误横幅与 `.empty(message:)` 样式。

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
| 2026-11-21 | 最近列表按 Engine 记、只记对象 | 相当于 Xcode 按工作区记最近文件；镜像页是对象的入口而非内容，记进去会挤掉对象。上限原定 50，逆向后改为 Xcode 的 10（见下）。 |
| 2026-11-21 | 扩展 `ContentPlaceholderViewModel` 而不是另起一页 | 它本来就是「空标签这一页」的 VM，读文件的占位与起始页互斥地出现在同一位置，扩展比在协调器里多一个场景改动小。 |
| 2026-11-21 | 第 1 步审查后调整 | 两位审查者指出：搜索框只有这一个控制器用，按规则改为它的私有嵌套类型（原计划放进 `RuntimeViewerUI`）；行模型与 `editorPaneID` 的传入提前到第 1 步作骨架，改动地图随之更新；镜像行的路径段原取上一级目录，框架会显示成 `Versions` 下的「C」，改为装着最近那个 bundle 的文件夹；另补了切到读文件时让出焦点、光环只在 key 窗口亮、输入时点框体不全选、文本框不抢宽度。 |
| 2026-11-21 | 读文件开头的一瞬仍显示起始页，不另处理 | `.readingFile` 照旧按 `LoadingPlaceholderTiming.appearsAfter` 节流，读得快的文件不闪转圈；代价是慢的文件在出现转圈前先显示起始页，与原先先显示提示文字、再换成「Reading…」相同。 |
| 2026-11-21 | 按逆向结果对齐 Xcode | Xcode 27.2 的度量写进「前期调研」。随之改的：最近列表上限 10、默认 8 行、按钮在「Show All」与「Show Less」之间切换；单击只选中，双击或回车打开（原写点击打开）；满 3 个字符才搜索，少于 3 个时留着上一次的结果；结果板浮在框下 5pt，只在搜索框聚焦且窗口为 key 时显示。 |
| 2026-11-21 | 第 2 步审查后调整 | 两位审查者指出：存储每次选中都整文件重写，带着完整子树会卡主线程——改为只存去掉 `children` 的对象；别的 Engine 的写入会让每个起始页重建——改为只比较本 Engine 那一段；同一对象换了形态会被顶到最前——记录器先按身份去重；否定断言靠固定等待——改为利用存储「读等写」的顺序立即读；补了正例、双窗口与切换 Engine 的测试；提案的详细设计照实际写法同步。Debug 版与发布版共用存储目录、Engine 键不清理两条记为已知、列入后续项。 |
| 2026-11-21 | 第 2 步第二轮审查后调整 | `listedForm(of:)` 改用 Core 新增的 `RuntimeObject.withChildren(_:)`；一条测试不再依赖调度细节；记录器的注释写明「焦点换到显示同一对象的另一栏」与「同一对象换形态」都不算再看一次，中间看过别的对象后才会再记。审查者另提醒：第 3 步打开存下的无子树对象时，若已有标签显示同一对象，要用那个标签里的形态，免得把它换成无子树的形态——记进第 3 步的行为清单。 |
| 2026-11-21 | 第 3 步审查后调整 | 审查者指出：macOS 27 上单击行只选中、不让列表取得焦点，回车落到搜索框——列表照 `StatefulOutlineView` 加只调 `super` 的 `mouseDown` 覆写；取得焦点时选第一行改为只在键盘取焦点时做，免得点击时先闪第一行；Show Less 收掉选中行后补选第一行；一栏的起始页被所有空标签复用，Show All 与选中会跨标签残留——页面每次出现时复位；`formOnScreen(of:)` 改用 `EditorArea.tabID(showing:)` 的查找顺序；输入名与提案同步（`recentItemOpened`、`ItemOpening`）。 |
| 2026-11-21 | 与 Xcode 有意不同的两处 | 路径行只占一行（Xcode 最多两行）：行高按 Xcode 截图固定为 38，两行会溢出；页面不整页滚动，搜索框与标题固定、只有列表滚动：最多 10 行，窗口不矮时看不出区别。 |
| 2026-11-21 | 第 3 步第二轮审查后调整 | 两个空标签之间切换时栏里的内容场景不变、`viewWillAppear` 不触发，复位改为同时跟随这一栏的当前标签；列表重排后选中原先留在行号上、回车可能打开别的对象，改为按对象恢复选中（三路订阅的先后顺序写在注释里）；`formOnScreen(of:)` 改为只按身份找标签，以别的语言显示的标签也算。 |
| 2026-11-21 | 第 4 步审查后调整 | 审查者指出：读目录时删到不足 3 个字符，`flatMapLatest` 换上空流、丢掉进行中的搜索，页面会一直停在读取中——改为短文本根本不进入搜索流，让上一次查询照常完成（也正是 Xcode 的做法）；点空白处原先把焦点交给窗口，这一栏不会成为焦点栏——改为交给页面自己；没有结果时方向键原先被吞——只在有结果时接管；页面释放时取消还在读的目录；一条否定断言可能被跳过——改为比较搜索前后的已索引镜像集合；补了「搜索中删字」与「切换 Engine 结束搜索」两条测试。另一条「匹配区分大小写」查明不成立：FuzzySearch 把模式与名字都转成小写，本来就不分大小写，与 Xcode 一致。 |
| 2026-11-21 | 第一次搜索的代价不封顶，记为已知 | 第一次满 3 个字符时会读这个 Engine 所有已索引镜像的对象列表（同时 8 个），这次搜索结束才释放。后台索引默认关闭，一般会话里已索引的只有用户打开过的镜像；开了 Always Index 或索引了大半个 shared cache 时第一次会慢、占用变大。根治要 Engine 端按名字找对象的命令，列入后续项。 |
| 2026-11-21 | 放大镜用 SF Symbols | Xcode 用自带的 23 × 23 模板图（`IDESearchWindowMagnifyingGlass`），不随 App 分发；这里用系统的 `magnifyingglass`，21pt 大约等大，放在同样的 32 × 32 框里。 |
| 2026-11-21 | 第 4 步第二轮审查后调整 | 页面空白处能取得焦点之后，它会进 Tab 顺序（焦点看似丢失）、焦点在它上面时打字会响——改为不进 Tab 顺序，打字时把焦点交回搜索框、字接在原有文字后面。「读取期间转圈」仍没有测试：要一个读得慢的目录才出现，列为目视。 |
| 2026-11-21 | 自审 | `/code-review medium` 审功能分支相对 `next` 的全部改动，六条逐条按四问核实，记在 [`KnownIssues/2026-11-21-editor-start-page-review-findings.md`](../KnownIssues/2026-11-21-editor-start-page-review-findings.md)：回车打开旧查询的结果（SP.1）与读目录时回车被吞（SP.2）一并修掉，带两条回归测试；页面空白处的方向键等不再转进输入框（SP.3）；图标照 Xcode 占 32 点的位、按 24 点画（SP.4）；目录在一次搜索期间不刷新（SP.5）与输入框文字经 relay 上报（SP.6）不修，理由留档。 |
| 2026-11-21 | 自审第二轮 | 只审 SP.1–SP.4 的修复，又找出两条：挂起的回车在用户接着打字后会为新文字自动打开（SP.7，已修，带回归测试）；挂起期间方向键选的是旧结果里的行（SP.8，不修）。 |
| 2026-11-21 | 实现完成，待用户看过后收尾 | 五步都已完成并推送功能分支。文档判断：不另写使用指南或实现说明——调用方契约只在 App 内部，维护要知道的「一栏一页、要复位」「度量照 Xcode」两条写进了 `RuntimeViewerUsingAppKit/AGENTS.md`；新术语「起始页」登记进 `Documentations/Glossary.md`。没做的验证：界面目视（布局、颜色、焦点、结果板）与 macOS 27 上的点击取焦点都没有在 App 里实测——这次没有启动 App 做界面操作，只编过 App、跑了 ViewModel 层的测试，留给用户看效果时确认。 |
| 2026-11-21 | 用户要求 ⇧⌘O 与起始页统一范围 | 用户看过初版后问 Xcode 的两个 Open Quickly 是否同一个：逆向显示起始页的搜索框与 ⇧⌘O 的窗口用同一套输入框、结果列表与按键处理，只是起始页嵌在页面里、自己持有一份结果；⇧⌘O 由 App 级的 `IDEApplicationCommands.openQuickly:` 打开浮动窗口。RV 原先的 ⇧⌘O 只搜侧栏当前镜像，与起始页范围不同，用户要求改成一样。加第 6 步（统一范围）与第 7 步（删掉侧栏那套从此没人用的 Open Quickly 机制）；浮动条从一个字符起就搜，因为 Xcode 只给起始页写死了 3 个字符。 |
| 2026-11-21 | 第 6 步审查后调整 | 审查者指出：关掉浮动条只结束了目录、没丢掉还在作答的词，那次搜索会把目录重新读起来并一直留着；切换 Engine 时旧 Engine 的结果会被标成新 Engine 的；镜像树还没出来时读到的空目录会被留用一整次搜索。改为关掉、打开一项、切换 Engine 都经同一条流复位（与起始页的做法相同），结果带上它来自的 Engine、落地时核对，`OpenQuicklySearch` 在调用方已取消时不再读目录、镜像树为空时不缓存目录；三条各带回归测试。另记为已知：起始页与浮动条各持有一个 `OpenQuicklySearch`，同一窗口里先后用两者会各读一份目录。 |
| 2026-11-21 | 第 7 步的两处取舍 | 删掉侧栏的 Open Quickly 之后，`RuntimeObjectCellTag.privateDeclaration(isClickable:)` 只剩传 `true` 的调用，收成无参数的 `privateDeclaration`；单元格在「模糊模式」下的性能基线测的是侧栏 Open Quickly 的配置（侧栏自己的过滤不用模糊匹配，生产代码里只剩 `OpenQuicklyCatalog` 用），一并删掉。`SidebarReloadInvalidationTests` 原来经 Open Quickly 的索引验证「重载失败要丢掉上次的列表」，改为直接断言 `nodes` 被清空，去掉清空那一行它会变红；「镜像未加载时也要调钩子」那条随钩子删掉。 |
| 2026-11-21 | 第 6 步修复与第 7 步审查后调整 | 审查者指出：镜像树为空时不缓存目录，于是每敲一个键都新起一次读取、`end()` 也取消不到，改为此时什么也不读；为 SP.9、SP.10 写的测试有一部分覆盖不到它们点名的检查，取消检查补了测试，结果上的 Engine 核对没有接缝可测、登记为不补；删掉钩子后「镜像未加载也清空列表」没人测了，给重载加了可覆写的 `isImageLoaded()` 补上。另外，全量测试里起始页一条挂起回车的测试在负载下偶尔失败，是测试先于「搜索结束」那一拍断言，改为等到搜索结束。裁决见 `Documentations/KnownIssues/2026-11-21-editor-start-page-review-findings.md` 的 SP.14–SP.16；旧清单里 PR100.8（侧栏 Open Quickly 物化表无上限）随第 7 步不再适用，已在原处注明。 |
| 2026-11-21 | 实现完成（第 6、7 步），待用户看过后收尾 | 七步都已完成并推送功能分支，第 6、7 步各过了审查关（第 6 步两轮、第 7 步连同第 6 步的修复一轮、修复再复审一轮）。文档判断：⇧⌘O 的变化写进本提案「影响」与 `RuntimeViewerUsingAppKit/AGENTS.md`（惰性 cell ViewModel 一节改述），不另写指南；已裁决清单补 SP.9–SP.16、旧清单 PR100.8 注明不再适用。没做的验证：浮动条与起始页的界面目视、⇧⌘O 的按键与修饰键都没在 App 里实测。 |
| 2026-11-21 | 用户要求最近列表跟着侧栏分层 | 用户看过第 6、7 步后指出：侧栏停在镜像列表（外面那层）时起始页应只列镜像，进到镜像里（里面那层）才列对象。确认了三点：分层依据是侧栏所在的层级，而不是把列表本身做成可展开的两层；进到一个镜像后只列这个镜像的最近对象；搜索框不分层，两层都与 ⇧⌘O 一样搜镜像与对象。加第 8 步。 |
| 2026-11-21 | 第 8 步的取舍（agent 定的，用户可推翻） | 「用过一个镜像」算三种：侧栏进到它、在镜像页看它、看它的一个对象。存储改为每个 Engine 一列最近镜像、每个镜像带自己的最近对象，各以 10 为上限（镜像照 `NSDocumentController` 的默认，对象照 Xcode 一个工作区的最近文件）；镜像被挤出时连同对象一起丢，所以一个 Engine 最多存 100 个对象。只按一列 10 个对象再按镜像过滤，进到镜像里常常只剩一两个，所以不这样做。路径一律按规范形式存，侧栏的路径与对象的 `imagePath` 才对得上。打开最近镜像显示镜像页，不移动侧栏，与搜索结果里的镜像行一致。旧的 `recentRuntimeObjectsByEngine` 从未发布，不迁移。 |
| 2026-11-22 | 第 8 步审查后调整 | 两位审查者没发现违反项目规则的地方。指出：模拟器进程的 Engine 要连上后才问到 `DYLD_ROOT_PATH`，之前按侧栏路径记下的镜像与之后按对象路径记下的成了两项，起始页也只在侧栏移动时算一次规范路径（SP.17）；路径为空的对象会记成没有名字的镜像（SP.20）；标题断言等于初始值、永远不会失败，A→B 关掉 Show All、在镜像里换 Engine、规范路径都没测（SP.21）。三条都修了、各带回归测试。焦点留在变空、被隐藏的列表上（SP.18）与换 Engine 时多出一次不会画出来的中间结果（SP.19）不修，理由在已裁决清单。同一种「问到写法之前算好规范路径、之后不重算」在路径栏的镜像节点表里也有，是基线问题，记进后续项。文字上补了术语表、行的注释、提案里两处旧说法。 |
| 2026-11-22 | 修复再审后调整 | SP.17 的第一版修法在每次记录前把整列路径都按当前 Engine 的写法改写一遍，再审指出这会改坏别的 Engine 的记录：两个同名、根路径不同的模拟器进程共用一个键，每记一次就给对方的路径再叠一层根路径（SP.22）。改为只把「按当前写法改过来正好是这次记录的镜像」的几项合并进来（`foldingOtherSpellings(of:in:canonicalImagePath:)`），其余各项一概不动；起始页读的时候不再改写，只按当前写法算侧栏的路径，随存储每次变化重算。Engine 问到根路径并不通知任何人，所以起始页要到下一次记录才赶上，这一点写进 SP.17、列入后续项。另一条「模拟器 App 自己的二进制不在根路径下，加前缀后成了不存在的路径」是 Core 规范形式的定义问题，全 App 同一口径，登记为 SP.23、不在本功能处理。 |
| 2026-11-22 | 第三轮审查 | 两位审查者确认改后的合并写法与记录器正确、不会给别的 Engine 的路径叠根路径。指出合并时的去重没有测试，补了；一个 Mac 进程与同名模拟器进程共用键时模拟器一侧会反复把 Mac 那一项并过去（有上限），照原判断不修，把 SP.22 的说法改准；旧版 payload 永远不回答根路径时同一镜像的两行会一直留着，写进 SP.17，是全 App 的同一限制。文字上补了「最近列表」一节的接口与两段说明、改了一条测试名。审查关到三轮为止。 |
| 2026-11-22 | 实现完成（第 8 步），待用户看过后收尾 | 第 8 步完成并推送功能分支，审查关三轮。文档判断：起始页的变化写进本提案、`RuntimeViewerUsingAppKit/AGENTS.md` 与术语表，裁决补 SP.17–SP.23，不另写指南。没做的验证：两种标题、换层级时列表的切换、最近镜像行的样子都没在 App 里目视。 |

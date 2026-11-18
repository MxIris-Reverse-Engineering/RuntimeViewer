# Draft - macOS App 的 ViewModel 移进 AppCore，通用视图移进 RuntimeViewerUI

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-18
- **最后更新**: 2026-11-18
- **所属愿景**: 无
- **关联提案**: [0091](0091-app-core-ui-split.md)（拆出 AppCore 与 AppUI，当时明确「App target 不动，以后另立提案」）、[0094](0094-app-core-without-ui-models.md)（AppCore 不用 AppKit/UIKit 模型；当时把 `RuntimeSourcePickerContent` 搬进了 AppUI）、[0095](0095-app-layer-directory-layout.md)（AppCore 与 AppUI 的目录规则）、[0048](0048-routes-carry-no-views.md)（路由不带视图）、[0070](0070-xcode-style-runtime-source-picker.md) 与 [0071](0071-xcode-activity-progress.md)（来源选择器与工具栏活动）
- **实现分支 / PR**: `feature/view-models-to-app-core`（worktree `.worktrees/RuntimeViewer-ViewModelsToAppCore`），做完一次合进 `next`
- **配套文档**: 待定 —— 落地时判断
- **网页版**: 同目录同名的 `.html`

## 摘要

macOS App target（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`）里还有 18 个 ViewModel 文件，以及它们的路由与状态类型。这次把它们全部搬进 `RuntimeViewerAppCore`，并把其中用到的 UI 类型改成 AppCore 的值：

- 主窗口的工具栏活动、来源选择器的内容与图标、标题图标、历史菜单。
- 特化页的描述文字。
- 「在 Finder 中显示」与拷贝。

MCP 状态弹窗通过新的跨层服务 `mcpServerClient` 启停服务，接口在 AppCore，真实实现在 MCP 包。没人用的 `Load Frameworks` 那组死代码删掉。8 个不碰 AppCore 类型的通用视图搬进 `RuntimeViewerUI`：加载圈、`LoadingButton`、行号标尺、内容文本视图、`EventMonitor`、两个控件扩展，以及侧栏转场的背板控制器。

此后 App target 只放这几类东西：ViewController、window controller、coordinator、`App/` 下的生命周期控制器、绑着 AppCore 类型的视图与菜单胶水。新增的包测试 `AppTargetBoundaryTests` 读 App 的源码，发现 ViewModel 就失败。行为不变，没有用户可见的变化。

## 动机

- **App 里的 ViewModel 没法单元测试。** 包测试不链接 App target，所以这 18 个文件里的逻辑一行都没有测试：
  - 主窗口的切换来源、附加进程可用性、分享与保存、历史菜单。
  - 导出与批量导出的三步流程。
  - 特化页、MCP 状态。

  其中 `Main/MainViewModel.swift` 一个文件就有 680 行。0091 把 AppCore 拆出来，就是为了 ViewModel 能在测试里构造、驱动，而这一半至今没享受到。
- **分层规则与实际不符。** 根 `AGENTS.md` 的「Key Source Locations」写着「ViewModels: `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/`」，`RuntimeViewerUsingAppKit/AGENTS.md` 也把 ViewModel 归在 AppCore。但实际上：
  - App target 还有 `BatchExporting/`（6 个）、`Exporting/`（3 个）、`Specialization/`（4 个）、`Attach Process/`、`Generation Options/`、`MCP/`、`Main/`、`Sidebar/RuntimeObject/`（各 1 个）。
  - 0091 的决策日志写的是「AppUI 只收从这里拆出来的部分；`RuntimeViewerUI` 与 App target 不动……以后要做可以另立提案」（0091 决策日志 2026-11-13「AppUI 范围」）。
- **App 里的 ViewModel 绕开了 0094 的约束。** `MainViewModel` 的输出直接是 UI 库的类型：`NSImage`、`RuntimeSourcePicker.Icon`、`ToolbarActivityState`、`RuntimeSourcePickerContent`（带 `NSImage`）。0094 只能因此把 `RuntimeSourcePickerContent` 留在 AppUI（0094 决策日志「第二步完成」第一条）。`SpecializationCellViewModel` 直接拼 `NSAttributedString`。导出完成页直接调 `NSWorkspace`，MCP 弹窗直接写 `NSPasteboard`。
- **通用视图埋在 App 里。** 加载圈、`LoadingButton`、行号标尺这些视图不依赖任何 App 或 AppCore 类型，却只能在 App target 里用。

## 前期调研

以下路径中，`MAC` 指 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit`，`AC` / `AUI` / `RUI` 分别指 `RuntimeViewerPackages/Sources/` 下的 `RuntimeViewerAppCore` / `RuntimeViewerAppUI` / `RuntimeViewerUI`，`ACT` / `AUT` 指 `RuntimeViewerPackages/Tests/` 下的两个测试 target。

### App target 里的 ViewModel，以及各自挡路的东西

| 文件 | 挡路的东西 | 处理 |
|---|---|---|
| `MAC/Exporting/Exporting{Configuration,Progress,Completion}ViewModel.swift` | 完成页 `NSWorkspace.shared.activateFileViewerSelecting`（`ExportingCompletionViewModel.swift:60`）；依赖 App 的 `ExportingRoute`（`ExportingCoordinator.swift:6`）、`ExportingStepViewModel`（`ExportingViewController.swift:7`）、`ExportingState` | 改走 `finderClient.revealFile`（`AC/ContextMenus/FinderClient.swift:11`）；路由、协议、状态一起搬 |
| `MAC/BatchExporting/` 6 个 ViewModel、`BatchExportingState.swift` | 完成页同样调 `NSWorkspace`（`BatchExportingCompletionViewModel.swift:65`）；两个行 ViewModel 的 `Differentiable` 扩展没有平台条件（`BatchExportingCompletionRowViewModel.swift:13`、`BatchExportingProgressRowViewModel.swift:111`） | 改走 `finderClient`；`Differentiable` 照 AppCore 惯例加 `#if canImport(AppKit) && !targetEnvironment(macCatalyst)`（`AC/BatchExporting/BatchExportingImageTreeNode.swift:145`）。`BatchExportingImageTree` 等已在 AppCore |
| `MAC/Specialization/` 4 个 ViewModel、`SpecializationRoute`（`SpecializationCoordinator.swift:16`） | `SpecializationCellViewModel` 用 `NSAttributedString` + `NSUIFont` / `NSUIColor` 拼描述文字与「Loading inner parameters…」占位（`:65`、`:237-261`）；`SpecializationTypePickerCellViewModel` 多余地 import 了 `RuntimeViewerUI`、`UIKit`、`AppKit`、`RxAppKit` | 描述文字改 `RowText`：`RowTextStyle.list` 画出来的就是 13 号系统字、`labelColor` / `secondaryLabelColor`、尾部截断（`AUI/Presentation/RowText+AttributedString.swift:18-46`），只多一个左对齐，标签单行显示看不出差别；去掉多余 import |
| `MAC/Generation Options/GenerationOptionsViewModel.swift` | 只多余地 import 了 `AppKit` 与 `RuntimeViewerUI` | 直接搬 |
| `MAC/Sidebar/RuntimeObject/SidebarRuntimeObjectScopeViewModel.swift` | 只多余地 import 了 `AppKit` | 直接搬 |
| `MAC/MCP/MCPStatusPopoverViewModel.swift` | `NSPasteboard`（`:67-76`）；`@Dependency(\.mcpService)` 来自 `RuntimeViewerMCPBridge`，而 MCP 包依赖 AppCore（`RuntimeViewerMCP/Package.swift:76`），AppCore 看不到它；启动要传 App 的 `AppMCPBridgeDocumentProvider()`（`:61`） | 见「MCP 状态的跨层服务」 |
| `MAC/Attach Process/AttachToProcessViewModel.swift` | `Input.attachToProcess` 是 RunningApplicationKit 的 `any RunningItem`（`:24`）；远端附加时把行的 `NSImage` 图标记到 AppUI 的 `runtimeEngineIconProvider`（`:156`、`:200-202`） | 见「附加进程」 |
| `MAC/Main/MainViewModel.swift`（680 行） | `SwitchSourceState.image: NSImage?` 与 `pickerIcon: RuntimeSourcePicker.Icon?`（`:32-35`）；`Output.runtimeSourcePickerContent`（AppUI 类型，`:165`）；`Output.activity: Driver<ToolbarActivityState>`（RuntimeViewerUI 类型，由 AppUI 的 `ToolbarActivityPresenter` 产出，`:178`、`:205`）；`Output.toolbarIcon: Driver<NSImage?>`（`TitleDocumentIcon` 与 App 自己的符号，`:180-192`）；`NavigationHistorySnapshot`（App 类型，项里有 `NSImage`）；`@Dependency(\.fileController)`（App 的 `FileController`，`:211`、`:433`、`:578`）；`SIPChecker`（App 的 `Utils/`，`:486`）；`SharingData.provider: NSItemProvider`（Foundation 类型） | 见「主窗口的 ViewModel」 |
| `MAC/Load Frameworks/LoadFrameworksViewController.swift` | 文件里一个空的 `LoadFrameworksViewModel` 和一个只用它的 VC，整个仓库没有别处引用它们（Load Frameworks… 实际走 `MainWindowController.presentOpenPanel()`） | 整个目录删除 |

没有一个简单 ViewModel 用到 App target 里声明的 `@Dependency`，它们只用基类给的 `appDefaults` 与 `settings`（`AC/Base/ViewModel.swift:13-22`）。

### 名字冲突与平台

- 搬进 AppCore 的名字和 AppCore、AppUI、`RuntimeViewerUI`、`RuntimeViewerCore` 里已有的都不冲突。
- iOS App 自己声明了 `public enum MainRoute`（`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Main/MainCoordinator.swift:9`）和 `class MainViewModel`（`Main/MainViewModel.swift:7`），也 import 同一个门面。本模块的声明会遮住导入的同名声明，按理能编过，但没实测。
- `SpecializationViewModel` 等文件今天已经整个包在 `#if os(macOS)` 里（`MAC/Specialization/SpecializationViewModel.swift:1`）。搬过去的文件一律照此处理，iOS 一侧看不到它们，也就不存在遮蔽问题。

### 依赖

- AppCore 已声明的依赖：`RuntimeViewerCore`、`RuntimeViewerArchitectures`（重导出 Rx 一族、RxDefaultsPlus、Dependencies）、`RuntimeViewerSettings`、`RuntimeViewerEngineManagement` 与 `RuntimeViewerHelperClient`（后两个只在 AppKit 平台）（`RuntimeViewerPackages/Package.swift:454-469`）。
- `RuntimeViewerInjection` 没有声明，只经 `RuntimeViewerEngineManagement` 间接可见（`Package.swift:570`）。附加进程的 ViewModel 要用它，所以这次补上声明。`FoundationToolbox`、`OrderedCollections`、`RuntimeViewerCommunication` 已有 AppCore 文件在间接使用，照旧。
- `RxAppKit` 不在 `AppCoreBoundaryTests` 的 UI 库名单上（`ACT/AppCoreBoundaryTests.swift:206-218`），AppCore 已有 7 个文件 import 它。它的 `RxMenuItemRepresentable` 只要求 `title` 与 `keyEquivalent`（RxAppKit `Components/NSMenu+Rx.swift:5-8`），所以历史菜单的项留在 AppCore 也能直接给 `NSMenu.rx.items` 用。

### 工具栏活动

- AppUI 的 `ToolbarActivityPresenter`（93 行）做三件事：
  - 合并会话里各后台工作的报告快照。
  - 用 AppCore 的 `ActivityReportSelector` 挑出要显示的报告，并在显示延迟、最短停留时间到点时再挑一次。
  - 把挑选结果转成 `ToolbarActivityState`，然后 `distinctUntilChanged` 并按 1 秒节流（`AUI/Activity/ToolbarActivityPresenter.swift:26-90`）。
- 转换写在 `AUI/Activity/ToolbarActivityState+Reports.swift`（130 行）：`idle`、`make(for:sourceName:readyDate:)`，以及拼文字的 `ActivityText`。
- `ToolbarActivityState` 与 `ActivityTextSegment` 是纯值（`RUI/Activity/ToolbarActivityState.swift:6-106`）。它们放在 `RuntimeViewerUI`，是因为工具栏的视图接收它们，而 `RuntimeViewerUI` 在 AppCore 之下、看不到 AppCore。
- 节流作用在「显示状态」上，不是「挑选结果」上。挑选结果里有下次重挑的时间，到点重挑时显示可能不变。如果改成对挑选结果去重、节流，一次不改显示的重挑也会占掉 1 秒窗口，把紧接着的真实变化推后。所以 AppCore 要产出一个与显示状态一一对应的值，在它上面去重、节流。

### 引擎图标

- AppUI 的 `RuntimeEngineIconProvider` 按引擎解析图标：
  - 本机附加的进程查 Launch Services。
  - 镜像来的引擎解码描述里的图标数据。
  - 设备上注入的进程由创建者 `record(_:for:)`，每次记录都发出 `recordedIconsChanged`（`AUI/Engine/RuntimeEngineIconProvider.swift:29-40`、`:212-229`）。
- `icon(forEngineID:)` 对已不在管理器里的引擎返回通用可执行文件图标（`:102-111`）。所以 0094 没法把「已断开的来源」改成按 ID 的描述值：断开后显示的是断开前存下的那张图，按 ID 已经找不回（0094 决策日志「第二步完成」）。
- 今天的 `MainViewModel` 在每个窗口里缓存上次的 `NSImage` 与选择器图标（`MAC/Main/MainViewModel.swift:217-235`、`:526-543`）。

### FileController 里的两段

`dependencyCacheChoices(for:)` 与 `pair(_:with:)`（`MAC/App/FileController.swift:115-155`）只读 `runtimeEngineManager` 与 `settings`，不碰 AppKit，唯一的调用方是 `MainViewModel`（`:433`、`:578`）。

### MCP 服务

- `MCPService`（`RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPService.swift`）是 `@MainActor` 的单例。
  - `serverState` 改变时调用唯一一个闭包槽 `onStateChange`（`:33-40`）。这个槽只有 `MCPStatusPopoverViewModel` 用，两个窗口先后打开弹窗时，后打开的会覆盖前一个。
  - `start(for:)` 会把文档提供者存进 `documentProvider`（`:84-85`）。
- `AppDelegate` 在启动时 `start(for: AppMCPBridgeDocumentProvider())`（`MAC/App/AppDelegate.swift:95`）。弹窗里「Start」只在 `.stopped` 时出现，那时服务已经带着提供者启动过一次。
- `MCPBridgeTests` 今天只依赖 MCPBridge 与 Core（`RuntimeViewerMCP/Package.swift:81-87`）。

### 通用视图

| 文件 | 依赖 | 使用方 | 结论 |
|---|---|---|---|
| `MAC/Base/CommonLoadingView.swift` | AppKit、RuntimeViewerUI | `Base/ViewControllers.swift:26` | 搬，改 `public` |
| `MAC/Base/LoadingButton.swift` | AppKit、RuntimeViewerUI、SnapKit | `SpecializationViewController.swift:232` | 搬，已是 `open` |
| `MAC/Utils/EventMonitor.swift` | AppKit | `ContentTextViewController` | 搬，改 `public` |
| `MAC/Utils/NSOutlineView+.swift` · `expandItem(_:toDepth:)` | AppKit | `SidebarRootViewController` | 搬，改 `public`。AppKitPlus 是二进制包，有没有同名方法没核实，靠构建发现 |
| `MAC/Utils/CheckboxButton+.swift` | UIFoundation | 批量导出选镜像页、生成选项页 | 搬，改 `public`。与 UIFoundationToolbox 的 `NSButton.init(title:titleColor:titleFont:…)` 标签顺序不同，重载应选子类的，靠构建核实 |
| `MAC/Content/ContentTextView.swift` | 只 import 了用不到的 Core / Application / Architectures | `ContentTextViewController` | 搬，去掉多余 import |
| `MAC/Content/ContentLineNumberRulerView.swift` | 第 30 行用了 AppUI 的 `NSColor(light:dark:)`（`AUI/Extensions/NSUIColor+Adaptive.swift:32`） | `ContentTextViewController` | 改用等价的 `NSColor(name: nil) { appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? … : … }` 后搬。原生工程里有一条针对它的 `file-types` 条目（`RuntimeViewerUsingAppKit.xcodeproj/project.xcproj:61`），一起删掉 |
| `MAC/App/NavigationTransitionBackdropController.swift` | AppKitPlus、UIFoundation 的 `GlassEffectReplicaView`、FrameworkToolbox；`RuntimeViewerArchitectures` 与 `DependenciesMacros` 的 import 用不到 | `SidebarNavigationController.swift:10`；它定义的 `_backgroundColor` 桥接（`:81`）也被两个内容页 VC 用 | 搬，连 `_backgroundColor` 一起改 `public` |

留在 App 的，以及原因：

- **绑着 AppCore 类型的**：`Base/RuntimeObjectCellView.swift`、`ContextMenuItem.swift`、`RuntimeObjectAction+Menu.swift`、`RuntimeObjectListInteractions.swift`、`TabViewController.swift`（用 `Driver` 与 CocoaCoordinator 的 `Transition`），以及 `Base/ViewControllers.swift`（泛型参数是 AppCore 的 `ViewModelProtocol`）。
- **按 App 自己的规则就该留下的**：
  - 嵌在 VC 里的私有小视图，例如 `EditorPaneViewController` 的 `SeparatorView`、批量导出完成页的 `StatCardView`。`RuntimeViewerUsingAppKit/AGENTS.md` 规定「只有一个 VC 用的视图是它的私有嵌套类型」。
  - `Resources/RuntimeViewerSymbols.swift`：从 App 的 asset catalog 取符号。
  - `Reports/SFSymbols+ReportNavigator.swift`：一个符号名，不是视图。
  - `EditorArea/EditorPaneContent.swift`：点名了 App 的两个 VC。
  - `Attach Process/RemoteProcessItemSource.swift`：给 RunningApplicationKit 选择器供数据的胶水，绑着 `RuntimeEngine`。
- **App 的副本**：`Utils/Then.swift` 是 App 自己的副本。`RuntimeViewerUI` 自带一份 `internal` 的 `Then`，搬过去的文件里的 `.then` / `.do` 会自动用那一份。

`RuntimeViewerUI` 的依赖是 UIFoundation、UIFoundationToolbox、SnapKit、SFSymbols、LateResponders、AppKitPlus、RunningApplicationKit、KeyboardShortcuts（`Package.swift:387-400`），能覆盖上面这些文件的 import。FrameworkToolbox 没有直接声明；`NavigationTransitionBackdropController` 用的 `FrameworkToolbox` 扩展如果需要，就在 `RuntimeViewerUI` 的依赖里补上。

### 构建描述

- Tuist 的 App target 用 `buildableFolders`（`RuntimeViewerUsingAppKit/Project.swift:155-157`），包按 SwiftPM 的目录约定，搬文件不用改 Tuist 描述。
- 原生工程是文件夹引用，唯一的单文件条目就是上面那条行号标尺的。

### 防回流检查能借用的现成设施

- `ACT/Support/PackageSourceScan.swift`：
  - 从 `#filePath` 推出包根（`:46-52`），用 `FileManager` 枚举 `Sources/<target>`（`:24-43`）。
  - 把注释和字符串内容换成空格，行号不变（`SwiftSourceText.codeOnlyLines`，`:247`）。
  - 按 macOS / iOS / visionOS 求值 `#if`（`:154-194`、`:345`）。
- 把包根往上一级再拼 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit` 就能读 App 的源码，URL 接口能处理目录名里的空格。目前没有测试读包外的文件。

## 提议方案

### 分层：改完之后每一层放什么

| 层 | 放什么 |
|---|---|
| App target | ViewController 与 window controller；coordinator（它们构造 VC）；`App/` 下的 `AppDelegate` 与生命周期控制器；绑着 AppCore 类型的视图、cell 视图、菜单与列表交互的胶水；App 自己的资源与系统修补。**不放 ViewModel** |
| `RuntimeViewerAppCore` | 所有 ViewModel（含 cell ViewModel）、路由、页面状态，以及它们用到的逻辑。macOS 窗口专用的整文件包在 `#if os(macOS)` 里 |
| `RuntimeViewerAppUI` | 不变：胶水、把 AppCore 的值画出来、AppCore 声明的服务的真实实现。多一个把 `ToolbarActivity` 转成 `ToolbarActivityState` 的初始化方法；工具栏活动的 presenter 与来源选择器的内容回到 AppCore |
| `RuntimeViewerUI` | 不依赖 AppCore 的通用视图，多 8 个文件 |
| `RuntimeViewerMCPBridge` | 多一份 AppCore 声明的 `mcpServerClient` 的真实实现 |

### 1. 简单的 ViewModel：原样搬，UI 调用改走现有服务

- **导出**：三个 ViewModel，加上 `ExportingState`（含 `ExportingStep`、`ExportFormat`、`ExportingDefaultsKey`）、`ExportingRoute`、`ExportingStepViewModel`，搬进 `AC/Exporting/`。`ExportingStepViewController` 留在 App。
- **批量导出**：6 个 ViewModel 加 `BatchExportingState`，搬进已有的 `AC/BatchExporting/`。
- **特化**：4 个 ViewModel 加 `SpecializationRoute`，搬进 `AC/Specialization/`。
- **生成选项**：`GenerationOptionsViewModel` 搬进 `AC/GenerationOptions/`。
- **过滤范围**：`SidebarRuntimeObjectScopeViewModel` 搬进已有的 `AC/Sidebar/RuntimeObject/`。
- **两个完成页**的「Show in Finder」改成 `@Dependency(\.finderClient)` 的 `revealFile(_:)`。
- **`SpecializationCellViewModel.descriptionText`** 从 `NSAttributedString` 改成 `RowText`：
  - 描述是 `RowText(displayDescription, fontSize: 13)`。
  - 占位是 `RowText("Loading inner parameters…", role: .secondary, fontSize: 13)`。

  VC 绑定时画成 `attributedString(in: .list)`。
- **App 的 ViewController 与 coordinator 要读的成员都改成 `public`**，各 `Input` 补上 `public init`。各类型的具体清单列在「详细设计」。
- **`LoadFrameworks/`** 整个删除。

### 2. MCP 状态的跨层服务

- **`MCPServerState`** 从 MCPBridge 下移到 `AC/MCP/`，MCPBridge 改用 AppCore 的这个类型。MCPBridge 本来就依赖 AppCore。
- **AppCore 声明 `MCPServerClient`**：
  - 三个成员：读当前状态、启动、停止。
  - 测试值 `inert`：状态恒为 `.stopped`，启动、停止都不做事。
  - key 是 `public enum MCPServerClientKey: TestDependencyKey`，访问器是 `DependencyValues.mcpServerClient`。
  - key 必须是 `public` 而不是 `package`：真实实现在另一个包，`package` 跨不了包。
- **MCPBridge 在 `MCPService.swift` 里补 `extension MCPServerClientKey: DependencyKey`**，真实值转发给 `MCPService.shared`。
  - 「启动」调用新加的 `MCPService.resume()`，用上次 `start(for:)` 存下的文档提供者再启动一次。
  - 没有存过提供者时记一条错误日志，什么也不做。
- **`MCPService` 改用 Observation 让状态可被跟踪，去掉只有弹窗在用的 `onStateChange`。**
  - 加 `@Observable`，除 `serverState` 外的存储属性标 `@ObservationIgnored`。
  - 弹窗的 ViewModel 用 `Observable.tracking { mcpServerClient.state() }`（`RuntimeViewerArchitectures/Observable+Tracking.swift:40`）跟随状态，写法同 `MainViewModel` 跟随设置。
  - 多个弹窗不再互相覆盖。
- **`MCPStatusPopoverViewModel` 与 `MCPConfigType` 搬进 `AC/MCP/`**，拷贝改走 `pasteboardClient.copyString`。

### 3. 附加进程

- **`AttachToProcessViewModel` 搬进 `AC/AttachToProcess/`**：
  - `Input.attachToProcess` 改成 `Signal<RuntimeProcessAttacher.Target>`。这个类型是 `RuntimeViewerEngineManagement` 的（名字加 pid）。
  - 删掉 `runtimeEngineIconProvider` 与 `NSImage` 参数。
  - `Output` 多一个 `remoteProcessAttached: Signal<RuntimeEngine>`：设备上的进程附加成功、它的引擎报到时发出，发生在 `.dismiss` 之前。
- **图标由视图层记**：`AttachToProcessViewController` 记住用户选中的 `RunningItem`，把它转成 `Target` 交给 ViewModel。收到 `remoteProcessAttached` 时，用那一行的图标调 AppUI 的 `runtimeEngineIconProvider.record(_:for:)`。这张图只存在于视图层（设备读出图标数据后画给选择器的那一行），不让它绕进 AppCore 再出来。
- **`AttachAvailability`** 从 `MainViewModel.swift` 拆出，与 `SIPChecker` 一起搬进 `AC/AttachToProcess/`。`SIPChecker` 原在 `MAC/Utils/`，只是调 `csrutil`，不碰 UI。
- **`RemoteProcessItemSource` 留在 App。**

### 4. 主窗口的 ViewModel

`MainViewModel`、`MainRoute`、`NavigationHistorySnapshot` 搬进 `AC/Main/`，所有 UI 类型的输出改成值：

- **工具栏活动**：
  - `AUI/Activity/ToolbarActivityState+Reports.swift` 里的拼装逻辑搬进 AppCore 的新值类型 `ToolbarActivity`（`AC/Activity/ToolbarActivity.swift`），带上 `idle`、`make(for:sourceName:readyDate:)` 与 `ActivityText`。它的字段与 `ToolbarActivityState` 一一对应。
  - `ToolbarActivityPresenter` 整个搬进 `AC/Activity/`，挑选、定时重挑、去重、1 秒节流都在 AppCore，输出 `Driver<ToolbarActivity>`。
  - AppUI 只留 `ToolbarActivityState.init(_ activity: ToolbarActivity)`，一一照抄。
  - `MainViewModel.Output.activity` 改成 `Driver<ToolbarActivity>`，`MainWindowController` 转成显示状态再交给两个活动视图。
- **来源选择器**：
  - `RuntimeSourcePickerContent` 搬回 `AC/RuntimeSourcePicker/`，`Source.image: NSImage?` 改成 `icon: IconDescriptor`。各来源都是 `.runtimeEngine(engineID:)`，已断开的来源也一样。
  - `SwitchSourceState` 的 `image` 与 `pickerIcon` 合并成 `icon: IconDescriptor`。
  - 两个 adapter 画 `source.icon.image`。`MainWindowController` 用 AppUI 新加的 `runtimeEngineIconProvider.sourcePickerIcon(forEngineID:)` 给选择器取图标。
  - 记录图标会发出 `recordedIconsChanged`，`MainWindowController` 收到时重新取图、重设 adapter 的内容。今天这个「图标到了，重画一遍」的提示由 ViewModel 合进来源列表，改完之后在视图层做。
- **断开来源的图标**：`RuntimeEngineIconProvider` 每画一次在管理器里的引擎，就按 engineID 记下这张图与选择器图标。`icon(forEngineID:)` 与新的 `sourcePickerIcon(forEngineID:)` 遇到已不在管理器里的引擎时，先用记下的，没有才用通用图标。这样 ViewModel 不必在每个窗口里缓存 `NSImage`，0094 卡住的那一点也解开了。
- **标题图标**：
  - `Output.toolbarIcon` 改成 `Driver<MainViewModel.TitleIcon>`，取值有两种：`.application`（没打开镜像时）和 `.imageKind(RuntimeImageKind)`。
  - `MainWindowController` 画图：`.application` 是 App 自己的符号（`RuntimeViewerSymbols.runtimeViewer`，在 App 的 asset catalog 里），蓝色；`.imageKind` 用 `kind.icon` 加 `kind.iconColor`。两种都经 `TitleDocumentIcon.image(symbol:color:)`。
  - App 自己的符号因此留在 App。
- **历史菜单**：
  - `NavigationHistoryItem.icon` 从 `NSImage` 改成 `IconDescriptor`：对象是 `.runtimeObject(kind)`，镜像是 `.imageKind(RuntimeImageKind(ofImageAt:))`。
  - App 构造菜单时画图：对象按 `image(size: NavigationHistorySnapshot.iconSize)`；镜像照 AGENTS.md「菜单里的镜像图标取 `coloredIcon`」，画 `kind.coloredIcon`。
  - `RxMenuItemRepresentable` 的一致性随类型留在 AppCore。
- **依赖缓存**：`FileController` 的两段搬进 `AC/Engine/RuntimeEngineManager+DependencyCache.swift`，作为 `RuntimeEngineManager` 的扩展：
  - `dependencyCacheChoices(for:)` 直接返回 `RuntimeSourcePickerContent.DependencyCacheChoice`。
  - `pair(_:with:)` 原样搬。

  `FileController.DependencyCacheChoice` 删掉。`MainViewModel` 不再依赖 `fileController`。
- **分享**：`SharingData.provider` 仍是 `NSItemProvider`。它是 Foundation 的类型，加进 `AppCoreBoundary.allowedSystemPrefixedNames`。
- **ViewModel 内部依赖变化**：
  - `MainViewModel` 不再依赖 `runtimeEngineIconProvider`。
  - 「图标到了要重画」由 `MainWindowController` 合并 `recordedIconsChanged` 承担（见上）。

### 5. 通用视图搬进 RuntimeViewerUI

前期调研表里的 8 个文件搬进 `RUI/AppKit/`，用到的成员改成 `public`，多余的 import 去掉。行号标尺换掉 AppUI 的取色初始化方法，原生工程里它的单文件条目删掉。两个扩展文件按内容改名：`NSOutlineView+ExpandToDepth.swift`、`CheckboxButton+Title.swift`。

### 6. 防回流检查

在 `ACT/` 新增 `AppTargetBoundaryTests`：

- 用 `PackageSourceScan` 读 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/` 下的全部 Swift 源码，注释与字符串不算。
- 遇到这两种情况就报文件与行号，测试失败：
  - 声明了名字以 `ViewModel` 结尾的类型。
  - 有类型继承 `ViewModel<…>`、`CellViewModel`，或遵循 `ViewModelProtocol`。
- App 的目录不在预期位置时直接失败，不会因为什么都没读到而通过。

`PackageSourceScan` 加一个读任意目录的入口，复用现有的注释剥离与 `#if` 求值。

### 7. 文档

- `RuntimeViewerPackages/Sources/AGENTS.md`：
  - AppCore 持有全部 ViewModel、App target 不放 ViewModel，并提及 `AppTargetBoundaryTests`。
  - 跨层服务一段加上 `mcpServerClient`：key 是 `public`，真实实现在 MCP 包。
  - 图标一段加上「断开的引擎按 ID 取回最后的图标」。
  - 「Where a file goes」的目录名单加上新目录。
- `RuntimeViewerUsingAppKit/AGENTS.md`：
  - 开头一段改成 App target 只放 VC、coordinator、生命周期控制器和绑定 AppCore 类型的视图。
  - 工具栏一节改成「presenter 在 AppCore 产出 `ToolbarActivity`，AppUI 转成 `ToolbarActivityState`」。
  - `NavigationTransitionBackdropController` 的路径改到 `RuntimeViewerUI`。
- 根 `AGENTS.md`：
  - 「Singletons & Dependency Injection」里跨层依赖的例外加上 `mcpServerClient`，并写明它的 key 为什么是 `public`。
  - Package Structure 里 AppUI 的描述去掉「the toolbar activity presenter」。

### 非目标

- **不动** coordinator、`App/` 下的生命周期控制器（`FileController` 只删掉搬走的两段）、任何 ViewController 的布局与交互。
- **不动** iOS App（`RuntimeViewerUsingUIKit`）。它自己的 `MainViewModel` / `MainRoute` 照旧。
- **不改**测试 target 的平铺目录（0095 的约定）。
- **不改行为**：工具栏活动的挑选、定时与节流逐条保持；来源选择器、历史菜单、标题的图标逐像素不变。断开来源的图标原本是在窗口里缓存的，改成由图标表按 ID 记住，显示结果相同。
- 不把绑着 AppCore 类型的视图、`RemoteProcessItemSource` 挪出 App。
- 不给单纯搬家、逻辑没改的部分补测试。

## 改动地图

路径缩写同「前期调研」。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `MAC/Base/CommonLoadingView.swift` → `RUI/AppKit/CommonLoadingView.swift` | 移动 | 类、`isRunning`、`init`、`updateLayer` 改 `public` | 通用视图 | 1 |
| `MAC/Base/LoadingButton.swift` → `RUI/AppKit/LoadingButton.swift` | 移动 | 无 | 通用视图 | 1 |
| `MAC/Utils/EventMonitor.swift` → `RUI/AppKit/EventMonitor.swift` | 移动 | 类、`init`、两个方法改 `public` | 通用 | 1 |
| `MAC/Utils/NSOutlineView+.swift` → `RUI/AppKit/NSOutlineView+ExpandToDepth.swift` | 移动、改名 | `expandItem(_:toDepth:)` 改 `public` | 通用；文件名说出内容 | 1 |
| `MAC/Utils/CheckboxButton+.swift` → `RUI/AppKit/CheckboxButton+Title.swift` | 移动、改名 | 便利 `init` 改 `public` | 通用 | 1 |
| `MAC/Content/ContentTextView.swift` → `RUI/AppKit/ContentTextView.swift` | 移动 | 改 `public`，删多余 import | 不依赖 AppCore | 1 |
| `MAC/Content/ContentLineNumberRulerView.swift` → `RUI/AppKit/ContentLineNumberRulerView.swift` | 移动 | `lineNumberColor` 默认值改用 `NSColor(name: nil)` 动态色（取色与 AppUI 的 `NSColor(light:dark:)` 相同）；类、`init`、`reload()`、`gutterBackgroundColor`、`lineNumberColor` 改 `public` | 去掉对 AppUI 的唯一依赖 | 1 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.xcproj` | 修改 | 删掉 `Content/ContentLineNumberRulerView.swift` 的 `file-types` 条目 | 文件已不在 App 目录 | 1 |
| `MAC/App/NavigationTransitionBackdropController.swift` → `RUI/AppKit/NavigationTransitionBackdropController.swift` | 移动 | 控制器、`NavigationTransitionBackdrop`、`_backgroundColor` 改 `public`；删掉用不到的 `RuntimeViewerArchitectures` / `DependenciesMacros` import；需要时给 `RuntimeViewerUI` 补 FrameworkToolbox 依赖 | 通用转场辅助 | 1 |
| `MAC/Load Frameworks/`（`LoadFrameworksViewController.swift`） | 删除 | 整个目录 | 死代码 | 1 |
| `RuntimeViewerUsingAppKit/AGENTS.md` | 修改 | `NavigationTransitionBackdropController` 的路径 | 同批文档 | 1 |
| `MAC/Exporting/Exporting{Configuration,Progress,Completion}ViewModel.swift` → `AC/Exporting/` | 移动 | `public`；`#if os(macOS)`；完成页改用 `finderClient.revealFile` | 可测试 | 2 |
| `MAC/Exporting/ExportingState.swift` → `AC/Exporting/ExportingState.swift` | 移动 | `ExportingState`、`ExportingStep`、`ExportFormat`、`ExportingDefaultsKey` 改 `public` | 随 ViewModel | 2 |
| `MAC/Exporting/ExportingCoordinator.swift` · `ExportingRoute` → `AC/Exporting/ExportingRoute.swift` | 拆出、移动 | `public` | 路由归 AppCore | 2 |
| `MAC/Exporting/ExportingViewController.swift` · `ExportingStepViewModel` → `AC/Exporting/ExportingStepViewModel.swift` | 拆出、移动 | 协议与默认实现改 `public` | ViewModel 遵循它 | 2 |
| `MAC/BatchExporting/BatchExporting*ViewModel.swift`（6 个）、`BatchExportingState.swift` → `AC/BatchExporting/` | 移动 | `public`；`#if os(macOS)`；两个行 ViewModel 的 `Differentiable` 加平台条件；完成页改用 `finderClient` | 可测试 | 2 |
| `MAC/Specialization/Specialization*ViewModel.swift`（4 个）→ `AC/Specialization/`；`SpecializationCoordinator.swift` · `SpecializationRoute` → `AC/Specialization/SpecializationRoute.swift` | 移动、拆出 | `public`；`SpecializationCellViewModel.descriptionText` 改 `RowText`；去掉多余 import | 可测试；不用 UI 模型 | 2 |
| `MAC/Specialization/SpecializationViewController.swift` | 修改 | 描述标签绑定 `descriptionText.attributedString(in: .list)` | 跟随 `RowText` | 2 |
| `MAC/Generation Options/GenerationOptionsViewModel.swift` → `AC/GenerationOptions/` | 移动 | `public`（连同两个 typealias）；删多余 import | 可测试 | 2 |
| `MAC/Sidebar/RuntimeObject/SidebarRuntimeObjectScopeViewModel.swift` → `AC/Sidebar/RuntimeObject/` | 移动 | `public`（`init`、`draft`、`availableKinds`、`availableProperties`） | 可测试 | 2 |
| `ACT/ExportingCompletionViewModelTests.swift`、`ACT/BatchExportingCompletionViewModelTests.swift` | 新增 | Show in Finder 经 `finderClient` 揭示导出目录（记录器替身） | 从 `NSWorkspace` 改成服务的部分 | 2 |
| `ACT/SpecializationCellViewModelTests.swift` | 新增 | 描述与占位的 `RowText` 取值 | 从富文本改成值的部分 | 2 |
| `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPService.swift` | 修改 | `MCPServerState` 移出；`@Observable`（其余属性 `@ObservationIgnored`）；删 `onStateChange`；加 `resume()`；加 `extension MCPServerClientKey: DependencyKey` 的 `liveValue` | 真实实现在 MCP 包 | 3 |
| `AC/MCP/MCPServerState.swift` | 新增（移入） | 原样 | AppCore 要用这个类型 | 3 |
| `AC/MCP/MCPServerClient.swift` | 新增 | `MCPServerClient`、`inert`、`public enum MCPServerClientKey: TestDependencyKey`、`DependencyValues.mcpServerClient` | 跨层服务 | 3 |
| `MAC/MCP/MCPStatusPopoverViewModel.swift` → `AC/MCP/MCPStatusPopoverViewModel.swift`；`MCPConfigType` → `AC/MCP/MCPConfigType.swift` | 移动、拆出 | 改用 `mcpServerClient`、`Observable.tracking`、`pasteboardClient`；`public` | 可测试 | 3 |
| `RuntimeViewerMCP/Package.swift` | 修改 | `RuntimeViewerMCPBridgeTests` 加 `RuntimeViewerAppCore` 依赖 | 测试要点名 key | 3 |
| `RuntimeViewerMCP/Tests/RuntimeViewerMCPBridgeTests/MCPServerClientLiveTests.swift` | 新增 | live 值存在，状态读自服务，`resume()` 用存下的提供者 | `CrossLayerDependencyTests` 链接不到 MCP 包 | 3 |
| `ACT/MCPStatusPopoverViewModelTests.swift` | 新增 | 三种状态下按钮的动作；拷贝端口与配置走 `pasteboardClient` | 从 `NSPasteboard` / 闭包槽改成服务的部分 | 3 |
| 根 `AGENTS.md`、`RuntimeViewerPackages/Sources/AGENTS.md` | 修改 | 跨层依赖例外加 `mcpServerClient` | 同批文档 | 3 |
| `MAC/Attach Process/AttachToProcessViewModel.swift` → `AC/AttachToProcess/AttachToProcessViewModel.swift` | 移动 | `Input` 收 `RuntimeProcessAttacher.Target`；加 `Output.remoteProcessAttached`；删图标参数与 `runtimeEngineIconProvider` | 不收 UI 库的类型 | 4 |
| `MAC/Attach Process/AttachToProcessViewController.swift` | 修改 | `RunningItem` 转 `Target`；记住选中的行；收到 `remoteProcessAttached` 时记图标 | 图标只在视图层 | 4 |
| `MAC/Main/MainViewModel.swift` · `AttachAvailability` → `AC/AttachToProcess/AttachAvailability.swift` | 拆出、移动 | `public` | 一个文件一个主类型 | 4 |
| `MAC/Utils/SIPChecker.swift` → `AC/AttachToProcess/SIPChecker.swift` | 移动 | `public` | 不是 UI，`MainViewModel` 要用 | 4 |
| `RuntimeViewerPackages/Package.swift` · `RuntimeViewerAppCore` | 修改 | 声明 `RuntimeViewerInjection`（AppKit 平台） | 附加流程直接用它 | 4 |
| `AC/Activity/ToolbarActivity.swift` | 新增 | `ToolbarActivity`（含 `Segment`、`Progress`）、`idle`、`make(for:sourceName:readyDate:)`、`ActivityText` | 显示状态的值 | 5 |
| `AUI/Activity/ToolbarActivityPresenter.swift` → `AC/Activity/ToolbarActivityPresenter.swift` | 移动 | 输出 `Driver<ToolbarActivity>` | 挑选与节流归 AppCore | 5 |
| `AUI/Activity/ToolbarActivityState+Reports.swift` | 删除 | 内容进 `ToolbarActivity.swift` | 同上 | 5 |
| `AUI/Activity/ToolbarActivityState+ToolbarActivity.swift` | 新增 | `ToolbarActivityState.init(_:)` | 值到显示状态 | 5 |
| `AUT/ToolbarActivityStateTests.swift` → `ACT/ToolbarActivityTests.swift`；`AUT/ToolbarActivityPresenterTests.swift` → `ACT/` | 移动、改写 | 断言 `ToolbarActivity` | 随代码 | 5 |
| `AUT/ToolbarActivityStateConversionTests.swift` | 新增 | 每个字段一一照抄 | 转换不丢信息 | 5 |
| `AUI/RuntimeSourcePicker/RuntimeSourcePickerContent.swift` → `AC/RuntimeSourcePicker/RuntimeSourcePickerContent.swift` | 移动 | `Source.image: NSImage?` → `icon: IconDescriptor` | 回到 AppCore | 5 |
| `AUI/RuntimeSourcePicker/RuntimeSourcePopoverAdapter.swift`、`RuntimeSourceMenuAdapter.swift` 及其测试 | 修改 | 画 `source.icon.image` | 跟随描述值 | 5 |
| `AUI/Engine/RuntimeEngineIconProvider.swift` | 修改 | 按 engineID 记住最后画的图与选择器图标；`icon(forEngineID:)` 先用记下的；新增 `sourcePickerIcon(forEngineID:)` | 断开来源按 ID 取图 | 5 |
| `AUT/RuntimeEngineIconProviderTests.swift` | 新增 | 引擎离开后按 ID 仍得到最后的图标 | 新行为 | 5 |
| `AC/Engine/RuntimeEngineManager+DependencyCache.swift` | 新增 | `dependencyCacheChoices(for:)`、`pair(_:with:)` | 纯逻辑归 AppCore | 5 |
| `MAC/App/FileController.swift` | 修改 | 删 `DependencyCacheChoice` 与两段方法 | 已搬走 | 5 |
| `MAC/Main/MainViewModel.swift` → `AC/Main/MainViewModel.swift` | 移动 | `SwitchSourceState.icon`、`TitleIcon`、`activity` 改值；删 `fileController`、`runtimeEngineIconProvider` 与每窗口的图像缓存；`public` | 可测试 | 5 |
| `MAC/Main/MainRoute.swift`、`NavigationHistorySnapshot.swift` → `AC/Main/` | 移动 | 历史项的 `icon` 改 `IconDescriptor`；`public` | 随 ViewModel | 5 |
| `MAC/Main/MainWindowController.swift` | 修改 | 画标题图标；活动转显示状态；选择器图标按 ID 取并随 `recordedIconsChanged` 重取；历史菜单画描述值 | 画图在视图层 | 5 |
| `ACT/AppCoreBoundaryTests.swift` | 修改 | `allowedSystemPrefixedNames` 加 `NSItemProvider` | Foundation 类型 | 5 |
| `ACT/MainViewModelTests.swift` | 新增 | 来源状态与选择器内容的描述值、断开来源、标题图标、历史项 | 从 UI 类型改成值的部分 | 5 |
| `ACT/Support/PackageSourceScan.swift` | 修改 | 加读任意目录的入口 | 防回流检查复用 | 6 |
| `ACT/AppTargetBoundaryTests.swift` | 新增 | App 源码里不得有 ViewModel | 防回流 | 6 |
| `RuntimeViewerPackages/Sources/AGENTS.md`、`RuntimeViewerUsingAppKit/AGENTS.md`、根 `AGENTS.md` | 修改 | 见「7. 文档」 | 同批文档 | 2–6 |

## 架构图

改了什么（模块与文件的去向）：

```text
RuntimeViewerUsingAppKit (app target)
  ViewControllers, window controllers, coordinators, App/ lifecycle controllers
  views and menu glue bound to AppCore types            (unchanged, stay)
- Exporting/*ViewModel, ExportingState, ExportingRoute, ExportingStepViewModel ─┐
- BatchExporting/*ViewModel (6), BatchExportingState                             │
- Specialization/*ViewModel (4), SpecializationRoute                             │
- Generation Options/GenerationOptionsViewModel                                  ├─> RuntimeViewerAppCore
- Sidebar/RuntimeObject/SidebarRuntimeObjectScopeViewModel                       │
- MCP/MCPStatusPopoverViewModel                                                  │
- Attach Process/AttachToProcessViewModel, Utils/SIPChecker                      │
- Main/MainViewModel, MainRoute, NavigationHistorySnapshot ──────────────────────┘
- Base/CommonLoadingView, Base/LoadingButton, Utils/EventMonitor,     ─┐
  Utils/NSOutlineView+, Utils/CheckboxButton+, Content/ContentTextView,├─> RuntimeViewerUI/AppKit
  Content/ContentLineNumberRulerView, App/NavigationTransitionBackdrop ┘
- Load Frameworks/                                                   (deleted, dead code)
- App/FileController: dependencyCacheChoices, pair ──────────────────> AppCore/Engine

RuntimeViewerAppUI
- Activity/ToolbarActivityPresenter ─────────────────────────────────> AppCore/Activity
- Activity/ToolbarActivityState+Reports ─────────────────────────────> AppCore/Activity/ToolbarActivity
+ Activity/ToolbarActivityState+ToolbarActivity    init(_ activity: ToolbarActivity)
- RuntimeSourcePicker/RuntimeSourcePickerContent ────────────────────> AppCore/RuntimeSourcePicker
~ Engine/RuntimeEngineIconProvider   + remembers last icon per engineID, + sourcePickerIcon(forEngineID:)

RuntimeViewerMCPBridge
- MCPServerState ────────────────────────────────────────────────────> AppCore/MCP
~ MCPService   @Observable, - onStateChange, + resume(), + MCPServerClientKey.liveValue
+ AppCore/MCP/MCPServerClient   (TestDependencyKey, public key)

Tests
+ AppCoreTests/AppTargetBoundaryTests   fails on any ViewModel in the app target
```

依赖方向不变：

```text
app target ──> RuntimeViewerApplication (facade) ──> RuntimeViewerAppUI ──> RuntimeViewerAppCore ──> RuntimeViewerArchitectures
     │                                                     │                     ▲
     └──> RuntimeViewerMCPBridge ──────────────────────────┼─────────────────────┘ (+ live MCPServerClient)
                                                           └──> RuntimeViewerUI (+ 8 generic views)
```

数据流：工具栏活动与来源选择器的图标。

```text
Before
  MainViewModel(app) ─ ToolbarActivityPresenter(AUI) ─ select ─ make ToolbarActivityState ─ distinct ─ throttle(1s) ─> views
  MainViewModel(app) ─ runtimeEngineIconProvider(AUI).icon(for:) ─ NSImage ─> RuntimeSourcePickerContent(AUI) ─> adapters
                     └ caches last NSImage per window for the disconnected source

After
  MainViewModel(AC) ─ ToolbarActivityPresenter(AC) ─ select ─ make ToolbarActivity ─ distinct ─ throttle(1s)
      ─> MainWindowController ─ ToolbarActivityState(activity)(AUI) ─> views
  MainViewModel(AC) ─ RuntimeSourcePickerContent(AC){ icon: .runtimeEngine(engineID:) }
      ─> MainWindowController ─┬─ adapters draw icon.image ─ RuntimeEngineIconProvider.icon(forEngineID:)
                               ├─ picker.icon = sourcePickerIcon(forEngineID:)
                               └─ re-resolve on recordedIconsChanged
  RuntimeEngineIconProvider: engine gone ─> last icon drawn for that engineID ─> generic executable icon
```

附加进程的图标：

```text
AttachToProcessViewController ── Target(name, pid) ──> AttachToProcessViewModel(AC)
        │ keeps picked RunningItem                         │ inject, await injected engine
        │ <── remoteProcessAttached(engine) ───────────────┘ (before .dismiss)
        └── runtimeEngineIconProvider.record(item.icon, for: engine)   (AUI)
```

## 详细设计

### 访问级别与平台条件

- 搬进 AppCore 的每个文件整体包在 `#if os(macOS)` 里，与今天的 `SpecializationViewModel.swift:1` 相同。
- ViewModel 类、它们的 `init`、`transform`、`Input`、`Output` 及其属性都改成 `public`。
- 除 `SpecializationTypePickerViewModel.Input` 外，各 `Input` 补 `public init`，因为 VC 要构造它们。
- App 要读的其它成员：
  - `SidebarRuntimeObjectScopeViewModel.draft`（`public private(set)`）、`availableKinds`、`availableProperties`。
  - `BatchExportingCompletionViewModel.Summary`、`BatchExportingImageSelectionViewModel.Summary`。
  - `BatchExportingProgressRowViewModel` 的 `State`、`Status`、`image`、`state`，以及 `exportFailureTooltip`。
  - `BatchExportingState` 的 `currentStep`、`availableImages`、`imageTree`、`destinationURL`，以及 `BatchExportingStep`、`BatchExportingImage`（带 `public` 成员初始化方法）、`BatchExportingPerImageOutcome`、`BatchExportingObjectFailure`、`BatchExportingAggregatedResult`。
  - `GenerationOptionKeyPath`、`GenerationOptionsMutation`。
- 实现时以编译器报错为准补齐。
- 新目录名不带空格：`AttachToProcess/`、`GenerationOptions/`、`Exporting/`、`MCP/`、`Main/`、`RuntimeSourcePicker/`、`Specialization/`。App 那边的同名目录原样保留。

### 工具栏活动

```swift
// RuntimeViewerAppCore/Activity/ToolbarActivity.swift
public struct ToolbarActivity: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public enum Separator: Hashable, Sendable { case primary, space }
        public var text: String
        public var priority: Int
        public var isEmphasized: Bool
        public var separator: Separator?
    }
    public enum Progress: Hashable, Sendable {
        case determinate(percent: Int)
        case indeterminate
    }
    public var reportIdentifier: UUID?
    public var isCompleted: Bool
    public var segments: [Segment]
    public var progress: Progress?
    public var activityCount: Int

    static func idle(sourceName: String, readyDate: Date) -> ToolbarActivity
    static func make(for selection: ActivityReportSelector.Selection, sourceName: String, readyDate: Date) -> ToolbarActivity
}

// RuntimeViewerAppCore/Activity/ToolbarActivityPresenter.swift (moved)
@MainActor
public final class ToolbarActivityPresenter {
    static let updateThreshold: RxTimeInterval = .seconds(1)
    public let activity: Driver<ToolbarActivity>
    public convenience init(documentState: DocumentState)
    init(documentState: DocumentState, scheduler: SchedulerType, now: @escaping () -> Date)
}

// RuntimeViewerAppUI/Activity/ToolbarActivityState+ToolbarActivity.swift
extension ToolbarActivityState {
    public init(_ activity: ToolbarActivity)
}
```

两边相等的条件相同，所以去重与节流的次数和今天一样。`ActivityText` 原样搬过去，`RuntimeViewerUsingAppKit/AGENTS.md` 说「新的后台工作要在 `ActivityText` 里加文字」，这句仍然成立。

### 来源选择器与引擎图标

```swift
// RuntimeViewerAppCore/RuntimeSourcePicker/RuntimeSourcePickerContent.swift
public struct RuntimeSourcePickerContent: Equatable {
    public struct Source: Equatable {
        public let engineIdentifier: String
        public let title: String
        public let icon: IconDescriptor          // was image: NSImage?
        public let isCurrent: Bool
        public let isEnabled: Bool
    }
    // Section, DependencyCacheChoice, disconnectedSource, sections, dependencyCacheChoices, empty: unchanged
}

// RuntimeViewerAppCore/Main/MainViewModel.swift
public struct SwitchSourceState: Equatable {
    public let title: String
    public let icon: IconDescriptor              // was image: NSImage? + pickerIcon: RuntimeSourcePicker.Icon?
    public let isDisconnected: Bool
    public let selectedEngineIdentifier: String
}

// RuntimeViewerAppUI/Engine/RuntimeEngineIconProvider.swift
public func icon(forEngineID engineID: String) -> NSImage                         // + falls back to the last icon drawn
public func sourcePickerIcon(forEngineID engineID: String) -> RuntimeSourcePicker.Icon
```

- 记下的图按 engineID 存在 `lastIconsByEngineID` 里，进程内一直保留。条目数与出现过的引擎数相同，一般在几十个以内。
- 同一个 engineID 重新出现时，用新画的图覆盖。
- 不跟随管理器的测试值不记。

### 标题图标与历史菜单

```swift
// RuntimeViewerAppCore/Main/MainViewModel.swift
public enum TitleIcon: Hashable, Sendable {
    case application
    case imageKind(RuntimeImageKind)
}
public let toolbarIcon: Driver<TitleIcon>            // in Output

// RuntimeViewerAppCore/Main/NavigationHistorySnapshot.swift
public struct NavigationHistoryItem: RxMenuItemRepresentable, Hashable, Sendable {
    public let index: Int
    public let displayName: String
    public let icon: IconDescriptor                  // was NSImage
    public var title: String { displayName }
}
```

`MainWindowController` 构造菜单项时，按上文的规则把 `icon` 画成图（`.imageKind` 用 `coloredIcon`，其余用 `image(size: NavigationHistorySnapshot.iconSize)`）。

### 依赖缓存

```swift
// RuntimeViewerAppCore/Engine/RuntimeEngineManager+DependencyCache.swift
#if os(macOS)
extension RuntimeEngineManager {
    @MainActor
    public func dependencyCacheChoices(for engine: RuntimeEngine) -> [RuntimeSourcePickerContent.DependencyCacheChoice]
    @MainActor
    public func pair(_ engine: RuntimeEngine, with dependencyCache: RuntimeFile.DependencyCache?) async throws
}
#endif
```

- 函数体照搬，设置经 `@Dependency(\.settings)` 读取。
- 日志改用 `private extension LogCategory` 里声明的分类（根 `AGENTS.md`「Logging」）。

### MCP

```swift
// RuntimeViewerAppCore/MCP/MCPServerClient.swift
public struct MCPServerClient: Sendable {
    public var state: @MainActor @Sendable () -> MCPServerState
    public var start: @MainActor @Sendable () -> Void
    public var stop: @MainActor @Sendable () -> Void
    public static let inert = MCPServerClient(state: { .stopped }, start: {}, stop: {})
}
public enum MCPServerClientKey: TestDependencyKey {
    public static let testValue = MCPServerClient.inert
}
extension DependencyValues {
    public var mcpServerClient: MCPServerClient {
        get { self[MCPServerClientKey.self] }
        set { self[MCPServerClientKey.self] = newValue }
    }
}

// RuntimeViewerMCPBridge/MCPService.swift
extension MCPServerClientKey: DependencyKey {
    public static let liveValue = MCPServerClient(
        state: { MCPService.shared.serverState },
        start: { MCPService.shared.resume() },
        stop: { MCPService.shared.stop() }
    )
}
```

- `MCPService` 加了 `@Observable`，`state()` 读到的 `serverState` 会被 `Observable.tracking` 跟踪。
- 如果 `@Observable` 与 `@Loggable`、`isolated deinit` 或 `@Dependency` 属性包装器冲突、编不过，退路是在 `MCPServerClient` 里加一个 `observeState` 成员，返回取消令牌，`MCPService` 维护一组观察者代替单个闭包槽。退路同样去掉 `onStateChange`，选哪条写进决策日志。

### 防回流检查

```swift
// RuntimeViewerAppCoreTests/AppTargetBoundaryTests.swift
@Suite struct AppTargetBoundaryTests {
    @Test func appTargetDeclaresNoViewModel()     // name ends in ViewModel
    @Test func appTargetInheritsNoViewModel()     // ": ViewModel<", ": CellViewModel", ": ViewModelProtocol"
    @Test func appTargetDirectoryExists()
}
```

报告格式与 `AppCoreBoundaryTests` 相同，都是 `文件:行`。

### 验证

在 Ultra 上，用 agent 专属的构建目录：

1. `swift build --build-tests`：每一步的提交各编一次。
2. `RuntimeViewerAppCoreTests|RuntimeViewerAppUITests` 全量。已知的红灯：标题悬停副标题、Call Hierarchy 超时、整包跑时 `ReportSharedByEngineTests` 与 `BackgroundWorkProcessActivityTests` 各一条。
3. `RuntimeViewerMCP` 包的测试。
4. iOS 模拟器包构建（`RuntimeViewerApplication` scheme）：AppCore 有改动。
5. `./TuistScript.sh warm` 后编 macOS App（Tuist workspace，Debug）。

不做模拟器或界面验证。图标与活动显示要不要目视，由用户决定。

## 替代方案考量

- **ViewModel 进 AppUI 而不是 AppCore**——否。AppUI 是 UI 胶水层，链接 UI 库。放进去就和「ViewModel 可在不链 UI 的测试里驱动」的分层目的相反。
- **绑着 AppCore 类型的视图也挪走，进 AppUI 或拆成 RuntimeViewerUI 加绑定层**——否。用户定：它们是平台视图与 VC 基类，留在 App 符合「App 只放 VC 与平台视图」；拆开的改动最大。
- **MainViewModel 这次先留在 App**——否。用户定一起迁，UI 类型的输出全改成值。
- **`ToolbarActivityState` 搬进 AppCore，或另起一个两边都能看到的非 UI 模块**——否：
  - 搬进 AppCore：`RuntimeViewerUI` 里的活动视图接收这个类型，而 `RuntimeViewerUI` 看不到 AppCore。
  - 另起模块：只为两个值类型多一个模块。
  - 采用的做法是在 AppCore 镜像一份值，AppUI 一一转换。
- **节流留在 AppUI，AppCore 只输出挑选结果**——否。见「前期调研 · 工具栏活动」：按挑选结果节流会改变时机，而按显示状态节流就得在 AppUI 再算一遍显示状态，挑选与节流就分到了两层。
- **把设备进程的图标以图像数据（比如新的 `IconDescriptor` case）带进 AppCore**——否。这张图只在视图层存在，AppCore 存它只是为了原样交回去。由视图层在附加成功后记下更直接。
- **MCP 状态弹窗的 ViewModel 留在 App**——否。用户定走跨层服务。
- **MCP 的 key 照惯例写 `package`**——做不到。真实实现在另一个包，`package` 跨不了包。
- **跨层服务的真实实现放在 App target**——否。包测试链接不到 App，没法核对实现是否存在。放在 MCP 包，由它自己的测试核对。
- **防回流只靠 AGENTS.md**——否。用户定加测试。编译器拦不住 App 里写 ViewModel。
- **`App/` 下生命周期控制器里的非 UI 逻辑一起抽进 AppCore**——否。用户定这次不动，范围会翻倍。只有 `MainViewModel` 要用的 `FileController` 两段搬走。

## 影响

### 用户可见变化

无。工具栏、来源选择器、历史菜单、标题、导出、特化、MCP 弹窗、附加进程的外观与行为都不变。断开来源的图标原本缓存在窗口里，改成由图标表按 ID 记住，显示结果相同。

### 可发现性

不涉及。

### 数据与配置兼容

不涉及。偏好键（`ExportingDefaultsKey`、`AppDefaults`）只换了所在的模块，字符串不变；设置与 MCP 端口文件不变。

### 平台与最低版本

不变。搬进 AppCore 的文件只在 macOS 编译。iOS App 不受影响，它的 `MainViewModel` / `MainRoute` 照旧是自己的。

### 发布

不涉及权限、entitlement、隐私清单、公证或 Sparkle。

## 落地步骤

1. **通用视图进 RuntimeViewerUI，删死代码**（已完成，2026-11-18）：改动地图步骤 1 的各行。
   - 行为：`appBuildsWithGenericViewsFromRuntimeViewerUI`
   - 行为：`lineNumberRulerColorMatchesInBothAppearances`
   - 行为：`loadFrameworksStillOpensThePanel`
2. **导出、批量导出、特化、生成选项、过滤范围的 ViewModel 进 AppCore**：步骤 2 的各行。
   - 行为：`exportingCompletionRevealsDestinationThroughFinderClient`
   - 行为：`batchExportingCompletionRevealsDestinationThroughFinderClient`
   - 行为：`specializationDescriptionIsPrimaryRowTextAtThirteenPoints`
   - 行为：`specializationLoadingPlaceholderIsSecondaryRowText`
3. **MCP 状态改走跨层服务**：步骤 3 的各行。
   - 行为：`actionButtonOpensSettingsWhenDisabled`
   - 行为：`actionButtonStartsWhenStopped`
   - 行为：`actionButtonStopsWhenRunning`
   - 行为：`copyPortCopiesThroughPasteboardClient`
   - 行为：`copyConfigurationCopiesClientCommand`
   - 行为：`stateFollowsServerWithoutCallbackSlot`
   - 行为：`liveClientResumesWithStoredDocumentProvider`
4. **附加进程进 AppCore**：步骤 4 的各行。
   - 行为：`attachInputIsAProcessTarget`
   - 行为：`remoteAttachReportsInjectedEngineBeforeDismiss`
   - 行为：`attachedDeviceProcessKeepsItsRowIcon`（App 内，构建与人工核对）
5. **主窗口的 ViewModel 进 AppCore**：步骤 5 的各行。
   - 行为：`toolbarActivityMatchesFormerDisplayState`
   - 行为：`toolbarActivityThrottlesOnDisplayedValue`
   - 行为：`toolbarActivityStateCopiesEveryField`
   - 行为：`sourcePickerContentDescribesEngineIcons`
   - 行为：`disconnectedSourceKeepsEngineIconDescriptor`
   - 行为：`iconProviderReturnsLastIconForDepartedEngine`
   - 行为：`titleIconIsApplicationWithoutImage`
   - 行为：`titleIconFollowsImageKind`
   - 行为：`historyItemsDescribeObjectAndImageIcons`
   - 行为：`historyTitleMarksGeneratedInterface`
6. **防回流检查与文档收尾**：步骤 6 的各行，以及三份 `AGENTS.md` 的剩余改动。
   - 行为：`appTargetDeclaresNoViewModel`
   - 行为：`appTargetInheritsNoViewModel`
   - 行为：`appTargetDirectoryExists`

每一步各自构建通过。全部做完后跑一次「详细设计 · 验证」的完整清单，在一条功能分支上一次合进 `next`。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：要不要配使用指南或实现说明；有没有新术语要进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-18 | Created as Draft | 0091 把 App target 留到以后另立提案，App 里仍有 18 个 ViewModel 文件，其逻辑没有测试。用户要求 ViewModel 全部进 AppCore，App 只放 ViewController 与平台视图，通用视图进 `RuntimeViewerUI`。按大型重构走完整档，问了两轮。 |
| 2026-11-18 | 视图归属 | 用户定：绑着 AppCore 类型的视图（cell 视图、VC 基类、菜单与列表交互的胶水）留在 App；只有不碰 AppCore 类型的通用视图进 `RuntimeViewerUI`。否决搬进 AppUI，以及拆成「绘制进 RuntimeViewerUI、绑定留 App」。 |
| 2026-11-18 | MainViewModel | 用户定：这次一起迁，UI 类型的输出全改成值。否决先留在 App。 |
| 2026-11-18 | MCP 状态 | 用户定：AppCore 声明服务，MCP 包给真实实现。否决留在 App。 |
| 2026-11-18 | 范围 | 用户定：coordinator 与 `App/` 下的生命周期控制器不动。否决把控制器里的非 UI 逻辑一起抽进 AppCore。 |
| 2026-11-18 | 防回流 | 用户定：加 `AppTargetBoundaryTests`，读 App 的源码，发现 ViewModel 就失败。 |
| 2026-11-18 | 自定的做法 | 用户认可以下做法：路由与页面状态随 ViewModel 进 AppCore；`FileController` 的两段纯逻辑进 AppCore；工具栏活动的挑选与节流在 AppCore，转显示状态在 AppUI；来源选择器内容回到 AppCore，图标改描述值，图标表记住断开引擎的图标；附加进程的图标由视图层记；只给从 UI 类型改成值的部分补测试；一条功能分支分步提交，做完一次合进 `next`。 |
| 2026-11-18 | 调研中定下的细节 | `LoadFrameworks/` 是死代码，删除；`SIPChecker` 不是 UI，进 AppCore 而非 `RuntimeViewerUI`；嵌在 VC 里的私有小视图按 `RuntimeViewerUsingAppKit/AGENTS.md` 的规则留在原处；`RemoteProcessItemSource` 是绑着引擎的选择器胶水，留在 App；`ContentTextView` 与 `NavigationTransitionBackdropController` 不依赖 AppCore，按同一判据进 `RuntimeViewerUI`，通用视图因此是 8 个而不是先前估计的约 6 个；搬进 AppCore 的文件一律 `#if os(macOS)`，避开 iOS App 同名的 `MainViewModel` / `MainRoute`；MCP 的 key 必须是 `public`。 |
| 2026-11-18 | Accepted | 用户批准，开始实现。 |

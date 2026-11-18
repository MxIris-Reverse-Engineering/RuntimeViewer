# Draft - AppCore 不再使用 AppKit/UIKit 模型

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-18
- **最后更新**: 2026-11-18
- **所属愿景**: 无
- **关联提案**: [0091](0091-app-core-ui-split.md)（把 `RuntimeViewerApplication` 拆成 AppCore 与 AppUI；本提案推翻其中「UI 框架的模型可以留在 AppCore」一条）、[0005](0005-cellvm-appearance-single-observed.md)（cell ViewModel 的 `Appearance` 单流）、[0090](0090-image-kind-icons.md)（镜像种类图标）
- **实现分支 / PR**: `feature/app-core-without-ui-models`（worktree `.worktrees/RuntimeViewer-AppCoreWithoutUIModels`）
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

`RuntimeViewerAppCore` 的代码里不再出现 AppKit/UIKit 类型。图标和图标颜色改成描述值 `IconDescriptor`、`ColorDescriptor`；行标题改成带语义角色的 `RowText`；内容页的 ViewModel 输出 `ContentInterface`，即生成器给的语义串 `FrozenSemanticString` 加上链接与声明成员两张旁表。主题（`ThemeProfile`、`ResolvedTheme`、上色代码）整体搬进 `RuntimeViewerAppUI`，由 AppUI 的渲染环节 `ContentTextRenderer` 在后台把语义串变成富文本，只有显示富文本的 `NSTextView` 内容视图和 iOS 内容视图用它；正式构建用的 SourceEditor 视图本来就不显示上过色的富文本，从此每次显示少建一份。剪贴板和 Finder 改走跨层依赖，修饰键的换算搬进 AppUI。做完以后 AppCore 的 ViewModel 状态全是值类型，可以直接拿来序列化（为以后 Reflex 式的 `ls` / `do` 内省铺路，那是另一份提案）。边界测试加两条规则守住：不 import AppKit/UIKit，代码里不出现 AppKit/UIKit 的类型名。分四步合进 `next`，用户看到的行为不变。

## 动机

**现状。** 0091 把应用层拆成 AppCore 与 AppUI 时，定下的分界是「UI 组件不许进 AppCore，UI 框架的模型可以」（0091 决策日志 2026-11-13「边界标准」），并明确否决了「ViewModel 只输出不含 UI 类型的描述，属性串和图标交给 AppUI 渲染」，理由是「改写 cell ViewModel 的输出换不来更好的可测性」。结果是 AppCore 里有 31 个文件 import AppKit 或 UIKit：

- cell ViewModel 的 `Appearance` 装着 `NSImage` 与 `NSAttributedString`（`RuntimeObjectCellAppearance.swift:24-34`、`SidebarRootCellViewModel.swift:53-64`、`FindResultNode.swift:15-27`、`ReportCellViewModel.swift:17-23`）；
- `ContentTextViewModel` 的输出是上过主题的 `NSAttributedString`（`ContentTextViewModel.swift:70-87,651-669`），主题 `ThemeProfile` 的接口全是 `NSUIColor` / `NSUIFont`（`Theme/ThemeProfile.swift:15-25`）；
- 剪贴板与 Finder 的真实实现直接写在 AppCore 里（`ContextMenus/PasteboardClient.swift:26-31`、`ContextMenus/FinderClient.swift:23-25`）。

**新的理由，三条，都能验证：**

1. **状态要能序列化。** Shopify Engineering 的《Reflex》（2026-11-05）描述了一种架构：每个 ViewModel 暴露一份可编码成 JSON 的状态和一组可调用的动作，agent 用 `ls` 看当前界面、用 `do` 执行动作，不渲染界面就能验证行为。RuntimeViewer 已经具备其中大半（AppCore 不含 UI 组件、ViewModel 能在单测里无界面驱动、App 里有 MCP server 和 CLI 的 socket 通道），缺的是状态本身是值：一个 `NSImage` 只能序列化成像素，一个 `NSAttributedString` 里是 `NSFont`、`NSColor` 对象。今天 agent 要验证一处界面改动，只能启动整个 App 再截图，而且会和用户正开着的 RuntimeViewer 抢 CLI host 与 MCP 端口。本提案只做「状态全是值」这一步，`ls` / `do` 本身另立提案。
2. **0091 说的「换不来可测性」现在不成立了，有具体的测试为证。** AppCore 的测试今天这样断言 UI 类型：按对象身份比图标（`RuntimeObjectIconGlyphTests.swift:32-40`、`FindCrossReferenceTests.swift:172-214`、`ReportEngineGroupsTests.swift:61-86`、`InspectorReferencesViewModelTests.swift:184,196`、`SidebarRuntimeObjectCellViewModelTests.swift:177`），按像素取样比颜色（`RuntimeImageKindTests.swift:132-176`，借 `ImageColorSampling`），逐段比字体（`FindResultMemberEmphasisTests.swift:18-21,64-67`、`FindResultNodeTests.swift:155-181`）。换成描述值以后，这些断言都变成值的 `==`，「画出来对不对」只在 AppUI 的测试里验一次。
3. **正式构建每次显示都白建一份富文本。** SourceEditor 内容视图（官方构建用它）从 `RenderedInterface.attributedString` 只读 `.string`、`.link` 和 `.runtimeViewerDeclaredMember`（`ContentSourceEditorViewController.swift:154,206,447-561`），颜色取自 `semanticString` 加主题字典（`:202,372-429`），从不显示这份上过色的串。可每次显示，`ContentTextViewModel` 都要建一遍带字体颜色的富文本（`ContentTextViewModel.swift:611-619`），再整份拷成可变串加声明成员属性（`:581-603`）。把上色挪到只有 `NSTextView` 视图和 iOS 视图订阅的环节，这两步在正式构建上就没了。

## 前期调研

以下路径中 `AC/` = `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/`，`AUI/` = `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/`，`MAC/` = `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`，`IOS/` = `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/`，`T/` = `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/`，`TUI/` = `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/`。

### AppCore 里的 AppKit/UIKit 类型，按用途分

| 用途 | 文件 | 暴露 UI 类型的接口 |
|---|---|---|
| 图标 | `AC/PlatformTypes.swift`、`AC/SystemSymbol.swift:40-65`、`AC/CustomSymbol.swift:32-52`、`AC/RuntimeImageKind.swift:143-242`、`AC/RuntimeObjectIcon.swift:102-283`、`AC/Engine/RuntimeEngineIconProviding.swift`、`AC/RuntimeObject/RuntimeObjectCellAppearance.swift:24-30`、`AC/Sidebar/SidebarRootCellViewModel.swift:54`、`AC/Find/FindResultNode.swift:16-17`、`AC/Find/FindResultCellStyle.swift:48-167`、`AC/Reports/ReportCellViewModel.swift:18`、`AC/Reports/ReportViewModel.swift:591,811-829`、`AC/Reports/ReportGroupWork.swift:25,46-52`、`AC/RuntimeSourcePicker/RuntimeSourcePickerContent.swift:20,29` | `RuntimeImageKind.icon` / `iconColor` / `coloredIcon`，`RuntimeObjectIcon.icon(...)` 一族，`RuntimeObjectIconRendering`，`RuntimeEngineIconProviding`，四种 `Appearance` 的图标字段，`RuntimeSourcePickerContent.Source.image` |
| 颜色 | `AC/RuntimeImageKind.swift:166-242`、`AC/Extensions.swift:12-32,56-68`、`AC/Find/FindResultCellStyle.swift:60-62,172-203`、`AC/Theme/NSColor+Xcode.swift`，以及四种 `Appearance` 的 `iconColor` | `iconColor: NSUIColor`，`NSUIColor(light:dark:)`，`FindResultCellStyle.iconTintColor` |
| 字体 | `AC/Find/FindResultCellStyle.swift:17-43,196-201`、`AC/SystemSymbol.swift:47`、`AC/NSAttributedString+RowText.swift:20`、`AC/Sidebar/SidebarRuntimeObjectCellViewModel.swift:271` | `FindResultCellStyle.Metrics` |
| 行文字 | `AC/NSAttributedString+RowText.swift`、`AC/RuntimeObject/RuntimeObjectCellAppearance.swift:33-34`、`AC/Sidebar/SidebarRootCellViewModel.swift:57,82`、`AC/Sidebar/SidebarRuntimeObjectCellViewModel.swift:241-305`、`AC/Inspector/InspectorSwiftSpecializationCellViewModel.swift:28`、`AC/Inspector/InspectorHierarchyCellViewModel.swift:58`、`AC/Inspector/RuntimeObjectCellAppearance+Inspector.swift:26,38`、`AC/Find/FindResultNode.swift:22,237-272,355` | `title` / `subtitle` / `name: NSAttributedString` |
| 内容页与主题 | `AC/Content/ContentTextViewModel.swift`、`AC/Content/NSAttributedString+ContentLinks.swift`、`AC/Theme/ThemeProfile.swift`、`AC/Theme/ThemePreset+ThemeProfile.swift`、`AC/Theme/ResolvedThemeStream.swift`、`AC/Theme/FrozenSemanticString+ThemeProfile.swift` | `RenderedInterface.attributedString`，`Output.attributedString` / `theme`，`ThemeProfile` |
| 事件 | `AC/EditorArea/SelectionRouteDestination+ModifierFlags.swift`、`AC/Find/FindResultsOutline.swift:66-86` | `SelectionRoute.Destination.init(listClickModifierFlags:)` / `init(linkClickModifierFlags:)`，`FindResultActivation` |
| 系统服务 | `AC/ContextMenus/PasteboardClient.swift`、`AC/ContextMenus/FinderClient.swift` | `static let general` / `workspace` |
| 其他 | `AC/Then.swift:6-12,79-106`（给 `NSEdgeInsets`、`NSSuggestionItem` 等 UI 类型加的 `Then`，协议是 internal）、`AC/DocumentState.swift:8-10,456-462,559-577`（iOS 路由为满足 XCoordinator 的 `Presentable` 写的 `UIViewController`，全是 private） | 无 |
| 只 import、不用 | `AC/Inspector/InspectorViewModel.swift`、`AC/Inspector/InspectorRelationshipsCellViewModel.swift`、`AC/RuntimeObject/RuntimeObjectCellDisplayable.swift` | 无 |

`AppCoreBoundaryTests` 今天不拦这些：它的测试样例里明确放行 `import AppKit`、`NSImage(size:)`、`NSColor(name:)`、`NSMutableParagraphStyle()` 和 `var viewController: UIViewController! { nil }`（`T/AppCoreBoundaryTests.swift` 的 `lineInsideTheBoundaryIsNotReported`）。

### 内容页的渲染管线

- **取接口**（`ContentTextViewModel.swift:273-302`）：`combineLatest($runtimeObject, appDefaults.$options, transformer, marksCommentStructure)` → `Observable.async` 走接口缓存，得到 `FetchedInterface`（语义串、对象、注释结构、宏展开）→ `trackActivity(_commonLoading)`。
- **上色**（`:313-332`）：`combineLatest(interfaceStream, themeObservable)` → 在 `ConcurrentDispatchQueueScheduler(qos: .userInitiated)` 上 `renderInterface(for:theme:)` → `trackActivity(_commonLoading)` → 回主线程写 `$renderedInterface`。`renderInterface`（`:512-528`）做三件事：建上过色并带 `.link` 的富文本（`:611-619`，signpost `content.attributedStringBuild`）；从语义串建注释装饰（与主题无关）；`markingDeclaredMembers` 把富文本整份拷成可变串，逐行加 `.runtimeViewerDeclaredMember`（`:581-603`，只用到文字和 `declaredMembersByLineNumber()`）。宏展开也只用语义串（`:535-574`）。
- **加载转圈**：`_commonLoading`（`AC/ViewModel.swift:31-51`）同时盖住取接口与上色；`delayedLoading` 在变成 true 100 毫秒后才发 true，变 false 立即发。`MAC/Base/ViewControllers.swift:97-110` 把它绑到内容区的 `CommonLoadingView`。注释（`ContentTextViewModel.swift:317-324`）说明取接口与上色之间没有未计入的空档。
- **主题从哪来**：`ResolvedThemeStream`（`AC/Theme/ResolvedThemeStream.swift:18-57`，macOS 才有的依赖 `resolvedThemeStream`）把 `Settings.theme` 变成 `ResolvedTheme`；唯一使用方是 `ContentTextViewModel.swift:251-252`。测试经 `RuntimeViewerAppTestingSupport/ViewModelTestEnvironment.swift:27,42-46,58` 注入。
- **谁读上过色的富文本**：只有 `MAC/Content/ContentTextViewController.swift:156`（`NSTextView` 视图，`isRichText = false`，复制出来是纯文本）、它的行号尺读 `.font`（`MAC/Content/ContentLineNumberRulerView.swift:114-123`）、iOS 的 `IOS/Content/ContentTextViewController.swift:41`。其余读者——两种视图的右键菜单、⌘-点击、光标所在成员、高亮定位、交叉引用——只要文字、链接目标或声明成员，一张按字符位置查的旁表就够（`NSAttributedString+ContentLinks.swift:16-33` 是现在唯一的查找入口）。`NSTextView` 的链接点击靠文本里的 `.link` 属性（`ContentTextViewController.swift:89-93,119,130`），所以那份富文本里仍要写 `.link`。
- **链接目标的解析不需要 UI**：`resolveSwiftLinkTargets`（`AC/Theme/FrozenSemanticString+ThemeProfile.swift:127-182`）只用 `FrozenSemanticString.enumerateSpans`、`SemanticType`、`RuntimeObject`；外面那层 `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` 只是因为 iOS 不处理链接点击（`IOS/Content/ContentTextViewController.swift:46-83` 是注释掉的）。
- **别处不消费上过色的文本**：MCP（`MCPBridgeServer.swift:177,214`）、批量导出（`RuntimeEngine+Export.swift:50`）、CLI、右键拷贝（`ViewModel+RuntimeObjectAction.swift:25-26`）都用纯文本。
- `FrozenSemanticString` 是 `Sendable`（swift-semantic-string `Sources/Semantic/Frozen/FrozenSemanticString.swift:21`）。

### 图标的几个来源

- `SystemSymbol` / `CustomSymbol` 是符号名的枚举，`image` 才造 `NSImage`；`CustomSymbol` 的素材在 `AC/Resources/Symbols.xcassets`（`Package.swift:471-473` 的 `resources: [.process("Resources")]`），只有 `CustomSymbol.imageInAssetCatalog` 读它，只有 `RuntimeImageKind` 用它。
- `RuntimeObjectIcon.Glyph`（`AC/RuntimeObjectIcon.swift:21-50`）已经是值：文字、颜色名、样式、尺寸。0091 把它的绘制交给 AppUI（`runtimeObjectIconRendering`，live 值在 `AUI/IDEIconRuntimeObjectIconRenderer.swift:20-22`），但 AppCore 仍然自己调渲染、存 `NSImage`。这正是本提案要推广的形状，只差最后一步：AppCore 存 `Glyph`，AppUI 在绑定处渲染。
- 引擎图标（`AUI/Engine/RuntimeEngineIconProvider.swift:85-142,177-241`）取决于 `engine.source`、`engine.hostInfo.metadata` 与按 `engine.engineID` 记下的图标；`engineID` 是 `String`（`RuntimeEngine.swift:73`）。`RuntimeEngineManager.runtimeEngines`（`RuntimeEngineManager.swift:621`）汇总了它管理的全部引擎，AppUI 可以按 ID 找回引擎再画。
- Find 行的图标是按行的种类组合出来的（`AC/Find/FindResultCellStyle.swift:50-167`）：成员、函数、语言的字母徽章（都是 `Glyph`），对象图标，镜像种类图标，以及六个固定符号（匹配行、未解析、展开三角、递归调用、加载中、失败），各有自己的字号和字重。

### 事件

没有任何 AppCore 的 `Input` 收 `NSEvent` 或修饰键。视图控制器从 `OutlineViewUserActivation.triggeringEvent`（`RuntimeViewerArchitectures/NSOutlineView+UserActivation.swift:8-35`）取事件，自己调 `SelectionRoute.Destination.init(listClickModifierFlags:)` 换成「在哪打开」再交给 ViewModel（调用点 `MAC/Sidebar/RuntimeObject/SidebarRuntimeObjectViewController.swift:147-171`、`MAC/Inspector/InspectorReferencesViewController.swift:124`、`MAC/Base/RuntimeObjectListInteractions.swift:20`、`MAC/Main/MainWindowController.swift:460`、`MAC/Content/ContentTextViewController.swift:71-74,265`、`MAC/Content/ContentSourceEditorViewController.swift:452,539`、`AUI/EditorArea/JumpBar/EditorJumpBarAdapter.swift:93-94`）；`FindResultActivation` 只有 `MAC/Find/FindViewController.swift:394-411` 用。所以修饰键这一块只是把换算代码换个模块，不必新造类型。

### 系统服务与跨层依赖

- `PasteboardClient` / `FinderClient` 用 `@DependencyEntry(liveValue: .general)` / `(liveValue: .workspace)` 写在 AppCore（`PasteboardClient.swift:40-41`、`FinderClient.swift:34-35`），调用点都在 AppCore，测试经 `ViewModelTestEnvironment.swift:59-60` 换成记录器。
- 0091 定下的跨层写法：AppCore 声明 `package enum XxxKey: TestDependencyKey` 与访问器，AppUI 补 `extension XxxKey: DependencyKey` 与 `liveValue`；`TUI/CrossLayerDependencyTests.swift:14-21` 核对每个 key 在链接 AppUI 后有 live 值，现有 `AppRouterKey`、`RuntimeEngineIconProvidingKey`、`RuntimeObjectIconRenderingKey` 三个。

### 测试现状

断言 UI 类型的 AppCore 测试：`RuntimeImageKindTests`（模板、像素颜色、`===`）、`CustomSymbolTests`、`SystemSymbolTests`、`RuntimeObjectIconGlyphTests`、`RuntimeObjectIconTests`、`FindCrossReferenceTests:172-214`、`FindResultNodeTests:115,155-181`、`FindResultMemberEmphasisTests`、`InspectorReferencesViewModelTests:184,196`、`ReportEngineGroupsTests:61-86`、`ReportViewModelTests:73-75`、`InspectorCellViewModelTests:28-97`、`SidebarCellAppearanceTests:52,64`、`SidebarRuntimeObjectCellViewModelTests:177`、`SidebarRootCellViewModelTests:55`、`FindResultActivationTests`（造 `NSEvent`）、`ContentTextPipelineTests:60,109,261`（字体、上色）、`ContentCrossReferenceTests:65-85`（从富文本读声明成员属性）、`ContentLinkLookupTests`（手造富文本）。其余只比 `.string`。性能方面没有任何渲染的基准测试，只有 `content.attributedStringBuild` 一个 signpost；可参照的写法是 `T/SidebarFilterPerformanceBaselineTests.swift`。

### 前人怎么做

- **Apple 的 `ImageResource` / `ColorResource`**（macOS 27.2 SDK，`DeveloperToolsSupport.swiftmodule/arm64e-apple-macos.swiftinterface:210-220`）：`Hashable, Sendable` 的结构体，只写资源名和 bundle，由 `NSImage(resource:)`、`Color(_:)` 在 UI 层解析。模型里放描述，UI 层解析，正是本提案的形状。SwiftUI 的 `Image(systemName:)` 本身也是一份到渲染时才解析的描述。
- **Reflex**：Core 模块不 import UIKit / `android.*`，状态编码成 JSON；视图只读状态、只发动作。
- **本仓库**：`RuntimeObjectIcon.Glyph` + `runtimeObjectIconRendering`（0091）。

### 验证过什么

- 本提案写作时没有构建或测量，以上全部来自读代码。「正式构建少建一份富文本」是从调用关系推出的，第四步用测量确认（见落地步骤）。
- **推测，第二步验证**：`RuntimeEngineManager.runtimeEngines` 包含 Report 和来源选择器会显示的每一个引擎（含借出 shared cache 镜像的引擎）。不成立时，AppUI 的引擎图标查找改为由 `RuntimeEngineIconProvider` 在首次见到引擎时按 ID 记下引擎（见替代方案）。

## 提议方案

### 新的分界规则（替换 0091 的「边界标准」）

AppCore 可以用：Foundation 的值与工具类型（`NSRange`、`NSString`、`NSLock`、`NSRegularExpression`……）、CoreGraphics 的几何类型（`CGFloat`、`CGSize`）、RxSwift / RxCocoa 的 `Driver` / `Signal`、`@RxObserved`、`Router`。AppCore **不可以**：import AppKit、UIKit 或 Cocoa；在代码里写出任何 AppKit/UIKit 的类型名；用 `NSAttributedString`（虽然 Foundation 声明了它，它装的是 `NSFont`、`NSColor`）。唯一的例外是 iOS 路由：`DocumentState` 里的私有 `SelectionRouter` 和 `EmptyRouteTransitionContext` 要满足 XCoordinator 的 `Presentable` / `TransitionProtocol`，必须写 `UIViewController`，这几行连同它们需要的 `import UIKit` 记进边界测试的 `allowedLines` 并写明理由。等以后导航也搬出 App 层，这个例外再去掉。

### AppCore 产出描述值，AppUI 解析

| AppCore 的描述值 | 描述什么 | AppUI 怎么解析 |
|---|---|---|
| `IconDescriptor`（封闭枚举） | 系统符号、镜像种类的符号、对象图标与字母徽章（`Glyph`）、Find 的六个行符号、引擎图标 | `descriptor.image`（带缓存），`descriptor.image(size:)` 给固定图标尺寸的地方（Find 行） |
| `ColorDescriptor`（封闭枚举） | 图标着色：`secondaryLabel`、`tertiaryLabel`、镜像种类的颜色 | `descriptor.color` |
| `RowText`（结构体） | 一行文字：若干段，每段一个语义角色（`primary`、`secondary`、`tertiary`、`emphasized`、`hitLine`、`unresolved`），加可选字号 | `rowText.attributedString(in: RowTextStyle)`，按列表或 Find 的样式把角色换成字体和颜色 |
| `ContentInterface`（结构体） | 内容页显示的一个接口：语义串、链接表、声明成员表、注释装饰、宏展开，以及一个 ID | `interface.attributedString(themedWith:)`，由 `ContentTextRenderer` 在后台调用 |

`IconDescriptor` 和 `ColorDescriptor` 用封闭枚举而不是「结构体加静态成员」：它们只在这一个包里用，AppUI 必须给每一种画出图来，加了新种类而 AppUI 没跟上时，编译器在 AppUI 的 `switch` 处报错。

`RuntimeImageKind.icon` / `iconColor` / `coloredIcon` 和 `RuntimeObjectIcon.icon(...)` 一族以**同样的名字**搬进 AppUI 的扩展。App target 与 AppUI 里今天直接调它们的地方（`MAC/Main/MainViewModel.swift:192,199,201`、`MAC/Content/ContentImageViewController.swift:116-117`、`MAC/BatchExporting/BatchExportingImageSelectionViewController.swift:279-280`、`MAC/EditorArea/EditorPaneViewController.swift:466,469`、`MAC/Content/SourceEditorLandmarkIcon.swift:17`、`AUI/EditorArea/JumpBar/EditorJumpBarItemStore.swift:235,264,292`）经门面 `RuntimeViewerApplication` 照样看得到，一行不用改。AGENTS.md 里「图标一律取自 `RuntimeImageKind`、颜色只在一处定」的规则不变，只是那一处挪到了 AppUI。

### 内容页

```text
ContentTextViewModel (AppCore)                       AppUI / views
  fetch ─► prepare on background ─► $interface ─────► SourceEditor pane: semanticString + tables + theme
            (links, declared members,                   └─ after setSource: interfaceDisplayed(id)
             comment decorations, macros)            ─► ContentTextRenderer ─► NSTextView pane / iOS pane
  loading: fetch start … until interfaceDisplayed(id)     (themes on background, .link from the table)
                                                           └─ after setting the text: interfaceDisplayed(id)
```

- `ContentTextViewModel` 不再知道主题：去掉 `@RxObserved theme`、`@RxObserved attributedString`、`Output.attributedString`、`Output.theme`；`RenderedInterface` 换成 `ContentInterface`，`Output.renderedInterface` 换成 `Output.interface`。
- 后台的「准备」一步只建旁表：链接表（今天 `resolveSwiftLinkTargets` 与 ObjC/C 逐 token 建链接的逻辑原样搬来，只是写进表而不是属性）、声明成员表（`declaredMembersByLineNumber()` 按行范围记下，不再整份拷富文本）、注释装饰、宏展开。旁表在每个平台都建，它们不需要 UI。
- **加载转圈改成「从开始取接口，到视图报告显示完」**。`Input` 新增 `interfaceDisplayed: Signal<ContentInterface.ID>`，没有默认值，每个内容视图都必须接上（漏接就编译不过，而不是转圈永远不停）。ViewModel 发出一个接口时开始追踪一段「等待显示」，收到同一 ID 的报告才结束；旧 ID 的迟到报告不结束新接口的等待。这样 AppUI 上色的时间仍在转圈里，取接口、上色、显示之间没有空档，转圈的表现与今天相同。
- `ContentTextRenderer`（AppUI）：输入 ViewModel 的 `interface` 与主题流，在 `userInitiated` 后台队列上调 `interface.attributedString(themedWith:)`，输出 `renderedText`（接口与它的富文本），主题变了就重新上色。它另有自己的 `delayedRendering`：只换主题（例如 ⌘+ 调字号）时 ViewModel 什么都不知道，这次重新上色由它自己点亮转圈。`renderedText` 是冷的：没人订阅就不上色，所以 SourceEditor 视图只订阅 `theme` 时一份富文本都不建。
- 上色时只在 macOS 上写 `.link`（与今天一致：iOS 不处理链接点击，写了反而会把链接画成蓝色）；不再写 `.runtimeViewerDeclaredMember`，两种视图的右键菜单与光标所在成员改查 `ContentInterface.declaredMember(at:)`，链接查 `linkedRuntimeObject(at:)`，下标都是 UTF-16 偏移，与今天按 `NSAttributedString` 下标查一致。
- 主题整体搬进 AppUI：`ThemeProfile`、`ResolvedTheme`（`ThemePreset+ThemeProfile.swift`）、`ResolvedThemeStream` 与 `resolvedThemeStream` 依赖、`Settings.Theme.ColorValue.nsuiColor`。`SourceEditorThemeConversion` 不用改（它要的 `ThemeProfile` 经门面照样看得到）。两种内容视图的背景色、选中色改从 `ContentTextRenderer.theme` 取。

### 跨层服务

- `PasteboardClient`、`FinderClient`：结构体与 `inert` 留在 AppCore，改成 0091 的跨层写法（`package enum PasteboardClientKey: TestDependencyKey`，`testValue = .inert`），`general` / `workspace` 两个真实实现搬进 AppUI。两个 key 加进 `CrossLayerDependencyTests`。
- `runtimeObjectIconRendering` 与 `runtimeEngineIconProviding` 不再跨层：AppCore 不再画对象图标、不再取引擎图标，`RuntimeObjectIconRendering` 协议、它的缓存与 key 整体搬进 AppUI，成为普通的 `@DependencyEntry`；`RuntimeEngineIconProviding` 协议与 key 删除，AppCore 用 `.runtimeEngine(engineID:)`，AppUI 的 `RuntimeEngineIconProvider` 增加按 ID 取图标。两个 key 从 `CrossLayerDependencyTests` 移除。

### 修饰键

`SelectionRouteDestination+ModifierFlags.swift` 原样搬进 `AUI/EditorArea/`，`FindResultActivation` 搬进新文件 `AUI/Find/FindResultActivation.swift`。所有调用点都在 App target 或 AppUI，经门面照样可见。

### 边界测试

`AppCoreBoundaryTests` 加两条规则：

4. import AppKit、UIKit、Cocoa 或它们的子模块（`UIKit.UIGeometry`）；
5. 代码里出现 `NS` / `UI` 开头、第三个字符大写的名字，而它不在「Foundation 名字清单」里。清单只收 Foundation 声明的名字（`NSRange`、`NSMaxRange`、`NSNotFound`、`NSString`、`NSObject`、`NSObjectProtocol`、`NSLock`、`NSRegularExpression`、`NSNumber`、`NSURL`、`NSCharacterSet`、`NSRangeException` 等 AppCore 今天用到的），以及 `UIFoundationSettings` 这个模块名；`NSAttributedString`、`NSMutableAttributedString`、`NSParagraphStyle` 故意不收。用清单放行而不是列禁用名，是为了以后新冒出来的 AppKit 名字也被拦住。

两条规则从第一步就加上，同时带一份**过渡清单**：按文件列出还没清理的文件，每一步合入时删掉清完的那些，第四步结束时清单为空、规则全面生效。这样分四次合入期间，已经清干净的文件不会再被写回 UI 类型。`allowedLines` 从此不再为空，只放 iOS 路由那几行。

### 分四步合进 next

1. **系统服务与修饰键**：剪贴板、Finder 跨层；修饰键与 `FindResultActivation` 搬进 AppUI；`Then.swift` 去掉 UI 类型；去掉三个文件里没用的 import；边界测试加规则与过渡清单。
2. **图标与图标颜色**：`IconDescriptor`、`ColorDescriptor`；四种 `Appearance`、Report、Find、来源选择器改用描述值；符号、镜像种类、对象图标、引擎图标的画法与素材搬进 AppUI。
3. **行文字**：`RowText`；行标题改用它；`FindResultCellStyle`（字体、颜色、段落、尺寸）与 `NSColor+Xcode.swift` 搬进 AppUI。
4. **内容页与主题**：`ContentInterface`、显示报告、`ContentTextRenderer`；主题、`NSUI*` 别名与颜色扩展搬进 AppUI；过渡清单清空；文档更新。

这个顺序与对话里最初说的「服务和修饰键 → 图标 → 颜色、字体和主题 → 富文本」略有调整：图标颜色随图标走（第二步），行的字体颜色随行文字走（第三步），主题随内容页走（第四步），因为每种颜色、字体都只服务于其中一类输出，拆开反而要在中间状态里同时维护两套。

### 未经询问采用的做法

- 修饰键不新造类型：没有 `Input` 收事件（见调研），换算代码搬家即可。
- 剪贴板、Finder 照 0091 的跨层写法，`testValue` 用不碰系统的 `.inert`，测试照旧换成记录器。
- 图标在 AppUI 渲染并缓存；`Symbols.xcassets` 随 `CustomSymbol` 搬进 AppUI 的资源。
- AppUI 上色时写 `.link`，`NSTextView` 的链接点击原样工作；声明成员改查旁表。
- 断言渲染结果（图像、字体、颜色、富文本属性）的测试搬进 `RuntimeViewerAppUITests`；断言逻辑的测试改成断言描述值，留在 AppCoreTests。
- 性能以「不变慢」为准，第四步给上色加一条基准测试，改动前后各跑一次比较（不用 Instruments）。
- `RowText` 带可选的 `fontSize`：今天同一个 `Appearance` 的标题和副标题字号不同（Inspector 12 与 10，Open Quickly 16），字号是纯数字，留在描述值里不违反规则。
- 新类型只做成 `Hashable`（`ContentInterface` 只是 `Sendable`）与 `Sendable`，不做 `Codable`；JSON 长什么样留给 `ls` / `do` 提案。

### 非目标

- 不碰 `RuntimeViewerArchitectures`（其中 `NSOutlineView+UserActivation.swift` 带 `NSEvent`）和 `RuntimeViewerSettings`（`ApplicationRelauncher.swift` import AppKit）。AppCore 只是不再用前者的 `triggeringEvent`。
- 不做 `Codable`、不做 `ls` / `do`、不碰 MCP 与 CLI。
- 不改 iOS 路由对 `UIViewController` 的那处例外，不把导航搬出 App 层。
- 不清理测试文件里与本次搬家无关的 `import AppKit`；不动 `RuntimeViewerAppTestingSupport/ImageColorSampling.swift`（AppUITests 继续用它）。
- 不改任何用户可见的行为、外观和持久化格式。

## 改动地图

路径缩写同前期调研。「步骤」对应落地步骤的编号。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `AC/ContextMenus/PasteboardClient.swift` · `PasteboardClient` | 修改 | 去掉 import 与 `general`；`@DependencyEntry` 换成 `package enum PasteboardClientKey: TestDependencyKey`（`testValue = .inert`）与访问器 | 真实实现要用 `NSPasteboard` / `UIPasteboard` | 1 |
| `AUI/ContextMenus/PasteboardClient+Live.swift` | 新增 | `PasteboardClient.general` 与 `extension PasteboardClientKey: DependencyKey` | 同上 | 1 |
| `AC/ContextMenus/FinderClient.swift` · `FinderClient` | 修改 | 同 `PasteboardClient`，key 为 `FinderClientKey` | 真实实现要用 `NSWorkspace` | 1 |
| `AUI/ContextMenus/FinderClient+Live.swift` | 新增 | `FinderClient.workspace` 与 `liveValue` | 同上 | 1 |
| `AC/EditorArea/SelectionRouteDestination+ModifierFlags.swift` | 移动 → `AUI/EditorArea/` | 内容不变 | 收 `NSEvent.ModifierFlags` | 1 |
| `AC/Find/FindResultsOutline.swift` · `FindResultActivation` | 修改 | 移出 `FindResultActivation`，去掉 `import AppKit` | 收 `NSEvent` | 1 |
| `AUI/Find/FindResultActivation.swift` | 新增 | 搬来的 `FindResultActivation` | 同上 | 1 |
| `AC/Then.swift` | 修改 | 删掉 AppKit/UIKit 类型的 `Then` 遵循与两处 import（第一步先确认 AppCore 里没有对这些类型调 `.then`；有就随调用点一起搬） | UI 类型 | 1 |
| `AC/Inspector/InspectorViewModel.swift`、`AC/Inspector/InspectorRelationshipsCellViewModel.swift`、`AC/RuntimeObject/RuntimeObjectCellDisplayable.swift` | 修改 | 去掉没用的 import | 规则 4 | 1 |
| `T/AppCoreBoundaryTests.swift` · `AppCoreBoundary` | 修改 | 规则 4、5，Foundation 名字清单，过渡清单（第一步列出其余全部文件），`allowedLines` 收 iOS 路由几行；`lineInsideTheBoundaryIsNotReported` 的样例里删掉现在要拦的几条，挪进「要报告」的样例 | 守住新边界 | 1；2、3、4 缩短过渡清单 |
| `T/FindResultActivationTests.swift` | 移动 → `TUI/` | 内容不变 | 造 `NSEvent` | 1 |
| `TUI/CrossLayerDependencyTests.swift` | 修改 | 加 `PasteboardClientKey`、`FinderClientKey`；第二步删 `RuntimeObjectIconRenderingKey`、`RuntimeEngineIconProvidingKey` | 跨层清单 | 1、2 |
| `AC/Presentation/IconDescriptor.swift` · `IconDescriptor`、`FindResultSymbol` | 新增 | 见详细设计 | 图标的描述值 | 2 |
| `AC/Presentation/ColorDescriptor.swift` · `ColorDescriptor` | 新增 | 见详细设计 | 图标颜色的描述值 | 2 |
| `AUI/Presentation/IconDescriptor+Image.swift` | 新增 | `IconDescriptor.image`、`image(size:)`（缓存）；`ColorDescriptor.color` | AppUI 解析 | 2 |
| `AC/SystemSymbol.swift` · `SystemSymbol` | 修改 | 只留枚举与名字；`image`、`image(pointSize:weight:)`、`image(named:)` 搬走 | 造 `NSImage` | 2 |
| `AUI/SystemSymbol+Image.swift` | 新增 | 搬来的三个成员 | 同上 | 2 |
| `AC/CustomSymbol.swift` | 移动 → `AUI/CustomSymbol.swift` | 内容不变（`bundle: .module` 随之指向 AppUI 的资源包） | 只有搬走的 `RuntimeImageKind+Icon` 用 | 2 |
| `AC/Resources/Symbols.xcassets` | 移动 → `AUI/Resources/Symbols.xcassets` | 内容不变 | 同上 | 2 |
| `RuntimeViewerPackages/Package.swift` | 修改 | AppCore 去掉 `resources`，AppUI 加 `resources: [.process("Resources")]`，注释随之改 | 同上 | 2 |
| `AC/RuntimeImageKind.swift` · `RuntimeImageKind` | 修改 | 只留种类与判定；`icon`、`iconColor`、`coloredIcon` 和私有的图像、颜色常量搬走 | UI 类型 | 2 |
| `AUI/RuntimeImageKind+Icon.swift` | 新增 | 同名的 `icon`、`iconColor`、`coloredIcon` | App 的调用点不用改 | 2 |
| `AC/RuntimeObjectIcon.swift` · `RuntimeObjectIcon` | 修改 | 留 `Glyph`、`glyph(for:)`、tooltip；新增 `genericGlyph`、`specializedGlyph`、`objcImplementationGlyph`、`secondaryGlyph(for:)`；删 `icon(...)` 一族、`RuntimeObjectIconRendering`、key、`RuntimeObjectIconImageCache`、`BlankRuntimeObjectIconRenderer` | 造 `NSImage` | 2 |
| `AUI/RuntimeObjectIcon+Image.swift` | 新增 | 同名的 `icon(...)` 一族、`secondaryIcon(for:)`；`RuntimeObjectIconRendering` 协议、缓存与 `@DependencyEntry` | App 的调用点不用改 | 2 |
| `AUI/IDEIconRuntimeObjectIconRenderer.swift` | 修改 | 不再补 AppCore 的 key，改由上面的 `@DependencyEntry` 当 live 值 | 不再跨层 | 2 |
| `AC/Engine/RuntimeEngineIconProviding.swift` | 删除 | — | AppCore 改用 `.runtimeEngine(engineID:)` | 2 |
| `AUI/Engine/RuntimeEngineIconProvider.swift` · `RuntimeEngineIconProvider` | 修改 | 去掉对 AppCore 协议的遵循与 key；新增 `icon(forEngineID:) -> NSImage`，经 `RuntimeEngineManager.runtimeEngines` 找回引擎，找不到用占位图 | 解析 `.runtimeEngine` | 2 |
| `AC/RuntimeObject/RuntimeObjectCellAppearance.swift` | 修改 | 三个图标字段改 `IconDescriptor` / `IconDescriptor?` | 状态是值 | 2 |
| `AC/Sidebar/SidebarRuntimeObjectCellViewModel.swift` | 修改 | 图标改描述值（第二步）；标题改 `RowText`（第三步） | 同上 | 2、3 |
| `AC/Sidebar/SidebarRootCellViewModel.swift` · `Appearance` | 修改 | `icon: IconDescriptor?`、`iconColor: ColorDescriptor?`（第二步）；`name: RowText`（第三步） | 同上 | 2、3 |
| `AC/Inspector/InspectorSwiftSpecializationCellViewModel.swift`、`AC/Inspector/RuntimeObjectCellAppearance+Inspector.swift`、`AC/Inspector/InspectorHierarchyCellViewModel.swift` | 修改 | 图标改描述值（第二步）；标题、副标题改 `RowText`、去掉 import（第三步） | 同上 | 2、3 |
| `AC/Reports/ReportCellViewModel.swift` · `Appearance` | 修改 | `icon: IconDescriptor?`、`iconColor: ColorDescriptor?` | 同上 | 2 |
| `AC/Reports/ReportViewModel.swift` · `ReportOutline` | 修改 | 九个图标常量与 `icon(forImagePath:)`、`iconColor(forImagePath:)` 改返回描述值 | 同上 | 2 |
| `AC/Reports/ReportTreeBuilder.swift` | 修改 | 跟随 `ReportOutline` 的类型 | 同上 | 2 |
| `AC/Reports/ReportGroupWork.swift` | 修改 | `engineIcon: IconDescriptor?`，值为 `.runtimeEngine(engineID:)` | 同上 | 2 |
| `AC/Find/FindResultNode+Icon.swift` | 新增 | 从 `FindResultCellStyle` 搬来「哪种行配哪个图标」的逻辑（`crossReferenceIcon(for:)` 两个重载、徽章选择），返回 `IconDescriptor` | 逻辑留在 AppCore | 2 |
| `AC/Find/FindResultNode.swift` · `FindResultCellAppearance` | 修改 | `icon: IconDescriptor?`、`iconColor: ColorDescriptor?`，删 `iconAlpha`（第二步，淡化由 `FindResultSymbol` 在 AppUI 决定）；`title: RowText`，`makeAppearance(for:)` 不再收 `metrics`，`isContentEqual` 改 `==`（第三步） | 同上 | 2、3 |
| `AC/Find/FindResultCellStyle.swift` | 修改（第二步）→ 移动 → `AUI/Find/FindResultCellStyle.swift`（第三步） | 第二步删掉图标部分；第三步整份搬走，`Metrics`、字体、颜色、段落样式与六个符号的画法留在其中，新增把 `RowText` 角色映射成属性的 `RowTextStyle.findResult(_:)` | 渲染 | 2、3 |
| `AC/Inspector/InspectorReferencesViewModel.swift` | 修改 | 展开三角改 `.findResultSymbol(.disclosure(isExpanded:))`（第二步）；去掉 `.inspector` 尺寸（第三步） | 同上 | 2、3 |
| `AC/RuntimeSourcePicker/RuntimeSourcePickerContent.swift` · `Source` | 修改 | `image: NSImage?` → `icon: IconDescriptor?`，去掉 import | 同上 | 2 |
| `AUI/RuntimeSourcePicker/RuntimeSourceMenuAdapter.swift`、`AUI/RuntimeSourcePicker/RuntimeSourcePopoverAdapter.swift` | 修改 | 用 `icon?.image` | 解析 | 2 |
| `MAC/Main/MainViewModel.swift` | 修改 | 造来源列表时给 `.runtimeEngine(engineID:)` | 同上 | 2 |
| `MAC/Base/RuntimeObjectCellView.swift` | 修改 | 图标用 `.image`（第二步）；标题用 `attributedString(in:)`（第三步） | 解析 | 2、3 |
| `MAC/Sidebar/Root/SidebarRootTableCellView.swift` | 修改 | 同上 | 同上 | 2、3 |
| `MAC/Find/FindResultCellView.swift` | 修改 | 图标用 `image(size: metrics.iconSize)`、颜色用 `.color`（第二步）；按自己的 `metrics` 渲染标题（第三步） | 同上 | 2、3 |
| `MAC/Find/FindViewController.swift`、`MAC/Inspector/InspectorReferencesViewController.swift` | 修改 | 把 `.navigator` / `.inspector` 尺寸交给 cell 视图 | 尺寸归视图 | 3 |
| `MAC/Reports/ReportCellView.swift` | 修改 | 图标与颜色解析 | 同上 | 2 |
| `MAC/Specialization/SpecializationTypePickerCellViewModel.swift` | 修改 | 图标改描述值（第二步）；标题、副标题改 `RowText`，不再用 UIFoundation 的 `AText`（第三步） | 它造的是 AppCore 的 `RuntimeObjectCellAppearance` | 2、3 |
| `IOS/Sidebar/SidebarRuntimeObjectViewController.swift`、`IOS/Sidebar/SidebarRootViewController.swift` | 修改 | 解析图标、颜色（第二步）与 `RowText`（第三步） | iOS 也链接这两层 | 2、3 |
| `T/RuntimeImageKindTests.swift` | 修改 | 种类判定留下；模板、像素颜色、`===` 的断言搬进 `TUI/RuntimeImageKindIconTests.swift`（新增） | 渲染测试归 AppUI | 2 |
| `T/CustomSymbolTests.swift`、`T/SystemSymbolTests.swift`、`T/RuntimeObjectIconGlyphTests.swift` | 移动 → `TUI/` | 按新位置调整 import | 同上 | 2 |
| `T/RuntimeObjectIconTests.swift`、`T/FindCrossReferenceTests.swift`、`T/InspectorReferencesViewModelTests.swift`、`T/ReportEngineGroupsTests.swift`、`T/ReportViewModelTests.swift`、`T/InspectorCellViewModelTests.swift`、`T/SidebarCellAppearanceTests.swift`、`T/SidebarRuntimeObjectCellViewModelTests.swift`、`T/SidebarRootCellViewModelTests.swift` | 修改 | `===` / 像素断言改成描述值的 `==` | 状态是值 | 2 |
| `T/FindResultNodeTests.swift` | 修改 | 图标尺寸断言搬进 `TUI/FindResultCellStyleTests.swift`（新增，第二步）；字号断言同去（第三步）；`title ===` 改 `==` | 同上 | 2、3 |
| `TUI/IconDescriptorRenderingTests.swift` | 新增 | 每种描述值都画得出图，同一描述值取到同一个缓存图像，`.runtimeEngine` 找不到引擎时用占位图 | 解析的测试 | 2 |
| `AC/Presentation/RowText.swift` · `RowText` | 新增 | 见详细设计 | 行文字的描述值 | 3 |
| `AC/NSAttributedString+RowText.swift` | 移动 → `AUI/Presentation/NSAttributedString+RowText.swift` | 原有 `init(rowText:fontSize:color:)` 保留；新增 `RowText.attributedString(in:)` 与 `RowTextStyle` | 渲染 | 3 |
| `AC/Theme/NSColor+Xcode.swift` | 移动 → `AUI/Theme/NSColor+Xcode.swift` | 内容不变 | 只有 Find 的样式与 App 的 Find 页用 | 3 |
| `MAC/Sidebar/RuntimeObject/SidebarRuntimeObjectViewController.swift:346`、`MAC/Sidebar/Root/SidebarRootViewController.swift:218` | 不改（核对） | `.title.string` / `.name.string` 由 `RowText.string` 承接 | — | 3 |
| `T/FindResultMemberEmphasisTests.swift` | 修改 | 改成断言 `RowText` 的段与角色；字体断言搬进 `TUI/FindResultCellStyleTests.swift` | 同上 | 3 |
| `TUI/RowTextAttributedStringTests.swift`、`TUI/FindResultRowDrawingTests.swift` | 修改 | 覆盖 `RowText.attributedString(in:)` 的每种角色与两种样式 | 渲染测试 | 3 |
| `AC/Content/ContentInterface.swift` · `ContentInterface` | 新增 | 见详细设计；包括从 `FrozenSemanticString+ThemeProfile.swift` 搬来的链接解析与从 `markingDeclaredMembers` 改写的声明成员表 | 内容页的描述值 | 4 |
| `AC/Content/ContentTextViewModel.swift` · `ContentTextViewModel` | 修改 | 去掉 `theme`、`attributedString`、`renderedInterface`、上色环节与 `RenderedInterface`；新增 `@RxObserved interface`、`Input.interfaceDisplayed`、等待显示的追踪；`Output.interface` 取代 `renderedInterface` / `attributedString` / `theme`；高亮定位改用 `interface.string`；删掉对 `NSAttributedString` 的 `@retroactive Sendable` 与 `.runtimeViewerDeclaredMember` | 状态是值 | 4 |
| `AC/Content/NSAttributedString+ContentLinks.swift` | 删除 | 查找改由 `ContentInterface` 提供 | 同上 | 4 |
| `AC/Theme/ThemeProfile.swift`、`AC/Theme/ThemePreset+ThemeProfile.swift`、`AC/Theme/ResolvedThemeStream.swift` | 移动 → `AUI/Theme/` | 内容不变 | 主题归 AppUI | 4 |
| `AC/Theme/FrozenSemanticString+ThemeProfile.swift` | 移动并改写 → `AUI/Theme/ContentInterface+Theme.swift` | 变成 `ContentInterface.attributedString(themedWith:)`：按语义类型上色，macOS 上从链接表写 `.link` | 同上 | 4 |
| `AUI/Content/ContentTextRenderer.swift` · `ContentTextRenderer` | 新增 | 见详细设计 | 渲染环节 | 4 |
| `AC/PlatformTypes.swift` | 移动 → `AUI/PlatformTypes.swift` | `NSUIImage` / `NSUIColor` / `NSUIFont` 别名 | 最后的使用方都已搬走 | 4 |
| `AC/Extensions.swift` | 修改 | `NSUIColor(light:dark:)` 与 iOS 的 `labelColor` 一族搬进 `AUI/Extensions/NSUIColor+Adaptive.swift`（新增）；其余留下 | 同上 | 4 |
| `AC/ViewModel.swift` | 修改 | `delayedLoading` 的「true 晚 100 毫秒、false 立即」抽成 `SharedSequence<DriverSharingStrategy, Bool>.delayingTrue(by:)`，AppUI 的渲染环节复用 | 两处同一规则 | 4 |
| `MAC/Content/ContentTextViewController.swift` | 修改 | 用 `ContentTextRenderer`；显示后发 `interfaceDisplayed`；右键菜单与光标成员改查 `ContentInterface`；背景色等取 `renderer.theme`；转圈合并 `renderer.delayedRendering` | 跟随 | 4 |
| `MAC/Content/ContentSourceEditorViewController.swift` | 修改 | 直接绑 `output.interface`；`setSource` 后发 `interfaceDisplayed`；⌘-点击、菜单改查 `ContentInterface`；主题取 `renderer.theme`（不订阅 `renderedText`） | 跟随 | 4 |
| `MAC/Base/ViewControllers.swift` · `BaseViewController` | 修改 | 绑定转圈的地方改成可覆写的 `commonLoadingState: Driver<Bool>`（默认 `viewModel.delayedLoading`） | 内容视图要合并两路 | 4 |
| `IOS/Content/ContentTextViewController.swift` | 修改 | 用 `ContentTextRenderer`（主题为 `ResolvedTheme.fallback`，与今天一致）；显示后发 `interfaceDisplayed` | 跟随 | 4 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppTestingSupport/ViewModelTestEnvironment.swift` | 修改 | 去掉 `resolvedThemeStream` 注入 | 主题不在 AppCore | 4 |
| `T/ContentTextPipelineTests.swift` | 修改 | `:60`、`:109`、`:261` 三例（换字号重新上色、换字号点亮转圈、上色结果相等）搬进 `TUI/ContentTextRendererTests.swift`（新增）；其余改等 `interface`；新增显示报告的用例 | 同上 | 4 |
| `T/ContentTextViewModelTests.swift`、`T/ContentCrossReferenceTests.swift`、`T/ContentMacroExpansionTests.swift`、`T/InterfaceCommentDecorationsTests.swift`、`T/ContentTextHighlightTests.swift`、`T/DerivedDataRestoreTests.swift` | 修改 | 改读 `ContentInterface`（文字、旁表）；去掉调用签名里的主题参数 | 同上 | 4 |
| `T/ContentLinkLookupTests.swift` | 修改 | 改测 `ContentInterface.linkedRuntimeObject(at:)` / `declaredMember(at:)` 与越界 | 同上 | 4 |
| `TUI/ContentTextRendererTests.swift`、`TUI/ContentTextRenderingPerformanceTests.swift` | 新增 | 渲染环节的行为；上色的基准测试（见落地步骤 4） | 同上 | 4 |
| `RuntimeViewerPackages/Sources/AGENTS.md` | 修改 | 分界规则、描述值、跨层服务清单、资源位置、`RuntimeImageKind` 一段 | 文档同批 | 1–4 |
| `RuntimeViewerUsingAppKit/AGENTS.md:71-72,368-378` | 修改 | 「造 AppKit 对象的值在 `observeOnMainScheduler()` 之后映射」改成「在视图里解析描述值」；`Appearance` 一节写明字段是描述值 | 同上 | 2、3 |
| `AGENTS.md`（仓库根）· Package Structure | 修改 | AppCore 一行补上「代码里没有 AppKit/UIKit 类型」 | 同上 | 4 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案；落地时改编号 | 索引 | 起草、4 |

## 架构图

### 改了什么：类型的归属

```text
RuntimeViewerAppCore                                   RuntimeViewerAppUI
  Presentation/                                          Presentation/
+   IconDescriptor, FindResultSymbol                  +    IconDescriptor.image / image(size:)
+   ColorDescriptor                                   +    ColorDescriptor.color
+   RowText                                           +    RowText.attributedString(in:), RowTextStyle
                                                      ~    NSAttributedString(rowText:fontSize:color:)   (moved)
  Content/                                               Content/
+   ContentInterface (+ link / declared-member tables)+    ContentTextRenderer
~   ContentTextViewModel  (no theme, no NSAttributedString)
-   NSAttributedString+ContentLinks
  Theme/                                                 Theme/
-   ThemeProfile, ResolvedTheme, ResolvedThemeStream  +    ThemeProfile, ResolvedTheme, ResolvedThemeStream
-   FrozenSemanticString+ThemeProfile                 +    ContentInterface+Theme (attributedString(themedWith:))
-   NSColor+Xcode                                     +    NSColor+Xcode
  Icons                                                  Icons
~   SystemSymbol (names only)                         +    SystemSymbol+Image
-   CustomSymbol, Resources/Symbols.xcassets          +    CustomSymbol, Resources/Symbols.xcassets
~   RuntimeImageKind (kind only)                      +    RuntimeImageKind+Icon (icon, iconColor, coloredIcon)
~   RuntimeObjectIcon (Glyph only)                    +    RuntimeObjectIcon+Image (icon(...), renderer, cache)
-   RuntimeEngineIconProviding (+ key)                ~    RuntimeEngineIconProvider.icon(forEngineID:)
  Find/                                                  Find/
+   FindResultNode+Icon (which icon for which row)    +    FindResultCellStyle (metrics, fonts, colours, symbols)
-   FindResultCellStyle                               +    FindResultActivation
-   FindResultActivation (in FindResultsOutline)
  EditorArea/                                            EditorArea/
-   SelectionRouteDestination+ModifierFlags          +    SelectionRouteDestination+ModifierFlags
  ContextMenus/                                          ContextMenus/
~   PasteboardClient, FinderClient (+ TestDependencyKey) + PasteboardClient+Live, FinderClient+Live
-   PlatformTypes (NSUIImage / NSUIColor / NSUIFont)  +    PlatformTypes

Cross-layer keys (AppCore declares, AppUI goes live):
    AppRouterKey                                       (unchanged)
+   PasteboardClientKey, FinderClientKey
-   RuntimeObjectIconRenderingKey                      → plain @DependencyEntry inside AppUI
-   RuntimeEngineIconProvidingKey                      → deleted
```

### 内容页的数据流

```text
before
  ContentTextViewModel (AppCore)
    fetch ──► render on background: themed NSAttributedString + .link
          │                         + copy for .runtimeViewerDeclaredMember
          │   (_commonLoading tracks fetch + render)
          ▼
    $renderedInterface ──► NSTextView pane:   attributedString (displayed)
                       ──► SourceEditor pane: attributedString.string / .link / declared member
                                              + semanticString + theme dictionary

after
  ContentTextViewModel (AppCore)
    fetch ──► prepare on background: link table, declared-member table,
          │                          comment decorations, macro expansions
          │   (_commonLoading tracks fetch + prepare + "awaiting display" until interfaceDisplayed(id))
          ▼
    $interface (ContentInterface) ──► SourceEditor pane: semanticString + tables
                                  │     theme ◄── ContentTextRenderer.theme (renderedText never subscribed)
                                  │     setSource ──► interfaceDisplayed(id)
                                  └─► ContentTextRenderer (AppUI): themes on background ──► NSTextView / iOS pane
                                        setAttributedString ──► interfaceDisplayed(id)
                                        theme change ──► re-render, own delayedRendering lights the plate
```

### 图标从描述到图像

```text
cell ViewModel (AppCore)            cell view (MAC / IOS)                  AppUI
  appearance.primaryIcon  ───────►  imageView.image = icon.image  ───────► IconDescriptor.image
    = .runtimeObject(kind)                                                   ├─ .systemSymbol    → SystemSymbol.image
  appearance.iconColor    ───────►  contentTintColor = iconColor.color       ├─ .imageKind       → RuntimeImageKind.icon
    = .imageKind(kind)                                                       ├─ .glyph           → RuntimeObjectIconRendering (cached)
                                                                             ├─ .findResultSymbol→ FindResultCellStyle
                                                                             └─ .runtimeEngine   → RuntimeEngineIconProvider.icon(forEngineID:)
```

## 详细设计

### `IconDescriptor` 与 `FindResultSymbol`（AppCore）

```swift
/// An icon the application layer shows, described as a value; RuntimeViewerAppUI draws it
/// (`IconDescriptor.image`).
public enum IconDescriptor: Hashable, Sendable {
    /// A system symbol at its default configuration.
    case systemSymbol(SystemSymbol)
    /// The template symbol of a kind of image; tint it with `ColorDescriptor.imageKind(_:)`.
    case imageKind(RuntimeImageKind)
    /// A runtime object's glyph, or a letter badge drawn the same way.
    case glyph(RuntimeObjectIcon.Glyph)
    /// One of the Find navigator's row symbols, each with its own size, weight and dimming.
    case findResultSymbol(FindResultSymbol)
    /// The icon of a runtime engine, found again by `RuntimeEngine.engineID`.
    case runtimeEngine(engineID: String)
}

extension IconDescriptor {
    /// The glyph of a kind of runtime object at the default size and style.
    public static func runtimeObject(
        _ kind: RuntimeObjectKind,
        size: CGFloat = RuntimeObjectIcon.defaultIconSize,
        style: RuntimeObjectIcon.Glyph.Style = RuntimeObjectIcon.defaultIconStyle
    ) -> Self {
        .glyph(RuntimeObjectIcon.glyph(for: kind, size: size, style: style))
    }
}

/// The symbols of the Find navigator's rows that are not a runtime object's glyph.
public enum FindResultSymbol: Hashable, Sendable {
    case match
    case unresolved
    case disclosure(isExpanded: Bool)
    case recursiveCall
    case loading
    case failure
}
```

调用点：

```swift
// Sidebar cell ViewModel
appearance.primaryIcon = .runtimeObject(runtimeObject.kind)
appearance.secondaryIcon = RuntimeObjectIcon.secondaryGlyph(for: runtimeObject).map(IconDescriptor.glyph)
// Report
ReportGroupWork(…, engineIcon: .runtimeEngine(engineID: engine.engineID))
// Find
FindResultCellAppearance(icon: .findResultSymbol(.match), iconColor: .secondaryLabel, title: …)
```

### `ColorDescriptor`（AppCore）

```swift
/// A colour the application layer asks for, described as a value; RuntimeViewerAppUI resolves it
/// (`ColorDescriptor.color`) for the current appearance.
public enum ColorDescriptor: Hashable, Sendable {
    case secondaryLabel
    case tertiaryLabel
    /// The colour Xcode gives this kind of file (`RuntimeImageKind.iconColor` in AppUI).
    case imageKind(RuntimeImageKind)
}
```

只收今天真正用到的三种。以后加一种，AppUI 的 `switch` 编译不过，必须同时给出颜色。

### `RowText`（AppCore）

```swift
/// A row's text as runs of semantic roles; the list or the Find navigator that draws it decides
/// the font and colour of each role (`RowText.attributedString(in:)` in RuntimeViewerAppUI).
public struct RowText: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// The row's name.
        case primary
        /// A subtitle, an image name, the part of a name a filter did not match in Open Quickly.
        case secondary
        /// The part of a name a filter did not match in the sidebar.
        case tertiary
        /// What a filter or a search matched.
        case emphasized
        /// A Find hit line around the match.
        case hitLine
        /// A Find row whose target could not be resolved.
        case unresolved
    }

    public struct Run: Hashable, Sendable {
        public var string: String
        public var role: Role

        public init(_ string: String, role: Role = .primary)
    }

    public var runs: [Run]
    /// The point size the row is drawn at; nil takes the style's own (the Find navigator's).
    public var fontSize: CGFloat?

    public init(_ string: String, role: Role = .primary, fontSize: CGFloat? = nil)
    public init(runs: [Run], fontSize: CGFloat? = nil)

    /// The text without its roles, for type-select and accessibility.
    public var string: String { get }

    /// A copy whose characters in `ranges` (UTF-16 offsets into `string`) take `role`, the rest
    /// keeping theirs: how a filter's matches are marked.
    public func marking(_ ranges: [NSRange], as role: Role) -> RowText

    public static let empty: RowText
}
```

今天各处的写法与新写法对应：

| 今天 | 新写法 |
|---|---|
| `NSAttributedString(rowText: name, fontSize: 12, color: .labelColor)` | `RowText(name, fontSize: 12)` |
| `NSAttributedString(rowText: imageName, fontSize: 10, color: .secondaryLabelColor)` | `RowText(imageName, role: .secondary, fontSize: 10)` |
| 侧栏过滤命中：底色 `.tertiaryLabelColor`（Open Quickly 为 `.secondaryLabelColor`），命中段 `.labelColor` + semibold | `RowText(name, role: forOpenQuickly ? .secondary : .tertiary, fontSize: fontSize).marking(filterResult.ranges, as: .emphasized)` |
| Find 标题 + 「 — 副标题」 | `RowText(runs: [.init(title), .init(separator + subtitle, role: .secondary)])` |
| Find 命中行：命中段 bold + 匹配色，其余 hit line 色 | `RowText(runs: [.init(before, role: .hitLine), .init(match, role: .emphasized), .init(after, role: .hitLine)])` |

AppUI 一侧：

```swift
/// How a list draws `RowText`'s roles.
public struct RowTextStyle: Sendable {
    /// A navigator, an inspector or Open Quickly: the system font at the row's size, label colours,
    /// `.emphasized` in semibold `labelColor`, truncating the tail.
    public static let list: RowTextStyle
    /// The Find navigator's and the inspector's references: `FindResultCellStyle`'s fonts and colours.
    public static func findResult(_ metrics: FindResultCellStyle.Metrics, allowsWrapping: Bool) -> RowTextStyle
}

extension RowText {
    public func attributedString(in style: RowTextStyle) -> NSAttributedString
}
```

`RowTextStyle.list` 产出的属性必须与今天 `NSAttributedString(rowText:fontSize:color:)` 逐属性相同（字体、颜色、左对齐、尾部截断），`RowTextAttributedStringTests` 逐角色对照。

### `ContentInterface`（AppCore）

```swift
/// One interface as the content pane shows it: the generator's semantic string with what the
/// pane looks up by character position. Every index is a UTF-16 offset into `string`.
public struct ContentInterface: Sendable, Identifiable {
    /// Which interface a view reports displayed; a later interface of the same view model has a
    /// later identifier.
    public struct ID: Hashable, Sendable {
        let generation: Int
    }

    /// A jump target over a range of the text.
    public struct Link: Sendable {
        public let range: NSRange
        public let target: RuntimeObject
    }

    /// The member a line of the text declares.
    public struct DeclaredMemberLine: Sendable {
        public let range: NSRange
        public let member: RuntimeMemberReference
    }

    public let id: ID
    public let runtimeObject: RuntimeObject
    public let semanticString: FrozenSemanticString
    /// Ascending by location, never overlapping.
    public let links: [Link]
    /// Ascending by location, never overlapping.
    public let declaredMemberLines: [DeclaredMemberLine]
    public let commentDecorations: InterfaceCommentDecorations?
    public let macroExpansions: [ContentTextViewModel.MacroExpansion]

    public var string: String { semanticString.string }

    /// The object the text links to at `characterIndex`; nil off a link or out of bounds.
    public func linkedRuntimeObject(at characterIndex: Int) -> RuntimeObject?
    /// The member declared on the line holding `characterIndex`; nil off one or out of bounds.
    public func declaredMember(at characterIndex: Int) -> RuntimeMemberReference?
}
```

两个查找都按区间二分。`ID` 的初始化只在 AppCore 内可见，由 `ContentTextViewModel` 逐次加一。

`ContentTextViewModel` 改动的部分：

```swift
@RxObserved public private(set) var interface: ContentInterface?

@MemberwiseInit(.public)
public struct Input {
    // … unchanged inputs …
    /// The view has put this interface on screen; ends the loading indicator for it.
    public let interfaceDisplayed: Signal<ContentInterface.ID>
}

public struct Output {
    public let interface: Driver<ContentInterface>
    public let highlightRange: Signal<NSRange>
    public let findBarQuery: Signal<String>
    public let highlightsFirstRender: Bool
    // removed: renderedInterface, attributedString, theme
}
```

等待显示：准备好的接口在主线程写进 `$interface` 的同时，ViewModel 订阅一个只在 `interfaceDisplayed` 发来同一 ID 时完成的序列，并对它 `trackActivity(_commonLoading)`。新接口到来时 `flatMapLatest` 丢掉上一段等待，所以旧 ID 的迟到报告没有效果。ViewModel 被释放时等待随之释放。

### `ContentTextRenderer` 与主题（AppUI）

```swift
@MainActor
public final class ContentTextRenderer {
    public struct RenderedText {
        public let interface: ContentInterface
        public let attributedString: NSAttributedString
    }

    /// `themes` defaults to `@Dependency(\.resolvedThemeStream)` on macOS and to
    /// `ResolvedTheme.fallback` on the other platforms, as the content pane's theme is today.
    public init(interfaces: Driver<ContentInterface>, themes: Observable<ResolvedTheme>? = nil)

    public var theme: Driver<ResolvedTheme> { get }
    /// Themes each interface on a user-initiated background queue, again whenever the theme
    /// changes; nothing is themed while no one subscribes.
    public var renderedText: Driver<RenderedText> { get }
    /// True from 100 ms into a render until it is delivered — the plate for a theme-only change.
    public var delayedRendering: Driver<Bool> { get }
}

extension ContentInterface {
    /// The text in `theme`'s fonts and colours; on macOS each link of `links` becomes a `.link`.
    public func attributedString(themedWith theme: some ThemeProfile) -> NSAttributedString
}
```

`attributedString(themedWith:)` 保留今天的 signpost 名 `content.attributedStringBuild`，以便前后对比。`ContentTextViewController` 覆写 `commonLoadingState` 为 `Driver.combineLatest(viewModel.delayedLoading, renderer.delayedRendering).map { $0 || $1 }`。

### 跨层服务（AppCore 声明、AppUI 实现）

```swift
// AppCore
package enum PasteboardClientKey: TestDependencyKey {
    package static let testValue = PasteboardClient.inert
}
extension DependencyValues {
    package var pasteboardClient: PasteboardClient {
        get { self[PasteboardClientKey.self] }
        set { self[PasteboardClientKey.self] = newValue }
    }
}

// AppUI
extension PasteboardClientKey: DependencyKey {
    package static let liveValue = PasteboardClient.general
}
```

`FinderClient` 照写。

### 边界测试的两条新规则

```swift
enum AppCoreBoundary {
    /// Rule 4: the platform UI frameworks themselves.
    static func isPlatformUIFramework(_ moduleName: String) -> Bool  // AppKit, UIKit, Cocoa, and their submodules

    /// Rule 5: Foundation's names that start as AppKit's and UIKit's do, which RuntimeViewerAppCore
    /// may use; any other such name is a violation.
    static let foundationNames: Set<String>

    /// Files not yet cleaned up, exempt from rules 4 and 5 until the step named beside each removes
    /// them; empty once the last step lands.
    static let filesPendingCleanup: [String]
}
```

## 替代方案考量

- **维持 0091 的分界**（UI 框架的模型可以留在 AppCore）——否。状态不是值，`ls` / `do` 没法做；测试仍按对象身份与像素断言。
- **ViewModel 只改对外输出，内部计算照用 AppKit**——否。这条边界没法用测试守住：内部用不用 AppKit，扫描源码时与对外暴露分不开。
- **只抽系统服务和修饰键**——否。图标、颜色、富文本才是状态里不是值的部分，只抽服务对目标没有帮助。
- **富文本统一用 Foundation 的 `AttributedString` 加自定义属性**——否。写法统一，但大接口每次都要多一次整串转换（转成 `NSAttributedString`），而内容页已经有平台无关的 `FrozenSemanticString`，再包一层没有收益。
- **主题留在 AppCore，颜色换成 `Settings.Theme.ColorValue`、字体换成描述值**——否。AppCore 要多维护一套颜色字体的值类型，而它们只为渲染服务；主题整体归 AppUI 后，AppCore 里没有颜色字体的概念。
- **上色经跨层服务在 ViewModel 里调**（和对象图标一样，AppCore 声明、AppUI 实现，管线与线程都不变）——否。ViewModel 的状态里会多一个不透明、不能序列化的渲染结果，违背本提案的目标。
- **不加显示报告，只把 ViewModel 的转圈与渲染环节的转圈「或」起来**——否。取接口在后台结束、渲染环节在主线程收到接口后才开始，两者之间有一个 runloop 的空档；`delayedLoading` 遇 false 立即发出，转圈会先消失，上色超过 100 毫秒时再出现，即闪一下。显示报告把「等待显示」算在 ViewModel 的转圈里，没有空档。
- **`IconDescriptor` 写成结构体加静态成员**（API 设计规范里「会增加成员的选项集合」的做法）——否。它只在一个包里用，AppUI 必须给每一种画图，封闭枚举让漏画在编译期报错。
- **引擎图标的描述值带一份引擎快照**（来源、主机元数据）——否。`hostInfo.metadata` 是否 `Hashable` 未查证，而且快照会过期（附加进程的图标是之后才解析出来的，`RuntimeEngineIconProvider.swift:221-241`）。按 ID 找回引擎每次都是最新的。备选：若 `RuntimeEngineManager.runtimeEngines` 不含某些引擎，改由 `RuntimeEngineIconProvider` 在首次见到引擎时按 ID 记下它的弱引用。
- **为修饰键新造一个 `OptionSet`**——否。没有 `Input` 收事件，换算本来就在视图层做。
- **连同 `RuntimeViewerArchitectures` 与 `RuntimeViewerSettings` 一起清**——否，范围外；AppCore 只是不再用前者带 `NSEvent` 的类型。
- **新类型这次就做成 `Codable`**——否。JSON 的形状应由 `ls` / `do` 提案按实际需要定，提前定下的编码以后改起来是兼容问题。

## 影响

### 用户可见变化

无。图标、颜色、字体、行文字、内容页的显示与转圈都与今天相同；右键菜单、⌘-点击、光标所在成员、高亮、链接点击照旧。正式构建（SourceEditor 内容视图）每次显示少建一份富文本，显示应当略快或持平；`NSTextView` 内容视图与 iOS 持平。

### 可发现性

不涉及。

### 数据与配置兼容

不涉及持久化格式：主题设置（`Settings.theme`）、Find 的最近查询、Filter Scope 记忆都不变。`CustomSymbol` 的素材从 AppCore 的资源包搬到 AppUI 的资源包，包名随 target 变（`RuntimeViewerPackages_RuntimeViewerAppUI.bundle`），由 SwiftPM 与 Xcode 自动嵌入，不涉及用户数据。

### 平台与最低版本

不变。iOS 版同样链接 AppCore 与 AppUI，AppUI 的解析代码都有 UIKit 分支（`NSUI*` 别名本来就是为此设的）；iOS 内容视图的主题与今天一样固定为 `ResolvedTheme.fallback`，也一样不写链接。

### 发布

不涉及权限、entitlement、隐私清单、公证与 Sparkle。第二步要确认 Release 归档里 AppUI 的资源包确实带上了 `Symbols.xcassets`（编进 App 后打开一个 framework 镜像看图标），并跑 `./TuistScript.sh check`：本地包的资源搬家可能要 Tuist 描述跟着改。

## 落地步骤

每一步都单独合进 `next`，合入前跑 `RuntimeViewerPackages` 的两组测试（`RuntimeViewerAppCoreTests|RuntimeViewerAppUITests`）、编 macOS App，并编 iOS App（`RuntimeViewerUsingUIKit`）确认 UIKit 分支能编译。

1. **系统服务与修饰键** —— 改动地图里步骤为 1 的各行
   - 行为：`pasteboardClientResolvesToTheGeneralPasteboardOnceAppUIIsLinked`（`CrossLayerDependencyTests`）
   - 行为：`finderClientResolvesToTheWorkspaceOnceAppUIIsLinked`
   - 行为：`copyNameStillCopiesTheDisplayName`（现有 `RuntimeObjectActionTests` 照样通过）
   - 行为：`findResultActivationMapsModifierFlagsAsBefore`（搬到 AppUITests 后照样通过）
   - 行为：`appCoreImportingAppKitOutsideThePendingFilesIsReported`
   - 行为：`appCoreNamingAnAppKitTypeOutsideThePendingFilesIsReported`
   - 行为：`foundationNamesAreNotReported`
   - 行为：`theIOSRouteViewControllerIsTheOnlyAllowedLine`
2. **图标与图标颜色** —— 步骤为 2 的各行
   - 行为：`everyIconDescriptorDrawsAnImage`
   - 行为：`theSameIconDescriptorReturnsTheSameCachedImage`
   - 行为：`anUnknownEngineIDDrawsThePlaceholder`
   - 行为：`imageKindIconIsATemplateAndColoredIconIsDrawnInItsColor`（从 AppCoreTests 搬来）
   - 行为：`sidebarRowIconIsTheGlyphOfTheObjectKind`（描述值的 `==`）
   - 行为：`reportEngineGroupRowNamesItsEngineByID`
   - 行为：`findCrossReferenceRowsPickTheBadgeOfTheirLanguage`
   - 行为：`findInspectorRowsDrawIconsAtFourteenPoints`
   - 行为：`customSymbolsLoadFromAppUIsResourceBundle`
   - 行为：`runtimeEngineManagerKnowsEveryEngineTheReportShows`（验证调研里的推测；不成立就改用替代方案里的弱引用记录）
3. **行文字** —— 步骤为 3 的各行
   - 行为：`listStyleDrawsEachRoleAsTheOldRowTextInitializerDid`
   - 行为：`sidebarFilterMatchesAreEmphasizedRuns`
   - 行为：`openQuicklyUnmatchedTextIsSecondary`
   - 行为：`findHitLineMarksTheMatchAsEmphasized`
   - 行为：`findStyleDrawsEmphasisInBoldMatchColour`（从 AppCoreTests 搬来的字体断言）
   - 行为：`findResultContentEqualityComparesRowText`
4. **内容页与主题** —— 步骤为 4 的各行
   - 先在改动前的 `next` 上加 `TUI/ContentTextRenderingPerformanceTests.swift` 的前身（放在 AppCoreTests 里，调今天的 `renderAttributedString` 与 `markingDeclaredMembers`），对一个大接口（本机 AppKit 的 `NSView`）连续上色 20 次取中位数，记下数字；改完后同一测试改调 `attributedString(themedWith:)`，中位数不得高出 10%。结果写进本提案的决策日志。
   - 行为：`contentInterfaceCarriesTheLinkTableAndDeclaredMembersWithoutATheme`
   - 行为：`linkedRuntimeObjectAndDeclaredMemberLookUpByUTF16Offset`
   - 行为：`lookupsOutOfBoundsReturnNil`
   - 行为：`loadingStaysOnUntilTheViewReportsTheInterfaceDisplayed`
   - 行为：`aLateReportOfAnOlderInterfaceDoesNotEndLoading`
   - 行为：`rendererRethemesWithoutRefetchingWhenTheFontSizeChanges`（从 `ContentTextPipelineTests:60` 搬来）
   - 行为：`rendererLightsItsOwnPlateForAThemeOnlyChange`（对应 `:109`）
   - 行为：`themedTextHasTheSameFontsColoursAndLinksAsBefore`（对应 `:261`，与改动前的输出逐属性对照）
   - 行为：`rendererThemesNothingWhileRenderedTextHasNoSubscriber`
   - 行为：`iOSThemedTextCarriesNoLinks`
   - 行为：`appCoreHasNoPendingFilesLeft`（过渡清单为空）

**收尾时必须判断两件事**（判断结果写进决策日志）：

- **要不要配套专题文章**：「AppCore 只产出描述值、AppUI 解析」是以后每个新 ViewModel 都要遵守的契约，预计写进 `RuntimeViewerPackages/Sources/AGENTS.md` 就够，不另写指南；落地时再确认。
- **有没有引入新术语**：「描述值（descriptor）」可能值得进 `Documentations/Glossary.md`，落地时确认。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-18 | Created as Draft | 起因：讨论 Shopify 的 Reflex 架构能否在 RuntimeViewer 实现时，发现缺的是「ViewModel 状态全是值」这一步，而 AppCore 里还有 31 个文件用着 AppKit/UIKit 的模型。按完整档做了两轮澄清提问。 |
| 2026-11-18 | 抽离程度 | 用户定：AppCore 的代码里不出现 AppKit/UIKit 类型，由边界测试按类型名守住；iOS 路由的 `UIViewController` 作例外。否决「只改对外输出」与「只抽服务和修饰键」。这推翻了 0091 决策日志「边界标准」一条中「UI 框架的模型可以用」与「否决 ViewModel 只输出不含 UI 类型的描述」两处，理由是状态要能序列化，且可测性的收益已有具体测试为证（见动机）。 |
| 2026-11-18 | 富文本的表示 | 用户定：内容页沿用 `FrozenSemanticString` 加旁表，行标题用「文字 + 强调区间」的小结构。否决统一用 `AttributedString`。写提案时小结构具体化为「若干段，每段一个语义角色」的 `RowText`：Find 的行除了强调还有副标题、命中行、未解析三种样式，只记强调区间表达不了。 |
| 2026-11-18 | 主题的归属 | 用户定：主题整体搬进 AppUI，AppCore 只留语义色 token（`ColorDescriptor`）。否决主题留在 AppCore、换成平台无关的颜色字体值。 |
| 2026-11-18 | 合入方式 | 用户定：一份提案分四步合进 `next`。写提案时调整了每步的内容（图标颜色随图标、行的字体颜色随行文字、主题随内容页），理由见提议方案「分四步合进 next」。 |
| 2026-11-18 | 上色在哪里跑 | 用户定：AppUI 的渲染环节在后台上色，耗时计入转圈。否决经跨层服务在 ViewModel 里调。写提案时为消除取接口与上色之间的转圈空档，加了「视图报告显示完」的输入（替代方案里写了不加它会怎样）。 |
| 2026-11-18 | 下层模块 | 用户定：只管 AppCore，`RuntimeViewerArchitectures` 与 `RuntimeViewerSettings` 不动。 |
| 2026-11-18 | Codable | 用户定：新类型这次只做成 `Hashable` / `Sendable`，`Codable` 留给 `ls` / `do` 提案。 |
| 2026-11-18 | 共识 | 用户确认以上决定和「未经询问采用的做法」作为写提案的共识。 |
| 2026-11-18 | Accepted | 用户批准，开始实现。四步共用一条功能分支，每做完一步就先在本地合进 `next` 的检出给用户看，用户同意后再推送 `next`、开始下一步；编号与 Implemented 等第四步合入后再定。 |

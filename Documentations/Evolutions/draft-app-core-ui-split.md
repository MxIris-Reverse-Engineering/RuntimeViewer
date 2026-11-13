# Draft - 把 RuntimeViewerApplication 拆成 AppCore 与 AppUI

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-13
- **最后更新**: 2026-11-13
- **所属愿景**: 无
- **关联提案**: [0016](0016-application-viewmodel-tests.md)（ViewModel 测试覆盖）、[0035](0035-engine-management-module.md)（引擎管理下沉为无 UI 模块）、[0048](0048-routes-carry-no-views.md)（Route 不携带视图）、[0073](0073-core-source-layout.md)（Core 源码按功能分目录，只搬家）
- **实现分支 / PR**: `feature/app-core-ui-split`（worktree `.worktrees/RuntimeViewer-AppCoreUISplit`）
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

`RuntimeViewerApplication` 现在一个模块装着两类东西：一类是 ViewModel、`DocumentState`、后台工作这些能测的应用逻辑；另一类是 UI 胶水，比如给 AppKit / AppKitPlus 控件当 delegate、往菜单和弹窗里填内容的 adapter。本提案把它拆成两个 target：

- **`RuntimeViewerAppCore`**：放全部 ViewModel（含 cell ViewModel 与路由）和应用逻辑。这里的代码必须能在单元测试里构造、驱动；可以用 `NSImage`、`NSColor`、`NSAttributedString` 这类 UI 框架的模型，但不出现任何 UI 组件。
- **`RuntimeViewerAppUI`**：依赖 AppCore，放从这里拆出来的业务 UI 胶水——6 个控件 adapter、编辑栏路径栏的条目、打开设置窗口的 coordinator、引擎图标、工具栏活动的 presenter，以及画 Xcode 风格对象图标的实现。

AppCore 不依赖任何 UI 库：本仓库的 `RuntimeViewerUI`、`RuntimeViewerSettingsUI` 不依赖，上游的 UIFoundation、SFSymbols、AppKitPlus 也不依赖，经 `RuntimeViewerArchitectures` 间接依赖也不行。替代办法是：

- `NSUI*` 别名自己定义；属性串手写，不用 builder；系统图标直接调系统 API。
- Find 查询的 pattern 模型与正则拼接，在 AppCore 里照 AppKitPlus 重写一份，再用对照测试守住两边一致。
- Xcode 风格字母图标的绘制，经依赖注入交给 AppUI。
- `RuntimeViewerArchitectures` 里驱动 AppKitPlus 导航的转场挪到 AppUI。

AppCore 要用、但实现只能放在 AppUI 的服务，按 swift-dependencies 的「接口与实现分开」写法接入。`RuntimeViewerApplication` 保留下来，只做再导出的门面，两个 App 的 import 和 Xcode 工程都不用改。分界规则写进 AGENTS.md，再由一个跟着包测试一起跑的检查守住。整件事分四次合进 `next`，用户看不到任何变化。

## 动机

1. **UI 胶水和应用逻辑混在一个模块。** 138 个文件里有 46 个直接用到 UI。其中一部分只是用了 UI 框架的模型（cell ViewModel 产出的属性串和图标），这没有问题。另一部分本身就是 UI 胶水：`NavigatorTextFilterFieldAdapter` 设置 `NSFilterTokenField` 并当它的 delegate；`RuntimeSourceMenuAdapter` 往弹出按钮的菜单里填项；`FindResultsPresentation.apply(to:)` 直接改 `NSOutlineView` 的展开与选中。它们和 ViewModel 放在一起，结果 ViewModel 所在的模块不得不依赖 `RuntimeViewerUI`、`RuntimeViewerSettingsUI` 和 AppKitPlus 的控件。
2. **没有规则说 UI 胶水该放哪。** `RuntimeViewerUsingAppKit/AGENTS.md` 规定业务逻辑不进 ViewController，却没说 ViewController 之外的 UI 胶水放哪，于是它们都落进了 ViewModel 的模块。[0048](0048-routes-carry-no-views.md) 只管住了路由和 `Input` 不带视图。
3. **想只测逻辑，也得把整套 UI 栈编进来。** `RuntimeViewerApplicationTests` 的 155 个文件里，约 30 个测的是 UI 组件：AppUI 一侧的 adapter，以及 `RuntimeViewerUI` 自己的视图（`StatefulOutlineView`、`NavigatorScrollViewLayout`、`TitleToolbarItem`……）——`RuntimeViewerUI` 没有自己的测试 target。测一个 ViewModel，得把这些全编进来。
4. **没有自动检查。** 现有唯一的源码检查 `CrossPlatformSourceGuardTests` 管的是 iOS 构建会不会编进只有 macOS 才有的模块，不管 UI 组件出现在哪个模块。
5. **和用户自己定的分层不一致。** 用户的 ApplicationScaffold 模板把 `<Name>AppCore` 定为不依赖 UI 框架的 ViewModel 层（模板 `Template/__NAME__Package/Package.swift` 里 `__NAME__AppCore` target 的注释，以及 `Documentations/ScaffoldDesign.md`「取舍记录」）。RV 的这一层成型比模板早。

## 前期调研

### 现状

- **规模**：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/` 有 138 个 Swift 文件、约 25,200 行，30 个 ViewModel 类。判定「碰到 UI」的口径：去掉注释后，import 了 AppKit、UIKit、`RuntimeViewerUI`、AppKitPlus、RxAppKit、UIFoundation、`RuntimeViewerSettingsUI`、CocoaCoordinator 之一，或用到 NS / UI 的视图、图像、颜色、字体、属性串等类型。按这个口径有 46 个文件。
- **使用方**：macOS App 93 个文件、iOS App 12 个、MCP bridge 1 个（`RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPBridgeServer.swift`，只用到 `DocumentState`）、测试 120 个——测试全部写的是 `@testable import RuntimeViewerApplication`。两个 Xcode 工程（`RuntimeViewerUsingAppKit.xcodeproj`、`RuntimeViewerUsingUIKit.xcodeproj`）链接的是 product `RuntimeViewerApplication`。Tuist 在 `Tuist/ProjectDescriptionHelpers/LocalPackages.swift` 里列着这个包的各个 target。
- **对 `RuntimeViewerUI` 的使用**：Application 里有 24 个文件 import 它，但只有 4 个真正用到它的类型：
  - `Activity/ToolbarActivityPresenter.swift`、`Activity/ToolbarActivityState+Reports.swift`：用 `ToolbarActivityState`、`ActivityTextSegment`。
  - `RuntimeSourcePicker/RuntimeSourcePopoverAdapter.swift`：用 `RuntimeSourcePicker`、`RuntimeSourcePopoverCellView`。
  - `Engine/RuntimeEngineIconProvider.swift`：用 `DeviceGlyph`、`RuntimeSourcePicker.Icon`。

  其余 20 个只是靠它再导出的 SFSymbols 与 UIFoundation（`RuntimeViewerUI/RuntimeViewerUI.swift`）。
- **跨层服务**：
  - `appRouter` 声明在 `AppCoordinator.swift`，写法是 `@DependencyEntry(liveValue: AppCoordinator.shared)`。用它的有 `ViewModel.swift` 的基类和 `Reports/ReportViewModel.swift:231-244`，App 里还有 `AppDelegate` 与 `MCPStatusPopoverViewModel`。
  - `runtimeEngineIconProvider`（`Engine/RuntimeEngineIconProvider.swift:273-279`，`@MainActor` 的 final class）被 `Reports/ReportGroupWork.swift:49`、`EditorArea/JumpBar/EditorJumpBarItemStore.swift:222` 和 App 的 `Attach Process/AttachToProcessViewModel.swift:69` 使用。
  - 测试一直在覆盖 `appRouter`：`ReportViewModelTests.swift:273-277` 换成 `MockRouter<AppRoute>`。
- **数据**：Application 里没有 `NSKeyedArchiver`、`NSStringFromClass`、`@objc(名字)`，也没有按类型名拼出来的存储键。类型换了模块，已存的设置、书签与 autosave 都不受影响。
- **在途分支**：还没合进 `next` 的分支里，只有用完即弃的 `prototype/comment-tag-styles` 改过这里的 1 个文件。

### 基础设施本身连着 AppKit（决定保留）

- `Driver` / `Signal` 定义在 RxCocoa（`RxCocoa/Traits/Driver/Driver.swift`），而 RxCocoa 有 8 个 macOS 文件 `import Cocoa`。`@RxObserved` 所在的 RxSwiftPlusMacro 依赖 RxSwiftPlus，RxSwiftPlus 又依赖 RxCocoa（见 RxSwiftPlus `Package.swift` 里的这两个 target）。`Router` 来自 CocoaCoordinator，它有 24 个文件 `import AppKit`。这三个库都不再导出 AppKit，RxCocoa 只再导出 RxRelay（`RxCocoa/RxCocoa.swift:12`）。
- iOS 上，XCoordinator 的 `Router` 继承 `Presentable`，要求实现 `viewController: UIViewController!`。`DocumentState.swift:477-500` 的 `SelectionRouter` 为此返回 `nil`；`:576` 起还有一个 UIKit 版的空 `TransitionProtocol`。
- `RuntimeViewerArchitectures` 再导出 RxAppKit、CocoaCoordinator 与 RxCocoaCoordinator（`RuntimeViewerArchitectures.swift:15-19`）。
- 讨论中定下：这些都是基础设施，照常使用。AppCore 是否「链接」AppKit 不是判断标准，标准是代码能测、不出现 UI 组件。

### AppCore 一侧对三个上游库的实际用量

把要搬进 AppUI 的文件去掉后，剩下 126 个文件。

- **`NSUI*` 别名**：用到的只有 `NSUIImage`（31 处）、`NSUIColor`（21 处）、`NSUIFont`（15 处）。SFSymbols（`Sources/SFSymbols/SFSymbols.swift:5-7`）和 UIFoundation 的 `UIFoundationTypealias` 各自公开导出了一份同名别名，`RuntimeViewerUI` 把两者都再导出了，现在用到这些别名的文件照样能编过。所以同名、指向同一类型的别名并存不会冲突，AppCore 再定义一份也不会和它们撞车。
- **UIFoundation 的其他用法**：
  - `NSAttributedStringBuilder`：只有 7 处，在 `InspectorHierarchyCellViewModel`、`InspectorSwiftSpecializationCellViewModel`、`RuntimeObjectCellAppearance+Inspector`（2 处）、`SidebarRootCellViewModel`、`SidebarRuntimeObjectCellViewModel`（2 处）。写法全都一样：一段文字，系统字体某个字号，可选的前景色，左对齐，尾部截断。
  - `NSAppearance.isLight`：只有 `Extensions.swift:84` 一处。UIFoundation 的实现是 `bestMatch(from: [.darkAqua, .aqua]) == .aqua`。
  - `IDEIcon`、`IDEIconColor`、`IDEIconStyle`：`RuntimeObjectIcon.swift`（每一行运行时对象前面的 Xcode 风格字母图标）和 `Find/FindResultCellStyle.swift`（Find 成员行的角标）在用。实现在 UIFoundation 的 `UIFoundationShared/IDEIcons/`，共 4 个文件、756 行，只依赖类型别名；而 `UIFoundationShared` 只能经 `UIFoundation` 总模块拿到。`RuntimeObjectIcon` 的公开签名里带着 `IDEIconColor`、`IDEIconStyle`；App 一侧没有直接写这两个类型名，只有测试 `FindCrossReferenceTests.swift:178` 写了。
  - 主题里的 `nsuiColor` 是 Application 自己定义的（`Theme/ThemePreset+ThemeProfile.swift:167`、`:183`），不是 UIFoundation 的。
- **SFSymbols**：只在 3 个文件里造了 18 个图标——`Extensions.swift` 4 个、`Find/FindResultCellStyle.swift` 7 个、`Reports/ReportViewModel.swift` 7 个，全是公开的系统符号。它造图的做法是 `NSImage(systemSymbolName:)` / `UIImage(systemName:)`，有配置时再 `withSymbolConfiguration`，找不到符号就 `fatalError`（`SFSymbols.swift:211` 起）。RV 没有打开它的 `PrivateSymbols` trait。
- **AppKitPlus**：只有 Find 查询一处，但用得深。
  - `Find/FindQueryTerm.swift` 就是把 `NSFindPatternComponents` 包了一层：纯文本（`plainText`）、有没有 pattern（`hasPatterns`）、把文字和 pattern 拼成正则（`regularExpressionPattern(escapingText:)`），以及最近查询的存盘格式（`propertyListRepresentation`）都靠它。
  - 存盘格式是 Xcode 查找框写进粘贴板的那种：文字是字符串，pattern 是一个字典，键名是 `NSFindPatternRegularExpressionKey`、`NSFindPatternDisplayStringKey`、`NSFindPatternTokenStringKey`、`NSFindPatternTokenReplacementStringKey`、`NSFindPatternTokenAllowsBackreferencesKey`、`NSFindPatternTokenIsNegationKey`、`NSFindPatternTokenUniqueIDKey`。每个 pattern 自带它的正则，所以读盘本身不需要 AppKitPlus。
  - 拼接规则在本机 AppKitPlus 源码 `AppKitPlus/Text Fields/Filter Text Fields/NSFindPattern.m` 里，大约 120 行：
    - 数一段正则里有几个捕获组：`NSPLFindPatternCaptureGroupCount`，第 28 行起。
    - 转义正文：给 `$()*+./?[\]^{|}` 前面加反斜杠，第 61 行起。
    - 拼接：第 463 行起。允许反向引用的 token 第一次出现时包成捕获组，同一标识再出现时写成 `(?:\N)`；不转义正文时，编号要跳过正文自己的组。
    - 属性表读写：第 310 行起。

    AppKitPlus 为这些写了 25 个测试（`AppKitPlusTests/Text Fields/Filter Text Fields/NSFindPatternTests.m`）。
  - `Find/FindRecentQueries.swift` 的 `attributedTitle(for:font:)` 用 `NSFindPatternComponents.attributedString(font:textColor:)` 把 token 画成胶囊，只给 `FindQueryFieldMenuAdapter` 造菜单项标题用。
- **间接依赖**：
  - `RuntimeViewerArchitectures` 依赖 AppKitPlus，原因只有一个文件 `Transition+Navigation.swift`：coordinator 驱动 AppKitPlus 的 `NSNavigationController` 做 push / pop。用它的只有 App 的 `Sidebar/SidebarCoordinator.swift`，那个文件同时 import 了 `RuntimeViewerApplication`。
  - RxAppKit 的 AppKitPlus trait 默认关着（它的 `Package.swift` 里没有 `.default(enabledTraits:)`）。
  - `RuntimeViewerSettings` 依赖的 `UIFoundationSettings` 自己没有依赖。

  所以 Architectures 去掉那个文件以后，AppCore 的依赖图里就没有 AppKitPlus 了。UIFoundation 这个包仍会经 `UIFoundationSettings`（设置存储，不含任何组件）出现在依赖图里。

### 上游能提供什么

- **swift-dependencies**（1.17.1 起）：文档 `Documentation.docc/Articles/LivePreviewTest.md` 的「Separating interface and implementation」一节给出了标准写法——接口模块里让依赖遵循 `TestDependencyKey`、只给测试值；实现模块里补上 `DependencyKey` 和 `liveValue`。
- **可复用的检查**：`RuntimeViewerApplicationTests/CrossPlatformSourceGuardTests.swift` 已经会读包清单、逐个 target 扫描源码，并按 iOS 求值 `#if`。新的边界检查直接复用它的扫描。

### 测试现状

- 共 155 个文件、约 27,900 行。约 30 个测的是 UI 组件，名单见「详细设计 · 测试」，其中多数测的是 `RuntimeViewerUI` 的视图。
- 以文件名为主类型名统计，126 个类型里有 21 个从未在测试里出现，例如 `RuntimeEngineActivityReporter`、`RuntimeConnectionNotificationService`、`FindCrossReferences`、`EditorAreaViewModel`。其中 `RuntimeConnectionNotificationService` 直接调用 `UNUserNotificationCenter.current()`（`Engine/RuntimeConnectionNotificationService.swift:25`），按现在的写法测不了。

## 提议方案

### 模块关系

```
App（macOS）、App（iOS）              MCP bridge
        │                                 │
        ▼                                 │
RuntimeViewerApplication                  │   纯门面：@_exported import 下面两个
   │                                      │
   ├──► RuntimeViewerAppUI                │   业务 UI 胶水、跨层服务的真实实现
   │      ├─ RuntimeViewerUI、RuntimeViewerSettingsUI
   │      ├─ UIFoundation、AppKitPlus
   │      └─ RuntimeViewerAppCore
   │                                      ▼
   └──► RuntimeViewerAppCore ◄────────────┘   ViewModel、cell ViewModel、路由、DocumentState、
          │                                   后台工作、Find、过滤、存储、主题
          └─ RuntimeViewerArchitectures（不再依赖 AppKitPlus）、RuntimeViewerSettings、
             EngineManagement、HelperClient、CatalystExtensions、Core 系列
```

### 分界规则

**AppCore 里的代码必须能测，且不出现 UI 组件，也不依赖任何 UI 库。**

- **可以放**：
  - ViewModel、cell ViewModel、路由、`DocumentState` 与各种状态和服务，以及可测的逻辑。
  - UI 框架的模型：`NSImage` / `UIImage`、`NSColor` / `UIColor`、`NSFont`、`NSAttributedString`、`NSEvent` 与它的 `ModifierFlags` 这类值，以及 AppCore 自己定义的 `NSUIImage` / `NSUIColor` / `NSUIFont` 别名。
  - `Driver` / `Signal`、`@RxObserved`、`Router` 这些基础设施。
  - 系统服务的可替换依赖：粘贴板、Finder、系统通知。
- **不能放**：
  - 视图、控件、cell、菜单、弹窗、窗口、view controller 等 UI 组件的子类与构造。
  - 控件的 delegate、data source 与 adapter，以及 coordinator 的实现。
  - 对 `RuntimeViewerUI`、`RuntimeViewerSettingsUI`、SwiftUI、SnapKit、AppKitPlus、SFSymbols 的 import；UIFoundation 的模块里只许 import `UIFoundationSettings`。
- **允许的例外**：iOS 上 `SelectionRouter` 为满足 XCoordinator 的 `Router` 协议而返回 `nil` 的 `viewController`，以及空的 `TransitionProtocol`。它们只是协议形状，没有构造任何组件。

### 文件归属

- **整体搬进 AppUI**：Application 里的 10 个文件，加上 `RuntimeViewerArchitectures` 的 `Transition+Navigation.swift`。
- **拆开**：5 个——UI 那一半进 AppUI，模型、逻辑或接口那一半留在 AppCore。
- **其余文件**：留在 AppCore，只改 import 和对三个上游库的用法。

逐个文件见「详细设计 · 文件归属」。

### 跨层服务

AppCore 要用、但实现只能放在 AppUI 的服务有三个：

- 打开设置窗口的 `appRouter`；
- 引擎图标；
- 把对象图标的文字、颜色、样式画成图（由 `IDEIcon` 实现）。

做法是：接口和测试值放 AppCore，真实实现和 `liveValue` 放 AppUI，照 swift-dependencies 文档里「接口与实现分开」的写法。根 `AGENTS.md`「Singletons & Dependency Injection」规定一律用 `@DependencyEntry`，这里开一个只限这一类依赖的例外。

### AppCore 不依赖 UIFoundation、SFSymbols、AppKitPlus

- **别名**：AppCore 自己公开定义 `NSUIImage`、`NSUIColor`、`NSUIFont`，按平台指向 AppKit 或 UIKit 的类型。
- **属性串**：7 处 builder 换成一个手写的初始化方法 `NSAttributedString(rowText:fontSize:color:)`。
- **外观判断**：`isLight` 换成同样的 `bestMatch(from: [.darkAqua, .aqua]) == .aqua`。
- **系统图标**：18 个图标改用 AppCore 自己的 `SystemSymbol` 枚举。每个 case 的 raw value 是符号名，直接调系统 API 造图，找不到符号时同样 trap。`SystemSymbolTests` 逐个载入全部 case，补回 SFSymbols 原先在编译期做的名字检查。
- **对象图标**：`RuntimeObjectIcon` 选什么文字、什么颜色，以及按描述缓存图片，都留在 AppCore；只有「画」这一步经依赖注入交给 AppUI，由 AppUI 用 `IDEIcon` 实现。描述里的颜色与样式是 AppCore 自己的枚举，取值与 `IDEIconColor`、`IDEIconStyle` 同名，所以调用处不用改。Find 成员行的角标走同一个接口。
- **Find 查询**：AppCore 自己定义 `FindQueryTerm` 的组成（文字与 `FindPattern`），用 Swift 照 `NSFindPattern.m` 逐字重写四件事：数捕获组、转义、拼接、属性表读写，并照搬 AppKitPlus 的 25 个测试。存盘格式不变，已存的最近查询照常读回。AppUI 在查询框与 `FindQueryTerm` 之间按属性表互转。AppUI 的测试里另加一组对照测试，逐例比较 AppCore 与 AppKitPlus 拼出的正则；AppKitPlus 升级后规则一变，这组测试就会失败。`FindRecentQueries.attributedTitle(for:font:)` 要画 token，随菜单 adapter 搬进 AppUI。
- **间接依赖**：`Transition+Navigation.swift` 从 `RuntimeViewerArchitectures` 挪进 AppUI，Architectures 去掉对 AppKitPlus 的依赖。`SidebarCoordinator` 经门面照样拿得到这些转场。

### 越界检查

在 `RuntimeViewerAppCoreTests` 里加一组 `AppCoreBoundaryTests`，复用 `CrossPlatformSourceGuardTests` 的扫描：AppCore 的源码里一旦出现「不能放」的写法，测试就失败，报出「文件:行」和原因。规则本身写进 `RuntimeViewerPackages/Sources/AGENTS.md`，根 `AGENTS.md` 的包结构一节指过去。

### 测试

- **`RuntimeViewerAppCoreTests`**：只依赖 AppCore 与 Core 系列，装下现有测试里测 AppCore 的大多数，以及新增的 `SystemSymbolTests`、移植过来的查找 pattern 测试。
- **`RuntimeViewerAppUITests`**：依赖 AppUI、`RuntimeViewerUI` 与 AppKitPlus，装下测 AppUI 和 `RuntimeViewerUI` 视图的约 30 个文件，以及正则对照测试。
- **`RuntimeViewerAppTestingSupport`**：两边都要用的测试帮手放进这个新的普通 target，只给这两个测试 target 依赖。

### 门面与使用方

- `RuntimeViewerApplication` 只剩一个文件，内容是两行 `@_exported import`。product 名不变，所以两个 App 的 import、两个 Xcode 工程和 Tuist 的 App 工程描述都不用动。
- MCP bridge 改成直接依赖 `RuntimeViewerAppCore`：它只用 `DocumentState`，不该经门面带上 AppUI。

### 分四次合进 `next`

每一步都能单独构建、测试全绿，各自更新文档与 Tuist 描述，详见「落地步骤」。

1. 建 target 与门面，把 UI 胶水搬进 AppUI。
2. 接口与实现分开，AppCore 不再依赖视图库、UIFoundation 与 SFSymbols。
3. AppCore 不再依赖 AppKitPlus：Find 查询模型、对照测试，以及挪走转场文件。
4. 拆测试，加越界检查。

### 未经询问采用的做法

下面几条是由上面的决定推出来的，讨论时没有单独问：

- 新建测试帮手 target `RuntimeViewerAppTestingSupport`。测试 target 之间不能互相依赖，而 AppUI 一侧也要用 `TestRuntimeEngine`、`ViewModelTestEnvironment`、`FindResultFixtures`、`AsyncObservation`。它用到的 AppCore 成员开到 `package`，不用 `@testable import`。
- `RuntimeViewerUI` 视图的测试随 AppUITests 走，这次不给 `RuntimeViewerUI` 建自己的测试 target。
- AppUI 要用到的 AppCore `internal` 成员改成 `package`，不改成 `public`。
- `Then.swift` 留在 AppCore。它的 `Then` 协议是 `internal` 的，AppUI 要用 `.then {}` 时自带一份，和 `RuntimeViewerUI` 现在的做法一样。
- `RuntimeConnectionNotificationService` 留在 AppCore。它对 `UNUserNotificationCenter` 的调用改成走一个可替换的依赖，并补一组测试，证明它现在能测——测什么时候发、发什么。
- 新增的 `SystemSymbolTests`、移植的查找 pattern 测试和正则对照测试，都是为替换上游库而加的。除此之外，不为没有测试的类型补测试。
- 新代码照 `RuntimeViewerCore/Sources/AGENTS.md` 的做法按功能分目录；搬进来的文件保持原来的子目录结构。

### 非目标

- 不改 `RuntimeViewerUI` 与 App target 的内容。`RuntimeViewerArchitectures` 只挪走 `Transition+Navigation.swift`。ViewModel 的写法约定（`Driver` / `Signal`、`@RxObserved`、`Router`）不改。
- 不把 ViewModel 的输出改成不含 UI 类型的描述。属性串和图标照旧由 ViewModel 产出，只是图标的绘制经接口完成。
- 不追求链接级的纯净：AppCore 仍会经 RxCocoa、CocoaCoordinator 间接链接 AppKit。
- 不改 UIFoundation、SFSymbols、AppKitPlus 本身，也不改 Find 查询的行为与存盘格式。
- 不给 `RuntimeViewerUI` 建自己的测试 target。
- 不把 MCP bridge 搬出 App 进程（那是愿景《无头 RuntimeViewer》的事）。
- 不改类型名，不改任何用户看得到的行为。

## 详细设计

### 包清单

`RuntimeViewerPackages/Package.swift` 第四步完成后的样子（各步之间的过渡依赖见「落地步骤」）：

```swift
products: [
    // ...
    .library(name: "RuntimeViewerApplication", targets: ["RuntimeViewerApplication"]),
    .library(name: "RuntimeViewerAppCore", targets: ["RuntimeViewerAppCore"]),
],

targets: [
    .target(
        name: "RuntimeViewerArchitectures",
        dependencies: [
            // ... unchanged, except that AppKitPlus is gone: `Transition+Navigation.swift`, its only
            // user, moved to RuntimeViewerAppUI.
        ],
    ),

    // The app's view models and application logic. Everything here can be built and driven in a
    // unit test; no UI component appears here, and no UI library is a dependency: views, controls,
    // cells, menus, popovers, windows, their delegates and adapters belong to RuntimeViewerAppUI
    // (Sources/AGENTS.md).
    .target(
        name: "RuntimeViewerAppCore",
        dependencies: [
            "RuntimeViewerArchitectures",
            "RuntimeViewerSettings",
            .target(name: "RuntimeViewerHelperClient", condition: .when(platforms: appkitPlatforms)),
            .target(name: "RuntimeViewerEngineManagement", condition: .when(platforms: appkitPlatforms)),
            .target(name: "RuntimeViewerCatalystExtensions", condition: .when(platforms: appkitPlatforms)),
            .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
            .product(name: "RuntimeViewerCrossReferences", package: "RuntimeViewerCore"),
            .product(name: "DependenciesMacros", package: "swift-dependencies"),
            .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
            .product(name: "IfritStatic", package: "Ifrit"),
            .product(name: "FuzzySearch", package: "fuzzy-search"),
        ],
    ),

    // The UI glue split out of the application layer: the adapters that set up AppKit and AppKitPlus
    // controls, the jump bar's items, the coordinator that opens app-level windows, and the live
    // values of the services RuntimeViewerAppCore declares.
    .target(
        name: "RuntimeViewerAppUI",
        dependencies: [
            "RuntimeViewerAppCore",
            "RuntimeViewerUI",
            "RuntimeViewerArchitectures",
            .target(name: "RuntimeViewerSettingsUI", condition: .when(platforms: appkitPlatforms)),
            .target(name: "RuntimeViewerEngineManagement", condition: .when(platforms: appkitPlatforms)),
            .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
            .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
            .product(name: "UIFoundation", package: "UIFoundation"),
            .product(name: "AppKitPlus", package: "AppKitPlus-Release", condition: .when(platforms: appkitPlatforms)),
            .product(name: "DependenciesMacros", package: "swift-dependencies"),
        ],
    ),

    // A facade: the apps link this one product and import this one module.
    .target(
        name: "RuntimeViewerApplication",
        dependencies: ["RuntimeViewerAppCore", "RuntimeViewerAppUI"],
    ),
]
```

UIFoundation 的依赖边和 `RuntimeViewerUI` 一样不带平台条件，AppKitPlus 的依赖边一律带 macOS 条件。同一个 product 上混用「有条件」和「无条件」的边，Xcode 合并依赖图时会丢掉无条件的那条（ApplicationScaffold `ScaffoldDesign.md`「踩坑记录」）。

门面的全部内容（`Sources/RuntimeViewerApplication/RuntimeViewerApplication.swift`）：

```swift
@_exported import RuntimeViewerAppCore
@_exported import RuntimeViewerAppUI
```

### 文件归属

路径相对 `RuntimeViewerPackages/Sources/RuntimeViewerApplication/`。

**整体搬进 AppUI**

| 文件 | 为什么是 UI 胶水 | 哪一步 |
|------|------------------|--------|
| `NavigatorTextFilterFieldAdapter.swift` | 设置 `NSFilterTokenField` 并当它的 delegate | 第一步 |
| `Find/FindModePathControlAdapter.swift` | `NSPopUpPathControl` 的 delegate | 第一步 |
| `Find/FindQueryFieldMenuAdapter.swift` | 给 `NSFindPatternSearchField` 造放大镜菜单 | 第一步 |
| `RuntimeSourcePicker/RuntimeSourceMenuAdapter.swift` | 往 Classic 样式弹出按钮的菜单里填项 | 第一步 |
| `RuntimeSourcePicker/RuntimeSourcePopoverAdapter.swift` | 搭 `NSNavigationPopoverController` 与它的 cell | 第一步 |
| `EditorArea/JumpBar/EditorJumpBarAdapter.swift` | 路径栏 `NSPopUpPathControl` 的 delegate | 第一步 |
| `EditorArea/JumpBar/EditorJumpBarItem.swift` | 路径控件的条目（遵循 AppKitPlus 的 `NSPopUpPathItem`） | 第一步 |
| `EditorArea/JumpBar/EditorJumpBarItemStore.swift` | 只为路径控件造条目树，使用方都在 UI 一侧 | 第一步 |
| `Activity/ToolbarActivityPresenter.swift` | 产出 `RuntimeViewerUI` 的 `ToolbarActivityState`，使用方是 App 的 `MainViewModel` | 第一步 |
| `Activity/ToolbarActivityState+Reports.swift` | 同上 | 第一步 |
| `RuntimeViewerArchitectures/Transition+Navigation.swift` | coordinator 驱动 AppKitPlus 的导航控制器 | 第三步 |

**拆开**

| 文件 | 留在 AppCore | 进 AppUI | 哪一步 |
|------|--------------|----------|--------|
| `Find/FindResultsOutline.swift` | `FindResultsPresentation` 结构体、`FindResultsOutline`、`FindResultActivation` | `FindResultsPresentation.apply(to: NSOutlineView)`，改成 AppUI 里的扩展 | 第一步 |
| `AppCoordinator.swift` | `AppRoute`，以及 `appRouter` 的接口与测试值 | `AppCoordinator` 与 `liveValue` | 第二步 |
| `Engine/RuntimeEngineIconProvider.swift` | `RuntimeEngineIconProviding` 协议，以及它的依赖接口与测试值 | `RuntimeEngineIconProvider`（用 `DeviceGlyph`、`RuntimeSourcePicker.Icon`）与 `liveValue` | 第二步 |
| `RuntimeObjectIcon.swift` | 选图标的逻辑、按描述缓存图片、`RuntimeObjectIcon.Glyph`、`RuntimeObjectIconRendering` 接口与测试值 | 用 `IDEIcon` 画图的实现与 `liveValue` | 第二步 |
| `Find/FindRecentQueries.swift` | 最近查询的记录、标题文字 | `attributedTitle(for:font:)`（把 token 画成胶囊），改成 AppUI 里的扩展 | 第三步 |

**留在 AppCore、但要改的**

- 第二步：
  - 20 个只靠 `RuntimeViewerUI` 再导出的文件，去掉这个 import，改用 AppCore 自己的别名、`SystemSymbol` 与 `NSAttributedString(rowText:fontSize:color:)`。
  - `Extensions.swift`：图标改用 `SystemSymbol`，外观判断写成 `bestMatch`。
  - `Find/FindResultCellStyle.swift`：图标改用 `SystemSymbol`，角标改走 `RuntimeObjectIconRendering`。
  - `Reports/ReportViewModel.swift`：图标改用 `SystemSymbol`。
  - `Reports/ReportGroupWork.swift`：改用引擎图标的接口。
  - `Engine/RuntimeConnectionNotificationService.swift`：加可替换的依赖与测试。
- 第三步：`Find/FindQueryTerm.swift` 改用 AppCore 自己的模型。
- 不改：`DocumentState.swift`——iOS 路由属于允许的例外。

其余文件原样搬进 `Sources/RuntimeViewerAppCore/`，保持原来的子目录。`SelectionRouteDestination+ModifierFlags.swift`、`RuntimeSourcePicker/RuntimeSourcePickerContent.swift`、`Theme/` 下的文件都只用 UI 框架的模型，留在 AppCore。`ContextMenus/FinderClient.swift`、`ContextMenus/PasteboardClient.swift` 是系统服务的可替换依赖，也留在 AppCore。

### 跨层服务的写法

`appRouter`（只在 macOS 上有，和现在一样）：

```swift
// RuntimeViewerAppCore
#if os(macOS)
public enum AppRoute: Routable {
    case settings
}

package enum AppRouterKey: TestDependencyKey {
    // Triggering it records an issue: a test that opens a window has to say which router it expects.
    package static var testValue: any Router<AppRoute> & Sendable {
        MainActor.assumeIsolated { UnimplementedRouter<AppRoute>() }
    }
}

@MainActor
extension DependencyValues {
    public var appRouter: any Router<AppRoute> & Sendable {
        get { self[AppRouterKey.self] }
        set { self[AppRouterKey.self] = newValue }
    }
}
#endif

// RuntimeViewerAppUI
#if os(macOS)
extension AppRouterKey: DependencyKey {
    package static var liveValue: any Router<AppRoute> & Sendable {
        MainActor.assumeIsolated { AppCoordinator.shared }
    }
}
#endif
```

引擎图标：AppCore 只声明 AppCore 自己要用的那一个方法。AppUI 与 App 里原有的 `\.runtimeEngineIconProvider`（具体类型，带 `sourcePickerIcon(for:)` 与 `record(_:for:)`）保持不变，两个依赖在运行时指向同一个实例。

```swift
// RuntimeViewerAppCore
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@MainActor
public protocol RuntimeEngineIconProviding: AnyObject, Sendable {
    func icon(for engine: RuntimeEngine) -> NSImage
}

package enum RuntimeEngineIconProvidingKey: TestDependencyKey {
    // A generic executable icon, so that a test never reaches Launch Services.
    package static var testValue: any RuntimeEngineIconProviding {
        MainActor.assumeIsolated { PlaceholderRuntimeEngineIconProvider() }
    }
}

@MainActor
extension DependencyValues {
    public var runtimeEngineIconProviding: any RuntimeEngineIconProviding {
        get { self[RuntimeEngineIconProvidingKey.self] }
        set { self[RuntimeEngineIconProvidingKey.self] = newValue }
    }
}
#endif

// RuntimeViewerAppUI
extension RuntimeEngineIconProvider: RuntimeEngineIconProviding {}

extension RuntimeEngineIconProvidingKey: DependencyKey {
    package static var liveValue: any RuntimeEngineIconProviding {
        MainActor.assumeIsolated { RuntimeEngineIconProvider.shared }
    }
}
```

对象图标：`RuntimeObjectIcon` 的公开函数签名不变，只是参数类型从 `IDEIconColor` / `IDEIconStyle` 换成 AppCore 自己的同名取值，所以 `.gray`、`.simple` 这样的调用处照旧能编。

```swift
// RuntimeViewerAppCore
extension RuntimeObjectIcon {
    /// What an object's icon shows: a short text on a coloured badge, the way Xcode marks a symbol's kind.
    public struct Glyph: Hashable, Sendable {
        /// The values of UIFoundation's `IDEIconColor`, under the same names.
        public enum Color: Hashable, Sendable {
            case monochrome, blue, brown, gray, green, orange, pink, purple, red, teal, yellow, indigo, mint, cyan
        }

        /// The values of UIFoundation's `IDEIconStyle`, under the same names.
        public enum Style: Hashable, Sendable {
            case `default`, outline, simple, simpleHighlighted
        }

        public var text: String
        public var color: Color
        public var style: Style
        public var size: CGFloat
    }
}

@MainActor
public protocol RuntimeObjectIconRendering: AnyObject, Sendable {
    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage
}

package enum RuntimeObjectIconRenderingKey: TestDependencyKey {
    // An empty image of the glyph's size: tests compare glyphs, not pixels.
    package static var testValue: any RuntimeObjectIconRendering {
        MainActor.assumeIsolated { BlankRuntimeObjectIconRenderer() }
    }
}

@MainActor
extension DependencyValues {
    public var runtimeObjectIconRendering: any RuntimeObjectIconRendering {
        get { self[RuntimeObjectIconRenderingKey.self] }
        set { self[RuntimeObjectIconRenderingKey.self] = newValue }
    }
}

// RuntimeViewerAppUI
@MainActor
final class IDEIconRuntimeObjectIconRenderer: RuntimeObjectIconRendering {
    func image(for glyph: RuntimeObjectIcon.Glyph) -> NSUIImage {
        IDEIcon(glyph.text, color: IDEIconColor(glyph.color), style: IDEIconStyle(glyph.style), size: glyph.size).image
    }
}

extension RuntimeObjectIconRenderingKey: DependencyKey {
    package static var liveValue: any RuntimeObjectIconRendering {
        MainActor.assumeIsolated { IDEIconRuntimeObjectIconRenderer() }
    }
}
```

`RuntimeObjectIcon` 的缓存仍以描述为键，留在 AppCore；渲染只在缓存未命中时才调用。

解析规则沿用根 `AGENTS.md` 对 `@MainActor` 依赖的要求：只在已有的主线程调用路径里第一次解析，非隔离类型不要用存储属性持有它们。

这条写法要的前提是：App 进程里一定链接了 AppUI。两个 App 经门面链接；MCP bridge 跑在 App 进程里，同样能拿到 `liveValue`。只链接 AppCore 的进程如果在非测试环境下解析这三个依赖，swift-dependencies 会报「没有真实实现」——目前没有这样的进程。

AGENTS.md 的例外写成：「接口在 AppCore、实现在 AppUI 的依赖，用 swift-dependencies 的分离写法：AppCore 手写一个遵循 `TestDependencyKey` 的 key 与 `DependencyValues` 访问器，AppUI 补 `DependencyKey` 与 `liveValue`。只限这一类；其余依赖照旧用 `@DependencyEntry`。」

### 三个上游库的替代

别名（`Sources/RuntimeViewerAppCore/PlatformTypes.swift`）：

```swift
#if os(macOS)
import AppKit

public typealias NSUIImage = NSImage
public typealias NSUIColor = NSColor
public typealias NSUIFont = NSFont
#else
import UIKit

public typealias NSUIImage = UIImage
public typealias NSUIColor = UIColor
public typealias NSUIFont = UIFont
#endif
```

属性串：

```swift
extension NSAttributedString {
    /// A row's title or subtitle: `string` in the system font of `fontSize`, left-aligned and truncated at the
    /// tail, in `color` when one is given — the one shape the rows built with UIFoundation's builder used.
    package convenience init(rowText string: String, fontSize: CGFloat, color: NSUIColor? = nil)
}
```

`SidebarRuntimeObjectCellViewModel` 要在标题上再标出匹配，它的可变标题用 `NSMutableAttributedString(attributedString:)` 从这个结果复制出来。

系统图标：

```swift
/// The system symbols RuntimeViewerAppCore draws. A case's raw value is the symbol's name; `SystemSymbolTests`
/// loads every case, which is what SFSymbols' typed names used to check at compile time.
package enum SystemSymbol: String, CaseIterable, Sendable {
    case latch2Case = "latch.2.case"
    case shippingbox
    case textAlignleft = "text.alignleft"
    // ... the eighteen symbols in Extensions.swift, FindResultCellStyle.swift and ReportViewModel.swift

    /// Traps when the system has no symbol of this name, as SFSymbols did.
    package var image: NSUIImage { get }

    #if os(macOS)
    package func image(pointSize: CGFloat, weight: NSFont.Weight) -> NSImage
    #endif
}
```

Find 查询：

```swift
public struct FindQueryTerm: Hashable, Sendable {
    public enum Component: Hashable, Sendable {
        case text(String)
        case pattern(FindPattern)
    }

    public let components: [Component]

    public init(components: [Component])
    public init(text: String = "")

    public var plainText: String { get }
    public var hasPatterns: Bool { get }

    /// `-[NSFindPatternComponents regularExpressionPatternEscapingText:]` of AppKitPlus, rule for rule.
    func regularExpressionPattern(escapingText: Bool) -> String

    /// The form Xcode's find field writes to the pasteboard, and the form recent queries are stored in.
    public init?(propertyListRepresentation: Any)
    public var propertyListRepresentation: [Any] { get }
}

/// A token in the Find navigator's query field: AppKitPlus's `NSFindPattern`, as data.
public struct FindPattern: Hashable, Sendable {
    public var regularExpression: String
    public var title: String
    public var tokenTitle: String
    public var allowsBackreferences: Bool
    public var replacementString: String?
    public var isNegation: Bool
    public var identifier: String?
}
```

- **数捕获组、转义与拼接**按 UTF-16 逐个处理，和原实现读 `unichar` 的方式一致。
- **`Codable` 编码**沿用现有的 `StoredComponent` 形状。pattern 字典的键名和取值照 `NSFindPattern.m` 的属性表读写：`replacementString` 与 `identifier` 为空时不写，读不到正则时整条作废。
- **AppUI 里的互转**：`FindQueryTerm(propertyListRepresentation: components.propertyListRepresentation)` 与 `NSFindPatternComponents(propertyListRepresentation: term.propertyListRepresentation)`。

### 越界检查的规则

`AppCoreBoundaryTests` 扫描 `RuntimeViewerAppCore` 的每个源文件：去掉注释，`#if` 按 macOS 与 iOS 各求值一次。下面任何一项出现即失败，并报出「文件:行」和原因：

1. import 了下列模块之一：
   - 本仓库的 `RuntimeViewerUI`、`RuntimeViewerSettingsUI`、`RuntimeViewerAppUI`；
   - `SwiftUI`、`SnapKit`、`AppKitPlus`、`SFSymbols`、`AppKitNavigation`、`UIKitNavigation`；
   - UIFoundation 中除 `UIFoundationSettings` 以外的任何模块。
2. 类型声明继承了 UI 组件。检查只看名字、解析不了继承链，所以按名单与后缀判断：父类是 `NSResponder`、`UIResponder`，或 CocoaCoordinator / XCoordinator 的 coordinator 基类（`Coordinator` 继承自 `NSResponder`），或名字以组件后缀结尾的 NS / UI 类——后缀包括 `View`、`ViewController`、`Window`、`WindowController`、`Control`、`Cell`、`Menu`、`MenuItem`、`Popover`、`Field`、`Bar`（含 `Toolbar`）、`Button`。
3. 构造 UI 组件：调用上一条那些类型的初始化方法，例如 `NSMenu(`、`NSPopover(`、`NSWindow(`。
4. 遵循 UI 组件的 delegate 或 data source 协议，即名字以 `Delegate`、`DataSource` 结尾的 NS / UI 协议，AppKitPlus 控件的 delegate 也在内。

**允许清单**写在检查里，每条带理由，目前是空的。下面这些都不会命中上面四条：

- `NSObject`；
- 模型类型；
- 作为参数或属性类型出现的 `UIViewController`（iOS 路由的例外）；
- 不以 NS / UI 开头的系统服务协议，例如通知服务的 `UNUserNotificationCenterDelegate`。

以 NS 开头、但不属于 UI 的系统服务协议（例如 `NSXPCListenerDelegate`）会被误报，到时候加进允许清单。

依赖层面另有一道把关：AppCore 在 `Package.swift` 里不声明任何 UI 库。和 `CrossPlatformSourceGuardTests` 一样，检查还要证明自己真的在看：确认读到了 AppCore 的文件，并对一组故意越界的样例行逐条报出。

### 测试

**进 `RuntimeViewerAppUITests` 的**：

- AppUI 的测试：`EditorJumpBarTests`、`FindModePathControlAdapterTests`、`FindQueryFieldMenuAdapterTests`、`FindResultsOutlineTests`、`NavigatorTextFilterFieldAdapterTests`、`RuntimeSourceMenuAdapterTests`、`RuntimeSourcePopoverAdapterTests`、`ToolbarActivityPresenterTests`、`ToolbarActivityStateTests`、`ReportOutlineBindingTests`。
- `RuntimeViewerUI` 视图的测试：`ApplicationIconMaskTests`、`BaseNavigationControllerTests`、`ChoiceFilterControlBarItemTests`、`DeviceGlyphTests`、`EditorSplitViewTests`、`GenericViewControllerAppearanceEventTests`、`HorizontalSeparatorViewTests`、`NavigatorScrollViewLayoutTests`、`RuntimeSourcePickerTests`、`RuntimeSourcePopoverCellViewTests`、`StackedHeightSharingTests`、`StatefulOutlineViewAutosaveTests`、`StatefulOutlineViewRevealTests`、`StatefulOutlineViewRowGeometryTests`、`TabSwitcherBarSafeAreaTests`、`TagButtonHitTestingTests`、`TitleToolbarItemOverflowTests`、`ToolbarActivityViewSourcePickerTests`、`ToolbarCenteredItemTests`、`ToolbarScrollPocketContainerViewTests`。
- 新增：`FindPatternParityTests`，用同一份属性表分别造 `FindQueryTerm` 与 `NSFindPatternComponents`，逐例比较两边拼出的正则；`IDEIconRuntimeObjectIconRendererTests`，确认描述到 `IDEIcon` 的映射。
- 只有它们用的帮手：`Support/LayerRendering.swift`、`Support/MaterialFillRendering.swift`。

**要逐个看的**：

- `FindCrossReferenceTests` 与 `ReportViewModelTests` 测的是 AppCore 的类型，却构造了窗口或 `NSFilterSearchField`。按同一条规则处理：用到 UI 组件的那几个用例拆进 AppUITests，其余留下。
- `FindCrossReferenceTests.swift:178` 用 `IDEIconColor` 造期望的角标。留在 AppCoreTests 的部分改成比较 `RuntimeObjectIcon.Glyph`。
- `FindQueryTermTests` 与 `FindViewModelTests` 现在用 AppKitPlus 造查询。改用 AppCore 自己的模型，留在 AppCoreTests。

**进 `RuntimeViewerAppTestingSupport` 的**：`TestRuntimeEngine`、`ViewModelTestEnvironment`、`FindResultFixtures`、`AsyncObservation`。只有 AppCore 一侧用到的帮手（`DerivedDataFixture`、`ScriptedPeer`、`SharedCacheBorrowingFixture`、`LocalServiceFixture`、`RuntimeObjectFixtures`、`JoinedBackgroundWork`）留在 AppCoreTests。

**其余**全部进 `RuntimeViewerAppCoreTests`，再加上三组新测试：

- `SystemSymbolTests`；
- 照 AppKitPlus 的 25 个测试移植的查找 pattern 测试；
- 一条用现版本写出的最近查询存盘样本做的读回测试。

`CrossPlatformSourceGuardTests` 也进 AppCoreTests，它的 target 清单换成 `RuntimeViewerAppCore`、`RuntimeViewerAppUI`、`RuntimeViewerApplication`、`RuntimeViewerArchitectures`、`RuntimeViewerSettings`、`RuntimeViewerUI`。

### 文档与工程描述

| 位置 | 改什么 |
|------|--------|
| 根 `AGENTS.md` | 「Package Structure」列出三个模块；「Key Source Locations」里 ViewModel 与 `DocumentState` 的路径；「Singletons & Dependency Injection」的例外；「Testing」的过滤名 |
| `RuntimeViewerPackages/Sources/AGENTS.md` | 分界规则全文、两个模块各放什么、门面不放任何实现、AppCore 不依赖 UI 库 |
| `RuntimeViewerUsingAppKit/AGENTS.md` | 写着「(RuntimeViewerApplication)」的地方改成实际所在的模块；Find 查询框一段说明内容在 AppUI 与 `FindQueryTerm` 之间按属性表互转、拼接规则在 AppCore 有一份照抄并由对照测试守住 |
| `RuntimeViewerPackages/Tests/AGENTS.md` | 改成两个测试 target 与帮手 target 的规则 |
| `Documentations/CommunicationAndEngineArchitecture.md`、`Documentations/Guides/TuistDevelopment.md` | 提到 `RuntimeViewerApplication` 的地方 |
| `Tuist/ProjectDescriptionHelpers/LocalPackages.swift`、`Tuist.swift` | 新 target、测试 target、product 清单，以及 Architectures 不再依赖 AppKitPlus |

已落地的提案、计划、审查记录、已解决问题与任务报告是历史记录，不改。

## 替代方案考量

- **ViewModel 放进 AppUI，AppCore 只放 ViewModel 以外的应用逻辑**——否。ViewModel 正是最该能单独测的那一层，和脚手架对 AppCore 的定义也不一致。
- **链接级纯净：AppCore 的依赖图里完全没有 AppKit / UIKit**——否。要把约 360 处 `Driver` / `Signal` 和 91 处 `@RxObserved` 换成只用 RxSwift 的写法，再拆 RxSwiftPlus 与 CocoaCoordinator，所有 ViewController 的绑定都得跟着改；而测试本来就在 macOS 上跑，可测性不会因此更好。
- **ViewModel 只输出不含 UI 类型的描述，属性串和图标交给 AppUI 渲染**——否。UI 框架的模型不算越界，改写 cell ViewModel 的输出换不来更好的可测性。
- **删掉 `RuntimeViewerApplication`，各处直接 import 两个新模块**——否。226 个文件的 import 和两个 Xcode 工程的产品依赖都得改。门面让 App 一侧完全不动；而包内代码与测试都直接 import 具体模块，分层照样看得见。
- **AppUI 顺带收 `RuntimeViewerUI` 里的业务视图，或 App target 的界面代码**——否。范围太大，这次只解决越界；以后要做可以另立提案。
- **AppCore 可以依赖 `RuntimeViewerUI`，只许用其中的模型**——否。import 它会把它自己和 UIFoundation 的组件一起带进 AppCore，越界就只剩检查一道防线。而用到它的两个文件本来就只为工具栏和来源选择器服务。
- **逐个改结构，绕开跨层服务**（ViewModel 触发自己的路由去开设置；cell 视图自己去取引擎图标）——否。要改 ViewModel 基类和 Report 的 cell 模型。「接口与实现分开」是 swift-dependencies 文档里的标准做法，以后再有同类需求也照这个做。
- **AppCore 为取模型继续依赖 UIFoundation、SFSymbols、AppKitPlus**（起草初稿的做法）——否。用户要 AppCore 不依赖任何 UI 库；调研下来，三个库在 AppCore 一侧的用量都能替换。
- **让 UIFoundation 把 `IDEIcons` 拆成单独的 product，AppCore 依赖它**——否。要先改上游并发版，AppCore 仍依赖 UIFoundation 这个包；绘制经依赖注入交给 AppUI，用的是已经定下的同一套写法。
- **把 `IDEIcon` 的 4 个文件复制进 AppCore**——否。756 行重复代码，以后两边会走样。
- **Find 的正则拼接经依赖注入交给 AppUI**——否。规则只留一份，但 AppCore 的 Find 测试只能用替身拼接，最常用的那条搜索路径反而测不到真实结果。照抄一份、再用对照测试守住两边一致，两头都能测。
- **`Transition+Navigation.swift` 留在 Architectures**——否。AppKitPlus 会经 Architectures 间接留在 AppCore 的依赖图里，而挪走它只涉及一个文件、一个使用方。
- **只写规则、不加检查**——否。规则只写在文字里时，新代码照样会越界，这次的 adapter 就是这么混进来的。
- **一次合进 `next`**——否。分次合并，每次的改动更小，可以单独验收。

## 影响

### 用户可见变化

无。这次只是搬代码、拆模块，界面和行为都不变；对象图标、系统图标和 Find 查询的结果都与现在一致。

### 可发现性

不适用。

### 数据与配置兼容

不受影响。

- Application 里没有按模块名或类名持久化的数据（见「前期调研 · 现状」）；`settings.json`、书签文件、UserDefaults 的键和 autosave 名都不变。
- Find 的最近查询（`AppDefaults.findRecentQueriesByScope`）仍按 Xcode 查找框的属性表格式存。AppCore 自己的模型读写同一种格式，由一条用现版本写出的存盘样本做的读回测试守住。

### 平台与最低版本

不变。两个新 target 沿用包的平台声明（macOS 15、iOS 18、Mac Catalyst 18、tvOS 18、visionOS 2）。iOS App 照常经门面使用；AppUI 保留现在的 AppKit 与 UIKit 两套条件编译。AppCore 自己的 `NSUI*` 别名在 Mac Catalyst 上指向 UIKit 的类型，和 UIFoundation、SFSymbols 的做法一致。

### 发布

- 没有新的权限、entitlement 或隐私清单条目。
- 包里多了几个 target，但 App 仍是静态链接，App 包的结构不变，公证与 Sparkle 不受影响。
- Tuist 的描述与原生工程同批更新，`./TuistScript.sh check` 必须通过。

## 风险

- **在途分支冲突**：目前没有。以后从旧 `next` 切出、又改了这些文件的分支，要在搬家之后 rebase。搬家只改 import 行，git 的改名检测能把改动带过去。
- **功能地图里的路径会失效**：另一个会话正在写的 `Documentations/FeatureMaps/EditorJumpBar.md`（还没提交）引用了 26 处 `RuntimeViewerApplication/` 下的路径。功能地图头部记着核对时的 commit，对账时从那里开始；第一步合进 `next` 后要提醒更新它。
- **两份拼接规则日后不一致**：AppKitPlus 升级时如果改了拼接规则，AppCore 的那份不会自动跟上。对照测试会因此失败，提醒同批更新。
- **隐藏的成员用法**：Swift 5 模式下，经别的模块间接载入的扩展成员不 import 也能调用。AppCore 去掉 UIFoundation、AppKitPlus 后，这类用法会在第二步、第三步变成编译错误，按出现的地方逐个改用系统 API 或 AppCore 自己的写法。
- **跨模块补遵循可能被当成 retroactive**：在 AppUI 里给 AppCore 的 key 补 `DependencyKey` 遵循，编译器若按 SE-0364 提示 retroactive，就照提示处理，并在代码里写明原因。
- **普通 target 里用 swift-testing**：`RuntimeViewerAppTestingSupport` 里有 `import Testing` 的帮手。SwiftPM 支持这样写，Tuist workspace 能不能编要在第四步验证；编不过就把用到 `Testing` 的帮手放回各自的测试 target。
- **检查误报**：组件后缀的匹配可能误伤模型类型。误报的处理方式是加进允许清单并写明理由，不是放宽规则。

## 落地步骤

**第一步：建 target 与门面，把 UI 胶水搬进 AppUI**（✅ 已完成。合进 `next` 一次，提案在这次分配编号，状态改为 In Progress）

1. `Package.swift`：新增 `RuntimeViewerAppCore`、`RuntimeViewerAppUI`，把 `RuntimeViewerApplication` 改成门面，新增 product `RuntimeViewerAppCore`。AppCore 暂时保留现在 Application 的全部依赖（第二步、第三步逐步去掉），旁边加注释说明这是过渡。
2. 用 `git mv` 把 10 个文件搬进 `Sources/RuntimeViewerAppUI/`，其余文件按原子目录搬进 `Sources/RuntimeViewerAppCore/`；把 `FindResultsPresentation.apply(to:)` 拆到 AppUI 的扩展里。AppUI 要用的 AppCore 成员改成 `package`。
3. 测试暂不拆：`RuntimeViewerApplicationTests` 的 `@testable import RuntimeViewerApplication` 改成 `@testable import RuntimeViewerAppCore`，用到 AppUI 的文件再加 `@testable import RuntimeViewerAppUI`；同时更新 `CrossPlatformSourceGuardTests` 的 target 清单。
4. MCP bridge 改成依赖并 import `RuntimeViewerAppCore`。
5. Tuist 描述加上新 target；更新「文档与工程描述」表里与模块位置有关的各处。
6. 验证：
   - 用 Debug workspace 编 macOS App；编一次 iOS App；
   - 包测试全绿，`RuntimeViewerMCP` 的测试全绿；
   - `./TuistScript.sh check` 通过。

**第二步：接口与实现分开，AppCore 不再依赖视图库、UIFoundation 与 SFSymbols**（合进 `next` 一次）

1. 三个跨层服务：
   - `appRouter`：`AppRoute` 与接口留在 AppCore，`AppCoordinator` 与 `liveValue` 搬进 AppUI。
   - 引擎图标：`RuntimeEngineIconProviding` 与接口进 AppCore，`RuntimeEngineIconProvider` 搬进 AppUI，并成为 `liveValue`。
   - 对象图标：`RuntimeObjectIcon.Glyph` 与 `RuntimeObjectIconRendering` 进 AppCore，用 `IDEIcon` 的实现进 AppUI。
2. AppCore 自己的 `NSUI*` 别名、`NSAttributedString(rowText:fontSize:color:)`、`SystemSymbol`，以及 `isLight` 的替换；同时加上 `SystemSymbolTests`。
3. 20 个只靠再导出的文件，以及 `Extensions.swift`、`FindResultCellStyle.swift`、`ReportViewModel.swift`、`ReportGroupWork.swift` 改用上面这些。然后去掉 AppCore 对 `RuntimeViewerUI`、`RuntimeViewerSettingsUI`、UIFoundation、SFSymbols 的依赖。
4. `RuntimeConnectionNotificationService` 加可替换的依赖与测试。
5. 根 `AGENTS.md` 写上依赖注入的例外。
6. 验证同第一步，并逐一比对侧栏、Inspector、Find、Report 的图标与改动前一致（截图对照）。

**第三步：AppCore 不再依赖 AppKitPlus**（合进 `next` 一次）

1. `FindQueryTerm` 与 `FindPattern` 改成 AppCore 自己的模型。数捕获组、转义、拼接与属性表读写照 `NSFindPattern.m` 用 Swift 重写；照搬 AppKitPlus 的 25 个测试，再加最近查询存盘样本的读回测试。
2. AppUI 里加上与 `NSFindPatternComponents` 的互转；`FindRecentQueries.attributedTitle(for:font:)` 搬进 AppUI；加 `FindPatternParityTests`。
3. `Transition+Navigation.swift` 从 `RuntimeViewerArchitectures` 挪进 AppUI；Architectures 与 AppCore 去掉对 AppKitPlus 的依赖。
4. 更新 `RuntimeViewerUsingAppKit/AGENTS.md` 里 Find 查询框那一段。
5. 验证同第一步，并手动查一次带 pattern 的 Find 搜索与最近查询菜单。

**第四步：拆测试，加越界检查**（合进 `next` 一次，提案改为 Implemented）

1. 建 `RuntimeViewerAppCoreTests`、`RuntimeViewerAppUITests`、`RuntimeViewerAppTestingSupport`，按「详细设计 · 测试」搬文件，删掉 `RuntimeViewerApplicationTests`。
2. 加 `AppCoreBoundaryTests`，与 `CrossPlatformSourceGuardTests` 共用扫描代码。
3. 分界规则写进 `RuntimeViewerPackages/Sources/AGENTS.md`；改写 `Tests/AGENTS.md` 与根 `AGENTS.md`「Testing」里的过滤名；Tuist 的测试 target 清单。
4. 验证：
   - 两个测试 target 各自全绿；
   - 故意在 AppCore 里写一个 `NSMenu()`、加一行 `import AppKitPlus`，确认检查会失败，再删掉；
   - Tuist check 通过。

每一步都能单独构建通过。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：分界规则写在 `RuntimeViewerPackages/Sources/AGENTS.md`，检查本身会报出原因。落地时再判断，是否还需要一份实现说明，记录三件事：为什么不追求链接级纯净、为什么图标有两个依赖、为什么 Find 的拼接规则有两份。
- **有没有引入新术语**：AppCore、AppUI、门面模块。落地时判断要不要登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-13 | Created as Draft | 用户提出把 `RuntimeViewerApplication` 拆成两个模块：一个不含 UI 组件、可测试的 AppCore，一个放业务 UI 组件的 AppUI。属于架构级重构，按完整档问了三轮后起草。 |
| 2026-11-13 | ViewModel 归属 | ViewModel、cell ViewModel、路由与 `DocumentState` 进 AppCore，与脚手架里「AppCore 是 ViewModel 层」一致。否决放进 AppUI。 |
| 2026-11-13 | 边界标准 | AppCore 的代码必须可测；UI 框架的模型（图像、颜色、字体、属性串等）可以用；UI 组件不许出现；`Driver` / `Signal`、`@RxObserved`、`Router` 照用。越界指的是 adapter 这类驱动控件的代码，不是链接了哪个框架。否决链接级纯净，以及「ViewModel 只输出不含 UI 类型的描述」。 |
| 2026-11-13 | 旧模块 | `RuntimeViewerApplication` 留作纯门面，两个 App 的 import 与 Xcode 工程不动。否决删除。 |
| 2026-11-13 | AppUI 范围 | AppUI 只收从这里拆出来的部分；`RuntimeViewerUI` 与 App target 不动。否决顺带收 `RuntimeViewerUI` 的业务视图或 App 的界面代码。 |
| 2026-11-13 | 视图库依赖 | AppCore 不依赖 `RuntimeViewerUI`（也不依赖 `RuntimeViewerSettingsUI`）。否决「可以依赖、只许用模型」：那样会把组件一起带进 AppCore。 |
| 2026-11-13 | 跨层服务 | 接口与测试值在 AppCore，真实实现在 AppUI，用 swift-dependencies 的分离写法；AGENTS.md 为这类依赖开例外。否决逐个改结构绕开。 |
| 2026-11-13 | 越界检查 | 规则写进 AGENTS.md，另加一个跟着包测试一起跑的检查。否决只写规则。 |
| 2026-11-13 | 默认做法 | 用户确认五条默认做法：分三次合进 `next`；测试拆成 AppCoreTests 与 AppUITests，MCP bridge 直接依赖 AppCore；`RuntimeViewerArchitectures` 不动，UIFoundation、AppKitPlus、SFSymbols 在 AppCore 里只取模型；通知服务的系统调用改为可替换的依赖；iOS 路由返回 `nil` 的 view controller 算允许的例外。 |
| 2026-11-13 | 起草时补充 | 由上面的决定推出、未单独询问的几条，列在「提议方案 · 未经询问采用的做法」：共用的测试帮手 target、`RuntimeViewerUI` 视图测试随 AppUITests、跨模块成员开到 `package`、`Then.swift` 的处理、通知服务补一组测试。 |
| 2026-11-13 | 去掉三个上游库 | 审阅草案时，用户要求 AppCore 也不依赖 UIFoundation、SFSymbols、AppKitPlus，推翻了上一行里「只取模型」的默认做法。调研后定下：`NSUI*` 别名自己定义，属性串手写，系统图标改用 AppCore 的 `SystemSymbol`。`IDEIcon` 的绘制经依赖注入交给 AppUI，否决让 UIFoundation 拆出单独的 product。Find 的拼接规则在 AppCore 照 AppKitPlus 重写，并用对照测试守住，否决经依赖注入交给 AppUI，也否决保留 AppKitPlus。`Transition+Navigation.swift` 挪进 AppUI，Architectures 去掉 AppKitPlus，否决不挪。 |
| 2026-11-13 | 落地改为四次 | 新增的「去掉 AppKitPlus」自带对照测试，单独合一次，保持每次改动小、能单独验收。用户确认四次，否决并回第二步。 |
| 2026-11-13 | Accepted | 用户批准，开始实现。实现在功能分支 `feature/app-core-ui-split` 上按四步提交，每一步的最后一个提交就是一次可单独合进 `next` 的边界；合进 `next` 由用户看过后经 `finish-feature` 按步进行。 |
| 2026-11-13 | 第一步：访问级别 | AppUI 用到的 AppCore 成员改成 `package`，没有一个改成 `public`：`ActivityReportSelector`（连同 `Selection` 的三个字段、`init()` 与 `update(with:now:)`）、`ActivityReportsSnapshot.merged(_:)`、`RuntimeEngineSession.backgroundWorks`、`RuntimeEngineBackgroundWork`、`RuntimeEngineActivityReporter` 与它的 `snapshot`、`FindRecentQueries` 的 `title(for:)` 与 `attributedTitle(for:font:)`、`FindModePathComponent.path(for:)`、`SidebarRootViewModel.isOnThisMac(_:)`。 |
| 2026-11-13 | 第一步：文档 | 愿景《无头 RuntimeViewer》里提到 `RuntimeViewerApplication` 的两处，说的是写愿景时的旧状态和当时考虑过的选项，属于历史论证，不改；「文档与工程描述」表相应删去这一项。`CommunicationAndEngineArchitecture.md` 里引擎管理器的路径本来就过时（0035 已把它搬进 `RuntimeViewerEngineManagement`），借这次一并改正。测试 target 第一步还没改名，测试规则文件与根 `AGENTS.md`「Testing」里的名字留到第四步。 |
| 2026-11-14 | 第一步：测试基线 | 全量包测试里有 5 处失败。`InjectedDeviceEngineReconnectionTests`、`ReportSharedByEngineTests`、`FindViewModelCrossReferenceTests`、`BackgroundWorkProcessActivityTests` 是满载并行时的超时，单独重跑全部通过。`TitleActivityIndicatorTests` 里「指针在标题上时副标题显示活动」一例在 `next` 基线上同样失败，与本次无关；它只测 `RuntimeViewerUI`，本提案不碰。 |
| 2026-11-14 | 第一步：验证 | macOS App（`RunScript.sh --no-launch`）、iOS App（`RuntimeViewer iOS`，不签名）、`RuntimeViewerMCP` 的构建与 95 个测试都通过。`./TuistScript.sh check` 的 target 名单、锁文件与 trait 各项都过了，只报 `RuntimeViewerUsingAppKit.xcodeproj` 在工程级设了 `DEVELOPMENT_TEAM`：这是 `next` 上 8768b8cd 照收 Xcode 改写时带进来的，本分支没有改动任何工程文件，与本提案无关，不在这条分支上修。 |

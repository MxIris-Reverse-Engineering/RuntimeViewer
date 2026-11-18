# Draft - 整理 AppCore 与 AppUI 的目录分类

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-18
- **最后更新**: 2026-11-18
- **所属愿景**: 无
- **关联提案**: [0091](0091-app-core-ui-split.md)（把 `RuntimeViewerApplication` 拆成 AppCore 与 AppUI）、[0094](0094-app-core-without-ui-models.md)（AppCore 不再使用 AppKit/UIKit 模型，新增了 `Presentation/`、`Theme/` 等目录）
- **实现分支 / PR**: `feature/app-layer-directory-layout`（worktree `.worktrees/RuntimeViewer-AppLayerDirectoryLayout`）
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

把 `RuntimeViewerAppCore` 与 `RuntimeViewerAppUI` 的源文件按功能重新归目录，只移动、不改行为。AppCore 根目录下散着的 17 个文件全部收进有名字的目录（`App/`、`Base/`、`Document/`、`Extensions/`、`Filtering/`、`RuntimeImage/` 等）；每个 Engine 的后台工作——索引、Find 语料、交叉引用预建、手动加载——从 `Find/`、`Engine/`、`BackgroundIndexing/`、`ManualLoading/` 四处收到 `BackgroundWork/` 一处；22 个文件的 `Find/` 分出 `Query/`、`Scope/`、`Results/`、`CrossReferences/` 四个子目录；`Sidebar/` 照 App 一侧分成 `Root/` 与 `RuntimeObject/`。AppUI 镜像 AppCore：扩展、绘制或适配某个 AppCore 类型的文件放进与该类型同名的目录，`Icons/` 因此拆散。只拆两个名不副实的文件（`Extensions.swift`、`InspectorViewModel.swift`），其余多类型文件原样移动。测试 target 不动，只改测试里写死的两处源文件路径。归类规则写进 `RuntimeViewerPackages/Sources/AGENTS.md`，以后新文件照它放。

## 动机

**根目录成了杂物间。** AppCore 根目录有 17 个文件，AppUI 有 6 个，彼此毫无关系：ViewModel 基类（`ViewModel.swift`）、文档状态（`DocumentState.swift`）、存储（`AppDefaults.swift`）、过滤（`FilterEngine.swift`、`NavigatorTextFilter.swift`）、图标（`RuntimeObjectIcon.swift`、`SystemSymbol.swift`）、杂项扩展（`Then.swift`、`Extensions.swift`）。找一个文件只能靠记名字。

**同一类东西分在几处。** 每个 Engine 有三个后台协调器，由 `RuntimeEngineBackgroundWork` 统一持有（根 `AGENTS.md`「Engine work is shared by the documents on the engine」）：

- 索引协调器在 `BackgroundIndexing/`；
- Find 语料协调器和交叉引用预建协调器在 `Find/`，虽然它们是 Engine 范围的后台工作，Report 与工具栏活动也读它们；
- 持有它们的 `RuntimeEngineBackgroundWork` 在 `Engine/`，它要的 `BackgroundWorkProcessActivity` 在根目录；
- 手动加载协调器（同样属于 Engine 的后台工作）在 `ManualLoading/`。

**`Find/` 太大。** 22 个文件平铺，查询模型（`FindMode`、`FindQueryTerm`）、结果树（`FindResultNode`）、范围选择（`FindScopeChooserViewModel`）、交叉引用（`FindCrossReferenceTree`）、后台协调器混在一起。

**AppUI 的目录和 AppCore 对不上。** 0094 把绘制代码搬进 AppUI 时按「做什么」起了 `Icons/`，于是 `RuntimeObjectIcon` 在 AppCore 根目录、它的绘制在 AppUI `Icons/`，`RuntimeImageKind` 在 AppCore 根目录、绘制也在 `Icons/`；`ContentInterface` 在 AppCore `Content/`，它的上色在 AppUI `Theme/`；`SelectionRoute` 在 AppCore 根目录，修饰键换算在 AppUI `EditorArea/`。从一边的类型找另一边的配套代码没有规律可循。

**名不副实的文件。** `Extensions.swift` 里是三段互不相干的扩展（`RuntimeImageLoadState` 的 `CaseAccessible`、`RuntimeImageNode` 的 `Sequence`、`String` 的整数下标换算）；`InspectorViewModel.swift` 里没有叫 `InspectorViewModel` 的类型，是 `InspectorPlaceholderViewModel` 和 `InspectorRuntimeNodeViewModel` 两个 ViewModel。

## 前期调研

- **现状**（`next` 上 20d56e71）：AppCore 131 个 Swift 文件，根目录 17 个、`Find/` 22 个、`Sidebar/` 15 个；AppUI 39 个，根目录 6 个。逐个文件的顶层声明与行数已核对，见改动地图。
- **App 一侧已有的目录**（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`）：`App`、`Base`、`BatchExporting`、`Content`、`EditorArea`、`Find`、`Inspector`、`Main`、`Reports`、`Sidebar`（下分 `Root/`、`RuntimeObject/`，`PrivateDeclarationViewController` 与 `SidebarRuntimeObjectScopeViewController` 都在 `RuntimeObject/`）。本提案的目录名尽量与之相同，`App/`、`Base/` 也照它起。
- **根目录文件的使用者**（`grep -w` 统计）：
  - `SelectionRoute` 被 `EditorArea/`、`Content/`、`Find/`、`Inspector/`、`ContextMenus/` 使用，根 `AGENTS.md` 把它描述为作用在编辑栏标签上的路由；AppUI 里它的修饰键换算已在 `EditorArea/`。
  - `NavigatorTextFilter` 被 `Sidebar/`（5 处）、`Find/`、`Reports/` 使用；`FilterEngine` 只被 `Sidebar/` 使用。
  - `LoadingPlaceholderTiming` 被 `Content/`、`Inspector/`、`Sidebar/` 使用；`OwnerReportingTask` 只被 App 的 `BatchExportingProgressViewModel` 使用。
  - `RuntimeImageKind`、`RuntimeObjectIcon` 被五六个目录使用；`SystemSymbol` 被 AppCore `Presentation/` 和 AppUI 使用。
- **依赖文件路径的地方**：
  - `Package.swift` 只声明 AppUI 的 `Resources/Symbols.xcassets`，不动它即可；Tuist 的描述（`Tuist.swift`、`Tuist/ProjectDescriptionHelpers/`）只列 target，不列文件。
  - 测试里写死源文件路径的只有 `AppCoreBoundaryTests`：`RuntimeViewerAppCore/AppRoute.swift`（第 89 行）和 `allowedLines` 里的四条 `RuntimeViewerAppCore/DocumentState.swift`（第 176–188 行）。`PackageSourceScan` 按 target 目录递归读文件，子目录不影响它。
  - 源码里没有 `#filePath` / `#file` 的用法，也没有注释引用这些相对路径。
- **现行文档里的路径**：根 `AGENTS.md` 第 809 行（`DocumentState.swift`）；`RuntimeViewerPackages/Sources/AGENTS.md` 第 22、74、75、87、90、93、102、110、120 行（`Transition+Navigation.swift`、`Presentation/`、`Theme/`、`PlatformTypes.swift`、`Icons/RuntimeImageKind+Icon.swift`）。`Documentations/FeatureMaps/EditorJumpBar.md` 也列了路径，但它按头部记的核对基准 commit 读，0091 拆包之后就没跟着改。

## 提议方案

1. **目标根目录不放文件。** 每个文件属于一个有名字的目录。
2. **目录按功能分**，名字与 App 一侧的目录相同（`App`、`Base`、`Content`、`EditorArea`、`Find`、`Inspector`、`Reports`、`Sidebar/Root`、`Sidebar/RuntimeObject`）。App 一侧没有的，按它装的东西起名：`BackgroundWork`、`Document`、`Engine`、`Extensions`、`Filtering`、`Presentation`、`RuntimeImage`、`RuntimeObject`、`Storage`。
3. **Engine 的后台工作归 `BackgroundWork/`**：`RuntimeEngineBackgroundWork` 持有的协调器、它们的状态与结果类型，以及手动加载，各占一个子目录。读它们结果的功能（Find、Report、工具栏活动）不收它们。
4. **AppUI 镜像 AppCore**：扩展、绘制或适配某个 AppCore 类型的文件，放进 AppCore 里该类型所在目录的同名目录。只有 AppUI 才有的东西自成目录（`Theme/`、`RuntimeSourcePicker/`、`Resources/`），或者跟着它唯一的使用者走。
5. **文件以主类型命名**：主类型旁边的小辅助类型可以留在同一个文件里；把两件不相干的东西放在一起、或者名字里的类型根本不存在的文件，拆开。本次只拆 `Extensions.swift` 与 `InspectorViewModel.swift`。
6. 规则写进 `RuntimeViewerPackages/Sources/AGENTS.md`，新增一节「Where a file goes」。

### 非目标

- 不改任何代码行为，不改类型名、访问级别和文件内容（两处拆分只是把原有代码原样分到新文件）。
- 不把其余约 35 个多类型文件拆成一类型一文件（`FindMode.swift`、`FilterEngine.swift`、`ReportNode.swift` 等）。
- 不整理两个测试 target 的目录，只改 `AppCoreBoundaryTests` 里写死的路径。
- 不动 `RuntimeViewerUI`、`RuntimeViewerArchitectures` 等别的包内 target，也不动 App 一侧的目录。
- 不合并 AppCore 与 AppUI 各自的一份 `Then.swift`：两份都是 `internal`，各自模块用，合并要新增一个公开模块，不属于整理文件。
- 不更新 `Documentations/FeatureMaps/EditorJumpBar.md`：功能地图按头部的核对基准 commit 读，下次核对时一并更新。
- 不改已落地提案、ResolvedIssues、TaskReports 里的旧路径：它们是当时的记录。

## 改动地图

`AC` = `RuntimeViewerPackages/Sources/RuntimeViewerAppCore`，`AUI` = `RuntimeViewerPackages/Sources/RuntimeViewerAppUI`。移动一律 `git mv`，文件内容不变。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `AC/AppRoute.swift` | 移动 → `AC/App/` | — | App 级路由，对应 App 一侧的 `App/` 与 AUI 的 `AppCoordinator` | 1 |
| `AC/ViewModel.swift`、`AC/ViewModelProtocol.swift`、`AC/LoadingPlaceholderTiming.swift`、`AC/OwnerReportingTask.swift` | 移动 → `AC/Base/` | — | ViewModel 的基础设施，对应 App 一侧的 `Base/` | 1 |
| `AC/DocumentState.swift` | 移动 → `AC/Document/` | — | 文档状态 | 1 |
| `AC/SelectionRoute.swift` | 移动 → `AC/EditorArea/` | — | 作用在编辑栏标签与分栏上的路由；AUI 的修饰键换算已在 `EditorArea/` | 1 |
| `AC/Then.swift` | 移动 → `AC/Extensions/` | — | 通用扩展 | 1 |
| `AC/Extensions.swift` | 拆分后删除 | 三段扩展各成一个文件：`AC/Extensions/String+IntegerIndex.swift`、`AC/RuntimeImage/RuntimeImageNode+Sequence.swift`、`AC/RuntimeImage/RuntimeImageLoadState+CaseAccessible.swift`；每个文件只带它要的 import | 名不副实 | 1 |
| `AC/FilterEngine.swift`、`AC/NavigatorTextFilter.swift`、`AC/NavigatorTextFilter+Keystrokes.swift` | 移动 → `AC/Filtering/` | — | 导航栏过滤框共用的过滤逻辑 | 1 |
| `AC/SystemSymbol.swift` | 移动 → `AC/Presentation/` | — | 描述值的组成部分，与 `IconDescriptor` 同处 | 1 |
| `AC/RuntimeImageKind.swift` | 移动 → `AC/RuntimeImage/` | — | 镜像的种类 | 1 |
| `AC/RuntimeObjectIcon.swift` | 移动 → `AC/RuntimeObject/` | — | 对象图标的字形选择，与对象的 cell 外观同处 | 1 |
| `AC/AppDefaults.swift` | 移动 → `AC/Storage/` | — | 书签与选项的存储，与 `ResilientFileStorage`、`UserDefaultsNamespace` 同处 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/AppCoreBoundaryTests.swift` | 修改 | 第 89 行改为 `RuntimeViewerAppCore/App/AppRoute.swift`；`allowedLines` 四条改为 `RuntimeViewerAppCore/Document/DocumentState.swift` | 写死的路径 | 1 |
| `AC/Engine/RuntimeEngineBackgroundWork.swift`、`AC/BackgroundWorkProcessActivity.swift` | 移动 → `AC/BackgroundWork/` | — | 后台工作的持有者与它的 App Nap 活动 | 2 |
| `AC/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift`、`AlwaysIndexImageResolver.swift`、`AC/Engine/RuntimeEngine+ImageIndexing.swift` | 移动 → `AC/BackgroundWork/Indexing/` | — | 索引协调器与它调的引擎扩展 | 2 |
| `AC/Find/FindCorpusCoordinator.swift`、`FindCorpusCoordinators.swift`、`FindCorpusFinishedBuild.swift` | 移动 → `AC/BackgroundWork/FindCorpus/` | — | Engine 的 Find 语料协调器 | 2 |
| `AC/Find/CrossReferencePreparationCoordinator.swift`、`CrossReferencePreparationState.swift` | 移动 → `AC/BackgroundWork/CrossReferencePreparation/` | — | Engine 的交叉引用预建协调器 | 2 |
| `AC/ManualLoading/`（`ManualImageLoad`、`ManualImageLoadCoordinator`、`DocumentState+ManualLoading`） | 移动 → `AC/BackgroundWork/ManualLoading/` | — | 手动加载记录也属于 Engine 的后台工作 | 2 |
| `AC/Find/FindMode.swift`、`FindModePath.swift`、`FindPattern.swift`、`FindQueryTerm.swift`、`FindRecentQueries.swift` | 移动 → `AC/Find/Query/` | — | 查询的模型 | 2 |
| `AC/Find/FindScopeChooserViewModel.swift`、`FindScopeImageCellViewModel.swift`、`FindScopeMenu.swift` | 移动 → `AC/Find/Scope/` | — | 搜索范围选择 | 2 |
| `AC/Find/FindResultNode.swift`、`FindResultNode+Icon.swift`、`FindResultsOutline.swift` | 移动 → `AC/Find/Results/` | — | 结果树 | 2 |
| `AC/Find/FindCrossReferences.swift`、`FindCrossReferenceRootResolver.swift`、`FindCrossReferenceTree.swift` | 移动 → `AC/Find/CrossReferences/` | — | Find 的交叉引用模式 | 2 |
| `AC/Find/FindViewModel.swift`、`FindSession.swift`、`FindNavigatorRoutable.swift` | 不动 | — | Find 的入口留在 `Find/` | 2 |
| `AC/Sidebar/SidebarRoot*.swift`（5 个） | 移动 → `AC/Sidebar/Root/` | — | 照 App 一侧 `Sidebar/Root/` | 2 |
| `AC/Sidebar/SidebarRuntimeObject*.swift`（6 个）、`RuntimeObjectScope.swift`、`RuntimeObjectScopeMemory.swift`、`PrivateDeclarationViewModel.swift` | 移动 → `AC/Sidebar/RuntimeObject/` | — | 照 App 一侧 `Sidebar/RuntimeObject/`（Filter Scope 与私有声明的视图都在那里） | 2 |
| `AC/Sidebar/SidebarRoutes.swift` | 不动 | — | 两页共用的路由 | 2 |
| `AC/Inspector/InspectorViewModel.swift` | 拆分后删除 | `InspectorPlaceholderViewModel.swift`、`InspectorRuntimeNodeViewModel.swift` 各一个类型，内容原样 | 名不副实 | 2 |
| `AUI/AppCoordinator.swift` | 移动 → `AUI/App/` | — | 镜像 `AC/App/AppRoute` | 3 |
| `AUI/Transition+Navigation.swift` | 移动 → `AUI/Base/` | — | 路由基础设施 | 3 |
| `AUI/Then.swift`、`AUI/PlatformTypes.swift` | 移动 → `AUI/Extensions/` | — | 与 `NSUIColor+Adaptive` 同处 | 3 |
| `AUI/NavigatorTextFilterFieldAdapter.swift` | 移动 → `AUI/Filtering/` | — | 镜像 `AC/Filtering/NavigatorTextFilter` | 3 |
| `AUI/IDEIconRuntimeObjectIconRenderer.swift`、`AUI/Icons/RuntimeObjectIcon+Image.swift` | 移动 → `AUI/RuntimeObject/` | — | 镜像 `AC/RuntimeObject/RuntimeObjectIcon` | 3 |
| `AUI/Icons/RuntimeImageKind+Icon.swift`、`AUI/Icons/CustomSymbol.swift` | 移动 → `AUI/RuntimeImage/` | — | 镜像 `AC/RuntimeImage/RuntimeImageKind`；`CustomSymbol` 的五个符号都是镜像种类的，唯一使用者是 `RuntimeImageKind+Icon` | 3 |
| `AUI/Icons/SystemSymbol+Image.swift` | 移动 → `AUI/Presentation/` | — | 镜像 `AC/Presentation/SystemSymbol` | 3 |
| `AUI/Theme/NSColor+Xcode.swift` | 移动 → `AUI/Find/Results/` | — | 里面是 Xcode 过滤结果的文字颜色，使用者只有 `FindResultCellStyle` 与 App 的 `FindViewController`，不属于内容页主题；跟着使用者走 | 3 |
| `AUI/Theme/ContentInterface+Theme.swift` | 移动 → `AUI/Content/` | — | 镜像 `AC/Content/ContentInterface`，与 `ContentTextRenderer` 同处 | 3 |
| `AUI/Find/FindModePathControlAdapter.swift`、`FindQueryFieldMenuAdapter.swift`、`FindQueryTerm+FindPatternComponents.swift`、`FindRecentQueries+AttributedTitle.swift` | 移动 → `AUI/Find/Query/` | — | 镜像 `AC/Find/Query/` | 3 |
| `AUI/Find/FindResultActivation.swift`、`FindResultCellStyle.swift`、`FindResultsPresentation+OutlineView.swift` | 移动 → `AUI/Find/Results/` | — | 镜像 `AC/Find/Results/` | 3 |
| `RuntimeViewerPackages/Sources/AGENTS.md` | 修改 | 新增「Where a file goes in RuntimeViewerAppCore and RuntimeViewerAppUI」一节（规则见详细设计）；第 22、74–120 行里的旧路径改成新路径 | 规则落地、路径同步 | 4 |
| `AGENTS.md`（根） | 修改 | Key Source Locations 的 Document state 改为 `…/RuntimeViewerAppCore/Document/DocumentState.swift` | 路径同步 | 4 |

## 架构图

AppCore，改动前后（`+` 新目录，`-` 消失的目录或文件，`→` 来自哪里）：

```text
RuntimeViewerAppCore/
- (root: 17 loose files)
+ App/                       AppRoute                                    → root
+ Base/                      ViewModel, ViewModelProtocol,
                             LoadingPlaceholderTiming, OwnerReportingTask → root
+ Document/                  DocumentState                               → root
+ BackgroundWork/            RuntimeEngineBackgroundWork                 → Engine/
                             BackgroundWorkProcessActivity               → root
+   Indexing/                RuntimeBackgroundIndexingCoordinator,
                             AlwaysIndexImageResolver                    → BackgroundIndexing/
                             RuntimeEngine+ImageIndexing                 → Engine/
+   FindCorpus/              FindCorpusCoordinator(s), FindCorpusFinishedBuild → Find/
+   CrossReferencePreparation/ …Coordinator, …State                      → Find/
+   ManualLoading/           ManualImageLoad(Coordinator), DocumentState+ManualLoading → ManualLoading/
- BackgroundIndexing/
- ManualLoading/
  EditorArea/                + SelectionRoute                            → root
+ Extensions/                Then → root; String+IntegerIndex            ← Extensions.swift
+ Filtering/                 FilterEngine, NavigatorTextFilter(+Keystrokes) → root
  Find/                      FindViewModel, FindSession, FindNavigatorRoutable
+   Query/                   FindMode, FindModePath, FindPattern, FindQueryTerm, FindRecentQueries
+   Scope/                   FindScopeChooserViewModel, FindScopeImageCellViewModel, FindScopeMenu
+   Results/                 FindResultNode(+Icon), FindResultsOutline
+   CrossReferences/         FindCrossReferences, FindCrossReferenceRootResolver, FindCrossReferenceTree
  Inspector/                 - InspectorViewModel.swift
                             + InspectorPlaceholderViewModel, + InspectorRuntimeNodeViewModel
  Presentation/              + SystemSymbol                              → root
+ RuntimeImage/              RuntimeImageKind → root; RuntimeImageNode+Sequence,
                             RuntimeImageLoadState+CaseAccessible        ← Extensions.swift
  RuntimeObject/             + RuntimeObjectIcon                         → root
  Sidebar/                   SidebarRoutes
+   Root/                    SidebarRoot{Bookmark,Cell,Directory}ViewModel, …FilterPipeline, SidebarRootViewModel
+   RuntimeObject/           SidebarRuntimeObject{Bookmark,Cell,List}ViewModel, …FilterPipeline,
                             …Section, SidebarRuntimeObjectViewModel,
                             RuntimeObjectScope(+Memory), PrivateDeclarationViewModel
  Storage/                   + AppDefaults                               → root
  Activity/ BatchExporting/ Content/ ContextMenus/ Engine/ Reports/      (unchanged)
```

AppUI 镜像 AppCore（左列 AppUI 目录，右列它镜像的 AppCore 目录）：

```text
RuntimeViewerAppUI/                                    mirrors RuntimeViewerAppCore/
- (root: 6 loose files)
+ App/            AppCoordinator                       App/AppRoute
+ Base/           Transition+Navigation                Base/
  Content/        ContentTextRenderer
                  + ContentInterface+Theme (← Theme/)  Content/ContentInterface
+ Extensions/     Then, PlatformTypes (← root),
                  NSUIColor+Adaptive                   Extensions/
+ Filtering/      NavigatorTextFilterFieldAdapter      Filtering/NavigatorTextFilter
+ Find/Query/     FindModePathControlAdapter,
                  FindQueryFieldMenuAdapter,
                  FindQueryTerm+FindPatternComponents,
                  FindRecentQueries+AttributedTitle    Find/Query/
+ Find/Results/   FindResultActivation,
                  FindResultCellStyle,
                  FindResultsPresentation+OutlineView,
                  NSColor+Xcode (← Theme/)             Find/Results/
- Icons/
  Presentation/   + SystemSymbol+Image (← Icons/)      Presentation/SystemSymbol
+ RuntimeImage/   RuntimeImageKind+Icon, CustomSymbol  RuntimeImage/RuntimeImageKind
+ RuntimeObject/  RuntimeObjectIcon+Image,
                  IDEIconRuntimeObjectIconRenderer     RuntimeObject/RuntimeObjectIcon
  Theme/          ThemeProfile, ThemePreset+ThemeProfile, ResolvedThemeStream   (AppUI only)
  Activity/ ContextMenus/ EditorArea/ Engine/ Resources/ RuntimeSourcePicker/   (unchanged)
```

## 详细设计

**新增的规则**（写进 `RuntimeViewerPackages/Sources/AGENTS.md`，英文，以下是拟稿）：

```markdown
## Where a file goes in RuntimeViewerAppCore and RuntimeViewerAppUI

- **Nothing at a target's root.** Every file is in a directory named after a feature: the app's own
  folder name where the app has one (`App`, `Base`, `Content`, `EditorArea`, `Find`, `Inspector`,
  `Reports`, `Sidebar/Root`, `Sidebar/RuntimeObject`), otherwise what the directory holds
  (`BackgroundWork`, `Document`, `Engine`, `Extensions`, `Filtering`, `Presentation`, `RuntimeImage`,
  `RuntimeObject`, `Storage`).
- **An engine's background work is in `BackgroundWork/`**: what `RuntimeEngineBackgroundWork` holds —
  indexing, Find corpora, cross-reference preparation, manual loading — one subdirectory each, with
  its state and results. A feature that reads them (Find, the Report, the toolbar's activity) does not
  hold their files.
- **RuntimeViewerAppUI mirrors RuntimeViewerAppCore.** A file that extends, draws or adapts an AppCore
  type goes in the directory of the same name as that type's: `RuntimeObject/RuntimeObjectIcon+Image.swift`
  beside AppCore's `RuntimeObject/RuntimeObjectIcon.swift`. What only AppUI has gets a directory of its
  own (`Theme/`, `RuntimeSourcePicker/`, `Resources/`) or goes with its one user.
- **A file is named after its main type.** Small helper types may stay beside it; a file whose name
  names no type in it, or that holds unrelated things, is split.
```

**两处拆分的写法**：新文件只带它要的 import。`Extensions.swift` 现在 import `Foundation`、`RuntimeViewerCore`、`RuntimeViewerArchitectures`：`String+IntegerIndex` 只要 `Foundation`；`RuntimeImageNode+Sequence` 要 `RuntimeViewerCore`；`RuntimeImageLoadState+CaseAccessible` 要 `RuntimeViewerCore` 与 `RuntimeViewerArchitectures`（`CaseAccessible` 在那里）。`InspectorViewModel.swift` 的 import 两个新文件各带一份，用不到的删掉。拆出来的代码一字不改，文档注释跟着它的类型走。

**改名对 git 历史的影响**：一律用 `git mv`，每个落地步骤一个提交、提交里只有移动（加上测试路径或文档），`git log --follow` 与 blame 都能跟过去。两处拆分在提交里表现为一删两增，旧文件的历史在被删文件那里查。

## 替代方案考量

- **一个文件一个顶层类型（照 RuntimeViewerCore 的规则）**：要把约 35 个多类型文件拆开，多出约 60 个文件，其中不少辅助类型只有几行、只给主类型用（`FindResultCellAppearance`、`TabBarItem`）。用户选了只拆名不副实的。
- **按层分目录（`ViewModels/`、`Models/`、`Services/`）**：同一功能的 ViewModel、模型、路由会分散到三处，和 App 一侧按功能分的目录对不上，改一个功能要跳几个目录。
- **AppUI 按「做什么」分（保留 `Icons/`、`Theme/`）**：0094 之后的现状，从 AppCore 类型找绘制代码没有规律；镜像规则一句话就能说清新文件放哪。
- **Find 语料与交叉引用预建协调器留在 `Find/`**：它们是 Engine 范围的工作，Report 与工具栏活动同样读它们，放在 `Find/` 会让人以为它们属于 Find 面板、随面板创建。
- **测试 target 一起整理**：用户选了先不动，测试目录留到以后。

## 影响

### 用户可见变化

无。只移动源文件，二进制里的代码不变。

### 可发现性

不适用。

### 数据与配置兼容

无影响：没有类型改名，没有存储格式或键名变化。

### 平台与最低版本

不变。iOS 与 macOS 共用这两个 target，按 iOS 模拟器另编一次包确认目录变化对两边都没影响。

### 发布

无影响。正在别的分支上改这两个 target 的人，合并时 git 会按改名跟踪，文件被移动不会冲突，除非同时改了被拆的两个文件。

## 落地步骤

1. **AppCore 根目录收进目录** —— 改动地图里步骤为 1 的各行
   - 行为：`packageBuildsWithNoFileAtAppCoreRoot`（`RuntimeViewerAppCore/` 下没有 `.swift` 文件）
   - 行为：`boundaryTestsStillFindTheiOSRouteAllowances`（`AppCoreBoundaryTests` 全部通过，`allowedLines` 没有失配）
   - 行为：`extensionsSplitKeepsEveryExtension`（拆出的三个文件里的声明与原 `Extensions.swift` 逐行相同）
2. **BackgroundWork、Find 子目录、Sidebar 子目录与 Inspector 拆分** —— 步骤为 2 的各行
   - 行为：`backgroundWorkHoldsEveryCoordinatorTheEngineWorkOwns`（三个协调器与手动加载都在 `BackgroundWork/` 下）
   - 行为：`findDirectoryKeepsOnlyItsEntryPoints`（`Find/` 根下只剩三个文件）
   - 行为：`inspectorSplitKeepsBothViewModels`
3. **AppUI 镜像** —— 步骤为 3 的各行
   - 行为：`packageBuildsWithNoFileAtAppUIRoot`
   - 行为：`iconsDirectoryIsGone`
4. **规则与路径写进文档** —— 步骤为 4 的各行
   - 行为：`agentsFilesNameNoMovedPath`（现行文档里不再有旧路径）

每一步后：包级 `swift build --build-tests`、`RuntimeViewerAppCoreTests` 与 `RuntimeViewerAppUITests` 全部通过（对照既有红灯）、iOS 模拟器包构建通过。全部做完后 `./TuistScript.sh warm` 并编 macOS App（Tuist 生成的工程按文件列，目录变了要重新生成）。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不要：规则写在 `RuntimeViewerPackages/Sources/AGENTS.md`。
- **有没有引入新术语** —— 预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-18 | Created as Draft | 0094 落地后 AppCore 与 AppUI 的目录不再相互对应、根目录散着二十多个文件，用户要求重新整理分类。按轻量档问了一轮：只拆名不副实的文件，测试 target 不动，先写提案再动手。 |
| 2026-11-18 | Accepted | 用户批准，开始实现。功能分支从 `next` 切出，四步各一个提交，做完在本地合进 `next` 给用户看。 |

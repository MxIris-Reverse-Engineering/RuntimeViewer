# Draft - Generation Options 搬进设置，并可按 engine + 镜像逐项覆盖

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-26
- **最后更新**: 2026-11-26
- **所属愿景**: 无
- **关联提案**: [0067](0067-exported-declarations-filter.md)、[0068](0068-exported-objc-declarations-filter.md)、[0104](0104-multiline-type-formatting.md)（往 Generation Options 里加过选项的三份）；[0085](0085-filter-scope-memory.md)（按 engine + 镜像记住 Filter Scope 的先例）；[0029](0029-find-navigator.md)（Find 语料按选项投影）
- **实现分支 / PR**: `feature/generation-options-image-overrides`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

Generation Options 从工具栏的弹窗搬进设置窗口，成为 Settings › Generation Options 一页，那里改的是**全局**选项。每个 engine + 镜像可以**逐项覆盖**全局：覆盖的那几项用这个镜像自己的值，没覆盖的照旧跟着全局走，全局改了它们也跟着变。覆盖在文档窗口里改：Editor › Generation Options for “<镜像名>”… 打开一个 sheet，列出这个镜像生效的选项，改一项就记成这一项的覆盖，改回与全局相同就自动去掉覆盖；被覆盖的行有标记和还原按钮。设置页列出所有覆盖，可以逐项还原或整条删除。工具栏的 Generation Options 按钮和弹窗删掉。全局与覆盖都存在 `settings.json` 的新分支里，首次启动从旧的 `UserDefaults` 键 `generationOptions` 迁移一次。凡是按选项打印或投影 interface 的地方——内容区、复制与保存、单个与批量导出、命名词云、Find 的文本与成员搜索、交叉引用——都按对象所在镜像生效的选项来；CLI 的 `--options app` 与 MCP 只用全局。

## 动机

- **全局一套不够用。** 现在的选项只有一套，存在 `AppDefaults.options`（`UserDefaults` 键 `generationOptions`，`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Storage/AppDefaults.swift`），所有窗口、所有镜像共用。逆向一个框架时要看的地址、偏移、布局注释，换到另一个只想读声明的镜像就成了噪音，只能来回开关；两个窗口各看一个镜像时，一边改了另一边也跟着变。
- **在内容区切一下就改了整个 App。** 内容区 C 导入类型名标签的切换（`ContentTextViewModel.swift:686-694`）直接改写全局的 `cImportedTypeNameSpelling`，用户只想看这一个镜像的 C 名，结果所有窗口的所有镜像一起换了拼写。
- **工具栏按钮占地方。** Generation Options 是偶尔才改的配置，却在三种工具栏样式里都占一个常驻按钮（`MainToolbarController.swift:231`、`326`、`359`），而 App 的其余配置都在设置窗口里。

## 前期调研

### 现状代码怎么走的

- **存储**：`AppDefaults.options` 是 `@UserDefault`，标准域里的键就是 `generationOptions`（`UserDefaultsNamespace.key(_:)` 对 `.standard` 原样返回，`Storage/UserDefaultsNamespace.swift:35`），JSON 编码整个 `RuntimeObjectInterface.GenerationOptions`。
- **改写**：工具栏弹窗 `GenerationOptionsViewController`（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Generation Options/`）经 `GenerationOptionsViewModel`（`RuntimeViewerAppCore/GenerationOptions/GenerationOptionsViewModel.swift`）把一个 `(inout GenerationOptions) -> Void` 应用到 `appDefaults.options`；内容区的 C 名标签切换是另一个改写点。
- **弹窗怎么开**：`MainViewModel.Input.generationOptionsClick`（`Main/MainViewModel.swift:50`、`284`）→ `MainRoute.generationOptions`（`Main/MainRoute.swift:15`）→ `MainCoordinator` 取工具栏按钮做锚点开 popover（`MainCoordinator.swift:108-114`）。工具栏 `allowsUserCustomization = false`（`MainToolbarController.swift:266`），没有存下来的工具栏配置要迁移。
- **合并**：`ViewModel.currentMergedGenerationOptions`（`Base/ViewModel.swift:52`）取 `appDefaults.options`，再填上 `settings.transformer` 与三个按编辑器决定的 `marks…` 字段。根 `AGENTS.md` 的开发规则第 7 条要求单对象 interface 都用它作 interface cache 的键。
- **读取点**（`grep appDefaults.options / currentMergedGenerationOptions`，测试除外）：
  - 内容区取 interface：`ContentTextViewModel.swift:258` 订阅 `appDefaults.$options`；跳转预热 `:654`
  - 保存与复制：`MainViewModel.swift:316`、`:401`
  - 单个导出 `ExportingProgressViewModel.swift:61`，批量导出 `BatchExportingProgressViewModel.swift:69`（一次导出多个镜像，现用同一套选项）
  - 命名词云 `NamingWordCloudViewModel.swift:238`（订阅）、`:370`
  - Find：`FindSession.swift:228`（订阅，选项变了重跑屏上的搜索）、`:372`、`:415`、`:799`（交叉引用的根解析）；`FindViewModel.swift:419` 与 `InspectorReferencesViewModel.swift:328`（打开交叉引用的成员）
  - CLI host：`CommandLineHostController.swift:97` 的 `LiveApplicationOptionsReader`
- **Find 怎么用选项**：语料每个对象只打印一次、带可见性区域；搜索时按请求里的选项投影（`RuntimeInterfaceVisibility`，`RuntimeViewerCore/Search/Corpus/RuntimeInterfaceVisibility.swift`；`RuntimeInterfaceCorpusStore.swift:1054`、`:1101` 各算一次 `visibility`，整次搜索共用）。`RuntimeInterfaceSearchQuery.generationOptions` 与 `RuntimeMemberSearchQuery.generationOptions` 都是**一套**，作用于所有镜像（`RuntimeInterfaceSearchQuery.swift:19`）。请求是合成的 `Codable`：可选字段缺失时解码为 `nil`，不认识的键被忽略，所以加一个可选字段两头都兼容。
- **CLI**：`ApplicationOptionsReader`（`RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Execution/ApplicationOptionsReader.swift`）从 App 的 `UserDefaults` 域读 `generationOptions`，从 `settings.json` 读顶层 `transformer`（把整个文件当 `GenerationOptions` 解码，只有 `transformer` 键重合）。App 自己当 host 时走 `LiveApplicationOptionsReader`。使用指南 `Documentations/Guides/CommandLineInterface.md:111` 写明了这两处来源；插件 skill `AgentPlugins/runtime-viewer/skills/runtime-viewer-cli/SKILL.md:175` 提到「The app's Generation Options › Imported Type Names」。
- **MCP**：`MCPBridgeServer.generationOptions()`（`MCPBridgeServer.swift:822`）用固定的 `.mcp` 预设加 transformer，不读 App 的选项，本提案不碰它。
- **选项清单**：ObjC 11 项（`objcHeaderOptions`，MachOObjCSection 的 `ObjCGenerationOptions`）加顶层的 `marksSwiftNamesFromAPINotes`；Swift 16 项（`SwiftGenerationOptions.swift`），其中 `cImportedTypeNameSpelling` 与 `memberSortOrder` 是枚举，其余是 `Bool`。`maximumLineWidth`（默认 100）不在界面上。`transformer`、三个 `marks…`、`waitsForTypeIndex`、`interfaceLanguage` 是每次请求时决定的，不是用户设的（各自的文档注释都这么写）。

### 设置一侧

- `Settings`（`RuntimeViewerSettings/Settings.swift`）是 `@Observable @Codable` 的根，分支用 `@Default`；`accessPersistedValues()` 必须读到每个顶层属性，`SettingsPersistenceTests` 逐个核对（根 `AGENTS.md` *Settings Integration*）。`RuntimeViewerSettings` 已经依赖 `RuntimeViewerCore`（`Settings+IndexingEngineReference.swift`），能直接用 `RuntimeObjectInterface.GenerationOptions`。
- 一次性迁移放在 `SettingsAccess.runMigrations()`，先例是 `migrateLegacyThemeProfileIfNeeded()`：读 `UserDefaults.standard` 的旧键，用一个 `UserDefaults` 标记保证只跑一次。
- 页面在 `SettingsWindowController`（macOS）与 `SettingsViewController`（iOS）里注册；页面是 SwiftUI，经 `@AppSettings(\.branch)` 绑定（`RuntimeViewerSettingsUI/AppSettings.swift`）。
- UIFoundation 0.50.1（RV 的下限，也是三个锁文件钉的版本）的 `SettingsWindowController` 有 `navigator.navigate(to: SettingsPage.ID)`，能打开到指定页（`UIFoundationSettingsUI/SettingsNavigator.swift:88`，按 tag `0.50.1` 核对过）。App 现在只有 `AppRoute.settings`，经 `AppCoordinator` 调 `showWindow(nil)`。

### 按 engine + 镜像记东西的先例

- `RuntimeObjectScopeMemory`（`Sidebar/RuntimeObject/RuntimeObjectScopeMemory.swift`）用 `Settings.Indexing.EngineReference.key(for:)` 作 engine 的键：本机附加的进程按进程名记（进程重启后键不变），其余按书签范围；再按镜像路径分。只存「真的改了」的条目。
- 最近打开的镜像（提案 [0106](0106-editor-start-page.md)）按 `engine.canonicalImagePath(_:)` 存路径（`RuntimeViewerCore/Engine/RuntimeEngine+ImagePathCanonicalization.swift:41`，`public nonisolated`），因为侧栏的写法与对象的 `imagePath` 可能不同。

### 菜单

- Editor 菜单现在只有 Code Folding（`MainMenuController.swift:389`）；View 菜单的 Show Naming Word Cloud 是「菜单项 → `MainWindowController` 的 `@objc` 动作 → `router.trigger(...)` → `validateMenuItem` 决定能不能点」的现成样板（`MainWindowController.swift:528`、`675`）。

## 提议方案

1. **设置页**：新增 Settings › Generation Options（macOS 放在 Theme 与 Transformer 之间，图标 `ellipsis.curlybraces`，沿用工具栏按钮的符号），分 Objective-C、Swift 两组，控件与原弹窗一一对应（勾选框、两个分段选择）。这里改的是全局。macOS 上页面末尾是 **Image Overrides** 一组：每条覆盖一行（镜像名、engine 名、覆盖了几项），展开后逐项列出覆盖的选项与值，每项可还原，整条可删除；没有覆盖时说明去 Editor 菜单设置。
2. **存储**：`Settings` 加顶层分支 `generationOptions`（`Settings.GenerationOptionsSettings`），含 `global` 与 `imageOverrides`。首次启动把旧的 `UserDefaults` 键 `generationOptions` 迁到 `global`，旧键留着不删（降级回旧版本时还在）。`AppDefaults.options` 删除。
3. **逐项覆盖**：一条覆盖由 engine 的键（`EngineReference.key(for:)`）加镜像的规范路径（`canonicalImagePath(_:)`）认出，存「覆盖了哪几项」与这些项的值。生效选项 = 全局，再把覆盖的那几项换成覆盖值。**改成与全局相同的值就去掉这一项的覆盖**，最后一项去掉时整条删掉，和 Filter Scope 的记法一样只存真正不同的。
4. **窗口里的入口**：Editor 菜单顶部加 **Generation Options for “<镜像名>”…**，作用于聚焦编辑栏显示的镜像（对象所在的镜像，或 jump bar 打开的镜像页），空标签时退到侧栏打开的镜像，都没有时灰掉并显示「Generation Options for This Image…」。它打开一个 AppKit sheet：标题是镜像名，副标题是 engine 名；行与设置页相同，显示这个镜像生效的值，被覆盖的行标题加粗、行尾有还原按钮；底部 Revert All、Global Options…（打开设置窗口到这一页）、Done。改动即时生效，sheet 后面的内容区跟着重取。
5. **按镜像解析**：所有按选项打印或投影的地方都按对象所在镜像的生效选项（详细设计 §3 列全）。内容区、词云、Find 订阅生效选项而不是 `appDefaults.$options`，全局或这个镜像的覆盖变了就重取。
6. **Find**：搜索请求在一套选项之外，多带一张「镜像路径 → 生效选项」的表，只含这个 engine 有覆盖的镜像；引擎对每个镜像按它自己的选项投影。旧版本的对端忽略这张表，退回全部用全局（与今天相同）。
7. **内容区的 C 名标签**：切换改为记成这个对象所在镜像的覆盖，不再改全局。
8. **删掉**工具栏按钮、`MainRoute.generationOptions`、`MainViewModel.Input.generationOptionsClick`、弹窗的 ViewController 与 ViewModel（改造成 sheet 的那一对）。
9. **CLI 与 MCP**：`--options app` 读全局（`settings.json` 的 `generationOptions.global`，读不到再退回旧的 `UserDefaults` 键），不看覆盖；MCP 不变。
10. **iOS / visionOS**：设置里也加这一页，只有全局两组（那边没有设置覆盖的入口，也就不显示 Image Overrides）。

### 非目标

- CLI、MCP 按镜像套用覆盖。CLI 的独立 host 要自己算 engine 键与规范路径，MCP 本来就用固定预设；留作后续项。
- 在设置页里**新建**覆盖或改覆盖的值：设置页只看、还原、删除；新建与修改都在窗口的 sheet 里，那里才有「当前镜像」。
- 按对象覆盖、按镜像名（不分路径）匹配、在 engine 之间共享覆盖。
- 按镜像覆盖 Transformer 或编辑器的显示设置。
- 导出对话框里另选选项：导出照用各镜像生效的选项。
- iOS 上设置覆盖的入口。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerSettings/Settings+GenerationOptionsSettings.swift` · `Settings.GenerationOptionsSettings`；`Settings+ImageGenerationOptionsOverride.swift` · `Settings.ImageGenerationOptionsOverride` | 新增 | 全局 + 覆盖列表的模型；`effectiveOptions(forImageAt:engineKey:)`、`override(forImageAt:engineKey:)`、`updateOverride(forImageAt:engine:_:)`、`revert(_:forImageAt:engineKey:)`、`removeOverride(forImageAt:engineKey:)` | 存储与解析规则放在一处，设置页、sheet、AppCore 共用 | 1 |
| `RuntimeViewerSettings/Settings+GenerationOption.swift` · `Settings.GenerationOption`、`Settings.GenerationOption.Control`、`Settings.GenerationOption.Section` | 新增 | 用户可设的每个选项一个 case（原始值存盘，不改名）：标题、分组、控件（勾选的 key path 或分段选择的标签与读写）、`copyValue(from:to:)`、`hasSameValue(in:as:)` | 逐项覆盖要给每个选项一个稳定的标识；两处界面从同一份清单生成，加选项只改这里 | 1 |
| `RuntimeViewerSettings/Settings+GenerationOptionsEngine.swift` | 新增 | `effectiveOptions(forImageAt:in engine:)`、`updateOverride(forImageAt:in engine:_:)` 等便捷入口：内部取 `EngineReference.key(for:)` 与 `engine.canonicalImagePath(_:)` | 调用方不用自己算键与规范路径 | 1 |
| `RuntimeViewerSettings/Settings.swift` · `Settings`、`SettingsAccess` | 修改 | 加 `@Default var generationOptions`；`accessPersistedValues()` 读它；`runMigrations()` 加 `migrateLegacyGenerationOptionsIfNeeded()` | 新分支要持久化；旧值迁一次 | 1 |
| `Tests/RuntimeViewerSettingsTests/SettingsPersistenceTests.swift` | 修改 | 覆盖清单加 `generationOptions` | 守住 `accessPersistedValues()` | 1 |
| `Tests/RuntimeViewerSettingsTests/GenerationOptionsSettingsTests.swift`、`GenerationOptionCatalogTests.swift`、`LegacyGenerationOptionsMigrationTests.swift` | 新增 | 解析、覆盖增删、清单覆盖全部字段、迁移 | 见各步行为 | 1 |
| `RuntimeViewerAppCore/GenerationOptions/SettingsAccess+GenerationOptions.swift` | 新增 | `mergedGenerationOptions(forImageAt:in:)`：生效选项再填 transformer 与 `marks…`（`mergingRequestOptions(into:)`）；`generationOptionsSettingsObservable()` 与 `effectiveGenerationOptionsObservable(forImageAt:in:)` 返回 `Observable` | 取代 `currentMergedGenerationOptions` 里的合并逻辑，非 ViewModel（`FindSession`）也能用 | 2 |
| `RuntimeViewerAppCore/Base/ViewModel.swift` · `ViewModel` | 修改 | `currentMergedGenerationOptions` 换成 `mergedGenerationOptions(for runtimeObject:)` 与 `mergedGenerationOptions(forImageAt:)` | 选项随镜像而定 | 2 |
| `RuntimeViewerAppCore/Content/ContentTextViewModel.swift` | 修改 | 取 interface 的管线订阅这个对象所在镜像的生效选项；C 名标签切换写这个镜像的覆盖；「Turn it off in Generation Options…」提示改指向新位置 | 内容区按镜像；切换不再动全局 | 2 |
| `RuntimeViewerAppCore/Main/MainViewModel.swift` | 修改 | 保存与复制用对象所在镜像的合并选项；删 `generationOptionsClick` | 同上；按钮删了 | 2、5 |
| `RuntimeViewerAppCore/Exporting/ExportingProgressViewModel.swift`、`BatchExporting/BatchExportingProgressViewModel.swift` | 修改 | 单个导出用该镜像的生效选项；批量导出每个镜像各用各的 | 导出与内容区一致 | 2 |
| `RuntimeViewerAppCore/NamingWordCloud/NamingWordCloudViewModel.swift` | 修改 | 订阅并使用该镜像的生效选项 | 同上 | 2 |
| `RuntimeViewerAppCore/Storage/AppDefaults.swift` · `AppDefaults` | 修改 | 删 `options` 与它的初始化 | 存储搬走了 | 2 |
| `Tests/RuntimeViewerAppCoreTests/`（`ViewModelBaseTests`、`ContentTextPipelineTests`、`CImportedTypeNameTagTests`、`AppDefaultsIsolationTests`、`FindGenerationOptionsTests`、`FindSessionLifecycleTests`） | 修改 | 从注入 `AppDefaults.options` 改为注入 `SettingsAccess.preview` 的 `generationOptions`；隔离测试删掉 `$options` 那一条 | 跟着存储走 | 2、3 |
| `Tests/RuntimeViewerAppCoreTests/ImageGenerationOptionsResolutionTests.swift` | 新增 | 两个镜像各自生效、覆盖变化只重取受影响的内容区、导出按镜像 | 见第 2 步行为 | 2 |
| `RuntimeViewerCore/Search/RuntimeInterfaceSearchQuery.swift`、`RuntimeMemberSearchQuery.swift` | 修改 | 加 `generationOptionsByImagePath: [String: RuntimeObjectInterface.GenerationOptions]?` 与 `generationOptions(forImageAt:)` | 每个镜像按自己的选项投影；可选字段对旧对端兼容 | 3 |
| `RuntimeViewerCore/Search/RuntimeEngine+Search.swift` | 修改 | 表的键照 `imagePaths` 一样经 `imageCatalog.canonicalImagePath` 规范化（`canonicalizingImagePaths(_:)`）再交给语料库 | 语料库按目录的规范路径存镜像 | 3 |
| `RuntimeViewerCore/Search/Corpus/RuntimeInterfaceCorpusStore.swift` | 修改 | 扫描前做好 `SearchVisibilities`（私有，按镜像的可见性表）；`scan` 的匹配闭包多收一个参数：条目所在镜像（来源的路径） | 原来整次搜索只有一个 `visibility` | 3 |
| `Tests/RuntimeViewerCoreTests/RuntimeInterfaceSearchImageGenerationOptionsTests.swift` | 新增 | 两个方向的按镜像投影；没有表的请求与今天相同；旧形状的 JSON 能解码 | 见第 3 步行为 | 3 |
| `RuntimeViewerAppCore/Find/Query/FindGenerationOptions.swift` · `FindGenerationOptions` | 新增 | 一次搜索读镜像所用的选项：全局 + 本 engine 各镜像的生效选项 | `FindSession` 的请求、重跑判断与交叉引用根解析共用一个值 | 3 |
| `RuntimeViewerAppCore/Find/FindSession.swift`、`Find/CrossReferences/FindCrossReferenceRootResolver.swift`、`Find/CrossReferences/FindCrossReferences.swift`、`Find/FindViewModel.swift`、`Inspector/InspectorReferencesViewModel.swift` | 修改 | 请求带上这个 engine 的覆盖表；订阅 `generationOptions` 分支重跑屏上的搜索；交叉引用按成员所在镜像取选项 | Find 结果与内容区逐字相同 | 3 |
| `RuntimeViewerSettingsUI/Components/GenerationOptionsSettingsView.swift` · `GenerationOptionsSettingsView` | 新增 | 全局两组（从 `GenerationOption.allCases` 生成）+ macOS 的 Image Overrides 组 | 设置页 | 4 |
| `RuntimeViewerSettingsUI/SettingsWindowController.swift`、`SettingsViewController.swift` | 修改 | 注册新页（id `generationOptions`）；macOS 暴露 `show(pageWithID:)` | 新页；sheet 要跳到这一页 | 4 |
| `RuntimeViewerSettings/Settings+PageIdentifier.swift` · `Settings.PageIdentifier` | 新增 | 页面 id 常量（先只放 `generationOptions`） | AppCore 的路由与设置窗口共用一个 id，不各写字符串 | 4 |
| `RuntimeViewerAppCore/App/AppRoute.swift`、`RuntimeViewerAppUI/App/AppCoordinator.swift` | 修改 | 加 `AppRoute.settingsPage(Settings.PageIdentifier)`，AppCoordinator 导航后显示窗口 | sheet 的 Global Options… | 4 |
| `RuntimeViewerAppCore/GenerationOptions/GenerationOptionsViewModel.swift` → `ImageGenerationOptionsViewModel.swift` | 修改（改名） | 编辑一个镜像的覆盖：输出行（选项、生效值、是否覆盖）、标题副标题；输入改值、还原一项、全部还原、打开全局、完成 | 弹窗改造成 sheet | 5 |
| `RuntimeViewerUsingAppKit/.../Generation Options/GenerationOptionsViewController.swift` → `ImageGenerationOptionsViewController.swift` | 修改（改名） | 行从 `GenerationOption` 生成；被覆盖的行加粗并显示还原按钮；底部三个按钮 | 同上 | 5 |
| `RuntimeViewerAppCore/Main/MainRoute.swift` | 修改 | 删 `generationOptions`；加 `imageGenerationOptions(imagePath: String)` | 新入口 | 5 |
| `RuntimeViewerUsingAppKit/.../Main/MainCoordinator.swift` | 修改 | 删 popover 分支；新路由开 sheet，完成时 `.dismiss` | 同上 | 5 |
| `RuntimeViewerUsingAppKit/.../Main/MainToolbarController.swift`、`MainWindowController.swift` | 修改 | 删 `generationOptionsItem` 及三种样式的标识；加 `@objc showImageGenerationOptions(_:)` 与 `validateMenuItem` 分支（动态标题、能否点） | 删按钮；菜单入口 | 5 |
| `RuntimeViewerUsingAppKit/.../App/MainMenuController.swift` | 修改 | Editor 菜单顶部加菜单项与分隔线 | 入口 | 5 |
| `RuntimeViewerAppCore/GenerationOptions/DocumentState+ImageGenerationOptions.swift` | 新增 | `DocumentState.imagePathForGenerationOptions`：聚焦标签的对象或镜像页的镜像，退到侧栏的镜像 | 菜单项与 sheet 用同一个答案 | 5 |
| `Tests/RuntimeViewerAppCoreTests/ImageGenerationOptionsViewModelTests.swift` | 新增 | sheet 的行为 | 见第 5 步行为 | 5 |
| `RuntimeViewerCommandLineInterface/Execution/ApplicationOptionsReader.swift` | 修改 | 先读 `settings.json` 的 `generationOptions.global`，读不到再读旧 `UserDefaults` 键 | 存储搬走 | 6 |
| `RuntimeViewerUsingAppKit/.../App/CommandLineHostController.swift` · `LiveApplicationOptionsReader` | 修改 | 读 `settings.generationOptions.global` | 同上 | 6 |
| `RuntimeViewerCommandLine/Tests/.../ApplicationOptionsReaderTests.swift` | 修改 | 新位置、旧位置、两处都有时新的优先 | 同上 | 6 |
| `Documentations/Guides/CommandLineInterface.md`、`AgentPlugins/runtime-viewer/skills/runtime-viewer-cli/SKILL.md` 与两个插件清单的 `version` | 修改 | `--options app` 的来源与「只用全局」；Imported Type Names 的位置 | CLI 文档跟着改；插件规则要求升版本 | 6 |
| 根 `AGENTS.md` 开发规则第 7 条、`RuntimeViewerUsingAppKit/AGENTS.md`（*Routes carry no views* 里的 popover 例子）、`RuntimeViewerUsingUIKit/AGENTS.md`（iOS 设置页清单）、`Documentations/Glossary.md` | 修改 | 新 API 名；popover 例子只剩 MCP；iOS 页清单；术语「镜像覆盖」 | 文档与代码同批 | 6 |

## 架构图

### 改了什么

```text
Before                                         After
──────                                         ─────
Toolbar [{…}] ─▶ MainRoute.generationOptions   Editor ▸ Generation Options for "X"…
   popover: GenerationOptionsViewController      ─▶ MainRoute.imageGenerationOptions(imagePath:)
          │                                         sheet: ImageGenerationOptionsViewController
          ▼                                                 │
AppDefaults.options  (UserDefaults               Settings ▸ Generation Options (SwiftUI)
   "generationOptions")                                     │
          │                                                 ▼
          │                                  + Settings.generationOptions  (settings.json)
          │                                      global: GenerationOptions
          │                                      imageOverrides: [ImageGenerationOptionsOverride]
          │                                        engine: EngineReference  imagePath (canonical)
          │                                        overriddenOptions: Set<GenerationOption>
          │                                        values: GenerationOptions
          ▼                                                 │
ViewModel.currentMergedGenerationOptions         effectiveOptions(forImageAt:in engine:)
   (one set for every image)                      = global, overridden options replaced
          │                                                 │
          ▼                                                 ▼
content · save/copy · export · batch export    + SettingsAccess.mergedGenerationOptions(forImageAt:in:)
word cloud · Find · cross references             (per object's image; Find gets a per-image table)
CLI --options app                                CLI --options app ─▶ global only
```

### 一次取 interface 的数据流

```text
ContentTextViewModel
  $runtimeObject ──flatMapLatest──▶ Observable.tracking {
                                        settings.generationOptions
                                          .effectiveOptions(forImageAt: object.imagePath, in: engine)
                                     } .distinctUntilChanged()
        └─ combineLatest(transformer, marksCommentStructure, typeNameResolutionCount)
             └─ merged options ─▶ documentState.interfaceCache.interface(for:options:) ─▶ engine

Find text / member search
  FindSession.startSearch
    query.generationOptions            = global (merged)
  + query.generationOptionsByImagePath = [canonical path: effective]   // this engine's overrides only
      └─▶ RuntimeEngine.searchInterfaces
            translate canonical paths ─▶ catalog spelling
            └─▶ RuntimeInterfaceCorpusStore.searchInterfaces
                  visibilityByImagePath (built before the scan)
                  entry ─▶ visibility(for: entry.object.imagePath) ─▶ projection ─▶ matches
```

### 窗口入口

```text
MainMenuController.editorMenuItem
+ "Generation Options for \"X\"…"  ─▶ MainWindowController.showImageGenerationOptions(_:)
                                        imagePath = documentState.imagePathForGenerationOptions
                                        router.trigger(.imageGenerationOptions(imagePath:))
                                     ─▶ MainCoordinator ─▶ .presentOnRoot(sheet, mode: .asSheet)
ImageGenerationOptionsViewModel
  updateOption ─▶ settings.generationOptions.updateOverride(forImageAt:in:)
  revert(option) / revertAll ─▶ revert(_:…) / removeOverride(…)
  showGlobalOptions ─▶ appRouter.trigger(.settingsPage(.generationOptions))
- MainToolbarController.generationOptionsItem
- MainViewModel.Input.generationOptionsClick
```

## 详细设计

### 1. 选项清单 `Settings.GenerationOption`

```swift
extension Settings {
    /// One Generation Option the user sets, as the settings page and the image sheet list it, and
    /// as an image override names it. The raw values are stored in `settings.json`: never rename one.
    public enum GenerationOption: String, CaseIterable, Codable, Sendable {
        // Objective-C
        case objcStripProtocolConformance = "objc.stripProtocolConformance"
        case objcStripOverrides = "objc.stripOverrides"
        // … the other nine of `ObjCGenerationOptions`, then:
        case marksSwiftNamesFromAPINotes = "objc.marksSwiftNamesFromAPINotes"
        // Swift
        case swiftPrintStrippedSymbolicItem = "swift.printStrippedSymbolicItem"
        // … the other fifteen of `SwiftGenerationOptions` the popover lists today

        public enum Section: Sendable { case objectiveC, swift }

        public enum Control {
            case toggle(WritableKeyPath<RuntimeObjectInterface.GenerationOptions, Bool>)
            case choice(labels: [String], selectedIndex: (RuntimeObjectInterface.GenerationOptions) -> Int,
                        select: (Int, inout RuntimeObjectInterface.GenerationOptions) -> Void)
        }

        public var title: String { get }      // the popover's titles, unchanged
        public var section: Section { get }
        public var control: Control { get }

        /// Copies this option's value from `source` into `destination`.
        public func copyValue(from source: RuntimeObjectInterface.GenerationOptions,
                              to destination: inout RuntimeObjectInterface.GenerationOptions)

        public func hasSameValue(in options: RuntimeObjectInterface.GenerationOptions,
                                 as otherOptions: RuntimeObjectInterface.GenerationOptions) -> Bool
    }
}
```

- 用 `enum` 而不是「struct 加静态成员」：这是 App 内部的清单，需要 `CaseIterable` 生成界面，也要 `switch` 的穷尽检查——加一个 case 不写标题和控件就编不过。
- 标题、顺序照原弹窗（`GenerationOptionsViewController.sections`），两个分段选择的标签也照抄（Swift / C，By Category / By Offset）。
- `GenerationOptionCatalogTests` 守住清单：逐个翻转每个选项，比较 `objcHeaderOptions`、`swiftInterfaceOptions` 编码后的键，所有键都要恰好被一个选项改到；不在界面上的字段（现在只有 `maximumLineWidth`）列在测试的排除清单里并写明理由。往 `ObjCGenerationOptions` / `SwiftGenerationOptions` 加字段而忘了加 case，测试就红。

### 2. 存储 `Settings.GenerationOptionsSettings`

```swift
extension Settings {
    @Codable
    @MemberInit
    public struct GenerationOptionsSettings: Sendable, Hashable {
        /// What every image is printed with, unless it overrides an option. Only the options
        /// `GenerationOption` lists are read from it; the per-request fields (`transformer`, the
        /// `marks…` flags, `waitsForTypeIndex`, `interfaceLanguage`) keep their defaults.
        @Default(RuntimeObjectInterface.GenerationOptions())
        public var global: RuntimeObjectInterface.GenerationOptions

        @Default([ImageGenerationOptionsOverride]())
        public var imageOverrides: [ImageGenerationOptionsOverride]

        public func effectiveOptions(forImageAt canonicalImagePath: String, engineKey: String) -> RuntimeObjectInterface.GenerationOptions
        public func override(forImageAt canonicalImagePath: String, engineKey: String) -> ImageGenerationOptionsOverride?
        /// Applies `body` to the image's effective options and records every option it changed:
        /// as an override where the new value differs from `global`, removing the override where
        /// it is the same. An override left with no option is removed.
        public mutating func updateOverride(forImageAt canonicalImagePath: String, engine: Indexing.EngineReference,
                                            _ body: (inout RuntimeObjectInterface.GenerationOptions) -> Void)
        public mutating func revert(_ option: GenerationOption, forImageAt canonicalImagePath: String, engineKey: String)
        public mutating func removeOverride(forImageAt canonicalImagePath: String, engineKey: String)
    }

    @Codable
    @MemberInit
    public struct ImageGenerationOptionsOverride: Sendable, Hashable, Identifiable {
        /// The engine's key and the names it carried when the override was last changed, for the
        /// settings page to show.
        public var engine: Indexing.EngineReference
        /// In the engine's canonical spelling (`RuntimeEngine.canonicalImagePath(_:)`).
        public var imagePath: String
        public var overriddenOptions: Set<GenerationOption>
        /// The overridden options' values; the other fields mean nothing.
        public var values: RuntimeObjectInterface.GenerationOptions

        public var id: String { engine.key + "\u{0}" + imagePath }
    }
}
```

- 存一份完整的 `GenerationOptions` 当值、再存一组覆盖了哪几项，而不是为每种值另造一个 `enum`：复用现成的 `Codable`，`copyValue` 一个 key path 就搞定。`Set<GenerationOption>` 编码为原始值字符串的数组；解码时不认识的原始值（将来删掉的选项）丢弃，不让整条覆盖解码失败。
- `global` 照旧存整个 `GenerationOptions`，与旧 `UserDefaults` 里的形状相同，迁移是原样搬，CLI 也照旧按这个类型解码。
- 便捷入口（`Settings+GenerationOptionsEngine.swift`）：

```swift
extension Settings.GenerationOptionsSettings {
    public func effectiveOptions(forImageAt imagePath: String, in engine: RuntimeEngine) -> RuntimeObjectInterface.GenerationOptions {
        effectiveOptions(forImageAt: engine.canonicalImagePath(imagePath),
                         engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }
    public mutating func updateOverride(forImageAt imagePath: String, in engine: RuntimeEngine,
                                        _ body: (inout RuntimeObjectInterface.GenerationOptions) -> Void)
    /// This engine's overrides as effective options, keyed by canonical image path — what a Find
    /// request carries.
    public func effectiveOptionsByImagePath(in engine: RuntimeEngine) -> [String: RuntimeObjectInterface.GenerationOptions]
}
```

- 迁移 `migrateLegacyGenerationOptionsIfNeeded()`，照主题迁移的写法：
  1. `UserDefaults.standard` 的标记 `didMigrateLegacyGenerationOptions` 已设就返回；否则 `defer` 设上，无论结果如何只试一次。
  2. 读旧键 `generationOptions`，解码成 `GenerationOptions`；没有或解码失败就返回，旧数据留着。
  3. 只有 `generationOptions.global` 仍等于默认值时才写入，免得覆盖用户已在新版本里改过的全局（比如标记被清掉之后）。
  4. 旧键不删。

### 3. 按镜像解析与各个消费者

```swift
// RuntimeViewerAppCore
extension SettingsAccess {
    /// The options a fetch of an object in this image uses: its effective Generation Options,
    /// with the transformer and the editor's `marks…` flags merged in, as the content pane merges them.
    public func mergedGenerationOptions(forImageAt imagePath: String, in engine: RuntimeEngine) -> RuntimeObjectInterface.GenerationOptions
    public func mergingRequestOptions(into options: RuntimeObjectInterface.GenerationOptions) -> RuntimeObjectInterface.GenerationOptions
    /// The branch now and whenever it changes; emits on the main thread.
    public nonisolated func generationOptionsSettingsObservable() -> Observable<Settings.GenerationOptionsSettings>
    /// The image's effective options, emitting only when they change.
    public nonisolated func effectiveGenerationOptionsObservable(forImageAt imagePath: String, in engine: RuntimeEngine) -> Observable<RuntimeObjectInterface.GenerationOptions>
}

extension ViewModel {
    public func mergedGenerationOptions(for runtimeObject: RuntimeObject) -> RuntimeObjectInterface.GenerationOptions
    public func mergedGenerationOptions(forImageAt imagePath: String) -> RuntimeObjectInterface.GenerationOptions
}
```

| 消费者 | 用哪个镜像 | 订阅变化 |
|---|---|---|
| 内容区取 interface、跳转预热 | 对象的 `imagePath` | 是：`$runtimeObject` → `Observable.tracking { effectiveOptions }`，取代 `appDefaults.$options` |
| 保存、复制 | 对象的 `imagePath` | 否 |
| 单个导出 | `exportingState.imagePath` | 否 |
| 批量导出 | 每个镜像各自 | 否 |
| 命名词云 | 词云的镜像 | 是 |
| Find 文本与成员搜索 | 每个镜像各自（请求里的表） | 是：订阅 `settings.generationOptions` 整个分支，变了就重跑屏上的搜索 |
| 交叉引用根解析、打开成员 | 成员所在镜像 | 否 |
| CLI `--options app`（两种 host） | 无：只用 `global` | — |
| MCP | 不变：`.mcp` 预设 | — |

- 订阅用 `Observable.tracking`，与 transformer 的订阅同法（`ContentTextViewModel.swift:197`）；读的是整个 `generationOptions` 分支，任何覆盖变了都会唤醒，`distinctUntilChanged()` 挡掉与本镜像无关的变化，不重取。
- interface cache 的键里本来就有选项，两个镜像各自的选项自然是不同的缓存条目，不用改 cache。

### 4. Find 的请求

```swift
public struct RuntimeInterfaceSearchQuery: Hashable, Codable, Sendable {
    // …
    public var generationOptions: RuntimeObjectInterface.GenerationOptions?
    /// Images read under options of their own, keyed by canonical image path; an image not listed
    /// is read under `generationOptions`. A peer that predates it ignores the key and reads every
    /// image under `generationOptions`.
    public var generationOptionsByImagePath: [String: RuntimeObjectInterface.GenerationOptions]?

    public func generationOptions(forImageAt imagePath: String) -> RuntimeObjectInterface.GenerationOptions?
}
```

- `RuntimeMemberSearchQuery` 同样加这两样。
- `RuntimeEngine+Search` 在交给语料库前，把表的键照 `imagePaths` 的做法经 `imageCatalog.canonicalImagePath` 规范化：语料库本来就按目录的规范路径存镜像（实现时查明，原先设想的「换成目录写法」不需要）。规范化只对 iOS 模拟器进程（`DYLD_ROOT_PATH` 前缀）改变路径。
- `RuntimeInterfaceCorpusStore.searchInterfaces` / `searchMembers`：扫描前做好私有的 `SearchVisibilities`（整体那一套加按镜像的表，都是 `RuntimeInterfaceVisibility`）；`scan` 把每个来源的镜像路径交给匹配闭包，闭包按它取可见性。没有表时与今天完全相同。
- 借用 shared cache 镜像的 engine（文件、Load Frameworks 的窗口）：搜索是跨 engine 的 spanning 命令（`RuntimeEngine+SpanningCommands.swift`），每个参与者拿到的是原请求的副本，只改了 `imagePaths`，表原样带过去，参与者按自己的规范路径查。读代码核实，没有另写测试。
- `FindSession` 用 `FindGenerationOptions`（全局 + 本 engine 的表）构造请求，`ShownSearch` 记下它；设置变了先比一比本 engine 的值，没变（例如别的 engine 的覆盖）就不重跑。交叉引用的根解析（`FindCrossReferenceRootResolver.resolve`）也收它。

### 5. sheet

- `DocumentState.imagePathForGenerationOptions`：聚焦编辑栏活动标签的当前条目——对象就取对象的 `imagePath`，镜像页取镜像路径——空标签退到 `currentImageNode?.path`，都没有为 `nil`。
- 菜单项：`MainWindowController.validateMenuItem` 在有镜像时把标题设为 `Generation Options for “<镜像名>”…` 并可点；没有时标题为 `Generation Options for This Image…`、灰掉。
- `ImageGenerationOptionsViewModel`：

```swift
public final class ImageGenerationOptionsViewModel: ViewModel<MainRoute> {
    @MemberwiseInit(.public)
    public struct Input {
        public let updateOption: Signal<GenerationOptionsMutation>
        public let revertOption: Signal<Settings.GenerationOption>
        public let revertAll: Signal<Void>
        public let showGlobalOptions: Signal<Void>
        public let done: Signal<Void>
    }

    public struct Output {
        public let title: Driver<String>          // the image's name
        public let subtitle: Driver<String>       // the engine's name
        public let options: Driver<RuntimeObjectInterface.GenerationOptions>   // effective
        public let overriddenOptions: Driver<Set<Settings.GenerationOption>>
        public let canRevertAll: Driver<Bool>
    }

    public init(imagePath: String, documentState: DocumentState, router: any Router<MainRoute>)
}
```

- 状态订阅 `settings.generationOptions`，所以设置页里同时改全局、或还原这个镜像的覆盖，sheet 立刻跟着变。
- ViewController 从 `Settings.GenerationOption.allCases` 按分组生成行（每行：控件 + 还原按钮，按钮只在被覆盖时显示；被覆盖时标题加粗），底部 Revert All / Global Options… / Done；这些固定按钮用 `rx.click`，行内动态生成的控件照现在的写法汇进一个 `PublishRelay`（AGENTS 允许的例外）。Done 触发 `.dismiss`。

### 6. 设置页

- `GenerationOptionsSettingsView`：`@AppSettings(\.generationOptions) var settings`。全局两组：`Toggle(option.title, isOn: $settings.global[dynamicMember: keyPath])`；分段选择用 `Picker(...).pickerStyle(.segmented)`，绑定由 `selectedIndex` / `select` 拼成。
- Image Overrides（`#if os(macOS)`）：每条一个 `DisclosureGroup`，标签是镜像名（路径最后一段）与 engine 名、「N options」，展开后逐项列「标题：值」与还原按钮；行尾 Remove。footer 说明「Set an image's own options from Editor › Generation Options for This Image… in its window」。按 engine 名、镜像名排序。
- 在 `SettingsWindowController` 里排在 Theme 之后、Transformer 之前；iOS 的 `SettingsViewController` 里排在 Theme 之后。

### 7. CLI

- `ApplicationOptionsReader.readGenerationOptions()`：先把 `settings.json` 解码成一个私有的镜像结构 `{ generationOptions: { global: GenerationOptions? }? }`，拿到 `global` 就用；否则退回旧的 `UserDefaults` 键；都没有用默认值。`transformer` 照旧从顶层读。读不了的文件照旧记一行 `HostLog`。
- `LiveApplicationOptionsReader` 读 `settings.generationOptions.global` 再填 transformer。

## 替代方案考量

- **整套覆盖**（一个镜像要么跟随全局，要么复制一整套）：界面更简单，但覆盖之后再改全局就再也影响不到它，用户以为改了全局、某些镜像却没变。用户选了逐项覆盖。
- **保留工具栏按钮，改成编辑当前镜像**：入口最顺手，但与「搬进设置」的目的相反，按钮照样常驻占位。用户选了 Editor 菜单加 sheet。
- **只在设置页里管理覆盖**：设置窗口不属于任何文档窗口，没有「当前镜像」，新建覆盖要从列表里挑 engine 和镜像，绕。被否。
- **覆盖存进 `AppDefaults` 的文件存储**（像 Filter Scope 那样）：设置页要绑定和列出覆盖，放在 `Settings` 里能直接用 `@AppSettings`；全局与覆盖也只在一个文件里，CLI 读一处。被否。
- **为每个选项的值另造一个 `enum` 做稀疏字典**：要为每种值类型写编解码与比较；存一份完整的 `GenerationOptions` 加一组选项名，复用现成的 `Codable` 与 key path。被否。
- **Find 只用全局**：改动最小，但有覆盖的镜像里，Find 搜到的行与内容区显示的不一致（被隐藏的部分会被搜到，行内容也对不上），违背 Find 「搜到的行与内容区逐字相同」的设计（术语表「Find 语料」）。被否。
- **值改回与全局相同时保留覆盖**（钉住这个值，不随全局变）：能表达「始终开」，但存储里会留下大量与全局相同的条目，用户也看不出哪些是真的不同。按 Filter Scope 的先例只存真不同的。被否，有需要再加「钉住」。
- **CLI 也按镜像套覆盖**：独立 host 不链接 App，要自己算 engine 键与规范路径并读覆盖；收益是 CLI 输出与 App 一致。工作量与风险不小，留作后续项。

## 影响

### 用户可见变化

- 工具栏不再有 Generation Options 按钮（三种样式都去掉）。替代路径：全局在 Settings › Generation Options；单个镜像在 Editor › Generation Options for “<镜像名>”…。
- 设置窗口多一页 Generation Options；iOS 的设置里也多这一页（只有全局）。
- 内容区切换 C 导入类型名的标签，只改当前镜像，不再改所有镜像。
- Find 在有覆盖的镜像里按那个镜像的选项搜。
- 内容区「只打印导出的声明」提示里的「Turn it off in Generation Options」改为指向新位置。

### 可发现性

- 设置窗口侧栏能看到新页；Editor 菜单顶部的菜单项标题带当前镜像名。
- 设置页的 Image Overrides 组在没有覆盖时说明去哪里设。
- 下一个功能版本的 What's New 可以提一句（属于发版时的事，不在本提案里写）。

### 数据与配置兼容

- 首次启动把旧 `UserDefaults` 键 `generationOptions` 迁进 `settings.json`，旧键不删：降级回旧版本时旧版本照旧读到它（但读不到新版本里的修改与覆盖）。迁移失败（旧数据解码不了）时用默认值，旧数据留着，与主题迁移相同。
- `settings.json` 多一个顶层键 `generationOptions`；旧版本读新文件时忽略它（`@Codable` 不认识的键跳过）。
- 新版本的 CLI 读新位置，读不到再读旧键，所以新 CLI 配旧 App、旧 CLI 配新 App 都能读到（旧 CLI 读到的是迁移时的旧值）。
- Find 请求的新字段是可选的：新 App 连旧对端（注入的旧载荷、旧 service）时对端忽略它，按全局搜；旧 App 连新对端时字段缺失，与今天相同。

### 平台与最低版本

- 不变。macOS 15+ 的 App 全部可用；iOS / visionOS 只有设置页的全局部分。

### 发布

- 无新权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。插件 skill 文字改了，按插件规则两个清单的 `version` 升一级。

## 落地步骤

1. **设置模型、选项清单与迁移**（已完成） —— 改动地图里 `RuntimeViewerSettings` 的五行与 `RuntimeViewerSettingsTests` 的两行
   - 行为：`effectiveOptionsEqualsGlobalWithoutOverride`
   - 行为：`overriddenOptionUsesImageValueAndOthersFollowGlobal`
   - 行为：`changingGlobalReachesOptionsTheImageDoesNotOverride`
   - 行为：`updatingAnOptionToTheGlobalValueRemovesItsOverride`
   - 行为：`removingTheLastOverriddenOptionRemovesTheOverride`
   - 行为：`overridesOfOtherEnginesOrImagesDoNotApply`
   - 行为：`unknownStoredOptionIsDroppedWithoutLosingTheOverride`
   - 行为：`catalogCoversEveryEncodedOptionExactlyOnce`
   - 行为：`legacyUserDefaultsOptionsMigrateIntoGlobalOnce`
   - 行为：`unreadableLegacyOptionsLeaveDefaultsAndKeepTheOldValue`
   - 行为：`legacyOptionsDoNotOverwriteAGlobalAlreadyChanged`
   - 行为：`settingsPersistenceCoversGenerationOptions`
2. **按镜像解析，换掉 `AppDefaults.options`**（已完成） —— `RuntimeViewerAppCore` 里 Base、Content、Main（保存与复制）、Exporting、BatchExporting、NamingWordCloud、Storage 各行与改动的测试；新行为的测试放进已有的套件（`ContentTextPipelineTests`、`CImportedTypeNameTagTests`、`ViewModelBaseTests`、`NamingWordCloudViewModelTests`）与新的 `BatchExportingGenerationOptionsTests`
   - 行为：`contentPaneUsesTheEffectiveOptionsOfTheObjectsImage`（含「改这个镜像的覆盖会重取」）
   - 行为：`anOverrideOfAnotherImageDoesNotRefetchTheContentPane`
   - 行为：`togglingFlipsStoredSpelling`（C 名标签只改对象所在镜像）
   - 行为：`mergedOptionsCombineEffectiveOptionsAndTransformer`（保存、复制与跳转预热都经 `mergedGenerationOptions(for:)`）
   - 行为：`batchExportUsesEachImagesOwnOptions`
   - 行为：`wordCloudCountsUnderItsImagesOptions`
3. **Find 按镜像投影**（已完成） —— Core 的四行、AppCore 的 Find 与交叉引用各行、Find 的测试
   - 行为：`searchProjectsEachImageUnderItsOwnOptions`（文本与成员搜索，两个方向）
   - 行为：`searchWithoutPerImageTableMatchesTodaysResults`
   - 行为：`queryEncodedWithoutTheTableStillDecodes`
   - 行为：`changingAnOverrideRerunsTheShownSearch`
   - 行为：`anotherEnginesOverrideRunsNothingAgain`
4. **设置页**（已完成） —— `RuntimeViewerSettingsUI` 三行、`Settings.PageIdentifier`、`AppRoute` 与 `AppCoordinator`
   - 行为（编译核实）：两处设置窗口注册新页，`AppRoute.settingsPage` 经 `SettingsWindowController.show(_:)` 打开
   - 行为（目视，交给用户）：设置页的两组控件与 Image Overrides 的展开、还原、删除
5. **窗口 sheet，删掉工具栏按钮**（已完成） —— AppCore 的 GenerationOptions、Main、Document 各行，App 的 Generation Options、Main、MainMenuController 各行，`ImageGenerationOptionsViewModelTests`
   - 行为：`menuItemTargetsTheFocusedPanesImage`
   - 行为：`menuItemFallsBackToTheSidebarsImageOnAnEmptyTab`
   - 行为：`menuItemIsDisabledWithoutAnImage`
   - 行为：`sheetShowsEffectiveValuesAndMarksOverriddenOptions`
   - 行为：`changingAnOptionInTheSheetRecordsAnOverride`
   - 行为：`revertingAnOptionReturnsItToTheGlobalValue`
   - 行为：`revertAllRemovesTheImagesOverride`
   - 行为：`sheetFollowsGlobalChangesMadeInSettings`
   - 行为：`globalOptionsOpensTheSettingsPage`（含 Done 关闭 sheet）
   - 行为（编译核实）：三种工具栏样式都不再有 Generation Options 项
6. **CLI 与文档**（已完成） —— CLI 三行、文档两行、AGENTS 与术语表一行
   - 行为：`applicationOptionsReaderReadsGlobalFromSettingsFile`
   - 行为：`applicationOptionsReaderFallsBackToLegacyUserDefaults`
   - 行为：`settingsFileGlobalWinsOverLegacyUserDefaults`

- 构建与测试按项目规矩在 Ultra 上跑（本机是公司那台）：三个包的 `swift test` 各自过一遍，App 用 Tuist workspace 编一次（项目记忆规定的编译验证方式）。原生工程的 target、依赖与设置都不变（改名的两个文件在同步文件夹里），预计不用改 Tuist 描述；落地前跑一次 `./TuistScript.sh check` 确认。
- 界面目视（设置页、sheet、菜单标题）交给用户。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要单独的指南；解析规则写在 `Settings.GenerationOptionsSettings` 的文档注释里，根 `AGENTS.md` 第 7 条改成新 API。收尾时再确认。
- **有没有引入新术语** —— 「镜像覆盖（image override）」登记进 `Documentations/Glossary.md`，并更新「Find 语料」一条里「按内容区当前的选项投影」的说法（改为按每个镜像生效的选项）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-26 | Created as Draft | 把工具栏的 Generation Options 搬进设置，并支持按 engine + 镜像覆盖全局选项。 |
| 2026-11-26 | 覆盖粒度定为逐项 | 用户选择逐项覆盖：没动过的项继续跟随全局。整套覆盖记入替代方案。 |
| 2026-11-26 | 窗口入口定为 Editor 菜单开 sheet | 用户选择 Editor › Generation Options for “<镜像名>”… 打开 sheet；工具栏按钮删除；设置页列出全局与覆盖。 |
| 2026-11-26 | agent 自定的假设 | 存进 `settings.json` 并迁移旧键；engine 键沿用 Always Index 的；镜像路径用规范写法；Find 按镜像投影；C 名标签只改当前镜像；CLI 与 MCP 只用全局；iOS 设置加全局页。均在简报里列出，用户未反对前按此执行。 |
| 2026-11-26 | Accepted | 用户批准，开始实现。 |
| 2026-11-26 | In Progress | 在 `feature/generation-options-image-overrides` 上开始实现。 |
| 2026-11-26 | 迁移读取的 user defaults 可注入 | `SettingsAccess.init(store:legacyUserDefaults:)`，默认 `.standard`；主题迁移也改读它，测试因此不碰测试进程的标准 defaults。 |
| 2026-11-26 | 第 3 步：表的键在引擎里规范化 | 语料库本就按目录的规范路径存镜像，原先设想的「换成目录写法」不需要；改为照 `imagePaths` 的做法规范化，再按来源的路径查。 |
| 2026-11-26 | 第 3 步：加 `FindGenerationOptions` | 全局与本 engine 的表总是一起用（请求、`ShownSearch`、重跑判断、交叉引用根解析），合成一个值；设置变了先比本 engine 的值，别的 engine 的覆盖不再让屏上的搜索重跑。 |
| 2026-11-26 | 几条计划中的测试没写 | 规范化测试要 iOS 模拟器进程才有差别；借用 engine 的转发读代码核实（每个参与者拿原请求的副本，表原样带过去）；打开交叉引用成员只是把成员所在镜像的选项传进去。设置页注册、`AppRoute.settingsPage`、工具栏删项与 CLI host 的 `LiveApplicationOptionsReader` 都在没有测试目标的 App 层或私有类型里，以编译核实，界面交给用户目视。 |
| 2026-11-26 | sheet 的勾选框只在点击时发改动 | 原弹窗用 `rx.state`，绑定时的初值会发一次；放在 sheet 里，初值发出会把与默认值不同的全局选项记成覆盖。改用 `rx.click`，并取点击后的状态。 |
| 2026-11-26 | 实现完成，待用户看过后收尾 | 在 Ultra 上验证：Settings、Core（相关套件）、CommandLine 三个包的测试通过；Packages 的 AppCore、AppUI、Settings 整包跑的红都在已知清单里，不在清单里的 `FindSessionCorpusTests` 单独重跑 9 条全过（整包负载下超时）；macOS App（Tuist workspace）与 iOS App（模拟器）都编过。界面没有目视。 |
| 2026-11-26 | 文档判断 | 不另写使用指南或实现说明：解析规则写在 `Settings.GenerationOptionsSettings` 与 `Settings.GenerationOption` 的文档注释里，根 `AGENTS.md` 第 7 条改成新 API；新术语「镜像覆盖」已登记进术语表，「Find 语料」一条改为按每个镜像生效的选项投影；CLI 指南与插件 skill（升到 1.4.1）已同步。 |

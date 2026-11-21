# Draft - 长类型拆行：生成选项里加「Break Long Types」

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-21
- **所属愿景**: 无
- **关联提案**: MachOSwiftSection 的 [multiline-type-formatting](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/draft-multiline-type-formatting.md)（格式化本身由那边提供）
- **实现分支 / PR**: `feature/multiline-type-formatting`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

工具栏「生成选项」面板的 Swift 一栏加一个勾选框「Break Long Types」，默认关闭。打开后，Swift interface 里一行放不下的类型按括号结构拆成多行——SwiftUI 视图的 `typealias Body = SwiftUI.ModifiedContent<…>` 不再是一行几千个字符，而是一层一层缩进展开。格式化由 MachOSwiftSection 新增的 `MultilineTypeFormatting` 完成，在引擎生成 interface 时对每个定义的打印各做一次；语法着色、跳转链接、注释标签与宏展开照旧。查找（Find）同时改为能跨被拆开的行定位结果。行宽固定为 100 列（不计缩进），数值存进选项、暂不给界面。

## 动机

在 RuntimeViewer 里打开一个 SwiftUI 视图类型（例如 Preferences 里的 `SettingsApp.SettingsNavigationSplitView`），`extension … : SwiftUI.View` 里的 `typealias Body` 是一行几千个字符的嵌套泛型，编辑器软换行成几十行，看不出哪个参数属于哪一层。MachOSwiftSection 已经提供了按括号拆行的格式化（关联提案），RuntimeViewer 要把它接到界面上，用户才能在这里看到效果。

## 前期调研

全部路径相对于本仓库根目录，基于 `next`（`5e77b25e`）。

- **选项模型**：`RuntimeViewerCore/Sources/RuntimeViewerCore/Interfaces/SwiftGenerationOptions.swift:21-79`，MetaCodable 的 `@Codable @MemberInit struct SwiftGenerationOptions`，每个字段带 `@Default`。最近加的同类选项是 `expandsMacros`（`:70-76`，提案 0088），它的完整路线是本提案的模板：字段 → `SwiftDeclarationPrintConfiguration+GenerationOptions.swift:38` 的 `applySwitches(of:)` → `.mcp` 预设（`RuntimeObjectInterface+GenerationOptions.swift:76`）→ 面板勾选框（`GenerationOptionsViewController.swift:63`）→ `GenerationOptionsTests.swift:97-145`。选项存在 `AppDefaults.options`（UserDefaults 键 `generationOptions`，`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Storage/AppDefaults.swift:123`），旧数据靠 `@Default` 解码。
- **界面**：Swift 选项在工具栏弹出的 AppKit 面板 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Generation Options/GenerationOptionsViewController.swift`，勾选框写作 `.checkbox(title:keyPath:)`（`:63`），没有数字输入的控件。
- **选项怎么到引擎**：`ViewModel.currentMergedGenerationOptions`（`RuntimeViewerAppCore/Base/ViewModel.swift:52-62`）→ `RuntimeInterfaceCache` → `runtimeEngine.interface(for:options:)` → `InterfaceCommand`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Engine/RuntimeEngine+Commands.swift:166-195`，Codable，带着整份 `GenerationOptions`）。「My Mac」的引擎在 XPC service 里，Catalyst、附加进程、Bonjour 等远端引擎走各自的连接，所以新字段必须可编码、带默认值；旧版本的对端会忽略未知键，返回不格式化的文字。
- **引擎里的打印**：`RuntimeSwiftSection.interface(for:)`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/Swift/RuntimeSwiftSection.swift:448-489`）先 `printDefinitions` 得到每个定义的打印，`joinedDefinitionPrints` 拼起来（`:459`），再 `separatingMarks` 拆出注释结构与宏归属用的 region（`:460`）。`typeUTF8Range`（`:466-467`）按**第一个定义的打印**的长度算。宏展开的各块由 `printer.printMacroExpansionParts` 另印（`:647`）。ObjC 对象的「Generated Interface」在 `importedInterface(for:)`（`:544-556`）。
- **缓存**：引擎侧 `updateConfiguration(using:…)` 只在打印配置真的变了时清 `interfaceByObject` 与 `importedInterfaceByObject`（`RuntimeSwiftSection.swift:1892-1898`）；`MultilineTypeFormatting` 不是打印配置的一部分，所以要另存、另比、另清。App 侧 `RuntimeInterfaceCache` 按 `(object, GenerationOptions)` 做键（`RuntimeInterfaceCache.swift:55-61`），新字段自动生效。
- **查找怎么定位结果**：`ContentHighlightRequest.locate(in:)`（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentHighlightRequest.swift:64-110`）先找正文里与语料行**整行相同**（只去掉首尾空白，`:171-173`）的行，取离语料行号最近的；找不到才退回按查询词在全文匹配、取离行号最近的一处。语料（`RuntimeSwiftSection.swift:2195-2245`）总是用 `.mcp` 选项一次印好存盘，不随显示选项变——拆行打开后，被拆开的那行在正文里不再有整行相同的对应，查询词退回匹配时行号也因插入的行而偏移，可能落到另一处同名的地方。
- **其它读正文的地方**：`RuntimeMemberDeclarationLocator`（`Search/Matching/RuntimeMemberDeclarationLocator.swift:59-110`）按行找成员声明，成员声明仍从自己的第一行开始，拆开的只是类型；行号标尺（`ContentLineNumberRulerView.swift:130`）只是多出几行；导出（`Export/RuntimeEngine+Export.swift:38`）走同一个 `interface(for:options:)`，开着时导出的也是拆开的。
- **依赖**：`RuntimeViewerCore/Package.swift:143-152` 依赖 MachOSwiftSection 远端的 `next` 分支（`USING_LOCAL_DEPENDENCIES=1` 时用 `../../MachOSwiftSection`）。`MultilineTypeFormatting` 目前只在 MachOSwiftSection 本地的 `next` 上，没推送；本提案落地前要先推 MachOSwiftSection 的 `next`，再用 `./UpdatePackagesScript.sh` 抬各 `Package.resolved` 的 pin。开发期间用 `USING_LOCAL_DEPENDENCIES=1` 或 `RuntimeViewer-Local.xcworkspace`。
- **MachOSwiftSection 那边的保证**：`format(_:)` 只插入换行与缩进，semantic type、identifier 与 visibility / definition / annotation region 都不变；行宽不计缩进，嵌套定义从格式化过的父定义里取出，等于它单独打印再格式化（关联提案的保持性测试）。

## 提议方案

1. **选项**：`SwiftGenerationOptions` 加两个字段——`breaksLongTypes: Bool`（`@Default(false)`）与 `maximumLineWidth: Int`（`@Default(100)`），再加一个计算属性 `multilineTypeFormatting: MultilineTypeFormatting?`：关着时 `nil`，开着时按 `maximumLineWidth` 构造。`.mcp` 预设明确保持关闭：MCP 的使用者是 agent，按整行搜索声明，一个声明散到多行对它不利。
2. **引擎**：`RuntimeSwiftSection` 存下当前的 `MultilineTypeFormatting?`，在 `updateConfiguration(using:…)` 里和打印配置一起比较；变了就同样清掉两份 interface 缓存。`interface(for:)` 对 `printDefinitions` 得到的每个定义的打印各格式化一次再拼接——这样 `typeUTF8Range` 量的就是格式化后的第一个定义，宏展开的归属照旧对得上；宏展开的各块不格式化（它们带着嵌套属性的 UTF-8 范围，见决策日志）。`importedInterface(for:)` 在 `separatingMarks` 之前格式化。格式化始终发生在拆 region 之前，注释标签与宏归属读到的是格式化后的偏移。
3. **界面**：生成选项面板的 Swift 一栏在「Expand Macros」下面加勾选框「Break Long Types」。导出元数据（`RuntimeInterfaceExportMetadata`）写明这个选项的状态。
4. **查找**：`ContentHighlightRequest.locate(in:)` 第一步在「整行相同」（或长行的「窗口在某一行里」）找不到时，再在一份去掉全部空白的正文里找：整行的语料行要恰好对上从某行第一个可见字符到某行最后一个可见字符的一段，长行截出的窗口可以落在行中间。取离语料行号最近的一处，命中按「去空白后的第几个 UTF-16 单元」映射回正文。语料本身不变。

### 非目标

- **行宽不给界面**：数值存在选项里（默认 100），本次不加调节控件；以后要调再加，不动存储格式。
- **语料与 MCP、命令行不格式化**：语料是全部选项共用的一份，按行搜索；MCP 预设、`runtime-viewer-cli` 的 `full` / `default` 预设都保持关闭，CLI 与 agent 插件的行为不变。
- **不改 ObjC 头文件的显示**：格式化只作用于 Swift interface 与 ObjC 对象的「Generated Interface」（后者打印的也是 Swift）。
- **不补导出元数据里 `expandsMacros`、`printExportedDeclarationsOnly` 的缺口**：那是此前就有的遗漏，记为后续项，本次只写自己的这一行。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Interfaces/SwiftGenerationOptions.swift` · `SwiftGenerationOptions` | 修改 | 加 `breaksLongTypes`（`@Default(false)`）、`maximumLineWidth`（`@Default(100)`）与计算属性 `multilineTypeFormatting` | 选项随 `InterfaceCommand` 传到任何引擎；旧数据与旧对端照常解码 | 1 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Interfaces/RuntimeObjectInterface+GenerationOptions.swift` · `.mcp` | 修改 | 明确写 `breaksLongTypes: false` 并注明原因 | MCP 使用者按整行搜索 | 1 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/GenerationOptionsTests.swift` | 修改 | 默认关闭、旧 JSON 解码为关闭、`multilineTypeFormatting` 随两个字段变化、`.mcp` 关闭 | 照 `expandsMacros` 的测试写法 | 1 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/Swift/RuntimeSwiftSection.swift` · `RuntimeSwiftSection` | 修改 | 存 `multilineTypeFormatting`；`updateConfiguration(using:…)` 比较并清缓存；`interface(for:)` 逐个定义格式化后再拼；`interfaceParts(of:in:)` 格式化宏展开块；`importedInterface(for:)` 在拆 region 前格式化 | 格式化发生在引擎里、拆 region 之前 | 2 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/FileEngineTests.swift`（或同目录新文件 `MultilineTypeFormattingEngineTests.swift`） | 修改 / 新增 | 文件引擎对带长泛型的镜像打开选项后 interface 被拆开、关闭时与原来逐字节相同、切换选项后缓存失效、宏展开归属仍对 | 端到端验证引擎侧 | 2 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Generation Options/GenerationOptionsViewController.swift` | 修改 | 加 `.checkbox(title: "Break Long Types", keyPath: \.swiftInterfaceOptions.breaksLongTypes)` | 用户入口 | 3 |
| `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportMetadata.swift` | 修改 | 导出元数据加一行写明这个选项 | 导出的文字受它影响 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Content/ContentHighlightRequest.swift` · `ContentHighlightRequest` | 修改 | `locate(in:)` 第一步加「跨行相同」的比较与命中位置映射 | 拆行后查找仍定位到对的地方 | 4 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/ContentHighlightRequestTests.swift` | 修改 | 跨行定位的用例：拆开的类型、命中在拆开那段中间、两处同名时取最近、整行相同的旧行为不变 | 查找的回归保护 | 4 |
| `Package.resolved`（`RuntimeViewerCore`、`RuntimeViewerPackages`、各 workspace、`Tuist/`） | 修改 | MachOSwiftSection 推送 `next` 后用 `./UpdatePackagesScript.sh` 抬 pin | 远端构建要拿到 `MultilineTypeFormatting` | 5 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案 | 文档索引 | 1、6 |

## 架构图

改了什么：

```text
RuntimeViewerCore
~ Interfaces/SwiftGenerationOptions.swift          + breaksLongTypes, maximumLineWidth, multilineTypeFormatting
~ Interfaces/RuntimeObjectInterface+GenerationOptions.swift   .mcp keeps it off
~ Sections/Swift/RuntimeSwiftSection.swift         + stored formatting; format each definition print
~ Export/RuntimeInterfaceExportMetadata.swift      + one row
RuntimeViewerPackages/RuntimeViewerAppCore
~ Content/ContentHighlightRequest.swift            + cross-line match
RuntimeViewerUsingAppKit
~ Generation Options/GenerationOptionsViewController.swift   + "Break Long Types" checkbox
MachOSwiftSection (dependency, next)
  SwiftDeclarationRendering.MultilineTypeFormatting
```

数据流：

```text
GenerationOptionsViewController ──► AppDefaults.options
        │ currentMergedGenerationOptions
        ▼
RuntimeInterfaceCache (key: object + options) ──► InterfaceCommand (Codable, XPC / remote)
        ▼
RuntimeSwiftSection.interface(for:options:)
  updateConfiguration ── formatting changed? ──► clear interfaceByObject / importedInterfaceByObject
  printDefinitions ──► + format(each print) ──► join ──► separatingMarks ──► RuntimeObjectInterface
                                                   macro expansion parts ──► + format
        ▼
content pane  ◄── ContentHighlightRequest.locate  (+ cross-line match against the unformatted corpus line)
```

## 详细设计

### 选项

```swift
@Codable
@MemberInit
public struct SwiftGenerationOptions: Equatable, Hashable, Sendable {
    // …
    /// Breaks a type that runs past `maximumLineWidth` over several lines, at
    /// its brackets (MachOSwiftSection's `MultilineTypeFormatting`). Off by default.
    @Default(false)
    public var breaksLongTypes: Bool

    /// The widest a line may be, not counting its indentation, before
    /// `breaksLongTypes` breaks its types. No control in the panel yet.
    @Default(100)
    public var maximumLineWidth: Int
}

extension SwiftGenerationOptions {
    /// The formatting these options ask for; `nil` while `breaksLongTypes` is off.
    public var multilineTypeFormatting: MultilineTypeFormatting? {
        guard breaksLongTypes else { return nil }
        return MultilineTypeFormatting(maximumLineWidth: max(1, maximumLineWidth))
    }
}
```

`max(1, …)` 兜住手改偏好或旧对端传来的非法值，不让引擎 trap。

### 引擎

```swift
// RuntimeSwiftSection
private var multilineTypeFormatting: MultilineTypeFormatting?

// updateConfiguration(using:…), beside the print configuration comparison
let newMultilineTypeFormatting = options.swiftInterfaceOptions.multilineTypeFormatting
if newPrintConfiguration != oldPrintConfiguration || newMultilineTypeFormatting != multilineTypeFormatting {
    // … existing printer update only when the print configuration changed …
    multilineTypeFormatting = newMultilineTypeFormatting
    interfaceByObject.removeAll()
    importedInterfaceByObject.removeAll()
}

// interface(for:)
let definitionPrints = try await Self.printDefinitions(definitions, using: printer).map(formatted)
let newInterfaceString = Self.joinedDefinitionPrints(definitionPrints)

private func formatted(_ print: SemanticString) -> SemanticString {
    multilineTypeFormatting?.format(print) ?? print
}
```

拼接只在定义之间插入空行，逐个格式化与整份格式化结果相同；逐个做是为了让 `typeUTF8Range` 直接取格式化后的第一个定义。`printer.updateConfiguration` 仍只在打印配置变化时调用——只切换拆行不重建打印器，保住文件引擎的静态布局计算器（`:1887-1891` 的注释说明了那次代价）。

### 查找的跨行定位

`locate(in:)` 第一步改为：

1. 照旧找整行相同（去首尾空白）的行，或含有长行窗口的行，取离语料行号最近的。
2. 找不到时，把正文与语料行（或窗口）都去掉全部空白，得到两串 UTF-16 单元，正文那串记下每个单元在原文里的偏移（`CompactedText`）。在正文那串里找语料那串的每次出现：整行的语料行只认从某行第一个可见单元开始、到某行最后一个可见单元结束的一段；窗口可以落在行中间。取起点所在行离语料行号最近的一处。
3. 命中在语料行（或窗口）里的位置换算成「去空白后的第几个单元」，在那一处数到同一个单元，得到正文里的范围；命中跨了插入的换行时，范围从起点算到终点（包含中间的换行与缩进）。整行的情况没有命中范围时，先在那一段里按查询词找，再退回选中整段。

只有拆行会让一条语料行散到多行，所以这一步只在第一步落空时才走，关着拆行时行为逐字不变。

## 替代方案考量

- **把格式化放进 App 侧（拿到文字后再拆）**：否。App 拿到的是已经拆掉 region 的纯文字加偏移表，再插换行就要重算注释标签与宏展开的全部偏移；引擎里在拆 region 之前格式化，MachOSwiftSection 已经保证 region 跟着走。
- **把格式化做成 `SwiftDeclarationPrintConfiguration` 的一部分**：否。MachOSwiftSection 有意不放进打印配置（关联提案的替代方案）；本仓库也因此要另存、另比、另清缓存。
- **语料也格式化**：否。语料对所有选项共用一份、按行搜索，跟着显示选项变会让索引随选项失效。
- **查找不改、接受退化**：用户否掉了，选了跨行定位。
- **面板里加行宽控件 / 设置页里调宽度**：用户选了只加勾选框，数值先存着。

## 影响

### 用户可见变化

- 生成选项面板的 Swift 一栏多一个勾选框「Break Long Types」，默认不勾，界面与输出都和原来一样。
- 勾上后，Swift interface（以及 ObjC 对象的 Generated Interface）里放不下的类型按括号拆成多行；行号变多；导出的文字同样拆开。
- 查找结果在拆开的类型上仍定位到那一段。

### 可发现性

勾选框放在「Expand Macros」旁边，与其它改变 interface 外观的选项在一起。默认关闭：已有用户的显示不应在升级后突然改变，且 MCP、导出的下游可能按行处理文字。

### 数据与配置兼容

两个新字段带 `@Default`，旧的 `generationOptions` 偏好照常解码为关闭；旧版本的远端引擎收到带新键的命令会忽略它们，返回不拆的文字（不报错）。不需要迁移。

### 平台与最低版本

不变。iOS 版若显示同一份 interface，选项可用但本次只在 macOS 的面板里给入口。

### 发布

不需要新的权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。落地依赖 MachOSwiftSection 的 `next` 先推送、本仓库抬 pin。

## 落地步骤

1. **选项字段与预设**（已完成） —— 改动地图第 1、2、3、11 行
   - 行为：`defaultOptionsLeaveLongTypesOnOneLine`
   - 行为：`optionsSavedBeforeBreakLongTypesExistedDecodeWithItOff`
   - 行为：`breakLongTypesDerivesTheFormattingWithTheStoredWidth`
   - 行为：`theMCPOptionsLeaveLongTypesOnOneLine`
2. **引擎格式化与缓存失效**（已完成） —— 改动地图第 4、5 行
   - 行为：`interfaceBreaksLongTypesWhenAsked`
   - 行为：`interfaceWithBreakLongTypesOffIsUnchanged`
   - 行为：`togglingBreakLongTypesRegeneratesTheCachedInterface`
   - 行为：`macroExpansionsStillAttachToTheirTypeWhenFormatted`
   - 行为：`togglingBreakLongTypesKeepsThePrinter`（打印器不重建）
3. **面板与导出元数据**（已完成；面板一行未经 App 构建验证，见决策日志） —— 改动地图第 6、7 行
   - 行为：面板 Swift 一栏出现「Break Long Types」，勾上后内容区刷新为拆开的文字（无测试目标，人工核对）
   - 行为：`exportMetadataDescribesBreakLongTypes`
4. **查找跨行定位**（已完成） —— 改动地图第 8、9 行
   - 行为：`aCorpusLineBrokenAcrossDisplayedLinesIsLocated`
   - 行为：`aHitAcrossAnInsertedBreakCoversTheBreak`
   - 行为：`theNearestBrokenOccurrenceWins`
   - 行为：`aWindowOfABrokenLongLineIsLocated`
   - 行为：`aWholeLineMatchStillWinsFirst`、`aRunInsideALongerLineIsNotTakenForTheCorpusLine`（旧行为不变）
5. **抬依赖 pin**（已完成：MachOSwiftSection `25c4515c`） —— 改动地图第 10 行
   - 行为：不带本地依赖的构建通过
6. **文档** —— 改动地图第 11 行
   - 行为：索引与提案状态一致

验证：每步构建通过、本步测试通过；`RuntimeViewerCore` 与 `RuntimeViewerPackages` 的定向套件（`GenerationOptionsTests`、新的引擎测试、`RuntimeInterfaceCorpusVisibilityTests`、`ContentHighlightRequestTests`）。`RuntimeInterfaceCorpusVisibilityTests` 若按选项自动枚举，要确认新选项不在「语料投影等于正文」的比较里，或写明排除原因。界面在 Xcode 里运行后人工看一次。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不要：选项只有一个勾选框，规则在 MachOSwiftSection 的提案里。
- **有没有引入新术语** —— 本仓库没有新术语（long type 已登记在 MachOSwiftSection 的术语表）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-21 | Created as Draft | MachOSwiftSection 新增了按括号拆长类型的格式化，RuntimeViewer 要把它接到界面上，SwiftUI 视图的 `Body` 才能在这里看清层级。 |
| 2026-11-21 | 只加勾选框，查找跨行定位 | 澄清提问后用户选定：面板里只加一个勾选框，行宽固定 100 列、数值存进选项；查找改为能跨被拆开的行定位，不接受退化。 |
| 2026-11-21 | Accepted | 用户批准，开始实现。功能分支 `feature/multiline-type-formatting`，从 `next` 切出；先用本地依赖开发，MachOSwiftSection 推送 `next` 后再抬 pin。机器负载高时构建用低优先级跑。 |
| 2026-11-21 | 宏展开块不格式化 | 方案原写在 `interfaceParts(of:in:)` 里格式化宏展开的每一块。实现时发现每一块带着嵌套宏属性相对自身文字的 UTF-8 范围（`MacroExpansionPart.NestedExpansion.attributeUTF8Range`），插入换行会让它们指错位置；展开出来的又都是很短的成员声明。改为不格式化，正文照常格式化、宏归属不受影响。 |
| 2026-11-21 | 查找的跨行定位也覆盖「窗口」 | 方案只写了整行对不上时的跨行比对。实现时发现引擎会把超过 320 个 UTF-16 单元的语料行截成一段带 `…` 的窗口交给查找——SwiftUI 的 `Body` 正是这种——走的是另一条分支。两条分支统一改用一份「去掉空白的正文」：整行的情况要求比对上的一段恰好从某行第一个可见字符开始、到某行最后一个可见字符结束；窗口的情况允许落在行中间。命中位置都按「去空白后的第几个 UTF-16 单元」映射回正文。 |
| 2026-11-21 | 查找测试先在旧代码上变红 | 新测试不带查询词，免得旧的「按查询词就近匹配」碰巧找到同一处；换回改动前的 `ContentHighlightRequest` 跑过一次，四条新测试（拆开的整行、跨插入换行的命中、多处取最近、拆开的长行窗口）都失败，两条旧行为保护通过；换回新代码后全部通过。 |
| 2026-11-21 | 实现完成，待用户看过后收尾 | 第 1–4 步完成，在 JHs-Mac-Studio-Ultra 上用本地依赖（`USING_LOCAL_DEPENDENCIES=1`，MachOSwiftSection 本地 `next` 已含 `MultilineTypeFormatting`）以低优先级构建：`RuntimeViewerCore` 定向 42 个测试（含 `RuntimeInterfaceCorpusVisibilityTests`，它不按选项自动枚举，新选项不影响它）、`RuntimeViewerPackages` 的 `ContentHighlightRequestTests` 与 `ContentTextHighlightTests` 20 个测试全过。面板那一行（`GenerationOptionsViewController`）在 App target 里，没有单独的测试目标，机器负载高、没做 App 构建，也没在界面上人工看过。第 5 步（MachOSwiftSection 推送 `next` 后抬 pin）与第 6 步（落地时补齐本分支的索引行）留到收尾。文档判断：不另写说明或指南，没有新术语；CLI 与 agent 插件不变。 |

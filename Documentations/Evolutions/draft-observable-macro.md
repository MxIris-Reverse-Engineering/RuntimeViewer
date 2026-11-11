# Draft - 识别 @Observable 宏：默认折叠，可在原地展开

- **状态**: Accepted
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **实现分支**: `feature/observable-macro`
- **依赖**: MachOSwiftSection 的提案 `draft-observable-macro-folding`（分支 `feature/observable-macro`，未发布）

## 摘要

用 `@Observable` 写的类，编译后带着宏生成的一批成员：`_$observationRegistrar`，每个属性的 `_x` 存储和计算属性 `x`，`access(keyPath:)`、`withMutation(keyPath:_:)`、几个 `shouldNotifyObservers`，以及 `extension X: Observation.Observable {}`。RV 现在把它们原样列出，读起来和源码对不上。MachOSwiftSection 正在加识别：类上打印 `@Observation.Observable`，被跟踪的属性打印成普通的 `var x: T`，生成的成员折叠掉。这份提案把它接进 RV：默认折叠，Generation Options 里可以切回展开；内容区用 SourceEditor 显示时，在 `@Observation.Observable` 上右键选 Expand Macro，生成的声明像 Xcode 的展开宏那样插在这一行下方。插入用的是 SourceEditor 自带的 Gap，和 SourceEditor 示例 App 的行内展开是同一套。

## 方案

- **依赖 MachOSwiftSection**：
  - 已获对方用户批准：识别 `@Observable`、折叠打印、打印配置的 `expandsMacros`（默认 false，即折叠），以及 Find 语料用的可见性选项 `swift.expandsMacros`。
  - 正在请示对方用户：单独打印一个宏的展开块（`printExpansion(of:for:)` 之类），以及用一种新的 annotation region 标出 `@Observation.Observable` 在接口文本里的位置。原地展开靠这两项。
  - 开发期间用本地依赖（`RuntimeViewer-Local.xcworkspace`、Tuist 的本地依赖模式）。合进 `next` 要等 swift-demangling 与 MachOSwiftSection 依次发版，再抬 RuntimeViewerCore 里的版本下限。
- **生成选项**：`SwiftGenerationOptions` 加 `expandsMacros`（`@Default(false)`，旧设置读成折叠），`applySwitches(of:)` 把它交给打印配置；Generation Options 的 Swift 一栏加 Expand Macros 勾选框。Find 语料走同一个映射，搜索结果与内容区显示的形态一致。
- **接口模型**：`RuntimeObjectInterface` 带上宏展开，每个识别出的宏一项：宏名、属性在接口文本里的范围、展开块的语义文本。RuntimeSwiftSection 在折叠打印接口时一起算出；属性范围从 annotation region 读，读法与现有的注释结构相同。展开打印时不带。
- **内容区**：`ContentSourceEditorViewController` 的右键菜单在属性上加 Expand Macro，展开后换成 Hide Macro Expansion。bridge 新增显示、收起行内展开的接口，`SourceEditorBridging` 里仍不出现 SourceEditor 的类型。实现照 SourceEditor 示例的 `InlineDefinitionView`（即 Xcode 的 `GapEmbeddedEditorContentView`）：只读的内嵌编辑器，主题和语义着色与内容区相同，首行行号让给关闭按钮。换显示的接口之前先收起所有展开。用 `NSTextView` 显示时不提供原地展开，只能靠生成选项切换。
- **侧栏**：先不标出 `@Observable` 类型。被折叠掉的 `extension X: Observation.Observable` 如果作为 conformance 条目出现在侧栏，折叠时一并不列，等接口定下来再核对。
- **命令行与 MCP**：`default` 与 `app` 照各自的选项（默认折叠）；`full`（也就是 MCP 用的 `.mcp` 预设）展开。agent 插件的 skill 跟着写明，并抬版本号。
- **测试**：Core 的选项映射与宏展开字段；bridge 测试里展开、收起 Gap；内容区右键菜单项的状态。
- **文档**：命令行指南与 agent 插件；落地时提案取号。
- **没有询问就采用的假设**：
  - 展开块里各声明怎么打印由 MachOSwiftSection 定，RV 不自己从区域里拼；
  - `full` 预设的定义是「什么都显示」，所以展开；
  - 原地展开只在 SourceEditor 显示时提供。

## 落地步骤

1. 生成选项、打印配置映射、命令行预设（MachOSwiftSection 的识别与 `expandsMacros` 到位即可做）。
2. 接口模型带上宏展开（等 MachOSwiftSection 的展开块与属性位置）。
3. bridge 的行内展开与内容区的右键菜单。
4. 测试与文档补齐；两个库发版后抬版本下限，再合进 `next`。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created as Draft | 用户要求在 MachOSwiftSection 加入 `@Observable` 识别，并接进 RV |
| 2026-11-11 | 默认折叠，Generation Options 可以切回展开 | 用户选定；与 MachOSwiftSection 的默认值一致 |
| 2026-11-11 | 侧栏先不标出 `@Observable` 类型 | 用户选定 |
| 2026-11-11 | 这次一起做 Xcode 式的原地展开 | 用户选定；SourceEditor 的 Gap 与 Xcode 的做法已查清，示例 App 已经实现过一遍 |
| 2026-11-11 | 展开块由 MachOSwiftSection 打印，RV 不从区域里拼 | 对方会话的建议：展开块里的注释与转换器要和接口其余部分一致，只有打印器自己做得到 |
| 2026-11-11 | 用户批准，开始实现 | 在功能分支 `feature/observable-macro` 上做；提案在本地 `next` 提交、不推送，因为 `next` 上还有一个按用户要求不推送的文档提交 |
| 2026-11-11 | 先做 bridge 的行内展开（落地步骤 3 的 bridge 部分），步骤 1 的代码写好后等 MachOSwiftSection 的 `expandsMacros` 推上来再编 | bridge 不依赖 MachOSwiftSection，可以先验证；步骤 1 引用的打印配置成员对方还没推 |
| 2026-11-11 | 行内展开里不接 ⌘ 点和右键菜单，也不画注释标签 | 内容区的导航与注释装饰都按主编辑器的文本范围工作，展开是另一段文本；先做显示，有需要再加 |
| 2026-11-11 | bridge 的展开视图照 SourceEditor 示例的 `InlineDefinitionView` 移植 | 两边都照 Xcode 26.6 的 `GapEmbeddedEditorContentView` 逆向而来，公式与地址在 `/Volumes/RE/Xcode/26.6/README.md` |
| 2026-11-11 | 展开的数据源不在末尾补换行（`lineEndingAtEndOfFileBehavior = .optional`） | 默认的 `.mandatory` 会在文本末尾补一个换行，展开因此多出一行空行；新测试比对展开文本时抓到。框架自己的内嵌编辑器和跳转预览都这样设，SourceEditor 示例同批改正 |

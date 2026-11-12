# Draft - 识别 @Observable 宏：默认折叠，可在原地展开

- **状态**: In Progress
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **实现分支**: `feature/observable-macro`
- **依赖**: MachOSwiftSection 的提案 `draft-observable-macro-folding`（分支 `feature/observable-macro`，未发布）

## 摘要

用 `@Observable` 写的类，编译后带着宏生成的一批成员：`_$observationRegistrar`，每个属性的 `_x` 存储和计算属性 `x`，`access(keyPath:)`、`withMutation(keyPath:_:)`、几个 `shouldNotifyObservers`，以及 `extension X: Observation.Observable {}`。RV 现在把它们原样列出，读起来和源码对不上。MachOSwiftSection 正在加识别：类上打印 `@Observation.Observable`，被跟踪的属性打印成普通的 `var x: T`，生成的成员折叠掉。这份提案把它接进 RV：默认折叠，Generation Options 里可以切回展开；内容区用 SourceEditor 显示时，在 `@Observation.Observable` 上右键选 Expand Macro，生成的声明像 Xcode 的展开宏那样插在这一行下方。插入用的是 SourceEditor 自带的 Gap，和 SourceEditor 示例 App 的行内展开是同一套。

## 方案

- **依赖 MachOSwiftSection**：
  - 已获对方用户批准：识别 `@Observable`、折叠打印、打印配置的 `expandsMacros`（默认 false，即折叠），以及 Find 语料用的可见性选项 `swift.expandsMacros`。
  - 同样已获批准、已推到对方的 `feature/observable-macro`：打印配置的 `marksAttachedMacros` 给折叠形态里的每个宏属性包一个 `attachedMacro.<模块>.<宏>` 类的 annotation region；`printMacroExpansion(of:attachedTo:level:)` 单独打印一个类型的展开块。原地展开靠这两项。
  - 开发期间：包级构建用 SwiftPM 的 edit 模式，把 MachOSwiftSection 换成对方的功能分支、swift-demangling 换成它的 `next`（对方的 `next` 已经用到 swift-demangling 未发版的接口）；App 构建用一个临时 workspace 加上这两个本地包。换掉这两个之后，其余依赖仍按 RV 现有锁文件解析，没有一条被改动。
  - 合进 RV 的 `next`：RuntimeViewerCore 按 `branch: "next"` 依赖 MachOSwiftSection 和 swift-demangling，所以先要 MachOSwiftSection 把这批改动合进它的 `next`，再把 RV 锁文件里这两个库的 pin 一起抬到各自 `next` 上的对应提交（swift-demangling 至少到 8809c1b）。MachOSwiftSection 自己的远程构建要等 swift-demangling 发版、它抬了下限才通过；RV 是等到那时再抬，还是先抬，落地时再定。
- **生成选项**：`SwiftGenerationOptions` 加 `expandsMacros`（`@Default(false)`，旧设置读成折叠），`applySwitches(of:)` 把它交给打印配置；Generation Options 的 Swift 一栏加 Expand Macros 勾选框。Find 语料走同一个映射，搜索结果与内容区显示的形态一致。
- **接口模型**：`RuntimeObjectInterface` 带上宏展开（`macroExpansions`，元素是 `RuntimeInterfaceMacroExpansion`），每个识别出的宏一项：宏名、属性在接口文本里的 UTF-8 范围、展开块的语义文本。请求带上 `GenerationOptions.marksAttachedMacros` 时，RuntimeSwiftSection 在折叠打印接口时一起算出；属性范围从 annotation region 读，读法与现有的注释结构相同，注释结构跳过这类区域。展开打印时没有属性，也就没有展开。进程间传输走已有的列式编码，旧版本的对端不认这个键、也不会请求它。
- **内容区**：`ContentSourceEditorViewController` 的右键菜单在属性上加 Expand Macro，展开后换成 Hide Macro Expansion。bridge 新增显示、收起行内展开的接口，`SourceEditorBridging` 里仍不出现 SourceEditor 的类型。实现照 SourceEditor 示例的 `InlineDefinitionView`（即 Xcode 的 `GapEmbeddedEditorContentView`）：只读的内嵌编辑器，主题和语义着色与内容区相同，首行行号让给关闭按钮。换显示的接口之前先收起所有展开。用 `NSTextView` 显示时不提供原地展开，只能靠生成选项切换。
- **侧栏**：先不标出 `@Observable` 类型。宏生成的 `extension X: Observation.Observable` 跟着类型本身打印、不是侧栏里的独立条目，折叠时 MachOSwiftSection 把它和其余生成的成员一起略去，侧栏无需改动。
- **命令行与 MCP**：`default` 与 `app` 照各自的选项（默认折叠）；`full`（也就是 MCP 用的 `.mcp` 预设）展开。agent 插件的 skill 跟着写明，并抬版本号。
- **测试**：Core 的选项映射与旧设置的解码；测试包里的 `@Observable` 夹具（含一个嵌套的）经引擎打印，核对属性范围、展开归属、缩进、有无标记文本不变、注释结构不变、展开形态无可展开；注释结构跳过宏区域；JSON 与 XPC 两条传输路径都带上宏展开；内容区把 UTF-8 范围换成屏幕文本的 UTF-16 范围、提示语替换文本时丢掉展开；bridge 测试里展开、收起 Gap。右键菜单项本身在 App target 里，没有测试 target，靠构建与手工验证。
- **文档**：命令行指南与 agent 插件；落地时提案取号。
- **没有询问就采用的假设**：
  - 展开块里各声明怎么打印由 MachOSwiftSection 定，RV 不自己从区域里拼；
  - `full` 预设的定义是「什么都显示」，所以展开；
  - 原地展开只在 SourceEditor 显示时提供。

## 落地步骤

1. ✅ 生成选项、打印配置映射、命令行预设（MachOSwiftSection 的识别与 `expandsMacros` 到位即可做）。
2. ✅ 接口模型带上宏展开（等 MachOSwiftSection 的展开块与属性位置）。
3. ✅ bridge 的行内展开与内容区的右键菜单。
4. 测试与文档已补齐；剩下的等上游：MachOSwiftSection 把这批改动合进它的 `next` 之后，抬 RV 锁文件里 MachOSwiftSection 与 swift-demangling 的 pin，再合进 RV 的 `next`（见上文「合进 RV 的 `next`」）。

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
| 2026-11-11 | MachOSwiftSection 定下的接口：`marksAttachedMacros` 给每个宏属性包一个 `attachedMacro.<宏>` 类的 annotation region，`printMacroExpansion(of:attachedTo:level:)` 打印展开块 | 对方用户批准；`printTypeDefinition` 会把嵌套类型一起打出来，一个接口里可能有多个宏属性 |
| 2026-11-11 | 宏属性属于哪个类型：请求宏标记时显示打印器同时打开 `marksNestedDefinitions`，属性落在最内层的定义区域里就属于那个类型，不在任何定义区域里就属于打印的对象本身。区域的标识是类型的 mangled name，按它在本次打印的类型定义树（含扩展里的嵌套类型）里找类型，不靠侧栏对象的子节点 | 对方会话的建议；用的是 Find 语料已经在读的嵌套定义区域，不必在 RV 一侧重演打印顺序。调用方传来的对象可能没带子节点（例如跟随链接时），靠子节点会把嵌套类型的属性错配成外层类型的展开 |
| 2026-11-11 | 同一个类型名下出现第二个同种宏属性时不给展开 | 说明某个嵌套类型打印时没带定义区域（名字无法重新 mangle），它的展开认不出来；少一个展开好过给错 |
| 2026-11-11 | 宏展开随接口一起下发（`RuntimeObjectInterface.macroExpansions`），不新增引擎命令 | 打印接口时类型定义就在手边，展开块几行字；省一次往返，也不必为新命令声明共享缓存的路由 |
| 2026-11-11 | 宏标记只在 SourceEditor 可用时打开；接口前面换成提示语时不带宏展开 | `NSTextView` 显示不了 Gap；提示语会让属性的偏移错位，与注释结构的处理一致 |
| 2026-11-11 | 同一段文本因主题或字号变化重新显示时，已展开的宏重新展开 | bridge 每次换文本都会收起所有展开，不这样做的话一改字号展开就全没了 |
| 2026-11-11 | 注释结构跳过 `attachedMacro.` 类的区域并重新编号 | 宏区域与注释在同一张表里，不跳过的话 `@Observation.Observable` 会被画成注释标签 |
| 2026-11-11 | RV 一侧实现完成，对着 MachOSwiftSection 功能分支的 a792aed8 验证通过；暂不合进本地 `next` | 本地 `next` 锁文件里的 MachOSwiftSection 没有这些接口，合进去 `next` 就编不过。等对方把识别合进它的 `next`，抬 pin 后再落地 |
| 2026-11-12 | SourceEditor 的 pin 抬到 `27.2.0-alpha.1`，行内展开的关闭按钮才点得动 | 用 macOS 27 SDK 编的 App 里，主编辑器的行号栏盖住按钮，普通 `NSButton` 不接 AppKit 转来的点击。用户定重建版 26.6 线不改，SourceEditor 新开 `xcode-27` 线照 Xcode 27.2 修好，见 `Documentations/ResolvedIssues/2026-11-11-inline-expansion-dismiss-button-ignores-clicks.md` |

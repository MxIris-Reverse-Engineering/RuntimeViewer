# 0088 - 识别 @Observable 宏：默认折叠，可在原地展开

- **状态**: Implemented
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-12
- **实现分支**: `feature/observable-macro`（已合进 `next`）
- **依赖**: MachOSwiftSection 的提案 0093-observable-macro-folding 与 0095-observable-nested-expansion（都已合进它的 `next`，未发布）

## 摘要

用 `@Observable` 写的类，编译后带着宏生成的一批成员：`_$observationRegistrar`，每个属性的 `_x` 存储和计算属性 `x`，`access(keyPath:)`、`withMutation(keyPath:_:)`、几个 `shouldNotifyObservers`，以及 `extension X: Observation.Observable {}`。RV 现在把它们原样列出，读起来和源码对不上。MachOSwiftSection 正在加识别：类上打印 `@Observation.Observable`，被跟踪的属性打印成普通的 `var x: T`，生成的成员折叠掉。这份提案把它接进 RV：默认折叠，Generation Options 里可以切回展开；内容区用 SourceEditor 显示时，在 `@Observation.Observable` 上右键选 Expand Macro，宏写的东西像 Xcode 的展开宏那样插在类型里。展开分两层，与宏本身一致：`@Observable` 只给每个被跟踪的属性加上 `@ObservationTracked`，再展开这个属性才看到它的访问器块和存储属性。插入用的是 SourceEditor 自带的 Gap，和 SourceEditor 示例 App 的行内展开是同一套。

## 方案

- **依赖 MachOSwiftSection**：
  - 已获对方用户批准：识别 `@Observable`、折叠打印、打印配置的 `expandsMacros`（默认 false，即折叠），以及 Find 语料用的可见性选项 `swift.expandsMacros`。
  - 同样已获批准、已推到对方的 `feature/observable-macro`：打印配置的 `marksAttachedMacros` 给折叠形态里的每个宏属性包一个 `attachedMacro.<模块>.<宏>` 类的 annotation region；`printMacroExpansion(of:attachedTo:level:)` 单独打印一个类型的展开块。原地展开靠这两项。
  - 开发期间：包级构建用 SwiftPM 的 edit 模式，把 MachOSwiftSection 换成对方的功能分支、swift-demangling 换成它的 `next`（对方的 `next` 已经用到 swift-demangling 未发版的接口）；App 构建用一个临时 workspace 加上这两个本地包。换掉这两个之后，其余依赖仍按 RV 现有锁文件解析，没有一条被改动。
  - 合进 RV 的 `next`：RuntimeViewerCore 按 `branch: "next"` 依赖 MachOSwiftSection 和 swift-demangling，所以先要 MachOSwiftSection 把这批改动合进它的 `next`，再把 RV 锁文件里这两个库的 pin 一起抬到各自 `next` 上的对应提交（swift-demangling 至少到 8809c1b）。落地时五份锁文件（Debug 与 Distribution 两个 workspace、Core、Packages、CommandLine）钉在 MachOSwiftSection `next` 的 1ba927ad（含 0093、0094 与 0095）与 swift-demangling `next` 的 8809c1b。
  - 两层展开的接口（MachOSwiftSection 的 0095-observable-nested-expansion）：`@Observable` 每个被跟踪属性那段只是它加的 `@ObservationTracked`；这段文字里标出属性的位置，并带上它展开后的几段（访问器块与存储属性），这几段锚在正文里那个属性的声明上。
- **生成选项**：`SwiftGenerationOptions` 加 `expandsMacros`（`@Default(false)`，旧设置读成折叠），`applySwitches(of:)` 把它交给打印配置；Generation Options 的 Swift 一栏加 Expand Macros 勾选框。Find 语料走同一个映射，搜索结果与内容区显示的形态一致。
- **接口模型**：`RuntimeObjectInterface` 带上宏展开（`macroExpansions`，元素是 `RuntimeInterfaceMacroExpansion`），每个识别出的宏一项：宏名、属性在接口文本里的 UTF-8 范围，以及展开的各段——每段带锚点（被跟踪属性的声明，或类型 `}` 所在的行）、放在锚点行的上方还是下方、不带缩进的语义文本。各段由 MachOSwiftSection 的 `printMacroExpansionParts(of:attachedTo:)` 打印；RV 只负责放：属性那段按区域类型找到它的声明，`}` 取嵌套类型定义区域的最后一行，或 RV 分开打印各个定义时记下的类型自身范围的最后一行。请求带上 `GenerationOptions.marksAttachedMacros` 时，RuntimeSwiftSection 在折叠打印接口时一起算出；属性范围从 annotation region 读，读法与现有的注释结构相同，注释结构跳过这类区域。展开打印时没有属性，也就没有展开。每段还可以带「段内再展开」（`Part.nestedExpansions`，元素同样是 `RuntimeInterfaceMacroExpansion`）：段里的文字本身挂着宏时，属性范围是在这段文字里的 UTF-8 范围，它那几段照常锚在接口文本里。进程间传输走已有的列式编码，旧版本的对端不认这个键、也不会请求它。
- **内容区**：`ContentSourceEditorViewController` 的右键菜单在属性上加 Expand Macro，展开后换成 Hide Macro Expansion。展开照 Xcode 放 attached macro 的位置分成几段，放进类型里，分两层：展开 `@Observable`，每个被跟踪的属性上方是它加的 `@ObservationTracked`，类的 `}` 上方是 registrar 与生成的方法，`}` 下方是一致性扩展；在展开段里的 `@ObservationTracked` 上右键再选 Expand Macro，属性下方出现它的访问器块（`{`、`get`、`set`、`}`）与存储属性 `_x`。写了 `@ObservationIgnored` 的属性没有 `@ObservationTracked`，也就没有第二层，和宏本身一样。已有的行不变，属性那一行不改写成计算属性。几段是同一个展开，收起或点任意一段的关闭按钮都一起关；收起外层也收起从它里面展开的第二层，单独收起第二层不影响外层。bridge 的接口是一次传入多段（`SourceEditorBridgingInlineExpansionPart`：文字、锚点范围、放在行上方还是下方），`SourceEditorBridging` 里仍不出现 SourceEditor 的类型。实现照 SourceEditor 示例的 `InlineDefinitionView`（即 Xcode 的 `GapEmbeddedEditorContentView`）：只读的内嵌编辑器，主题和语义着色与内容区相同，首行行号让给关闭按钮。换显示的接口之前先收起所有展开。用 `NSTextView` 显示时不提供原地展开，只能靠生成选项切换。
- **侧栏**：先不标出 `@Observable` 类型。宏生成的 `extension X: Observation.Observable` 跟着类型本身打印、不是侧栏里的独立条目，折叠时 MachOSwiftSection 把它和其余生成的成员一起略去，侧栏无需改动。
- **命令行与 MCP**：`default` 与 `app` 照各自的选项（默认折叠）；`full`（也就是 MCP 用的 `.mcp` 预设）展开。agent 插件的 skill 跟着写明，并抬版本号。
- **测试**：Core 的选项映射与旧设置的解码；测试包里的 `@Observable` 夹具（含一个嵌套的）经引擎打印，核对属性范围、展开归属、各段放置（属性下方、`}` 上方与下方，嵌套类型按自己的声明与 `}`）、段内容不带缩进、有无标记文本不变、注释结构不变、展开形态无可展开；注释结构跳过宏区域；JSON 与 XPC 两条传输路径都带上宏展开；内容区把 UTF-8 范围换成屏幕文本的 UTF-16 范围、提示语替换文本时丢掉展开；bridge 测试里多段 gap 的位置、缩进、一起收起，以及点任意一段的关闭按钮全部关闭；第二层挂在正文里、随外层收起或被外层的关闭按钮关掉、单独收起时外层还在、外层没显示时不显示，展开段里的右键菜单带着词的范围、段号与展开标识来问，且去掉 Cut；内容区把段内再展开的属性范围按那段文字换成 UTF-16。右键菜单项本身在 App target 里，没有测试 target，靠构建与手工验证。
- **文档**：命令行指南与 agent 插件；落地时提案取号。
- **没有询问就采用的假设**：
  - 展开块里各声明怎么打印由 MachOSwiftSection 定，RV 不自己从区域里拼；
  - `full` 预设的定义是「什么都显示」，所以展开；
  - 原地展开只在 SourceEditor 显示时提供。

## 落地步骤

1. ✅ 生成选项、打印配置映射、命令行预设（MachOSwiftSection 的识别与 `expandsMacros` 到位即可做）。
2. ✅ 接口模型带上宏展开（等 MachOSwiftSection 的展开块与属性位置）。
3. ✅ bridge 的行内展开与内容区的右键菜单。
4. ✅ 测试与文档已补齐；MachOSwiftSection 的 0093 与 0094 合进它的 `next` 后，锁文件里它与 swift-demangling 的 pin 已抬上去。
5. ✅ 两层展开：bridge 的第二层与展开段里的右键菜单，接口模型、RuntimeSwiftSection 的两层摆放、内容区与 App 的菜单；MachOSwiftSection 的 0095 合进它的 `next` 后抬 pin、全量验证，合进 RV 的 `next`。

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
| 2026-11-12 | 展开放进类型里，分段放：每个被跟踪的属性下方是访问器块与存储属性，类的 `}` 上方是 registrar 与生成的方法，`}` 下方是一致性扩展；几段一起展开、一起收起 | 用户选定。Xcode 展开 attached macro 时按 SourceKit 给的插入点分段放 gap（IDESourceEditor 26.6 `MacroManager.showInGap`）；重建版的 gap 能放在行的上方或下方，关闭按钮会移除同一标识的所有 gap（27.2.0-alpha.1 `SourceEditorGapView.dismissButtonAction(_:)`） |
| 2026-11-12 | `{ get set }` 放在属性下方的 gap 里，属性那一行不改写 | 用户选定。gap 只能插在行与行之间；改写正文要重算注释标签、跳转与其他展开的全部偏移，Xcode 展开访问器宏也是放在下方 |
| 2026-11-12 | 存储属性各自紧跟在它的属性下面，不集中放在类体末尾 | 用户选定；与宏自己生成存储属性的位置一致 |
| 2026-11-12 | 分段打印由 MachOSwiftSection 在它收尾前加：折叠形态里每个被跟踪属性的声明标一个按属性命名的区域，展开按属性、成员、一致性分段打印；类的 `}` 不单独标，用嵌套类型的定义区域或 RV 打印的那个定义的最后一行 | 用户选定现在就协调。`}` 由 swift-semantic-string 的 `DeclarationBlock` 写出、没有挂钩，单独标它要改上游再发版；RV 本来就分开打印各个定义再拼接，自己记下类型定义的范围即可 |
| 2026-11-12 | 展开里的文字按测量对齐正文：内嵌编辑器的左边距取「正文第 0 列在窗口里的横坐标，减去内嵌编辑器不加边距时第 0 列的横坐标，再加缩进格数乘空格宽」，不再用 Xcode 的「字号一半加缩进」 | 用户在 macOS 27.2 的 AppKit 上看到每段都比正文往左偏十几个点。重建版 27.2.0-alpha.1 里三处让两边的左边距不同：行号栏宽度按行数的位数算（`SourceEditorGutter.gutterWidthFor(lineCount:referenceFont:)`），正文有折叠条、内嵌编辑器没有，macOS 26 起正文只在行号栏出现 overfillTrailing 类标注时才加字号一半的边距（`SourceEditorView.updateAdditionalLeftPadding()`）。两个编辑器都从 `layoutBounds` 的左边开始排每一行（`ContentViewLayoutContainer`、`ViewportLayoutStrategy`），所以比较它们就能算准；折叠条开关时 bridge 让展开重新对齐 |
| 2026-11-12 | 展开改成两层：展开 `@Observable` 只在每个被跟踪属性上方给出 `@ObservationTracked`，外加 `}` 上方的成员与下方的一致性；访问器块与 `_x` 改由在展开段里右键这个 `@ObservationTracked` 再展开得到，放在正文里那个属性的下方。两层都由 MachOSwiftSection 打印，两层都做完再落地 | 用户在落地前指出展开过头了，并选定这三项。Swift 源码里 `ObservableMacro` 是 MemberAttributeMacro，只给属性加 `@ObservationTracked`；访问器块和 `_x` 是 `ObservationTrackedMacro` 的 accessor 与 peer 两个角色写的（`swift/lib/Macros/Sources/ObservationMacros/ObservableMacro.swift`）。Xcode 也是在展开出来的文字里再展开：内嵌编辑器请求展开时带上 macro buffer 的名字（IDESourceEditor 26.6 `SourceCodeEditor.showMacroExpansion()`，0x1873B0） |
| 2026-11-12 | 写了 `@ObservationIgnored` 的属性照旧：折叠形态已经标出 `@Observation.ObservationIgnored`，两层展开都不给它东西 | MachOSwiftSection 已能认出：类里的存储 `var` 只要不是被跟踪属性的 `_x`，就是宏没碰过的，源码里一定写了 `@ObservationIgnored`（`let` 宏本来就不跟踪）；宏本身也跳过这些属性 |
| 2026-11-12 | 第二层的几段挂在正文里，收起外层（菜单或任意一段的关闭按钮）时一起收起；单独收起第二层，外层不动；外层没显示时第二层不显示 | 第二层锚在正文里的属性上，与外层的段是不同的 gap。外层的关闭按钮由框架直接移除 gap、不经 bridge，所以 bridge 向主编辑器的 gap controller 注册观察者，外层最后一个 gap 被移除时收掉从它展开的那些（重建版 27.2.0-alpha.1 `SourceEditorGapController.addObserver(observer:)`，移除完才通知、遍历的是副本，回调里再移除是安全的；Xcode 26.6 的 SourceEditor 也导出这两个接口） |
| 2026-11-12 | 展开段里接右键菜单，只为展开里挂着的宏给出 Expand Macro / Hide Macro Expansion，并去掉 Cut；⌘ 点、跳转与注释标签仍不接 | 推翻 2026-11-11「行内展开里不接右键菜单」的一半：第二层要从这里打开。每个 `SourceEditorView` 初始化时都注册自己的 `ContextualMenuEventConsumer`，右键时问 `contextualMenuItemProvider` 要更多菜单项（重建版 27.2.0-alpha.1），主编辑器用的也是这个钩子 |
| 2026-11-12 | 不等 swift-demangling 发版，先把锁文件抬到 MachOSwiftSection 的 270c0218 与 swift-demangling 的 8809c1b；功能分支快进到本地 `next`，带上 init 访问器的 `.initAccessor` 标签 | RV 根包对两者都按 `branch: "next"` 依赖，盖过 MachOSwiftSection 写的版本下限，锁文件钉的是提交，RV 自己的构建与发版都不受影响。270c0218 带着 init 访问器，`AccessorKind` 多了 `.initAccessor`，成员列表的 switch 要有那一行才编得过；它只在本地 `next` 上（另一个会话提交），功能分支是 `next` 的祖先，快进不产生合并提交 |
| 2026-11-12 | 折叠形态里 `@Observation.ObservationIgnored` 单独占一行，声明放在下一行、缩进相同；被忽略的属性带属性包装器时，包装器属性也单独一行；`lazy` 留在声明行 | 用户看 SwiftUI 的类时提出：属性与长类型挤在一行，每行都折行，难读。打印由 MachOSwiftSection 做（并进它的 0095），RV 不用改：Find 语料与右键菜单按每行的 `.variable` 片段认成员（`RuntimeMemberDeclarationLocator`），属性那一行没有变量名，成员仍落在声明行 |
| 2026-11-12 | 实现完成，合进 `next`，编号 0088，状态改为 Implemented | 五份锁文件钉在 MachOSwiftSection `next` 的 1ba927ad 与 swift-demangling `next` 的 8809c1b，FrameworkToolbox 0.21.0 不动。落地前在 MacBook 上对这个提交验证：Debug workspace 的 App（Debug-arm64e）与命令行工具编过；bridge 测试 69 个只有 `SourceEditorScrollerTests` 的两个滚动条用例失败，基线上同样；Core 与 Packages 全量测试里满载时的失败单独重跑都过，只有 `TitleActivityIndicatorTests` 的标题悬停仍失败，不含本次改动的 origin/next 上在同一行同样失败。不另写使用指南或实现说明：入口是 Generation Options 的 Expand Macros 与内容区的右键菜单，用法与 Xcode 一致，命令行指南与 agent 插件在实现时已同步，设计与证据都在本提案；术语表加「行内展开」 |

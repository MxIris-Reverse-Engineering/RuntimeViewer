# Draft - Find navigator：查找文本、类型关系与成员

- **状态**: In Progress
- **创建日期**: 2026-09-29
- **最后更新**: 2026-10-01
- **所属愿景**: 无（内容区的行定位部分与《自建代码视图引擎》相邻，但本提案不改视图引擎的方向）
- **前置设计**: `feature/interface-corpus-probe` 分支上的
  `Documentations/Plans/2026-07-26-global-search-design.md`（2026-07-27 按
  `Reviews/2026-07-27-global-search-design-review.md` 修订）。文本搜索这一半**原样采用**那份设计，本提案只把它迁进
  提案制、补上与 `next` 分叉后过时的三处，并加上关系与成员两种模式。

## 摘要

仿 Xcode 的 Find navigator，给文档窗口加一个查找面板，三种模式：

1. **文本**——在已索引镜像的全部 interface 正文里做文本匹配（含注释），Containing / Matching Word /
   Starting With / Ending With / Regular Expression，可选大小写与搜索域（全部 / 排除注释 / 仅注释 / 仅符号）。
2. **关系**——输入一个类型名，列出它的 Ancestor Types / Descendant Types / Conforming Types，语义与 Xcode 一致
   （传递闭包，结果成树）。
3. **成员**——按名字查找 ObjC property / method / ivar，Swift field / function / variable / subscript /
   initializer，可按种类过滤；数据直接来自 section 里的结构（`ObjCClassInfo` 一族、`TypeDefinition` 一族），
   不从文本反推。

点击结果跳到对应类型，内容区滚到命中行并高亮（NSTextView 与 SourceEditor 两条路径都做）。面板的具体 UI 照
Xcode Find navigator 的 view hierarchy 实现，由用户提供，本提案不设计 UI。

## 方案

### 0. 前置：`RuntimeObjectInterface` 改存 `FrozenSemanticString`（单独一个 PR）

`feature/interface-corpus-probe` 上的三个提交（`c8bd6a15` 存储边界 `compacted()`、`606bf8f8` 改存
`FrozenSemanticString`、`388dd212` 应用侧改按 span 渲染）先单独 rebase 到 `next` 合入。理由有两条，都与本提案无关也
成立：`RuntimeObjectInterface` 现在每一份都过 XPC（「My Mac」引擎已在 `RuntimeViewerLocalRuntimeService.xpc` 里），
Frozen 的列式编码比逐 component 编码小一个数量级；语料条目本来就是 Frozen，不改边界就要在 store 里再冻一次、
两种形态并存。

`next` 上的消费点比分支当年多，rebase 时逐个改：`ContentTextViewModel`（`interfaceString` 类型与
`RenderedInterface.semanticString`）、`RuntimeInterfaceCache`、`ThemePreset+ThemeProfile`、
`ContentSourceEditorViewController`、`MainViewModel` 的导出、`RuntimeInterfaceExportEvent.objectCompleted`、
CLI 与 MCP 的 `.string`。`FrozenSemanticString.components` 仍在，需要 component 视图的地方可以兜底。
分支 `RuntimeViewerCore/Package.swift` 里那段 `from: "0.1.5"` 的重复依赖声明**丢掉**——`next` 已经 pin 到
`swift-semantic-string` 的 `next` 分支（0.3.0 之后），`FrozenSemanticString` 已在其中。探针 target
`InterfaceCorpusProbe` 不合入。

### 1. 引擎侧语料：`RuntimeInterfaceCorpusStore`

按设计稿 §2，逐条列出并把审查意见落进来：

- 新 actor `RuntimeInterfaceCorpusStore`，挂在 `RuntimeEngine` 上（lazy，与 `backgroundIndexingManager` 同模式），
  **语料永远住在拥有 section 的进程里**。远程引擎只过线请求与结果。
- 条目：`Entry { object: RuntimeObject; interface: FrozenSemanticString; visibilityRegions; members: [RuntimeMemberDeclaration] }`，
  按 `imagePath` 分组。成员表与语料**同一趟构建**（见 §3.2 为什么必须同一趟）；每个成员记下声明在全量文本里的
  位置，投影后据此判断它是否可见、取它在显示文本里的行。
- `BuildState`：`pending / building(built, total) / built(summary) / failed(message)`。取消（订阅归零、驱逐、引擎停止）
  → 条目移除，回到未构建，不记 failed；构建抛错 → `failed`，不自动重试，任一触发源再次命中该镜像时重新排队；
  单个对象打印失败不整体 failed——跳过并计数，summary 报告跳过数。
- 驱逐与 section 生命周期对齐：`RuntimeSwiftSectionFactory.removeSection(for:)` / `removeAllSections()`、
  `RuntimeEngine.stop()`（`releaseIndexedSections`）时同步清掉该镜像的语料。Settings 总开关关掉时整体清空。
- 驻留预算：store 记录 Frozen 总字节数，硬上限 256 MB；超限按「最久未被搜索命中」整镜像驱逐回未构建。
- 构建队列在 store 内串行（并发 1）、`.utility`；同镜像重复入队按 `buildStateByImagePath` 去重。
- **取消按订阅引用计数**：每个 `BuildInterfaceCorpusRequest` 只是对该镜像构建的一次订阅，最后一个订阅者退订才取消
  构建任务。多文档共享 `.local` 引擎时，文档 A 关闭不会砍掉文档 B 在等的语料。

**语料 = 全量打印 + 可见性区域，搜索时按当前选项投影**（2026-09-29 取代原先的「canonical 选项」，见决策日志）。
每个对象只打印一次：打印器的**标记模式**把受 Generation Options 控制的内容全部打出来，并用 swift-semantic-string 的
`VisibilityRegion` 标上它在什么选项下可见（ObjC 的六个 strip 与四个注释开关，Swift 的偏移 / 地址 / 布局注释、
stripped symbolic item、opaque 类型约束、按名字推断的 `@objc override`）。冻结后分离成「文本 + 区域表」存进条目。
搜索请求带上内容区当前的 Generation Options，引擎按它把每个条目投影成「内容区会显示的文本」再匹配，所以搜到的
都看得见，行文本与内容区逐字节相同；切换这些选项**不重建**语料。只有 transformer 仍要重建：它改写的文字含用户
输入，无法预先打全（触发源 4，§4），store 记录构建时的 transformer 指纹，远程场景下配置随请求过线。
`memberSortOrder` 是重排，区域表达不了，语料固定按分类排序，只影响同一类型内结果的先后与行号（行号不显示，
定位先按整行文本）。三处上游改动各有提案：swift-semantic-string `docs/VisibilityRegions.md`、MachOObjCSection 提案 0011 与
MachOSwiftSection 提案 0056（都叫 `visibility-regions`）。

**旁路打印路径**（Swift / ObjC 各一）：用标记模式打印 → 冻结并分离区域 → 入 store。**不写
`RuntimeSwiftSection.interfaceByObject`、不动 `lastTransformerConfiguration`**，不污染显示缓存。ObjC 侧本就无缓存，
只需走 builder 的标记入口；Swift 侧用独立的语料 printer（标记模式 + 用户 transformer + 注册 opaque 类型解析器），
显式绕开 `updateConfiguration` 的驱逐逻辑。逐对象响应 `Task.checkCancellation`，进度按 built / total 上报。

### 1.1 语料构建性能（2026-09-30 修订）

用户实测（Debug 构建、M1 Max）：5 个 Always Index 镜像索引完 4 分钟后只有 1 个可搜，18 分钟后服务进程仍在建第二个。
对该进程采样（`sample`，5 s / 3851 个样本全落在同一个 Swift 类型的打印里）：

- 61% 在 `printExpandedFieldOffsets`：每个存储字段递归展开嵌套 struct / enum 布局到 16 层，每次从运行时元数据重算，没有记忆化；
- 其中 9% 是 `InProcessContext.lookupSymbol(at:)`：每查一个匿名上下文地址线性扫整张符号表，共享缓存镜像的本地符号已剥离，必落空；
- `corpusObjects(in:)` 把嵌套类型当独立对象再打一遍，而父类型的接口已内联嵌套类型——重复打印，搜索结果也重复；
- 构建串行、单线程、`.utility`，只跑 2 个效率核；
- 用户自己的显示选项是 Swift 全开，所以「语料不打昂贵选项」不可行，行号会和内容区对不上。

**计量先行**：分支专属的可执行目标 `CorpusBuildTimingProbe`（`RuntimeViewerCore/Sources/CorpusBuildTimingProbe/`，不合入）：
`corpus` 模式计真实构建，`display <preset>` 模式按预设选项经内容区路径打印全部对象，预设两两相减得到每个选项的代价；
`--top-level-only` 量出嵌套重复的份额。每个预设各起一个进程。Release 下对 Foundation / SwiftUI / libswiftCore 各测一遍，
优化前后的数字记入决策日志。

**交付顺序**：MachOSwiftSection 的 `draft-concurrent-definition-printing` 排在最前，而且不管下面第 2 条做不做都要做——
它修的是本分支**今天就在发生**的竞争：`RuntimeSwiftSection` 是 actor，显示路径与语料路径都 `await` 到 printer 的 nonisolated
入口、打印期间 actor 被释放，语料在后台建几分钟时用户点开同一镜像的类型，两边同时对同一个定义惰性索引、同时写 `attributes`。

**RuntimeViewerCore 侧**：

1. **嵌套类型的重复**（审查后重做）。命中记的是 `(object, lineNumber)`，行号必须落在该对象内容区的文本里；父对象的文本里
   嵌套类型以 `level + 1` 打印、且不含嵌套类型自己的 extension / conformance extension、嵌套协议的默认实现扩展与
   `specializedChildren`（只在子对象的 `printedDefinitions` 里），所以「只建顶层条目、把嵌套类型的扩展补在父条目后面」不成立。
   先用 probe 的 `display mcp --top-level-only` 量出嵌套对象占打印时间的份额（它走内容区路径，是语料路径的代理——语料还多了
   标记、区域分离和定位），再二选一：
   - **B（默认，份额 < 20%）**：条目照旧一个对象一条；父条目记下每个嵌套定义块的**行区间**，文本与成员搜索扫父条目时跳过——
     嵌套类型的命中只从子条目出来，对象与行号都对；打印量不变，只去掉重复结果。区间从哪来：子条目本来就单独打印，把子对象
     第一个定义的文本加一级缩进后在父文本里做子串匹配，区间精确，还顺便在真实数据上持续验证 D 的前提；匹配不到就不跳过
     （退化为今天的重复）。区间记原文偏移，搜索跑在投影后的文本上，要经 `projectedUTF8Offset(ofOriginalUTF8Offset:)` 换算。
   - **D（份额大时）**：父条目照旧打印；子条目**不再打印嵌套体**，而是从父条目的嵌套块派生（去掉一级缩进；span 与可见性
     区域随之平移，且平移后逐条相等要一起断言），只额外打印子对象自己的扩展定义接在后面。前提：同一类型内联与独立打印的
     文本除缩进外逐字节相同（`displayParentName` 两处都是 false）——注意 enum layout 的逐 case 注释是**单个多行原子**，每行各自
     带缩进前缀，去缩进要进到原子内部逐行删；fixture 覆盖 enum layout、展开字段偏移、transformer 开着三种情况。失败回退：
     父对象整体打印失败或该嵌套子定义被逐子 catch 掉时没有派生来源，回退到独立打印。D 让子条目依赖父条目，与第 2 条并行
     打印的交互要定：工作单元改成「一个根对象连同它的全部后代」。嵌套块的边界 D 拿不到（`NestedDeclaration` 摊平后不留边界），
     需要上游在嵌套子定义的原子上打标记（与可见性区域同一手法，MachOSwiftSection 的 API 变更，选 D 才另开提案）。
   两条路都要修一个**既有缺陷**：`memberDeclarations(for:)` 不递归，但父对象文本里嵌套类型的声明排在父对象自己的字段与成员
   之前，定位器按「第一条未认领的同名行」分配——父类型的成员会抢到嵌套类型同名成员的行。比「父子同名 `init`」常见得多：
   Codable 类型编译器合成的嵌套 `CodingKeys` 的 case 名与父类型的存储属性一一同名，父类型每个字段都会分到 `CodingKeys` 的
   case 行上。复现测试就用它。修法是定位父对象成员时跳过嵌套块区间（区间来源同 B）。
   **待核实的同类重复**：根协议的默认实现扩展可能被打印两遍——printer 对 `parent == nil` 的协议在协议之后接着打印
   `defaultImplementationExtensions`，而 `printedDefinitions(.rootProtocol)` 又把它们作为独立定义追加了一遍；`next` 的显示路径
   同样写法。先用 Foundation 里带默认实现的根协议写一条测试核实，属实则同批修（`printedDefinitions` 不再追加）。
2. **一个镜像内按对象并行打印**：`RuntimeInterfaceCorpusStore.run` 改为有界任务组，条目按列表顺序落位，进度按完成数在
   actor 上累加，子任务随父任务取消，与订阅 / 取消模型不冲突。宽度：大栈执行器每个 QoS 类只有 `max(2, 核数)` 个线程，
   后台索引也跑在同一个 `.utility` 类上，两边加起来不能超——取 `max(2, 核数 / 2)`。`RuntimeObjCSection.corpusPrint`（原 `corpusEntry`）一路改
   `nonisolated`（只读 `let`）。Swift 侧的**串行尾巴**：`RuntimeSwiftSection` 是 actor，打印本身能并行，但 `printedDefinitions`、
   `memberDeclarations`、定位器、`frozen()`、`separatingVisibilityRegions`、`RuntimeInterfaceCorpusEntry.init`（逐字节扫行首）
   都在 actor 上——`memberDeclarations` 拆成「actor 上取定义列表」+「actor 外读成员」，其余是值上的纯函数，全部挪到
   nonisolated；只有取定义列表留在 actor 上。**QoS 待定**：设计稿选 `.utility` 是为了不抢用户的前台加载，但 `.utility` 偏向
   效率核，任务组的并行度可能仍被卡住；先按 `.utility` 落地，用 probe 的 `corpus` 模式前后对照，提速被卡时再向用户提是否改
   固定的 `.default`。
3. **插队**：store 加 `prioritize(imagePath:)`（`pendingImagePaths` 移到队首，不新增订阅，不抢占正在跑的镜像——SwiftUI 这种
   要建几分钟的镜像在跑时，用户点开的镜像仍要等它建完），经引擎请求暴露；协调器对已有订阅的镜像调它而不是 `requestBuild`
   （后者遇到已有订阅直接返回，到不了 store）。触发源 2（用户点开的镜像）置顶——提案写了，实现没做。
4. `FindCorpusCoordinator` 暴露每镜像的构建状态（由 `onProgress` 与任务结果驱动、16 ms 合并，启动时用 `interfaceCorpusCoverage()`
   补快照；归属与展示见 [draft-report-navigator](draft-report-navigator.md)），Find 摘要改写成「N images being made
   searchable · building Foundation 37%」。**语料建成时不重跑整个搜索**——`run(_:)` 一进来就清空结果，几个镜像接连建成会连清
   好几次、选中与滚动位置全丢；改为只对新建成的镜像搜一次（搜索请求加 `imagePaths` 范围）、把命中并进现有结果，仍复用
   `rerunAfterGenerationOptionsChange` 的 guard（空查询与关系搜索不做）。

**测试与记录**：`RuntimeInterfaceCorpusStoreTests` 补并行落位顺序、插队、进度计数；`RuntimeMemberDeclarationLocatorTests` /
`RuntimeInterfaceSearchTests` 补 `CodingKeys` 同名与根协议默认实现重复；probe 报的 `ru_maxrss` 前后记入决策日志（并行时同时在飞的
`SemanticString` 数 = 宽度，峰值内存会升）。

**不做**（用户裁定）：语料落盘缓存；按 Find 分页可见与否切换构建优先级。

**实施记录（2026-10-01）**：

- **构建拆成两步**。逐对象打印只产出 `RuntimeInterfaceCorpusPrint`（文本、区域表、未定位的成员、对象自身定义的
  UTF-8 长度）；整镜像打印完后由纯函数 `RuntimeInterfaceCorpusAssembly` 在 store actor 之外组装成条目：找嵌套块、
  定位成员、建行表。原先在 section actor 上的定位器随之移出，这是第 2 条「串行尾巴」的第一步。
- **第 1 条按 B 的区间落地**，在 probe 数字之前：区间是 B 和 D 共有的（定位修复要它，文本搜索跳过嵌套块也要它），
  probe 只决定要不要再做 D 的「子条目从父条目派生、省掉嵌套体的打印」。区间取法：子条目的自身定义每个非空行
  加一级缩进（空行保持为空），在父文本里找第一处**占满整行**、且未被别的子条目认领的出现。没有父类型定义的协议，
  打印器会把默认实现接在它后面，而协议嵌在别的模块类型的扩展里时这段落在第 0 列，所以协议的自身定义截到第一个
  顶格 `extension` 之前。父条目记 `nestedDefinitionRanges`（原文偏移），文本搜索在投影后经
  `projectedUTF8Offset(ofOriginalUTF8Offset:)` 换算后跳过；成员定位排除这些区间内的行。Foundation 上的数字：
  修复前 16317 个已定位 Swift 成员里 1183 个落在嵌套类型的行上，修复后 0；嵌套块全部找到。
- **根协议默认实现的重复核实属实并已修**：见决策日志。
- **第 3 条**：构建请求加 `isPrioritized`，第一次请求就置顶；已有订阅的镜像再被点开时发 `PrioritizeInterfaceCorpusRequest`，
  不加订阅。
- **第 4 条**：`FindCorpusCoordinator` 发布 `buildStatesByImagePath`、`finishedBuilds`（100 条封顶）、`corpusBuilt` 与
  `hasActiveBuild`；进度经加锁的暂存 16 ms 合并后上主线程；启动、换引擎与每次构建结束后用 coverage 补快照（规则见
  决策日志）；`cancelBuild(of:)` 只撤本文档的请求并记一条 cancelled。搜索请求加 `imagePaths` 范围，摘要报告
  `scannedImagePaths`；`FindSession` 记住结果读过哪些镜像，新建成的镜像只搜它一个、并进现有结果，搜索进行中建成的
  等搜索结束再补。摘要栏是 `N results in M types · 2 images being made searchable · building Foundation 37%`，
  没有在建的镜像时仍报 `N images not yet searchable`；关系搜索不带这一段。
- **第 2 条的结构先落地，宽度暂为 1**：`RuntimeInterfaceCorpusStore.run` 改成有界任务组，宽度是 store 的参数
  （`defaultPrintingWidth`），打印结果按对象下标落位，进度按完成数累计。ObjC 侧 `corpusPrint` / `markedInterface` /
  `memberDeclarations` 改 `nonisolated`；Swift 侧只有「取定义列表与语料打印器」留在 actor 上，打印、冻结、区域分离与
  成员读取（`memberDeclarations(of:)` 改为对定义列表的静态函数）都在 actor 之外——显示路径不再排在语料打印后面。
  上游的并发打印安全落地之前，同一镜像的两个打印可能同时索引同一个定义，所以生产宽度保持 1，届时改为
  `max(2, 核数 / 2)` 并用 probe 前后对照。
- **未做**：probe 的运行（等用户同意）；并行宽度的放开（等 MachOSwiftSection 的并发打印安全落地）；两份上游提案
  由 MachOSwiftSection 那边的会话实现。

### 2. 引擎请求（全部经 `registerSharedHandlers` 注册，XPC / TCP / proxy 链自动透传）

| 请求 | 类型 | 进度 | 响应 |
|------|------|------|------|
| `BuildInterfaceCorpusRequest { imagePath, transformerConfiguration }` | progress | `CorpusBuildProgress { built, total }` | `CorpusBuildSummary { objectCount, skippedCount, byteCount }` |
| `SearchInterfacesRequest { query, options, generationOptions, resultLimit }` | progress | `[GlobalSearchMatch]`（按镜像粒度增量推送） | `GlobalSearchSummary { totalMatchCount, scannedImageCount, isTruncated, unbuiltIndexedImagePaths }` |
| `SearchMembersRequest { query, kinds, isCaseSensitive, generationOptions, resultLimit }` | progress | `[RuntimeMemberMatch]`（按镜像粒度） | 同上形态的 summary |
| `TypeRelationshipsRequest { query, isCaseSensitive, relationship: ancestors / descendants / conformers }` | 普通 | — | `[RuntimeRelationshipTree]` |
| `InterfaceCorpusCoverageRequest` | 普通 | — | `[imagePath: BuildState]`，覆盖率 UI 用 |

`Progress` 必须是具名 `Codable` struct，不能是 tuple（审查意见 2）。请求与结果模型放在 `RuntimeViewerCore/Common/`，
命名与 CLI / MCP 的 `--json` 词汇对齐，将来暴露成命令只是机械包装（本提案不做，见「不做」）。

### 3. 三种模式的语义

#### 3.1 文本

- 匹配：对每个条目在 `frozen.text` 的 UTF-8 上做 ASCII case-folding 子串扫描（非 ASCII 字节精确匹配）；span 游标随扫描
  推进，命中时 O(1) 取语义类别做域过滤；行号 / 行文本由命中偏移向两侧找 `\n`。Starting With / Ending With 以标识符
  字符类 `[A-Za-z0-9_$]` 判边界，Matching Word 两侧都判。Regular Expression 模式对每个条目的 `text` 跑 Swift `Regex`
  （`text` 是现成 `String`，逐条目取消）。
- 搜索域 → `SemanticType` 映射（闭合定义，单测按此断言）：

  | 域 | 命中的语义类别 |
  |---|---|
  | all | 全部 |
  | excludeComments | 除 `comment` 外全部 |
  | commentsOnly | 仅 `comment` |
  | symbolsOnly | `type` / `member` / `function` / `variable` / `argument` |

  `keyword`、`standard`、`numeric`、`error`、`other` 不属于 symbols。
- `resultLimit` 默认 1000，全局上限：达到后停止收集，**继续扫描只计数**，`totalMatchCount` 是真实总数，UI 呈现
  「共 N 条，展示前 1000 条」。
- `GlobalSearchMatch`（过线的只有它，不含 Frozen 本体）：`object`、`imagePath`、`lineNumber`、`lineText`、
  `matchRangeInLine`（UTF-16）、`semanticKind`（`SemanticType` 的 Codable 镜像）。
- 父 / 子对象的 interface 有少量重叠（探针实测 child 部分占 17–31.5%），两处命中都如实报告，不去重（与 Xcode 一致）。

#### 3.2 成员

- **数据来源是结构，不是文本。** ObjC：`RuntimeObjCInterfaceIndexer` 的 `classGroup(forName:)` /
  `protocolGroup(forName:)` / `categoryGroup(forName:)` 给出 `ObjCClassInfo`（`properties` / `classProperties` /
  `methods` / `classMethods` / `ivars`）、`ObjCProtocolInfo`（含 optional 四组）、`ObjCCategoryInfo`。
  Swift：`TypeDefinition`（`fields`、`variables` / `functions` / `subscripts` 及 `static*`、`constructors` /
  `allocators`、`orderedMembers`）、`ProtocolDefinition`（同一组 + `strippedSymbolicRequirements`）、
  `ExtensionDefinition`（同一组）。
- **为什么和语料同一趟构建。** Swift 定义的成员是惰性索引的：`TypeDefinition.index(in:)` 是 MachOSwiftSection 的
  package 级方法，只有打印（`SwiftDeclarationPrinter`）才触发；语料构建正好把每个对象打印一遍，打印完
  `definition.isIndexed == true`，成员表现成。不打印就拿不到 Swift 成员，除非上游开一个公开的索引入口——本提案不改
  上游。
- `RuntimeMemberDeclaration { name, kind, isStatic, declarationText, lineNumber? }`，`kind` 枚举：
  `objcProperty / objcMethod / objcIvar / swiftField / swiftEnumCase / swiftFunction / swiftVariable /
  swiftSubscript / swiftInitializer`。用户要的六类（ObjC Property、Methods、Swift Field、Function、Variable、
  Subscript）是面板上的过滤组，ivar / enum case / initializer 归入相邻组或单列，由 UI 定。
- **行号来自同一趟打印的 span 序列**：打印完成后顺序遍历 Frozen 的 `.member(.declaration)` /
  `.function(.declaration)` / `.variable` span，与结构成员按名字顺序对齐（ObjC 多段 selector 取第一段对齐）。对不上
  的成员 `lineNumber` 为空，仍可搜、点击只跳到类型。
- 查询：名字子串匹配（大小写可选），`kinds` 过滤；`RuntimeMemberMatch { object, member, matchRangeInName }`。
  `resultLimit` / truncated 语义与文本相同。

#### 3.3 关系（Ancestor / Descendant / Conforming Types）

- 输入是类型名：先按名字在全部已索引镜像里解析候选类型（精确匹配优先，其次子串，大小写可选，上限 50 个），每个候选
  各出一棵树 `RuntimeRelationshipTree { root: RuntimeObject; children: [Node]; Node { object, isResolved, children } }`。
  `isResolved == false` 表示该类型不在任何已索引镜像里（例如父类在未索引的框架），只能给名字，不能点击跳转。
- **Ancestor Types**：类 → 整条父类链（逐级嵌套）+ 每一级采纳的协议；协议 → 它 refine 的协议（递归）；
  struct / enum / actor → 采纳的协议（递归到协议的 refine）。
- **Descendant Types**：类 → 全部传递子类（逐级嵌套）；协议 → refine 它的协议（递归）。
- **Conforming Types**：协议 → 直接 conformer（与 Inspector Relationships 一致，不含经 refining 协议间接 conform 的）。
- 数据来源与要新增的两张表：

  | 关系 | ObjC | Swift |
  |------|------|-------|
  | 父类链 | `classGroup.info`（自身在前，父类逐级，跨镜像已解析） | `classDescriptor.superclassTypeMangledName(in:)` 逐级 demangle + remangle（与 `RuntimeSwiftInterfaceIndexer.prepare` 建子类表的钥匙同一空间） |
  | 类型 → 协议 | `ObjCClassInfo.protocols`（含 category 采纳） | `SwiftDeclarationIndexer.conformingProtocolNamesByTypeName` |
  | 子类（已有） | `subclasses(of:)` | `subclasses(of:)` |
  | conformer（已有） | `conformingClasses(toProtocol:)` | `conformingTypes(of:)` |
  | 协议 → refined 协议（**新表**） | `ObjCProtocolInfo.protocols`，`prepare()` 之后遍历 `protocolNames` 建 | `Protocol(descriptor:in:).requirementInSignatures` 里 subject 为 `Self`（mangled `x`）且 content 为 `.protocol` 的项（`ProtocolFactsResolver.facts(fromDescriptor:)` 的做法，它本身是 internal，不复用） |
  | 协议 → refining 协议（**新表**，上一行的反表） | 同上反向 | 同上反向 |

  两张新表按 0008 的对称形态放进 `RuntimeObjCInterfaceIndexer` / `RuntimeSwiftInterfaceIndexer`，eager 建、
  `addSubIndexer` 聚合、查询跨镜像。传递闭包在 `RuntimeRelationshipsResolver` 旁新建的 `RuntimeTypeRelationshipsResolver`
  里做（BFS，visited 去重防环，深度上限 64）。桥接类的去重沿用 `isSwiftStable`。
- 已知缺口（沿用现状，本提案不修）：ObjC 类的泛型 Swift 子类没有 `class_t` 记录，出现不了；`hierarchy(for:)` 对泛型
  Swift 类返回空，本提案不用它，改走静态父类链，所以泛型类的祖先链是有的。

### 4. App 侧

- **`GlobalSearchCorpusCoordinator`**（`RuntimeViewerApplication`，`@MainActor`，与
  `RuntimeBackgroundIndexingCoordinator` 平级，同样订阅 `documentState.$runtimeEngine` 换引擎重接）。触发源：
  1. `backgroundIndexingManager.events` 的 `.taskFinished(result: .completed)` → 该镜像排队。`events` 每次访问都是
     一条独立的订阅，与索引协调器互不抢事件；订阅到手后先把已索引的镜像补队，堵住订阅之前刚好索引完的那段空隙
     （决策日志 2026-09-29「后台索引事件改为广播」）；
  2. `imageDidLoadPublisher`（用户显式点开镜像）→ 排队并置顶；
  3. Settings 开关 off → on → 对所有已索引镜像补队；
  4. `settings.transformer` 变更（约 2 s debounce）→ 全量驱逐重建。
  独立于背景索引 coordinator：那个管「让镜像有索引」，这个管「让已索引镜像可搜」，生命周期与取消语义不同。
- **Settings**：新增 `Settings.search` 分支：`isCorpusEnabled`（默认开）、`residentByteLimit`（默认 256 MB）。
  加进 `accessPersistedValues()` 与 `SettingsPersistenceTests` 的覆盖表。
- **`FindViewModel`**（`RuntimeViewerApplication`）：Input = 模式、查询串（debounce 300 ms）、文本匹配方式 / 大小写 /
  搜索域、成员种类过滤、关系种类、结果点击、结果在新标签页打开；`@RxObserved` 状态 = 结果（按镜像 → 对象分组，成树）、
  `searchState`（idle / searching / done(summary) / truncated）、`corpusCoverage`（已建 / 已索引，含构建中明细）。
  结果可达千级，cell ViewModel 走 `DifferentiableBox` 的 lazy 形态（AGENTS.md 表格规则 9）。
- **挂载与路由**：`MainRoute.find`（⇧⌘F，Xcode 的 Find in Workspace；本 App 与 UIFoundation 标准菜单都没占用），
  经 `MainWindowController` 的 late-responder 送达。面板是侧栏的第三个分页（`magnifyingglass`），**两层侧栏各有一个
  分页，共用同一个 per-document `FindViewModel`**，从 image 列表层还是对象列表层进去看到的都是同一份查询与结果；
  分页布局照 §4.1 的 view hierarchy 实现，ViewModel 与请求层不依赖挂载位置。
- **跳转与二次定位**：点击 → `documentState.selectionRouter.trigger(.push(object))`（⌥ / 右键 → `.openInNewTab`）；
  同时把 `PendingHighlight { query, lineNumber, lineText, matchRangeInLine }` 写进 `DocumentState` 的一次性握手字段，
  内容区渲染完成后按优先级定位、滚动、闪烁高亮：
  1. 整行匹配：找与 `lineText` 完全相等的行，多行相等取行号最接近 `lineNumber` 的，行内套 `matchRangeInLine`；
  2. query 降级：整行 miss（搜索之后又改了显示选项，或成员排序与语料不同）时按同规则找 `query`，取行号最接近的一处；
  3. 完全 miss：只跳到对象，find bar 预填 query，提示「命中内容受当前 Generation Options 影响未显示」。
  `ContentTextViewModel` 加一个 `highlightRequest` 输出。NSTextView 路径：`scrollRangeToVisible` +
  `showFindIndicator(for:)`。SourceEditor 路径：实现桥的 `scrollToCharacterIndex(_:)`（今天是 TODO）并加高亮——
  该模块的动工前提已满足：dump 在 `/Volumes/RE/SourceEditor/Xcode/26.6/` 与 `27.0/`，`ObjCHeaders` 与
  `SwiftInterfaces` 都齐；行为事实按 AGENTS.md「SourceEditor Module」的顺序建立（资源 → dump → 反编译 → 运行时探针）。
- 语料构建期间搜索：store 返回已建部分 + summary 报告缺口，UI 呈现覆盖率，不阻塞。
- **落地形态（2026-09-29）**：查询与结果的状态放在 per-document 的 `FindSession`（`DocumentState.findSession`），
  两层侧栏各自的 `FindViewModel<Route>` 只是它的适配器——ViewModel 的 router 是各自层级的 coordinator，会随
  push / pop 销毁，所以状态不能住在 ViewModel 里。语料协调器叫 `FindCorpusCoordinator`
  （`DocumentState.findCorpusCoordinator`，Document 打开时唤起）。内容区握手是 `SelectionRoute` 的两个新 case
  `pushHighlighting` / `openInNewTabHighlighting`，把 `ContentHighlightRequest` 挂到
  `DocumentState.pendingContentHighlight`，`ContentTextViewModel` 渲染完成后 `takeContentHighlight(for:)` 取走并按
  优先级链在显示文本里定位，`Output.highlightRange` 交给两个内容 ViewController：NSTextView 路径
  `scrollRangeToVisible` + `setSelectedRange` + `showFindIndicator`；SourceEditor 路径走桥的新方法
  `revealCharacterRange(_:)`。完全 miss 时只跳到对象，**没有做**「find bar 预填 query + 提示」那一档降级（决策日志）。
- **SourceEditor 桥的证据**：按 dump（`/Volumes/RE/SourceEditor/Xcode/26.6/`，27.0 一致）给 stub 补了
  `ScrollPlacement`（九个 case 按声明顺序）、`SourceEditorView.selectTextRange(_:scrollPlacement:alwaysScroll:)`（dispatch
  thunk）、`showCallout(for:)`（dispatch thunk）、`SourceEditorDataSource.positionFromInternalCharOffset(_:lineHint:)`
  （只有直接符号，声明为 `final`）。`positionFromInternalCharOffset` 正是桥里 `characterIndex(of:in:)` 所用的
  `characterRangeForLineRange` 的逆运算（同一内部偏移空间）；负的 `lineHint` 会 trap，传 0。反汇编（26.6 `0x3E3900`）
  显示 `showCallout` 不滚动，只解折叠 + 弹 callout 动画，所以先 `selectTextRange(…, scrollPlacement: .center,
  alwaysScroll: true)` 再 `showCallout`——Xcode 自己的 `SourceCodeEditor.select(_:scrollToSelection:)` 也是这两步
  （它用 `.optimal`）。七个新符号写进 `UsedSymbols.txt`，`Generate.sh` 重生成 `.tbd`（diff 两行）。

#### 4.1 面板布局：照 Xcode 26 Find navigator 的 view hierarchy

来源：用户 2026-09-29 从 Xcode 26.6（深色外观）导出的 `Xcode26-FindNavigator.viewhierarchy`，两份快照——空状态（宽 537）
与带 1704 条结果（宽 395.5）。下面的坐标是 flipped 坐标（原点左上），`W` 为面板宽。导出文件不入库，量到的数据以本节为准。
自上而下四块：

| 块 | 高 | Xcode 的实现 | 我们的实现 |
|----|----|-------------|-----------|
| 查询参数区 | 72，三行各 24 | `DVTStackView_ML`，三个固定高的行容器，frame 布局 | `VStackView`，三行各 24 |
| 结果摘要条 | 22，**只在有结果时存在** | `NSTextField` + 底部 1pt `DVTBorderView` | `Label` + 1pt 分隔线 |
| 结果列表 | 填满 | `DVTScrollView`（无边框、不画背景、上下各 1pt 分隔线）+ `IDEFindNavigatorOutlineView` | `ScrollView` + `StatefulOutlineView`，`rx.nodes` |
| 底部 Filter 栏 | 44 | `IDENavigatorSearchFilterControlBar` | 沿用侧栏 filter 栏的容器，只放一个搜索框 |

**第一行（y 0–24）**：模式路径控件 `NSPathControl`，容器 frame `(3, 3, W−39, 17)`，`controlSize = .small`、字号 11，三个
组件 Find ▸ Text ▸ Containing。我们的三个组件：`Find`（单项，无菜单）▸ 模式 `Text / Regular Expression / Ancestor Types /
Descendant Types / Conforming Types / Members` ▸ 第三组件按模式：Text 是 `Containing / Matching Word / Starting With /
Ending With`，Members 是种类 `Any Member / ObjC Property / ObjC Method / ObjC Ivar / Swift Field / Swift Function /
Swift Variable / Swift Subscript / Swift Initializer`，其余模式没有第三组件。右侧「Aa」大小写切换：`NSButton`
frame `(W−29, 3, 21, 16)`，title `Aa`、toolTip `Case Sensitive`、`.pushOnPushOff`、`bezelStyle = .smallSquare`、
**`isBordered = false`**、字号 11、居中；on 时 `contentTintColor = .controlAccentColor`，off 时 `.secondaryLabelColor`
（导出里看不到 on 态的绘制，这是假设）。

**第二行（y 24–48）**：`NSSearchField` frame `(7, 1, W−14, 22)`，`controlSize = .small`、字号 11、
`sendsWholeSearchString = true`（**按 Return 才搜，不是逐字符**，与 Xcode 一致；设计稿里的 300 ms debounce 作废），
placeholder 随模式变：`Text` / `Regular Expression` / `Type Name`（三种关系）/ `Member Name`。Xcode 的类是
`IDEProgressSearchField`：搜索或语料构建进行中时在框内右侧转小菊花，我们同样做（覆盖率不足时 tooltip 写明还在建哪个镜像）。

**第三行（y 48–72）**：范围容器 `(2, 0, W−4, 24)`，里面一个 **无边框** `NSPopUpButton` frame `(0, 5, 98, 15)`，
`controlSize = .small`、字号 11、`bezelStyle = .regularSquare`、`isBordered = false`、`arrowPosition = .arrowAtBottom`、
`pullsDown = false`，title `In Workspace`。我们只有一项 `In Indexed Images`（范围固定，见「不做」），保留这一行是给
将来的范围档留位置。

**结果摘要条（y 72–94）**：`Label` frame `(10, 4, W−20, 14)`，系统字体 11 regular，颜色用 `secondaryLabelColor`
（Xcode 是 DVTUserInterfaceKit 的 `parameterTextColor`，灰度 0.57），截尾；文案 `N results in M files` → 我们
`N results in M types`（关系模式 `N types`）。底边 1pt `separatorColor`。

**结果列表**：`NSOutlineView` 设置——`selectionHighlightStyle = .sourceList`、背景透明（Xcode 是
`_sourceListBackgroundColor`，我们的侧栏本来就在玻璃上）、`indentationPerLevel = 14`、`intercellSpacing = (3, 0)`、
`indentationMarkerFollowsCell`、`floatsGroupRows`、`allowsMultipleSelection`、`allowsTypeSelect`、无表头、单列、
`columnAutoresizingStyle = .lastColumnOnly`、`rowHeight` 默认 17 但行高按 cell 自适应；滚动视图 `borderType = .noBorder`、
`drawsBackground = false`、只有竖向滚动条、自动隐藏。

- **一级行（类型 / 文件，高 22）**：disclosure 按钮 frame `(12, 0, 13, 22)`；cell 起点 x = 27，宽 `W − 27 − 16`；
  cell 内图标 16×16 在 `(0, 3)`（Xcode 是文件类型图标，我们用 `RuntimeObjectIcon` 的类型图标），文字 frame
  `(19, 3, cellW − 23, 16)`，字号 13 regular、`labelColor`、截尾；内容是主名 + 次要文字（Xcode：`Package.swift`
  + 所在 group；我们：类型 `displayName` + 镜像名，次要部分 `secondaryLabelColor`）。
- **二级行（命中，高 22 或 38）**：cell 起点 x = 41（多一级缩进 14），无 disclosure；图标 16×16 在 `(0, 3)`、
  `alphaValue = 0.45`（Xcode 是三横线的圆角方块，我们用 SF Symbol `text.alignleft`）；文字 frame `(19, 3, cellW − 23, 16 或 32)`，
  字号 13、**按词换行、最多两行、`truncatesLastVisibleLine`**，两行时行高 38；命中片段按 `matchRangeInLine` 用
  semibold 强调。关系模式的树没有二级「命中行」，每一级都是类型行（带 disclosure）；成员模式的二级行是成员声明。
- 选中行由 source-list 样式自己画（`NSTableRowSidebarSelectionView`，左右各缩 10pt），不自定义。

**底部 Filter 栏（44）**：`NSSearchField` frame `(8, 8, W−16, 28)`，`controlSize = .large`、字号 13、placeholder
`Filter`、toolTip `Show results with matching text`、`sendsWholeSearchString = false`（逐字符）、单行；对**已显示的结果**
按文本做包含过滤，不重新发请求。

Xcode 顶部的导航器选择条（`IDETwoLevelChooserView`，28pt）对应我们侧栏已有的分页条，不另做。

### 5. 验证

- **Core**（`RuntimeViewerCoreTests`，真实系统框架 fixture，锚在 `NSObject` / `NSString` / `NSCoding` 一类稳定符号）：
  语料构建 / 驱逐 / 重建；failed 语义（抛错 → failed、触发源重排队、单对象失败跳过计数）；文本匹配（大小写、五种匹配
  方式、四档域按映射表、行号 / snippet / range）；成员（六类各至少一条、static 区分、行号对齐与对不上时为空）；
  关系（父类链、协议 refine 两张新表、传递子类去重、`isResolved`）；取消（引用计数：双订阅单退订不取消）；
  limit / truncated（真实总数继续计数）；LRU 驱逐；远程 dispatch 形态（local 覆盖协议面即可）。
  搜索与构建加 signpost，搜索延迟基线（AppKit + SwiftUI 级 < 100 ms）进 perf 清单。
- **Application**（`RuntimeViewerApplicationTests`，按 0016 的约定）：`FindViewModel` 契约；
  `GlobalSearchCorpusCoordinator` 的四个触发源与 off / on；`ContentTextViewModel` 的定位优先级链。
- **App**：`RunScript.sh` 编译通过；NSTextView 与 SourceEditor 两种编辑器下各跳一次；跨镜像结果跳转；
  `SettingsPersistenceTests` 全过。

**落地的测试（2026-09-29）**：Core 三个纯逻辑套件（matcher 8、locator 3、store 10）与 `RuntimeInterfaceSearchTests`
7 条（Foundation 语料 ~50 s）；Application 侧 `ContentHighlightRequestTests` 5、`ContentTextHighlightTests` 2、
`FindCorpusCoordinatorTests` 3、`FindViewModelTests` 11；`SettingsPersistenceTests` 覆盖表加了 `search`。

**验证结果（2026-09-29，`feature/find-navigator`）**：`RuntimeViewerApplicationTests` 全量 254 条 / 45 套件与
`RuntimeViewerSettingsTests` 22 条 / 6 套件全部通过（按原始退出码判定）；Core 回归集 84 条通过，只剩
`RelationshipsEquivalenceSnapshotTests` 那两处在干净 `next` 上同样重现的不一致（见决策日志）；`RunScript.sh --no-launch`
整 App 构建通过（Xcode 27.0，`RUNTIME_VIEWER_ALLOW_MISMATCHED_CATALYST_HELPER=YES`）。**§5「App」的三项交互验证未做**：
NSTextView 与 SourceEditor 两种编辑器下各跳一次、跨镜像结果跳转，都要在真实 App 里点一遍，留给用户。

**用户实测发现语料库从未构建（2026-09-29）**：上面落地的 `FindCorpusCoordinatorTests` 只有三条，都不经过后台索引的事件，
而 §5 要求的是四个触发源。补上的回归测试：`FindCorpusCoordinatorTests.backgroundIndexedImageBecomesSearchable`（两个协调器
同时在场，后台索引一个镜像后可被搜到，修复前 4/4 红、修复后 5/5 绿），以及 Core 的
`RuntimeBackgroundIndexingManagerTests.everySubscriberReceivesEveryEvent` / `subscriberArrivingMidBatchFirstReceivesThatBatch`。
排查经过见 [ResolvedIssues/2026-09-29-find-corpus-never-built-indexing-events-split](../ResolvedIssues/2026-09-29-find-corpus-never-built-indexing-events-split.md)。

**用户实测搜到了被 strip 的内容（2026-09-29）**：语料固定按 `.mcp`（strip 全关）打印，成员表直接列出 ObjC metadata 的
全部 ivar 与方法，所以内容区隐藏掉的合成 ivar、合成 getter / setter 照样能搜到。回归测试：

- `FindGenerationOptionsTests.searchesFollowTheGenerationOptions`（App 层，先写、先确认变红）：以 `NSURLQueryItem`
  为锚，测试专用的 `appDefaults` 打开合成 ivar 与合成方法两个 strip 开关后，文本搜 `_value`、成员搜 `value` 都不应命中
  被 strip 的 ivar 与 getter，属性本身仍能命中，每条文本结果的行都是内容区显示的行；关掉开关后不重建语料就能搜到。
  修复前 14 处失败——被 strip 的 ivar 被文本搜到、ivar 与 getter 被成员搜到、11 条结果的行带着内容区没显示的注释；
  修复后通过。
- `RuntimeInterfaceCorpusVisibilityTests`（Core 层）：libobjc 与 Foundation 的全部 ObjC / C 条目和四分之一的 Swift
  条目，在默认、全部显示、strip 与细节全开（用户的设置）、混合四组选项下，「语料条目按选项投影」与「引擎按同一组
  选项给内容区打印的 interface」完全相等（文本、span、identifier）。四组选项都按分类排序 Swift 成员，因为语料如此。
- 上游各自的对照测试：swift-semantic-string `VisibilityRegionTests`、MachOObjCSection `ObjCMarkedInterfaceTests`、
  MachOSwiftSection `VisibilityRegionProjectionTests`，见各自的设计记录与提案。

`FindSession` 在 Generation Options 变化时重跑正在显示的文本 / 成员搜索，结果列表不会停在旧选项下。

### 6. 交付顺序

1. PR-0：Frozen 存储边界（§0）。
2. PR-1（Core）：store + 旁路打印 + 五个请求 + 两张新表 + 单测。
3. PR-2（App）：coordinator + Settings + `FindViewModel` + 面板（照 hierarchy）+ 跳转与定位 + SourceEditor 桥。
4. 提案落地时编号，与 PR-2 同批次置为 Implemented。

### 不做

- 语料落盘（注释里的地址是 per-run 的，落盘要先剔除地址列或按 slide 归一化）。
- CLI / MCP 命令（请求层已 CLI / MCP-ready，命令本身归《无头 RuntimeViewer》下一篇）。
- 「当前镜像」范围档：设计稿的范围就是全部已索引镜像，覆盖率 UI 负责说明还没建的部分。
- Conforming Types 经 refining 协议的传递 conformer；跨进程搜索的 batching / caching；iOS 版。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-29 | Created as Draft | 用户：「实现一个查找(Find)功能：1. 查找任何文本，用文本匹配；2. 查找关系，例如 Xcode 里的 Ancestor / Descendant / Conforming Types；3. 查找成员，ObjC Property、Methods、Swift Field、Function、Variable、Subscript」。UI 不由本提案设计，用户提供 Xcode 的 view hierarchy。 |
| 2026-09-29 | 文本搜索按 `feature/interface-corpus-probe` 的设计稿实现 | 用户：「我有个分支专门讨论过文本搜索的，按照那个实现」。设计稿的四条开放项里：面板形态由用户的 hierarchy 决定；构建并发度先串行；Settings 开关默认开；驻留上限 256 MB、transformer debounce 2 s 先按稿定，Phase 1 落地后按实测调。 |
| 2026-09-29 | 成员搜索走 section 里的结构，不从文本反推 | 用户：「查找成员，就要深入 ObjC/Swift Section 里面的结构，例如 ObjC 的各种 info，Swift 的 TypeDefinition，Indexer 应该能够获取到」。Swift 成员的惰性索引只有打印触发，所以成员表与语料同一趟构建。 |
| 2026-09-29 | 关系语义仿 Xcode 的传递闭包（假设，未问） | UI 照 Xcode，语义也照 Xcode；只做一层的话比现有 Inspector 强不了多少。代价是两张协议 refine 表。 |
| 2026-09-29 | Regular Expression 纳入 v1（偏离设计稿的 Phase 3） | Xcode 的模式列表里有它；`text` 是现成 `String`，逐条目跑 `Regex` 即可，成本不在实现而在 UI 位置，而 UI 位置由 hierarchy 给定。 |
| 2026-09-29 | 范围固定为全部已索引镜像，不加「当前镜像」档 | 设计稿即如此；关系模式本来就跨镜像；覆盖率 UI 已经解释「为什么某镜像搜不到」。 |
| 2026-09-29 | Frozen 存储边界作为前置 PR 单独合 | 分支落后 `next` 402 个提交，直接 merge 会在 `RuntimeObjectInterface.swift` 冲突；边界改动独立成立（XPC 载荷缩小），先合掉也让本提案的 diff 只剩搜索本身。 |
| 2026-09-29 | SourceEditor 行定位纳入 v1 | dump（Xcode 26.6 与 27.0）在盘上，满足该模块动工前提；不做的话 SourceEditor 模式下点结果只能跳到类型顶部。 |
| 2026-09-29 | 二次定位完全 miss 时只跳到对象，不做 find bar 预填与提示 | `NSTextFinder` 没有公开的「预填搜索串并展示」入口；SourceEditor 那边的 find 面板更没有。miss 只发生在显示选项把命中行整段隐藏时，先留着，用户反馈后再补。 |
| 2026-09-29 | UI 照用户导出的 Xcode 26 Find navigator view hierarchy 量化实现（§4.1） | 用户：「具体的 UI 不用你设计，我会给你 Xcode 的 viewHierarchy，你照着实现就行了」。随之而来的三个偏离设计稿的点：搜索由 Return 触发（`sendsWholeSearchString`），不做 300 ms debounce；Find 分页在两层侧栏各放一个、共用一个 ViewModel（假设）；范围弹出按钮只有 `In Indexed Images` 一项（假设，为将来范围档留位）。 |
| 2026-09-29 | Draft → Accepted | 用户：「ok」。按 §6 的三个 PR 顺序实施。 |
| 2026-09-29 | PR-0 只取分支上的 `606bf8f8`、`388dd212` 两个提交 | 中间那个 `c8bd6a15`（`compacted()`）依赖的 API 在当前 pin 的 swift-semantic-string 里已不存在，被 `frozen()` 取代。`next` 上多出的消费点（`ContentTextViewModel`、SourceEditor 的 `enumerate`、一条管线测试）改用 `enumerateSpans` / Frozen 类型。 |
| 2026-09-29 | 包级 `swift build` 一律带 `USING_LOCAL_DEPENDENCIES=1`，且 `.worktrees/` 补上 `swift-capstone`、`capstone` 两条链接 | `RuntimeViewerPackages/Package.resolved` 钉的 MachOSwiftSection 早于 `next` 的 Core 所需（`ObjCImplementationClasses`），远程解析本来就编不过；本地 MachOSwiftSection 又要 swift-capstone 6 的 `AARCH64` trait，没链接时回落到远程旧版报 trait 不存在。构建前删掉锁文件、构建后还原，锁文件不入库。 |
| 2026-09-29 | Swift 侧语料用独立的第二个 `SwiftDeclarationPrinter` 实例 | 显示路径的 `updateConfiguration` 会在打印挂起期间改写共享 printer 的配置；语料 printer 按 `.mcp` 选项 + 用户 transformer 配置，transformer 变了才重建，且永远不写 `interfaceByObject`。 |
| 2026-09-29 | 成员行号对齐：ObjC selector 的片段是不带冒号打印的 | 实测 Foundation：修正前 10457 个 ObjC 方法只对上 3758 个；按「片段用冒号连接再补尾冒号」注册键后对上 10453 个（4 个未对上）。属性、Swift field / enum case / function / variable 全部对上。 |
| 2026-09-29 | 关系树的 visited 集合按路径而非按整棵树 | 按整棵树去重时 `NSObject` 协议在 `NSItemProviderReading` 下出现过一次，`NSObject` 类那一级就再也不列它，看起来像 NSObject 什么都不采纳。按路径只防环，同一协议可在多个层级下重复出现，与 Xcode 一致。 |
| 2026-09-29 | `RelationshipsEquivalenceSnapshotTests` 的两处不一致（`__C.Decimal` → `__C.NSDecimal`、NSObject 少一个 `_DefaultScopeRegistration` 桥接子类）**不是本提案的回归** | 在一个临时的干净 `next` 检出（`92bff04a`）上用同样的本地依赖跑同一套件，两条不一致一字不差地重现；是本地 MachOSwiftSection checkout（`5552b074`）相对快照基线的差异，快照的更新归上游 pin 变更那一批，本提案不动它。 |
| 2026-09-29 | App 侧只做到编译通过与包内测试，交互式 UI 验证留给用户 | 未获授权启动 App 做交互验证；侧栏 Find 分页、⇧⌘F、两种编辑器的行定位与 callout、跨镜像跳转都没有在真实窗口里点过。 |
| 2026-09-29 | Accepted → In Progress | 三个 PR 的代码与提案已按 PR-0 补丁 / PR-1（Core）/ PR-2（App）/ 提案 分四个提交落在 `feature/find-navigator`，未推送、未合入 `next`；编号与 Implemented 留到落地那一批。 |
| 2026-09-29 | 后台索引事件改为广播：`RuntimeBackgroundIndexingManager.events` 每次访问是一条独立订阅，新订阅者先收到进行中批次的快照；`FindCorpusCoordinator` 先订阅再补建已索引镜像 | 用户实测：5 个镜像索引完成后搜 `view`，得到「0 results in 0 types · 5 images not yet searchable」。`events` 原本是交给每个调用者的同一条 `AsyncStream`，多个读者时每个元素只交给一个；触发源 1 让 Find 协调器成了每个文档的第二个读者，和索引协调器轮流瓜分事件，Find 一个 `taskFinished` 都没拿到。另一个方案是只让索引协调器读、再转给 Find，被否决：它修不了多窗口共用一个引擎时同样的瓜分（`main` 上就有），还会把两个按设计互相独立的协调器绑在一起。 |
| 2026-09-29 | 推翻「canonical 选项」：语料改为标记模式打印一次全量、按可见性区域在搜索时投影；只有 transformer 触发重建 | 用户：「目前能搜索到被printer strip的内容，比如objc的ivar，合成的getter/setter」。先提出的「语料跟随显示选项、改开关就重建」被否：「我不想更改options就重新生成语料，语料要为所有可能出现的内容进行索引，但是只输出匹配当前options的内容」。继而提出的「每个选项各打一遍再 diff」也被否：「目前打印2次的方法可能会有性能问题」，且 ObjC 组合 strip 把一组成员删空时容器的标题与空行 diff 叠加还原不出来。按用户要求交给另一个会话独立设计后比较，两边都收敛到「打印器在输出时标出归属」，取对方的整体结构与本方核实的两点（`infersObjCOverridesFromSelectorNames` 是替换而非超集、区域表不进 Frozen 的存储与编码格式）。实现时把标记放在原子的 `identifier` 上而不插入标记原子，打印文本逐字节不变。用户：「可以改，上游都是我自己的库，写提案直接开工吧」。 |
| 2026-09-29 | `synthesizeOpaqueType` 不重建 | 用户：「synthesizeOpaqueType可以不重建吧，它输出的结果是固定的，只是要改的地方是返回值」。核实：关掉时 `printOpaqueReturnType` 只写 `some`，打开时再写 ` <约束>`，是纯删减。 |
| 2026-09-29 | `memberSortOrder` 不处理 | 它是重排，区域表达不了；结果列表不显示行号，内容区定位先按整行文本，只影响同一类型内结果的先后。 |
| 2026-09-29 | 实现：标记写在原子的 `identifier` 上，不插入成对的标记原子；装饰的显隐由容器传递 | 标记原子会穿过所有容器、干扰「看末原子」一类判断（如 `DeclarationBlock` 决定是否补换行），而改写 `identifier` 让标记模式的文本与「全部显示」逐字节相同。投影起初靠「删掉因删除而变空的行」还原容器排版，随机测试很快找到反例（整组被删时组间空行、多行区域），改为让 swift-semantic-string 的容器把成员的条件带到自己打的换行、分隔符与前后缀上，投影只删区域。详见 swift-semantic-string `docs/VisibilityRegions.md`。 |
| 2026-09-29 | `FindSession` 在 Generation Options 变化时重跑当前的文本 / 成员搜索 | 搜索结果是按运行时的选项投影的；不重跑的话，改了选项后列表仍是旧选项下的结果，正是这次要消除的「看到的与搜到的不一致」。关系搜索不依赖这些选项，不重跑。 |
| 2026-09-29 | 三个上游未发版期间，RuntimeViewer 用 SwiftPM edit 模式编进它们的 `feature/visibility-regions` | `.worktrees/` 下的依赖链接被其它会话共用，不能改；edit 模式的状态只落在自己的 scratch。发版后按分支规则抬 `exact:` pin，与抬 pin 同批合入。 |
| 2026-09-30 | 全量回归（三个上游经 edit 模式编入） | RuntimeViewerCore 349 个测试 3 处失败，与改动前那次全量回归逐条相同：`RuntimeMemberDeclarationLocatorTests` 的 ObjC 夹具 2 处（选择子片段仍带冒号，本分支原有），`RelationshipsEquivalenceSnapshotTests` 的 Swift 快照 1 处（`__C.Decimal.FormatStyle` 如今读作 `__C.NSDecimal.FormatStyle`，差异与改动前逐字相同）。RuntimeViewerPackages 全部通过。新增的 `RuntimeInterfaceCorpusVisibilityTests` 与 `FindGenerationOptionsTests` 均通过。 |
| 2026-09-30 | 不等上游发版：三个上游的 `feature/visibility-regions` 合入各自的 `next`，本分支合入 RuntimeViewer 的 `next`；状态仍为 In Progress | 用户：「合并吧，MachOKit那边完工了」。MachOKit 的重构已完成并发布 0.53.101，MachOObjCSection 与 MachOSwiftSection 的 `next` 随之稳定，两条 feature 分支 rebase 上去无冲突，各自在本地依赖下重跑通过后合入（swift-semantic-string 的 `next` 未动，直接合入）。此后 RuntimeViewer 以 `USING_LOCAL_DEPENDENCIES=1` 构建即可，edit 模式不再需要。更正上一行：本包的远程依赖跟随各上游的 `next` 分支，不是 `exact:` pin，上游 `next` 推送后远程解析也能拿到；但 MachOObjCSection 与 MachOSwiftSection 的 `next` 要求 swift-semantic-string `from: "0.3.0"`，那个版本没有 `VisibilityRegion`，它们自己的远程构建要等 swift-semantic-string 发版并抬下限。用户仍在实测中发现问题，交互验证未完，所以状态不改。 |
| 2026-09-30 | swift-semantic-string 发布 0.4.0，MachOObjCSection / MachOSwiftSection 把它的下限抬到 0.4.0，四个仓库的 `next` 全部推送 | 用户：「可以，推送然后发版吧」。上一行说的远程构建缺口就此补上：两个上游在纯远程依赖下构建、测试通过后才推送。本仓库的远程依赖跟随各上游的 `next`，但 workspace 与包的 `Package.resolved` 仍钉着合并前的 revision，默认（不开本地依赖）构建要先用 `UpdatePackagesScript.sh` 刷新锁文件。 |
| 2026-09-30 | 退回 `feature/find-navigator`，不进 3.0.0：`next` reset 到合并前的 `92bff04a` 并强推，分支前进到 `8319f55b`（两条修复 + 上游发版记录） | 用户：「这些改动有点大，把 Find 以及后续功能都放回原来的分支吧，next 分支 reset 回去，不打算 3.0.0 版本发布这个功能」。合并提交没有夹带任何冲突解决编辑（`git diff 94316dd8 ace19d3a` 为空），reset 不丢东西。 |
| 2026-09-30 | 「只索引到 1 个 image、另外 4 个不能搜」不是事件瓜分的复发，是 4 个语料库在串行排队且无处可见 | 对运行中的服务进程采样：正停在 `RuntimeInterfaceCorpusStore.run` 逐对象打印；5 个批次全进了 History，说明事件已全部送达。libswiftCore 最先索引完所以最先建成。 |
| 2026-09-30 | 性能范围：记忆化 + 判别符缓存（上游）、跳过嵌套重复 + 并行打印（Core）；不做落盘缓存与优先级切换；状态展示另开 Report navigator 提案 | 用户在提问轮选定。采样证据与嵌套重复见 §1.1。 |
| 2026-09-30 | 动手前先用 `CorpusBuildTimingProbe` 量 Release 下每镜像、每选项的耗时 | 「没有一条能变红的命令就不许猜原因」同样适用于性能：Debug 采样只给结构，比例要在 Release 下量。 |
| 2026-09-30 | §1.1 按独立审查修订：第 1 条重做（B / D 二选一、由 probe 数字定，并修父子同名成员的定位缺陷）；第 2 条补 Swift actor 上的串行尾巴与 QoS 待定；第 3 条补「已排队再请求也前移」；第 4 条复用重跑 guard | 审查指出把嵌套类型的扩展补在父条目后面会让命中行号落在父对象内容区之外，与本节自己的约束矛盾；`.utility` 与「用上性能核」自相矛盾；定位器对父对象文本里排在前面的嵌套声明今天就会分错行。 |
| 2026-10-01 | §1.1 开工，先 rebase 到本地 `next`（`9ca0d5a6`）；上游两份提案交给 MachOSwiftSection 那边的会话 | 用户：「开始实现提案，MachOSwiftSection的更改可以和 MachOSwiftSection-FindNavigator 这个agent说」，随后「你可以先rebase一下next分支」。唯一冲突在 `RuntimeSwiftInterfaceIndexer.swift`：`next` 的 `d300bafd`（C 导入类型的索引配置固定）删了 `updateConfiguration` 转发，本分支在同一处加了关系查询，两边都留。 |
| 2026-10-01 | 计时 probe 重写，等用户同意再跑 | 旧 worktree 删除时未提交的 probe 一并丢失。自己写的程序先给用户看再运行（全局规则）。 |
| 2026-10-01 | 嵌套块区间按 B 的取法先落地，不等 probe | 定位修复两条路都要这个区间，文本搜索跳过嵌套块也是 B、D 共有；probe 只决定是否再做 D 省打印的那一半。复现测试 `RuntimeInterfaceCorpusNestingTests`（Foundation）：`PersonNameComponents.FormatStyle` 的字段 `style` 落在嵌套 `CodingKeys` 的 `case style` 行上；全镜像 1183 / 16317 个 Swift 成员落在嵌套类型的行上；`var parseStrategy` 被父子各报一次。修复前 4 条全红，修复后全绿，另加「嵌套块全部找到」的覆盖测试。 |
| 2026-10-01 | 协议的自身定义截到第一个顶格 `extension` 之前 | 覆盖测试只差 `__C.NSNotificationCenter` 的 2 个嵌套协议：没有父类型定义的协议，打印器把默认实现接在协议后面打印，嵌在别的模块类型的扩展里时这段落在第 0 列、而且在外层扩展的大括号里，加缩进后对不上。截掉后嵌套协议块能找到，第 0 列那段在父条目里仍会多报一次。打印位置本身是 MachOSwiftSection 的问题，转告上游，本提案不修。 |
| 2026-10-01 | 根协议默认实现被打印两三遍：`printedDefinitions` 只在协议有父类型定义时追加 `defaultImplementationExtensions`，扩展表里已挂到协议上的副本（`isAttachedToProtocolDefinition`）不再打印 | 「待核实的同类重复」属实，而且是三遍：打印器对没有父类型定义的协议自己打一遍，`defaultImplementationExtensions` 一遍，MachOSwiftSection 的容器统一把同一批扩展留在扩展表里又一遍。Foundation 上 110 处扩展块重复，修复后 0（测试同上）。`next` 与 `main` 的显示路径是同样写法，内容区也显示多遍，属既有缺陷；本分支的修复在 `printedDefinitions`，显示与语料两条路都受益。 |
| 2026-10-01 | 插队：构建请求加 `isPrioritized`，另加 `PrioritizeInterfaceCorpusRequest` | 第一次请求就带置顶，免得「构建」「插队」两个请求到达 store 的先后不定；已有订阅的镜像只发插队，不加订阅（原文第 3 条）。 |
| 2026-10-01 | 语料状态与合并重搜按第 4 条落地；搜索摘要改报 `scannedImagePaths` | 会话要知道结果读过哪些镜像，才能只补搜没读过的，并且不和搜索进行中建成的镜像重复；`scannedImageCount` 留作计算属性。快照合并规则：本文档有请求在途的镜像保持请求报的状态，其余以 coverage 为准（覆盖掉驱逐后过期的 built）；本文档没看到结束的语料排在历史末尾、按路径排序、不记时间；已建好的语料被再次请求时不带任何进度就返回，不算本文档看到的一次构建。 |
| 2026-10-01 | probe 基线（用户：「能跑」）：嵌套对象占打印时间四成，指向方案 D；展开字段偏移约一成；`.utility` 在争用下被压着跑 | `72913c3d`，Release，JHs-Mac-Studio-Ultra（28 核），每个预设一个进程；同机有其他会话在跑测试（负载 16–55），同一镜像相邻几组可比。Foundation（2559 对象）：语料构建 4.44 s，`display mcp` 3.72 s，只打顶层 2.23 s（嵌套 40%），关掉展开字段偏移 3.33 s（−10.5%），默认选项 3.17 s。SwiftUI（7378 对象）：语料 66.5 s 墙钟 / 48.8 s CPU，`display mcp` 51.95 s，只打顶层 31.15 s（嵌套约 40–45%）。libswiftCore（660 对象）：负载低时各预设 0.82–0.86 s，嵌套 15–22%；语料 10.8 s 墙钟却只有 1.67 s CPU。结论：两个大框架都远超 20% 门槛，按 §1.1 第 1 条应选 D，需要 MachOSwiftSection 另立「嵌套子定义边界标记」提案，待用户定；Debug 采样里 61% 的展开字段偏移在 Release 下只占一成，记忆化有收益但不是大头；`.utility` 在机器忙时会被饿着（M1 Max 上它只有 2 个能效核），QoS 待定那一条有了证据。结果目录 `/Volumes/DerivedData/Agents.noindex/claude/ProbeRuns/`。 |
| 2026-10-01 | 第 2 条先做结构：任务组 + 打印尾巴移出 actor，宽度暂为 1 | 结构本身不依赖上游，而且已经有收益：语料打印不再占着 section actor，用户在建语料时点开同一镜像的类型不用排队。放开宽度会让同一镜像的两个打印同时索引同一个定义，正是上游并发打印提案要修的竞争，所以等它落地。测试：任务组的落位顺序、宽度上限、进度计数（`RuntimeInterfaceCorpusStoreTests`，宽度经 store 的初始化参数注入）。 |
| 2026-10-01 | 写 Generation Options 的测试与「结果是合并而非重跑」的测试取同一把跨套件锁（`withSharedGenerationOptionsLock`，锁本体抽成 `CrossSuiteTestLock`，共享引擎锁也改用它） | 合并测试第一次跑就红了，原因不在产品：`AppDefaults.options` 是 `UserDefaults.standard` 上的 `@UserDefault`，隔离实例只隔离了文件；投影值是对这个键的 KVO，并行套件里 `FindGenerationOptionsTests` 一改选项，这边的会话就按「用户改了选项」整个重跑，Foundation 先占满 1000 条上限，libobjc 的结果没了。另一条路是给每个隔离实例开独立的 `UserDefaults` suite，代价是每个测试环境在 `~/Library/Preferences` 留一个 plist，没走。 |
| 2026-10-01 | `RuntimeMemberDeclarationLocatorTests` 的 ObjC 夹具改成渲染器的真实输出 | 2026-09-30 全量回归里那 2 处失败就是它：定位器早已按「选择子片段不带冒号」改了，夹具还带着冒号。 |
| 2026-09-30 | §1.1 第二轮审查（RuntimeViewer-Opus）：上游并发打印提案提到最前、定位为现存竞争的修复；B 的嵌套块行区间改由子条目文本反查、D 的前提补上多行原子与区域表断言并需要上游标记；建成后不重跑整个搜索、只搜新镜像并合并；插队改为不增订阅的 `prioritize`；串行尾巴补全、任务组宽度定为 `max(2, 核数 / 2)`；定位缺陷用 `CodingKeys` 复现；记下根协议默认实现扩展疑似双打 | 审查指出 B / D / 定位修复都依赖「嵌套块行区间」而原稿没说怎么拿；`run(_:)` 会清空结果列表；协调器对已有订阅直接返回，插队到不了 store；显示与语料两条打印今天已在 actor 外并行。 |
| 2026-10-01 | 语料两处缺陷随 Report navigator 的测试一起修：`FindCorpusCoordinator` 记住列进 history 的镜像，Clear History 之后的 coverage 刷新不再把它们当作别的文档建的列回来；`RuntimeInterfaceCorpusStore` 对引擎的引用由 `unowned` 改为 `weak`，引擎不在时排队的构建按取消结束 | 两处都由 `ReportViewModelTests` 暴露，前者是 Clear History 清不掉，后者是测试进程崩在 `swift_abortRetainUnowned`；原因、回归测试与修前红修后绿的记录见 [draft-report-navigator](draft-report-navigator.md) 的决策日志。 |

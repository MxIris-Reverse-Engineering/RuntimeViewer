# Draft - Find navigator：查找文本、类型关系与成员

- **状态**: In Progress
- **创建日期**: 2026-09-29
- **最后更新**: 2026-10-04
- **所属愿景**: 无（内容区的行定位部分与《自建代码视图引擎》相邻，但本提案不改视图引擎的方向）
- **前置设计**: `feature/interface-corpus-probe` 分支上的
  `Documentations/Plans/2026-07-26-global-search-design.md`（2026-07-27 按
  `Reviews/2026-07-27-global-search-design-review.md` 修订）。文本搜索这一半**原样采用**那份设计，本提案只把它迁进
  提案制、补上与 `next` 分叉后过时的三处，并加上关系与成员两种模式。

## 摘要

仿 Xcode 的 Find navigator，给文档窗口加一个查找面板，三种模式：

1. **文本**——在已索引镜像的全部 interface 正文里做文本匹配（含注释），Containing / Matching Word /
   Starting With / Ending With / Regular Expression，可选大小写与搜索域（全部 / 排除注释 / 仅注释 / 仅符号）。
2. **关系**——输入一个类型名，列出它的 Ancestor Types / Descendent Types / Conforming Types，语义与 Xcode 一致
   （传递闭包，结果成树）；类型名的匹配方式与文本相同的四种，作用在类型自己的名字上（§8）。
3. **成员**——按名字查找 ObjC property / method / ivar，Swift field / function / variable / subscript /
   initializer，匹配方式与文本相同（另加正则），可按种类过滤；数据直接来自 section 里的结构（`ObjCClassInfo` 一族、
   `TypeDefinition` 一族），不从文本反推。

三种模式的范围默认是全部已索引镜像，可以限定到侧栏当前的镜像、当前结果所在的镜像，或在表单里选出的几个镜像。范围按钮
照 Xcode 先弹菜单，菜单最后一项 Custom Scopes… 才打开选镜像的表单（§7、§9）。

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
| `TypeRelationshipsRequest { query, matchMode, isCaseSensitive, relationship: ancestors / descendants / conformers }` | 普通 | — | `[RuntimeRelationshipTree]` |
| `InterfaceCorpusCoverageRequest` | 普通 | — | `[imagePath: BuildState]`，覆盖率 UI 用 |

`Progress` 必须是具名 `Codable` struct，不能是 tuple（审查意见 2）。请求与结果模型放在 `RuntimeViewerCore/Common/`，
命名与 CLI / MCP 的 `--json` 词汇对齐，将来暴露成命令只是机械包装（本提案不做，见「不做」）。

### 3. 三种模式的语义

#### 3.1 文本

- 匹配：对每个条目在 `frozen.text` 的 UTF-8 上做 ASCII case-folding 子串扫描（非 ASCII 字节精确匹配）；span 游标随扫描
  推进，命中时 O(1) 取语义类别做域过滤；行号 / 行文本由命中偏移向两侧找 `\n`。Starting With / Ending With 以标识符
  字符类 `[A-Za-z0-9_$]` 判边界，Matching Word 两侧都判。Regular Expression 模式对每个条目的 `text` 跑
  `NSRegularExpression`（引擎的部署目标早于 Swift `Regex`），`^` / `$` 按行锚定，与 Xcode 的 Find 一致。
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
- 查询：名字按匹配方式匹配（Containing / Matching Word / Starting With / Ending With / 正则，规则与文本模式相同，
  见 §7；2026-10-03 之前只有子串），大小写可选，`kinds` 过滤；`RuntimeMemberMatch { object, member, matchRangeInName }`。
  `resultLimit` / truncated 语义与文本相同。

#### 3.3 关系（Ancestor / Descendent / Conforming Types）

- 输入是类型名：先按名字在全部已索引镜像里解析候选类型（按所选匹配方式匹配类型自己的名字，名字就是查询本身的排前面，
  大小写可选，上限 50 个；2026-10-03 之前是「精确匹配优先，其次子串」，见 §8），每个候选
  各出一棵树 `RuntimeRelationshipTree { root: RuntimeObject; children: [Node]; Node { object, isResolved, children } }`。
  `isResolved == false` 表示该类型不在任何已索引镜像里（例如父类在未索引的框架），只能给名字，不能点击跳转。
- **Ancestor Types**：类 → 整条父类链（逐级嵌套）+ 每一级采纳的协议；协议 → 它 refine 的协议（递归）；
  struct / enum / actor → 采纳的协议（递归到协议的 refine）。
- **Descendent Types**：类 → 全部传递子类（逐级嵌套）；协议 → refine 它的协议（递归）。
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

**第一行（y 0–24）**：模式路径控件，容器 frame `(3, 3, W−39, 17)`，`controlSize = .small`、字号 11，三个组件
Find ▸ Text ▸ Containing。Xcode 用的不是 `NSPathControl`，而是 DVTKit 的 `DVTPathControl`，我们复刻为 `RuntimeViewerUI`
的 `PopUpPathControl`，规格见 §4.2。我们的三个组件：`Find`（无菜单）▸ 模式 `Text / Regular Expression / Ancestor Types /
Descendent Types / Conforming Types / Members` ▸ 第三组件按模式：Text 与三个关系模式是 `Containing / Matching Word /
Starting With / Ending With`，四个模式共用一个选择（§8），Members 是同样四种匹配方式加 `Regular Expression`
（2026-10-03 之前是成员种类，种类挪到了第三行，见 §7），Regular Expression 没有第三组件。右侧「Aa」大小写切换：`NSButton`
frame `(W−29, 3, 21, 16)`，title `Aa`、toolTip `Case Sensitive`、`.pushOnPushOff`、`bezelStyle = .smallSquare`、
**`isBordered = false`**、字号 11、居中；on 时字体加粗、`contentTintColor = .controlAccentColor`，off 时常规字体、不着色
（`-[IDEFindNavigatorQueryParametersController refreshUserInterface:]`，IDEKit `0x198474`）。

**第二行（y 24–48）**：`NSSearchField` frame `(7, 1, W−14, 22)`，`controlSize = .small`、字号 11、
`sendsWholeSearchString = true`（**按 Return 才搜，不是逐字符**，与 Xcode 一致；设计稿里的 300 ms debounce 作废），
placeholder 随模式变：`Text` / `Regular Expression` / `Type Name`（三种关系）/ `Member Name`。Xcode 的类是
`IDEProgressSearchField`：搜索或语料构建进行中时在框内右侧转小菊花，我们同样做（覆盖率不足时 tooltip 写明还在建哪个镜像）。

**第三行（y 48–72）**：范围容器 `(2, 0, W−4, 24)`，里面一个 **无边框** `NSPopUpButton` frame `(0, 5, 98, 15)`，
`controlSize = .small`、字号 11、`bezelStyle = .regularSquare`、`isBordered = false`、`arrowPosition = .arrowAtBottom`、
`pullsDown = false`，title `In Workspace`。我们的范围按钮外观照此，点开的也是菜单（§9）；Members 模式在这一行
右侧另有成员种类的弹出按钮（§7）。

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
  semibold + `labelColor` 强调，其余部分 regular + `secondaryLabelColor`。关系模式的树没有二级「命中行」，每一级都是类型行（带 disclosure）；成员模式的二级行是成员声明。
- 两种行的字体、颜色、图标（含图标尺寸与着色）都集中在 `RuntimeViewerApplication` 的 `FindResultCellStyle`，构建外观的
  `FindResultNode` 和 App 里的 `FindResultCellView` 只引用它。上面的字号与颜色是照 Xcode 定的起点，现行值以那里为准。
  标题跟在图标后面 3pt，图标比文字高时行跟着变高。
- 选中行由 source-list 样式自己画（`NSTableRowSidebarSelectionView`，左右各缩 10pt），不自定义。

**底部 Filter 栏（44）**：`NSSearchField` frame `(8, 8, W−16, 28)`，`controlSize = .large`、字号 13、placeholder
`Filter`、toolTip `Show results with matching text`、`sendsWholeSearchString = false`（逐字符）、单行；对**已显示的结果**
按文本做包含过滤，不重新发请求。

Xcode 顶部的导航器选择条（`IDETwoLevelChooserView`，28pt）对应我们侧栏已有的分页条，不另做。

#### 4.2 模式路径控件：复刻 DVTPathControl（2026-10-03）

Xcode 的模式路径不是 `NSPathControl`：DVTKit 带着一份私有的 `NSPathControl` 拷贝（`_DVTNSPathControl` /
`_DVTNSPathCell` / `_DVTNSPathComponentCell`），在其上派生 `DVTPathControl` / `DVTPathCell` / `DVTPathComponentCell`，全部自绘。
Find 导航器在 `-[IDEFindNavigatorQueryParametersController viewDidLoad]`（IDEKit `0x199130`）里用代码创建它，放进 nib 里的
`_modeRowPathControlContainer`（`{{3, 3}, {208, 17}}`，所在行宽 247），`controlSize = .small`，
`cell.selectsComponentsOneAtATime = YES`（菜单项不带子菜单），其余全是默认值：平直高亮（非胶囊）、`hoverHighlightInsets` 为零、
菜单式呈现（非 popover）、`padsFirstItem = YES`；`drawsActive` 取 `dvt_effectiveIsActive`，导航区没人设 `dvt_activeState`，
所以恒为 YES（DVTUserInterfaceKit `0xE4610`）。

**证据来源**：Xcode 27.0（27A266a）。DVTKit Mach-O UUID `79126E33-3A82-3276-AF4B-CF215007F7B3`，头文件导出在
`/Volumes/RE/Xcode/27.0/DVTKit/`（剥离 override 的版本）与 `/Volumes/RE/Xcode/27.0/SwiftSectionFull-20261002/DVTKit/`（完整版），
IDA 库 `/Volumes/RE/Xcode/27.0/DVTKit.i64`；IDEKit UUID `FA11B07C-9B26-328B-8B0A-C1C4055354C6`，IDA 库
`/Volumes/RE/Xcode/27.0/IDEKit.i64`（本次新建，来源记在同目录 README）。下表地址除注明外都是 DVTKit 内的偏移，伪代码都对照过汇编。

| 规则 | 出处 | 取值 |
|------|------|------|
| 组件宽度 | `-[DVTPathComponentCell cellSizeForBounds:]` `0x337B0`、`-[_DVTNSPathComponentCell _fullWidth]` `0x28E94` | 左边距 + 标题宽 + 右侧箭头槽，按设备像素向外对齐 |
| 左边距 | `_leftDividerWidth` `0x336DC` | 首个组件 7，其余 2（胶囊高亮时 6） |
| 箭头槽 | `_rightDividerWidth` `0x3372C` | 14，最后一个组件也有（胶囊：末项 6、其余 15） |
| 最小宽度 | `_minWidth` `0x3376C`、`+_iconSizeForControlSize:` `0x33E30` | 左边距 + 16（即使没有图标）+ 14 |
| 放不下时 | `-[_DVTNSPathCell _updateSizesForInteriorFrame:]` `0x24440` | 中间组件（首个与末两个之外）从最宽的往下拉平，再缩首个到最小，再缩倒数第二个；末个不缩 |
| 越界 | `-[_DVTNSPathCell rectOfPathComponentCell:withFrame:inView:]` `0x2693C` | 跨过右边缘的那个被裁切，之后的不显示 |
| 绘制顺序 | `-[DVTPathComponentCell drawWithFrame:inView:]` `0x345E4` | 箭头 → 悬停底 → 标题；末个组件只在悬停时画箭头 |
| 悬停底 | `_drawHoveredInFrame:` `0x348E4`、`_highlightHeight` `0x34764` | 覆盖整个组件（含箭头槽），圆角 4，高度不超过 21（small / mini；其余 28），比控件矮时垂直居中 |
| 悬停底颜色 | `-[DVTTheme hoveredScopeControlColor]` DVTUserInterfaceKit `0x67214` → `0x67308` | 深色 5% 白，浅色 5% 黑 |
| 箭头图像 | `_currentDividerImageForControlView:` `0x33930`、`+initialize` `0x32DAC`、`_hoverChevronSymbolConfigWithActiveAndEnabled:demiSized:` `0x338F4` | 平时 `chevron.compact.right`，11pt（`smallSystemFontSize`）；悬停时换成 DVTKit 私有的 `chevrons.popup`，8pt；窗口激活且控件可用时 medium，否则 bold |
| 箭头位置 | `_drawDividerForFrame:inControlView:` `0x33AEC` | 在箭头槽里居中；图像左边不超过「组件左缘 + 左边距 + 16」时不画 |
| 箭头颜色 | 同上 | 深色：激活 `labelColor`，否则 `secondaryLabelColor`；浅色：未激活 `tertiaryLabelColor`，激活时悬停 `labelColor`、不悬停 `secondaryLabelColor` |
| 标题颜色 | `-[DVTPathComponentCell textColor]` `0x335F0`、`-[NSWindow dvt_useActiveAppearance]` DVTCocoaAdditionsKit `0x1660C` | 委托给的颜色优先；否则窗口激活（key / main / 全屏 / panel）`labelColor`，未激活时深色 `secondaryLabelColor`、浅色 `tertiaryLabelColor`；不随控件 enabled 变化 |
| 强调色 | IDEKit `0x19C9FC` 与三个组件类的 `usesAlternateColor` | Replace、Text 以外的类别、Containing 以外的锚定方式画成 `controlAccentColor` |
| 标题 | `drawInteriorWithFrame:inView:` `0x34D18` | 空间不足 3pt 不画；可伸进箭头槽 2pt；纵向 `floor((midY − 高/2) × 缩放) / 缩放`；超出可用宽度 0.9pt 以上则渐隐 |
| 渐隐 | `_drawGradientMaskForTitleRect:` `0x349FC` | 末尾 10pt 从不透明到透明，`destinationIn` 合成，不用省略号 |
| 展开动画 | `-[_DVTNSPathCell _createHoverChangeAnimation]` `0x25F3C`、`animation:didReachProgressMark:` `0x26128` | 被压缩的组件悬停时 0.2 秒内展开到全宽，其余回到压缩宽度；按动画原始进度线性插值 |
| 悬停跟踪 | `-[_DVTNSPathControl updateTrackingAreas]` `0x29860` | 每个组件一块 tracking area，`activeAlways` + `enabledDuringMouseDrag`；路径一变就按指针位置重定悬停组件 |
| 点击 | `-[DVTPathCell trackMouse:inRect:ofView:untilMouseUp:]` `0x30C88` → `_handleClickInComponentCell:…` `0x30A8C` | 按下即弹菜单；右键同样（`-[DVTPathControl rightMouseDown:]` `0x36654`）；不抢焦点 |
| 菜单 | `popUpMenuForComponentCell:inRect:ofView:withMenuItems:` `0x2FA90` | 列出该组件的同级项，字号同控件，`autoenablesItems = NO`；当前项用 `popUpMenuPositioningItem:` 放在 `(组件左缘 − 14 + 2〔无图标〕 + 5〔首个组件〕, 组件中线 − 11)`，标题正好压在组件标题上 |
| 菜单项 | `_menuItemWithItem:additionalItems:currentGroupIdentifier:indentationLevel:` `0x2E35C`、`_popUpMenuItemsForPathCellItems:` `0x2EC1C` | 不设 state（没有勾）；组别变化处插分隔线 |
| 键盘 | `-[DVTPathControl acceptsFirstResponder]` `0x3642C`、`becomeFirstResponder` `0x364E8`、`keyDown:` `0x3634C`、`moveLeft:` … `0x3641C`–`0x36428`、`focusRingMaskBounds` `0x36110` | 只在 Tab / Shift-Tab 移动 key view 时接受焦点（需要全键盘访问）；Tab 进来聚焦首个、Shift-Tab 聚焦末个；←→ 换组件，空格 / 回车 / ↑↓ 弹菜单；焦点环只框当前组件 |
| 辅助功能 | `-[_DVTNSPathCell accessibilityRoleAttribute]` `0x27F14`、`DVTPathComponentCellAccessibilityObject` `0x32684` / `0x32BFC` | 控件是 AXList，每个组件是 AXPopUpButton，值为标题，Press / ShowMenu 弹菜单 |

`DVTPathControl` 另装的点按 / 长按手势识别器（`0x60FDC`）只认直接触摸（Sidecar），鼠标不走它们，不复刻。

**我们的实现**：`RuntimeViewerUI/AppKit/PopUpPathControl.swift`，`Control`（UIFoundation 的 `NSControl` 子类）上整段自绘，规则逐条照上表并
在注释里标出 DVTKit 方法名。模型是 `PopUpPathControl.Component`（标题、可选标题颜色、当前值、菜单项）与 `PopUpPathControl.MenuItem`；
选中菜单项后控件记下 `lastSelection` 并发 action，自己不改路径，由拥有者重设 `components`。与 Xcode 的差别，都是有意的：

- 没有菜单的组件（我们的 `Find`）不悬停、不弹菜单、键盘焦点跳过它，辅助功能里是静态文本。Xcode 的 `Find` 切换 Find / Replace，我们没有 Replace。
- 悬停时的上下箭头用 SF Symbols 的 `chevron.up.chevron.down`（同为 8pt）：`chevrons.popup` 是 DVTKit 的私有资源。
- 悬停跟踪用一块覆盖整个控件的 tracking area 加 `mouseMoved` 按指针位置判定，代替每组件一块：结果相同，不依赖相邻两块 area 的
  进出事件谁先到。菜单关闭后也按指针位置重定一次悬停组件（Xcode 要等下一次鼠标移动）。
- `dvt_useActiveAppearance` 里那个私有的 `hasKeyAppearance` 不查；图标、胶囊高亮、popover 呈现、拖拽、文件代理菜单、RTL、
  常规 / 大号尺寸的专属规则（`usesPseudoLargeControlSize`、大号图标尺寸）都不做——Find 导航器用不到。

Find 页面这边：路径的组成（标题、当前项、哪一项该强调、各组件菜单里列什么）由 `FindModePathComponent.path(for:)`
（`RuntimeViewerApplication/Find/FindModePath.swift`）从查询算出，作为 `FindViewModel.Output.modePath` 输出；三处菜单的选择合成一个
`Input.modePathChoiceSelected`（`FindModePathChoice`），视图控制器用 RxAppKit 的 `rx.click(with: \.lastSelection)` 接控件，
原先的三个 relay 与手写的 `@objc` 菜单代码删掉。控件放在 `(3, 3)`，右缘离「Aa」7pt，与 Xcode 的 `W − 39` 宽一致。

**测试**：`PopUpPathControlTests`（`RuntimeViewerApplicationTests`）从公开接口验证——组件位置读辅助功能元素的 frame，悬停读控件画出来的像素，
菜单经 `menuPresenter`（internal，测试替换它，因为菜单的跟踪循环在测试里跑不起来）；`FindViewModelTests` 加三条 `modePath` 用例。

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

### 7. 搜索范围与成员匹配方式（2026-10-03）

用户实测的两处不便：范围写死为全部已索引镜像，没法只搜某个框架；成员模式只有子串匹配。提问轮定了三件事，另有五条
未问而定的假设（都见决策日志）。

**范围模型**。`FindQuery.scope: FindScope`：`allIndexedImages`（默认）、`currentImage`（侧栏正在列出的镜像，即
`DocumentState.currentImageNode`，搜索时才取值）、`images(Set<String>)`（勾选的一个或多个镜像）。`FindSession.run` 把它
解析成请求的 `imagePaths`：全部为 `nil`；`currentImage` 而侧栏停在镜像列表那一层时不发请求，摘要栏写 `No current image`。
换引擎时范围保留，引擎没有的已选镜像在选择器里标成 `not indexed`（原写「回到全部」，实施时改，见决策日志）。

**范围选择器**。第三行左侧的范围按钮，标题随范围变：`In Indexed Images` / `In Current Image` / `In Foundation` /
`In 3 Images`（多个时 tooltip 列出镜像名）。2026-10-04 起照 Xcode 改为先弹菜单、Custom Scopes… 才打开表单，见 §9；
本节原先的 popover（两个单选行加一列勾选框，改动当场生效）随之撤下，理由见决策日志。两种呈现共有的部分不变：镜像列表 =
引擎的 `indexedImagePathList()`（打开时取一次）∪ 语料协调器知道的镜像 ∪ 范围里已有的镜像，按镜像名排序，可按名字过滤；
每行右侧是语料状态（`waiting` / `building 37%` / `failed`，已建好的不写），跟着
`FindCorpusCoordinator.buildStatesByImagePath` 实时变。行数是百级，cell ViewModel 照常 eager 建。

MVVM-C 的落点：`FindScopeChooserViewModel<Route>` 与镜像行的 `FindScopeImageCellViewModel` 在
`RuntimeViewerApplication/Find/`，`FindScopeChooserViewController<Route>` 在 App。`FindViewModel` 的 `Route` 约束为新协议
`FindNavigatorRoutable`，它的静态要求由两个路由枚举的 case 直接满足（SE-0280）；要求的内容与呈现方式见 §9。

**范围在三类搜索里的含义统一为「结果只来自这些镜像」**：

- 文本 / 成员：`imagePaths` 原样交给引擎——这个参数早就有，原先只用于语料晚建成后的补搜。引擎摘要的
  `unbuiltIndexedImagePaths` 改为只算范围内的镜像；晚建成的语料只有在范围内才补搜；摘要栏的
  「N images being made searchable · building X%」也只算范围内的。补搜那一趟的引擎摘要只覆盖补搜的镜像，所以补搜后
  「还不能搜」的列表改为原列表减去这趟读过的镜像，不再取引擎的值。
- 关系：`RuntimeTypeRelationshipsQuery` 加 `imagePaths`。输入的类型仍在全部已索引镜像里找——否则范围 AppKit 搜
  `NSObject` 的子类会落空，`NSObject` 在 libobjc。树建好后剪枝：不在范围内、下面也没有范围内类型的节点去掉；不在范围内
  但通往范围内类型的中间层保留；剪空的树整棵去掉。
- 范围里语料还没建好的镜像经 `FindCorpusCoordinator.requestBuild(of:isPrioritized: true)` 插队，已在队里的只前移；选定
  范围时与搜索时各做一次。会话经 `follow(_:)` 拿到的协调器做这件事，不自己去创建协调器。

**成员匹配方式**。`RuntimeMemberSearchQuery` 加 `matchMode: RuntimeInterfaceSearchMatchMode`（默认 `.containing`），与文本
搜索同一个枚举。`RuntimeInterfaceTextMatcher.Pattern` 不再绑定 `RuntimeInterfaceSearchQuery`，改为
`init(text:matchMode:isCaseSensitive:)`；成员名与正文用同一个匹配器，取第一处命中，专用的
`memberNameMatchRange(in:query:isCaseSensitive:)` 删除。规则与文本模式完全相同：词内字符只有 `[A-Za-z0-9_$]` 与非 ASCII
字节，不按驼峰拆。所以 ObjC 选择子按 `:` 分段、每段一个词：`Starting With did` 命中
`tableView:didSelectRowAtIndexPath:`，`Matching Word delegate` 不命中 `setDelegate:` 与 `_delegate`。空查询仍然不命中任何
成员；正则写错时整次搜索失败、报在摘要栏，与文本模式相同。

**面板**。Members 模式下路径第三段改为匹配方式：`Containing / Matching Word / Starting With / Ending With`，分隔线后
`Regular Expression`（文本模式的正则仍是第二段里单独的模式，照 Xcode）。成员种类挪到第三行右侧的无边框弹出按钮
（`Any Member ⌄`），只在 Members 模式出现。`FindQuery` 加 `memberMatchStyle`（新枚举 `FindMemberMatchStyle`，比
`FindTextMatchStyle` 多一个 `regularExpression`），与 `textMatchStyle` 分开存，在两个模式间切换不会把正则带进文本模式。
改范围、匹配方式、种类都只改查询，按 Return 才搜，与改模式一致。

**成员行加粗**。结果行在声明文本里找整个成员名，再套上命中范围；多段选择子在声明里被参数类型隔开，找不到就不加粗。
新匹配方式下命中常落在后面几段，改为找命中所在的那一段（连同冒号）。

**测试**（先写，确认改动前是红的）：

- Core：matcher 对成员名的四种方式、正则、多段选择子、大小写，以及命中前有非 ASCII 字符时的 UTF-16 范围；store 的成员
  匹配方式与只算范围内的 `unbuiltIndexedImagePaths`；剪枝的纯函数测试，以及 Foundation 上的引擎测试——范围 Foundation
  搜 `NSObject` 的子类，根仍是 libobjc 的 `NSObject`，其余已解析节点要么在 Foundation、要么下面有 Foundation 的类型，
  libobjc 自己的类不出现。
- Application：`FindViewModelTests` 补匹配方式与种类的编辑、按范围搜索不越界、`currentImage` 为空时的摘要；
  `FindSessionCorpusTests` 补「范围外的语料建成后不并入」；新的 `FindScopeChooserViewModelTests` 覆盖列表、过滤、勾选
  语义、两个单选行与语料状态文字；摘要栏的范围过滤测纯函数。
- App：整 App 构建通过。popover 与第三行的交互验证照旧留给用户。

**不做**：Xcode 的自定义命名范围（规则编辑器）；范围跨文档、跨启动保存；改范围后自动重搜。

**实施记录（2026-10-03）**：

- 按上文落地，三处与方案不同（理由见决策日志）：换引擎时范围**不**回到全部，选择器把引擎没有的已选镜像标成
  `not indexed`；关系搜索有范围时，候选类型里范围内的排在前面，候选上限先花在它们身上；范围按钮是
  `NSPopUpButton` 的子类 `FindScopeButton`，外观仍是 §4.1 量出的无边框弹出按钮，`mouseDown(with:)` 与
  `performClick(_:)` 改为发出动作（打开选择器），菜单里只放标题一项。
- 成员种类的弹出按钮用 RxAppKit 的 `rx.click(with: \.indexOfSelectedItem)` 取值，只在用户选择时发出：两层侧栏各有一个
  Find 分页、共用一个查询，一个绑定时就发出自身当前值的输入，会用这一页的默认值盖掉另一页选好的种类。
- 测试：Core 新增 `RuntimeTypeRelationshipsImageScopeTests`，`RuntimeInterfaceTextMatcherTests` 的成员名用例改为
  13 个参数化用例，`RuntimeInterfaceCorpusStoreTests` 加范围内的「还不能搜」与成员匹配方式（7 个用例），
  `RuntimeInterfaceSearchTests` 加 Foundation 上的关系范围测试；改动前 store 两条与关系一条确认是红的。Application
  新增 `FindScopeChooserViewModelTests`（6）、`FindResultMemberEmphasisTests`（2，后段命中那条改动前是红的），
  `FindViewModelTests` 加 7 条、`FindSessionCorpusTests` 加 3 条。后写的两条会话测试用变异检查确认能变红：去掉补搜时的
  范围交集、去掉改范围时的插队，各自失败；补搜那条第一次没有失败——会话经 `emitOnNextMainActor` 晚一个主线程回合才
  知道语料建好，测试在补搜开始前就检查了结果，加一次 `settleMainQueue()` 后才能抓到。

### 8. 关系模式的匹配方式（2026-10-03）

用户指出 Xcode 的搜索模式都有 Containing / Matching Word / Starting With / Ending With，要求补上；正则照 Xcode 没有。
Xcode 27.0 里查到的事实：

| 事实 | 依据 |
|------|------|
| Text、Ancestor Types、Descendent Types、Conforming Types（以及我们没有的 Symbols、Call Hierarchy）有匹配方式；Regular Expression、Multiple Words 没有 | `IDEFoundation.xcplugindata` 里每个 `Xcode.IDEFoundation.IDEBatchFindConcreteQueryClass` 扩展各自声明 `supportsAnchoring`；IDEKit `-[IDEFindNavigatorQuerySelectorClassComponent childItems]`（`0x19d4e8`）只在它为真时给出第三段 |
| 菜单顺序 Containing、Matching Word、Starting With、Ending With；枚举值 0 Containing、1 Starting With、2 Ending With、3 Matching Word | IDEFoundation `_IDEBatchFindTextAnchoringDisplayOrderedValues`（`0xebe910`）、`IDEBatchFindTextAnchoringToDisplayString`（`0x23d28`） |
| 所有模式共用一个匹配方式，换模式不重置 | IDEKit `-[IDEFindNavigatorQueryParametersController selectQueryAnchoring:]`（`0x19bce8`）只写 `_selectedAnchoring`，`selectQueryExtension:`（`0x19bacc`）不碰它 |
| 类型层级查询把匹配方式锚在符号自己的名字上：Starting With 锚开头、Ending With 锚结尾、Matching Word 两头都锚（即整个名字），Containing 不锚；大小写按 Match Case | IDEFoundation `-[IDEBatchFindQuerySpecification termSymbolsForWorkspace:useQualifiedNameParser:cancelWhen:]`（`0x145e8`）调用 `symbolsContaining:anchorStart:anchorEnd:…`，`anchorStart` 取值 1 或 3、`anchorEnd` 取值 2 或 3 |
| 带容器的查询（`Container.name`）另走一条：容器名精确相等，名字按子串、不分大小写，匹配方式不起作用 | 同一方法里 `IDEIndexQualifiedNameParser` 解析成功的分支；`-[IDEIndexQualifiedNameParser parse:]`（`0x1561a0`）只在标识符后跟 `.` 或 `::` 时成功 |

做法：

- 三个关系模式的路径加第三段，与 Text 共用 `FindQuery.textMatchStyle`，因为 Xcode 也只存一份。Members 仍单独存
  `memberMatchStyle`，因为它多一个正则，共用会把正则带进别的模式（§7 的决定不变）。Regular Expression 照 Xcode 不加。
- `RuntimeTypeRelationshipsQuery` 加 `matchMode`（默认 `.containing`）。规则在
  `RuntimeInterfaceTextMatcher.typeNameMatches(_:pattern:)`：文本搜索的规则（标识符字符 `[A-Za-z0-9_$]` 判边界、ASCII 大小写
  折叠），作用在类型自己的名字上，即限定名的最后一段、去掉泛型实参（`SwiftUI.View` 取 `View`，`Swift.Array<Swift.Int>`
  取 `Array`；尖括号与圆括号里的点不切分，函数类型的 `->` 不算闭括号）。对纯标识符的名字，这与 Xcode 的锚定等价：标识符内部
  没有词边界，Starting With 就是前缀、Ending With 就是后缀、Matching Word 就是整个名字相等；名字带私有判别符时
  （`(Foo in _ABC123)`）也照样能命中 `Foo`。
- 查询里有 `.` 时改为匹配完整限定名，规则相同（Matching Word `Text.Storage` 命中 `SwiftUI.Text.Storage`）。这一处与 Xcode
  不同：Xcode 把查询拆成容器与名字，名字只按子串匹配；我们没有它的符号索引，直接对限定名套匹配方式更简单，匹配方式也照样
  起作用。
- 正则：界面不提供，引擎接口因为共用枚举而接受，对完整限定名匹配（正则自己决定锚在哪）；正则编译失败时 `typeRelationships`
  抛错，与成员搜索一致。
- 排序不变：名字就是查询本身的（类型自己的名字或完整限定名，大小写按开关）排前面，其余按名字排；有范围时范围内的先排（§7）。
- 行为变化：Containing 不再因模块名或外层类型名命中。以前 `UI` 会列出 SwiftUI 的全部类型，现在只列名字里含 `UI` 的。

**测试**：Core 的 `RuntimeInterfaceTextMatcherTests` 加 19 个类型名参数化用例（四种方式、大小写、模块与外层类型不算名字、
带点号的查询、泛型实参与函数类型的箭头、正则）；`RuntimeInterfaceSearchTests` 加 Foundation 上的引擎测试（Matching Word、
Starting With、Ending With、模块名不是类型名、带模块的查询），改动前 Matching Word 与模块名两处断言确认是红的。Application 的
`FindViewModelTests` 加两条：关系模式的路径有第三段并沿用 Text 的选择；关系搜索按匹配方式找起点类型（Matching Word
`NSString` 只出 `NSString` 一棵树）。两条改动前都是红的。结果：Core 的 matcher、search、范围剪枝三个套件 20 个测试通过，
`RuntimeViewerApplicationTests` 312 个测试通过，Debug App 构建通过；没有在运行中的 App 里看过。

### 9. 范围选择改为弹出菜单与表单（2026-10-04）

用户：「Xcode的Scope选择是先PopUpMenu，自定义才sheet弹出编辑框，所以我不要popover效果，viewModel input也不要传View进来」，
附 Xcode 的范围菜单与「Choose a search scope:」表单的截图；方案列给用户后用户回「可以」。Xcode 27.0 IDEKit 里查到的事实：

| 事实 | 依据 |
|------|------|
| 范围按钮是 `NSPopUpButton`，cell 关掉 `usesItemFromMenu`、另设一个标题项，所以按钮上总是「In …」，不随打勾的项变 | `-[IDEFindNavigatorQueryParametersController viewDidLoad]`（`0x199130`）：`setUsesItemFromMenu:NO`、`setMenuItem:` |
| 标题是 `In %@`；范围不是默认的 Workspace 时用 `controlAccentColor`，否则 `controlTextColor` | `refreshUserInterface:`（`0x198474`）、`attributedStringForTitle:control:accented:`（`0x198328`） |
| 菜单每次弹出前重建，再选中（打勾）代表当前范围的那一项；当前范围没有对应项（表单里选出的）时一项都不勾 | `NSPopUpButtonWillPopUpNotification` → `scopePopUpWillPopUp`（`0x19b1ac`）：`rebuildScopeChooserMenu`、`dvt_itemWithRepresentedObject:`、`selectItem:` |
| 菜单顺序：Workspace / Package Dependencies / Workspace and Package Dependencies，分隔线，Current Find Results，（分隔线、「Containing Group(s)」标题、编辑器里那个文件的上级组），（分隔线、「Saved Scopes」标题、已存的范围），分隔线，Custom Scopes… | `rebuildScopeChooserMenu`（`0x19a58c`）、`editorHierarchyScopeItems`（`0x199b4c`） |
| Current Find Results 只在结果区有可见结果时可选，取的是筛选栏筛过之后可见结果所在的文件 | `validateUserInterfaceItem:`（`0x19a520`）、`documentURLsForSubsearch`（`0x19b2a4`，读 `allVisibleResults`）、`createScopeFromCurrentResults:`（`0x19b690`） |
| Custom Scopes… 以表单打开 `IDEFindNavigatorScopeChooserController`，窗口最小 360×480；OK（返回码 1）才把选择交回、成为范围，Cancel 什么都不改 | `manageScopes:`（`0x19b710`）与它的 block（`0x19b7b4`）、`+beginSheetForWorkspaceTabController:initialScope:completionHandler:`（`0x1ab5b4`）与它的 block（`0x1ab780`） |
| 表单的大纲可多选，选中的几项合成一个组合范围；分组行不可选；双击 = 取选中项再 OK；打开时选中并展开当前范围的项 | `exportedPredicateFromOutlineItems:`（`0x1ac028`，`IDEBatchFindScopeChooserCompoundScope`）、`outlineView:shouldSelectItem:`（`0x1ae944`）、`doubleClickedOutline:`（`0x1ac56c`）、`viewDidInstall`（`0x1ab44c`） |

做法：

- **菜单**：`Indexed Images`（默认）、`Current Image (AppKit)`（侧栏没停在镜像上时置灰），分隔线，`Current Find Results`
  （结果区没有可见行时置灰；选它 = 范围改为筛选栏筛过之后可见行所在的镜像，即 `.images(…)`），分隔线，`Custom Scopes…`。
  当前范围那项打勾，表单里选出的范围没有对应项，一项都不勾。菜单模型 `FindScopeMenuItem` / `FindScopeMenuChoice` 由
  `FindViewModel.Output.scopeMenuItems` 给出，页面在每次弹出前（`NSPopUpButton.willPopUpNotification`）按最新的一份重建，
  免得菜单开着时随搜索结果的刷新变动。
- **按钮**：`FindScopeButton` 去掉拦截点击的 `mouseDown(with:)` / `performClick(_:)`，变回真正的弹出按钮；照 Xcode 关掉
  `usesItemFromMenu`、另设标题项，非默认范围时标题用强调色（`FindScope.isAccented`，与模式路径的强调规则一致）。菜单与标题的名字
  同出一处：`FindScope.name`（`Indexed Images` / `Current Image` / `Foundation` / `3 Images`），标题是 `In ` 加它。按钮宽度只跟
  标题项走，菜单里的项再长也不会把它撑宽：AppKit 27.0 的 `-[NSPopUpButtonCell _effectiveSizingBehavior]`（`0x185659880`）在
  `usesItemFromMenu` 关掉时返回 1，自动布局的尺寸（`-[NSPopUpButtonAppearanceBasedVisualProvider
  autolayoutCellSizeWithinSize:coordinateSpace:]`）这时只量 cell 自己的那一项；旧的 `cellSizeForBounds:` 路径同样只在
  `usesItemFromMenu` 开着时才逐项量。
- **表单**：「Choose a search scope:」、过滤框、镜像列表（行选中，⌘ / ⇧ 多选，不再用勾选框；右侧语料状态）、Cancel / OK
  （Esc / Return），最小 360×480。打开时选中范围里已有的镜像（`currentImage` 取侧栏当前的镜像，全部镜像时什么都不选）并滚到第一个；
  OK 或双击一行把选中的镜像写成 `.images(…)` 并关闭，Cancel 只关闭。选择只认用户自己的改动（RxAppKit 的
  `proposedSelection()`，背后是 `tableView(_:selectionIndexesForProposedSelection:)`）；列表因语料进度刷新行时，按 ViewModel
  里的选择重新选行，因为 `rx.items` 的重载按行号保留选中，上方插进一行就会错位。过滤不改选择；用户在过滤后的列表里改选择时，
  以看得见的选中为准，被过滤掉的旧选中随之放下。
- **ViewModel 不收视图**：`FindViewModel.Input.scopeButtonClicked: Signal<NSUIView>` 换成
  `scopeMenuChoiceSelected: Signal<FindScopeMenuChoice>`；`FindNavigatorRoutable` 的要求从 `findScopeChooser(sender:)` 改为无参的
  `findScopeChooser` 与 `dismissFindScopeChooser`，两层侧栏的 coordinator 以 `.presentOnRoot(_, mode: .asSheet)` 呈现、以
  `.dismiss()` 关闭。表单的 ViewModel 收「选中的镜像、OK、Cancel、双击」四个信号。

与 Xcode 的差异：

- 一个都没选时 OK 置灰（Xcode 的 OK 此时能点，但不改范围）。
- 表单的列表覆写 `mouseDown(with:)`，保留 AppKit 的跟踪循环，点一行即成为第一响应者。不覆写时 macOS 27 的手势识别器不给焦点，
  焦点留在过滤框，选中的行一直是非激活的灰色——与 `StatefulOutlineView` 同样的取舍，AppKit 也同样记一条预期内的错误日志。
- 菜单项不带图标；没有 Containing Groups 与 Saved Scopes（见下）。

**不做**：Saved Scopes（命名并保存范围，Xcode 还配了规则编辑器与 New Scope）；Containing Groups（按目录划范围，比如整个
`PrivateFrameworks`）。两者都要给 `FindScope` 加新类型，要的话另起。主窗口工具栏的两个 popover（生成选项、MCP 状态）与侧栏的
Filter Scope 仍把按钮视图经 ViewModel 传给路由，本次不动。

**测试**（先写，对着桩实现跑：12 条新写或改写的测试失败、其余全过；补上实现后全绿）：

- `FindViewModelTests`：默认范围下的菜单（顺序、标题、打勾、可用、分隔线）；选当前镜像（侧栏没有镜像时不生效，有了之后标题带
  镜像名、选中后打勾）；表单选出的范围一项不勾；Current Find Results 取可见行的镜像，筛选栏收窄后只取剩下的；Custom Scopes…
  触发 `findScopeChooser` 且不改范围；按钮标题的强调色。原先「按钮把自己当锚点传给路由」的那条删除。
- `FindScopeChooserViewModelTests`（改写）：列表与初始选中；OK 写范围并关闭、不搜索；Cancel 只关闭；空选择时 OK 置灰、OK 与双击
  都不生效；双击 = OK；全部镜像不选、当前镜像选侧栏的那个；过滤；语料状态文字。原先「勾选框」「单选行」两条随 popover 删除。

结果：上面两个套件 36 个测试通过；`RuntimeViewerApplicationTests` 319 个测试通过（51 个套件）；Debug App 构建通过，改动的
文件没有新警告。没有在运行中的 App 里看过：菜单的样子、表单的布局与点选、焦点，都还要用户实测。

### 不做

- 语料落盘（注释里的地址是 per-run 的，落盘要先剔除地址列或按 slide 归一化）。
- CLI / MCP 命令（请求层已 CLI / MCP-ready，命令本身归《无头 RuntimeViewer》下一篇）。
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
| 2026-10-01 | 上游并发打印（MachOSwiftSection `9f5ffa92`）与记忆化（`937172ef`）的 A/B；打印宽度暂保持 1，方案 D 上游提案已由用户置 Accepted | RV probe corpus 模式，Release，每次新进程，交替运行，除 MSS 与打印宽度外依赖逐项一致。**宽度 14 + 并发打印是负加速**：SwiftUI 串行 40 s（CPU 同），并行在负载 11–16 时 61 s / 约 400 s CPU，负载约 6 时 204 s / 2599 s CPU；Foundation 快 1–3 倍但 CPU 涨 3–7 倍。采样：栈顶 `swift_retain` / `swift_release` 共约 2.6 万个样本，来自 `ExtensionDefinition.runIndexingPass` 的 `_symbol(for:typeName:visitedNodes:)` → `DemanglingNode.first(of:)`——swift-demangling 的 `NodeReference` 每复制一次就 retain 共享的 `NodeStore`，多线程同时遍历时引用计数在核间争抢（MSS 会话已核实，修法另拿给用户）。**宽度 1 三档**（负载 5–9）：next 与并发改动持平（Foundation 4.15–4.27 s，SwiftUI 39.9–40.3 s）；加上记忆化 Foundation 3.80–3.98 s、SwiftUI 36.7–37.9 s，省 7–10%，与展开字段偏移约一成的分项一致。另：同一天负载 18–25 时串行的 Foundation 测出 12.9 s，`.utility` 只分到 0.8 个核——高负载下的单次数字不可比，A/B 要交替跑并记负载。方案 D 的上游草案 `draft-nested-definition-regions`（MSS `e129150b`）用户逐条选了推荐：嵌套协议的默认实现改到顶层 extensions 区块、单独开关 `marksNestedDefinitions`、身份用 mangled name（即 `RuntimeObject.name`）、切片与去缩进放 swift-semantic-string，置 Accepted。原始数据：`/Volumes/DerivedData/Agents.noindex/claude/ProbeRuns/20261001-163445-concurrent-printing/`。 |
| 2026-10-01 | swift-demangling 遍历修复（`d7693c2`，本地 next `e17ae7f`）之后重测打印宽度：建议宽度 `max(1, min(4, 核数 / 2))`，但要等 RV 能解析到含并发打印（MSS `9f5ffa92`）和该修复的版本才改代码，在那之前保持 1 | 交替各两轮、负载 5–7，MSS 固定在 `937172ef`。SwiftUI：修复前宽度 1 为 34–35 s，修复后宽度 1 为 16–17 s，宽度 4 为 6.7–6.8 s（CPU 22 s），宽度 14 为 11.6–12 s（CPU 144–149 s）；Foundation：3.6–3.7 → 3.3 → 1.28 s → 0.84 s；libswiftCore：0.95 → 0.85 → 0.34 → 0.35 s。宽度 4 在三个镜像上都快约 2.5 倍、CPU 只多约三成；宽度 14 在 SwiftUI 上比 4 慢且 CPU 多 6–7 倍，剩下的争用在 MachOSwiftSection 的 `SymbolIndexStore` 经 `SharedCache` 的锁，用户已定以后再修。`.utility` 在 10 核的 M1 Max 上会不会被限在效率核、宽度 4 还剩多少收益，这台 28 核机器上测不出来，换机器时补测。原始数据同上一行的目录（`fix-*`）。 |
| 2026-10-01 | §1.1 第 1 条改为方案 D 落地（叠加分支 `feature/find-navigator-nested-definition-regions`，依赖未合入的上游：MachOSwiftSection `86f65341`、swift-semantic-string `ef4bd30`、swift-demangling `e17ae7f`，用 SwiftPM edit 模式构建；上游合入 next 后再并回本分支） | 用户：「现在做，放在叠加分支上」。做法：语料的工作单元从单个对象改为「一个对象连同它的全部后代」（`RuntimeInterfaceCorpusBuilding.corpusPrints(of:transformer:)`，store 按列表里连续的家族切分）；父对象用开了 `marksNestedDefinitions` 的语料打印器打印一次，每个后代按名字（即 mangled name）、嵌套深度和外层区域找到自己的区域，切出、去掉 `depth + 1` 级缩进后作为自己的定义，再接上它自己另外打印的扩展（冻结串还原成 `SemanticString` 拼接后统一冻结，边界的 span 合并与直接打印一致）；找不到区域或去缩进失败就单独打印。嵌套块范围直接取区域表里深度 0、且名字属于侧栏所列子对象的区域，方案 B 的「缩进后子串匹配」与按 `"\nextension "` 截断协议的写法一并删除。上游 `a93960d3` 之后，写在别的模块类型 extension 里的协议不再自带默认实现，RV 在 `extensionContext != nil` 时自己接上（Foundation 的 `AsyncMessage`、`MainActorMessage`）。另：打印宽度改为 `max(1, min(4, 核数 / 2))`，`DyldUtilities.loadImage` 成功后调用 `RuntimeFieldLayoutMemo.removeAll()`。验证：Foundation 852 个嵌套类型的语料逐个与单独打印比较（文本、可见性区域、嵌套块）全部相同；把去缩进层数故意少算一级时 852 个全不同，把 extension 协议的条件去掉时那两个协议的默认实现消失——两条测试都先见红。Core 全量 580 个测试中 578 个通过：批次取消测试单独连跑三次全过（满载时序）；关系快照（`RelationshipsEquivalenceSnapshotTests` 的 Swift 半边）的四个 `Decimal.FormatStyle.*` 变成 `NSDecimal.FormatStyle.*`，在 `feature/find-navigator` + 本地 next 上、把 swift-demangling 换回修复前的 `35d550a` 时都同样出现，与本分支和两个上游 feature 分支都无关；基线记于 2026-08-15（`b99cfb7a`）。来源是 MachOSwiftSection 提案 0023（`1c8d8588`，2026-09-09）：C 导入类型按运行时规则改用 ABI 名（`Decimal` → `__C.NSDecimal`，`NSRange` → `__C._NSRange`），让描述符推出的名字节点与符号 demangle 出的一致；是有意的变化，RV 的基线该更新（MachOSwiftSection 会话确认，并更正了我先前归因的 `f786458f`——那个提交只改 interface 打印器，`displayName` 不经过它）。 |
| 2026-10-01 | 叠加分支并回 `feature/find-navigator`，RV 的远程依赖改指：MachOSwiftSection → `feature/runtime-viewer/find-navigator`，swift-demangling → `next`，swift-semantic-string 仍为 `next`（定义区域已快进合入其 next 并推送，`ef4bd30`） | 用户：「RuntimeViewer -> feature/find-navigator 最新；MachOSwiftSection -> feature/runtime-viewer/find-navigator；swift-demangling -> next；swift-semantic-string -> next」。swift-demangling 由 Core 在顶层直接声明 `branch: "next"`，覆盖 MachOSwiftSection 要的 0.7 发布版；Core 本来就直接 `import Demangling`，这也补正了一个隐式依赖。三个 workspace 的锁文件用 `UpdatePackagesScript.sh` 刷新，顺带把 AppKitPlus-Release（0.6.0）、UIFoundation（0.38.0）、MachOKitExtensions（1.0.0）、SwiftMCP（1.13.0）升到清单允许的最新版。代价：共享的 `.worktrees/MachOSwiftSection` 仍指向 MachOSwiftSection 的 next，本分支只能用远程依赖构建（`RunScript.sh` 的默认），`--local-deps` 编不过；那个分支合入 MachOSwiftSection 的 next 后，清单改回 `next`。 |
| 2026-10-03 | 结果行的字体、颜色、图标全部收进 `FindResultCellStyle`；命中行的未命中部分改用 `secondaryLabelColor`，字号与类型行标题分开（`hitLineFont`，13）；命中片段保持 semibold，并显式设 `labelColor` | 用户微调结果行样式：「未匹配单独抽出来，用secondaryLabelColor」「字体和颜色还有图标全部抽成常量吧，这样方便我改」。命中片段原本只设字体、颜色沿用整行底色，底色改灰后它会跟着变灰，所以单独设回 `labelColor`。图标尺寸原先在构建外观处和 cell 的约束里各写一次，标题左边距 19 也是按 16 的图标算死的，现在约束直接引用常量、标题跟在图标后面，改尺寸只动一处。 |
| 2026-10-03 | 推翻 2026-09-29 的「范围固定为全部已索引镜像」：查询加范围（全部 / 侧栏当前的镜像 / 勾选的镜像）；成员查询加匹配方式。方案写进 §7，待用户确认后动工 | 用户实测：「目前的查找体验还是不好……没办法选择特定框架，写死了所有已索引的image，另外Member查找时，不能走普通文本的查找，contains, matchWord, startWith等等」。当初不做范围档的理由是覆盖率 UI 能说明某个镜像为什么搜不到，但它解决不了「只想看某个框架里的结果」。成员只做子串的理由（成员名短、匹配方式碍事）也不成立：多段 ObjC 选择子与大量同前缀的成员名正需要按词、按开头筛。 |
| 2026-10-03 | 提问轮三条，用户都选了推荐项：范围用 Xcode 式选择器（popover、过滤框、可多选、标出语料状态），不用弹出菜单；Members 模式路径第三段放匹配方式，成员种类挪到第三行的弹出按钮；关系模式只保留范围内的结果，输入的类型本身不受范围限制、通往范围内类型的中间层保留 | 镜像上百个时（启发式索引深度可调到 5）菜单只能靠键入首字母找，也不能多选；路径加第四段在侧栏窄时会被截断；关系模式若只限定「去哪找输入的类型」，范围 AppKit 搜 `NSObject` 的子类会落空。剪枝让范围在三类搜索里是同一个意思：结果只来自这些镜像。 |
| 2026-10-03 | 未问而定、随提问一并列给用户且未被反对的五条：成员名的分词规则与文本模式相同（只认 `[A-Za-z0-9_$]`，不按驼峰拆）；成员模式也有正则（匹配方式菜单最后一项）；改范围与匹配方式不自动重搜；「当前镜像」指侧栏正在列的镜像，在镜像列表那一层时不可选；可选的镜像是全部已索引镜像，不只语料已建好的 | 分词与文本模式一致，同一个查询在两个模式里含义相同；不自动重搜与现有的改模式行为一致；只列语料建好的镜像会让还在建的那些无法提前选中，而选中正好能让它插队。 |
| 2026-10-03 | §7 开工 | 用户：「开工」。 |
| 2026-10-03 | 换引擎时不重置范围（偏离 §7 原文） | 原方案以为换引擎后路径都会失效，但在本机的几个进程之间切换时系统框架的路径完全相同，重置会丢掉一个仍然有效的范围。只有换到 iOS 设备或模拟器时路径才对不上，那时选择器把这些已选镜像标成 `not indexed`，用户一眼就能看到并取消。 |
| 2026-10-03 | 关系搜索有范围时，候选类型里范围内的排在前面（§7 未写） | 候选上限 50 在剪枝之前生效，部分匹配按名字排序时，前 50 个可能全是剪完为空的类型，范围内真正有结果的类型反而排不进来。只调整范围内外的先后，不改精确匹配优先的规则。 |
| 2026-10-03 | 成员种类弹出按钮只取用户的选择；曾怀疑分页的大小写开关会在重绑时把共享查询写回 false，探针证伪 | 两层侧栏的 Find 分页共用一个查询，绑定时就发出当前值的输入会盖掉另一页的选择，所以种类弹出按钮用 `rx.click(with:)`。大小写开关写的是 `caseSensitiveButton.rx.state.asSignal()`：RxCocoa 的 `rx.state` 是绑定即发当前值的 `ControlProperty`，但它没有无参数的 `asSignal()`，只有 `ControlEvent` 有，于是类型检查选中 RxAppKit 动态成员的 `ControlEvent` 重载，只在点击时发值。临时探针照分页原样接线、先把共享查询设为大小写敏感再绑定，结果保持 true；探针未入库。 |
| 2026-10-03 | 模式路径改用复刻 Xcode `DVTPathControl` 的自绘控件 `PathControl`（`RuntimeViewerUI`），规格与证据见 §4.2 | 用户：「复刻一下 Xcode 的 DVTPathControl，我们现在的这个 PathControl 是假的，选中效果也不一样」。反编译 Xcode 27.0 的 DVTKit / IDEKit 确认 Xcode 用的是 DVTKit 私有的 `NSPathControl` 拷贝、全部自绘：悬停底、悬停时换上下箭头、菜单把当前项压在组件上且不打勾，这些 `NSPathControl` 都没有。范围由用户选「Find 导航器用到的全部」（悬停、点击菜单、颜色、尺寸、压缩 / 渐隐 / 展开动画、键盘、辅助功能），不做图标、胶囊高亮、popover、拖拽、常规 / 大号尺寸；放在 `RuntimeViewerUI` 随本分支交付，不进 UIFoundation（那样要先发版再抬依赖）。 |
| 2026-10-03 | 与 Xcode 的四处有意偏离：`Find` 无菜单、不悬停；悬停箭头用 `chevron.up.chevron.down`；一块 tracking area 判定悬停，菜单关闭后按指针重定；键盘焦点跳过无菜单的组件 | 我们没有 Replace，只列自己一项的菜单没有意义；`chevrons.popup` 是 DVTKit 私有资源；一块 area 不依赖相邻两块进出事件的先后，菜单关闭时指针可能已经离开；聚焦一个按什么都不做的组件没有用。 |
| 2026-10-03 | 三处菜单的选择合成 `FindViewModel.Input.modePathChoiceSelected`，路径组成挪进 `FindViewModel.Output.modePath` | 新控件自己发 action，用 RxAppKit 的 `rx.click(with: \.lastSelection)` 接即可，原先的三个 relay 和手写的 `@objc` 菜单代码没有存在的理由；路径组成（含哪一项该强调）放在 ViewModel 里才测得到。测试替换菜单弹出入口 `menuPresenter`（internal）经用户同意。 |
| 2026-10-03 | 「Aa」按钮照 Xcode：开启时加粗 + 强调色，关闭时常规字体、不着色 | 用户：「一起改」。依据 IDEKit `-[IDEFindNavigatorQueryParametersController refreshUserInterface:]`（`0x198474`）；§4.1 原先写的「off 时 `secondaryLabelColor`」是猜的。 |
| 2026-10-03 | 控件改名 `PopUpPathControl`（文件、测试套件同步改名） | 用户：「不要直接叫 PathControl，这种名字一般属于基类」。每个组件都是一个弹出按钮：菜单打开时当前项压在组件上，与 `NSPopUpButton` 一致，辅助功能里也是 AXPopUpButton；DVTKit 自己的方法也叫 `popUpMenuForComponentCell:`。 |
| 2026-10-03 | 三个关系模式加匹配方式（Containing / Matching Word / Starting With / Ending With），与 Text 共用一个选择；Regular Expression 不加，Members 仍单独存 | 用户：「Xcode所有搜索模式都支持这几个, contains, matchWord, start with, end with，加一下这个feature」，随后：「正则没这个，可以忽略」。Xcode 27.0 的每个查询类别各自声明 `supportsAnchoring`，Regular Expression 为 false；匹配方式只存一份，换模式不重置（证据见 §8）。Members 多一个正则，共用会把它带进别的模式。 |
| 2026-10-03 | 类型名的匹配作用在类型自己的名字上（限定名最后一段、去掉泛型实参），查询带点号时改为整个限定名；Containing 因此不再命中模块名与外层类型名 | Xcode 的类型层级查询把锚点放在符号自己名字的两端（§8），用文本搜索的词边界规则实现，对纯标识符与之等价，对带私有判别符的名字也能命中。带点号查询与 Xcode 不同（它拆成容器与名字、名字只按子串），我们没有它的符号索引，对限定名直接套匹配方式更简单。以前「显示名包含即可」会让 `UI` 列出 SwiftUI 的全部类型。 |
| 2026-10-03 | 关系查询的引擎接口接受正则（与文本、成员共用 `RuntimeInterfaceSearchMatchMode`），对完整限定名匹配，编译失败时抛错 | 界面不提供，但枚举共用，接口收到正则时不能静默返回空；`typeRelationships` 原本就是 `throws`，与成员搜索的处理一致。 |
| 2026-10-03 | 模式名照 Xcode 拼作 `Descendent Types`；标识符 `FindMode.descendantTypes`、`RuntimeTypeRelationship.descendants` 不变 | 问用户要不要照 Xcode 的拼法，用户：「改一下」。Xcode 27.0 的 `IDEFoundation.xcplugindata` 里这个查询类别的 `displayName` 是 `Descendent Types`、`persistentIdentifier` 是 `descendent-types`。标识符用的是标准拼法，用户看不到，不跟着改。 |
| 2026-10-04 | 范围按钮改为照 Xcode 先弹菜单、Custom Scopes… 才打开表单，撤下 popover；推翻 2026-10-03「用 popover，不用弹出菜单」的选择（§9） | 用户：「Xcode的Scope选择是先PopUpMenu，自定义才sheet弹出编辑框，所以我不要popover效果，viewModel input也不要传View进来」。IDEKit 的依据见 §9。当初选 popover 的两条理由（镜像上百个，菜单只能靠键入首字母找；菜单不能多选）由表单承接：表单有过滤框、可多选，菜单只放几个固定的范围。 |
| 2026-10-04 | ViewModel 的 Input 不收视图，路由去掉 `sender` 参数：菜单由 ViewController 按 `Output.scopeMenuItems` 构建，表单由 coordinator 挂在窗口上 | 同上，用户原话。表单不需要锚点；按钮把自己经 ViewModel 传给路由只是为了给 popover 定位。主窗口的两个 popover 与侧栏 Filter Scope 还是这种写法，本次不动。 |
| 2026-10-04 | 菜单加 Current Find Results，取筛选栏筛过之后可见行所在的镜像；没有可见行时置灰 | Xcode 的菜单有这一项，取的也是可见结果（§9）；在方案里列给用户，用户确认。实现只是把可见行的镜像收成 `.images(…)`。 |
| 2026-10-04 | 表单用行选中（⌘ / ⇧ 多选）代替勾选框；只认用户自己的选择改动；过滤不改选择，用户在过滤后的列表里改选择时以看得见的选中为准 | 行选中照 Xcode 的大纲，在方案里列给用户；过滤与选择的规则是实施时定的，未问用户。过滤后改选择以看得见的为准：常见的用法是过滤出一个框架再点它，若保留被过滤掉的旧选中，OK 会把看不见的镜像也带上。代价是跨两次过滤累加选择时要清空过滤框再多选。 |
| 2026-10-04 | 一个都没选时 OK 置灰；表单列表覆写 `mouseDown(with:)`；菜单项不带图标 | Xcode 的 OK 此时能点却不改范围，置灰更直观。不覆写时 macOS 27 的列表点击不给焦点，选中的行一直是灰色，与 `StatefulOutlineView` 同一取舍。我们没有与 Xcode 那几个范围对应的图标。 |
| 2026-10-08 | 撤下 `withSharedGenerationOptionsLock`（推翻 2026-10-01 那条）：隔离的 `AppDefaults` 改为连 user defaults 一起隔离，所有隔离实例共用一个 suite、各用一个键前缀（`UserDefaultsNamespace`） | PR #121 审查 PR121.18：锁只修了表面，等搜索结果的测试已有两处没拿锁。当初没走 suite 方案是因为每个实例一个 suite 会在 `~/Library/Preferences` 留一个 plist；共用一个 suite、按键区分就没有这个代价，KVO 按键通知，实例之间互不可见。 |
| 2026-10-08 | `FindSession` 对文档改为 `weak`，`Document.close()` 调新增的 `documentWillClose()`：取消进行中的搜索、退订选项与语料协调器的信号 | PR #121 审查 PR121.02：XPC 上的引擎调用取消不掉，搜索 Task 等待期间留住会话；关窗后在别的窗口改一项 Generation Options，孤儿会话重跑搜索、经 `unowned` 读到已释放的 `DocumentState`，整个 App 中止。`FindSessionLifecycleTests` 修前即在 `swift_abortRetainUnowned` 处中止。 |
| 2026-10-08 | 正则的 `^` / `$` 按行锚定（`.anchorsMatchLines`） | PR #121 审查 PR121.15：条目是整段多行接口，结果却按行报告；不按行时 `^@property`、`;$` 这类按声明形状找的写法永远是 0 条，只有恰好是第一行的 `^@interface` 能用。Xcode 的 Find 按行处理。成员名与类型名是单行，不受影响。§3.1 原写 Swift `Regex`，与实现不符，一并改正。 |

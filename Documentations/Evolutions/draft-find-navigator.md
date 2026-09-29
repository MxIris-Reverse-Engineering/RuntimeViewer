# Draft - Find navigator：查找文本、类型关系与成员

- **状态**: In Progress
- **创建日期**: 2026-09-29
- **最后更新**: 2026-09-29
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
- 条目：`Entry { object: RuntimeObject; interface: FrozenSemanticString; members: [RuntimeMemberDeclaration] }`，
  按 `imagePath` 分组。成员表与语料**同一趟构建**（见 §3.2 为什么必须同一趟）。
- `BuildState`：`pending / building(built, total) / built(summary) / failed(message)`。取消（订阅归零、驱逐、引擎停止）
  → 条目移除，回到未构建，不记 failed；构建抛错 → `failed`，不自动重试，任一触发源再次命中该镜像时重新排队；
  单个对象打印失败不整体 failed——跳过并计数，summary 报告跳过数。
- 驱逐与 section 生命周期对齐：`RuntimeSwiftSectionFactory.removeSection(for:)` / `removeAllSections()`、
  `RuntimeEngine.stop()`（`releaseIndexedSections`）时同步清掉该镜像的语料。Settings 总开关关掉时整体清空。
- 驻留预算：store 记录 Frozen 总字节数，硬上限 256 MB；超限按「最久未被搜索命中」整镜像驱逐回未构建。
- 构建队列在 store 内串行（并发 1）、`.utility`；同镜像重复入队按 `buildStateByImagePath` 去重。
- **取消按订阅引用计数**：每个 `BuildInterfaceCorpusRequest` 只是对该镜像构建的一次订阅，最后一个订阅者退订才取消
  构建任务。多文档共享 `.local` 引擎时，文档 A 关闭不会砍掉文档 B 在等的语料。

**canonical 选项 = `.mcp` 的 strip / 注释开关 + 用户当前 `settings.transformer`。** strip 全关、注释全开，用户改这些
显示开关不触发重建；transformer 跟随用户设置（否则「所见搜不到」，二次定位整行匹配必 miss），transformer 变更是
触发源之一（§4），store 记录构建时的 transformer 指纹，远程场景下配置随请求过线。

**旁路打印路径**（Swift / ObjC 各一）：用 canonical 选项打印 → `frozen()` → 入 store。**不写
`RuntimeSwiftSection.interfaceByObject`、不动 `lastTransformerConfiguration`**，不污染显示缓存。ObjC 侧本就无缓存，
只需选项旁路；Swift 侧要显式绕开 `updateConfiguration` 的驱逐逻辑。逐对象响应 `Task.checkCancellation`，进度按
built / total 上报。

### 2. 引擎请求（全部经 `registerSharedHandlers` 注册，XPC / TCP / proxy 链自动透传）

| 请求 | 类型 | 进度 | 响应 |
|------|------|------|------|
| `BuildInterfaceCorpusRequest { imagePath, transformerConfiguration }` | progress | `CorpusBuildProgress { built, total }` | `CorpusBuildSummary { objectCount, skippedCount, byteCount }` |
| `SearchInterfacesRequest { query, options, resultLimit }` | progress | `[GlobalSearchMatch]`（按镜像粒度增量推送） | `GlobalSearchSummary { totalMatchCount, scannedImageCount, isTruncated, unbuiltIndexedImagePaths }` |
| `SearchMembersRequest { query, kinds, isCaseSensitive, resultLimit }` | progress | `[RuntimeMemberMatch]`（按镜像粒度） | 同上形态的 summary |
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
  1. `backgroundIndexingManager.events` 的 `.taskFinished(result: .completed)` → 该镜像排队；
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
  2. query 降级：整行 miss（显示 strip 选项与 canonical 不同）时按同规则找 `query`，取行号最接近的一处；
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

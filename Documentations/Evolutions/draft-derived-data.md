# Draft - 派生数据：按系统版本把 Find 语料存盘，为索引缓存铺路

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-10-21
- **最后更新**: 2026-10-21
- **所属愿景**: 无
- **关联提案**: [0002](0002-background-indexing.md)（后台索引）、[0023](0023-content-loading-overlay.md)（内容区加载遮罩）、[0027](0027-background-indexing-yields-to-foreground.md)（后台索引给前台让路）、[0029](0029-find-navigator.md)（Find navigator 与文本语料）、[0030](0030-report-navigator.md)（Report navigator）、[0037](0037-local-runtime-xpc-service.md)（本地引擎搬进 XPC service）、[0051](0051-catalyst-xpc-service.md)（Catalyst XPC service）、[0054](0054-always-index-per-engine.md)（Always Index 按 Engine 区分）、[0055](0055-engine-scoped-background-work.md)（后台工作按 Engine 共享）、[0056](0056-cross-references.md)（交叉引用）、[0058](0058-runtime-engine-session.md)（RuntimeEngineSession）
- **实现分支 / PR**: 待定
- **审查**: 两轮对抗审查，每轮四位审查者，分别侧重缓存键与失效、架构集成、性能论断与证据、范围与验收。[第一轮](../Reviews/2026-10-21-draft-derived-data-review.md)针对初稿，合并后 4 🔴、12 🟡；[第二轮](../Reviews/2026-10-21-draft-derived-data-review-round-2.md)针对第一次修订稿，合并后 1 🔴、17 🟡。两轮的问题均已在本版处理，处理方式见决策日志
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

每次启动，「My Mac」的后台服务都要重做三件事：给常驻镜像重新建 section（解析 ObjC 与 Swift 元数据得到的对象图），重新打印 Find 语料，重新准备交叉引用表。这三样都只放在内存里。可它们只取决于两样东西：系统镜像，以及 RuntimeViewer 自己的代码。系统没更新、代码没换，结果就不会变。

本提案引入一个类似 Xcode DerivedData 的「派生数据」目录，按「平台 + 系统版本 / build + dyld 共享缓存 UUID」和「产出数据的代码」分开存放，任何一项对不上就作废。

**本提案（第一期）只做 Find 语料这一样**：
- 一个镜像需要语料时，先从磁盘读，读不到才打印；打印完立刻写盘。
- Always Index 里的镜像，在后台索引一开始就先从磁盘读出语料，section 还没建好就能搜。
- 点开一个还没有 section 的镜像里的搜索结果，或者以它为根查调用层级时，先前台加载这个镜像。
- 设置页和应用菜单可以手动删除派生数据；服务进程自己清掉旧系统版本的目录，以及 14 天没用过的目录。

**第一期省下多少、还剩什么**：
- 省下的是语料打印。按已有实测，它的 CPU 时间并不比建 section 少：AppKit（Debug 探针）建 section 约 28 秒 CPU，打印语料约 40 秒 CPU；SwiftUI（Release，并发 4 路）打印语料约 22 秒 CPU。
- 剩下的是建 section，启动时照旧在后台进行，要等上游的索引缓存做出来才能省掉。交叉引用表在 Release 下只要零点几秒，维持只放内存。

上游那条线另立提案：先在 App 进程里分阶段测量，再决定修什么、存什么。第二期（不建 section 直接浏览）也另立提案，前提是上游缓存出来后的实测数字表明还值得做。

## 动机

### 每次启动都在重做同样的事

一个文档打开时，`Document.makeWindowControllers` 调 `DocumentState.startBackgroundWork()`，接着在这个 Engine 上建起三个协调器（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineBackgroundWork.swift:57`）：

1. **后台索引**：按 Always Index 等设置，为镜像建 ObjC 与 Swift 两个 section（`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine+BackgroundIndexing.swift:61-69`）。
2. **Find 语料**：一个镜像索引完，就把它全部对象的接口打印成可搜索的文本（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindCorpusCoordinator.swift:630-653`，触发源是 `imageDidIndexPublisher`）。
3. **交叉引用**：为已索引的镜像预建紧凑引用表。

三样都只放在服务进程的内存里，进程一退出就没了。下一次启动，就算系统一个字节都没变，也全部重来。

### 代价

已有的实测（Mac Studio）：

| 工作 | 墙钟 | CPU | 出处 |
|---|---|---|---|
| 单开 AppKit（两个 section） | 8.9 秒（Release）、25 秒（Debug） | — | 提案 [0027](0027-background-indexing-yields-to-foreground.md) 的测量表 |
| AppKit 加载与索引（Debug 探针） | 27.96 秒 | 27.92 秒 | `Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md:75` |
| AppKit 语料（Debug 探针） | 12.71 秒 | 39.90 秒（3.14 核） | 同上 `:76` |
| SwiftUI 语料（Release，并发 4 路） | 6.7 秒 | 22 秒 | 提案 [0029](0029-find-navigator.md) 决策日志 2026-10-01 一行 |
| Foundation、libswiftCore 语料（Release） | 0.84 秒、0.35 秒 | — | 同上 |
| AppKit 交叉引用表 | 5.9 秒（Debug），Release 快 20–50 倍 | — | 提案 [0056](0056-cross-references.md) |

从这些数字看，语料打印的 CPU 时间至少与建 section 相当；Release 下两者的比例没有直接测过。

用户的常驻配置在两个 Engine 上：My Mac 上 Always Index AppKit、SwiftUICore、libswiftCore、Foundation、SwiftUI 五个；My Mac (Mac Catalyst) 上 Always Index UIKitCore、UIKitMacHelper 两个。每次启动后，Find 的搜索范围要等这些镜像的语料一个个打印完才齐（具体要多久没有测过，取决于后台索引的进度），CPU 也要把同样的活再干一遍。

### 之前为什么没做

存盘这件事被排除过两次：

- Find 性能那条线（2026-09-30）选的是记忆化、符号索引、并行打印，明确不做落盘缓存。
- 交叉引用（2026-10-18）选了只放内存，理由是存盘要配一整套格式、失效和清理机制（[0056](0056-cross-references.md) 决策日志；`RuntimeViewerCore/Sources/RuntimeViewerCrossReferences/CrossReferenceSession.swift:14-18` 写明不落盘）。

本提案把这套机制一次建好。第一期只用它存语料，上游的索引缓存之后直接复用。

## 前期调研

### 现在什么都不落盘，也不知道「系统是哪一版」

- **Core 和 Packages 都不用缓存目录**：没有任何地方用 `cachesDirectory`，也没有读共享缓存 UUID。现有落盘的只有设置、书签、Find 最近查询、MCP 端口文件等。
- **系统版本只记了一个营销版本号**：`RuntimeDeviceMetadata` 只有「macOS x.y.z」（`RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeDeviceMetadata.swift:60-62`），没有 build 号，也没有共享缓存 UUID。
- **镜像只按路径区分**：LC_UUID 只有导出元数据会读（`Export/RuntimeInterfaceExportMetadata.swift:120`）。
- **共享缓存 UUID 现成能拿到**：MachOKit 的 `DyldCacheLoaded.current` 带缓存头部（`DyldCacheHeader.uuid`，MachOKit `Sources/MachOKit/Header/DyldCacheHeader/DyldCacheHeader.swift:24`）。`DyldUtilities` 已经在用它列共享缓存里的路径（`Utils/DyldUtilities.swift:243-257`）。公开的 `<mach-o/dyld.h>` 里没有 `_dyld_get_shared_cache_uuid`，所以不用它。

### Find 语料可以存盘，而且不用改上游

- **每个镜像存一份 `ImageCorpus`**（`RuntimeViewerCore/Sources/RuntimeViewerCore/Search/RuntimeInterfaceCorpusStore.swift:234`），放在 `corpora: [String: ImageCorpus]`（`:287`）里。
- **每个对象一条 `RuntimeInterfaceCorpusEntry`**（`:9-35`），内容是：
  - `RuntimeObject`：已经是 `@Codable`。
  - 完整接口 `FrozenSemanticString`。
  - 可见性区间表 `VisibilityRegionTable`。
  - 成员表 `[RuntimeMemberDeclaration]`：已经是 `Codable`。
  - 嵌套定义区间 `[Range<Int>]`。
  - 没有任何指向 `MachOImage`、section 或 actor 的引用。
- **swift-semantic-string 不用改**：`FrozenSemanticString` 的 `text`、`spans`、`identifierTable` 与 `init(text:spans:identifierTable:)`，`Span`、`VisibilityRegionTable`、`Region`、`VisibilityCondition`、`Requirement` 的全部字段与初始化器都是 public（swift-semantic-string `Sources/Semantic/Frozen/FrozenSemanticString.swift:39-92`、`Visibility/VisibilityRegionTable.swift:9-37`、`Visibility/VisibilityCondition.swift:24-56`）。RuntimeViewer 自己就能读写。
- **类型码可以放心存**：span 的类型码只追加、不重排，有测试钉住（`Frozen/FrozenSemanticString+TypeCodes.swift`）。
- **读回时有几处会 trap，必须先校验**：
  - `FrozenSemanticString.init(text:spans:identifierTable:)` 不校验，要求 span 长度恰好铺满文本的 UTF-8、没有空 span、边界落在 Unicode 标量上，否则在之后遍历文本的读取里 trap（`enumerateSpans(_:)`、`components`、`==`，`FrozenSemanticString.swift:70-87`）。也就是说，坏数据可能在搜索时才崩。
  - `VisibilityCondition.Requirement.init` 带两条 `precondition`：选项名不能为空，不能含控制字符（`VisibilityCondition.swift:33-38`），Release 构建下也会 trap。
  - 投影假定「区间由整段 span 组成」，自己不检查（`Visibility/VisibilityProjection.swift:109`），但会对区间先排序、截断（`RuntimeInterfaceVisibility.swift:46-62`），所以乱序与重叠不会 trap。
  - 未知的类型码会降级为 `.other`，越界的标识符下标会降级为 `nil`，不会 trap。
  - 库自带的 `Codable` 解码（`Frozen/FrozenSemanticString+Codable.swift:39-109`）校验了文本与 span 这几列：长度铺满、没有空 span、标量边界、三列长度相等。区间、条件、条目下标与嵌套区间不在它的范围内（它的 `CodingKeys` 只有 text、三列 span 与标识符表），要另外校验。

### 语料依赖什么，读回后什么时候需要 section

- **语料只依赖镜像、Transformer 设置和打印代码**：语料打印器建在本镜像的 `machO` 上，只挂本镜像的 opaque type 解析器（`Core/RuntimeSwiftSection.swift:1913-1933`）；ObjC 那边也只用本镜像的索引器（`Core/RuntimeObjCSection.swift:207-226`）。
- **显示选项不进缓存键，Transformer 设置要进**：语料把可选内容标记出来、不按选项删掉，搜索时再按选项投影（`Search/RuntimeInterfaceVisibility.swift`）。Transformer 设置改了语料就要重建（`RuntimeInterfaceCorpusStore.swift:377-389`）。成员排序固定按类别（`RuntimeSwiftSection.swift:1905-1912` 的注释与 `:1927`）。
- **Transformer 设置不能直接拿编码结果算摘要**：
  - `Transformer.CType.replacements` 的类型是 `[Pattern: String]`（MachOObjCSection `Sources/ObjCOutputTransformer/Transformer+CType.swift:26`），而 `Pattern` 是一个 `String` 原始值的枚举（同文件 `:122`），没有遵循 `CodingKeyRepresentable`。
  - 所以这个字典被编码成「键、值交替」的无键数组，顺序就是这张表在本进程里的遍历顺序，`JSONEncoder` 的 `.sortedKeys` 排不到它。
  - 用户自己的设置就是例证：Debug 与 Release 两份设置里同样的 11 对替换，存储顺序不同。
  - 设置页的三个预设会写入 10、5、11 条替换（`RuntimeViewerSettingsUI/Components/TransformerSettingsView.swift:188/195/202`），用过预设的用户都会受影响。
- **打印出的地址基本都是未加滑动的镜像内地址，有一个例外**：
  - Swift 的成员地址经 `address(forOffset:)`，对共享缓存镜像用 `ptr - slide`（MachOKitExtensions `Sources/MachOKitExtensions/MachORepresentableWithCache.swift:135-144`）。
  - ObjC 的 IMP 先换算成偏移，再转成未滑动地址（MachOObjCSection `Sources/ObjCMetadataSource/MachOImage+ObjCMetadataSource.swift:54-65`）。
  - **例外**：在进程内（`MachOImage`）模式下，名字解析不出来的 opaque type 符号引用存的是描述符的绝对进程内指针（MachOSwiftSection `Sources/Analysis/SwiftInspection/SymbolicDemangler.swift:459-461`），打印成 `opaque type symbolic reference 0x…`（swift-demangling `Sources/Demangling/Node/Printer/NodePrinter.swift:574`、MachOSwiftSection `Sources/Output/SwiftPrinting/NodePrintables/NodePrintable.swift:149`）。这是加了滑动的地址，重启后就失效。其余符号引用存的是偏移或未滑动地址。命令行文件模式的 AppKit、SwiftUI 输出里没出现过这段文字，进程内的频率未知。
- **建语料要求 section 已建好，搜索不要求**：建语料要求两个 section 都在（`RuntimeEngine+Search.swift:119-138`），但搜索扫的是仓库里的全部语料；「已索引镜像」这个集合只用来在结果摘要里列出「已索引却还没有语料」的镜像（`RuntimeInterfaceCorpusStore.swift:874-895`）。
- **Find 各模式读什么**：Text、Regular Expression、Members 从语料里找结果；Call Hierarchy 与 Callees 从语料里找根（`FindMode.swift:99-105`）；Ancestor、Descendant、Conforming Types 与 Type References 读关系表，不读语料。找调用者时，候选镜像只从已索引的镜像里挑（`RuntimeViewerCrossReferences/CrossReferenceQuery.swift:171-190`）。
- **点开搜索结果时，内容区不会先加载镜像**：
  - Find 结果直接推给内容区（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift:209-213`）。
  - 取接口时，Swift 对象只读已建好的 section，拿不到就返回 `nil`（`RuntimeEngine.swift:748`）。ObjC 类与协议则会按类名或协议名现建 ObjC section（`RuntimeEngine.swift:761-772` → `RuntimeObjCSection.swift:485-503`），这条路不经过前台加载闸门。
  - 内容区取接口只跟随对象、生成选项与 Transformer（`ContentTextViewModel.swift:164-168`）。引擎的数据变化只会清掉接口缓存（`Content/RuntimeInterfaceCache.swift:130-139`），不会让内容区重取，所以拿到 `nil` 之后会一直空着，直到用户重新导航。
  - Inspector 的关系与层级只跟随对象取数据（`Inspector/InspectorRelationshipsViewModel.swift:65-77`），镜像之后建好 section 也不会重取。
  - 今天语料只来自已索引的镜像，所以碰不到这些情况；从磁盘读出语料之后，会第一次出现「搜得到、但还没有 section」的状态。

### 现有的语料流程里，读取要接上的几处

- **构建只查内存**：`RuntimeInterfaceCorpusStore.build` 只查 `corpora`（`:377`）；`pump()` 一出队就打印，不再检查 `corpora`（`:458`）；`finishBuild` 直接覆盖（`:609`）。
- **订阅者只在一处结算**：`finishBuild` 的注释写明「A subscriber's continuation is resumed in one place only: whoever takes its build out of `builds`」；`cancelBuild` 只在 `builds`、`pendingImagePaths`、`runningBuild` 里找。仓库是 actor，中间一 `await` 就会被重入。
- **手动打开的镜像不开批次**：`RuntimeIndexingBatchReason.manual` 没有调用点；手动打开走 `imageDidIndexPublisher` → `FindCorpusCoordinator.imageDidIndex` → `requestBuild`（`FindCorpusCoordinator.swift:666`）。
- **已索引的根也不开批次**：BFS 遇到已索引的镜像直接跳过，`guard !items.isEmpty else { return nil }` 也不发事件（`RuntimeBackgroundIndexingManager.swift:230, 321`）。批次的条目里还会有 `.failed("cannot open MachOImage")` 与 `.failed("path unresolved")`（`:330, 360`），它们这次启动不会被索引。
- **启发式批次的规模**：启发式批次（主开关打开时默认开启、深度 1）的根是服务进程的可执行文件，Release 版直接链接 37 个库，除 `libswiftCompatibilitySpan` 外都在共享缓存里（`otool -L`），其中包括 AppKit、SwiftUI、Foundation、libswiftCore。
- **后台索引默认是关的**：`Settings.Indexing.isEnabled` 默认 `false`（`RuntimeViewerSettings/Settings+Types.swift:149`）。
- **协调器的几张表与信号**：
  - 改 Transformer 后只重新请求 `requestedImagePaths`（`FindCorpusCoordinator.swift:782`），这个集合只在 `requestBuild` 里写入（`:293`）。
  - `mergeCoverage` 会把协调器没跟踪过、覆盖情况里显示为 built 的镜像，当作「别处建好的」加进构建历史（`:600-625`）；为了让清掉的条目不在下一次刷新时回来，另有 `imagePathsListedInHistory`（`:186-196`）。
  - 正在显示的搜索靠 `corpusBuilt` 扩展到新建好的镜像（`FindSession.swift:302-306, 731-735`），这个信号只在 `finishBuildRequest` 里发出（`FindCorpusCoordinator.swift:541`）。
- **线上编码是 JSON**（`RuntimeViewerCommunication/RuntimeMessageChannel.swift:36-38`）：
  - 旧对端会忽略它不认识的字段，所以新字段对旧对端无害。
  - 反过来，合成的 `Codable` 遇到缺失的键会抛 `keyNotFound`，所以新字段要手写 `init(from:)`、用 `decodeIfPresent` 给默认值，先例是 `RuntimeHostInfo.swift:26`、`RuntimeDeviceMetadata.swift:43-44`。
  - 给 `RuntimeInterfaceCorpusBuildState`（`Common/RuntimeInterfaceSearch.swift:261`）加 case 不兼容：旧对端解码整份覆盖情况会失败，而失败被 `try?` 静默吞掉。
- **App 进程里也有不转发请求的引擎**：`.bonjour(role: .server)` 引擎（`RuntimeViewerEngineManagement/RuntimeEngineManager.swift:396-398`）是管理用的（`pushesRuntimeData: false`），但它不转发请求（`RuntimeEngine.swift:101-103`），收到的命令就在 App 进程里执行（`RuntimeEngine.swift:932-937`）。所以「是否启用派生数据」不能从「不转发请求的那一端」推断。
- **服务进程空闲时的优先级**：服务是 launchd 的 adaptive job，没有请求挂着时落在 Darwin 后台档，同样的工作要多花 2.5 到 4 倍的 CPU 时间（`Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md:78`）。所以写盘要放在 App 还等着的那段时间里做，不能等空闲。

### 索引本身（section）为什么不能整体存盘

- **section 是一张活的对象图**：Swift section 包着 MachOSwiftSection 的 `SwiftDeclarationIndexer`。它产出的是由类组成的定义图：类型、协议、扩展定义，带 weak 父节点，名字是指向每个镜像名字库的 `NodeReference`。成员表这类字段要到第一次打印某个类型时才去镜像里现读、现补，打印时还会往定义上写东西。
- **散在好几个进程级缓存里**：符号库 `SymbolIndexStore`、名字库 `InternedNodeReferenceCache`、`SwiftClassObjectIndex` 等。
- **要整体存盘得做这些事**：每一层都加一条「从磁盘恢复」的构造路径；让读回的节点编号、符号行号、描述符偏移原样对得上；再用覆盖整个共享缓存的对拍保证结果逐字一致。跨 swift-demangling、MachOSwiftSection、MachOObjCSection、RuntimeViewer 四个仓库，格式还要跟着上游结构一直改。
- **底层只有一部分是扁平的**：
  - swift-demangling 的节点库是三块扁平数组：每个节点 12 字节，加上子节点边和去重后的文本（`Sources/Demangling/Store/CompactNode.swift`）。它的提案 0001 规划过「第 4 阶段：几块缓冲直接二进制读写、支持 mmap」，后来推迟了（`Evolutions/0001-node-store-arena.md:119`）；节点种类的编号目前只在单次运行内稳定，存盘要另带一张对照表（同文件 `:40`）。
  - 符号表的每一行只是「规范偏移 + 名字在字符串表里的相对位置」（MachOSwiftSection `Sources/MachO/MachOSymbols/SymbolTable.swift:113-128`）。
  - 但 `SymbolIndexStore.Storage` 其余部分不扁平：`typeInfoByName`、三层嵌套的 `memberSymbolRowsByKind`、`thunkAttributeMembersByKindAndTypeName`、`symbolRowsByOffset`，还有按结构哈希重建的表和可追加的 `lateNameStore`（`SymbolIndexStore.swift:145-330`）。
- **有的分析会读别的镜像**：ObjC 成员表沿父类链读进别的镜像，进程内还会把其他已加载镜像的类别折叠进来（MachOSwiftSection `Sources/Analysis/SwiftInspection/ObjCAncestorResolver.swift:71-79`）。所以上游缓存的键只能放在「共享缓存 UUID」这一层之下，不能按单个镜像独立定键。

### 命令行实测：只能当作粗略的参考

2026-10-21，用 `swift-section` 0.23.0（Release）命令行读本机 macOS 27.2 的共享缓存。原始数据在 `/Volumes/DerivedData/Agents.noindex/claude/ProbeRuns/20261021-index-phases/`。各阶段的时间取自进度日志的时间戳：

| 阶段 | AppKit 的 Swift 部分 | SwiftUI |
|---|---|---|
| 读出描述符 | 0.06 秒 | 0.2 秒 |
| 把全部 Swift 符号解混淆，建符号库 | 0.1 秒（7,151 个符号） | 3.0 秒（220,628 个） |
| 类型与协议 | 0.2 秒 | 1.0 秒 |
| 协议遵循 | 0.3 秒 | 4.0 秒 |
| 扩展 | 5.1 秒 | 0.6 秒 |
| 建索引合计 | 5.9 秒 | 8.8 秒 |
| 命令行自己收集 import 的模块（App 不做） | 0.05 秒 | 2.2 秒 |
| 打印整份接口（不属于索引） | 2.5 秒 | 9.0 秒 |

另外，AppKit 的 ObjC 部分导出整份头文件，连索引带打印一共 6.7 秒。

**这组数字不能直接用来判断 App 里的开销**，原因有四个：

1. **走的不是同一条代码路径**。命令行读的是磁盘上的缓存文件（`MachOFile`），App 读的是自己进程里已经映射的镜像（`MachOImage`）。
   - 关联类型推算的跳板反汇编只对 `MachOFile` 开放，开头就是 `guard let machOFile = machO as? MachOFile else { return nil }`（`Node+OpaqueType.swift:281`）；App 的 section 建在 `MachOImage` 上（`RuntimeSwiftSection.swift:73`），走的是进程内的运行时解析，按那里的注释，SwiftUI 只有 17 个需要这样处理的见证。
   - `ObjCMethodThunkReferences` 的 `MachOImage` 重载也不建 `ThunkAddressSpace`。
   - 所以 SwiftUI「协议遵循」里属于这条路径的开销，App 里不存在。比如那一行约四成的样本（3366 个里的 1404 个）花在 `MachOThunkEnvironment.ownRuntimeSymbolNamesByAddress`：每读一个跳板就新建一个 environment（`AccessorThunkReader.swift:67`），把整张符号表重扫一遍；而整条 `MachOFile` 专有路径约占这一行样本的一半。
2. **命令行自身的日志开销混在各行里**。它每处理一个索引事件，就新建一个日期格式器（`ConsoleEventHandler`）。SwiftUI 那次采样的 11 秒只覆盖了索引阶段，其中日期格式器约占全部样本的四分之一，主要压在「类型」和「协议遵循」两行上。
3. **AppKit 的采样与阶段表对不上**。采样里 `prepare()` 只有 275 个样本，打印有 2144 个；ObjC 成员表（`applyObjCMembers`）全在打印路径下，是打印时惰性计算的。「扩展那 5 秒是什么」不能从这组数据下结论。
4. **采样的换算**。`sample` 的实际间隔远大于名义上的 1 毫秒，只能按「样本占比 × 该阶段实测时长」换算，不能按样本数直接折算成秒。

所以，上游先修什么、存什么，以 App 进程内的分阶段测量为准（见「上游的索引加速」）。

### 文件格式的依据

- **压缩率（实测，但测的不是语料本身）**：用系统自带的 `compression_tool` 压缩命令行导出的两份文本：

| 文本 | 原始 | LZ4 | LZFSE | zlib |
|---|---|---|---|---|
| AppKit 的 ObjC 头文件 | 6.2 MB | 1.82 MB（3.4 倍） | 1.00 MB（6.1 倍） | 1.08 MB（5.7 倍） |
| SwiftUI 的 Swift 接口 | 5.1 MB | 1.10 MB（4.6 倍） | 0.58 MB（8.9 倍） | 0.63 MB（8.1 倍） |

  LZFSE 解压一份（含 `compression_tool` 的进程启动）用了 22–28 毫秒。这两份文本是按默认选项打印的，没有地址、注释也少；语料按全部选项打印，AppKit 加 SwiftUI 约 27.3 MB，注释占一半以上（`Documentations/Plans/2026-07-26-global-search-design.md:25-33`），压缩率会有出入。
- **读回的成本不只是解压**：
  - 成员条数很多：SwiftUI 接口约 4.1 万行成员声明，AppKit 头文件约 9 万行方法与属性。
  - 每条语料初始化时都要重建一次行表 `RuntimeInterfaceLineTable`（`RuntimeInterfaceCorpusStore.swift:51-55`）。
  - 首尾相接存的列要切回每条各自的字符串和数组。
  - 每段还要校验、解压，读回后还要做一次完整遍历（见「读取标记」）。
  - 读回一个大镜像要多久没有实测过，在落地第 2 步用计时测试量出来（见「成功标准」）。
- **数据量**：语料里的大块是文本，再加上 span 的三列整数（长度 `UInt16`、类型码 `UInt8`、标识符编号 `UInt32`）。AppKit 加 SwiftUI 的纯文本约 27 MB，平均每个 token 7.9 字节（`Documentations/Plans/2026-07-26-global-search-design.md:30-33`）。

### 先例

- **按「系统版本-build」分目录的缓存**：MachOSwiftSection 的 `ModuleIndexCache`（`Sources/Declaration/TypeIndexing/ModuleIndexCache.swift`）把 SDK 接口的抽取结果按「平台 / 版本-build」分目录存成 JSON，带一个 `generatorVersion`。对不上就当作没有缓存，读写失败一律退回重新生成。
- **Xcode**：
  - DerivedData：按 workspace 分目录，可以整个删掉。
  - `iOS DeviceSupport`：按「设备型号 + 系统版本 + build」存从设备取下的共享缓存符号，每个系统版本只取一次。
- **进程入口处的一次性开关**：注入与交叉引用这两个命令扩展，都要求每个服务引擎的进程在入口处调用一次 `install()`（根 `AGENTS.md` 的 Injection commands 一节）。派生数据照这个先例，由两个服务的入口显式开启。

### 进程、沙盒与 bundle id

- **服务进程没有沙盒**：`RuntimeViewerLocalRuntimeService.entitlements` 只有 `disable-library-validation`，注释写明不开 App Sandbox。Catalyst service 的 entitlements 是空的。所以服务进程可以直接写 `~/Library/Caches`。
- **按 bundle id 分开的只是配置，不是构建**：Debug、Debug-arm64e、Release 的 App bundle id 各不相同（`Configurations/CodeSigning.xcconfig:7-9`、`:34-36`）。但同一配置常有多份构建共用一个 bundle id：多个 worktree、`RunScript.sh`、`TuistScript.sh` 编出的 Debug-arm64e 都是 `dev.JH.RuntimeViewer.arm64e`。
- **哪个进程建语料**：
  - App 的 `.local` 引擎把一切转发给内嵌 service（[0037](0037-local-runtime-xpc-service.md)），语料仓库在 service 里；Catalyst 引擎同理，在 Catalyst service 里（[0051](0051-catalyst-xpc-service.md)）。
  - 命令行与 MCP 都不建语料（在 `RuntimeViewerCommandLine/Sources`、`RuntimeViewerMCP/Sources` 里搜 `buildInterfaceCorpus`，结果为空）。
- **两个 service 的代码在哪**：Release 的本地 service 是静态链接的，除系统库外只依赖 `libswiftCompatibilitySpan`；Catalyst service 的外壳没有非系统依赖，Core 在它加载的插件 `RuntimeViewerCatalystHelperPlugin` 里，插件在引擎启动前就已加载。Debug 构建的 service 带一个指向构建产物目录的 rpath（`…/Build/Products/Debug/PackageFrameworks`），日后如果动态链接包框架，这部分代码就从 App 包外加载。
- **设置页的模块边界**：设置页在 package `RuntimeViewerSettingsUI` 里，引用不到 App target 里的类型。现有做法是：客户端在 `RuntimeViewerSettings` 里声明（它本来就依赖 `RuntimeViewerCore`，`RuntimeViewerPackages/Package.swift:405-411`），由 App 提供实际实现（`RuntimeViewerSettings/UpdaterClient+DependencyValues.swift`、`ApplicationRelauncher.swift`）。
- **App 工程没有可用的测试 target**：唯一的单元测试 target 是 `RuntimeViewerSourceEditorBridgeTests`，所以需要测试的逻辑要放进 package。

## 提议方案

### 派生数据目录

- **位置**：`~/Library/Caches/<App 的 bundle id>/DerivedData/`。Caches 本来就是放可以重新生成的数据的地方，也不进 Time Machine 备份。位置固定，不提供修改。
- **分层**：
  1. **系统目录**：平台（macOS / Mac Catalyst）+ 系统版本 + build + dyld 共享缓存 UUID。
  2. **生产者目录**：产出数据的代码。它的身份是「含有 RuntimeViewerCore 代码的那个映像」加上它在本进程里加载的全部非共享缓存依赖，用这些映像在内存里的 LC_UUID 算摘要：本地 service 是它的可执行文件，Catalyst service 是插件。之后经「Load Frameworks…」载入的东西不算在内。不读磁盘，所以 App 在运行时被原地重编，也不会给旧代码的产物贴上新摘要。
  3. **镜像**，最后是**数据种类与变体**，比如语料按 Transformer 设置与成员排序方式分变体。
- **谁读写**：
  - **只有两个服务进程读写**：App 内嵌的本地 service 与 Catalyst service，由它们的入口处各调用一次 `RuntimeDerivedData.enableInThisProcess()` 显式开启。App 进程（包括其中的 Bonjour 服务端引擎）、命令行宿主、Catalyst helper App、注入的载荷、测试都不启用；测试显式注入临时目录。
  - **清理也由服务进程做**：每个服务进程第一次用到派生数据时，先刷新自己生产者目录的使用时间，再清理过期目录。
  - **App 进程只做两件事**：统计占用大小、手动删除。
- **只管 dyld 共享缓存里的系统镜像。**

### 第一期

1. **写盘**：一个镜像的语料打印完、放进仓库后（此时已经能搜），在同一个构建任务的末尾编码并写盘，写完这次构建才算结束。
   - 这时 App 还在等这次构建，服务不会掉进后台档。写盘的开销相对打印很小（推测，第 2 步量）。
   - 所以 Report 里一次构建显示完成，就意味着已经写盘。
   - 文本里出现绝对进程内指针（`opaque type symbolic reference 0x…`）的镜像不写，记一条日志。
2. **从磁盘读取，两条路径**：
   - **构建路径**：任何「建语料」请求，在确认 section 已建好之后、打印之前，先查派生数据，命中就直接用、不打印。手动打开的镜像、已经索引过的根、启发式批次里的镜像，都走这条路。
   - **Always Index 的提前读取**：只针对 Always Index，与「启动时只恢复 Always Index 的镜像」这条决定一致。这个 Engine 的 Always Index 批次一派发，语料协调器就请服务读出两类镜像的语料，让它们在 section 建好之前就能搜：
     - 这个 Engine 的 Always Index 各行解析出的镜像，包括已经被别的批次抢先索引的那些；
     - Always Index 批次（包括跟随依赖时的闭包）里状态为 `.pending` 的条目。
     - 启发式批次里的其他镜像不提前读，等它们被索引时走构建路径。
   - 「Keep Interfaces Searchable」关着时两条路径都不走，也不写盘。
   - **后台索引关着时**（默认就是关的）：没有提前读取。手动打开一个镜像后，它的语料不再重打，section 建好就能搜。
3. **还没有 section 的镜像**：读出的语料让这种状态第一次成为可能，下面几处入口改为先前台加载这个镜像。前台加载和在侧栏里打开它走同一条路（`objectsWithProgress(in:)`），会和正在进行的后台构建合并成一次（`RuntimeSectionBuild`）。
   - **内容区**：接口为 `nil`、且对象所在镜像还没有 section 时，在同一个取接口的任务里先前台加载、再重取，期间显示内容区现有的加载遮罩（[0023](0023-content-loading-overlay.md)）；加载失败按取接口失败处理。ObjC 类与协议照旧走现有的「按类名现建 ObjC section」那条路。
   - **Inspector**：关系与层级在当前对象所在的镜像发出 `imageDidIndex` 时重取一次。
   - **Call Hierarchy 与 Callees**：选中的根如果所在镜像还没有 section，先前台加载它再查询，否则找调用者时会漏掉同一镜像里的调用者。
4. **清理**：
   - **自动**：服务进程第一次用到派生数据时清理，规则见「清理规则」。
   - **手动**：Settings › Indexing 新增的「Derived Data」一节（路径、占用大小、「Show in Finder」、「Delete Derived Data…」），以及应用菜单里 Simulator App Installer… 下面的「Delete Derived Data…」（执行前确认，不设快捷键）。
   - 删除只删磁盘上的文件。本次运行中已经在内存里的数据不受影响，之后打印出的语料照常写回。
5. **Report**：Searchable Interfaces 下新增一组「Restored from Derived Data」，每个镜像一行，细节栏写语料大小与读取用时。
   - 这些镜像不再作为构建出现。
   - Clear History 清掉这一组，之后刷新不会让它们回来。
   - 某个镜像的语料被淘汰、或被重新打印，它那一行就去掉，重新打印的那次照常列入构建历史。
   - Engine 从头来过时，这一组清空。
6. **给上游缓存的接口**：派生数据存储提供「某个镜像的目录、当前系统与生产者身份」。上游库的缓存写进这个目录，「Delete Derived Data…」会一并清掉。上游具体的接口在各自的提案里定。

### 成功标准

**测法**：
- 用 Release 构建，按用户的配置：后台索引打开，启发式关闭，「Keep Interfaces Searchable」打开。
- 两个 Engine 各开一个文档分别测：My Mac 上的五个镜像（AppKit、SwiftUICore、libswiftCore、Foundation、SwiftUI），My Mac (Mac Catalyst) 上的两个（UIKitCore、UIKitMacHelper）。
- 第一次启动写好派生数据：等 Report 里这些镜像的语料构建全部显示完成即可，构建在写盘之后才算结束。
- 退出 App（服务随之退出）后再启动，测第二次。「冷启动」只是指重新启动 App，不清文件系统缓存。
- 起点是这个 Engine 的 Always Index 批次派发、开始提前读取，终点是最后一个镜像的语料可搜，两处都有 `#signpostInterval` 埋点，并由 `#log` 打一行汇总；单镜像读取用时取 `RestoredImage.duration`，从开始读文件算到放进仓库，包括校验与读后遍历。验收读日志即可。

| 项目 | 目标 |
|---|---|
| 每个 Engine：从提前读取开始到它的 Always Index 镜像全部可搜 | ≤ 3 秒 |
| 单个镜像的读取用时（AppKit、SwiftUI 分别看） | ≤ 0.5 秒 |
| 第二次启动打印的语料数 | 0（Report 里这些镜像都在「Restored from Derived Data」下） |
| 七个镜像派生数据的磁盘占用 | ≤ 200 MB |

**达不到时**：在决策日志里记下实测数字和原因，由用户决定是调整方案还是接受。测试一节里的功能测试另外全部要通过。

### 上游的索引加速（各仓库另立提案，不在本提案内实现）

1. **在 App 进程里分阶段测量**：这是上游那条线的第一步，不是本提案的落地步骤。在 App 自己的进程里，把 ObjC section、符号库、类型、协议遵循、扩展、打印时的 ObjC 成员表、RuntimeViewer 自己的表与 `allObjects()` 各量一遍，AppKit 与 SwiftUI 都量。测量程序是一次性的，只放在分支上、不合入，写好后先给用户看再运行。命令行的数字只作粗略参考（见前期调研）。
2. **先修**：测量里显示出的、修掉就能省时间的开销，优先修掉。
3. **再存**：剩下贵、且结果稳定的分析，按测量结果挑出来存进派生数据目录。要遵守两条：键放在「共享缓存 UUID」这一层之下（有的分析读别的镜像）；读回成本同样要量，因为符号库不全是扁平的表。每项单独对拍：有缓存和没缓存时，打印结果逐字相同。

### 第二期（不在本提案内）

第二期指的是：侧栏、内容区、跳转都直接读派生数据，不等 section。之前讨论时为它定过下面几条，记在这里，作为第二期提案的输入：

- Find 语料改为跟随当前的成员排序设置，每个对象只打印一份，同时供 Find 和内容区用；改排序设置时像改 Transformer 一样重打。
- 对象列表存盘，侧栏直接用。
- 从磁盘读取之后，section 仍在后台补建。
- 后台 section 建好之前，Inspector 的关系区显示加载中；跳转到定义在存下的对象列表里按 mangled name 找（Swift 对象的 `RuntimeObject.name` 就是它的 mangled name，`RuntimeSwiftSection.swift:322-330`）。
- 关掉「Keep Interfaces Searchable」时仍然打印并存盘，开关只管 Find。

**闸门**：
- **什么时候量、量什么**：上游缓存落地后，在 Release 构建、App 进程里，测 AppKit 与 SwiftUI 各自从缓存把两个 section 建好要多久。
- **参考线**：每个镜像 2 秒。在参考线以内，说明 section 本身足够快，第二期大部分复杂度（投影显示、Inspector 等待、两种数据来源）可能都不需要。
- **谁拍板**：由用户看数字决定第二期做不做、做多少；要做就另立第二期提案，引用本节。

### 非目标

- **不覆盖共享缓存以外的镜像**：App 包里的框架、自己编的 dylib 都不管。
- **不在本机为远程与沙盒进程保存派生数据**：iOS Simulator、注入的进程、远程设备、越狱设备都照旧。App 进程里的引擎，包括 Bonjour 服务端引擎，也都不启用。
- **命令行宿主第一期不读写派生数据**：它不建语料。
- **不把交叉引用表存盘**，维持「只放内存」。
- **不跨 App 版本保留**：生产者一变就用不上，14 天没人用就被清掉，不做格式迁移。
- **不提供修改位置，不设大小上限，不加启用开关。**
- **不改 Find 语料的成员排序，也不存对象列表**：两者都属于第二期。
- **不在本提案里实现上游的任何缓存或优化，也不做上游的测量。**
- **不用 protobuf**，也不用 Foundation 的 JSON / plist 编码整份语料（理由见「替代方案考量」）。

## 详细设计

### 目录布局

```
~/Library/Caches/<App 的 bundle id>/
  DerivedData/
    macOS-27.2-26B5112a-<共享缓存 UUID>/          系统目录（名字即身份）
      Info.plist                                 系统身份，给人看
      <生产者摘要前 16 位>/                        生产者目录
        Info.plist                               完整摘要，给人看
        LastUsed                                 空文件，修改时间即最近使用时间
        Images/
          <镜像文件名>-<完整路径的摘要前 12 位>/
            InterfaceCorpus-<Transformer 摘要>-ByCategory.rvdd
            （上游缓存日后也放在这里）
  DerivedData.deleting-<UUID>/                   删除中的旧根目录，之后回收
```

- 系统目录名的平台部分用 `macOS` 或 `macCatalyst`。
- **清理的依据**：系统目录看目录名里的 build；生产者目录看 `LastUsed` 的修改时间，缺了就看目录本身的修改时间。两个 `Info.plist` 只给人看，清理不读它们，缺了也不影响。每次写盘前补齐缺失的 `Info.plist` 与 `LastUsed`。
- 镜像目录名带上完整路径的摘要，防止同名镜像相撞（共享缓存里 `/System/iOSSupport` 下有同名的 Catalyst 版本）。

### 开启、身份与位置

放在 `RuntimeViewerCore/Sources/RuntimeViewerCore/DerivedData/`：

```swift
public enum RuntimeDerivedData {
    /// Turns derived data on for this process. Called once, at the entry
    /// point of the two processes that serve an engine and keep derived
    /// data — the local-runtime XPC service and the Mac Catalyst service —
    /// before any engine connects. Every other process leaves it off, the
    /// app's own process included.
    public static func enableInThisProcess()
}

/// The system a piece of derived data was produced on.
public struct RuntimeDerivedDataSystemIdentity: Hashable, Sendable {
    public enum Platform: String, Hashable, Sendable {
        case macOS
        case macCatalyst
    }

    public let platform: Platform
    /// `ProcessInfo.operatingSystemVersion`, such as "27.2".
    public let operatingSystemVersion: String
    /// `sysctl kern.osversion`, such as "26B5112a".
    public let operatingSystemBuild: String
    /// `DyldCacheLoaded.current?.mainCacheHeader.uuid`.
    public let sharedCacheUUID: UUID

    /// "<platform>-<version>-<build>-<shared cache UUID>".
    public var directoryName: String { get }

    /// This process's system; `nil` when the process maps no shared cache.
    public static func current() -> RuntimeDerivedDataSystemIdentity?
}

/// The code that produced a piece of derived data: a SHA-256 digest over
/// the in-memory LC_UUID of the image that holds RuntimeViewerCore's code
/// and of every image it depends on that is loaded and outside the shared
/// cache, each with its path, sorted by path. Read from the loaded headers,
/// never from disk, so a process whose bundle was rebuilt in place keeps
/// the identity of the code it is running. Images loaded later through
/// Load Frameworks… are not dependencies and do not count.
public struct RuntimeDerivedDataProducerIdentity: Hashable, Sendable {
    public let digest: String

    /// `nil` when the image holding RuntimeViewerCore cannot be found.
    public static func currentProcess() -> RuntimeDerivedDataProducerIdentity?

    /// The digest of an explicit list — the seam the identity tests use.
    static func digest(of images: [(path: String, uuid: UUID)]) -> String
}

/// `~/Library/Caches/<bundle identifier>/DerivedData` of the RuntimeViewer
/// application enclosing a bundle.
public struct RuntimeDerivedDataLocation: Hashable, Sendable {
    public let applicationURL: URL
    public let rootURL: URL

    /// The `.app` enclosing `bundle` — the bundle itself, or an XPC service
    /// under `Contents/XPCServices` — when its `Info.plist` names
    /// `RuntimeViewerLocalRuntimeServiceBundleIdentifier`; `nil` anywhere
    /// else.
    public static func enclosingApplication(of bundle: Bundle) -> RuntimeDerivedDataLocation?
}
```

- **开启的义务**：根 `AGENTS.md` 的 Injection commands 一节列着每个服务进程的入口。派生数据只在其中两处调用 `RuntimeDerivedData.enableInThisProcess()`：`RuntimeViewerLocalRuntimeService/main.swift` 与 `AppKitPluginImpl.runService()`。漏掉调用不会报错，只是这个进程没有派生数据，所以不需要像命令扩展那样做成「链接了就必须调用」。
- **进程级的存储**：在开启了的进程里，第一次需要时按位置、系统身份、生产者身份建一个 `RuntimeDerivedDataStore`。三者任何一个拿不到就不建，也就是不启用。存储写成 `fileprivate static let`，照 `CrossReferenceSession` 的先例：`RuntimeViewerCore` 不依赖 swift-dependencies，所以不走 `@Dependency`，在文件头注释里说明这一点。
- **谁拿到存储**：服务进程里直接服务镜像的引擎建语料仓库时拿到它。测试经 `RuntimeEngine` 的一个 internal 注入点（`@testable` 可见），在第一次用到语料仓库之前给它指定一个用临时目录建的存储。

### 存储与容器格式

```swift
public struct RuntimeDerivedDataKind: Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String)

    public static let interfaceCorpus = RuntimeDerivedDataKind(rawValue: "InterfaceCorpus")
}

/// Reads and writes the derived data of one system and one producer.
public actor RuntimeDerivedDataStore {
    public init(location: RuntimeDerivedDataLocation, system: RuntimeDerivedDataSystemIdentity, producer: RuntimeDerivedDataProducerIdentity)

    /// Reads, validates and decodes the container stored for `kind` and
    /// `variant` of the image at `imagePath`, off the actor; `nil` when it
    /// is not stored, not for an image of the shared cache, being read by
    /// another live process, failing validation, or quarantined. A file that
    /// fails is deleted.
    public func read<Value: Sendable>(_ kind: RuntimeDerivedDataKind, variant: String, forImageAt imagePath: String, decode: @Sendable (RuntimeDerivedDataContainer) throws -> Value) async -> Value?

    /// Writes to a temporary file in the same directory and renames it into
    /// place, then deletes the image's other variants of `kind`. Failures are
    /// logged and dropped.
    public func store(_ container: RuntimeDerivedDataContainer.Builder, as kind: RuntimeDerivedDataKind, variant: String, forImageAt imagePath: String) async

    /// The directory of the image at `imagePath` — the seam for caches of
    /// other libraries; `nil` for an image outside the shared cache.
    public func imageDirectory(forImageAt imagePath: String) -> URL?
}
```

- **读取并行**：校验、解压与解码都在仓库外进行，最多同时 4 个，不在 actor 上排队。
- **同一镜像只读一次**：同一个进程里对同一镜像的并发读取合并为一次（按镜像的在途表），构建路径与提前读取共用这张表。

容器文件（扩展名 `.rvdd`，小端）：

- **头部**：魔数 `RVDD`、格式版本（`UInt32`）、种类、变体、镜像路径、系统目录名、生产者摘要。读回时逐项和期望值比对，以防文件被挪错位置。
- **分段目录**：每段记编号、偏移、长度、解压后长度、压缩方式（不压缩 / LZFSE）、校验和（SHA-256 前 8 字节，用 CryptoKit）。
- **数据段**：大块按原始的定长数组写入，每段单独压缩；读回时逐段校验、解压。
- **任何一步失败都按「没有缓存」处理**：删掉这个文件，走原来的建法，不弹错误。
- **格式不做跨版本兼容**：生产者一变整个目录都用不上，版本号只是用来防止读错。

**读回校验**：先全部通过，才构造任何对象。

- **容器**：魔数、版本、头部各项、分段目录不越界、校验和、解压后长度与记录相符。
- **条目**：各段的条目数一致；每条在各段里的起止下标满足 lower ≤ upper，且不越界。
- **文本与 span**（与 `FrozenSemanticString+Codable` 的 `init(from:)` 校验的内容相同）：
  - 文本必须是合法的 UTF-8。
  - span 三列长度相等。
  - 每条的 span 长度之和等于该条文本的 UTF-8 字节数，没有长度为 0 的 span。
  - 每个 span 的边界字节都不是 UTF-8 后续字节（`0b10xxxxxx`）。
- **可见性区间**：不越过文本末尾，边界与 span 边界重合，条件下标在范围内。
- **可见性条件**：每个选项名非空、不含控制字符。这一条必须在调用 `Requirement.init` 之前检查，它的 `precondition` 会让进程直接 trap。
- **嵌套定义区间**：lower ≤ upper，并且在文本范围内。

**读取标记**：防止坏文件让服务崩溃循环。

- **何时建、何时删**：读一个容器之前，先在旁边建标记文件 `<文件名>.reading`，内容是本进程的 PID 与启动时间。校验、解码之后，还要对每条语料做一次完整遍历（逐个 span），再按「选项全开」与「选项全关」各投影一次；这些都通过了才删标记。这样，遍历和投影里会 trap 的路径在标记还在时就已经走过一遍。
- **遇到别人的标记**：
  - 标记里的进程还活着（PID 与启动时间都对得上），说明别的进程正在读，本进程把这次当作没有缓存，不删文件。
  - 标记里的进程已经不在了，说明上次读到一半崩了，就把容器和标记一起删掉，不再解码。
- **代价**：服务在读取途中被正常杀掉（例如 App 退出），下次也会删掉一个好文件，那个镜像重打一次。这是派生数据，可以接受。
- **清理时成对处理**：标记从不单独删除；要删就和它旁边的容器一起删。

**Transformer 摘要**：
- 先把配置化成规范形式：`replacements` 按 `Pattern.rawValue` 排序，写成有序的 (键, 值) 列表，其余字段按固定顺序写出；对这个规范形式算 SHA-256，作为变体名的一部分。
- 容器里同时存下完整的配置，读回时再用 `==` 比对一次。
- 测试覆盖：把同样内容、不同数组顺序的两份设置 JSON 各自解码，算出的摘要相同。用户自己的 Debug 与 Release 两份设置就是现成的样本。

### 语料快照

一个镜像的 `ImageCorpus` 编成一个容器：

| 段 | 内容 | 编码 |
|---|---|---|
| `summary` | `RuntimeInterfaceCorpusBuildSummary` 与完整的 Transformer 设置 | 二进制 plist（现有 `Codable`） |
| `objects` | 每条的 `RuntimeObject` | 二进制 plist（现有 `Codable`） |
| `members` | 每条的 `[RuntimeMemberDeclaration]` | 二进制 plist（现有 `Codable`），读回太慢时改为定长列 |
| `text` | 全部条目的接口文本首尾相接 | UTF-8，LZFSE |
| `spanLengths` / `spanTypeCodes` / `spanIdentifierIndices` | 全部条目的 span 三列 | `UInt16` / `UInt8` / `UInt32` 数组，LZFSE |
| `identifiers` | 全部条目的标识符表 | 长度前缀的 UTF-8，LZFSE |
| `regions` | 可见性区间三列 | `UInt32` 数组，LZFSE |
| `conditions` | 可见性条件（选项名与开关的析取范式） | 长度前缀编码 |
| `nestedRanges` | 嵌套定义区间 | `Int64` 对数组 |
| `entries` | 每条在上面各段里的起止下标 | `UInt32` 数组 |

- 成员段先沿用 `Codable`，在第 2 步的计时测试里量读取用时，超出成功标准就改成定长列。
- `memberDeclarationLineRanges` 照现有做法在初始化时现算，不存。

### 引擎与语料仓库

- **读取是构建的一个阶段**：
  - `RuntimeInterfaceCorpusStore` 的 `Build` 多一个阶段：先「读取」，读不到才「打印」。
  - `build(imagePath:transformer:)` 在已有的「内存里有同一 Transformer 的语料就直接返回」之后，照常建一个带 identifier 的 `Build`、登记订阅者，先进入读取阶段；读取在仓库外进行，读回后核对这个 `Build` 的 identifier 仍是当前的（没被取消、淘汰、或被新的 Transformer 换掉），才把语料放进 `corpora`。
  - 命中就经现有的唯一出口 `finishBuild` 结算订阅者，不入打印队列；没命中就入队打印。
  - `cancelBuild`、`evict`、`evictAll` 都找得到处于读取阶段的 `Build`，所以读取途中关掉「Keep Interfaces Searchable」或改 Transformer，读回的语料会被丢弃。
- **出队时再查一次**：`pump()` 出队后、打印前，如果 `corpora` 里已经有同一 Transformer 的语料（被提前读取放进去的），同样经 `finishBuild` 结算，不打印。
- **写盘是构建的结尾**：打印完成、语料放进 `corpora` 之后，在同一个构建任务里编码、写盘，写完才经 `finishBuild` 结算。只写共享缓存里的镜像；文本含绝对进程内指针的镜像不写。服务退出时还没写完的，留下的临时文件之后被清理回收，那个镜像下次照常打印。
- **新增 Core 自己的命令**（`RuntimeEngine.CommandName` 加 `restoreInterfaceCorpora`，属于线上契约；在 `RuntimeEngineCommandRegistrar` 里注册）：
  - 它为每个镜像建一个只读不打印的 `Build`，走同一套读取阶段与结算。
  - 对已经排队打印的同一镜像，读取成功就把它移出打印队列，并通知那里的订阅者。
  - 对正在打印的镜像不读，让它打完。

```swift
extension RuntimeEngine {
    /// Loads into the corpus store whatever corpora the derived data holds
    /// for `imagePaths` under `transformer`, without indexing anything.
    /// Images without stored corpora are left alone; an engine whose serving
    /// process keeps no derived data restores nothing.
    public func restoreInterfaceCorpora(
        for imagePaths: [String],
        transformer: Transformer.Configuration
    ) async throws -> RuntimeInterfaceCorpusRestoreResult
}

/// One image whose corpus came from derived data.
public struct RuntimeInterfaceCorpusRestoredImage: Hashable, Codable, Sendable {
    public var summary: RuntimeInterfaceCorpusBuildSummary
    /// Seconds from opening the file to the corpus being in the store,
    /// validation and the traversal included.
    public var duration: Double
}

public struct RuntimeInterfaceCorpusRestoreResult: Codable, Sendable {
    public var restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage]
}
```

- **覆盖情况里的「已读取」**：
  - `RuntimeInterfaceCorpusCoverage` 新增 `restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage]`，构建路径与提前读取命中的镜像都记在里面。
  - 手写 `init(from:)`，用 `decodeIfPresent(...) ?? [:]`，所以新版本读旧对端发来的覆盖情况照样成功。
  - 这个字典的条目与 `corpora` 同进同出：语料被淘汰、被重新打印替换，条目就去掉。
  - 不给 `RuntimeInterfaceCorpusBuildState` 加 case。
- **对端太旧时**：对端没有 `restoreInterfaceCorpora`，调用就会失败，App 侧把失败当成「什么都没读到」。

### App 侧

- **`FindCorpusCoordinator`**：
  - **提前读取**：后台索引协调器派发这个 Engine 的 Always Index 批次时，把各行解析出的镜像路径交给语料协调器（两者同在 `RuntimeEngineBackgroundWork` 里，由它接线）；语料协调器另外订阅批次事件，收到 `.alwaysIndex` 原因的 `.batchStarted` 时，取其中状态为 `.pending` 的条目。两者合起来、去掉已经有语料的，交给 `restoreInterfaceCorpora`。
  - **读到的镜像和构建完成一样处理**：置为 `.built(summary)`，发出 `corpusBuilt`（正在显示的搜索因此会扩展到它们），并记进 `requestedImagePaths`，改 Transformer 后会被重建。
  - **Report 用的记录**：读到的镜像，以及覆盖情况里 `restoredImagesByImagePath` 中的镜像，记进新的 `restoredImagesByImagePath`。另有一个照 `imagePathsListedInHistory` 写的 `imagePathsListedAsRestored`，让 Clear History 清掉的条目不在下一次刷新时回来。`mergeCoverage` 跳过已读取的镜像，不把它们当作别处建好的构建。
  - **何时去掉**：覆盖情况里某个镜像不再是 built，或者不再在 `restoredImagesByImagePath` 里（被淘汰或被重新打印），就从这一组去掉；Engine 从头来过时清空。
  - Transformer 改了之后照旧整体重建；新的变体写盘时，同一镜像旧变体的文件被删掉。
- **内容区**：`ContentTextViewModel` 的接口来源，在接口为 `nil`、且对象所在镜像还没有 section（`isImageIndexed(path:)` 为假）时，在同一个 `Observable.async` 里调 `objectsWithProgress(in:)` 前台加载、再取一次接口，由现有的 `trackActivity(_commonLoading)` 覆盖，这样加载遮罩仍是唯一的加载状态，符合「一个状态枚举」的规则。前台加载失败，按取接口失败处理。
- **Inspector**：`InspectorRelationshipsViewModel` 与层级的 ViewModel 在 `$runtimeObject` 之外，再跟随引擎的 `imageDidIndexPublisher`；当前对象所在的镜像建好时重取一次。
- **Call Hierarchy 与 Callees**：Find 在用根查询之前，如果根所在的镜像还没有 section，先前台加载它（同一条路），并在 Find 的进度里显示。
- **Report**：
  - `ReportNodeIdentifier` 新增 `restoredCorpora` 与 `restoredCorpus(imagePath:)` 两个 case。
  - 要一起改的地方：`ReportNode.swift` 里 `category` 的穷举 switch，`ReportViewModel` 取消逻辑里的穷举 switch，`ReportTreeBuilder.corpusCategory` 的签名与 `ReportTreeBuilderTests` 里的调用。
  - 新组是 Searchable Interfaces 下第一个嵌套组，要遵守 `ReportOutlineBindingTests` 钉住的递归 `isContentEqual` 约定。
  - 每行细节栏写语料大小与 `duration`。
- **派生数据的客户端与实现**：
  - `RuntimeViewerSettings` 里声明 `DerivedDataClient`，用 `@DependencyEntry` 生成 `\.derivedDataClient`，提供位置、占用大小、删除、在 Finder 中显示四个操作，照 `UpdaterClient` 的做法。
  - 删除与统计的实际逻辑放在 Core 的 `RuntimeDerivedDataMaintenance` 里，与服务进程的自动清理共用，是纯文件系统操作，能在 Core 的测试里用临时目录测。
  - App 层新增 `@MainActor` 的控制器 `RuntimeDerivedDataController`（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/`），作为 `DerivedDataClient` 的实际实现，并负责菜单动作的确认对话框。
  - AppDelegate 只多一条 `@Dependency(\.runtimeDerivedDataController)` 声明，和一个一行转交的 `@objc` 菜单动作。
- **设置页**：`IndexingSettingsView` 底部新增「Derived Data」一节，经 `@Dependency(\.derivedDataClient)` 取用。说明文字讲清存了什么、什么时候作废、删除的后果。
- **菜单**：`MainMenuController.applicationMenuItem()` 在 Simulator App Installer… 之后插入「Delete Derived Data…」。

### 清理规则

由开启了派生数据的服务进程，在第一次用到派生数据时做一次（utility 优先级）：

1. **先刷新自己**：更新本生产者目录的 `LastUsed`。之后每次写盘、以及运行中每隔 24 小时，再各刷新一次，所以连续运行的实例不会被当成没人用。
2. **系统目录**：从目录名解析出 build，不等于当前 build 的，整个删掉。build 相同、共享缓存 UUID 不同的（比如另一种架构的缓存）保留。
3. **生产者目录**：除了自己的，`LastUsed` 超过 14 天没更新的，删掉。同一 bundle id 的多份构建不会互删；同时运行的实例每天都会刷新，也不会被删。
4. **残留**：
   - `DerivedData.deleting-*` 删掉。
   - 超过一天的临时文件删掉。
   - 标记里的进程已经不在、且超过一天的读取标记，连同它旁边的容器一起删掉。

几个进程同时清理不会冲突，因为每条规则都只看时间与 build，且从不删自己的目录。手动删除由 App 进程做：把 `DerivedData` 改名成 `DerivedData.deleting-<UUID>`，在后台删；删到一半退出也没关系，下次清理会回收。不设大小上限，占用大小在设置页里显示。

### 测试

全部用临时目录，绝不碰真实的派生数据目录。新增 `RuntimeViewerCore/Tests/AGENTS.md`（加 `CLAUDE.md` 符号链接，登记进根 `AGENTS.md` 的表）写明这一条；`RuntimeViewerPackages/Tests/AGENTS.md` 已有的「不得碰真实设置与书签」同批扩展到派生数据。

- **Core：容器与校验**：
  - 用 libobjc 与 Foundation 的语料做往返，读回后的搜索结果与读回前逐条相同。
  - 篡改样本，每一种都按「没有缓存」处理、删掉文件、进程不 trap：截断文件、翻转一个字节、伪造 span 长度、三列长度不等、区间不对齐、条目下标次序颠倒或越界、空选项名、带控制字符的选项名。其中文本与 span 几列的样本，另用 `FrozenSemanticString+Codable` 的解码对照，判定要一致；其余几项由本提案的校验单独判定。
  - 读取标记：标记里的进程还活着时不删文件；进程已经不在时连同容器删掉、不解码；读后遍历与投影跑完才删标记。
- **Core：键与身份**：
  - 改动生产者摘要、Transformer 设置、系统身份中的任何一项，都读不到。
  - Transformer 摘要：同样内容、不同数组顺序的两份设置 JSON 解码后摘要相同；以用户的 Debug 与 Release 设置为样本。
  - 生产者摘要经 `digest(of:)` 测：同一组（路径, UUID）结果稳定，换掉其中一个 UUID 就变，顺序不同结果相同。
  - 在临时目录里搭一个假的 `.app` 结构，测 `enclosingApplication(of:)` 的推导：App 本身与 `Contents/XPCServices` 下的 service 得到同一个位置；`Info.plist` 没有那个键的 App、不在 App 包里的位置，得到 `nil`。
  - 没有调用 `enableInThisProcess()` 的进程里，引擎拿不到存储。
- **Core：语料仓库**：
  - 共享缓存以外的镜像不写也不读。
  - 构建路径命中时不打印、订阅者收到结果；读取途中被取消、被淘汰、关掉开关、改 Transformer，读回的语料都被丢弃，订阅者照常结算。
  - 提前读取把排队中的同一镜像移出队列，那里的订阅者收到结果；读取后再请求构建不打印。
  - 写盘在构建结算之前完成；文本含绝对进程内指针的镜像不写。
  - `RuntimeInterfaceCorpusCoverage` 能解码不带新字段的旧 JSON。
- **Core：清理**：
  - 其他 build 的系统目录被删，当前 build 的保留。
  - 14 天没刷新的生产者目录被删，自己的与最近刷新过的保留（模拟两份构建交替使用、一份连续运行）。
  - `DerivedData.deleting-*`、过期临时文件、死进程留下的标记与容器都被回收。
- **Packages**（经 Core 的 internal 注入点给引擎指定临时目录里的存储，测试前用存储的写入接口预先放好容器）：
  - Always Index 批次派发时请求读取；被启发式批次抢先索引的 Always Index 根也读到；`.failed` 条目不读；启发式批次里的其他镜像不提前读。
  - 读到的镜像发出 `corpusBuilt`，正在显示的搜索扩展到它们；出现在 Report 的新组、不出现在构建历史里；Clear History 后刷新不回来；被淘汰或重新打印后行消失。
  - 手动打开的镜像走构建路径读取，不打印。
  - 读取后改 Transformer 会重建。
  - 不支持这条命令的对端退回构建。
  - 内容区对没有 section 的 Swift 对象转为前台加载并最终显示接口（ObjC 类与协议走现有的另一条路，不用它们测这个分支）；Inspector 在镜像建好后重取；Call Hierarchy 的根所在镜像没有 section 时先前台加载。
- **成功标准的测量**：见「成功标准」，在落地第 5 步做。

## 替代方案考量

- **把整张索引图（section）存盘。** 否。理由见「前期调研 › 索引本身为什么不能整体存盘」：要跨四个仓库加恢复路径，编号与身份要原样对得上，出错是静默的，格式还要跟着上游结构一直改。改为先在 App 进程里测量，再存贵且稳定的分析结果。
- **只存语料，不做上游索引加速。** 否。语料之外还有建 section 这一大块，只存语料省不掉它。所以本提案只是第一期，上游那条线另立提案。
- **只在批次开始时读取。** 否（初稿的做法，第一轮审查后推翻）。手动打开的镜像不开批次，已经索引过的根也不开批次。改为构建路径先查盘，提前读取只用来让 Find 早一点可用。
- **任何批次开始时都提前读取。** 否（第一次修订稿的做法，第二轮审查后推翻）。启发式批次深度 1 就带来约 35 个镜像，等于把「启动时全部恢复」这个被用户否掉的选项又做了回来，还把七个常驻镜像的读取排到它们后面。现在提前读取只针对 Always Index，其余走构建路径。
- **从 App 包与「不转发请求」推断是否启用派生数据。** 否（第二轮审查后推翻）。App 进程里的 Bonjour 服务端引擎同样不转发请求，会在 App 进程里读写。改为两个服务入口显式开启。
- **按整个 App 包的磁盘摘要作生产者身份，清理时「不是本 App 当前摘要的就删」。** 否（初稿的做法，第一轮审查后推翻）。同一 bundle id 的多份构建会互删数据，App 被原地重编后，还在运行的旧 service 会给旧代码的产物贴上新摘要。
- **由 App 进程在启动时清理。** 否（第一次修订稿的做法，第二轮审查后推翻）。生产者摘要只有服务进程算得出，App 认不出哪个目录正被使用；启动时的清理还可能删掉这个构建 14 天没开过、正要读的目录。改为服务进程先刷新自己、再按时间清理。
- **等服务空闲 5 秒再写盘。** 否（第一次修订稿的做法，第二轮审查后推翻）。服务进程里没有现成的「空闲」信号；空闲时服务落在后台档，写盘慢 2.5 到 4 倍；短会话退出时还会丢掉没写的部分。改为构建的结尾立刻写。
- **Transformer 摘要用 `JSONEncoder` 加 `.sortedKeys`。** 否（第一次修订稿的做法，第二轮审查后推翻）。`[Pattern: String]` 被编码成无键数组，`.sortedKeys` 排不到它，每次启动摘要都可能不同。改为先排序再算。
- **读取标记在解码后就删。** 否（第一次修订稿的做法，第二轮审查后推翻）。坏的 span 会在搜索时遍历文本才 trap，解码完就删标记罩不住。改为读后遍历与投影都跑过再删，并记下读者的进程。
- **用 protobuf（swift-protobuf）。** 否。
  - 读取要逐个元素解码变长整数，先生成中间的消息对象再转成我们的类型，没法直接映射文件。
  - 它省下的是小整数的字节，压缩之后差别不大（推测，未实测），而大头是文本。
  - 它的长处是新旧版本互相读写和跨语言，派生数据用不上：生产者一变就作废，读写都只有 Swift。
  - 成本是给要构建五个平台加 arm64e 的 `RuntimeViewerCore` 新增依赖，引入 protoc 代码生成，再写一层类型转换。
- **用 FlatBuffers。** 否。数据本来就是扁平数组，用不着它的 schema 工具，却要承担依赖与代码生成。
- **整份语料用 Foundation 的 JSON / plist 编码。** 否。这两种编码器把数组逐个元素当成对象处理，几十 MB、上百万个整数，读写会很慢（推测，未实测）。只把对象、成员、摘要这类不规则的部分交给二进制 plist，并在第 2 步量。
- **给 `RuntimeInterfaceCorpusBuildState` 加一个「已读取」case。** 否。线上编码是 JSON，旧对端遇到不认识的 case 会让整份覆盖情况解码失败。改为加一个手写解码、缺省为空的字段。
- **放在 Application Support，或像 Xcode 那样放在 `~/Library/Developer`。** 否。派生数据可以随时重建，按语义属于 Caches，而且 Caches 不进 Time Machine 备份。
- **生产者身份只认格式版本号，重编后沿用；或者加一个开发者开关。** 否。用户选定代码一变就作废，再配手动清理，绝不读到旧代码产出的数据。
- **交叉引用表一起存盘。** 否。Release 下准备本来只要零点几秒，名字表与预筛表反正存不了，维持 [0056](0056-cross-references.md) 只放内存的决定。
- **覆盖共享缓存以外的镜像、模拟器、注入进程与远程设备。** 否（本期）。非系统镜像的键要加文件身份并处理依赖变化；远程与沙盒进程写不了这个目录，数据得存在 App 侧、来回传输。
- **第二期留在本提案里。** 否（第一轮审查后改）。上游缓存在别的提案里，第二期又要等它的数字，留在这里本提案就永远到不了「完成」。改为本提案第一期落地即收尾，第二期另立提案。

## 影响

### 用户可见变化

- **启动后，Always Index 镜像的文本、正则与成员搜索立刻可用**：系统没更新、代码没换时，后台索引一派发就从磁盘读出这些镜像的语料，不再等打印。Ancestor、Descendant、Conforming Types 与 Type References 读关系表，照旧要等 section。
- **后台索引关着时**（默认）：手动打开一个镜像后，它的语料不再重打，section 建好就能搜。
- **启动时的 CPU**：省下语料打印，它的 CPU 时间至少与建 section 相当（见「代价」）；section 照旧在后台建，交叉引用表照旧准备。
- **新出现的加载状态**：点开一个还没有 section 的镜像里的搜索结果，或以它为根查调用层级时，先前台加载这个镜像，几秒到十几秒后显示。今天不会出现这种情况，因为语料只来自已索引的镜像。
- **Report**：Searchable Interfaces 下新增「Restored from Derived Data」一组。
- **Settings › Indexing**：新增「Derived Data」一节，显示路径、占用大小，带「Show in Finder」和「Delete Derived Data…」。
- **应用菜单**：新增「Delete Derived Data…」。
- **系统更新或 App 升级后的第一次启动**：和现在一样全量建，每个镜像的构建末尾多一次写盘。
- **磁盘占用**：目标是七个常驻镜像 ≤ 200 MB（见「成功标准」）；旧系统版本与 14 天没用过的构建的数据会被自动清掉。

### 可发现性

- 默认开启、不设开关，和 Xcode 的 DerivedData 一样。效果体现为「启动后就能搜」，Report 里看得到读取了哪些镜像。
- 清理入口在设置页和应用菜单里各有一个，设置页的说明文字讲清什么时候会自动作废。

### 数据与配置兼容

- 只新增一个缓存目录，不改动任何已有的设置、书签或文档，不需要迁移。
- 不新增持久化的设置项，`Settings.accessPersistedValues()` 与 `SettingsPersistenceTests` 不受影响。
- **线上兼容**：
  - `RuntimeInterfaceCorpusCoverage` 新增的 `restoredImagesByImagePath` 手写解码、缺省为空。线上编码是 JSON，旧对端会忽略这个字段，新版本读旧对端的数据时按空处理。
  - 新命令 `restoreInterfaceCorpora` 在旧对端上会失败，App 侧按「什么都没读到」处理。
- 旧版本的 App 不认识这个目录，会直接忽略它；新版本读到不认识或对不上的数据，就当作没有缓存，删掉重建。
- 不同配置（Debug、Debug-arm64e、Release）因为 bundle id 不同，各用各的目录；同一配置的多份构建共用目录，按生产者分开，互不删除。

### 平台与最低版本

- 只在 macOS 上生效：内嵌的本地 service 与 Catalyst service。iOS、visionOS 和越狱版的进程里不启用，行为不变。
- 所用的 API 都满足 `RuntimeViewerCore` 的最低版本（macOS 10.15、iOS 13、watchOS 6、tvOS 13）：`NSData.compressed(using:)` 与 CryptoKit 都从这些版本起可用，`sysctlbyname` 所有 Darwin 平台都有，MachOKit 的共享缓存读取在 `canImport(Darwin)` 之下。

### 发布

- 不需要新的 entitlement 或隐私清单条目：服务进程没有沙盒，写的是用户自己的 Caches。
- 不影响公证与 Sparkle。Sparkle 更新会换掉 App 包里的二进制，生产者随之改变，更新后第一次启动重建一次，旧生产者的目录 14 天后被清掉。

## 落地步骤

1. **Core：派生数据基础。**
   - 开启、系统身份、生产者身份（含 `digest(of:)`）、位置、容器读写、读回校验、读取标记、Transformer 摘要、清理与删除（`RuntimeDerivedDataMaintenance`）。
   - 对应测试，加上新的 `RuntimeViewerCore/Tests/AGENTS.md`。
   - 这一步之后，能单独构建、单独测试。
2. **Core：语料快照与语料仓库接入。**
   - 读取阶段、出队再查、构建末尾写盘、`restoreInterfaceCorpora`、覆盖情况的新字段与手写解码、引擎的 internal 注入点、两个服务入口的 `enableInThisProcess()`，加上对应测试。
   - 加一个计时测试，用 Release 配置（`swift test -c release`）对 Foundation 与 SwiftUI 的语料各做一次写盘与读取，记下用时。它只用来决定成员段要不要改成定长列，验收以第 5 步为准。
3. **Packages：App 侧逻辑。**
   - 语料协调器的提前读取、与构建同样的处理、Report 用的记录；内容区的前台加载；Inspector 的重取；Call Hierarchy 根的前台加载；Report 新组。
   - `RuntimeViewerSettings` 里的 `DerivedDataClient`、设置页一节。
   - 两处 `#signpostInterval` 埋点与汇总日志。
   - 对应测试。
4. **App：`RuntimeDerivedDataController`、应用菜单命令、AppDelegate 的一条依赖与一个菜单动作。**
5. **按「成功标准」验收。** Release 构建，两个 Engine 分别测，两次启动，把实测数字记进决策日志；达不到的由用户决定调整方案还是接受。
6. **文档。**
   - 根 `AGENTS.md` 增加一段：派生数据只由开启了它的两个服务进程读写与自动清理，App 只做统计与手动删除；开启的两处入口；新增一种派生数据要走 `RuntimeDerivedDataStore` 并带上种类与变体；只管共享缓存镜像。
   - `RuntimeViewerPackages/Tests/AGENTS.md` 的规则扩展（见「测试」）。
   - 术语表登记「派生数据」「系统身份」「生产者身份」「读取标记」。

第 6 步做完，本提案即可置为 Implemented。

**本提案之外的后续**：
- 上游索引加速，按「上游的索引加速」一节，各仓库另立提案，第一步是 App 进程内的测量。
- 第二期闸门与第二期提案，按「第二期」一节。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、代码本身看不出来的决策」就写实现说明（例如为什么生产者身份要读内存里的映像、为什么清理按最近使用时间、读取标记为什么要等遍历过才删）。写了就登记到头部的「配套文档」。
- **有没有引入新术语**：有就同批次登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-21 | Created as Draft | 每次启动，后台服务都要重建 section、重打 Find 语料、重备交叉引用表，可这些结果只取决于系统镜像与 App 自身的代码。目标是像 Xcode 的 DerivedData 一样，系统没更新就不重建。 |
| 2026-10-21 | 定为完整档 | 新增一层持久化机制，改变「已索引」与启动流程的含义，并推翻此前两次「不落盘」的决定（Find 性能线 2026-09-30、交叉引用 2026-10-18），属于架构级改动。 |
| 2026-10-21 | 范围最初定为两期 | 第一期是存储层，加上语料与对象列表存盘；第二期是侧栏、内容区、跳转直接读派生数据。用户选定（另一个选项是只做第一期）。后被「先第一期与测量」与「第二期另立提案」两行调整。 |
| 2026-10-21 | 只覆盖共享缓存里的系统镜像，以及服务进程在本机、没有沙盒的引擎 | 正对应「系统没更新」这个条件，键只需共享缓存 UUID。用户选定；另两个选项是加上本机的非系统镜像，以及连模拟器、注入进程、远程设备一起做。 |
| 2026-10-21 | 代码一变就作废，另提供手动清理 | 用户选定，并要求能像 Xcode 那样手动清缓存。否掉的是「加一个开发者开关，重编后沿用」：改了打印代码却忘了关开关，就会看到旧的输出。 |
| 2026-10-21 | 交叉引用表仍只放内存 | Release 下准备只要零点几秒；名字表与预筛表存不了；存盘还得要上游加编码接口。用户选定。 |
| 2026-10-21 | 凡是建过的系统镜像都存，启动时只恢复 Always Index 的镜像 | Find 的搜索范围与现在一致；其余镜像在被索引时直接从磁盘读取。用户选定；另两个选项是只存 Always Index 的镜像，以及启动时全部恢复。第二轮审查后的「提前读取只针对 Always Index」一行按这条决定落实。 |
| 2026-10-21 | 清理入口放在设置页和应用菜单，位置固定 | 用户选定；否掉的是只放设置页，以及像 Xcode 的 Locations 那样可改位置。 |
| 2026-10-21 | Report 里单独显示「从磁盘恢复」，后台补建照常显示 | 用户选定；另两个选项是不显示恢复，以及都不显示。 |
| 2026-10-21 | 第二期的五条决定先记为暂定 | 语料跟随当前成员排序（用户自己用按偏移排序）、对象列表存盘、读取后在后台补建 section、Inspector 等 section 建好、关掉语料开关仍打印，都是讨论第二期时用户选定或确认的。「读取后在后台补建」用户没选推荐的「只在用到时才建」，理由是更看重读取后所有功能都不用等。这几条现作为第二期提案的输入。 |
| 2026-10-21 | 索引也要加速：先量先修，再存分析结果 | 用户要求索引也纳入。整张索引图存盘代价太大，用户选定「先在 App 进程里测量、修掉能修的，再把贵的分析结果存盘」；否掉的是「整张索引图存盘」与「不先测量就直接缓存」。当时依据的命令行归因有两处后经审查证伪，见下面「实测归因更正」一行；这个选择本身不受影响，测量先行反而更有必要。 |
| 2026-10-21 | 先做第一期与测量，再定第二期 | 上游缓存若能把 section 的建立压到一两秒，第二期大部分复杂度可能都不需要。用户选定；否掉的是「两期照做、并行推进上游」与「先做上游」。 |
| 2026-10-21 | 对象列表挪到第二期；第一期的语料仍按类别排序 | 第一期还不能「不建 section 就浏览」，先存对象列表用不上；Find 的结果本来就带着对象信息。存储的键给排序方式预留了一层。agent 提出，用户确认。 |
| 2026-10-21 | 文件格式用自定义的扁平二进制，加系统 Compression 压缩；不用 protobuf | 用户问到 protobuf，讨论后采纳了这个建议。理由见「替代方案考量」。实测 LZFSE 对两份接口文本压缩 6–9 倍；语料本身的压缩率另量。 |
| 2026-10-21 | swift-semantic-string 不需要改动 | 写提案前核实到，所需类型的字段与初始化器都是 public，RuntimeViewer 自己就能编解码。 |
| 2026-10-21 | 第一轮对抗审查 | 用户要求开多个 agent 对抗审查。四位审查者并行，分别侧重缓存键与失效、架构集成、性能论断与证据、范围与验收，合并后 4 🔴、12 🟡、9 🔵（[报告](../Reviews/2026-10-21-draft-derived-data-review.md)）。用户同意按审查意见修改，以下到「第二轮对抗审查」之前的各行是第一次修订的处理。 |
| 2026-10-21 | 实测归因更正 | 初稿说「已经看到两处重复劳动」：符号表被解混淆两遍，地址空间对象被反复重建。审查与主 agent 复核证实这两处都不成立：前者其实是每个跳板重扫一遍符号表，调用子树里没有解混淆；两处又都只在命令行读磁盘文件的 `MachOFile` 路径上，App 走 `MachOImage`，不经过它们。SwiftUI 的合计从 10.9 秒改为 8.8 秒（多算了命令行自己收集模块的 2.2 秒），AppKit 的归因与样本换算也不可靠。命令行数字现在只作粗略参考，上游先修什么、存什么，以 App 进程内测量为准。 |
| 2026-10-21 | 读取改为两条路径：构建路径先查盘，再加提前读取 | 初稿只在 Always Index 批次开始时读取，会漏掉手动打开的镜像、已经索引过的根，以及被启发式批次抢先索引的根；后台索引默认关闭时，更是只写不读。现在任何建语料的请求都先查盘。提前读取的范围在第二轮审查后收窄，见「提前读取只针对 Always Index」一行。 |
| 2026-10-21 | 读回校验补全，并用读取标记防止崩溃循环 | 初稿的校验漏了 `Requirement.init` 的 `precondition`、span 三列长度、区间对齐与下标次序，这些都会在构造对象时 trap；而启动和重连都会读取，坏文件能让「My Mac」的服务反复崩溃。标记的做法在第二轮审查后加强，见「读取标记等遍历过再删」一行。 |
| 2026-10-21 | 生产者身份改为本进程在内存里的映像，清理按 build 与「14 天没用过」 | 初稿按整个 App 包的磁盘摘要定身份，并删掉「不是本 App 当前摘要」的目录。这样同一 bundle id 的多份构建会互删，App 被原地重编时还可能给旧代码的产物贴上新摘要。四位审查者都提到了这一点。14 天由 agent 提出，用户可推翻。哪些映像算数、清理由谁做，在第二轮审查后定准，见后面两行。 |
| 2026-10-21 | 点开还没有 section 的镜像里的结果时，转为前台加载 | 读取让「搜得到但没有 section」第一次成为可能，内容区原本会一直空着。第二轮审查后补上了 Inspector、Call Hierarchy 与失败分支，见「还没有 section 的镜像，几处入口一起补」一行。 |
| 2026-10-21 | 「已读取」放进覆盖情况的一个新字段，不加枚举 case；Report 新组的生命周期写明 | 线上编码是 JSON，旧对端遇到不认识的 case 会让整份覆盖情况解码失败。字段的类型、解码方式与 Report 的细节在第二轮审查后定准，见「覆盖情况的新字段与 Report 新组定准」一行。 |
| 2026-10-21 | 读取与在途构建的先后、Transformer 改动后的重建写明 | 出队时再查一次仓库；读取成功会把排队中的同一镜像移出队列；读到的镜像记进 `requestedImagePaths`，改 Transformer 后会被重建。读取怎样并入构建模型，在第二轮审查后定准，见「读取是构建的一个阶段」一行。 |
| 2026-10-21 | 含绝对进程内指针的镜像不写盘 | opaque type 符号引用解析不出名字时，会打印带滑动的进程内指针，重启后失效。上游改为打印未滑动地址之前，这类镜像不写。 |
| 2026-10-21 | 设置页经 `RuntimeViewerSettings` 里的 `DerivedDataClient` 取用，清理与删除的逻辑放 Core | 设置页所在的 package 引用不到 App target；App 工程也没有可用的测试 target。照 `UpdaterClient` 的先例处理。 |
| 2026-10-21 | 目录元数据与删除的收尾 | 每次写盘前补齐各级元数据；清理只依据目录名与时间，不依赖 `Info.plist`；手动删除先把根目录改名移开再删，残留由清理回收。 |
| 2026-10-21 | 上游缓存的键放在共享缓存 UUID 之下，读回成本同样要量 | 符号库不全是扁平的表，ObjC 成员表还会读别的镜像，所以上游缓存不能按单个镜像独立定键。写进「上游的索引加速」一节。 |
| 2026-10-21 | 加上成功标准 | 起初的目标是：启动后 3 秒内七个镜像全部可搜，单个镜像读取不超过 0.5 秒，第二次启动不打印语料，占用不超过 200 MB；达不到时由用户决定。具体数值由 agent 提出，用户可推翻。测法在第二轮审查后定准，见「成功标准按 Engine 分开」一行。 |
| 2026-10-21 | 第二期另立提案，本提案第一期落地即收尾；闸门写明测什么、参考线 2 秒 | 第二期要等上游缓存的数字，而上游在别的提案里；留在这里，本提案就永远到不了「完成」。这调整了「两期写在同一份提案」的最初安排，由 agent 按审查意见提出，用户可推翻。 |
| 2026-10-21 | 标题与摘要改为第一期实际交付的内容 | 初稿标题承诺「系统没更新就不重建」，可第一期只做到「语料不重打」，section 照旧重建。现在标题、摘要与「用户可见变化」都写明这一点。 |
| 2026-10-21 | 第二轮对抗审查 | 用户要求做第二轮，有问题直接修，修完提交推送。同样四位审查者，除了找新问题，还逐条核对第一轮是否闭环，合并后 1 🔴、17 🟡（[报告](../Reviews/2026-10-21-draft-derived-data-review-round-2.md)）。以下各行是这一版的处理。 |
| 2026-10-21 | Transformer 摘要改为先排序、再算 | 两位审查者独立指出：`[Pattern: String]` 被编码成无键数组，`.sortedKeys` 排不到它，摘要每次启动都可能不同，用过 C 类型替换预设的用户（包括作者自己）会永远读不到、还删掉上次写的文件。现在先按 `Pattern.rawValue` 排序成规范形式，测试用用户自己的 Debug 与 Release 设置作样本。 |
| 2026-10-21 | 提前读取只针对 Always Index | 第一次修订稿让任何批次开始时都提前读取，启发式批次深度 1 就带来约 35 个镜像，等于又做回了用户否掉的「启动时全部恢复」，还把常驻镜像的读取排在后面。现在提前读取的是这个 Engine 的 Always Index 各行解析出的镜像（包括被别的批次抢先索引的），加上 Always Index 批次里 `.pending` 的条目；`.failed` 条目不读；其余镜像走构建路径。 |
| 2026-10-21 | 读取是构建的一个阶段 | 第一次修订稿只说「在仓库外解码」「出队时跳过」，没有并入现有的 `Build` 与订阅者模型：照字面跳过会让订阅者永远等不到结果，App 也就永远进不了 App Nap；读取途中关掉开关，语料还会被塞回仓库。现在读取是 `Build` 的第一个阶段，经唯一的出口结算，取消、淘汰都找得到它，读回后先核对 identifier。 |
| 2026-10-21 | 写盘改为构建的结尾，撤回「空闲 5 秒后写」 | 服务进程里没有现成的「空闲」信号；空闲时服务落在后台档，写盘慢 2.5 到 4 倍；短会话退出时还会丢掉没写的部分。现在语料先放进仓库供搜索，然后在同一个构建任务里写盘，写完才结算，所以 Report 里构建完成就意味着已写盘。 |
| 2026-10-21 | 读取标记等遍历过再删，并记下读者的进程 | 坏的 span 会在搜索时遍历文本才 trap，解码完就删标记罩不住；同一构建开了两个实例时，还会把对方正在读的文件当成坏文件删掉。现在标记记录 PID 与启动时间，读后对每条语料完整遍历一次、按全开与全关各投影一次，都通过才删；清理时标记与容器成对删除。「一天」这个时限由 agent 提出，用户可推翻。 |
| 2026-10-21 | 生产者身份定准：含有 RuntimeViewerCore 的映像加它的非共享缓存依赖 | 「本进程从 App 包里加载的全部映像」有两种读法，按「第一次用到时已加载的全部」理解，经 Load Frameworks… 载入的东西会改变摘要；而 Debug 构建可能从 App 包外的构建产物目录加载代码。现在只算含有 Core 的那个映像（本地 service 的可执行文件、Catalyst service 的插件）与它在本进程里加载的非共享缓存依赖，不论它们在包内还是包外；找不到含有 Core 的映像就不启用。 |
| 2026-10-21 | 清理改由服务进程做，并定期刷新使用时间 | App 算不出服务进程的生产者摘要，认不出哪个目录正被使用；使用时间每个进程只刷新一次时，连续运行超过 14 天的实例会被别的构建清掉，启动时的清理还可能删掉这个构建正要读的目录。现在由服务进程第一次用到派生数据时先刷新自己、再清理，并在每次写盘与每 24 小时刷新一次。 |
| 2026-10-21 | 由两个服务入口显式开启，不再从 App 包与引擎角色推断 | App 进程里的 Bonjour 服务端引擎同样不转发请求，收到的命令在 App 进程里执行，按旧的推断它也会拿到派生数据，与「只在服务进程里读写」相反（审查者认为另一台 Mac 的 Find 会经它在本机建语料；主 agent 核实到它是 `pushesRuntimeData: false` 的管理用引擎，这一点没有坐实，但显式开启不依赖它）。现在 `RuntimeViewerLocalRuntimeService/main.swift` 与 `AppKitPluginImpl.runService()` 各调用一次 `RuntimeDerivedData.enableInThisProcess()`。 |
| 2026-10-21 | 覆盖情况的新字段与 Report 新组定准 | 新字段 `restoredImagesByImagePath` 带每个镜像的大小与读取用时，构建路径命中的镜像也有用时可显示；合成的 `Codable` 解不了缺这个键的旧 JSON，所以手写 `init(from:)`；条目与 `corpora` 同进同出。协调器另记 `imagePathsListedAsRestored`，Clear History 后刷新不会让它们回来；读到的镜像发出 `corpusBuilt`，正在显示的搜索会扩展到它们。 |
| 2026-10-21 | 还没有 section 的镜像，几处入口一起补 | 内容区的前台加载放进同一个取接口的任务，由现有的加载遮罩覆盖，失败按取接口失败处理。Inspector 原本只跟随对象取数据，镜像建好后不会重取，现在也跟随 `imageDidIndex`。Call Hierarchy 与 Callees 的根如果落在没有 section 的镜像里，先前台加载，否则会漏掉同一镜像里的调用者。前期调研里「返回 nil、等批次结束」的现状描述不准，一并改正：ObjC 类与协议走按类名现建 section 的另一条路，拿到 `nil` 后内容区会一直空着、直到重新导航。 |
| 2026-10-21 | 成功标准按 Engine 分开，写明起止点与读数 | 用户的七个镜像分属两个 Engine（五个在 My Mac，两个在 Mac Catalyst），一个文档里看不到全部。现在两个 Engine 各测一次；起点是 Always Index 派发、开始提前读取，终点是最后一个镜像可搜，用 signpost 与汇总日志读数；「冷启动」指重新启动 App、不清文件系统缓存；单镜像用时从开始读文件算到放进仓库。 |
| 2026-10-21 | 摘要与「代价」改正 CPU 的说法 | 第一次修订稿说 section 与交叉引用是启动时 CPU 的大头。实测相反：AppKit（Debug 探针）建 section 约 28 秒 CPU、打印语料约 40 秒 CPU，SwiftUI（Release）打印语料约 22 秒 CPU；交叉引用表在 Release 下只要零点几秒。现在写明第一期省下的语料打印至少与建 section 相当，Release 下的比例没有直接测过。 |
| 2026-10-21 | 上游测量移出本提案的落地步骤 | 第一次修订稿把 App 进程内的测量既列为上游那条线的第一步，又列为本提案第 1 步，本提案能否在没做测量时收尾就有两种读法。现在它只属于上游那条线；本提案第 6 步做完即收尾。 |
| 2026-10-21 | 测试补上注入点与漏掉的用例 | 生产者摘要经 `digest(of:)` 测；Packages 测试经引擎的 internal 注入点拿到临时目录里的存储；补上读取途中取消与淘汰、旧 JSON 解码、提前读取的范围、读到的镜像扩展正在显示的搜索、Inspector 重取等用例。 |

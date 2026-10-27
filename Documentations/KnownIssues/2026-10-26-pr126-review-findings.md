# PR #126 代码审查记录 — 2026-10-26

审查对象：PR #126（`feature/derived-data` → `next`，提案 [派生数据](../Evolutions/0061-derived-data.md)的实现），head `19fbf018`，基线 `next` `0c086cd7`。

**经过**
1. `/code-review xhigh` 交回 15 条发现，没有会崩溃的正确性问题；GitHub 上 Codex 的自动审查另有一条（内容区的竞态）。
2. 每条都回到代码复核，按四问作答：能否复现、基线上有没有、值不值得修、以前修过没有。复核时只读代码、追调用路径，没有跑探针；复核中另找到一处与 PR126.1 同类、审查漏掉的实例（PR126.17）。
3. 用户批准：要修的 3 处与顺手修的 8 处在本分支上修，其余记为不修或误报。要修的行为问题都先写了修复前失败的测试，亲眼看到它红，再修到绿。
4. 修完后跑了完整验证（App 构建，Core、Packages、MCP 全量测试），并在同一台机器上对照 next 跑了 Core 全量，没有回归。红灯的逐条判定写在提案决策日志 2026-10-26「修复后的完整验证」一行。

**约定**
- ID 为 `PR126.<N>`：1–15 按审查交回的顺序，16 是 Codex 的那条，17 是复核中找到的同类实例。
- 四问里的「基线」是 `next` `0c086cd7`；行号按审查时的 PR 分支 `19fbf018`。
- 下文两个词：「建索引」指引擎给一个镜像建好 ObjC 与 Swift 两份 section，打开镜像、查交叉引用都靠它；「语料」是 Find 文本搜索用的全部接口文本。这个 PR 让语料能从派生数据读回，于是第一次出现了「搜得到、但还没建索引」的镜像，多数发现都出在这个新状态上。

## 条目

| ID | 问题 | 严重度 | 处理 |
|---|---|---|---|
| PR126.1 | Find Type References 不先为没建索引的镜像建索引，漏掉类型自己镜像里的引用 | Major | 已修（`3847f33a`）：与 Call Hierarchy 一样先建索引；测试 `typeInAnUnindexedImageIsIndexedFirst` |
| PR126.2 | 改 Transformer、或把语料开关关了再开之后，读回而没建索引的镜像从搜索里消失 | Minor | 已修（`3847f33a`）：开关重开时再读一次，改 Transformer 后被拒的构建改为读回；测试 `switchOffAndOnReadsAgain`、`transformerEditTakenBackReadsAgain` |
| PR126.3 | 内容区的回退对任何「接口为空且镜像没建索引」的对象都加载镜像，不限于读回的搜索结果 | — | 不修：设计如此 |
| PR126.4 | 读回期间，Report 把正在读的镜像列成排队中 | Minor | 已修（`3847f33a`）：正在读的镜像不取引擎的说法；测试 `coverageWhileReadingListsNothingQueued` |
| PR126.5 | 语料仓库打印队列的注释写「按请求顺序」，实际是按读盘结束的先后入队 | Nit | 改注释（`c3fceda8`） |
| PR126.6 | 容器的解压长度只限 `≤ Int.max`，等于 `Int.max` 时溢出崩溃 | Minor | 已修（`c3fceda8`）：上限 1 GiB；测试 `oversizedDecodedLength` |
| PR126.7 | 写一种数据时按「种类名-」前缀删别的变体，种类名互为前缀时会误删 | Nit（潜在） | 已修（`c3fceda8`）：种类名只许 ASCII 字母与数字；测试 `kindNames` |
| PR126.8 | 写完盘才让出打印位，下一个镜像的打印要等写盘 | — | 不修：属于优化，暂不做 |
| PR126.9 | 写盘的文件操作在存储的 actor 上执行 | — | 不修：毫秒级，可以忽略 |
| PR126.10 | Always Index 的读回有两个触发点，审查认为重复 | False positive | 不修：两处各管一类，有测试 |
| PR126.11 | 「搜得到但没建索引」在各个消费者里分别处理，没有集中到一处 | — | 不改架构：补上漏掉的两处（PR126.1、PR126.17），更新实现说明的入口清单 |
| PR126.12 | Inspector 每次换选中对象多问一次「建好了吗」 | — | 不修：与取数据同时发出，可以忽略 |
| PR126.13 | 测试 `concurrentReadsJoin` 靠 0.2 秒的 sleep | Minor | 已改（`c3fceda8`）：数出等待的读者再放行，去掉 sleep |
| PR126.14 | `infoData`、`info` 是缩写；全库另有既有的同类 | Nit | 已改（`7340ba1c`），连同既有的 13 处（审查列出 5 处，复核又找到 8 处） |
| PR126.15 | `RuntimeDerivedDataController` 的 `measure()`、`showInFinder()` 只在类内部用，却是 internal | Nit | 已改为 `private`（`7340ba1c`） |
| PR126.16 | 内容区第一次取接口为空、恰好这时镜像建完，就一直空白（Codex） | Minor | 已修（`3847f33a`）：不论是否已建好都再取一次；测试 `contentInterfaceAskedForAgain` |
| PR126.17 | Inspector 的 References 页签在镜像建好后不重取（复核中找到） | Minor | 已修（`3847f33a`）：照另外两个页签跟随 `imageIndexedLater`；测试 `inspectorReferencesRefetchOnceIndexed` |

## PR126.1 — Find Type References 漏掉类型自己镜像里的引用

- **问题**：`FindSession.loadLevel` 只对 `.calls`（Call Hierarchy、Callees）先为没建索引的根镜像建索引，`.typeReferences` 直接交给引擎，而交叉引用只扫已建索引的镜像。
- **复现**：开着 Always Index 启动 App，AppKit 在后台建索引的那几十秒里，在 Find 搜到 `NSWindow` 并打开（ObjC 类按类名现建 section 显示，不触发建索引），再点 Find Type References：类型自己的镜像被排除在外，结果几乎为空，看起来却像已经查完；镜像在服务进程里还没加载时直接报错。测试 `typeInAnUnindexedImageIsIndexedFirst`：一个没建 Foundation 索引的引擎上查 `NSMutableString` 的 Type References，修复前等不到「Loading Foundation」。
- **基线**：有，但很少碰到——`next` 上只有经 ObjC 跳转进入「已加载、未建索引」的镜像时才会这样；这个 PR 让它成了启动后的常见路径。
- **修法**：`LoadRequest` 多一个 `imagePath`（调用的主体或类型所在的镜像），`loadLevel` 对两种请求都先 `indexImageIfNeeded(at:)`，摘要栏同样显示「Loading <镜像名>」。内容区右键、主菜单、Inspector 的 Show in Find Navigator 都经 `loadLevel`，一处修好全部入口。
- **历史**：「只扫已建索引的镜像」是交叉引用为性能特意定的（`9b1dda25`，2026-10-18：当时扫整个共享缓存会占满所有核），这个理由仍然成立。提案与它的第一轮审查把 Type References 当成「读关系表、不读语料」的 Find 模式，只想到 Find 页自己发起的查询，漏了从内容区、菜单、Inspector 发起的请求。以前没修过。

## PR126.2 — 读回的镜像在改 Transformer、开关重开后消失

- **问题**：改 Transformer 后的重建（`scheduleTransformerRebuild`）对每个请求过的镜像只发构建请求；引擎对没建索引的镜像直接回 `.imageNotIndexed`，构建请求根本走不到读盘那一步，而读回也没人再发。开关关了再开时，`requestBuildOfIndexedImages()` 只覆盖已建索引的镜像，读回的镜像连请求都没有。`restoreCorpora(of:)` 的注释还写着「改 Transformer 时会重新请求」。
- **复现**：测试 `switchOffAndOnReadsAgain`、`transformerEditTakenBackReadsAgain`：读回 libobjc（不建索引）后，关开关再开，或改 Transformer 再改回来，修复前 libobjc 都再也读不回来。
- **影响**：比审查说的小。盘上每个镜像只留一份语料，换成新的 Transformer 本来就读不回来，只能等后台索引轮到它再打印。真正吃亏的是开关关了再开、以及把 Transformer 改回原样：要等后台索引轮到这些镜像；用户取消过 Always Index 批次的话，这次运行就一直搜不到。
- **基线**：没有，读回是这个 PR 新加的。
- **修法**：协调器记下请它读回过的镜像（`requestedRestoreImagePaths`，与记构建请求的 `requestedImagePaths` 对应；开关关着时请求的也记下）。开关重新打开时，把它们再读一次；改 Transformer 后的重建照旧对每个请求过的镜像发构建请求，被引擎以「没建索引」拒绝的，若在这份清单里就改为读回。读回放在拒绝之后而不是与构建请求同时发出：同时发出时，读回若先于拒绝返回，协调器会把状态留给构建，构建随后被拒，状态就被清成「没建」，而语料其实已在引擎里。
- **历史**：以前没修过。

## PR126.3 — 内容区的回退不限于读回的搜索结果（不修）

- **问题**：审查认为，接口为空且镜像没建索引就前台加载，会波及书签、恢复的标签页、远程或注入引擎上的对象，悄悄把镜像加载进被检查的进程。
- **为什么不修**：方案明确写的就是「接口为 nil 且镜像没建索引，就前台加载」。审查举的书签、恢复标签页两条路其实走不到：书签只在已打开镜像的页面里显示，App 也不跨启动恢复选中的对象。能走到的路径（在交叉引用里点到别的镜像的类型、Engine 重启后再导航）里，加载用户点开的那个镜像正是想要的结果，和侧栏的 Load 一样。
- **何时重新审视**：App 开始跨启动恢复选中的对象或标签页时。

## PR126.4 — 读回期间 Report 把镜像列成排队中

- **问题**：引擎的语料仓库把读取中的构建一律报成 `.pending`。读回中的镜像在协调器里没有构建请求，`mergeCoverage` 对「没有请求的镜像」取引擎的说法，于是 Report 在启动读回期间把它们列进「排队或打印中」，还因为「别的连接在建」而开始每两秒轮询。
- **复现**：测试 `coverageWhileReadingListsNothingQueued`：读回 libobjc 的同时并入一份把它报成 `.pending` 的覆盖情况，修复前它就被记成排队中。
- **基线**：没有，读回是这个 PR 新加的。
- **修法**：`mergeCoverage` 跳过正在读回的镜像，它们的状态由读回的结果决定。仍可能剩一个窄窗口：读回期间发出、读回结束后才到的覆盖情况，会让一行「排队中」留到下一次轮询（最多 2 秒）；窗口只有一次往返宽，不再处理。
- **历史**：「没有请求的镜像按引擎的说法显示」是 Find 导航栏那次（`8ce77d36`，PR #121）特意定的，用来显示别的窗口发起的构建；那时还没有读回，所以没考虑进去。以前没修过。

## PR126.5 — 打印队列的注释（改注释）

- **问题**：`pendingImagePaths` 的注释写「按请求顺序」。先读盘的构建在读不到时才入队，位置是 `queueIndexAfterReading ?? count`，一起请求的几个镜像按读盘结束的先后入队。
- **为什么只改注释**：读不到的读盘都很快，顺序基本不变，界面上看不出来。

## PR126.6 — 解压长度没有上限

- **问题**：分段的解压长度只校验 `≤ Int.max`。`decompressed` 分配 `decodedByteCount + 1` 字节的缓冲区：长度正好是 `Int.max` 时加一溢出、进程崩溃；长度特别大时分配本身就可能失败。
- **复现**：测试 `oversizedDecodedLength`：把一个合法文件的解压长度改成 `Int.max`（校验和照样改对），修复前读它的测试进程崩溃。
- **影响**：要伪造一个校验和全对的文件才能触发；读取标记保证最多崩一次，下次启动会把那个文件删掉。但它违背了格式自己的承诺：读者会 trap 的条件都要在用之前查过。
- **修法**：解压长度上限 1 GiB（`maximumDecodedSectionByteCount`）。实测最大的单个镜像 AppKit 解压后全部分段才 31 MiB，这个上限留了三十多倍余量；万一真有超过的分段，结果只是读不回、重新打印。
- **历史**：方案的两轮审查只查了快照层会崩的地方，没看到容器层的这里。以前没修过。

## PR126.7 — 种类名互为前缀会误删（潜在）

- **问题**：`removeOtherVariants` 按文件名以「种类名-」开头删除同一镜像的其他变体。变体本身就带连字符（例如 `0123456789abcdef-ByCategory`），若将来有一个种类叫 `InterfaceCorpus-Members`，它的文件会被当成 `InterfaceCorpus` 的变体，每写一次 `InterfaceCorpus` 就被删掉一次。
- **复现**：现在只有一种数据，不会发生；实现说明第七节在教人新增种类，所以现在就堵上。测试 `kindNames`：带连字符或为空的种类名让进程以前置条件失败退出，修复前不会。
- **修法**：`RuntimeDerivedDataKind.init(rawValue:)` 加前置条件：种类名非空、只用 ASCII 字母与数字。种类名里没有连字符，「种类名-」这个前缀就只可能是这个种类自己的文件。实现说明第七节同步写明这条规则。
- **历史**：以前没修过。

## PR126.8 — 写完盘才让出打印位（不修）

- **问题**：语料打印完先放进仓库、写盘、再结束构建，单一的打印位在写盘期间一直占着，排在后面的镜像要等编码、压缩与写盘。
- **为什么不修**：「构建结束就意味着已写盘」是方案在 10-21 决策日志里定的：App 在等这次构建时，服务进程沿用 App 请求的优先级，写盘才不会被拖到后台档。审查给的改法（先让出打印位、回复仍等写完）两个目的都不丢，是可行的优化；估计每个大镜像多花零点几秒（没实测），相对几十秒的打印只是几个百分点，而且只在系统更新、或换了 App 构建后的第一次启动才发生。
- **何时重新审视**：实测写盘在打印总时长里占得明显更多时。

## PR126.9 — 写盘在存储 actor 上（不修）

- **问题**：`store()` 的写文件、改名、列目录都在 `RuntimeDerivedDataStore` 这个 actor 上执行；同时进行的读取要等它。
- **为什么不修**：几 MB 写进 SSD 是毫秒级，同时进行的读取只多等这么一下，可以忽略。

## PR126.10 — 两个读回触发点（误报）

- **问题**：审查认为 Always Index 的读回有两个重复的触发点：后台工作转来的 `alwaysIndexImagePathsResolved`，以及协调器自己跟随的 `.batchStarted` 事件。
- **为什么是误报**：两处覆盖的情形不同。前者在 Always Index 各行派发时读回根镜像，包括根已被别的批次抢先在建、因而收不到「Always Index 批次开始」事件的情况；后者在批次开始时读回它的依赖。协调器会去重，两次请求的内容不重叠。提案决策日志写明了原因，测试 `alwaysIndexDispatchReads` 与 `alwaysIndexBatchStartReads` 分别覆盖。

## PR126.11 — 「搜得到但没建索引」分散处理（不改架构）

- **问题**：内容区、Inspector 的两个 ViewModel、`FindSession.loadLevel` 各自处理这个新状态，新消费者容易漏，Type References（PR126.1）就是一个。
- **为什么不改架构**：分散处理确实漏了两处，即 PR126.1 与 PR126.17，已补上。审查建议的集中做法行不通：放进引擎会推翻交叉引用「只扫已建索引的镜像」那条性能规矩（PR126.1 的历史）；在打开搜索结果时统一建索引，各处仍然要在建好后重新取一次。实现说明 [`DerivedData.md`](../DerivedData.md) 第六节的入口清单已更新，新消费者照着它查。

## PR126.12 — Inspector 多问一次「建好了吗」（不修）

- **问题**：`imageIndexedLater` 让每次换选中对象多一次 `isImageIndexed` 的往返；远程引擎上多一点延迟与流量。
- **为什么不修**：这次询问和真正的取数据同时发出，不会让取数据变慢，消息也极小。PR126.17 让 References 页签也这样做，同样可以忽略。

## PR126.13 — 并发读测试靠 sleep

- **问题**：`concurrentReadsJoin` 假定 8 个任务都在第一次解码睡的 0.2 秒内调到 `store.read`。满载跑全量时，晚到的任务会自己发起一次读，解码次数变成 2，测试误报失败，产品本身没问题。
- **复现**：把其中一个任务推迟 0.3 秒再读，旧测试失败，解码了 2 次（临时加的一份旧测试，验证后删掉）。
- **修法**：存储加一个测试接口 `readerCount(of:variant:forImageAt:)`，数出等在同一次读上的读者；测试让解码先停住，等 8 个读者都到齐再放行，不再依赖时间。照语料仓库已有的 `subscriberCount(for:)` 的做法。新测试保留了那个晚到 0.3 秒的读者，照样通过。

## PR126.14 — 缩写

- **问题**：`RuntimeDerivedDataLocation.swift:57-58` 的 `infoData`、`info` 是缩写，违反「任何缩写都不允许」的规则；同一 PR 的 `RuntimeDerivedDataStore` 里写的是 `informationFileName`。
- **横向排查**：全库另有 `next` 上原本就有的同类局部名，一并改掉。审查列出 5 处：`RuntimeEngineProxyServer.swift`（`connectionInfo` 的局部名）、`DyldUtilities.swift`（`Dl_info`）、`RuntimeSwiftSection.swift`（协议约束）、`RuntimeInterfaceExportMetadata.swift` 与 `UpdaterClient.swift`（`infoDictionary`，后者顺带把 `short` 改成 `shortVersionString`）；复核时对全部被跟踪的 Swift 文件再搜一遍，又在 `RuntimeViewerMCP/Tests/RuntimeViewerMCPBridgeTests/MCPBridgeProtocolTests.swift` 找到 8 处 `let info`，按所装的类型改成 `typeInformation`、`memberAddressInformation`、`windowInformation`。只改局部名；`connectionInfo`、`RuntimeViewerInfo`、`MCPRuntimeTypeInfo` 这类对外的 API 名与 Apple 的 `infoDictionary` 不动。其它种类的缩写（如 `ptr`）不在这次排查的范围内。

## PR126.15 — 访问级别

- **问题**：`measure()`、`showInFinder()` 只经 `install()` 里设的闭包在类内部调用，却是 internal；AppDelegate 只用 `install()` 与 `confirmAndDeleteAll()`。
- **修法**：改为 `private`。

## PR126.16 — 内容区可能一直空白（Codex）

- **问题**：`ContentTextViewModel` 第一次取接口拿到 `nil`，下一步问「镜像建好了吗」；后台索引恰好在这两步之间建完时，代码直接返回 `nil`。内容区不会因为数据变化重新取，一直空着，直到用户重新导航。
- **复现**：测试 `contentInterfaceAskedForAgain`：第一次取接口返回空、而镜像这时已经建好索引，修复前不再取第二次。为此把这段逻辑从初始化闭包里抽成内部静态函数 `ContentTextViewModel.interface(of:fetchingWith:runtimeEngine:)`，「向接口缓存取接口」作为参数传进去（用户批准的测试接口）。
- **基线**：没有，回退是这个 PR 新加的；`next` 上那时本来就是空白。
- **修法**：不论是否已建好都再取一次：`indexImageIfNeeded(at:)` 对已建好的镜像什么都不做。空结果本来就不缓存，多一次往返只发生在真的取不到接口的对象上。
- **历史**：以前没修过。

## PR126.17 — Inspector 的 References 页签不重取（复核中找到）

- **问题**：同 PR126.1 的流程下，References 页签显示「AppKit is not indexed… load it first」；镜像随后建好，页签仍停在这句话，要重新选中对象才更新。这个 PR 给 Inspector 另外两个页签（Hierarchy、Relationships）加了「建好后重取」，唯独没给它加。
- **复现**：测试 `inspectorReferencesRefetchOnceIndexed`：没建 Foundation 索引的引擎上，`NSMutableString` 的 Type References 先报未建索引；加载 Foundation 之后，修复前一直停在那里。
- **基线**：有，`next` 上同样不刷新，但那时几乎碰不到。
- **修法**：每个分区的查询照另外两个页签跟随 `imageIndexedLater`，镜像建好时再问一次；页签本身仍不主动建索引，与另外两个页签一致。
- **历史**：以前没修过。

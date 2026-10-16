# 2026-10-16 同一个 Engine 再开一个文档：Report 里冒出一排 0 images，关掉或切走它还会取消前一个窗口的索引

**调查日期：** 2026-10-16
**修复落地：** 本日，`next`
**Severity：** Medium —— 已经在建的镜像照样建完，没有数据丢失；但每个窗口的 Report 被没有内容的批次刷屏，Engine 被整体 reload 多次（每次都重载所有窗口的侧栏、清空接口缓存）；关掉或切走第二个窗口会取消第一个窗口正在跑的批次，跟随依赖的批次剩下的镜像从此不再建
**触发场景：** 同一个 Engine（新文档默认都在 My Mac）上已有文档做过或正在做后台索引，再新建一个文档；之后关掉它，或把它切到别的 Engine

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 新建文档后，原窗口 Report 的 Background Indexing 下冒出一排「0 images」的批次，同一条目还会出现好几次，看上去像索引被重置、停了。关掉第二个窗口，或把它切到别的 Engine，第一个窗口里还在跑的批次以 Cancelled 结束 |
| **影响范围** | 多个文档共用一个 Engine 时。三处都是老问题，`main` 上同样存在：空批次自有后台索引起就会出现；关闭时取消别人的批次，自 2026-04-28 按根镜像合并批次起（第二个文档拿到的是第一个文档的批次 ID）；切走时取消旧 Engine 上的所有批次，自 2026-05-06 |
| **根因** | 同一个 Engine 上的文档共用一个索引管理器：同一根镜像的请求合并成一个批次，每个文档都能看到所有批次。文档的打开、关闭、切走却都把这些批次当成自己的：打开时把每一条重新派发一遍，对已索引的镜像也照样开批次；关闭时取消手里所有批次 ID，合并来的别人的也在内；切走时取消旧 Engine 上的全部批次 |
| **Status** | **Fixed** —— 后台索引协调器与语料协调器改为每个 Engine 一份，由这个 Engine 上的文档共用：派发按 Engine 只做一次，第二个文档打开什么也不派发；文档离开时 Engine 上还有别的文档就什么都不取消，最后一个离开才停掉并清空；同一 Engine 的窗口显示同一份 Report。另有两处保留：没事可做的根镜像不开批次，reload 不再起重叠的派发 |

---

## 根因

### 空批次：已索引的镜像照样开批次

`RuntimeBackgroundIndexingManager.startBatch` 只在同一根镜像**有批次在跑**时合并，跑完的不算。依赖遍历遇到已索引的镜像就跳过、也不往下走，所以根镜像已索引时条目列表为空——管理器照样登记并广播这个批次，`runBatch` 立刻以「完成、0 个镜像」结束它，结束后还 reload 整个 Engine。Engine 上每个窗口都听得到每个批次，于是这一行出现在所有窗口的 Report 里。

每个文档的协调器有一个「本次会话已派发」的闸门，是 2026-06-05 引入 Always Index 时加的，挡的正是单个文档里「空批次 → reload → 再派发 → 空批次」的循环。它挡不住两件事：

- **新文档的闸门是空的**，所以它把每一条都派发一遍，已索引的全变成空批次。
- **闸门要等每条派发返回后才登记**，而一轮派发是逐条 await 的。派发途中空批次一结束就 reload Engine，reload 泵又对还没登记的条目另起一轮，一条就变成了好几条。

### 关掉第二个窗口：取消了合并来的批次

`documentWillClose()` 取消文档手里的所有批次 ID。第二个文档派发时，管理器把第一个文档正在跑的批次合并给了它、交回那个 ID，关闭时它就把第一个文档的批次一起取消了。

### 切走第二个窗口：取消旧 Engine 上的所有批次

`handleEngineSwap` 自 2026-05-06 起调用旧 Engine 的 `cancelAllBatches()`，为的是清掉「切换途中才落地的批次」：`startBatch` 还在 await 时文档已经切走，ID 被丢弃，批次却在旧 Engine 上一直跑完。当时只从单个文档考虑，没顾及同一 Engine 上的其他文档；而且那个泄漏并没有堵住——在 `cancelAllBatches` 之后才登记的批次照样跑完。

### 被取消的批次为什么镜像还是建完了

经 XPC / TCP 转发的请求收不回来：`RuntimeMessageChannel.sendRequest` 等回应的 continuation 不响应任务取消。所以被取消的批次要等在途的那次加载回来才结束：单镜像的批次其实已经建完，却标成 Cancelled；跟随依赖的批次，剩下的镜像就真的不建了。

## 现场证据

- **用户的描述**：新建文档后原窗口 Report 的批次「变成 0 Images」；两个文档都在 My Mac，新窗口没有任何操作。设置文件里 Always Index 开、启发式关、并发 10，5 条（AppKit、SwiftUI、SwiftUICore、`libswiftCore.dylib`、Foundation）都限定 My Mac、都不跟随依赖。
- **探针**（包测试，按用户的设置，进程内 Engine 与经 XPC 转发的 Engine 各一组）：
  - 第一个文档全部索引完再开第二个：第一个文档的 Report 多出 10 个 0 images 的批次（XPC 转发的一组是 8 个），Foundation、`libswiftCore.dylib` 各 3 个，Engine reload 10 次（XPC：9 次）。
  - 还有批次在跑时开：已完成的条目照样出空批次；在跑的 4 个批次都正常完成，没有被取消。
  - 关掉或切走第二个文档：第一个文档在跑的 AppKit 批次以 Cancelled 结束，镜像本身已建完。
  - 每次运行前后，用户 `RuntimeViewer-Debug/settings.json` 的 SHA 都没变（测试用的是内存里的设置）。

## 为什么测试没抓到

- manager 的 `eventsStreamYieldsBatchStartedThenFinishedForEmptyGraph` 把「空依赖图也发开始、结束事件」钉成了契约，`alwaysIndexReasonRoundTripsThroughEvents` 也借已索引的根镜像廉价地拿一个批次。
- 协调器只有一条多文档测试（`RuntimeBackgroundIndexingReloadTests`：两个文档、一个批次结束只 reload 一次），两个文档在批次开始前就都开好了，没有「后开的文档」，也没有关闭和切走。

## 修复

最终的修法是把协调器从「每个文档一份」改成「每个 Engine 一份」，见提案 [后台工作按 Engine 共享](../Evolutions/0055-engine-scoped-background-work.md)。

- **每个 Engine 一个协调器**：新类型 `RuntimeEngineBackgroundWork` 持有一个 Engine 的后台索引协调器与语料协调器，`RuntimeEngineBackgroundWorkRegistry`（经 `@Dependency`）按 Engine 发放。文档第一次用到时加入当前 Engine 的那一份，切 Engine 时退出旧的、加入新的，关闭时退出；最后一个文档退出时关闭它：取消还在跑的批次与语料构建，Report 随之清空。`DocumentState.backgroundIndexingCoordinator` / `findCorpusCoordinator` 返回当前 Engine 的那一个，Report、Find 与 `reportActivity` 随 `runtimeEngine` 切换重新绑定。
- **第二个文档打开什么也不派发**：`documentDidOpen()` 只在 Engine 的协调器第一次打开时派发 App Launch 与 Always Index；之后的文档找到已经开始的协调器。
- **文档离开不再取消别人的批次**：文档关闭或切走，只是退出这个 Engine 的后台工作；Engine 上还有别的文档，什么都不取消。
- **Engine 背后换了进程**：协调器从 Engine 的就绪状态自己得知（`false → true`），先取消旧进程上的批次，再重新派发；语料协调器同样从头来。以前要等文档「有东西开着」、经 `.switchEngine` 走回镜像列表才会得知，什么都没开时后台索引根本不会重新派发。
- **没事可做就不开批次**：依赖遍历为空时 `startBatch` 返回 `nil`，不登记、不广播、不 reload；协调器把 `nil` 当作已派发登记进闸门。
- **已取消的批次不再被复用**：正在取消、最后一次加载还没回来的批次，不再交还给同一根镜像的新请求，新请求开自己的批次。否则最后一个文档离开、紧接着又有文档来到这个 Engine 时，新派发会拿到一个注定以 Cancelled 结束的批次，条目又已登记，再没人去建它。
- **reload 不再起重叠的派发**：reload 泵在有一轮派发进行中时只记一笔，等这一轮结束再补一轮。
- 用户主动的操作不变：Report 里的 Cancel / Cancel All / Clear History、设置里关掉开关，作用于这个 Engine，同一 Engine 的所有窗口一起变。

**第一版做法（已替换）**：最初保留每个文档一个协调器，给管理器的批次记「请求方」（`RuntimeIndexingRequester`），文档关闭或切走时撤回自己那份，没人再要的批次才取消。用户随即指出 Report 本该是 Engine 的：同一 Engine 的窗口应当显示同一份 Report，只有 Engine 不同才不同。那一版里历史与语料构建仍是每个文档各记一份：新开的窗口历史是空的，Clear History 只清自己，别的窗口发起的语料构建只显示 Building、不能取消，切过 Engine 的窗口还留着上一个 Engine 的记录。改成每个 Engine 一个协调器之后，一个 Engine 只剩一个协调器向管理器要批次，请求方没有用处，一并删除；切 Engine 时把批次归档为已取消的那一套（PR121.57 的修法）也随之删除。

**不采用的做法**：

- 只把 Report 的数据（历史、语料进度）挪到 Engine 一级，派发仍留在文档。语料构建的进度只有发起它的一方收得到，要每个窗口都有进度，就得由 Engine 一级发起；派发留在文档，「每个文档各派一遍」也还在。
- 只在协调器里先查「根镜像是否已索引」再派发。和依赖遍历的判断重复一份，而管理器本来就知道遍历的结果。
- 最后一个文档离开后让 Engine 的活继续跑、Report 一直留到 Engine 终止。没有窗口时也占 CPU，还得在 Engine 终止时另外释放协调器，否则 Engine 连同它的缓存一起泄漏；用户选了「停掉并清空」，只开一个窗口时与以前完全一样。

### 行为变化

- 同一 Engine 的窗口 Report 完全一样：新开的窗口直接看到已有的历史；在任一窗口 Cancel、Cancel All、Clear History，其他窗口一起变；语料行都有进度、都能取消。
- 文档切到另一个 Engine，Report 换成那个 Engine 的，包括它已有的历史，不再带着上一个 Engine 的记录。
- 最后一个文档离开一个 Engine，它的后台活被取消、Report 清空；之后在这个 Engine 上再开窗口，从空的 Report 开始，Always Index 重新派发，已索引的镜像不再开批次。
- Report 里不再出现「0 images」的批次：给已索引的镜像加条目、把 Always Index 关了再开、回到已经索引过的 Engine，都不再新增一行。
- 本 App 之外的客户端在同一来源上发起的语料构建（远程来源的其他连接），仍显示为别处发起、不能取消，提示由「Requested by another window」改为「Requested by another connection」。

## 横向排查

同一类问题，是文档的生命周期动作作用在 Engine 共享的工作上：

- **后台索引**：打开（空批次）、关闭（取消合并来的批次）、切走（取消全部）三处都在这次修复里。设置里关掉总开关、启发式或自定义时调用 `cancelAllBatches` / `cancelBatches(matching:)`：设置是全局的，现在每个 Engine 只响应一次，保留。Report 的 Cancel / Cancel All：用户显式操作，作用于这个 Engine，保留。
- **Find 语料库**：同样的「每个文档一份」——每个文档各自为每个已索引镜像请求一遍语料，各记各的完成记录，别的窗口发起的构建只能看、不能取消——一并改成每个 Engine 一个协调器。存储本身一直是订阅制（`RuntimeInterfaceCorpusStore`），没有改。关掉语料库开关、改 transformer 时 `evictInterfaceCorpus(for: nil)` 清掉 Engine 上的全部语料：全局设置，现在每个 Engine 只做一次。
- **`BackgroundWorkProcessActivity`**：每个文档各持各的 activity，随 `reportActivity` 跟着文档当前的 Engine，不必共享。

这条约定写进了 `AGENTS.md` 的 Key Architectural Patterns（*Engine work is shared by the documents on the engine*）。

## 验证

**第一版（请求方）**：`RuntimeBackgroundIndexingSharedEngineTests` 的第一版 4 个用例在修复前全红——第二个文档打开多出 libobjc 的 0 images 批次、Engine 多 reload；关掉或切走第二个文档，共享的批次以 Cancelled 结束；派发途中的 reload 又起了一轮。Core 的 `startBatchStartsNoBatchWhenTheRootIsIndexed` 修复前红（返回了批次、发了事件、多 reload 一次）。这几条在最终修法里仍然有效，以下是最终修法的验证。

- **新增 `ReportSharedByEngineTests`**（RuntimeViewerApplicationTests，7 个用例，约 50 秒，其中 Foundation 语料取消那条占 40 秒），在 Report 页这一层断言用户看到的东西：同一 Engine 后开的窗口看到的索引历史、语料完成记录与先开的窗口逐行相同；一个窗口 Clear History，另一个窗口的历史也空；一个窗口取消 Foundation 的语料构建，另一个窗口里它也以 Cancelled 结束；窗口切到另一个 Engine，看到的是那个 Engine 的 Report；最后一个窗口离开再回来，Report 是空的；最后一个窗口关闭或切走，Engine 上在跑的批次被取消。**在第一版修法上跑，7 个里 6 个红**，原因各自对得上：第二个窗口还列着已清掉的历史；第一个窗口取消的 Foundation 构建在第二个窗口里照样建完；切过去的窗口显示的是它原来那个 Engine 的批次；最后一个窗口离开再回来历史还在。「离开时取消在跑的批次」那条在第一版上就是绿的，留作行为的钉子。
- **`RuntimeBackgroundIndexingSharedEngineTests` 改写**（6 个用例）：第二个文档打开拿到的是同一个协调器，什么也不派发、Report 不多一行、Engine 不再 reload；一个文档离开而 Engine 上还有别的文档，批次不被取消；文档切走再回来，每个批次只列一次（PR121.57 的症状，换到新结构上钉住）；Engine 背后换了进程、文档什么都没开时，Always Index 照样重新派发；派发途中 reload 不起第二轮。
- **随结构调整的旧测试**：`RuntimeBackgroundIndexingStagingTests` 去掉切 Engine 归档的三条（那套机制已删除），留「结束只进历史一次」；`RuntimeBackgroundIndexingAlwaysIndexEngineTests` 的切 Engine 用例改为切过去后读新 Engine 的协调器；`FindCorpusCoordinatorOlderPeerTests` 的「另一个 Engine 重新开始」改为文档切过去后拿到另一个 Engine 的协调器；`FindCorpusCoordinator*Tests` 直接构造协调器的地方改用 `init(engine:)`；`ReportViewModelTests` 里「别的窗口发起的构建」改称别的连接发起的。
- **Core `RuntimeBackgroundIndexingManagerTests`**：`cancelledBatchIsNotReused` 用 `HeldLoadEngine` 拿一个不理会取消的信号量扣住加载，模拟收不回的在途请求。第一版加的两条请求方测试随请求方一起删除。
- **变异检查**：把新结构的关键处逐一临时改回，跑对应测试。每个文档各拿一套协调器 → 7 条红（同一 Engine 的 Report 一致 5 条、第二个文档拿到同一协调器、离开不取消别人的批次）；最后一个文档离开不关闭 → 3 条红；切 Engine 时文档不搬 → 5 条红；Report 页不跟着 Engine 换 → 2 条红；两个协调器不听 Engine 的就绪状态 → 各自的「Engine 回来后重新开始」红；已取消的批次又交还给新请求 → 「切走再回来」红。还原后 6 个源文件的 SHA 与改动后的版本逐一对上。第一次做「不关闭」这一项时，`return` 下一行的 `backgroundWork.close()` 被 Swift 当成了 return 的返回值，`close()` 照样执行，那一轮结果作废，改用 `if true { return }` 重做。
- **相关测试组**（按原始退出码）：后台索引、Report、文档生命周期、App Nap activity 共 8 组 40 个通过；Find 共 21 组 146 个，旧对端那条按新结构改写后通过。
- **回归**（按原始退出码）：Packages 全量，`RuntimeViewerApplicationTests` 534 个、88 组，其余包 33 / 34 / 50 / 73 / 9 个。第二次全部通过；第一次有 1 条超时：`RuntimeBackgroundIndexingAlwaysIndexEngineTests` 的「把 Engine 从条目上去掉，在跑的批次照样跑完」等 Foundation 批次结束超过 120 秒。同一次运行里其他几条要建 Foundation 的测试也从单独跑的 40–57 秒拖到 108–176 秒；它单独跑 28 秒通过，第二次全量 108 秒通过。满载下它本来就贴着超时线，这次新加的测试多了一次 Foundation 语料构建，负载更重，所以这次没有改它。Core 全量 499 个有 2 个失败，都与本修复无关：`cancelBatchStopsPendingItemsAndEmitsCancelledEvent` 满载时靠「睡 10 ms 再取消」赌时序（2026-09-29 已记录），`RelationshipsEquivalenceSnapshotTests` 的基线不一致在干净的 `next` 上同样重现（09-23、09-29 已记录）。第一版验证时 `RuntimeBackgroundIndexingReloadTests` 偶发多数一次 reload 的情况，这几轮都没再出现，原因仍未证实。
- 每次运行前后，用户 `settings.json` 与两个包的锁文件 SHA 都没变。
- **真实 App 未验证**：要在 App 里 My Mac 上开两个窗口，看两边 Report 完全一样（后开的窗口直接看到已有的历史）；在一个窗口 Clear History、取消一条语料构建，看另一个窗口一起变；把一个窗口切到别的 Engine 再切回来；关掉所有窗口再开一个，Report 应是空的。

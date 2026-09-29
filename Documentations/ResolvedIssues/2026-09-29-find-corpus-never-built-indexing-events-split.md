# 2026-09-29 Find 搜不到任何结果：后台索引的事件被两个读者瓜分，语料库一个都没建

**调查日期：** 2026-09-29
**修复落地：** 本日，分支 `feature/find-navigator`，随提案 [draft-find-navigator](../Evolutions/draft-find-navigator.md) 一批
**Severity：** High —— Find 的文本与成员搜索完全不可用：已索引的镜像全部报「not yet searchable」，结果恒为 0，没有任何报错
**触发场景：** 文档打开后由后台索引（Always Index 条目、启动时的主程序批次）把镜像索引完，再在 Find 里做文本或成员搜索

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 搜 `view` 得到「0 results in 0 types · 5 images not yet searchable」，而后台索引弹窗显示这 5 个镜像都已完成；弹窗里 5 个批次全绿、100%，却一直挂在 ACTIVE 下，不进历史 |
| **影响范围** | Find 的两个提交（b23b308a、6a5fc50e）引入第二个读者之后的 `feature/find-navigator`。「一个事件只给一个读者」自 2189817d（manager 骨架）起就在：`main` 上两个窗口共用 My Mac 引擎时，两个窗口的索引协调器同样互相瓜分事件 |
| **根因** | `RuntimeBackgroundIndexingManager.events` 把同一条 `AsyncStream` 交给每个调用者，而 `AsyncStream` 有多个读者时每个元素只交给其中一个。每个文档都有 `RuntimeBackgroundIndexingCoordinator` 在读，`FindCorpusCoordinator` 成了第二个读者 |
| **Status** | **Fixed** —— `events` 改为每个订阅者一条独立的流、事件广播给全部订阅者，新订阅者先收到进行中批次的快照；`FindCorpusCoordinator` 先订阅、再补建已索引镜像 |

---

## 根因

### 一条流、两个读者

Swift 标准库的 `AsyncStream`（`stdlib/public/Concurrency/AsyncStreamBuffer.swift`）允许多个任务同时读，但不广播：
`next` 把等待者追加进 `continuations`，`yield` 时 `continuations.removeFirst()`，谁排在前面给谁。读者一多，事件就被
轮流瓜分。（`AsyncThrowingStream` 更直接，第二个读者会 `fatalError("attempt to await next() on more than one task")`。）

每个文档打开时，`Document.makeWindowControllers` 先建 `RuntimeBackgroundIndexingCoordinator`，再建 `FindCorpusCoordinator`，
两者各起一个任务 `for await` 同一个 `engine.backgroundIndexingManager.events`：前者驱动索引弹窗，后者按提案 §4 的触发源 1
在 `.taskFinished(result: .completed)` 时请求建语料库。

### 为什么恰好一个 `taskFinished` 都没拿到

用户的 5 条 Always Index 都是 `followDependencies: false`，也就是 5 个各含 1 个镜像的批次。事件顺序是：批次依次开始时的
`batchStarted`、`taskStarted`，然后各镜像索引完时的 `taskFinished`、`batchFinished`。两个读者都在等时事件交替分发，结果：

- **索引协调器**拿到每一个 `batchStarted` 和 `taskFinished`：条目全部打勾、进度 100%，但批次只在收到 `batchFinished`
  时才移出 ACTIVE，于是永远挂着；批次结束时本该发出的 `reloadData` 也没发。
- **Find 协调器**拿到每一个 `taskStarted` 和 `batchFinished`：它只对 `taskFinished` 做事，于是一次建库都没请求。

它的另外两个触发源也补不上：创建时的补建（`requestBuildOfIndexedImages`）发生在 `makeWindowControllers`，那时什么都还没
索引，My Mac 引擎甚至可能还没连上 XPC 服务；`imageDidLoadPublisher` 只在前台加载时发出，后台索引按设计不发。

## 现场证据

- **XPC 服务进程的统一日志**（My Mac 引擎跑在 `RuntimeViewerLocalRuntimeService` 里）：5 个镜像的 ObjC / Swift section 都建了，
  没有一条 `RuntimeInterfaceCorpusStore` 的「Building corpus for …」。info 级日志只在内存里留一段时间，查的时候同一时段的
  section 日志还在。
- **搜索摘要**里的「5 images not yet searchable」来自服务端的 `indexedImagePaths.subtracting(corpora.keys)`：5 个已索引，
  0 个语料库。
- **弹窗截图**：全绿、100%、仍在 ACTIVE，正是缺 `batchFinished` 的样子；按上面的事件顺序推演，两个读者各分到什么与截图一致。
- **设置文件**里没有 `search` 分支，`isCorpusEnabled` 取默认值「开」，排除开关被关的可能。

## 为什么测试没抓到

提案 §5 要求测语料库协调器的四个触发源，落地的 `FindCorpusCoordinatorTests` 只有三条：显式 `requestBuild`、开关切换、
创建时补建，都不经过后台索引的事件；测试里也只有 Find 协调器一个读者。manager 自己的测试同样都只有一个读者。

## 修复

- **`RuntimeBackgroundIndexingManager.events` 改为订阅**：从 `nonisolated` 的共享流改成 actor 上的属性，每次访问新建一条流、
  登记它的 continuation；所有事件经 `emit` 广播给全部订阅者。读的任务被取消时注销订阅，manager 释放时结束所有流。
- **新订阅者先收到进行中的批次**：登记前，按批次开始的顺序给新流补发每个进行中批次的 `.batchStarted`，带着条目当时的状态。
  旧的共享流会缓冲订阅之前的事件，改成各自一条流之后，晚于批次开始的订阅者就会漏掉这个批次；两个协调器都在任务里异步订阅，
  与 `documentDidOpen` 起批次之间没有先后保证，所以补上这一步。
- **`FindCorpusCoordinator` 先订阅、再补建**：订阅到手后才调用 `requestBuildOfIndexedImages()`，去掉原先与订阅并行发出的那次。
  订阅之后索引完的镜像以事件到达，之前索引完的在已索引列表里，中间没有空隙。
- 调用方不用改：两个协调器本来就写的是 `await engine.backgroundIndexingManager.events`。

**不采用的做法**：只让索引协调器读事件、再转给 Find 协调器。改动更小，但修不了多窗口共用一个引擎时同样的瓜分，还会把两个
按设计互相独立的协调器绑在一起。

### 行为变化

多个文档共用一个引擎（My Mac）时，每个文档的索引弹窗都会看到这个引擎上的全部批次，每个批次结束时各文档各发一次
`reloadData`。以前是各自只看到一部分，状态错乱。

## 横向排查

全仓公开暴露、可能被多处读的 `AsyncStream` 只有这一条。其余都是「一条流一个读者」：`RuntimeEngine` 的连接状态流、
`RuntimeInterfaceExportReporter.events`、`SocketConnection.incomingPayloads`、`RuntimeEngineManager` 的探测流；
`RuntimeMessageChannel` 的接收流已经用 `SharedAsyncSequence` 广播。

## 验证

- `RuntimeBackgroundIndexingManagerTests.everySubscriberReceivesEveryEvent`：两个订阅者、一个单镜像批次。修复前确定性变红
  （4 个事件被分成 `[batchStarted, batchFinished]` 与 `[taskStarted, taskFinished]`，两边都等不齐），修复后通过。
- `RuntimeBackgroundIndexingManagerTests.subscriberArrivingMidBatchFirstReceivesThatBatch`：批次被前台加载挡住时才订阅，
  先收到该批次的快照，再看到它跑完。它守护的是新实现的晚订阅语义，修复前也通过（旧的共享流会缓冲）。
- `FindCorpusCoordinatorTests.backgroundIndexedImageBecomesSearchable`：按 `Document.makeWindowControllers` 的顺序建两个协调器，
  起一个与 Always Index 条目同形的单镜像批次。修复前 4/4 次变红，每次都是同样 4 处——语料库没建、搜索 0 结果、镜像报未建、
  批次没进历史，正是现场的全部症状；修复后 5/5 次通过，每次约 0.65 s。
- 回归（按原始退出码判定）：Packages 全量通过，其中 `RuntimeViewerApplicationTests` 255 条 / 45 个测试组；manager 测试组
  单独跑 10/10 次全过。Core 全量 348 条有 3 条失败，都与本修复无关：
  - `RuntimeMemberDeclarationLocatorTests` 的 ObjC 用例：夹具把冒号写进了选择子片段（`FunctionDeclaration("setValue:")`），
    而定位器按实测（片段不带冒号，冒号是片段之间的普通文本）拼键，自 b23b308a 起就对不上；
  - `RelationshipsEquivalenceSnapshotTests` 的 Swift 基线：提案决策日志已记录，在干净的 `next` 上同样重现；
  - `cancelBatchStopsPendingItemsAndEmitsCancelledEvent`：只在全量高负载下失败一次（同一时刻相邻测试从约 30 ms 拖到 1.1 s）。
    它靠「睡 10 ms 后取消」赌 6 次各 5 ms 的加载还没跑完，负载高时批次可能先跑完；本修复不涉及取消与结束事件。
- **真实 App 未验证**：需要重新构建运行后在 Find 里再搜一次。5 个框架的语料库是在后台以 utility 优先级逐个构建的，要等几分钟，
  期间「not yet searchable」的数量会逐步减少；搜索结果不会自动刷新，要再按一次回车。

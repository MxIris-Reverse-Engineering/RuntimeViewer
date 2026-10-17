# 2026-10-01 引擎在后台索引批次进行中被释放，下一个加载读到已释放的引擎

**调查日期：** 2026-10-01
**修复落地：** 本日，见 `RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/RuntimeBackgroundIndexingManager.swift`
**引入提交：** `c96f229b`（2026-04-28，fix(core): break engine retain cycle），为了打破引擎与 manager 的强引用环把 `engine` 改成了 `unowned`
**Severity：** Major —— 一旦触发就是整个进程 abort；触发条件在 App 现有路径里有保护，所以至今没有用户报告
**触发场景：** `feature/find-navigator` 上 Find 语料 store 用同样的写法，在测试里真实崩过；横向排查时在这里找到同一模式

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `Fatal error: Attempted to read an unowned reference but object … was already destroyed`，崩在批次的下一个镜像加载 |
| **影响范围** | 引擎在它的索引批次还在跑的时候被释放：只被一个文档持有的引擎随文档关闭、任何没先取消批次就丢掉引擎的路径 |
| **根因** | manager 由引擎持有、`unowned` 指回引擎；但批次的驱动任务持有 manager，manager 因此可以比引擎活得久，`runSingleIndex` 再读 `engine` 就 abort |
| **Status** | **Fixed** —— 改为 `weak`，引擎不在时剩下的批次按取消结束，配回归测试 |

---

## 根因

`RuntimeBackgroundIndexingManager` 是引擎的成员（`RuntimeEngine.backgroundIndexingManager`），反过来通过
`engine` 调 `loadImageForBackgroundIndexing` 等方法。2026-04-28 为了打破两者的强引用环，`engine` 改成了 `unowned`，
注释写的理由是「引擎拥有 manager，所以引擎总比 manager 活得久」。

这个前提不成立：`startBatch` 起的驱动任务是 `Task { [weak self] in guard let self … await self.runBatch(id:) }`，
批次跑着的时候任务持有 manager。引擎此时被释放，manager 还活着，批次循环发出下一个
`runSingleIndex`，`try await engine.loadImageForBackgroundIndexing(at:)` 读 `unowned` 引用即 abort。

App 现有的换引擎路径不会触发：`RuntimeBackgroundIndexingCoordinator.handleEngineSwap` 用一个持有旧引擎的 Task 先对旧
manager 调 `cancelAllBatches()`，取消落到 manager 这个 actor 上之后旧引擎才可能释放，而 `runSingleIndex` 在读引擎前
先 `Task.checkCancellation()`，两者在 actor 上串行，读引擎的那一段要么在取消之前（调用期间引擎被强引用着）、要么在之后（直接抛
`CancellationError`）。但凡哪条路径不先取消就丢掉引擎，就会崩——协调器的 `deinit` 只停事件泵、不取消批次。

## 修复

`engine` 改为 `weak var`（不能是强引用，强引用环的理由仍然成立）：

- `expandDependencyGraph` 一开始取一个强引用，整次遍历都持有，引擎已不在则返回空列表；
- `runSingleIndex` 在 `checkCancellation()` 之后取强引用，取不到就抛 `CancellationError`，这个镜像记为 cancelled；
- `runBatch` 每派发一个镜像前，除了 `Task.isCancelled` 也检查引擎还在不在，不在就整批按取消收尾——`finalize` 把剩下的镜像
  标成 cancelled 并发出 `.batchCancelled`。

正在加载的那个镜像在调用期间强引用着引擎，会正常完成。

## 验证

`RuntimeBackgroundIndexingManagerTests.batchWhoseEngineGoesAwayEndsCancelled`：mock 引擎上起一个 21 个镜像、并发 1 的批次，
`startBatch` 返回后立刻释放 mock。修复前测试进程以上面的 fatal error abort；修复后批次以 `.batchCancelled` 结束。
Core 全量 436 个测试中 435 个通过（Xcode 26.6，`main` 的锁定版本）；唯一的失败是 `ConnectionTransportRegressionTests` 的
DirectTCP 用例，单独连跑三次全过，属于全量并行时 IPC 测试的已知负载超时，与本修复无关。

同一写法的另一处——`feature/find-navigator` 上的 `RuntimeInterfaceCorpusStore.builder`——在那条分支上同日修复。
`main` 上其余的 `unowned`（`RuntimeEngine` 的消息处理闭包、Application 层几个指回 `DocumentState` 的引用）都是子对象指向
拥有者、且没有会比拥有者活得久的任务去读它们，不属于这一类。

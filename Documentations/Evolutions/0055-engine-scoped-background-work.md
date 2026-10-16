# 0055 - 后台工作按 Engine 共享：同一 Engine 的文档看同一份 Report

- **状态**: Implemented
- **创建日期**: 2026-10-16
- **最后更新**: 2026-10-16
- **配套文档**: 无（理由见决策日志 2026-10-16 的 Implemented 一行）；排查与修复记录见 [`ResolvedIssues/2026-10-16-second-document-disturbs-shared-indexing.md`](../ResolvedIssues/2026-10-16-second-document-disturbs-shared-indexing.md)

## 摘要

同一 Engine 上的文档本来就共用一个 Engine，但 Report 里只有「正在跑的批次」取自 Engine，其余都是每个文档各记一份：索引历史从文档打开时才开始记（新开的文档是空的，切过 Engine 的还留着上一个 Engine 的记录），Clear History 只清自己；可搜索接口只有本文档发起的构建有进度、能取消，别的窗口发起的只显示 “Building”。改为后台索引协调器和语料协调器每个 Engine 一个、由这个 Engine 上的文档共用，于是同一 Engine 的文档 Report 完全一样，只有 Engine 不同才不同。

## 方案

**用户看到的**

- 同一 Engine 的所有窗口，Report 的两个分类（后台索引、可搜索接口）完全相同：在跑的、历史、进度、完成记录。任一窗口点 Cancel、Cancel All、Clear History，作用于这个 Engine，其他窗口一起变；语料行都有进度、都能取消。
- 文档切到另一个 Engine，Report 换成那个 Engine 的，包括它已有的历史；原 Engine 上还有别的文档的话，那边什么都不变。
- 最后一个文档离开某个 Engine（关窗或切走）：这个 Engine 在跑的索引批次和语料构建取消，Report 清空，之后再开窗口从空的开始。只开一个窗口时行为与现在相同。
- App Launch、Always Index、语料请求，以及语料开关和 transformer 改动后的重建，都按 Engine 只做一次，不再每个文档各做一遍。

**结构**

- 新增一张按 Engine 登记的表（`@MainActor`，经 `@Dependency` 取得）发放两个协调器：文档第一次用到时登记到当前 Engine，切 Engine 时从旧的退出、在新的登记，关窗时退出；最后一个文档退出，协调器关闭并移除。`DocumentState.backgroundIndexingCoordinator` / `findCorpusCoordinator` 返回当前 Engine 的那一个；Report、Find、`reportActivity` 随 `runtimeEngine` 切换重新绑定。
- 留在文档的：侧栏正在看的镜像建好索引时优先建语料（协调器记着每个文档在看哪个镜像）；Find 会话照旧调用协调器、听它的 `corpusBuilt` / `corporaRebuilt`。
- Engine 背后的进程换了（XPC service 重启），协调器自己从 Engine 的就绪状态得知，重新派发、语料状态重来；文档重新选中同一个 Engine 不再惊动它。
- 上一轮修复随之收缩：一个 Engine 只有一个协调器要批次，删掉「请求方」（`RuntimeIndexingRequester`、`withdraw(_:)`）和协调器里切 Engine 时归档已取消批次的那一套；保留根镜像已索引不开批次、不加入已取消的批次、派发途中的 reload 等这一轮结束再补。

**没问就采用的假设**

- 只有本 App 以外的客户端在同一来源上发起的语料构建（远程来源的其他连接）仍显示为别处发起、不能取消，提示改为 “Requested by another connection”。
- 历史上限仍是 100 条，按 Engine 计。每个 swift-testing 测试有自己的一张登记表（依赖的 test value 按测试缓存），共用 `TestRuntimeEngine.shared()` 的测试互不相见。
- 先写并确认变红的回归测试：同一 Engine 两个文档的 Report 相同；一边 Clear / Cancel 另一边同步；切 Engine 看到那个 Engine 的历史；最后一个文档离开时取消并清空。
- 同批更新：已解决问题纪要 `2026-10-16-second-document-disturbs-shared-indexing.md` 的修复一节、`AGENTS.md` 的 *Engine work is shared by the documents on the engine*、术语表的「请求方」，以及提案 0002、0029、0030 的决策日志。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-16 | Created as Draft | 用户：「Report那里不管开多少个文档都是一样的，因为Engine都是共享一份」「开不同的Engine才不同，一样的Engine显示一样」 |
| 2026-10-16 | 最后一个文档离开 Engine 时停掉并清空 | 用户选定。只开一个窗口时行为不变；不留没有窗口的后台活，也不必在 Engine 终止时另外释放它 |
| 2026-10-16 | 协调器整个改为每个 Engine 一个，而不是只把 Report 的数据挪到 Engine 一级 | 语料进度只有发起构建的一方收得到，要每个窗口都有进度，就得由 Engine 一级发起；派发按 Engine 一次，也从根上去掉了上一轮那种重复派发 |
| 2026-10-16 | 删掉上一轮新加的请求方 | 一个 Engine 只剩一个协调器向管理器要批次，撤回自己的那份就等于全部取消 |
| 2026-10-16 | 状态改为 Accepted，随即 In Progress | 用户批准：「开工」 |
| 2026-10-16 | 实现：`RuntimeEngineBackgroundWork`（一个 Engine 的两个协调器，按需创建）与 `RuntimeEngineBackgroundWorkRegistry`（`@DependencyEntry`，test value 每个测试一份），都只在模块内可见；协调器的 `init(engine:)` 取代 `init(documentState:)`，`documentWillClose()` 改为由最后一个文档离开时调用的 `close()`；`documentDidOpen()` 每个 Engine 只在第一次生效；文档切到别的 Engine 时，若用过后台索引就启动那个 Engine 的协调器（与原先切 Engine 后重新派发一致），用过语料就让 Find 会话改跟那个 Engine 的语料协调器 | `.switchEngine` 先搬文档、再赋值 `runtimeEngine`，所以跟着 `$runtimeEngine` 的 Report、`reportActivity` 读到的已是新 Engine 的协调器 |
| 2026-10-16 | 两个协调器各自监听 Engine 就绪状态的 `false → true`：索引协调器在同一个任务里先取消旧进程上的批次、再重新派发；语料协调器从头请求 | 原先只能经文档的 `.switchEngine` 得知，而文档什么都没开时不会走这一步，后台索引因此不会重新派发（语料协调器另听 `runtimeEngineDidReset`，没有这个缺口）。先取消再派发放在一个任务里，是为了不让新派发拿到旧进程上还没结束的同一根镜像的批次 |
| 2026-10-16 | 删除切 Engine 时把批次归档为已取消的机制与它的三条暂存测试（PR121.57）；同一症状在新结构上由「切走再回来每个批次只列一次」钉住 | 协调器不再跨 Engine，离开再回来拿到的是新协调器，重放的批次只出现在它自己的列表里 |
| 2026-10-16 | 验证：`ReportSharedByEngineTests` 7 个用例在第一版修法上 6 红，最终修法上全绿；`RuntimeBackgroundIndexingSharedEngineTests` 改写为 6 个用例；变异检查 7 项（每个文档一套协调器、最后一个离开不关闭、切 Engine 不搬、Report 不跟 Engine、索引与语料协调器各自不听就绪状态、已取消批次被复用）各自让对应测试变红 | 详见已解决问题纪要的验证一节 |
| 2026-10-16 | Implemented，编号 0055：随本次提交合入 `next` | 用户以 `/push-updates` 提交。编号取 `origin/next` 上已有的最大号 0054 加一。配套文档：不另写——调用方要守的只有一条（经 `DocumentState` 取协调器、跟着 `$runtimeEngine` 重新绑定，不给文档留自己的索引或语料状态），写在 `AGENTS.md` 的 *Engine work is shared by the documents on the engine*；实现里不显而易见的决定（先取消再派发、每个测试一张登记表）在本提案的决策日志与已解决问题纪要里。新术语「Engine 的后台工作」已登记进 `Glossary.md`，取代第一版的「请求方」 |

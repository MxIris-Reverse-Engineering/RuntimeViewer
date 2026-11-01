# Draft - 降低引擎进程的常驻内存

- **状态**: In Progress
- **创建日期**: 2026-11-01
- **最后更新**: 2026-11-01
- **所属愿景**: 无
- **实现分支 / PR**: `feature/engine-resident-memory`（从 `next` 切出）

## 摘要

本地运行时与 Mac Catalyst 运行时各自搬进 XPC service（[0037](0037-local-runtime-xpc-service.md)、[0051](0051-catalyst-xpc-service.md)）之后，RuntimeViewer 由三个进程组成，2026-11-01 实测合计约 1.7 GB；2026-08 还是单进程时，稳态 239 MB、浏览后约 350 MB。原有索引基本没涨，涨的是两项新功能留在引擎进程里的数据：Find 语料（[0029](0029-find-navigator.md)，每个引擎 180–240 MB）与交叉引用表（[0056](0056-cross-references.md)，120–180 MB），而且一个引擎上的窗口全关了也不还。本提案做三件事：语料里重复存放的可见性条件只存一份；一个引擎上最后一个窗口离开时，释放它的语料与交叉引用表；两项的内存预算按实际占用计算。

## 方案

**实测依据**：Ultra 上的 Debug 版，运行约 2.5 小时；Always Index 在 My Mac 上是 6 个镜像，在 Mac Catalyst 上是 8 个（多 UIKitCore 与 UIKitMacHelper）。用 `leaks --outputGraph` 抓内存图，再用 `leaks --dominatorTree` 把内存归到独占的持有者。

| 进程 | 占用 | Find 语料 | 交叉引用表 | 原有索引 |
|---|---|---|---|---|
| My Mac (Mac Catalyst) 引擎 | 924 MB | 240 MB | 180 MB | 420 MB |
| My Mac 引擎 | 589 MB | 180 MB | 120 MB | 200 MB |
| App | 163 MB | — | — | — |

1. **可见性条件只存一份。** 每个语料条目的 `VisibilityRegionTable.conditions` 各存一份 `[VisibilityCondition]`，每个条件又是 `[[Requirement]]`，每个 `Requirement` 带一个选项名 `String`。可这些条件只由二十来个生成选项组成，不同的条件远少于条目数。Catalyst 引擎里这些副本约 30 MB（44 万次分配），My Mac 引擎约 20 MB。改为每个镜像的语料建一个条件池，相等的条件与条件列表换成池里那一份，共享存储。条目只在两处构造——`RuntimeInterfaceCorpusAssembly`（打印）与 `RuntimeInterfaceCorpusSnapshot`（从派生数据读回），两处都经过这个池。派生数据的文件格式不变。
2. **最后一个窗口离开时释放。** 最后一个文档离开引擎时，`RuntimeEngineBackgroundWork.close()` 现在只撤销构建与预建请求，数据留在引擎进程里。改为同时：
   - 驱逐这个引擎的全部语料（`evictInterfaceCorpus(for: nil)`）；
   - 把交叉引用的驻留上限置 0（`setPreparedCrossReferenceByteLimit(0)`），和关掉 Keep Cross References Ready 走同一条路，预建表与函数表随之放掉；
   - 驱逐完在引擎进程里调一次 `malloc_zone_pressure_relief`，让空出的页还给系统（实测确认是否需要）。

   下一个文档加入时，现有的启动流程会恢复上限，并请求已索引镜像的语料与预建：共享缓存里的镜像从派生数据读回语料，交叉引用在后台重建。释放还没做完就有文档加入时，迟到的驱逐可能清掉新工作刚请求的语料、迟到的上限 0 会盖掉刚恢复的上限。所以 `RuntimeEngineBackgroundWorkRegistry` 记下进行中的释放；同一引擎的新工作照常启动，等这次释放结束，两个协调器再走一遍「引擎重来」的现有路径（`engineDidReset()`：撤回请求、清空状态、重新请求全部已索引镜像并重新下发上限）。被驱逐取消的构建在 App 一侧只是悄悄复位，不会在 Report 里留下「已取消」。
3. **预算按实际算。** 语料条目的 `byteCount` 不算条件，字符串与数组的分配开销也只算了一部分，它的注释里就写着驱逐 Foundation 的语料实际释放的比估算多约五分之一。改为把条件池按镜像算一次，每次分配都算上 32 字节的头部和 malloc 的取整（按元素数与 `malloc_good_size` 算，不按容量，所以打印出的与从派生数据读回的同一份语料估算相同），再加上条目数组本身，并用测试钉住：给 Foundation 建语料，估算与驱逐前后 `malloc_zone_statistics` 量出的在用字节数之差相差不超过 10%（测量单独占一个 exit test 进程）。交叉引用的 `CrossReferencePreparedImage.byteCount` 用同样的测试核对：少了一成多，而它由 MachOSwiftSection 的 CrossReferenceAnalysis 算出，修它要改上游，见决策日志。

**没有询问就采用的假设**
- 只释放语料与交叉引用表。原有索引和引擎进程本身都留着，所以 Catalyst 引擎那 420 MB 索引不动，再开窗口也不必重新索引。
- 最后一个窗口一离开就释放，不设延时。
- 两项预算的默认值不变，各 256 MB。
- 只改 RuntimeViewer 自己的代码，不改 swift-semantic-string。
- CLI 与 MCP 不受影响：它们不读语料，也不发交叉引用查询。

**不做**
- 释放原有索引，或让没有窗口的引擎进程退出：省得最多，但再开窗口要重新加载并索引镜像，UIKitCore 这类要等很久，而且 CLI 与 MCP 可能正用着这个引擎。要做就另立提案。
- 压缩语料的 span 表（Catalyst 引擎里 79 MB，比 64 MB 的正文还大）：每个 span 已经只有 8 字节，表大是因为 token 多，要省就得改上游的存储形式。
- App 进程的峰值到过 579 MB，来自某次临时分配，来由没查，另行排查。

**落地步骤**（每步单独能编译、相关测试通过，各提交一次）
1. [x] 条件池：新增 `RuntimeInterfaceVisibilityConditionPool`，`RuntimeInterfaceCorpusAssembly` 与 `RuntimeInterfaceCorpusSnapshot` 构造条目时经过它，镜像语料的字节数加上池的字节数。测试：打印出的与从派生数据读回的语料里，相等的条件共享存储。
2. [x] 估算按实际算：语料条目的 `byteCount` 按实际分配计算；exit test 给 Foundation 建语料，量驱逐前后 malloc 在用字节数之差，与估算相差不超过 10%。交叉引用的 `CrossReferencePreparedImage.byteCount` 用同样的办法核对，超出的部分在上游，测试里记为已知问题。
3. [ ] 关窗释放：`RuntimeEngineBackgroundWork.close()` 让引擎进程驱逐语料、把交叉引用上限置 0，registry 记下进行中的释放并在它结束后让同一引擎的新工作重新请求；先用探针确认要不要 `malloc_zone_pressure_relief`。测试：最后一个文档离开时引擎收到这两条命令；释放被扣住时新文档加入，放行后上限按设置重新下发、语料重新请求。
4. [ ] 文档与实测：同批更新下文列出的文档；按上面的配置重测内存。

**验收**
- 三项各有测试，改代码之前先确认它是红的：条件池里相等的条件共享存储；最后一个文档离开时引擎收到驱逐与上限置 0，下一个文档加入后恢复，快速离开再加入时语料不会被迟到的驱逐清掉；两项估算的误差不超过 10%。
- 按上面的配置重测：Catalyst 引擎进程的堆少约 30 MB、My Mac 引擎进程少约 20 MB；关掉一个引擎上的全部窗口后，Catalyst 引擎进程降约 400 MB、My Mac 引擎进程降约 300 MB；重开窗口后 Find 与交叉引用照常可用。
- 同批更新文档：`AGENTS.md` 里讲 Engine 后台工作的那段，以及 `Glossary.md` 的「Engine 的后台工作」条目，都要写上最后一个文档离开时会释放引擎进程里的语料与交叉引用表。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-01 | Created as Draft | 运行中的 Debug 版三个进程合计约 1.7 GB；排查确认不是泄漏，增量来自 Find 语料与交叉引用表常驻在引擎进程里。用户选择写提案降低常驻内存。 |
| 2026-11-01 | 用户批准，开始实现；补上四个落地步骤 | 精简提案原本没有分步，按能各自编译验证的粒度拆开。 |
| 2026-11-01 | 释放与再加入的先后改为「新工作照常启动，释放结束后再走一遍引擎重来的路径」，不让新工作等释放完再启动 | 文档会直接调用协调器（Find 的搜索、Always Index 的提前读取），要让新工作等着，就得拦住每一个请求入口；`engineDidReset()` 本来就会撤回请求并重新请求全部已索引镜像，重复请求无害，被驱逐取消的构建也不会在 Report 里留下记录。只有释放还没做完时加入的工作才多走这一遍。 |
| 2026-11-01 | 估算按元素数与 `malloc_good_size` 算，不按数组容量 | 按容量算的话，打印出的语料（追加时容量会多出来）与从派生数据读回的同一份语料（容量正好）估算不同，派生数据的几组测试要求两者的摘要相同。实测给 Foundation 建语料：原来的估算加上条件池是 19.8 MB，驱逐释放 22.1 MB，少 10.3%；改后估算 23.0 MB，多 4.5%。 |
| 2026-11-01 | 交叉引用的估算偏低一成多，留给上游，不在本提案里修；测试用 `withKnownIssue` 记下差距 | Foundation 的预建表估算 17.6 MB，置 0 后释放 19.9 MB，少 11.7%。这个数由 MachOSwiftSection 的 `CodeReferenceIndex.approximateByteCount` 与分析器的 `approximateByteCount(ofImageDataAt:)` 算出，它们按元素数算、不含分配头部与取整；RuntimeViewer 只是相加，要修就得改另一个仓库，超出了「只改 RuntimeViewer 自己的代码」。测试保留，上游修好后已知问题不再出现，测试会提醒去掉包装。 |

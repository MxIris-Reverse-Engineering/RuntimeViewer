# 0065 - 降低引擎进程的常驻内存

- **状态**: Implemented
- **创建日期**: 2026-11-01
- **最后更新**: 2026-11-02
- **所属愿景**: 无
- **实现分支 / PR**: `feature/engine-resident-memory`（从 `next` 切出）

## 摘要

本地运行时与 Mac Catalyst 运行时各自搬进 XPC service（[0037](0037-local-runtime-xpc-service.md)、[0051](0051-catalyst-xpc-service.md)）之后，RuntimeViewer 由三个进程组成，2026-11-01 实测合计约 1.7 GB；2026-08 还是单进程时，稳态 239 MB、浏览后约 350 MB。原有索引基本没涨，涨的是两项新功能留在引擎进程里的数据：Find 语料（[0029](0029-find-navigator.md)，每个引擎 180–240 MB）与交叉引用表（[0056](0056-cross-references.md)，120–180 MB），用户没有办法让它们放手。本提案做三件事：语料里重复存放的可见性条件只存一份；Report 导航栏的 Searchable Interfaces 与 Cross References 两行显示引擎进程此刻为它们留着多少内存，并像访达推出卷那样带一个推出按钮，由用户决定清不清；两项的内存预算按实际占用计算。

## 方案

**实测依据**：Ultra 上的 Debug 版，运行约 2.5 小时；Always Index 在 My Mac 上是 6 个镜像，在 Mac Catalyst 上是 8 个（多 UIKitCore 与 UIKitMacHelper）。用 `leaks --outputGraph` 抓内存图，再用 `leaks --dominatorTree` 把内存归到独占的持有者。

| 进程 | 占用 | Find 语料 | 交叉引用表 | 原有索引 |
|---|---|---|---|---|
| My Mac (Mac Catalyst) 引擎 | 924 MB | 240 MB | 180 MB | 420 MB |
| My Mac 引擎 | 589 MB | 180 MB | 120 MB | 200 MB |
| App | 163 MB | — | — | — |

1. **可见性条件只存一份。** 每个语料条目的 `VisibilityRegionTable.conditions` 各存一份 `[VisibilityCondition]`，每个条件又是 `[[Requirement]]`，每个 `Requirement` 带一个选项名 `String`。可这些条件只由二十来个生成选项组成，不同的条件远少于条目数。Catalyst 引擎里这些副本约 30 MB（44 万次分配），My Mac 引擎约 20 MB。改为每个镜像的语料建一个条件池（`RuntimeInterfaceVisibilityConditionPool`），相等的条件与条件列表换成池里那一份，共享存储。打印（`RuntimeInterfaceCorpusAssembly`）与从派生数据读回（`RuntimeInterfaceCorpusSnapshot`）两条路最后都经 `ImageCorpus.init(sharingVisibilityConditionsOf:…)` 建成镜像语料。派生数据的文件格式不变。
2. **由用户推出，不自动释放。** Report 导航栏的 Searchable Interfaces 与 Cross References 两个类别行，标题后面显示引擎进程此刻为这一类留着的内存，行尾有推出按钮（`eject.fill`，位置与运行中的转圈相同）。点了之后：
   - Searchable Interfaces：`FindCorpusCoordinator.ejectCorpora()` 撤回构建与读取，让引擎进程驱逐全部语料（`evictInterfaceCorpus(for: nil)`），并忘掉自己请求过哪些镜像。之后不会自动重建：搜索时用到哪些就从派生数据读回或重新打印，搜全部镜像就全部请求。
   - Cross References：`CrossReferencePreparationCoordinator.ejectPreparations()` 撤回预建请求，让引擎进程把上限先置 0（预建表和为它们读的名字随之放掉）再恢复为设置里的值，所以之后查询顺带预建的镜像照常保留。之后不会自动重新预建：查询用到时再建。

   大小来自引擎进程自己的统计：语料取语料覆盖查询里的 `residentByteCount`；交叉引用新增一条命令 `crossReferencePreparedByteCount`（`RuntimeEngine.preparedCrossReferenceByteCount()`），返回会话里预建镜像的估算总和。前者在每次构建完、推出后与 Report 出现时刷新，后者在协调器启动、每次预建完、推出后、上限变化后与 Report 出现时刷新。某一类关着时不显示大小，那时引擎进程本来也不为它留东西；大小没变就不重建 Report 的树。比这条命令老的对端不显示交叉引用的大小。只有占用大于 0 才显示按钮；占用大于 0 时，即使这一类没有别的行，类别行也留着。

   不调 `malloc_zone_pressure_relief`：探针实测它一个字节也还不回来（见决策日志）。推出之后 malloc 在用的内存立刻降下来，footprint 只当场降一部分。
3. **预算按实际算。** 语料条目的 `byteCount` 不算条件，字符串与数组的分配开销也只算了一部分，它的注释里就写着驱逐 Foundation 的语料实际释放的比估算多约五分之一。改为把条件池按镜像算一次，每次分配都算上 32 字节的头部和 malloc 的取整（按元素数与 `malloc_good_size` 算，不按容量，所以打印出的与从派生数据读回的同一份语料估算相同），再加上条目数组本身，并用测试钉住：给 Foundation 建语料，估算与驱逐前后 `malloc_zone_statistics` 量出的在用字节数之差相差不超过 10%（测量单独占一个 exit test 进程）。交叉引用的 `CrossReferencePreparedImage.byteCount` 用同样的测试核对：少了一成多，而它由 MachOSwiftSection 的 CrossReferenceAnalysis 算出，修它要改上游，见决策日志。

**没有询问就采用的假设**
- 推出只清语料与交叉引用表。原有索引和引擎进程本身都留着（用户确认），侧栏与内容区不受影响，Catalyst 引擎那 420 MB 索引不动。
- 推出之后不自动重建，用到时再建；历史行（Report 里各镜像的完成记录）照旧保留。
- 两项预算的默认值不变，各 256 MB。
- 只改 RuntimeViewer 自己的代码，不改 swift-semantic-string 与 MachOSwiftSection。
- CLI 与 MCP 不受影响：它们不读语料，也不发交叉引用查询。

**不做**
- 释放原有索引，或让没有窗口的引擎进程退出：省得最多，但再开窗口要重新加载并索引镜像，UIKitCore 这类要等很久，而且 CLI 与 MCP 可能正用着这个引擎。要做就另立提案。
- 按镜像逐个推出：用户选了按类别推出。
- 压缩语料的 span 表（Catalyst 引擎里 79 MB，比 64 MB 的正文还大）：每个 span 已经只有 8 字节，表大是因为 token 多，要省就得改上游的存储形式。
- App 进程的峰值到过 579 MB（另一次运行到过 693 MB），来自某次临时分配，来由没查，另行排查。

**落地步骤**（每步单独能编译、相关测试通过，各提交一次）
1. [x] 条件池：新增 `RuntimeInterfaceVisibilityConditionPool`，打印与从派生数据读回的语料都经过它，镜像语料的字节数加上池的字节数。测试：打印出的与从派生数据读回的语料里，相等的条件共享存储。
2. [x] 估算按实际算：语料条目的 `byteCount` 按实际分配计算；exit test 给 Foundation 建语料，量驱逐前后 malloc 在用字节数之差，与估算相差不超过 10%。交叉引用的 `CrossReferencePreparedImage.byteCount` 用同样的办法核对，超出的部分在上游，测试里记为已知问题。
3. [x] ~~关窗释放~~（已撤回，见决策日志），改为推出按钮：交叉引用模块加 `crossReferencePreparedByteCount` 命令；两个协调器加占用大小与 `ejectCorpora()` / `ejectPreparations()`；Report 的类别行显示大小与推出按钮。测试：推出语料后引擎进程的语料清空且不会自己回来；推出交叉引用后引擎先收到上限 0、再收到设置里的上限，按钮消失；同一引擎开第二个窗口不会再预建一次交叉引用。
4. [x] 文档：同批更新下文列出的文档。App 里点推出、量引擎进程的验收没做，列在提案索引的「暂缓的后续项」。

**验收**
- 三项各有测试，改代码之前先确认它是红的（新接口的测试先是编不过，再用变异检查确认它们能变红）：条件池里相等的条件共享存储；推出语料与推出交叉引用各自生效、不会自己回来、上限恢复；两个窗口共用一份交叉引用；语料估算的误差不超过 10%。
- 在 App 里：Report 的两个类别行显示大小与推出按钮；点推出后，对应引擎进程 malloc 在用的内存降掉这一类的占用（Catalyst 约 400 MB、My Mac 约 300 MB），footprint 当场只降一部分；之后搜索与交叉引用查询照常可用。
- 同批更新文档：`AGENTS.md` 讲 Engine 后台工作的那段写上「不自动释放、由推出按钮释放」，`Glossary.md` 增加「推出（eject）」条目。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-01 | Created as Draft | 运行中的 Debug 版三个进程合计约 1.7 GB；排查确认不是泄漏，增量来自 Find 语料与交叉引用表常驻在引擎进程里。用户选择写提案降低常驻内存。 |
| 2026-11-01 | 用户批准，开始实现；补上四个落地步骤 | 精简提案原本没有分步，按能各自编译验证的粒度拆开。 |
| 2026-11-01 | 释放与再加入的先后改为「新工作照常启动，释放结束后再走一遍引擎重来的路径」，不让新工作等释放完再启动 | 文档会直接调用协调器（Find 的搜索、Always Index 的提前读取），要让新工作等着，就得拦住每一个请求入口；`engineDidReset()` 本来就会撤回请求并重新请求全部已索引镜像，重复请求无害，被驱逐取消的构建也不会在 Report 里留下记录。只有释放还没做完时加入的工作才多走这一遍。（随关窗释放一起撤回。） |
| 2026-11-01 | 估算按元素数与 `malloc_good_size` 算，不按数组容量 | 按容量算的话，打印出的语料（追加时容量会多出来）与从派生数据读回的同一份语料（容量正好）估算不同，派生数据的几组测试要求两者的摘要相同。实测给 Foundation 建语料：原来的估算加上条件池是 19.8 MB，驱逐释放 22.1 MB，少 10.3%；改后估算 23.0 MB，多 4.5%。 |
| 2026-11-01 | 交叉引用的估算偏低一成多，留给上游，不在本提案里修；测试用 `withKnownIssue` 记下差距 | Foundation 的预建表估算 17.6 MB，置 0 后释放 19.9 MB，少 11.7%。这个数由 MachOSwiftSection 的 `CodeReferenceIndex.approximateByteCount` 与分析器的 `approximateByteCount(ofImageDataAt:)` 算出，它们按元素数算、不含分配头部与取整；RuntimeViewer 只是相加，要修就得改另一个仓库，超出了「只改 RuntimeViewer 自己的代码」。测试保留，上游修好后已知问题不再出现，测试会提醒去掉包装。用户确认先不修。 |
| 2026-11-01 | 释放后不调 `malloc_zone_pressure_relief`；验收改看 malloc 在用字节，footprint 只作参考 | 探针在进程内给 Foundation 与 AppKit 建语料（估算 69 MB）：驱逐后 malloc 在用字节从 148.9 MB 降到 85.1 MB，footprint 只从 196.0 MB 降到 165.3 MB，5 秒后不变；再调 `malloc_zone_pressure_relief(nil, 0)`，它报告还回 0 字节，footprint 仍是 165.2 MB。空出的块散在仍有活对象的页里，这个调用还不回来；它们留给进程以后的分配复用，系统内存紧张时才回收。 |
| 2026-11-01 | 释放由两个协调器各出一半（`releaseEngineCorpora()`、`releaseEnginePreparations()`），后台工作把两者合成一个任务交给 registry；重来用新的 `startOver()` 调各自已有的 `engineDidReset()` | 每个协调器只发自己那条命令，后台工作不必知道交叉引用模块的命令；重来的路径与引擎换了新进程时完全相同。（随关窗释放一起撤回。） |
| 2026-11-01 | 实现完成，待用户看过后收尾（关窗释放版） | 当时的验证：三步各有测试并做过变异检查；RuntimeViewerApplicationTests 全量 697 个只有「Call Hierarchy opens its root and loads its callers…」一条在满载下等待超时，单独跑通过，next 上同一批也挂在这一条（另多一条计时测试）。 |
| 2026-11-01 | 用户实测后决定：不自动释放，改为 Report 里由用户点的推出按钮；撤回关窗释放的全部代码与测试 | 实测里关掉 Catalyst 引擎的全部窗口再重开，语料要读回、交叉引用表要在 Debug 版里重新扫描，service 的 footprint 从首次建完的 864 MB 涨到 1.04 GB（放掉的内存大半留在进程里，重建时只复用一部分）。「最后一个窗口离开」判断不了用户还会不会马上回来，由用户自己决定更准。 |
| 2026-11-01 | 推出按钮放在 Report 的 Searchable Interfaces 与 Cross References 类别行，每类一个，旁边显示占用；只清这两类，不碰索引 | 用户从三种布局里选了按类别；按镜像推出要另加一组「当前常驻」的行，按引擎推出放在工具栏菜单里不好找。清索引会让已打开的窗口退回镜像列表、重新索引，是另一块大得多的改动。 |
| 2026-11-01 | 同一引擎开多个窗口只有一份交叉引用，不另改代码；加测试钉住 | 用户以为每个窗口各建了一份。查证：同一引擎的窗口共用一份后台工作（[0055](0055-engine-scoped-background-work.md)），第二个窗口不会再请求预建——新测试 `CrossReferencePreparationSharedByEngineTests` 通过，把 registry 改成每个窗口各建一份后它变红；Catalyst service 的内存图里 8 个镜像正好 8 份函数表、8 份名字表、1 个分析器。实测里的重新加载来自已撤回的关窗释放。 |
| 2026-11-01 | 推出语料时协调器忘掉请求过的镜像；推出交叉引用时先置 0 再恢复设置里的上限 | 搜全部镜像时，协调器只重新请求「从没请求过」的镜像，以免预算淘汰后每次搜索都重建；推出是用户主动清空，忘掉之后下一次全量搜索会把它们都请求回来。只置 0 不恢复的话，此后查询顺带预建的镜像一个也留不住。 |
| 2026-11-01 | 交叉引用的大小由新命令 `crossReferencePreparedByteCount` 向引擎进程要，不在 App 一侧把各镜像的估算相加 | 查询会顺带预建镜像、超出上限时会淘汰镜像，这些协调器都不知道；只有引擎进程的会话知道此刻留着多少，也就是推出能放掉多少。 |
| 2026-11-01 | 大小在这一类关着时记为 0、去重之后才进 Report 的树；占用大于 0 时类别行常驻 | 测试进程里所有引擎共用一个交叉引用会话，别的测试留下的预建会让关着这一类的 Report 多出一行；从「未知」到 0 的回答原本会让整棵树多重建一次。类别行常驻是为了 Clear History 之后仍能推出——`ReportViewModelTests` 里 Clear History 那条测试的期望随之改为「只剩没有子行的类别行」。 |
| 2026-11-02 | 落地：合进 `next` 并推送，状态改为 Implemented | 用户看过效果后收尾。没做的：App 里点推出、量引擎进程的验收（用户当时说先不测推出），以及交叉引用估算偏低约 12%（在上游 MachOSwiftSection，测试以已知问题记着），两项都列进提案索引的「暂缓的后续项」。不另写使用指南或实现说明：要遵守的约定（不自动释放、由推出按钮释放）已写进 `AGENTS.md` 讲 Engine 后台工作的段落；新术语「推出（eject）」已登记。后一篇 [0066](0066-on-demand-corpora-and-cross-references.md) 在它之上把常驻部分降到 64 MB。 |

# PR #88（perf/pipeline-optimizations）第三轮 max 级审查发现裁决 — 2026-08-13

对 PR #88 的第三轮 max 级 code review（15 条发现）经跨会话独立复核后的最终裁决。
审查基线：分叉点 `8e72b6c5` vs 分支 `9e6ca6a3`。发起会话产出发现并逐条完成「四问」；
复核会话独立验证，**修正了 5 条结论**（1 条提级、1 条降级、2 条归并错误、1 条误报改判）。
裁决按复核后的结论落档。ID 形式 `PR88R3.<N>`。

前两轮裁决见 [2026-08-09](2026-08-09-pr88-review-findings.md)（`PR88.<N>`）与
[2026-08-10](2026-08-10-pr88-max-review-findings.md)（`PR88R2.<N>`）。

**本轮的总体判断：15 条中没有一条是本 PR 引入的回归。** 每一处 PR 分支都严格优于 main；
问题一律是「优化只覆盖了一半」。这与前两轮不同（前两轮各有真回归，如 `PR88.2` 的 iOS
搜索大小写、`PR88R2.1` 的展开状态覆写），是这条性能线趋于收敛的信号。

## 已修（本批次，2026-08-13）

| ID | 严重度 | 摘要 | 修复 commit |
|---|---|---|---|
| PR88R3.1 | Major | 链接跳转的缓存对自己的请求键永远 miss：结果只按 `interface.object` 归档，请求键被 `entries[key] = nil` 清掉且不回填，「Back 之后再点同一个 token」每次全量重算（且本 PR 把该路径的选项从空改为完整选项，抬高了每次 miss 的代价） | `91e2169`（请求键→存储键重定向表 + 回归测试 `repeatedResolutionOfTheSameTokenHitsCache`） |
| PR88R3.2 | Major | 模糊搜索模式下侧边栏树每个命中行都在主线程重建富文本标题：`composedTitle()` 用 `ranges(of:)` 在整个子树聚合串里搜自己的 displayName，而该串按构造恒以 displayName 开头——每行一次全串扫描（`ranges(of:)` 收集全部匹配，连第一个命中都不短路），去重复现了本 PR 目标场景（打字路径主线程卡顿）的成本 | `e23725f`（常量 `NSRange(location: 0, length:)` 替换搜索） |
| PR88R3.3 | Minor | Open Quickly 索引（haystack）构建不去重：`cachedHaystacks` 在调度时同步快照、任务体内不重读，缓存冷时（每次 reload 后）落在构建窗口内的每个键击各开一份全量 O(N) 构建；`defaultHaystackBuilder` 无取消点，取消被取代的 pass 不释放任何东西 | `37c7a47`（`inFlightOpenQuicklyHaystackBuild` 共享在飞构建 + 改写既有测试同时钉住去重与不丢弃） |
| PR88R3.4 | Minor | Open Quickly 每次键击遍历整个「暖缓存」字典来取消高亮，而该字典按设计跨查询保留，于是每键主线程成本随会话时长上涨 | `37c7a47`（`highlightedOpenQuicklyRowIndices` 差集，保留暖缓存设计不变） |
| PR88R3.5 | Minor | Open Quickly 的 reload 作废（取消任务、代际递增、对象列表替换、缓存清空）在 `await super.reloadData()` **之后**的第二个 `MainActor.run` 里执行，而基类的 5 个 `MainActor.run` 中最后一个才安装 `nodes`；两者之间的 main-actor hop 是一个窗口 | `37c7a47`（基类新增 `didInstallReloadedNodes()` hook，作废与安装合并进同一同步临界区） |

### 关于 PR88R3.5 的测试缺口（诚实登记）

**这一条没有配回归测试，因为写不出确定性的复现。** 触发要求在飞的 pass 恰好在
「`nodes` 已安装、作废尚未执行」这一次 main-actor hop 内恢复并跑完全部剩余工作。而
`matchOffMain` 必然挂起，挂起就把 main actor 让给了作废块，其后的 `Task.isCancelled` /
代际检查就会拦住它。用 gated builder 精确编排时序也命中不了：pass 的 continuation 与
作废块的入队顺序无法在测试里固定。

修复本身仍然值得做：它把窗口**消除**而不是缩窄，形状与 `PR88R2.2`（根侧边栏
`installRebuiltNodes(_:)`）一致，是同一个 bug 在 Open Quickly 分支上未修的那一半。
但严重度按复核结论定为 Minor 而非 Major：即便命中，后果是 Open Quickly 面板停在
重载前的结果，**用户再敲一个字符即恢复**（`quickActionBar(_:itemsForSearchTermTask:)`
会重新武装 `currentSearchTask`），不是永久卡死，也不越界——264 行代际守卫到 289 行
赋值之间没有 await，`openQuicklyRuntimeObjects` 在该窗口内尚未被替换，索引与捕获的
haystacks 仍然对齐。

main 侧同一位置是裸 `Task.detached`，无取消无代际守卫，失效顺序一样（77 行
`super.reloadData()` 之后才在 82-83 行重建），故非回归成立。

## 已被前两轮覆盖（对照后跳过，不重走四问）

| 本轮发现 | 归入 | 说明 |
|---|---|---|
| `SidebarRuntimeObjectViewModel.swift:452` 快照/应用时序不对称 | `PR88R2.12` | 复核确认：446 行按值快照 `nodes`、452 行读 `self.nodes`，正是该条分析的 mismatch 条件，且「所有树变形源与代际递增在同一 main-actor 同步临界区」的论证在此同样成立（`nodes` 赋值与 `scheduleRefilter()` 同在一个 `MainActor.run` 内）。维持「加固建议挂起」 |
| `FilterEngine.swift:25` 大小写默认值只活在视图层 | `PR88.1` + `PR88.2` | 两条合起来盖住两个平台臂。**补充**：`FilterContext.isCaseInsensitive = false` 这个模型层默认值本身没被正面记过，它与 `PR88.8`（空查询清空整棵树，仅靠唯一调用方守约）是同一类隐形契约，照 `PR88.8` 加注释即可，不必排期 |

## 需要独立登记 / 补注（复核推翻了本轮的归并）

### PR88R3.6 — 根过滤管线的取消检查形同虚设（`PR88R2.15` 的第 (d) 项）

`SidebarRootFilterPipeline.verdicts` 的 `Task.isCancelled` 只在顶层 forest 条目之间检查，
而根 forest 恰好只有 **2** 个条目（`RuntimeEngine.swift:471`
`setImageNodes([dyldSharedCacheImageRootNode, otherImageRootNode])`，已复核）。两次检查都在
实质工作之前；`verdictNode` 递归内与 `unfilterSubtree` 零检查。于是每一趟被取代的过滤
都会把 ~1.3 万节点的聚合串构建与逐节点 `localizedCaseInsensitiveContains` 跑到底，
`currentRootFilterTask?.cancel()` 什么也释放不了。

**不能并入 `PR88R2.15` 了事**：那条登记的是三笔开销 (a)(b)(c)，且它写的修法
（`ancestorMatched` 短路 + 聚合缓存）**不解决取消问题**——修完 (a)(c) 之后，被取代的
那一趟照样跑到底。作为 **(d)** 登记，随该批一并处理。

两个必须一并记住的点：
- **同形代码不同结论**：`SidebarRuntimeObjectFilterPipeline.swift:69-72` 写法一模一样，
  但对象树顶层是数千个对象，**那边的取消检查是有效的**。不要写成「两条管线同形所以同结论」。
- 两份文件的注释都写着 "Checks for cooperative cancellation between top-level nodes"，
  root 那份字面为真但实际等于没有；即便不修，也应把注释改准。

### PR88R3.7 — 对象过滤管线的快照进入被 scope 裁剪的子树（独立于 `PR88R2.7`）

`SidebarRuntimeObjectFilterPipeline.snapshot(of:scope:)` 无条件递归进
`cell.unfilteredChildren`（第 55 行），即使该节点已被 scope 裁掉；同时对每个节点调
`cell.matchesScopeRecursively(scope)`（第 54 行），而该函数自身要走完整个子树——scope
激活时是 sum-over-nodes 的子树大小而非 O(N)。第 53 行读 `currentAndChildrenNames` 还会在
缓存冷时**在主线程**为注定被丢弃的子树构建聚合串。删掉的旧 cascade 只进入 scope 幸存者，
所以这是严格多于基线的主线程工作；scope-only 过滤（空查询 + 激活 scope）路径下，真正
移出主线程的只有一次空查询 `FilterEngine.match`，即恒等函数。

**主题与 `PR88R2.7` 对不上**：那条讲的是时序/陈旧（reload 后 scope 激活时快路径被跳过、
loaded 界面短暂绑着旧 cell、点击 push 过期对象），本条讲的是开销。更接近
`PR88R2.15(c)` 的对象侧同胞。独立登记，随下一轮 sidebar 性能工作拾起。

### 对 PR88.9 的补注（必须补，否则将来只会修掉一半）

`PR88.9` 描述的展开状态持久化丢弃路径是 `filteringState == .idle` 守卫被 `beginFiltering`
打断。本轮发现的是另一条：`scheduledExpansionPersistStructureVersion == dataStructureVersion`
守卫失配时静默丢弃且不重排（`StatefulOutlineView.swift:309`）。**那个守卫是第二轮修
`PR88R2.1` 时（`3a99ca68`）才加进来的，写 `PR88.9` 时并不存在。** 后果与修法相同
（失败时重排一次），并入可以，但必须在 `PR88.9` 行内注明这条新增路径。

> 已在 [2026-08-09](2026-08-09-pr88-review-findings.md) 的 PR88.9 行补注。

## False positive / 不修（留档防止重查）

### PR88R3.8 — 「外层 `catchAndReturn` 被删导致 `bind(to:)` 无保护」（误报，且方向相反）

`ContentTextViewModel.swift:135-141` 的注释已写明内层 catch 是有意设计。复核对了
merge-base 与 PR HEAD 的 diff：**旧代码的 `.catchAndReturn(nil)` 挂在 `flatMapLatest`
之后**，而 RxSwift 中内层 error 会穿透 `flatMapLatest` 终止外层序列——旧写法就是
「首次错误 → 发一个 nil → complete 整条链」，正是注释警告的永久冻结该 tab。新写法
严格更好。

补充正面证据：新外层链上**没有任何 error 源**——`themeObservable` 是
`ResolvedThemeStream.observable`（tracking + `distinctUntilChanged` + `share`，无错误
路径），render 半段是 `just(()).observe(on:).map { }`，`map` 非 throwing，
`trackActivity` 不注入错误。`bind(to:)` 拿不到 error。

### PR88R3.9 — 缓存「幽灵 LRU 键」（**可达**，但最坏后果=一次冗余取数）

原发现主张的路径不可达：`ContentTextViewModel.swift:229-231` 的 push 发生在解析取数
**完成之后**（`.emit` 里才 `trigger(.push(interface.object))`），所以目标页的显示取数
必然命中已写好的条目，不会创建在飞条目。

**但复核构造出了另一条可达路径**，本轮据此改判：两笔取数请求键不同、存储键相同——
tab A 正在显示对象 O（请求键 K_O），tab B 点了指向 O 的链接（请求键 K_合成）。若 B 先完成，
它把 `.ready` 写到 K_O 上，**覆盖 A 的 `.inFlight`**（原第 130-134 行「只有这个创建者路径
会改下面的条目」的注释在该交错下不成立）；随后 A 恢复，无条件 `entries[key] = nil` 删掉
刚写好的条目。A 正常返回非 nil 时同一同步块内立刻重写回去而**自愈**——这正是它一直没被
撞见的原因；A 返回 nil 或抛错（XPC 断链、文档关闭时 fetcher 抛 `CancellationError`）才
留下幽灵：K_O 在 `readyKeysByRecency` 里而 entries 中没有它。

后果比原发现描述的轻得多：幽灵要么被下一次同键 store 经 `markRecentlyUsed` 去重吃掉，
要么被 `evictBeyondCapacity` 弹出；最坏是弹出时该键上恰好有活的 `.inFlight`——等待方
持有的是 Task 对象本身，照样拿到值，代价只是丢一次 dedup、多一趟引擎往返。不返回陈旧
数据、不崩、不无界增长。

**裁决：随 PR88R3.1 一并消除**（`clearInFlight(_:ifStillOwnedBy:)` 只删自己那一笔的
在飞条目），因为——

> ⚠️ **PR88R3.1 与本条是耦合的，两轮裁决都没记过这一点。** PR88R3.1 的修法引入
> 请求键与存储键的别名关系，会让本条的交错**更容易**形成、也更容易撞上活条目。
> 「不可达」这类结论必须连同「什么改动会让它变可达」一起记，否则一条被判死的发现
> 会在修另一条时悄悄复活。回归测试
> `failingFetchLeavesAConvergedEntryIntact` 钉住了这个交错。

### PR88R3.10 — 「漏掉 `dataSource` 重设 / `noteNumberOfRowsChanged()`」（不可达）

`StatefulOutlineView` 的 5 个 override（`reloadData` / `insertItems` / `removeItems` /
`moveItem` / `reloadItem(_:reloadChildren:)`）**完整覆盖** RxAppKit outline adapter 的全部
树变形入口（`NSOutlineView+StagedChangeset.swift:56,63,76,80,87`）。`dataSource` 由
DelegateProxy 设置，而 `SidebarRuntimeObjectCoordinator.swift:25` 只在 `.initial` 路由调
一次 `setupBindings`，`.objects` / `.bookmarks` 只是 `.select(index:)`；切换 image 是整个
新建 coordinator + ViewController + outline view，不存在重设 `dataSource`。
`noteNumberOfRowsChanged()` 全仓库只有 UIFoundation 自己的 override，无应用侧调用点。

**但值得记住的部分**：展开状态持久化在本仓已经修过至少三次（`997f4737` 改进过滤与
展开状态恢复、`69c4f38a` 修可靠恢复、`3a99ca68` 加结构版本号防护）。原发现提出的
「改用通知 `userInfo["NSObject"]` 增量维护展开集合」比继续枚举 AppKit 入口更根本，
且能同时去掉 O(rows) 全表走查与版本计数器。随 outline 那批工作一并考虑。

### PR88R3.11 — 「并发 scheduler 让被取代的渲染并行跑」（取舍，非缺陷）

`ConcurrentDispatchQueueScheduler` 下被取代的构建确实真并行跑（`flatMapLatest` 丢弃的是
emission，不是已开始的计算）。但串行会让新构建排在旧的后面等，用户看到结果更慢；
并发是用内存峰值换响应速度。

**不单独排期，但挂到 `PR88.10` 那一行**：每一份并行构建都带着 `PR88.7` 记过的 `.copy()`
瞬时 2× 峰值，而 `PR88.10` 已写「稳态基线 239 MB，大接口常驻敏感度上升」。连点字号在
`UIView.h` 量级接口上会把峰值乘几倍——它是那场讨论的输入，不是独立问题。

### PR88R3.12 — 「每个 ViewModel 一个 DispatchQueue」（属实，成本微小）

`PR88.6`（`30d6fef`）修的是「每次发射新建一个」，剩下「每个 ViewModel 一个」。
`ContentCoordinator.rebindTextViewController` 每次导航都构造新的 `ContentTextViewModel`，
所以确实是每次 push / next / back / tab 切换一个 DispatchQueue。改成
`private static let` 是安全的（`renderAttributedString` 是 `nonisolated static`、
无实例状态），**可顺手做，不值得单独排期**。

## 结构观察（不作为缺陷登记）

`SidebarRootFilterPipeline`（160 行）与 `SidebarRuntimeObjectFilterPipeline`（188 行）
约 55 行同构：`ForestVerdict` + `.empty`、`snapshot(of:)`、`apply(_:to:)`、`applyNodes`
（两者都是：count 守卫、`zip`、递归进 `cell.unfilteredChildren`、
`applyFilterOutcome(... indices.map { unfilteredChildren[$0] })`）、`resetToUnfiltered`。
真正不同的只有 `verdictNode`。

本轮的 PR88R3.6、PR88R3.7 各是「一条管线有、另一条没有」的缺陷，`PR88R2.13`
（localized 折叠不一致）也是——这就是拆分的具体代价。两种 cell 都已暴露泛型管线需要的
两个成员（`unfilteredChildren` + `applyFilterOutcome`），扁平版本的抽象
（`FilterableItem` + `FilterEngine.filter(context:items:)`）已在 `FilterEngine.swift`。
泛型树形版本应放在它旁边，每条管线只保留自己的 `verdictNode`。

注：根侧边栏不走 `FilterMode` 早于本 PR（基线 `SidebarRootCellViewModel.filter` 的 didSet
同样硬编码 `localizedCaseInsensitiveContains`），本 PR 是把它固化进一个新的 160 行文件，
而非引入。

> 修复后回填：某条 backlog 被修掉时，按本目录惯例在行内登记修复 commit，不删行。

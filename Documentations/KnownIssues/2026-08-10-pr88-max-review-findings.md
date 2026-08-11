# PR #88（perf/pipeline-optimizations）第二轮 max 级审查发现裁决 — 2026-08-10

对 PR #88 的第二轮 max 级 code review（15 条发现 F1–F15）经跨会话独立复核后的最终裁决。
发起会话产出发现；复核会话逐条读代码验证（含 RxSwiftPlus / RxConcurrency 依赖源码实测），修正了
其中 4 条的结论或严重度；裁决按复核后的结论落档。ID 形式 `PR88R2.<N>`，编号对应原发现 F<N>。

## 已修（本批次，2026-08-10）

| ID | 严重度 | 摘要 | 修复 commit |
|---|---|---|---|
| PR88R2.1 | Major | 展开状态持久化：coalesced flush 在树被整体重建后仍执行，收集空结果覆写用户的展开状态（新引入：旧版在通知回调内同步 persist，无此窗口） | `3a99ca68`（outline 结构版本号防护 + 3 条测试） |
| PR88R2.2 | Major | 根侧栏过滤作废动作经 `subscribeOnNextMainActor` 异步 hop，晚于同步的新树装载，被作废的过滤结果可覆盖新树且无自动恢复 | `920c2aa3`（合并为同步 `installRebuiltNodes(_:)` + 2 条测试） |
| PR88R2.3 | Major | 类型链接跳转缓存键错位：resolution fetch 以点击合成对象为键，display fetch 以引擎重建的权威对象为键——Swift 支全部 miss（不止跨 image）、ObjC 支跨 image miss，双倍生成且 resolution 键占 LRU | `9f32e85e`（缓存按 `interface.object` 回填索引 + 1 条测试） |
| PR88R2.9 | Minor | 被作废的过滤趟丢弃已完成的 haystack 构建（构建只依赖对象列表、与查询无关），构建慢于查询间隔时缓存永不建立且被丢弃的构建照跑 | `523d98dd`（对象列表版本号守卫下提前安装 + gated-builder 测试） |
| PR88R2.10 | Minor | 新 materialize 的 cell 被标高亮时触发 `composedTitle()`，在主线程重建与后台 pass 逐字节相同的子树 haystack（parity 契约明示两串相同） | `b3c65095`（materialize 时用 pass 的 haystack 播种 cell 缓存 + SeedMarker 测试） |
| PR88R2.11 | Major | Open Quickly 宽查询（单字符 fuzzy 命中近全部行）在一个 main-actor turn 内 materialize 全部行，重现被删除路径的 O(N) 主线程成本且每次 reload 后首个宽查询重付 | `11238751`（按 fuzzy 分数截断前 500 行 + 行数上限测试） |

复核对首批三条的严重度维持原判；PR88R2.11 由第三梯队提为 Major（它是 15 条中唯一在本 PR
自己的目标场景——打字路径主线程卡顿——上复现被删除问题的发现）。

## False positive / 不修（留档防止重查）

### PR88R2.5 — transformer 合并选项的一个 tick 时序偏差（基本误报）

`currentMergedGenerationOptions` 同步读 `settings.transformer`，内容管线的 `Observable.tracking`
re-arm 晚一个 main-queue tick。机制属实，但构造不出用户可见后果：

1. 新 push 的 `ContentTextViewModel` 订阅 tracking 时**首发射同步读当前值**（re-arm 延迟只影响
   已订阅链的后续发射）——「目标页渲染改动前的文本」不成立；
2. 写 settings（设置面板事件）与读 options（保存 / 链接点击事件）分属不同用户事件，间隔远超
   一个 tick，人类操作凑不出重叠；
3. 即便撞上窗口，后果是多一次 fetch（键分裂但各自正确）或保存文本比屏幕早一个 tick 更新，最终一致。

**裁决：不修。** `MainViewModel` 保存 / 分享路径的同一引用同理。

### PR88R2.12 — 过滤管线 `applyNodes` 非事务改写（降为加固建议）

`applyNodes` 深度优先边走边写，第 k 个 cell shape 失配时前缀已改写，且 `applyFilterOutcome`
直写 `filterContextStorage` 使等值守卫短路。两管线同形，均属实。但触发路径当前不可达：

- 所有树变形源（reload / splice / 查询变更）与代际递增在同一个 main-actor 同步临界区内完成，
  apply 与其代际检查之间无 await；
- root 侧唯一的异步作废窗口（PR88R2.2，已修）发生时，apply 作用于 Task 捕获的旧 cells 数组，
  其内部 shape 自洽——走的是成功路径而非 mismatch，两个发现互斥；
- 「永久失联」不成立：下一次成功 refilter 的 `applyFilterOutcome` 无条件全量覆盖，残留窗口
  只到下一次过滤触发。

**裁决：作为加固建议挂起**（若做：apply 先只读校验全树 shape，通过后再第二遍写入），不排期。

### PR88R2.14（正确性段）— 「特化后必 miss + 死条目占 16 格」（误报，撤销）

`.specializationAdded` 与 `.fullReload` 走同一个 `dataChangePublisher`，而
`RuntimeInterfaceCache` 的订阅 `.map { _ in () }` **不分 case 全量 flush**——特化事件当场清空
整个缓存，不存在跨特化的死条目。（副作用是特化一次全缓存清零，属过度失效，另行讨论。）
性能段（Key 内嵌整棵 `children` 的 hash/== 常数成本）属实，见 backlog。

## 暂不修（backlog，后续拾起）

| ID | 严重度 | 摘要 | 状态与理由 |
|---|---|---|---|
| PR88R2.4 | Minor | `invalidateAll` 经 `subscribeOnNextMainActor` 异步 hop 晚一个 main-actor turn，窗口内 hit 返回旧源文本；类文档承诺「绝不返回过期接口」未被实现兑现 | 触发窗口极窄、后果一次性陈旧渲染。注意 `RuntimeEngine` 是 actor、`dataChangePublisher` 从非主线程发出，不能简单改同步订阅；需 `observe(on:)` + 同步 main 路径设计，随下一轮缓存工作拾起 |
| PR88R2.6 | Minor | 缓存 fetch 的 `Task { fetcher }` 脱离结构化取消：`flatMapLatest` 释放只取消 awaiting 侧，在飞引擎生成照跑（改前 `Observable.async` 的 dispose 直达 engine 调用）；`.inFlight` joiner 同样不响应取消 | 正确性由代际守卫兜住，纯资源/延迟问题。joiner 需 `withTaskCancellationHandler` + 引用计数取消才能保住 dedup 语义，非一行改；`invalidateAll` 不取消在飞 fetch 是注释明示的设计（已 await 的 caller 要拿到值） |
| PR88R2.7 | Minor | reload 后 scope 激活时快路径被跳过，`filteredNodes` 只在异步 Task 里赋值：loaded 界面短暂绑着旧 cell，点击会 push 过期对象；书签侧栏订阅整个书签字典，触发频率高 | 低成本修法：`shouldFilter` 分支也先同步装未过滤新树再异步 refine（与 root 侧行为对齐）；随下一轮 sidebar 工作拾起 |
| PR88R2.8 | Minor | specialization splice 的 `reloadRow` 同步展开时，新 child cell 高亮缺失、其子树未过滤（parent 层过滤实际同步完成；瞬时视觉，pipeline 完成后自愈） | 与 PR88R2.7 同一批处理 |
| PR88R2.13 | Minor | object 侧 plain-contains 从 `localizedCaseInsensitiveContains` 改为无 locale 的 `range(of:options:)` 后，与 root 管线（保留 localized）折叠规则不一致；无 locale 语义测试钉住 | **修复方向与原发现相反**：非 localized 折叠对符号搜索更正确（tr/az locale 下 localized 版查询 "i" 匹配不了 "Image"），应把 root 管线统一到非 localized 并补 locale 对测试，而非恢复 localized |
| PR88R2.14（性能段） | Minor | 缓存 Key 内嵌整个 `RuntimeObject`（含递归 children）的 hash/== 常数成本；`markRecentlyUsed` 线性扫描至多 16 次递归 ==；链接合成对象把源类 children 带进 key 加剧 | 多数对象 children=[] 时微秒级；等缓存键结构再演进时一并考虑（注意不能裸换 `RuntimeObjectKey`——children 变化影响生成文本，现靠全量 flush 兜底） |
| PR88R2.15 | Minor | root 过滤管线每键三笔开销：(a) 后台重建全树聚合串（cell 侧 lazy 缓存已删）；(b) snapshot + apply 两遍 O(N) 主线程遍历（~1.3 万节点 ms 级/键）；(c) 祖先命中后子树先逐个匹配再被 `unfilterSubtree` 覆盖 | (a)(c) 在后台执行、(b) 主线程 ms 级——与 main 是不同 tradeoff 而非纯回归。修法：递归传 `ancestorMatched` 短路 + 聚合缓存（配合既有代际）；随下一轮 sidebar 性能工作拾起 |

### 复核中提级 / 新增的条目

- **`SidebarRootCellViewModel.lazy _children` 后台/主线程竞争**（次要项提级）：后台
  `indexedNodes` 迭代与主线程管线遍历可并发**首次**触碰同一 cell 的 lazy var（Swift lazy 非
  原子），理论上双构建 / 撕裂（crash 级，低概率）。建议随 PR88R2.15 一并处理。
- **`RuntimeImageNode` weak-parent 生命周期陷阱**（落地测试时新发现）：`parent` 是 weak、
  `absolutePath` 是 lazy 且靠 parent 链推导——持有裸叶子而不锚定 root 时祖先链释放，
  `path` 坍缩为 `"/"`（`absolutePath` 的 decode 注释早已记录同款坑）。测试脚手架已用
  `withExtendedLifetime(root) { _ = leaf.absolutePath }` 固化；生产侧 root 恒由 engine/VM
  持有，暂无实害。同目录 `OpenQuicklyLazyConstructionTests` 的同形代码靠 -Onone 下局部
  变量活到作用域尾才幸免，属未承诺的 ARC 行为，后续测试基建工作时一并加锚。
- 其余次要项（`resetToUnfiltered` 存 scope 不应用、filterMode 切换不重过滤、`children`
  setter 不设 parent、`ResolvedThemeStream` 永久捕获 Settings、`MainViewModel` sharing
  回调在任意线程读 `@MainActor` 属性、`SidebarRootFilterPipeline.verdicts` 的 assert 在
  -O 下编译掉、三处代际令牌等重复簇）复核均属实，维持次要级，随各自区域的后续工作拾起。

> 修复后回填：某条 backlog 被修掉时，按本目录惯例在行内登记修复 commit，不删行。

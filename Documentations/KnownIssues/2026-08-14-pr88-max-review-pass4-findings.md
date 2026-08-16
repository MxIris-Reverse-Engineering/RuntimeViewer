# PR #88（perf/pipeline-optimizations）第四轮 max 级审查发现裁决 — 2026-08-14

对 PR #88 的第四轮 max 级 code review 裁决。审查基线：分叉点 `8e72b6c5` vs 分支 `7276ae97`。
九个角度并行产出发现，发起会话逐条完成「四问」，另一个会话做对抗性复核，**修正了 3 条结论**
（1 条提级、1 条判为既存问题、1 条判为重报）。ID 形式 `PR88R4.<N>`。

前三轮裁决见 [2026-08-09](2026-08-09-pr88-review-findings.md)（`PR88.<N>`）、
[2026-08-10](2026-08-10-pr88-max-review-findings.md)（`PR88R2.<N>`）与
[2026-08-13](2026-08-13-pr88-max-review-findings.md)（`PR88R3.<N>`）。

**本轮的总体判断：真发现全部落在「为修上一轮发现而写的那两个提交」里。**
`37c7a47d`（共享 haystack 构建 + 单回合失效）与 `91e2169d`（重复点击链接的缓存命中）
各自引入了一条新缺陷，而它们本身就是第三轮 `PR88R3.3` / `PR88R3.5` / `PR88R3.1` 的修复，
落地后没有再被审过。这不是这条性能线的系统性问题，而是「修复未复审」这个流程缺口的表现。

## 已修（本批次，2026-08-14）

| ID | 严重度 | 摘要 | 修复 commit |
|---|---|---|---|
| PR88R4.1 | Minor | `reloadData()` 的 `.notLoaded` 提前返回与 `scheduleReload()` 的 `.loadError` catch 都不再执行子类失效钩子。被替换掉的 override 在 `super.reloadData()` **返回后**无条件执行，而 `.notLoaded` 走的是 `return` 不是 `throw`，故两条路径原本都被覆盖。后果：在飞的 Open Quickly pass 代际令牌仍然有效并发布已卸载镜像的行、搜索串不清空、整个 Open Quickly 索引常驻 | `ee860bb7`（钩子改名 `invalidateNodeDerivedState()` 并在三个终态调用 + 回归测试 `SidebarReloadInvalidationTests`） |
| PR88R4.2 | Minor | `openQuicklyHaystacks(forObjectListVersion:runtimeObjects:)` 对陈旧版本没有早退：pass 任务体入队时 `reloadData()` 的末个 `MainActor.run` 可能已排在它前面，于是 body 起跑时捕获的版本已失效，函数内三个检查同时落空——对已废弃列表启动全量 O(N) 构建、占住共享在飞槽位（后续 pass 再也 join 不上活跃构建）、末尾版本守卫又跳过清理，把废弃对象数组和成品 haystacks 一起钉到下次 reload | `9117025a`（把既有代际检查提到 haystack 调用之前） |
| PR88R4.3 | Minor（命中后果为 Major，但可达性未构造出） | 学习到的重定向只写不擦：`if storageKey != key` 没有 `else` 分支。一旦某请求键改为解析到自身，正确接口存进了请求键，而旧重定向仍把查询导向别处——那条刚存好的条目永久不可达，之后每次请求要么重取、要么被服务另一个类型的接口。该字段自己的注释用「后续的 store 会覆盖它」为陈旧重定向辩护，而在唯一要命的情形里 store 恰好走另一分支、不覆盖 | `97c253e7`（补 `else` 清除 + 订正注释 + 回归测试 `selfKeyedResolutionClearsStaleRedirect`） |
| PR88R4.4 | Minor | `RuntimeInterfaceCache.Key` 内嵌整个 `RuntimeObject`，于是 `children`（递归）、`displayName`、`properties` 都参与缓存身份。三重代价：每次查表哈希一整棵子树；点击链接的合成目标（只能带上**正在显示**的那个对象的 `children`，`displayName` 由印出的 token 拼成）永远匹配不上它解析到的权威对象，而这正是重定向表存在的理由；重定向表 `[Key: Key]` 只由 `invalidateAll()` 清理，每行钉住两张递归对象图，绕过了 16 条接口的容量设计 | `35ebcf9a`（改用 `RuntimeObjectKey`，即 `(imagePath, name, kind)` + 回归测试 `syntheticTargetSharesTheAuthoritativeObjectsEntry`） |
| PR88R4.5 | Minor | `seedCurrentAndChildrenNames(_:)` 自 `e23725f1` 起无任何读者：`composedTitle()` 改用常量 `0..<displayName.count` 后不再读 `currentAndChildrenNames`，而 filter pipeline 只走 `forOpenQuickly: false` 的树，`filterableString` 那条被 `FilterEngine.filter` 的空上下文守卫挡在前面。种进去的字符串被存下来但从不读取，外面却挂着一段称字节级 parity 为「hard contract」的注释 | `2e40bd21`（删除该接缝、`haystack:` 参数与两条覆盖它的测试；把 parity 注释改写为真正仍然生效的**前缀**契约，并在 parity 测试里为两个 builder 各加一条前缀断言） |

### 关于 PR88R4.2 的测试缺口（诚实登记）

**这一条没有配回归测试。** 触发窗口要求在 pass 的 `Task` 创建与其 body 执行之间插进一个
main-actor job，而现有代码没有任何接缝能让测试做到：`scheduleOpenQuicklyRefilter` 是
`private`，`@testable` 够不到；防抖计时器与 reload 的 `MainActor.run` 之间的入队顺序也
无法在测试里固定。

试过并排除的路径：靠 `Task.isCancelled` 走不通（被取代的 pass 会 join 现有构建，
`startedBuildCount` 不变）；靠 gated builder 卡住再触发 reload，走的是「构建期间 reload」
那条路径，而那条路径的末尾版本守卫本来就是对的。

未加生产接缝换取可测性，理由是 `PR88.14`（生产类型里的测试钩子）已在 backlog 上；
为一条一行的纯防御性守卫再加一个接缝不划算。此缺口与 `PR88R3.5` 同类，两者都记在案。

## 文档修正（本批次）

| 项 | 摘要 | commit |
|---|---|---|
| AGENTS.md §9 | 原文点名 `SidebarRuntimeObjectCellViewModel`「must stay eager」，而本 PR 正是把它改成按需构造。复核指出 Open Quickly 的实现**满足 §9 立论的理由**（暖缓存保证跨击键实例同一性，DifferenceKit 身份稳定），违反的只是字面。故改措辞、区分两种 lazy，不改代码 | 见本批次 |
| Evolution 0005 | 非目标写明不触碰 `SpecializationTypePickerCellViewModel`，落地记录却把它列入改动清单并称「与提案方案一致」，且无「与提案的差异」一节。按提案是决策快照的规则，不修改正文，补差异节 | 见本批次 |

## False positive / 不修（留档防止第五轮重查）

### PR88R4.6 — `ResolvedThemeStream` 的 `.share(replay: 1, scope: .forever)`（既存问题，且后果不成立）

发起会话报为本 PR 引入的新缺陷，**判错**。`ResolvedThemeStream.swift` 在分叉点
`8e72b6c5` 上就已存在，同一行 `.share(replay: 1, scope: .forever)`、同一句
「remains armed across document opens/closes」注释；本 PR 只改了 8~10 行（把 Settings
解析提到 tracking 闭包外）。

RxSwift 语义部分的判断是对的：`.forever` 只保留 replay subject，`refCount()` 在订阅数
归零时仍会释放上游连接，`Observable.tracking` 的 `ObservationTracker` 被 cancel，注释
确实失实。但推测的后果（关掉全部文档 → 改主题 → 新开文档时旧主题上屏 + 整页重复渲染）
**不成立**：`ContentTextViewModel` 里 `$theme` 的 bind 先订阅并泵起连接，render half 后
订阅只看到最新值，且 render 的 `combineLatest` 要等 interfaceStream 的异步 fetch 首发
才触发，届时 theme 槽位早已是新值。

剩余实害仅为注释与实现不符。**不进本批次**（既存问题，且属主题流那条线）。

### PR88R4.7 — Open Quickly 500 行上限截断结果集（重报已裁决条目）

> ⚠️ **本条已于第五轮翻案，见 [2026-08-16](2026-08-16-pr100-review-findings.md) 的
> `PR100.2`（已修 `79a6b3c`）。** 下面「`fuzzyMatch` 确实 best-first ⋯ 丢的是低分尾巴
> 而非任意 500 条」这个排除理由**被实测证伪**：排序确实按 weight 降序，但 weight 是
> **退化**的——`fuzzyMatch` 在 pattern 耗尽时冻结分数，所有连续包含查询串的名字同分，
> 所以丢的和留的分数完全相等。真实 AppKit 类表实测：`view` 命中 713、并列 639，砍掉
> 139 个满分行；`vi` 命中 1038、并列 875，`NSView` 落第 502 位被砍。
> 教训：**「按分数排序」不等于「分数有区分度」**——排除一条截断类发现之前，要验的是
> 分数分布，不是排序方向。

`verdicts.prefix(500)` 在发布前执行、`filteredNodesForOpenQuickly` 被截断、无 UI 提示，
行为描述属实；`fuzzyMatch` 确实 best-first（`UIFoundation/FuzzySearch.swift` 按 weight
降序），丢的是低分尾巴而非任意 500 条。

但**这就是 `PR88R2.11` 的修复本身**（`11238751`，0810 裁决文档原文：「按 fuzzy 分数截断
前 500 行 + 行数上限测试」），按 out-of-scope 规则出局。

若认为「无 UI affordance」值得处理，那是对 `PR88R2.11` 裁决的**增补议案**，不是新缺陷。

### 其余经复核维持排除的发现

| 发现 | 裁决 |
|---|---|
| `composedTitle()` 的高亮范围是 Character 偏移、却喂给按 UTF-16 计的 `NSMutableAttributedString.addAttributes(_:range:)`，含多 UTF-16 单元字素的名字会错位 | main 经 `integerRange(from:)` → `distance(from:to:)` 算出完全相同的值，**非本 PR 引入**。永不越界（Character 数 ≤ UTF-16 长度），仅错位。新注释只主张「与改前相比 ranges 不变」（属实），未主张对 `NSAttributedString` 绝对正确，故不算误导 |
| `.isSpecialized` 覆盖 `.isGeneric` 的 `tertiaryIcon`（Inspector 两处 + Sidebar 一处顺序 `if`） | main 同形，非本 PR 引入。`InspectorRuntimeObjectCoordinator` 的 `isGeneric && !isSpecialized` 证明两标志确实共存，属既存问题 |
| 三处 `nonisolated static func …OffMain` 依赖 SE-0338，将来启用 SE-0461 会静默回到主 actor | 当前安全：`.nonisolatedNonsendingByDefault` 在 `Package.swift` 只有**声明**（约 512 行），从未 append 进任何 settings 数组，且 `swiftLanguageModes: [.v5]` 仍在。另注意 `sharedSwiftSettings` 并非无人使用（`RuntimeViewerArchitectures` / `RuntimeViewerUI` 两个 target 在用），但 OffMain hop 所在的 `RuntimeViewerApplication` 不用它 |
| `ViewModel.currentMergedGenerationOptions` 与 `ContentTextViewModel` 内联 merge 是两份手抄 | 逐条比对 `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` 条件与两个分支取值，**当前完全一致**（含 Catalyst）。维护性风险，非活 bug。另 `ExportingProgressViewModel` / `BatchExportingProgressViewModel` 是第三、四份副本，同样一致 |
| `StatefulOutlineView` 的 `isExpansionPersistScheduled` 与 `scheduledExpansionPersistStructureVersion` 在异步块内存在不一致窗口 | 生产里唯一的 `persistentObjectForExpansion`（`SidebarRootViewController.swift:131`）是纯读取，重入路径不可达；且后果与 backlog 上的 `PR88.9` 是同一个 |
| `applySpecializationAdded` 重新赋值 `nodes` 却不调失效钩子 | main 的 `nodesForOpenQuickly` 同样只在 `reloadData` 重建，非回归。新代码的索引对齐耦合更紧，属未来隐患 |
| `SemanticString+ThemeProfile.resolveSwiftLinkTargets` 把同一 identifier 的每次出现累加进 `displayName` | 代码事实待查（`+=` 也可能是在拼一次出现的多个 component），但 `PR88R4.4` 换键后 `displayName` 不再参与缓存身份，对本 PR 关心的路径已无影响 |

## 遗留观察（未开条目，供后续参考）

- 第三轮裁决文件里的修复 commit 列仍是 `<commit1>` / `<commit2>` / `<commit3>` 占位符，
  从未回填真实哈希。不影响本轮，但下次触碰该文件时应补。
- 测试基建的重复（`pollUntil` 在同一 target 里 7 份声明，其中共享版用 `try?` 吞掉取消并
  空转到超时、6 份私有副本用 `try` 直接抛出，两套语义并存；`makeRuntimeObject` 五种签名；
  `AsyncLatch` / `HaystackBuildGate` / `SharedLocalEngineTestLock` 三份等价的续体门）
  归并进 `PR88.12` / `PR88.13` 的测试基建批次处理，本轮不动。

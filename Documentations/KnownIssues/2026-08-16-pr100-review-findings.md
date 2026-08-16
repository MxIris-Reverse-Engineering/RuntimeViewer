# PR #100（perf/pipeline-optimizations）第五轮审查发现裁决 — 2026-08-16

对同一条性能线的第五轮 code review（15 条发现）裁决。分支未变，PR 编号已从 #88 变为
**#100**，故本轮 ID 形式为 `PR100.<N>`；引用前四轮时仍用它们各自的 `PR88*` 前缀。
审查基线：分叉点 `8e72b6c5` vs 分支 `e6e70af3`，base `origin/next` @ `5ef0fc79`。

发起会话产出发现并逐条完成「四问」，另一个会话（`RuntimeViewer-Fable`）做对抗性复核，
**推翻或修正了 4 条结论**（1 条翻案撤销、1 条由真发现改判不可达、1 条可达性降级、
1 条结论维持但论证重写）。裁决按复核后的结论落档。

前四轮裁决见 [2026-08-09](2026-08-09-pr88-review-findings.md)（`PR88.<N>`）、
[2026-08-10](2026-08-10-pr88-max-review-findings.md)（`PR88R2.<N>`）、
[2026-08-13](2026-08-13-pr88-max-review-findings.md)（`PR88R3.<N>`）与
[2026-08-14](2026-08-14-pr88-max-review-pass4-findings.md)（`PR88R4.<N>`）。

**本轮的总体判断：15 条里只有 8 条是新发现，4 条是重报已裁决条目。**
这个比例本身是信号——这条性能线的缺陷面已经收敛到前四轮画出的边界内，第五轮的边际
收益主要来自两处「翻案」：一条前轮排除的发现被实验证据翻了回来，一条本轮的翻案又被
实现体证据翻了回去。

## 已修（本批次，2026-08-16）

| ID | 严重度 | 摘要 | 修复 commit |
|---|---|---|---|
| PR100.2 | Major | Open Quickly 的 500 行上限按名序确定性截断满分并列类：`fuzzyMatch` 在 pattern 耗尽时冻结分数，所有连续包含查询串的名字同分，`prefix(500)` 保留的是并列里名序靠前的一段而非最相关的一段 | `79a6b3c`（`rankByRelevance` 相关性排序 + `FuzzyFilterResult.relevanceWeight` + 回归测试 `rowCapKeepsTheMostRelevantMatches`） |
| PR100.4 | Minor | `installRebuiltNodes(_:)` 丢弃过滤结果却不清 `isFiltering`，根侧栏永久卡在过滤模式：此后每次 `$nodes` 重建都在主线程全树展开，且展开自动保存整场会话失效 | `183c49e`（在 `filteredNodes` 赋值**之前**清标志 + 回归测试 `rebuildClearsTheFilteringFlag`） |
| PR100.9 | Minor | `.notLoaded` / `.loadError` 两个终态调失效钩子却从不赋值 `nodes`，于是钩子清空 Open Quickly 索引后立刻用**上一次加载**的 cell 重新播种；同一次调用还丢掉了仍然有效的 haystack 缓存 | `07deb0a`（两个出口一并清 `nodes`，保留代际递增） |
| PR100.11 | Minor | `.loadError` 分支零覆盖：测试 target 里没有任何抛错的 reload，删掉该调用点全套测试仍绿 | `07deb0a`（`FailableSeededListViewModel` 抛错子类；顺带把第 7 份私有 `makeLoadedImageNode` 拷贝收进 `TestSupport`） |

### 关于 PR100.2 的实验证据（翻案依据，务必保留）

`FuzzySearchable.fuzzyMatch` 的 `hasPrefix(_:atIndex:)` 的 receiver 是 **pattern**：
`patternIndex` 一走到末尾，`substring(from:)` 恒为空串、`hasPrefix` 恒 false，其后每个
字符都走 `else` 把 `currentScore` 清零。**分数在 pattern 消耗完的那一刻冻结**，与名字
本身、长度、匹配位置全部无关。

真实语料实测（`objc_copyClassNamesForImage` 取 AppKit 类表 2573 个，按名排序模拟
`openQuicklyRuntimeObjects`，移植完整 FuzzySearch + sorted + prefix(500) 管线）：

| 查询 | 命中 | 并列最高分 | 后果 |
|---|---|---|---|
| `view` | 713 | 639 | cap 砍掉 **139 个满分行** |
| `vi` | 1038 | 875 | **`NSView` 落在第 502 位，被砍掉** |

**措辞订正（复核推翻了发起会话的机制表述）**：当前 toolchain 上 `sorted(by:)` 实测表现
为稳定，并列行按输入名序输出。所以保留的 500 条**不是「introsort 任意落位」，而是并列
类里名序靠前的确定性前缀**。结论不变（名序 ≠ 相关性），但不要写成「任意 500 条」——
那是可被实验推翻的表述，会成为下一轮的翻案把柄。

## 翻案与订正（对前轮裁决的修改）

### PR88R4.7 —— 翻案，重新裁决为真问题

第四轮以「`fuzzyMatch` 确实 best-first（`UIFoundation/FuzzySearch.swift` 按 weight 降序），
丢的是低分尾巴而非任意 500 条」为由，把 500 行上限判为**重报 `PR88R2.11`** 并按
out-of-scope 出局。**该前提已被上面的实测证伪**：排序确实按 weight 降序，但 weight 是
退化的，丢的和留的同分。按「新证据推翻当初的理由 → 更新清单并重新裁决」，本条翻案，
以 `PR100.2` 重新登记并已修。

`PR88R2.11`（`1123875`，按 fuzzy 分数截断前 500 行）本身的裁决不变——它解决的是主线程
materialize 成本，那个目标达成了；它只是建立在一个关于评分语义的错误假设上。

### PR88R2.14 —— 结论存活，机制措辞订正

本轮曾提案把 `.specializationAdded` 的全量 flush 收窄到 `.fullReload`，理由是
「`_specialize` 只生成新 child 并广播，不动 parent 条目」。**该论据是事实性错误**：
`RuntimeSwiftSection.specialize(for:with:)` 的最后一行就是
`interfaceByObject.removeValue(forKey: object.key)`（`RuntimeSwiftSection.swift:720-723`），
注释原文 "Force the parent generic's interface to be re-rendered next time it is requested
so that any consumers iterating its `specializedChildren` pick up the newly registered child."
引擎**明文声明**了 specialization 要让 parent 接口失效。**翻案撤销。**

订正 `PR88R2.14` 的措辞：它写的「children 变化影响生成文本」在**今天的 per-type printer
层面不精确**——`SwiftDeclarationPrinter.printTypeDefinition`（:105-150）只走
`typeChildren`/`protocolChildren`，`specializedChildren` 是独立的 associated-object 清单，
只有模块级 `SwiftInterfaceBuilder`（:150-158）会走它。所以「收窄后 parent 文本立刻变陈旧」
今天大概率不会发生。**但结论不变**，三个理由：

1. 收窄直接对抗引擎在 `:720-723` 声明的失效契约；
2. upstream `DiffRendering.swift:44` 注释明写 "Latent today — the diff builder never walks
   `specializedChildren`"，printer 侧开始走它的那天，收窄就无声变错；
3. 收益近零（specialization 低频，容量才 16）。

若将来确实要动，正确形态是**按 parent key 定向失效**，不是丢掉该事件。

### 第三轮修复 commit 占位符回填

`PR88R3.1` = `91e2169`、`PR88R3.2` = `e23725f`、`PR88R3.3`/`3.4`/`3.5` = `37c7a47`。
（`PR88R4` 的「遗留观察」记过这三个占位符从未回填，本轮触碰该文件时补上。）

## 不可达 / 误报（留档防止第六轮重查）

### PR100.1 —— 在飞条目挂在重定向目标下（**不可达**，非「第三次复活」）

`entries[lookupKey] = .inFlight(task)` 里 `lookupKey` 可能是学到的重定向目标，而 `task`
抓的是**请求对象**；任何直接请求该目标的调用方 `join` 这个 task，理论上会拿到另一个类型的
接口。三条支撑事实都成立：`evictBeyondCapacity()`（:260-265）只删 `entries` 不动
`storageKeysByRequestKey`；`clearInFlight` 的注释（:224-232）已明写双 tab 收敛到同一存储键
这个交错；`:172` 的 "Resolution is deterministic for a given request" 与 `:100-103`
的注释存在张力。

**但 mis-serve 需要「重定向存活期间发生解析漂移」，而每个漂移源都被堵死**：

1. 跨镜像聚合解析是 **keep-first**：`RuntimeSwiftSectionFactory.registerCandidateIDs`
   （`RuntimeSwiftSection.swift:1447-1459`）写入前检查 `indexedTypeByCandidateID[id] == nil`，
   后索引的镜像不会顶掉已有 winner。后台索引虽然刻意不广播
   （`RuntimeEngine+BackgroundIndexing.swift`，注释明写 deliberate），但静默生长只能把
   「从未解析成功、因此从未学到重定向」的 token 变成可解析，**不能翻转已有解析**。
2. 「解析到自身」这一臂无法在不广播的情况下从 fail 翻成 succeed：
   `interfaceDefinitionNameByObject` 只在 section 初始索引（section 可被展示之前）和
   `specialize`（广播 `.specializationAdded`）时增长；两类翻转事件全部触发
   `invalidateAll()`，而它**连 `storageKeysByRequestKey` 一起清**
   （`RuntimeInterfaceCache.swift:244-251`）。重定向活不过任何一次解析重构。
3. `removeSection(for:)` / `removeAllSections()` 全仓**零调用**（`RuntimeSwiftSection.swift:1429,1441`
   与 `RuntimeObjCSection.swift:586,590` 只有定义），不存在「移除后由另一镜像重注册」的通道。
   注意：这两个移除接缝**存在但无调用方**，不要写成「字典是 append-only」。
4. ObjC 侧 class→image 归属是 runtime first-wins，已注册类不随后续加载改变。

所以 `:172` 的确定性断言在它唯一需要成立的作用域（单个缓存代内）**恰好成立**，与
`:100-103` 并非不能同真——`else` 分支防的是跨代/假想漂移，与 `PR88R4.3` 自己的裁决
（「可达性未构造出」）一致，属 defense-in-depth。`selfKeyedResolutionClearsStaleRedirect`
用可注入 fetcher 人工制造漂移，不构成生产可达性证据。

> **什么改动会让它变可达**（按 `PR88R3.9` 立下的规矩必须一并记）：任何让**单个缓存代内**
> 解析结果可变的改动——`registerCandidateIDs` 改成 last-wins、给 `removeSection` 加上调用方、
> 或引入一条不触发 `invalidateAll()` 的解析结构变更事件。
> **廉价加固**（不动挂载结构）：在 `case .inFlight` 的 `try await task.value` 之后校验
> `interface.object.key` 与查询键一致，不一致则改走自取。

### PR100.3 —— `scheduleReload` 的 catch 缺代际守卫（**误报**，论证已重写）

发起会话的场景「init 的 reload 与 `.fullReload` 广播竞争」不成立：`:136` 的
`guard self.currentReloadTask == nil else { return }` 正是防这个。

**但复核推翻了「无并发 reload 路径」这个外推**：`@Observed` 的 `projectedValue` 是
`BehaviorRelay`（`RxSwiftPlus/Observed.swift:7,22`），订阅即重放，所以
`SidebarRuntimeObjectBookmarkViewModel` **每次创建**都会在 init 里立刻触发第二次
`scheduleReload` 并取消第一次——supersession 是常态。发起会话还漏评了同一个 catch 里的
`loadState = .loadError`（书签 VM 被打中时是用户可见的错误页，不是无害）。

误报结论仍然成立，理由换成：输家要走进 generic catch 必须抛出非 `CancellationError`，而
书签 reload 的可抛点只有 `isImageLoaded` dispatch——本地引擎 `_isImageLoaded` 同步非抛出；
流被取消时 `AsyncThrowingStream.next()` 返回 nil 不抛，随后 `:386` 的 `checkCancellation`
抛的是 `CancellationError`（干净路径）；通信层不感知取消，所以取消本身不制造错误。

**裁决：本地引擎不可达故判误报；client（attached-process）引擎标「不确定/极窄」**——
需要连接故障 + 输家的错误比赢家的成功晚落地，双重故障窄窗，未能构造。catch 里补
`guard self.currentReloadGeneration == myGeneration else { return }` 是廉价加固，
但无构造出的复现，不排期。注意紧邻的 `currentReloadTask = nil` **是**有代际守卫的，
两行之间的不对称是加固的动机。

### PR100.5 —— 展开状态被写成 `[]`（**不可达-as-described**，latent 加固项）

机制成立：persist 守卫看 outline 的 `filteringState`（`StatefulOutlineView.swift:307-309`），
而 `persistentObjectForExpansion` 闭包看 VM 的 `isFiltering`
（`SidebarRootViewController.swift:129-133`）；两者失同步时逐项返回 nil，`:322` 无条件写 `[]`。

**但形成窗口合不上**：`endFiltering()` 进 `.pendingRestore` 时同步入队一个
`DispatchQueue.main.async` fallback（`:105-108`，下一个 runloop turn），而根侧栏的
`didBeginFiltering` 最早也要在非空 query 的 `.delay(.milliseconds(150))` 之后到达
（`SidebarRootViewModel.swift:224-229`），且 `isFiltering = true` 全文件只有 `:147`
一个写点、就在那条 delay 流里。即使主线程被长任务阻塞，fallback 块（入队于 endFiltering
时刻）也在定时器回调（≥150ms 后）之前，FIFO 保证它先跑、状态先回 `.idle`。发现原文
"Any user expand from there" 严重夸大了可达性。

**裁决：latent 加固项。** 加固正解是让 `beginFiltering()` 显式处理 `.pendingRestore`
（转 `.filtering` 并丢弃 pending restore），而不是依赖时序。

**注意不要加空值守卫**：`3a99ca68`（修 `PR88R2.1`）的 commit message 显式拒绝过它——
"The guard keys on the data changing, not on the walk coming back empty — collapsing every
row is a legitimate way to persist an empty set, and the third new test pins that."
该理由至今成立。真正该修的是标志失同步，即已修的 `PR100.4`。

## 重报已裁决条目（对照后跳过，不重走四问）

| 本轮发现 | 归入 | 说明 |
|---|---|---|
| `SidebarRootCellViewModel` 的 `lazy _children` 后台/主线程竞争 | `PR88R2.14` 复核段 | 已提级登记，「建议随 `PR88R2.15` 一并处理」 |
| 根过滤每趟重建全树聚合串 + 双 O(N) 主线程遍历 | `PR88R2.15` (a)(b) | **新增的半条**：搜索流缺 `distinctUntilChanged`。复核确认 `NSSearchField.rx.stringValue` 只能落到 RxAppKit `HasTargeAction+Rx.swift:30` 的 dynamicMember ControlProperty（target/action、无 dedup）——RxCocoa macOS 的具体成员是 `text` 而非 `stringValue`，RxAppKit 的 `NSTextField+Rx` 里 `stringValue` 的 controlProperty 是**被注释掉的**。与 `PR88.1` 的排查顺序结论不冲突：那条讲 `rx.state` 有 RxCocoa 兜底，这条没有 |
| `FilterContext.isCaseInsensitive` 等大小写默认值极性 | `PR88R3`「已被前两轮覆盖」段 | 已裁决「照 `PR88.8` 加注释即可，不必排期」。**新增的半条**：`SidebarRuntimeObjectListViewModel` 里 Open Quickly 硬编码的 `FilterContext(..., isCaseInsensitive: false, mode: .fuzzySearch)` 是第三个带旧极性的默认值；今天不活（`.fuzzySearch` 不读该标志），但一旦把 `appDefaults.filterMode` 接进 Open Quickly 就无声变成区分大小写 |
| 测试基建重复（`pollUntil` 7 份、`makeRuntimeObject` 多份、等价续体门三份） | `PR88R4`「遗留观察」 | 已归入 `PR88.12` / `PR88.13` 批次。本轮 `07deb0a` 顺带把新增的 `makeLoadedImageNode` 收进 `TestSupport` 而非再开第 7 份拷贝 |

## 暂不修（backlog，后续拾起）

| ID | 严重度 | 摘要 | 状态与理由 |
|---|---|---|---|
| PR100.7 | Minor | 两条过滤管线的取消检查覆盖不到最大的那个工作块：`stampMatches` 对整个顶层做**一次** `FilterEngine.match`，fuzzy 分支是 map+filter+sorted、零取消点 | **是对 `PR88R3.6` 的正当补充而非重报**：`PR88R3.6` 记的是根管线（forest 恒为 2），并明确写了「对象树顶层是数千个对象，那边的取消检查是有效的」。复核确认对象管线**确实**把整个顶层一次性喂给 `match`，所以那句只对 `verdictNode` 递归阶段成立。精确表述：**递归阶段可取消（子树粒度），顶层那一次 aggregate match 不可取消**——而对象管线的顶层 haystack 是名字+全部后代拼接，那次调用要重扫整棵树的文本，是单个最大的工作块。随 `PR88R2.15` 批次一并处理 |
| PR100.8 | Minor | `openQuicklyCellViewModelsByRowIndex` 只在 `invalidateNodeDerivedState` 清空，跨查询累积，上界是全行数——会话越长常驻内存越高 | cap 部分已由 `PR88R2.11` + `PR100.2` 覆盖；**暖缓存无上限**这半条未被记过。最简修法是面板关闭时清一次。随下一轮 Open Quickly 工作拾起 |
| PR100.14 | Minor | 提案 0005 在实现提交 `70733b9` 里首版即 `状态: Implemented`（跳过 `Accepted`）；`Documentations/Evolutions/` 与既有 `Documentations/Evolution/` 双目录并存，0005 指向 0004 的相对链接解析不到；两个目录都没有 README 状态总表 | 目录并存与死链靠 merge 时的 rename 检测自愈；**缺索引行与批准顺序违规不自愈**。补索引行随文档批次做；批准顺序无法回溯修复，记档即止。相关：`PR88.15` 记过文档落位，`PR88R4` 记过 0005 缺「与提案的差异」节 |

## 对本批次修复自身的复审（2026-08-16，落地后立即执行）

前四轮的教训是「修复未复审」这个流程缺口——`PR88R4` 的总体判断就是「真发现全部落在
为修上一轮发现而写的那两个提交里」。本批次落地后立刻自审，结果：

### PR100.16 —— 排序对 plain contains 会重排（**已修**，本批次自审发现）

`rankByRelevance` 是为携带 weight 与 ranges 的 fuzzy verdict 写的。plain contains
（`FilterMode` 为 `nil`）两者都没有：所有 verdict 权重 0、`matchesOwnName` 恒真、
`firstMatchLocation` 回落到名字自身长度，于是比较器一路穿到**名字长度**这个 tie-breaker
并重排——而 `FilterMatchVerdict` 的文档明写 plain contains「preserves input order」。

今天不可达（Open Quickly 硬编码 `.fuzzySearch`），但 `PR100.13` 已经点名「把
`appDefaults.filterMode` 接进 Open Quickly」是显而易见的下一步——那正好会踩上它。
修复：`2905c61`（按 mode 早退，保留输入顺序）。

**无回归测试**：触发它需要一个目前不存在的生产接缝，而 `PR88.14` 已在 backlog 上跟踪
「生产类型里的测试钩子」。此缺口与 `PR88R3.5` / `PR88R4.2` 同类，一并记在案。

### 已披露的行为变更：`PR100.4` 让 `endFiltering()` 在重建时首次可达

修好 `isFiltering` 之后，`didEndFiltering` 会真的触发 `endFiltering()`，于是重建后
`filteringState` 走 `.pendingRestore` → 下一次 `reloadData()` 执行
`restoreExpansionState()`。而该函数按 **`AnyHashable` 对象身份**匹配
`savedExpandedItems`，重建后每个 cell 都是新实例（`3a99ca68` 的 commit message 已记录
这一点），所以匹配不到任何一项 —— 净效果是
`collapseItem(nil, collapseChildren: true)` 之后不展开任何行。

**「过滤中途遇到镜像列表重建」这一场景下，树从「全展开」变成「全折叠」。**
判为可接受并有意保留：1.3 万节点全展开本就不可用，折叠是正常静息态；换来的是展开
自动保存不再整场会话失效。`savedSelectedItem` 同理失配，但重建后 cell 全新、选中态本来
就保不住。

根治要让 `restoreExpansionState()` 改用**路径持久化标识**而非对象身份——这正是
`PR88R3.10` 已经记过的「改用通知 `userInfo` 增量维护展开集合」那条，随 outline 那批工作
一并做，本批次不动。

### 修复批次的对抗复核（`RuntimeViewer-Fable`，2026-08-16）

七个攻击点里六点确认、一点修正。**判定：可合。**

**修正的那点——回归测试没钉住它要钉的键。** `rowCapKeepsTheMostRelevantMatches` 原本
只有「600 个 `Zx%04d` + 子节点 `Alpha`」和目标 `zzzAlpha`：目标的匹配位置是 3，填充项是
7（6 字符名 + 空格），所以**把 `matchesOwnName` 整个删掉，位置这一把 tie-breaker 单独
就能让两个断言全绿**——测试钉住的是「排序整体优于名序截断」，不是 own-name 那把钥匙。

（顺带否掉了发起会话自己担心的方向：填充名字符集 `{Z,x,0-9,空格}` 与 `alpha` 无交集，
每个 haystack 恰一段连续匹配，601 项全部同分 57，权重并列成立。）

修法是加一个 decoy：`displayName` 为 `"Zz"`、子节点 `"Alpha"`。它的匹配位置同样是 3、
名长 2 < 8，于是 weight / 位置 / 名长三把键要么并列要么对它有利，**只有 own-name 能把
两者分开**。已用变异测试证实：临时删掉 own-name 键后 `displayedNames.first` 变成 `"Zz"`、
测试变红；恢复后 107 全绿。

**确认的六点里值得留档的**：

- `parts` 确是 Character 偏移（`tokenize()` 是 `string.map`，`characterIndex` 来自
  `enumerated()`），与 `displayName.count` 同单位，`matchesOwnName` 的判据成立。pattern
  侧确有 Character/UTF-16 混用（`hasPrefix` 走 `NSString.substring(from:)`、`patternIndex`
  按 Character 累加），但那是上游既有行为、错乱的是评分而非 parts 的单位语义。
- **`PR100.4` 的「全折叠」不是本批次引入的**（复核比发起会话的自评更站得住）：修复前
  用户清搜索框时 `endFiltering()` 同样进 `.pendingRestore`，`restoreExpansionState()`
  按对象身份在全新 cell 里同样一项都配不上，同样 collapse-all。修复只是把这个**既有
  终态**从「清搜索时」提前到「重建时」。无双重 reload（adapter reload 先把状态收回
  `.idle`，fallback 的 guard 落空）；collapse 期间的 didCollapse 通知被 `.pendingRestore`
  挡在 persist 之外，不写盘；`restoreSelectedItem` 失配走 `row < 0` guard。加固方向是
  restore 改走 `itemForExpansionPersistentObject`（按持久化标识而非对象身份），
  与 `PR88R3.10` 同一批。
- **iOS 侧无雷**（发起会话未查，复核补齐）：UIKit 的 `SidebarRuntimeObjectViewController`
  用 `loadState.map { $0.index }` 驱动 `imageTabBarController.rx.selectedIndex`（:112），
  错误/未加载态整页切走，与 AppKit 同构；`isEmpty` 只控 searchBar 与 emptyLabel
  （:108-110），且都在被切走的页上。无按索引消费 `nodes` 的路径。

**复核提出但未采纳的一条**：建议 `.notLoaded` / `.loadError` 顺手也清 `filteredNodes`
（状态更齐）。今天被页切换完全遮住、无可达后果，属行为变更而非缺陷修复，留给作者决定，
本批次不动。

### 未修的小账（不单独开条目）

- `FilterEngine.match` 已按 weight 排过一次，`rankByRelevance` 再排一次，第一次排序现在
  是纯浪费。去掉它要改 `FilterEngine.match` 的返回顺序契约，而 `stampMatches` 依赖那个
  顺序决定侧栏树的过滤子节点次序，所以不在本批次动。开销在 off-main，不影响主线程。
- `.notLoaded` / `.loadError` 清空 `nodes` 后 `filteredNodes` 仍持有旧 cell，形成
  `nodes.isEmpty && !filteredNodes.isEmpty` 的新组合。已验为安全：VC 用 `loadState`
  切 tab，outline 在隐藏页里；在飞的过滤 pass 走
  `SidebarRuntimeObjectFilterPipeline.apply` 的 count 守卫返回 nil，不崩不误写。

## 复核推翻发起会话的三处（方法论留档）

1. **只看壳层不看实现体**：`PR88R2.14` 的翻案建立在只读了 `RuntimeEngine+GenericSpecialization.swift`
   这个 dispatch 壳层，没跟进 `swiftSection.specialize` 的实现体。壳层证据不能支撑实现体结论。
2. **把局部守卫外推成全局不变式**：`PR100.3` 由「广播入口有守卫」推出「无并发路径」，
   漏了 `BehaviorRelay` 订阅即重放这个最常见的隐式触发。结论侥幸对了，论证换个 VM 就翻车。
3. **把两个问题混成一个**：曾把 `PR100.9` 标注为依赖 `PR100.3`。实际上「catch 会不会被
   并发克隆污染」（`PR100.3`）与「catch 会不会执行」（`PR100.9` 的前提）是两件事——
   任何一次真实 reload 失败都会走进 catch，与并发无关。
4. **可被实验推翻的机制表述**：`PR100.2` 结论对，但「非稳定排序 → 任意 500」那步没有实测
   支撑，实测是稳定名序截断。对抗审查时这类表述会成为翻案把柄。

> 修复后回填：某条 backlog 被修掉时，按本目录惯例在行内登记修复 commit，不删行。

---
reviewed_file: Documentations/Evolutions/0058-runtime-engine-session.md
reviewed_at: 2026-10-21
reviewer_model: claude-opus-5-5
doc_type: evolution
extra_instructions: 第二轮。四位审查者并行（xhigh），分别侧重第一轮闭环核查、事件表与生命周期、落地步骤与测试计划、对抗式全新视角；本文件是四份报告去重合并的结果。第一轮报告见 2026-10-20-draft-runtime-engine-session-review.md
critical_count: 2
should_fix_count: 6
suggestion_count: 10
---

## 📄 文档信息

- **路径**: `Documentations/Evolutions/0058-runtime-engine-session.md`（审查时还是草案 `draft-runtime-engine-session.md`，第一轮修订稿，146 行）
- **类型**: evolution
- **文档行数**: 146
- **审查日期**: 2026-10-20（审查）/ 2026-10-21（合并）

四份报告合并而成。每条末尾的「审查者」注明哪几位独立报告了它：闭环 = 第一轮闭环核查，生命周期 = 事件表与生命周期，步骤 = 落地步骤与测试，对抗 = 对抗式全新视角。

**总体结论**：事件表与生命周期的核心设计经逐行核对成立。问题集中在四个落地步骤的边界上：照现在的写法，「每步结束时全绿」做不到，「第 1 步之后测试就是回归护栏」也不成立。另有一个更省改动的替代设计没有讨论过，需要用户拍板。

---

### 🔴 Critical (2)

**1.** [D 可行性] `line 48, 56–59, 61–76` — 第 2、3 步依赖第 4 步才出现的东西，「每步全绿」做不到
> - **第 3 步没人调 `documentDidOpen()`。** 第 3 步删掉了 `moveBackgroundWork`（line 70），而现在正是它在切换后给新 Engine 的工作调 `documentDidOpen()`（`DocumentState.swift:378–380`）。「工作创建时调 `documentDidOpen()`」要到第 4 步（line 75）才有。`RuntimeBackgroundIndexingAlwaysIndexEngineTests.engineSwapMatchesRowsAgainstNewEngine` 切到 `secondEngine` 后只读协调器、不调 `documentDidOpen()`，就等 libobjc 的 Always Index 批次（主线程已核对，`:149–151`），第 3 步结束时会超时变红。`RuntimeBackgroundIndexingSharedEngineTests.documentMovingAwayAndBackListsEachBatchOnce` 同理。App 里，切到新 Engine 后也不会开始索引。
> - **第 2 步的「当前工作」与 activity 无处可取。** 第 2 步还没有 session，`reportActivity`「转发当前工作的 `isWorkInProgress`」（line 59）只能经带副作用的 getter 去取，或者去读不可观察的私有 `backgroundWork`；读后者时，首个窗口的 Report 活动标记会一直不亮。activity 什么时候建也没写：在 work 的 `init` 里组合三个协调器，等于把第 4 步提前；惰性建、由 start 去碰，则切到新 Engine 后没人碰，新 Engine 失去 App Nap 保护，正是 `ResolvedIssues/2026-10-13` 修过的问题，而 line 89 的两条 App Nap 用例都不切换 Engine，抓不到。
> 建议: 重排步骤：先让协调器随工作一并创建，再挪 activity，最后引入 session。若某步仍缺前置条件，写明过渡做法，即加入一份工作时由谁建三个协调器、由谁调 `documentDidOpen()`。
> 审查者：闭环、生命周期、步骤、对抗

**2.** [F 可测试性] `line 52–54, 102` — 第 1 步的「回归护栏」抓不住漏迁的套件，名单也不全
> line 52 写测试扩展「这一步里它读旧 getter」，line 54 写「此后它们就是回归护栏」。可旧 getter 读一下就会加入工作（`DocumentState.swift:276–282`、`:310–317`），`ReportViewModel` 自己也在 `$runtimeEngine.map` 里读 getter（`ReportViewModel.swift:106–113`）。所以漏调 `startBackgroundWork()` 的用例在第 1 步照样是绿的，要到第 3 步才红。
> line 53 的名单还漏了 5 个经文档 getter 取协调器的套件（共 6 处）：`FindCorpusCoordinatorTests.swift:59–60, 232`、`FindCorpusCoordinatorOlderPeerTests.swift:35, 60`、`FindCorpusCoordinatorRemoteTests.swift:77`、`FindGenerationOptionsTests.swift:26`、`DocumentStateLifecycleTests.swift:36`。它们需要 FindSession 跟着协调器，或者要验证切换 Engine 后协调器换了，没法照 line 102 改成 `init(engine:)` 直接构造。
> 建议: 第 1 步就让启动成为唯一的加入路径，让漏调启动的用例在第 1 步就变红，例如让 getter 不再加入工作、只读已加入的那份，或让测试扩展只读已加入的工作；名单写出具体套件名，并补上这 5 个。
> 审查者：闭环、步骤、对抗（生命周期报了名单部分）

---

### 🟡 Should Fix (6)

**1.** [E 范围] `line 16, 44, 62–63, 137–138` — 更省改动的「两个独立值」方案没有讨论
> 替代做法：`@RxObserved runtimeEngine` 原样保留，另加一个 internal 的 `@RxObserved fileprivate(set) var backgroundWork: RuntimeEngineBackgroundWork?`，每个消费者只跟随其中一个。需要协调器的（Report、FindSession、FindScopeChooser、侧栏 image）跟 `$backgroundWork`，其余 5 个只要 Engine 的跟随者一行不改；工作本身带着 Engine（`RuntimeEngineBackgroundWork.swift:23` `let engine`）。这样同样解决三个问题，还能省掉一个新的公开类型、App target 里的改动、启动时多发的一次事件，以及与「engine session」注释撞名的问题。line 137 否决推导方案的理由「需要对齐的第二个值」，对它是否成立，需要论证。
> 建议: 在决策日志里回应：哪个现有或将来的消费者必须同时拿到 Engine 和工作。
> 审查者：对抗

**2.** [B 一致性] `line 51, 102` — 语料构建从第 1 步就开始拖慢测试，关语料的措施却写在第 4 步
> 第 1 步 `startBackgroundWork()` 的函数体就含 `_ = documentState.findCorpusCoordinator`（`Document.swift:28`），`FindCorpusCoordinator.init` 会立即请求构建（`FindCorpusCoordinator.swift:222–229`、`:639`），而 `isCorpusEnabled` 默认开着（`Settings+Search.swift:18–19`）。`RuntimeBackgroundIndexing*Tests` 和 `ReportSharedByEngineTests.swift:198` 以前只建索引协调器，从第 1 步起就会为 Foundation 等 image 建语料、和索引争资源；`removingEngineStopsFutureDispatchesOnly` 还靠「Foundation 索引要好几秒」来卡时序。
> 建议: 第 1 步就在 `ViewModelTestEnvironment` 里默认关掉 `isCorpusEnabled`，做法与 `:31` 关交叉引用预建相同。多数语料套件已经显式打开它，只有少数（例如 `FindScopeChooserViewModelTests`、`ReportViewModelTests` 里的 5 个用例）依赖默认值，需要逐个核对。
> 审查者：闭环、生命周期、步骤、对抗

**3.** [F 可测试性] `line 84–100` — 有三项变异在包级测试里观察不到，「切换后」用例也写不严
> - **变异 3（同 Engine 重置时不重新赋值）**：用 `stop()` / `connect()` 驱动重置时，进程内 Engine 重连会 `broadcast(.fullReload)`，`RuntimeInterfaceCache` 也订阅着 `dataChangePublisher`（`:127–133`），不重新赋值缓存照样会被清。应先 `.switchImage`，再直接 `trigger(.switchEngine(同一个 Engine))`，用带计数 fetcher 的 `RuntimeInterfaceCache(documentState:fetcher:)` 断言重新取数。
> - **变异 4（`leave()` 不清侧栏 image）**：登记表 `onScreenImagePathsByDocument` 是 private（`FindCorpusCoordinator.swift:88`），「优先」只体现为发给 Engine 的 `isPrioritized`，测试目录里没有任何用例钉过它。需要给 `FindCorpusCoordinator` 加一个 internal 测试缝。
> - **变异 8（创建工作时不调 `documentDidOpen()`）**：测试里 14 处显式调用会把它补回来；「设置先关后开」也抓不到，因为 `handleSettingsChange` 不检查 `hasStarted`（`RuntimeBackgroundIndexingCoordinator.swift:646–656`）。迁移时应删掉这 14 处，另加一条用例：开着索引、只调 start，就应出现批次。
> - **「切换后」用例**：必须在切换前就订阅、记录每次发出的值，断言切换后**第一个**值就带着工作且只发一次。只看最终值的话，抓不到变异 2（先赋一个未加入的 session，再加入）。
> 审查者：步骤、对抗

**4.** [F 可测试性] `line 52–54, 68` — 第 3 步起，测试里的 FindSession 会在 `environment.make {}` 外首次创建
> 现在启动会顺带建出 FindSession（`findCorpusCoordinator` → `followInterfaceCorpus` → `findSession.follow`，`DocumentState.swift:349`），所以 `FindSessionCorpusTests.swift:19` 在 `make` 里就建好了它。第 3 步起，FindSession 自己跟随 session，启动不再建它，`FindSessionCorpusTests.swift:23/61/94/123/187/228`、`FindCorpusCoordinatorTests.swift:75, 239`、`FindCorpusCoordinatorRemoteTests.swift:85` 都会变成在 `make` 外首次创建。这时 `@Dependency(\.appDefaults)` 取到的是进程共享的 `AppDefaults.testFallback`，`\.settings` 没有测试值，而 `FindSessionLifecycleTests.swift:22–23` 的注释写明它必须在 `make` 里建。
> 建议: 第 3 步写明把这些首次读取改成 `environment.make { documentState.findSession }`。
> 审查者：生命周期

**5.** [C 歧义] `line 44, 51, 59` — 第 1、2 步里 `startBackgroundWork()` 放在哪一句没定
> line 44 的「正确性不依赖顺序」要等第 3 步有了 session 才成立。在第 1、2 步，如果启动仍在 `addWindowController` 之后，Report 页签在 `addWindowController` 内部就订阅了活动标记（`SidebarRootCoordinator.swift:40` → `TabViewController.swift:279`），首个窗口的标记会一直不亮，而包级测试覆盖不到 `TabViewController`。
> 建议: 第 1 步就把启动挪到第一句。旧实现下 `.main(.local)` 会在 `DocumentState.swift:497` 早退，这样挪是安全的。
> 审查者：生命周期、步骤

**6.** [B 一致性] `line 52, 70` — 「测试正文不动」与删测试缝互相矛盾，扩展的签名也撑不住
> line 70 要删 `hasCreatedFindCorpusCoordinator`，所以 `DocumentStateLifecycleTests.swift:26` 必须改；第 2 步删掉 `backgroundWorkProcessActivity` 与 `processActivityScheduler` 后，`DocumentStateLifecycleTests.swift:27` 和 `BackgroundWorkProcessActivityTests.swift:94, 98, 104, 108` 也得改。第 3 步后 `backgroundWork` 是可选的，扩展要保持非可选签名就只能强制解包，而所有套件跑在同一进程里，漏调启动会让整个进程崩溃，不只是一条用例失败。
> 建议: 写明每一步要改哪几处测试正文；扩展在第 1 步就定为 `throws`（用 `try #require`），之后签名不再变。
> 审查者：闭环、步骤

---

### 🔵 Suggestion (10)

**1.** [G 代码一致性] `line 59, 70` — 测试缝 `hasCreatedBackgroundWorkProcessActivity`（`DocumentState.swift:419–421`，`DocumentStateLifecycleTests.swift:27` 在用）在删除清单和保留清单里都没有。审查者：闭环、生命周期、对抗

**2.** [G 代码一致性] `line 63` — `reportActivity` 自己也订阅 `$runtimeEngine`（`DocumentState.swift:450`），是第 7 个跟随者，宜一并写明。审查者：步骤

**3.** [F 可测试性] `line 48` — 每步的完成标准只有包测试全绿，可第 1 步改了 `Document.swift`，第 3 步改了 `MainViewModel.swift`，宜加一条「App target 编译通过」。审查者：闭环

**4.** [B 一致性] `line 16, 28, 44` — 「任何变化都换一个新 session」和事件表里同 Engine 重置（原 session 再赋值）、关闭（只 `leave()`）对不上；「启动发出的那次事件没有订阅者」也不准确，`DocumentState.init` 里的 `combineLatest` 已经订阅了（结论不受影响）。宜照事件表收窄措辞。审查者：闭环、生命周期

**5.** [C 歧义] `line 63, 67` — 没写 session 没有工作时 Report 树显示什么：空树，还是只有「已关闭」这类行。审查者：闭环

**6.** [C 歧义] `line 111` — `RuntimeBackgroundIndexingCoordinator.swift` 里的私有计数器 `session`（`:40`）和 `isCurrent(_ session:)`（`:201`）也是「进程的一段生命周期」这个含义，同样撞名，宜一并处理。审查者：对抗

**7.** [C 歧义] `line 124` — Xcode 的 App Nap token「只在打开期间持有」容易读成文档打开的整段时间；逆向记录写的是加载完成（finishedLoading）就结束。审查者：对抗

**8.** [F 可测试性] `line 37, 129` — 在工具栏的来源弹出按钮里重选当前来源，会走 `.main(engine)`（`MainViewModel.swift:368–375`），先清空 `routeDisposeBag` 再触发同 Engine 的 `.switchEngine`，不撞断言。所以同 Engine 重置现在就能在 App 里验证，不必等那个既有缺陷修好。审查者：生命周期

**9.** [C 歧义] `line 53, 66` — 通配符 `RuntimeBackgroundIndexing*Tests` 也匹配到不经 `DocumentState` 的 `RuntimeBackgroundIndexingStagingTests`，宜写出具体套件名；`FindScopeChooserViewModel` 的路径规范化改用 `runtimeEngine.canonicalImagePath` 行为不变，可以提前到第 1 步。审查者：步骤

**10.** [H 结构] `line 111` — `RuntimeBackgroundIndexingCoordinator.swift` 的注释改动挂在「`Documentations/Glossary.md`」条目下，宜单独列为代码注释的改动。审查者：闭环

---

### 🔁 第一轮闭环

第一轮的 22 条里，18 条已解决，4 条部分解决：

| 第一轮编号 | 结论 | 说明 |
|---|---|---|
| 🔴1、🟡1–4、🟡9–12、🔵1–9 | 已解决 | 闭环审查者逐条对照代码核实，证据见其原报告 |
| 🟡5（验收与回归护栏） | 部分解决 | 变异清单已有，但第 1 步的护栏不成立 → 本轮 🔴2、🟡3 |
| 🟡6（分步落地） | 部分解决 | 已分四步，但步骤边界不成立 → 本轮 🔴1 |
| 🟡7（测试变慢） | 部分解决 | 对象已改成语料构建，但时点写成第 4 步 → 本轮 🟡2 |
| 🟡8（「直接构造协调器」歧义） | 部分解决 | 已给出归类规则，但还有 5 个套件没归类 → 本轮 🔴2 |

---

### ✅ Strength (3)

- **事件表经逐行核对成立。** 先启动、再 `addWindowController` 时，`.main(.local)` 切的是同一个 `RuntimeEngine.local` 对象，在 `DocumentState.swift:497` 早退，不会冲掉刚启动的 session。同 Engine 重置时各跟随者的反应与今天对同一 Engine 再赋值完全相同，`FindSession.swift:277` 不会断开重连，也不会丢掉进行中的搜索。关闭之后，没有路径能去取消别的窗口还在跑的工作：Cancel 只来自 Report 页，MCP 和 CLI 都不触发路由。
- **修订稿新出现的代码引用全部属实，第一轮的核心问题也已闭环。** RxSwiftPlus 0.2.5（64a9b8c4）的 setter 无条件 `accept`，`FindCorpusCoordinator.canonicalImagePath` 只是转发，`MainCoordinator.swift:184–190` 与提交 3d2ae6dc 都核实无误。
- **外部路径不受影响。** MCP 桥只读 `documentState.runtimeEngine`（`AppMCPBridgeDocumentProvider.swift:37`）；CLI host、`RuntimeEngineManager`、attach 与注入流程都不碰 `DocumentState` 和 registry；全工程只有 `MainViewModel.swift:374` 会发出别的 `.main(engine)`。

---

### 📊 摘要

| 严重程度 | 数量 |
|---------|------|
| 🔴 Critical | 2 |
| 🟡 Should Fix | 6 |
| 🔵 Suggestion | 10 |
| ✅ Strength | 3 |

**维度分布**:
- A 完整性: 0    B 一致性: 3    C 歧义: 5    D 可行性: 1
- E Scope: 1    F 验收: 5    G 代码一致性: 2    H 结构: 1

---

### 已淘汰候选 (Dropped Candidates)

- [D 可行性] 切换时 `combineLatest` 先把旧 image 写到新 Engine 的协调器上 — 淘汰原因：`setOnScreenImagePath` 只写字典，读它的 `imageDidIndex` 要跳到下一个主线程回合，而同一路由里随后的 `currentImageNode = nil` 已经清掉了它（三位审查者独立得出）。
- [D 可行性] 关闭后迟到的读者执行 Cancel All，误伤别的窗口 — 淘汰原因：取消命令只来自 Report 页的输入，关窗之后不会执行。
- [D 可行性] `combineLatest` 或 FindSession 的 `init` 订阅造成循环引用 — 淘汰原因：现有 `FindSessionLifecycleTests` 断言 `DocumentState` 会被释放，强引用会让它变红；项目规则本来就要求 `[weak self]`。
- [D 可行性] MCP、CLI、attach 或窗口恢复会改变文档所在的 Engine — 淘汰原因：全工程只有 `MainViewModel.swift:374` 发出别的 `.main(engine)`，其余路径都不碰 `DocumentState`。
- [D 可行性] registry 的 `init` 是 `fileprivate`，测试注入不了 scheduler — 淘汰原因：测试可以经 `@Dependency` 拿到每个用例一份的 registry，直接改它。
- [D 可行性] App target 在非隔离闭包里读 `@MainActor` 的 `session.engine`，编译不过 — 淘汰原因：App target 是 `SWIFT_VERSION = 5.0`，不是硬错误。
- [D 可行性] 改为在 `DocumentState.init` 里直接启动 — 淘汰原因：`ViewModelTestEnvironment` 在 `make {}` 之外建 `DocumentState`，协调器的 `@Dependency(\.settings)` 会拿不到测试设置。
- [D 可行性] 测试里调启动会在 Engine 上派发后台索引、互相干扰 — 淘汰原因：`indexing.isEnabled` 默认关着（`Settings+Types.swift:150`）。
- [A/H] 缺完整模板的章节；没有验收标准 — 淘汰原因：精简提案只要求三节，测试与变异检查一节在 line 80–100。

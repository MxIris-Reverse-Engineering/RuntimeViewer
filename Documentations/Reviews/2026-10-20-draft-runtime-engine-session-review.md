---
reviewed_file: Documentations/Evolutions/draft-runtime-engine-session.md
reviewed_at: 2026-10-20
reviewer_model: claude-opus-5-5
doc_type: evolution
extra_instructions: 架构改动，影响面大，要查漏补缺。四位审查者并行（xhigh），分别侧重生命周期与时序、消费者迁移与代码引用、Engine 级对象的改动、可测试性与范围与依据；本文件是四份报告去重合并的结果
critical_count: 1
should_fix_count: 12
suggestion_count: 9
---

## 📄 文档信息

- **路径**: `Documentations/Evolutions/draft-runtime-engine-session.md`
- **类型**: evolution
- **文档行数**: 83
- **审查日期**: 2026-10-20

四份报告合并而成。每条末尾的「审查者」注明哪几位独立报告了它：时序 = 生命周期与时序，迁移 = 消费者迁移，Engine = Engine 级改动，验收 = 可测试性、范围与依据。

---

### 🔴 Critical (1)

**1.** [D 可行性] `line 21–22, 28, 32, 37` — 订阅者早于 `startBackgroundWork()` 存在，工作怎么交到它们手上没写
> `Document.swift:20` 先 `addWindowController(mainCoordinator.windowController)`：`MainCoordinator.init` 以 `initialRoute: .main(.local)` 同步跑完 `prepareTransition`。这一步里已经建好：`ReportViewModel` 并调了 `transform`（`ReportViewController.swift:230`）；`FindViewModel`，它又建出 `FindSession`；以及订阅了 `reportActivity` 的 Report 页签（`SidebarRootCoordinator.swift:40`）。之后第 23 行起才是启动语句。这些订阅者第一次看到的 session，`backgroundWork` 都是 `nil`。
> 提案没写 `startBackgroundWork()` 是重新赋值 session，还是原地改字段；也没定 `RuntimeEngineSession` 是 class 还是 struct（line 15「合成一个值」，line 22 又给它 `leave()`）。
> - 原地改、且它是 class：`@RxObserved` 什么都不发，首个窗口的 Report 一直是空的，标签上的活动标记不亮，FindSession 跟不上语料。
> - 重新赋值：6 个跟随者都会收到一次 Engine 并没变的事件。
> - line 32「把 `backgroundWork` 置为 `nil`」同样二义：是 struct 就会在关窗时发事件，是 class 就不发。
> - 若改成要求「start 必须在第一次绑定之前调」，又是一条新的时序约束，与 line 62、81「时序约束从结构上消失」矛盾。
> 建议: 定为不可变的 `@MainActor final class`，每次状态变化都换一个新实例；写明 start、切换、同 Engine 重置、关闭四处各发不发事件；补一条测试：「先绑定 Report 与 Find，再 start，仍能拿到这个 Engine 的协调器」。
> 审查者：时序、迁移、Engine、验收

---

### 🟡 Should Fix (12)

**1.** [G 代码一致性] `line 27, 29` — 被删的 getter 还有三处直接读者没列进迁移
> - `SidebarRootViewModel.swift:227`：`documentState.backgroundIndexingCoordinator.prioritize(imagePath:)`
> - `FindScopeChooserViewModel.swift:96, 107`：`init` 里以非可选方式调 `corpusCoordinator.canonicalImagePath`，`transform` 里订阅 `$buildStatesByImagePath`
> - `ReportViewModel.swift:197–226`：Cancel、Cancel All、Clear History 共 9 处读取，不走 `:106` 那条跟随链
>
> `backgroundWork` 变成可选后，这些地方遇到 `nil` 怎么办都没写。`FindScopeChooserViewModelTests` 靠 getter 的惰性加入才能工作，却不在「约 12 个套件」里。
> 建议: 逐个写进方案并定 `nil` 时的行为；路径规范化退回到 `runtimeEngine.canonicalImagePath`。
> 审查者：时序、迁移、Engine、验收

**2.** [D 可行性] `line 22, 31–32` — 离开旧 Engine 时没清掉本文档登记的侧栏 image
> 现在的 `leaveBackgroundWork`（`DocumentState.swift:355–360`）离开前会先调 `corpusCoordinator.setOnScreenImagePath(nil, ofDocument:)`。新方案的 `leave()` 只写了「离开」，line 31 的 `combineLatest` 也只写当前 session 的协调器。
> 失败场景：窗口 A、B 都在 My Mac 上，A 正在看 image P，然后切到别的 Engine 或关掉。My Mac 的 `onScreenImagePathsByDocument` 里会一直留着 A→P，`imageDidIndex`（`FindCorpusCoordinator.swift:659–665`）照样把 P 的语料排到队首，可已经没有侧栏在显示它。这与 line 15「用户看到的行为不变」不符。
> 建议: 写明 `leave()` 先清掉本文档登记的路径，再离开 registry。
> 审查者：时序、迁移、Engine、验收

**3.** [G 代码一致性] `line 19–28` — `private(set)` 编译不过，公开面也没定
> line 26 写的是 `@RxObserved public private(set) var runtimeEngineSession`，可赋值的是同一文件里另一个类型 `SelectionRouter`（`DocumentState.swift:467`、`:504`）。现有的 `runtimeEngine` 正因为这一点才声明成 `fileprivate(set)`。
> 公开面方面：App target 只需要 `$runtimeEngineSession` 加 `.engine`（`MainViewModel.swift:412`、`:511`）、`startBackgroundWork()`、`reportActivity` 和 `documentWillClose()`。如果把 `backgroundWork` 也公开，`RuntimeEngineBackgroundWork` 就得跟着公开，推翻 0055「都只在模块内可见」的决定；`leave()` 若公开，App 代码就能打乱成员计数。
> 建议: 改为 `fileprivate(set)`；`RuntimeEngineSession` 只公开 `engine`，其余保持 internal；写明 `startBackgroundWork()` 为 public。
> 审查者：时序、迁移、Engine、验收

**4.** [F 可测试性] `line 29, 42, 54–62` — App Nap 的测试缝删了没处注入，也缺用例
> `BackgroundWorkProcessActivityTests.swift:94` 用 `documentState.processActivityScheduler = scheduler` 注入替身，钉住 `ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md` 记录的修复。line 29 删掉了这个测试缝；新的 activity 在 `registry.join` 内部创建（`RuntimeEngineBackgroundWork.swift:117`），从哪里注入没写。
> 改成每个 Engine 一份以后，现有的 `closingEndsTheActivity` 应改为：同一 Engine 上开两个文档、关掉一个，activity 仍然持有；最后一个离开才结束。这一条没列进测试清单。
> 建议: 写明 scheduler 的注入位置（例如 registry 的依赖），并补上这条用例。
> 审查者：时序、迁移、Engine、验收

**5.** [F 可测试性] `line 54–62` — 「结构保证」那条测试是同义反复，现有黑盒套件也当不了护栏
> 新结构里协调器直接从收到的 session 上取，line 62 那条测试几乎必然成立；只有同时断言 `backgroundWork != nil`、并在 start 之前就订阅，它才可能变红。0055 用 7 项变异检查证明过同类结论，本提案一项都没有。
> 另外，`ReportViewModelTests`（17 个用例）和 `ReportSharedByEngineTests` 都在没有启动过的文档上建页面，靠的就是 getter 的惰性加入，所以这些黑盒套件也必须随代码一起改。结果是没有一个原封不动的套件能证明「行为不变」。
> 建议: 列出变异清单，各自要让一条测试变红：start 不发事件；切换时先赋一个没有工作的 session；同 Engine 重置时不重新赋值；`leave()` 不清侧栏路径；任一文档离开就结束 activity；FindSession 不跟随新 Engine。再加一个第 0 步：先在旧实现上把那几句包成 `startBackgroundWork()`，把测试迁移到调用 start 并跑到全绿，之后换实现时测试一行不动。
> 审查者：验收

**6.** [E 范围] `## 方案` — 四件可独立落地的改动挤成一批，没有落地顺序
> 以下几件各自能编译、能通过测试：
> 1. `startBackgroundWork()` 包装，加上测试迁移；
> 2. `isWorkInProgress` 与 App Nap activity 挪到每个 Engine 一份（与时序问题无关）；
> 3. session、一次赋值、删 getter；
> 4. 协调器随工作一并创建。
>
> activity 那一项改的是一个有专门 ResolvedIssue、有变异验证的行为，和 `DocumentState` 重建混在一起，出了回归很难二分定位。
> 建议: 不另起提案，补一节落地顺序，每步单独 commit，并注明当步必须保持全绿的套件。
> 审查者：Engine、验收

**7.** [D 可行性] `line 68–69` — 「测试变慢」的风险找错了对象，退路自相矛盾
> 交叉引用预建在测试里本来就关着（`ViewModelTestEnvironment.swift:31`）。真正会多出来的是语料构建：`isCorpusEnabled` 默认开着，`FindCorpusCoordinator.init` 会立即请求构建已索引的 image，Foundation 的语料要好几秒。
> line 69 的退路是「在 `RuntimeEngineBackgroundWork` 内保留惰性创建」，可 line 44 又把 `documentDidOpen()` 并进了创建过程。两者合起来，读一次 `work.indexingCoordinator` 就会派发开机批次，正好把 line 11 要消除的「带副作用的 getter」放回了下一层。
> 建议: 风险改写成语料构建，在相关套件里显式关掉 `isCorpusEnabled`，删掉这条退路。
> 审查者：Engine

**8.** [C 歧义] `line 68` — 「直接构造对应的协调器」至少有三种理解
> - 直接 `FindCorpusCoordinator(engine:)`：可 FindSession 只跟随 session，看不到它；而 `FindSessionCorpusTests` 的 6 处都要 FindSession 跟着它搜索。
> - 只带一种协调器构造 `RuntimeEngineBackgroundWork`：这和 line 44 冲突，而且它的 `init` 是 `fileprivate`。
> - 测试手动调 `follow(_:)`：会和 FindSession 自己的跟随打架。
>
> 建议: 写明测试走哪条路，并点名 `FindSessionCorpusTests`、`RuntimeBackgroundIndexingAlwaysIndexEngineTests` 各归哪一类。
> 审查者：验收

**9.** [B 一致性] `line 28` — 「与现在的保证一致」不符合现状
> 对测试里的文档而言，现在的保证是「第一次读取就加入」：`ReportViewModel.swift:106–113` 在 `$runtimeEngine.map` 里读 getter，这一读就加入了工作；`ReportViewModelTests.finishedWorkUnderItsKind` 没调启动，照样期望出现语料行。新设计对这类文档是行为改变，应按改动来写。iOS 不受影响：它给 `selectedNode` 传的是 `.never()`（`SidebarRootViewController.swift:68`），从不读这些 getter。
> 审查者：验收（iOS 部分由迁移核实）

**10.** [B 一致性] `line 48–52, 80–82` — 对 Xcode 的引用比逆向结论走得远
> - 逆向记录里，工作区观察 `runContextManager.activeRunContext`，合并到下一轮 runloop 后拆掉旧索引、`setIndex:nil` 再重建。也就是说，Xcode 换服务是靠观察推导的，消费者在事件到达那一刻重读当前服务（`IDEIndexerActivityReporter` 比较 `notification.object == workspace.index`）。这恰恰接近 line 80 以「Xcode 都是显式的」为由否掉的那个方案。显式的只是共享对象的计数与失效树。
> - line 51「显式 register / unregister」：记录写的是「注销不停止，停止发生在失效时」，撑不起「最后一个离开就关闭」的类比。
> - line 82：Xcode 的 App Nap token 挂在 `IDEWorkspaceDocument` 上，只在打开期间持有，不能拿来支持「每个 Engine 一份」。
> - line 48：`DVTInvalidation` 出自 27.0 的 DVTFoundation，不是 27.2 的 IDEKit / IDEFoundation。
>
> 建议: 把这段降为「部分借鉴」；line 80 的否决只保留「推导出的工作仍是和 Engine 并列、要对齐的第二个值」这一条理由。
> 审查者：验收

**11.** [A 完整性] `line 64` — 同批要更新的文档漏了两处
> - `Documentations/CommunicationAndEngineArchitecture.md:333`：「由 `BackgroundWorkProcessActivity` 负责（`DocumentState.reportActivity` 为真时持有一个 user-initiated activity）」。
> - `Documentations/Glossary.md:34` 已有的「Engine 的后台工作」词条：写的是「两件事…第一个文档用到时建立」，改动后应是三件事、由显式启动建立，还要持有 App Nap activity。提案对术语表只写了「新增 `RuntimeEngineSession`」。
> 审查者：时序、迁移、Engine、验收

**12.** [D 可行性] `line 37` — 同一 Engine 重置所走的 `.switchEngine` 路径会撞上断言（既有缺陷）
> 有内容打开时，`handleReadinessChange` 直接 `selectionRouter.trigger(.switchEngine(engine))`（`DocumentState.swift:99`），不经过 `.main`。这时 `MainCoordinator` 对 `routeSignal` 的订阅还在，`fanOut` 的 `case .switchEngine` 会调用 `assertionFailure(".switchEngine fired with an active route subscriber; …")`（`MainCoordinator.swift:184–190`）。
> 后果：Debug 构建里，有内容打开时 XPC service 一重启，App 就崩；Release 构建里，侧栏和内容区不复位，`DocumentState` 却已经清空。这条路径来自 3d2ae6dc（2026-09-21，提案 0037）。line 37 的设计正依赖它，而 line 60 的包级测试没有 `MainCoordinator`，抓不到。主线程已核对代码，确认属实。
> 建议: 在「不在本提案内」登记并另行修复，或者同批修掉。
> 审查者：时序

---

### 🔵 Suggestion (9)

**1.** [G 代码一致性] `line 11, 28` — 「四句 `_ =`」实为三句 `_ =`（`Document.swift:28/31/35`）加一句 `documentState.backgroundIndexingCoordinator.documentDidOpen()`（`:23`）。四位审查者都报了。

**2.** [B 一致性] `line 26` — 「49 个调用点不变」里含要改的 6 个跟随者和 router 的读写；真正不变的读取是源码 39 处、测试 27 处。

**3.** [C 歧义] `line 19` — `RuntimeBackgroundIndexingCoordinator.swift:69, 98, 105` 的注释里，「engine session」指 Engine 背后进程的一段生命周期，进程重启就重置；而 `RuntimeEngineSession` 在同 Engine 重置时保留，同一个词两种相反的含义。改那几处注释的措辞，或在术语表里写清。

**4.** [C 歧义] `line 28, 61` — 没写重复调用 start、或关闭后再调 start 会怎样，会不会重复订阅 line 31 的 `combineLatest`。

**5.** [C 歧义] `line 37, 60` — 「同一 Engine 的重置」没区分「什么都没打开」的分支。那条分支只发 `runtimeEngineDidReset`（`DocumentState.swift:96–97`），不重新赋值 session，也不清 interface 缓存。

**6.** [F 可测试性] `line 44, 54–62` — `DocumentState.swift:270–274` 要求打开时开关关着也要留着协调器，以响应设置从关到开；把 `documentDidOpen()` 并入创建，改动的正是这条路径，但目前没有任何测试钉住它。

**7.** [C 歧义] `line 29, 44` — 几个成员改完后的去留没交代：`hasCreatedFindCorpusCoordinator`（`DocumentStateLifecycleTests.swift:26` 在用）、`hasCreatedFindSession`、`isClosed`、`backgroundWorkMember`，以及 public 的 `documentDidOpen()`（测试里直接调了 14 次）。

**8.** [D 可行性] `line 46` — `FindSession.follow(_:)` 的参数不是可选类型（`FindSession.swift:276`），session 的 `backgroundWork` 为 `nil` 时 FindSession 怎么办没写。

**9.** [H 结构] `line 54–70` — 测试和假设都在「方案」一节里，补上落地顺序（🟡6）后，可以按步骤重排。

---

### ✅ Strength (3)

- 数字与名字核实无误：`DocumentState.swift` 738 行，后台工作一块在第 232–464 行；`$runtimeEngine` 的外部跟随者正好 6 处；直接用到这些 API 的测试正好 12 个文件；要删的成员都存在。
- 核心前提成立：RxSwiftPlus 0.2.5（64a9b8c4，与两份锁文件一致）的 `@RxObserved` setter 无条件调用 `relay?.accept(newValue)`，`RuntimeInterfaceCache` 只用 `skip(1)`、不去重，所以「同一引用再赋值一次就会发事件」成立。
- 决策日志写清了被否掉的方案及理由，没有照录用户原话；导航那三点明确划在本提案之外。

---

### 📊 摘要

| 严重程度 | 数量 |
|---------|------|
| 🔴 Critical | 1 |
| 🟡 Should Fix | 12 |
| 🔵 Suggestion | 9 |
| ✅ Strength | 3 |

**维度分布**:
- A 完整性: 1    B 一致性: 4    C 歧义: 5    D 可行性: 5
- E Scope: 1    F 验收: 3    G 代码一致性: 3    H 结构: 1

---

### 已淘汰候选 (Dropped Candidates)

- [B 一致性] iOS 点选 image 时会读 `backgroundIndexingCoordinator`，所以现在 iOS 也会加入 registry（Engine 报告）— 淘汰原因：`RuntimeViewerUsingUIKit/.../SidebarRootViewController.swift:68` 给 `selectedNode` 传的是 `.never()`，`SidebarRootViewModel.swift:224–228` 那段订阅在 iOS 上永不触发；迁移报告独立得出了同样结论。
- [D 可行性] 先加入 B、再离开 A，与现在的先离开后加入相反，会出问题 — 淘汰原因：registry 按 Engine identity 存放，两个 Engine 的工作互不相干，四份报告都构造不出失败场景。
- [D 可行性] 防 App Nap 的 activity 改成每个 Engine 一份后效果不同 — 淘汰原因：activity 作用于整个进程；凡是有工作的 Engine，上面必有文档，按 Engine 持有和按文档持有覆盖的范围相同。
- [D 可行性] 把 `documentDidOpen()` 并入创建后，第二个文档就不再触发 — 淘汰原因：它本身有 `hasStarted` 守卫，本来就只生效一次。
- [D 可行性] 切换瞬间 `combineLatest` 会把旧 image 路径写进新协调器 — 淘汰原因：前后两次写入在同一个主线程回合里，中间没有 `imageDidIndex` 读取。
- [D 可行性] 同一 Engine 重置时重新赋值，会让 `follow(_:)` 重复订阅 — 淘汰原因：`FindSession.swift:277` 遇到同一个协调器会直接返回。
- [D 可行性] 关闭两次、关闭后 readiness 又触发 `.switchEngine` — 淘汰原因：`registry.leave` 有成员守卫；`handleReadinessChange` 只对同一个 Engine 触发，提案对同一 Engine 不重新加入。
- [D 可行性] `isWorkInProgress` 搬家后线程或隔离出错 — 淘汰原因：`RuntimeEngineBackgroundWork` 是 `@MainActor`，组合可以在它的 `init` 里完成，反而不再需要 `MainActor.assumeIsolated`。
- [A/H] 缺动机、备选方案等章节；没有验收标准 — 淘汰原因：精简提案只要求三节，line 54–62 也有测试一节（验收不足已改报为 🟡4、🟡5）。
- [规则] 决策日志转录用户原话、标识符有缩写 — 淘汰原因：都没有。

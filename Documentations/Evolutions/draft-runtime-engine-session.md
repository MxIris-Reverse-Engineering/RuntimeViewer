# Draft - DocumentState 瘦身：Engine 与它的共享后台工作合成 RuntimeEngineSession

- **状态**: Draft
- **创建日期**: 2026-10-20
- **最后更新**: 2026-10-21
- **审查**: 两轮，每轮四位审查者。[第一轮](../Reviews/2026-10-20-draft-runtime-engine-session-review.md)合并后 1 🔴、12 🟡；[第二轮](../Reviews/2026-10-20-draft-runtime-engine-session-review-round-2.md)合并后 2 🔴、6 🟡。两轮的问题均已在本版处理

## 摘要

`DocumentState` 有 738 行，其中第 232–464 行在维护「这个文档在它所在 Engine 的共享后台工作里占一份」。提案 [0055](0055-engine-scoped-background-work.md) 之后，每个 Engine 只有一份后台索引、Find 语料与交叉引用预建。这一块是随功能一层层叠出来的命令式状态机，有三个问题：

- **getter 带副作用。** 读一下 `backgroundIndexingCoordinator`、`findCorpusCoordinator` 或 `crossReferencePreparationCoordinator`，就会加入 registry，并把三个 `needs…` 标志之一置上。`Document.makeWindowControllers` 靠一句 `documentState.backgroundIndexingCoordinator.documentDidOpen()` 加三句 `_ = documentState.xxx` 来「启动」这些工作。
- **有时序约束。** `.switchEngine` 必须先把文档搬到新 Engine 的后台工作上，再给 `runtimeEngine` 赋值，否则跟随 `$runtimeEngine` 的 `ReportViewModel` 和 `reportActivity` 会读到旧 Engine 的协调器。
- **按 Engine 的东西在每个文档上各算一份。** `reportActivity` 与防 App Nap 的 `BackgroundWorkProcessActivity`，对同一 Engine 上的所有文档结果都相同，却每个文档各算、各持一份。

改法：把 Engine 和这个文档在它上面的后台工作合成一个不可变的值 `RuntimeEngineSession`，消费者只跟随这个值；后台工作只能经一次显式的 `startBackgroundWork()` 加入；按 Engine 的汇总挪到 `RuntimeEngineBackgroundWork` 上。分四步落地，每一步需要的东西都在前一步里备好。App 里用户看到的行为不变。

## 方案

### 终态：`RuntimeEngineSession`

`@MainActor public final class`，放在 `RuntimeViewerApplication/Engine/`，所有属性都不可变：

- `public let engine: RuntimeEngine`
- `let backgroundWork: RuntimeEngineBackgroundWork?`（internal）：这个文档在该 Engine 上加入的后台工作；文档还没启动后台工作时为 `nil`。
- `func leave()`（internal）：先把本文档在这份工作的语料协调器上登记的侧栏 image 清成 `nil`，再离开 registry；最后一个离开的文档关闭这份工作，与 0055 相同。重复调用无效果。

一个 session 对应「某个 Engine，加上本文档在它上面的成员身份」。Engine 或成员身份一变，`DocumentState` 就建一个新 session；同一 Engine 的重置沿用原 session，只重新赋值一次；关闭只调 `leave()`。建 session 时，registry 与成员身份由 `DocumentState` 传进去，session 自己不持有 `@Dependency`。加入与离开都是显式的，不随任何订阅的生灭而变化。模块外只看得到 `engine`，`RuntimeEngineBackgroundWork` 仍只在模块内可见（0055 的决定不变）。

`DocumentState` 上是 `@RxObserved public fileprivate(set) var runtimeEngineSession`：写它的是同一文件里的 `SelectionRouter`，所以用 `fileprivate(set)`。`runtimeEngine` 改为只读转发 `runtimeEngineSession.engine`，`DocumentState` 之外读它的地方（源码 39 处、测试 27 处）不用改。

**`$runtimeEngineSession` 在哪些时刻发事件：**

| 时刻 | 做法 | 发不发 |
|------|------|--------|
| `DocumentState.init` | 建一个未加入的 session | 初值 |
| `startBackgroundWork()` | 为当前 Engine 建一个已加入的 session，赋值 | 发一次 |
| `.switchEngine` 到另一个 Engine | 建新 session（已启动则加入新 Engine），赋值，再让旧 session `leave()` | 发一次 |
| 有内容打开时，同一 Engine 重置：`handleReadinessChange` → `.switchEngine`，或在工具栏里重选当前来源 → `.main(engine)` | 把原 session 再赋值一次，不离开也不重新加入 | 发一次；`RuntimeInterfaceCache` 靠这次清缓存（RxSwiftPlus 0.2.5 的 setter 无条件 `accept`，已核实） |
| 什么都没打开时，同一 Engine 重置 | 不赋值，仍只发 `runtimeEngineDidReset` | 不发，与现在相同 |
| `documentWillClose()` | 调 `leave()`，不赋值 | 不发 |

三点说明：

- **关闭后的读者。** 读到的仍是关闭前那份工作：要么已经关闭，要么还在为别的文档运行。这与现在一致。关闭之后，没有路径会再去操作它：取消命令只来自 Report 页的输入，MCP 与 CLI 都不触发路由。从未启动就关闭的文档读到 `nil`。
- **启动时机。** `Document.makeWindowControllers` 把 `startBackgroundWork()` 放在第一句，赶在 `addWindowController` 之前，所以启动发出的那次事件，页面一侧还没有订阅者，只有 `DocumentState.init` 里那条 `combineLatest` 收到。即便顺序反过来，订阅者也会收到这次事件并拿到工作，正确性不依赖顺序。重复调用 `startBackgroundWork()`、或在关闭之后调用，都不起作用。
- **没有工作时。** Report 页显示空的 Report，活动标记不亮；`ReportViewModel` 的 Cancel、Cancel All、Clear History，`SidebarRootViewModel` 的 `prioritize`，都什么也不做。

### 落地步骤

不另起提案，分四步落地，每步单独 commit。每步结束时都要满足两条：`RuntimeViewerApplicationTests` 全绿，`RuntimeViewer macOS` scheme 编译通过（第 1 步改了 `Document.swift`，第 4 步改了 `MainViewModel.swift`，这两处包测试编译不到）。

在第 4 步之前，现有的两条约束仍然有效：启动必须早于订阅者，以及先搬工作、再赋值 Engine。App 里已经满足这两条：启动在第一句，搬工作仍由 `moveBackgroundWork` 负责。测试里，凡是要用后台工作的用例，都把启动放在最前面。这两条约束在第 4 步一起消除。

**第 1 步：只能显式启动。**
- 新增 `public func startBackgroundWork()`：加入当前 Engine 的工作，建出三个协调器，调 `indexingCoordinator.documentDidOpen()`，让 FindSession 跟随语料协调器，建出 App Nap activity。`Document.makeWindowControllers` 把它放在第一句，删掉原来那四句。
- 三个协调器 getter 不再加入工作，只读已加入的那份；还没启动时，返回一份按当前 Engine 缓存的、已关闭的工作（现有的 `RuntimeEngineBackgroundWork.closed(on:)`），它什么都不向 Engine 要。于是**漏调启动的用例拿到的是关闭的协调器，在这一步就会变红**。
- 三个 `needs…` 标志合成一个 `hasStartedBackgroundWork`。`moveBackgroundWork` 只在已启动时才搬：离开旧工作，加入新工作，再把启动做过的那几件事做一遍。`hasCreatedFindCorpusCoordinator` 删除。
- `FindScopeChooserViewModel` 的路径规范化改用 `runtimeEngine.canonicalImagePath`。原来的 `corpusCoordinator.canonicalImagePath` 本来就只是转发给它，行为不变。
- 测试侧：
  - `ViewModelTestEnvironment` 默认关掉语料构建（`settings.search.isCorpusEnabled = false`），做法与它关交叉引用预建相同，并改写它的文档注释。测语料的套件自己打开（多数已经显式打开；`FindScopeChooserViewModelTests`、`ReportViewModelTests` 里依赖默认值的几个用例要逐个核对）。
  - `ViewModelTestEnvironment` 加一个 `startBackgroundWork()`，在 `make {}` 里调用文档的启动。
  - 测试目标里加一个 `DocumentState` 扩展，取三个协调器：只读已加入的工作，签名是 `throws`（用 `try #require`），漏调启动时只让这一条用例失败，不会让整个测试进程崩溃。此后测试一律经它取协调器。
  - 这几个套件改为先调启动、再经扩展取协调器：`ReportViewModelTests`、`ReportSharedByEngineTests`、`FindScopeChooserViewModelTests`、`FindSessionCorpusTests`、`FindCorpusCoordinatorTests`、`FindCorpusCoordinatorRemoteTests`、`FindCorpusCoordinatorOlderPeerTests`、`FindGenerationOptionsTests`、`DocumentStateLifecycleTests`、`RuntimeBackgroundIndexingAlwaysIndexEngineTests`、`RuntimeBackgroundIndexingSharedEngineTests`、`RuntimeBackgroundIndexingReloadTests`、`BackgroundWorkProcessActivityTests`。这份名单按「文档要参与后台工作」整理；有遗漏的话，这一步就会红。
  - 删掉测试里 14 处显式的 `documentDidOpen()`，启动已经调过它。
  - `DocumentStateLifecycleTests` 里关于惰性加入的断言，改成「没启动的文档读 getter 不会加入」，用 registry 现有的测试缝 `backgroundWork(on:)` 断言。

**第 2 步：协调器随工作一并创建。**
- `RuntimeEngineBackgroundWork` 经 `registry.join` 创建时，建好三个协调器，并调一次 `indexingCoordinator.documentDidOpen()`。它有 `hasStarted` 守卫，每个 Engine 只生效一次。设置关着时照样创建协调器，以便响应设置从关到开（`DocumentState.swift:270–274` 的要求不变）。
- `startBackgroundWork()` 和 `moveBackgroundWork` 都不再自己建协调器、不再调 `documentDidOpen()`，加入即可。所以第 4 步删掉 `moveBackgroundWork` 时，切换后启动新 Engine 索引的那件事已经由工作的创建负责了。
- `closed(on:)` 建出的已关闭工作仍按需建出已关闭的协调器，直到第 4 步把它删掉。
- 补两条用例：开着索引，只调启动、不调 `documentDidOpen()`，就应出现批次；打开时索引关着，之后打开，照样开始索引。

**第 3 步：按 Engine 汇总活动，App Nap activity 改为每个 Engine 一份。**
- `RuntimeEngineBackgroundWork` 在创建时组合 `isWorkInProgress`：索引批次、语料构建、交叉引用预建，任一在跑即为真。协调器在第 2 步之后已经存在，可以直接组合，不再需要 `flatMapLatest` 加 `MainActor.assumeIsolated`。
- 它同时建出 `BackgroundWorkProcessActivity` 并持有，在 `close()` 里结束。activity 原来的 `documentWillClose()` 改名为 `close()`。scheduler 由 registry 在创建工作时传入：registry 新增 `processActivityScheduler` 属性，默认是 `ProcessInfo.processInfo`。registry 本来就是每个测试一份的依赖，测试改它即可。
- `DocumentState.reportActivity` 改为跟随 `$runtimeEngine`，取已加入工作的 `isWorkInProgress`，没有工作时为假。删掉 `DocumentState` 上的 `backgroundWorkProcessActivity`、`processActivityScheduler`、`hasCreatedBackgroundWorkProcessActivity`。
- 补三条用例：同一 Engine 上开两个文档、关掉一个，activity 仍然持有；最后一个离开才结束；文档切到另一个 Engine 后，新 Engine 有工作时持有 activity。最后这条钉住 `ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md` 修过的场景。

**第 4 步：引入 `RuntimeEngineSession`，删掉命令式的成员管理。**
- 按上文终态加入 `runtimeEngineSession`，`runtimeEngine` 改为转发。
- `$runtimeEngine` 的 7 个跟随者改为跟随 `$runtimeEngineSession`：`RuntimeInterfaceCache` 两处、`FindViewModel`、`ReportViewModel`、`MainViewModel` 两处，以及 `DocumentState.reportActivity` 自己。
- 直接读 getter 的地方改读当前 session 的工作，没有工作时按上文「没有工作时」处理：
  - `SidebarRootViewModel.swift:227` 的 `prioritize`
  - `FindScopeChooserViewModel` 的构建状态订阅
  - `ReportViewModel` 的 Cancel、Cancel All、Clear History
- `FindSession` 在 `init` 里用 `[weak self]` 跟随 `$runtimeEngineSession`，取当前工作的语料协调器。`follow(_:)` 改收可选参数：`nil` 时断开，并清空语料构建状态。
- 侧栏当前 image 改由 `DocumentState.init` 里一条 `combineLatest($runtimeEngineSession, $currentImageNode)` 交给当前工作的语料协调器，没有工作时什么都不做；`SelectionRouter` 不再调 `currentImageNodeDidChange()`。离开时的清理由 `leave()` 负责。
- 删除：三个协调器 getter、`hasStartedBackgroundWork`（由 session 有无工作代替）、`joinedBackgroundWork` / `leaveBackgroundWork` / `moveBackgroundWork` / `followInterfaceCorpus` / `currentImageNodeDidChange`、`RuntimeEngineBackgroundWork.closed(on:)`，以及它里面为已关闭工作保留的惰性分支，三个协调器改为 `let`。
- 保留：`isClosed`（让启动与切换在关闭后不再加入工作）、`hasCreatedFindSession`。成员身份仍用 `ObjectIdentifier(self)`。
- 测试侧：
  - 测试扩展改为从 session 取协调器，签名不变。
  - FindSession 不再由启动顺带建出，以下首次读取改为 `environment.make { documentState.findSession }`：`FindSessionCorpusTests.swift:23/61/94/123/187/228`、`FindCorpusCoordinatorTests.swift:75, 239`、`FindCorpusCoordinatorRemoteTests.swift:85`。不然它会在 `make {}` 外取到进程共享的 `AppDefaults.testFallback`。
  - `FindCorpusCoordinator` 加一个 internal 测试缝：按文档读它登记的侧栏 image。

### 测试与变异检查

**要钉住的行为**（括号里是该用例出现的步骤）：
- 同一 Engine 的窗口看同一份 Report；最后一个离开的文档取消工作、清空 Report；切走再回来，Report 换成那个 Engine 的（现有，第 1 步迁移）。
- 没启动的文档读 getter 不会加入；启动前就关闭的文档什么都不建；重复启动、关闭后启动都不起作用（第 1 步）。
- 只调启动就开始索引；设置先关后开也照样开始索引（第 2 步）。
- App Nap：两个文档关一个仍持有、最后一个离开才结束、切到另一个 Engine 后仍持有，以及语料构建期间持有（第 3 步；最后一条为现有用例，改由 registry 注入 scheduler）。
- **先绑定再启动**：先建好 Report 页与 FindSession，再调启动，两者都拿到这个 Engine 的协调器（第 4 步）。
- **切换后**：在切换之前就订阅 `$runtimeEngineSession`，并记录每次发出的值；断言切换后**发出的第一个值**就带着新 Engine 的工作，而且只发一次（第 4 步）。
- 有内容打开时同一 Engine 重置：先 `.switchImage`，再直接 `trigger(.switchEngine(同一个 Engine))`；用带计数 fetcher 的 `RuntimeInterfaceCache(documentState:fetcher:)` 断言重新取了数。不用 `stop()` / `connect()` 驱动，因为重连本身就会经 `dataChangePublisher` 清缓存，抓不到变异 3（第 4 步）。
- 离开旧 Engine 后，经 `FindCorpusCoordinator` 的测试缝断言本文档登记的侧栏 image 已清空（第 4 步）。
- 切换后，FindSession 跟随新 Engine 的语料协调器（第 4 步）。

**变异检查**：每一项都要让至少一条测试变红，做法同 0055。

| # | 变异 | 由哪条用例抓到 | 步骤 |
|---|------|----------------|------|
| 1 | getter 读一下仍会加入工作 | 没启动的文档读 getter 不会加入 | 1 |
| 2 | 工作创建时不调 `documentDidOpen()` | 只调启动就开始索引 | 2 |
| 3 | 任一文档离开就结束 activity | 两个文档关一个仍持有 | 3 |
| 4 | 切换后新 Engine 的工作不持有 activity | 切到另一个 Engine 后仍持有 | 3 |
| 5 | 启动时原地加入、不赋新 session | 先绑定再启动 | 4 |
| 6 | 切换时先赋一个未加入的 session，再加入 | 切换后发出的第一个值 | 4 |
| 7 | 同一 Engine 重置时不重新赋值 | 计数 fetcher 断言重新取数 | 4 |
| 8 | `leave()` 不清侧栏 image | 侧栏 image 测试缝 | 4 |
| 9 | FindSession 不跟随新 session | 切换后 FindSession 跟随新语料 | 4 |
| 10 | 最后一个离开时不关闭工作 | `ReportSharedByEngineTests` 的 `lastWindowLeaving*` | 现有 |

**App 级手动验证**（每步编译之后）：开两个 My Mac 窗口，各自的 Report 一致；把其中一个切到 Mac Catalyst，Report 随之切换，另一个窗口不受影响；在工具栏里重选当前来源，触发同一 Engine 重置，内容复位、没有崩溃。这条路径走 `.main(engine)`，会先清空 `routeDisposeBag`，所以不会撞上下文那个既有缺陷，现在就能验证。

### 同批更新的文档与代码注释

- 根 `AGENTS.md`：「Engine work is shared by the documents on the engine」一段（它描述的正是被删掉的 getter 与时序约束），以及 App Nap 一段。
- `Documentations/CommunicationAndEngineArchitecture.md:333`：App Nap activity 改由每个 Engine 的工作持有。
- `Documentations/Glossary.md`：改写现有的「Engine 的后台工作」词条（三件事，由文档显式启动时建立，持有 App Nap activity）；新增 `RuntimeEngineSession`，写明它在同一 Engine 的进程重启时保留不换。
- 代码注释与命名：`RuntimeBackgroundIndexingCoordinator.swift` 里「engine session」一词指 Engine 背后进程的一段生命周期，与新类型撞名、含义相反。第 69、98、105 行的注释，以及私有计数器 `session`（第 40 行）和 `isCurrent(_ session:)`（第 201 行），一并改成表示「这一次连接」的说法，例如 `connectionGeneration`。

### 没有询问就采用的假设

- 三种后台工作一起启动，不再单独启动。App 里每个文档本来就三种都用；测试不想要哪一种，就用设置关掉。
- 对没启动过后台工作的文档（只有测试会这样），这是一处行为改变：现在读一次 getter 就会加入工作，改完之后不会。iOS 不受影响：它给 `selectedNode` 传的是 `.never()`，从来不读这些 getter。
- App Nap activity 由每个文档一份改为每个 Engine 一份，效果相同：activity 作用于整个进程，而有工作的 Engine 上必然有文档。

### 参照 Xcode：借鉴了什么，哪些不能类比

依据：逆向 Xcode 27.2 beta 27B5028f 的 IDEKit / IDEFoundation，以及 27.0 的 DVTFoundation（`DVTInvalidation`），均经反编译核对。

- **借鉴**：
  - 服务是上下文对象自己的属性（`IDEWorkspace._index`），文档上不另存一份要和上下文对齐的字段。
  - 消费者在事件到达时重读当前服务（`IDEIndexerActivityReporter` 比较 `notification.object == workspace.index`）。
  - 共享对象的计数（`IDEContainer`）与拆除（父对象按固定顺序 `invalidate` 子对象）是显式的。
  - 活动汇总每个工作区算一次，每个窗口各自展示。
- **不能类比**：
  - Xcode 的工作区一生不换，没有「切换 Engine」这样整体换上下文的操作。它在运行目标变化时更换索引，靠的是 KVO 观察、合并到下一轮 runloop 再拆旧建新，也就是说服务的更换是观察推导出来的，并不是显式的。
  - 它的 App Nap token 挂在 `IDEWorkspaceDocument` 上，只在加载期间持有，加载完成（finishedLoading）就结束，不能拿来支持「每个 Engine 一份」。

### 不在本提案内

- 导航一侧可向 Xcode 借鉴的三点另案处理：tab 去留抽成纯函数（Xcode 的 `tabActionAfterNavigation`）；时间线 `selectionStack` 设上限；需要等待的跳转（等语料找出声明位置）在执行前确认 Engine 没换。
- **既有缺陷，另行修复**：有内容打开时，Engine 经 `handleReadinessChange` 重置会走 `.switchEngine`，而这时 `MainCoordinator` 对 `routeSignal` 的订阅还在，`fanOut` 会撞上 `assertionFailure`（`MainCoordinator.swift:184–190`）。Debug 构建会崩；Release 构建里侧栏和内容区不复位，`DocumentState` 却已经清空。这个缺陷自 3d2ae6dc（提案 0037）起就存在。本提案的同 Engine 重置设计不依赖它怎么修。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-20 | Created as Draft | `DocumentState` 臃肿，主要来自后台工作成员身份这一块：getter 带副作用、三个 `needs…` 标志、先搬工作再赋值 Engine 的时序约束，每加一种后台工作就再叠一层 |
| 2026-10-20 | 不只是把这块原样搬进一个新类 | 搬家不改状态机，复杂度原样还在；改建模才能真正删掉代码 |
| 2026-10-20 | 不用 `flatMapLatest` + `Observable.using` 从 `$runtimeEngine` 推导成员身份 | 推导出来的工作仍是与 Engine 并列、需要对齐的第二个值，时序问题只是换了位置。（初稿还以「Xcode 的加入与离开都是显式的」为理由，审查指出 Xcode 更换服务恰恰是靠观察推导的，这条理由已撤回） |
| 2026-10-20 | Engine 与后台工作合成一个值，类型名定为 `RuntimeEngineSession` | 消费者只跟随一个值，时序约束从结构上消失。类型名由用户指定，与 `RuntimeEngine` 系列命名一致 |
| 2026-10-20 | 活动汇总与 App Nap activity 挪到 `RuntimeEngineBackgroundWork` | 同一 Engine 上每个文档算出的结果相同 |
| 2026-10-20 | 导航一侧的三点借鉴不并入本提案 | 与这次瘦身互不依赖，分开评审、分开落地 |
| 2026-10-20 | 按第一轮审查修订（用户批准修改）：session 定为不可变的 `@MainActor final class`，并写明每个时刻发不发事件；启动时赋一个新 session | 四位审查者都指出，订阅者在启动之前就已存在，而初稿没写工作怎么交到它们手上。不可变加上「状态变了就换新实例」，让每个时刻发不发事件都只有一种答案 |
| 2026-10-20 | `leave()` 负责清掉本文档登记的侧栏 image | 初稿漏掉了这一步，旧 Engine 会一直优先构建一个已经没人在看的 image |
| 2026-10-20 | 关闭时不再把工作置空，迟到的读者读到它离开的那份工作 | 保持现有语义，关闭也不必发事件；只有从未启动的文档才读到 `nil`，`closed(on:)` 因此可删 |
| 2026-10-20 | 删掉「测试变慢就退回惰性创建」的退路 | 惰性创建加上并入的 `documentDidOpen()`，等于把带副作用的 getter 放回下一层 |
| 2026-10-20 | 「同一 Engine 重置撞断言」登记为既有缺陷，另行修复 | 用户决定稍后处理；它在本提案之前就存在，修法与本提案无关 |
| 2026-10-21 | 按第二轮审查重排落地步骤：只能显式启动 → 协调器随工作一并创建 → 活动汇总与 App Nap → 引入 session | 原先的顺序里，第 3 步删掉 `moveBackgroundWork` 后没人给新 Engine 调 `documentDidOpen()`；第 2 步取不到「当前工作」，也定不了 activity 何时建。重排后，每一步需要的东西都在前一步里 |
| 2026-10-21 | 第 1 步就让 getter 不再加入工作，未启动时返回已关闭的工作 | 这样漏调启动的用例在第 1 步就会变红，测试从第 1 步起就是回归护栏；原先读旧 getter 的做法，要到第 3 步才暴露漏迁的套件 |
| 2026-10-21 | 测试环境默认关掉语料构建，测语料的套件自己打开 | 第 1 步的启动就会建出语料协调器；与 `ViewModelTestEnvironment` 关交叉引用预建的做法一致，不必逐个套件去关 |
| 2026-10-21 | 不采用「两个独立值」的替代方案（`runtimeEngine` 原样保留，另加一个可观察的 `backgroundWork`），仍用 `RuntimeEngineSession` | 用户选定。两个独立的值会留下交叉读取的隐患：跟随其中一个的消费者若顺手同步读另一个，读到新值还是旧值取决于赋值顺序，只能靠约定防范，而这正是本次重构要消除的那一类问题。代价是 App target 改两处、多一个公开类型 |
| 2026-10-21 | 第 1–3 步保留「启动早于订阅者」「先搬工作再赋值 Engine」两条过渡约束，第 4 步一并消除 | 前三步还没有 session，这两条约束无法提前消除；App 已经满足它们（启动在第一句，搬工作仍由 `moveBackgroundWork` 负责），测试按同样的顺序来写 |

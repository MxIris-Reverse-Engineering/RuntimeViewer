# PR #125 代码审查记录 — 2026-10-21

审查对象：PR #125（`chore/runtime-engine-session` → `next`，提案 [draft-runtime-engine-session](../Evolutions/draft-runtime-engine-session.md) 的四步实现），head `8cd5d2b5`，基线 `next` `9c1b3402`。

**经过**
1. `/code-review xhigh` 交回 9 条发现，没有高危的正确性问题。每条都回到代码复核，按四问作答：能否复现、基线上有没有、值不值得修、以前修过没有。
2. 用户批准：修 PR125.1、PR125.2、PR125.8、PR125.9 与 PR125.6 的措辞，其余记为不修；另要求同批修掉提案第一轮审查登记的既有缺陷「同一 Engine 重置撞断言」，记为 PR125.10。要修的代码问题都先写了修复前失败的测试。

**约定**
- ID 为 `PR125.<N>`：1–9 按审查交回的顺序，10 是同批修掉的既有缺陷。
- 四问里的「基线」是 `next` `9c1b3402`。
- 审查本身否掉的一条不入表：它建议把同步投递（`driveOnNext` 加 `MainActor.assumeIsolated`）换成 `…MainActor` 系列。后者每个值都隔一个主线程回合才执行，PR125.1 正是由此而来；提案决策日志记了为什么侧栏 image 与 FindSession 要同步投递。

## 条目

| ID | 问题 | 严重度 | 处理 |
|---|---|---|---|
| PR125.1 | 工作关闭后，App Nap activity 仍可能被一条正在路上的报告重新拿起 | Minor | 已修（`e93515d2`）：关闭之后的报告一律不再拿起；测试 `reportOnItsWayWhenClosingTakesNoActivity` |
| PR125.2 | `sameEngineStartingOverPutsTheSessionInPlaceAgain` 靠睡 300 毫秒等 Engine 首次连接后的刷新 | Minor | 已改（`6bdebd50`）：先订阅再连接，等到那次刷新 |
| PR125.3 | 切 Engine 时，新 Engine 的语料协调器短暂收到旧 Engine 的 image 路径 | Minor | 不修：同一回合内就被覆盖，读它的代码插不进来 |
| PR125.4 | `documentDidOpen()` 声明在 `#if canImport(RuntimeViewerSettings)` 里，调用处没包 | Nit | 不修：那些 `#if` 恒为真 |
| PR125.5 | 同一 Engine 重置靠把同一个 session 再赋值一次来表达 | — | 不修：提案定下的设计，由 PR125.2 那条测试守着 |
| PR125.6 | `RuntimeEngineSession` 的三个可选属性总是同时为空或同时有值；注释写「Immutable」 | Nit | 改措辞；结构不改 |
| PR125.7 | 「跟着 session 取工作的某个成员」的管道在四处手写 | Nit | 不修 |
| PR125.8 | 文档索引里这份提案还写着「待批准」，第二轮审查的替代设计还写着「待定」 | Nit | 已改 |
| PR125.9 | 测试辅助 `JoinedBackgroundWork.swift` 的注释还描述第 1 步的行为 | Nit | 已改 |
| PR125.10 | Engine 回来时文档有内容打开，`.switchEngine` 撞上 `MainCoordinator.fanOut` 的断言 | Major | 已修（`26d9fad7`）：改由窗口走 `.main`；测试 `comingBackWhileBrowsingSendsNoRoute` |

## PR125.1 — 关闭后又拿起 App Nap activity

- **问题**：`BackgroundWorkProcessActivity` 用 `driveOnNextMainActor` 跟随 `isWorkInProgress`。RxSwiftPlus 0.2.5 里它把每个值包进 `Task { @MainActor }`，晚一个主线程回合才执行。`close()` 只换掉 `disposeBag`，已经排进队列的 Task 照样执行，而 `update(isWorkInProgress:)` 不看工作是否已关闭。于是工作刚报「开始」、Task 还没执行时，同一回合里最后一个文档离开（关窗或切走），`close()` 先放掉 activity，排队的 Task 再把它拿起，之后再没有订阅放掉它。它一直持有到这份已关闭的工作被释放为止，而离开的文档的 session 还引用着这份工作。
- **复现**：`reportOnItsWayWhenClosingTakesNoActivity`：同一回合里先报 `true` 再 `close()`，等主线程清空后，修复前仍持有 activity。
- **基线**：有。基线上每个文档一份 activity，`documentWillClose()` 的函数体与订阅方式完全相同；本 PR 只是改名，挪成每个 Engine 一份。
- **修法**：记下 `isClosed`，`close()` 之后到达的报告不再拿起 activity——与三个协调器在每个 `Task { @MainActor }` 开头查 `isClosed` 的做法一致，横向排查时它们都已经这样写，只有这个类缺。
- **历史**：2026-10-13 修「App Nap 拖慢后台工作」时引入。注释从那时起就承诺「之后的报告不会再拿起」，实现一直没做到。

## PR125.2 — 测试靠睡眠等首次刷新

- **问题**：Engine 连上后那次 `.fullReload` 是 `broadcast` 在一个不被等待的 `Task` 里发出的，`connect()` 返回时它可能还没发。它晚于 300 毫秒落地时：落在两次取接口之间，第一条计数断言误报失败；落在 `.switchEngine` 之后，缓存是被这次刷新清空的，「同一 Engine 重置时不再重新赋值」的回归也能通过。
- **基线**：没有，测试是本 PR 新加的。
- **修法**：不用 `makeConnected`，先订阅 `dataChangePublisher` 再 `connect()`，等到 `.fullReload(isReloadImageNodes: true)` 再开始。横向排查：其余按计数断言接口缓存的测试（`RuntimeInterfaceCacheTests`、`ContentTextPipelineTests`）都不用新连上的 Engine。

## PR125.3 — 新 Engine 的协调器短暂收到旧 image（不修）

- **问题**：`moveSession(to:)` 赋上新 session 时，`currentImageNode` 还是旧 Engine 的，侧栏 image 的 `combineLatest` 把它报给新 Engine 的语料协调器；路由紧接着在同一回合里把它置为 `nil`。
- **为什么不修**：`setOnScreenImagePath` 只是存进字典，唯一读它的 `imageDidIndex(at:)` 经 `receive(on: DispatchQueue.main)` 投递，插不进这两句之间。基线上的 `moveBackgroundWork(to:)` 也是先用旧 image 通知新协调器、路由之后才置 `nil`，顺序完全相同。审查称「旧代码先清 image」不对。
- **何时重新审视**：`setOnScreenImagePath` 若改为当场排序或开始构建。

## PR125.4 — 未包 `#if` 的 `documentDidOpen()`（不修）

- **问题**：`RuntimeEngineBackgroundWork.init` 直接调 `documentDidOpen()`，而它声明在 `#if canImport(RuntimeViewerSettings)` 里。
- **为什么不修**：`RuntimeViewerApplication` 在 `Package.swift` 里无条件依赖 `RuntimeViewerSettings`，这些 `#if` 恒为真，构造不出失败；基线上 `moveBackgroundWork` 也不加 `#if` 就调它。真正的问题是这些 `#if`（`RuntimeBackgroundIndexingCoordinator`、`FindCorpusCoordinator`、`ReportViewModel` 三处）是 2026-04 后台索引最初几次提交留下的死代码，要清就单独清。
- **何时重新审视**：这项依赖改为按平台有条件时。

## PR125.5 — 同一个 session 再赋值一次（不修）

- **问题**：审查认为用「再赋值同一个对象」表达重置，依赖两个未写明的前提：`@RxObserved` 不去重，也没有消费者给它加 `.distinctUntilChanged { $0 === $1 }`。
- **为什么不修**：这是提案事件表定下、经两轮审查并由用户批准的设计，决策日志里也记了它放进 `putSessionInPlaceAgain()` 的理由。审查担心的去重会让 `sameEngineStartingOverPutsTheSessionInPlaceAgain` 变红——PR125.2 修好之后，这条测试就是它可靠的护栏。

## PR125.6 — session 的三个可选属性（改措辞）

- `backgroundWork`、`registry`、`member` 总是同时为空或同时有值。不合并：只有 `leave()` 一处用到，类型是 internal。「Immutable」改为写明 engine 与持有的工作从不改变、唯一的状态是是否已经离开——同 Engine 重置依赖的恰是引用身份，说成不可变值会误导。根目录 `AGENTS.md` 里同样的说法一并改了。
- **何时重新审视**：出现第二个要用到成员身份的操作时。

## PR125.7 — 四处手写的跟随管道（不修）

- `FindScopeChooserViewModel`、`ReportViewModel`、`FindSession`、`DocumentState.reportActivity` 各自跟随 `$runtimeEngineSession`、取 `backgroundWork` 的某个成员。基线上这几处同样各自跟随 `$runtimeEngine`、各自去读协调器 getter，只是换了形式。四处要的成员与空值本来就不同（Report 什么都不显示、Find 跟随 `nil`、活动为 `false`），抽出公共访问器只能省掉一行 `assumeIsolated`。

## PR125.10 — 同一 Engine 重置撞断言

- **问题**：Engine 背后的进程重启（本地运行时 XPC service 重新拉起）后，`DocumentState.handleReadinessChange` 在文档有内容打开时直接 `selectionRouter.trigger(.switchEngine(engine))`。这时 `MainCoordinator` 对 `routeSignal` 的订阅还在，`fanOut` 的 `case .switchEngine` 调 `assertionFailure`：Debug 构建崩溃；Release 构建里侧栏和内容区不复位，`DocumentState` 却已经清空。
- **复现**：`comingBackWhileBrowsingSendsNoRoute`：打开一个 image，Engine `stop()` 再 `connect()`，修复前 `routeSignal` 上收到 `.switchEngine`。
- **真实触发过一次**（2026-10-21，Debug 构建，屏幕锁着）：系统日志显示，内核的内存回收从 12:29 起每秒杀一个闲置进程，12:25–12:35 共 138 个。12:30:28 与 12:30:29 依次杀掉本地运行时 service（已闲置 2067 秒，占约 560 MB）与 Catalyst service，launchd 记下的退出原因是 `JETSAM_REASON_MEMORY_IDLE_EXIT`。12:30:36 App 发现两个 service 都已退出，第一次重连就连上「My Mac」，随即撞上断言。XPC service 只要手上没有正在处理的请求就算闲置，App 一直连着也不算在用，所以内存一紧，系统随时可能回收它们；修好之后，这种回收只会让文档退回镜像列表。
- **基线**：有，自 3d2ae6dc（提案 0037，本地运行时搬进 XPC service）起就存在；提案第一轮审查第 12 条发现了它，当时登记为另行修复。
- **修法**：`DocumentState` 不再自己发 `.switchEngine`，改发 `startOverRequested`；`MainCoordinator` 在 `.main` 里订阅，转成 `.main(engine)`，与在工具栏里重选当前来源同一条路径：先断开对路由的订阅，再发路由，再换上新窗格。不让 `fanOut` 接住这条路由：那样旧窗格会先看到状态被清空、再被换掉。`RuntimeViewerUsingAppKit/AGENTS.md` 加了一条：只有 `.main` 发 `.switchEngine`。
- **没有窗口的地方**：包测试与 iOS 不再自己复位。测试里由一个辅助函数扮演窗口；iOS 的本地引擎在进程内，不会重启。

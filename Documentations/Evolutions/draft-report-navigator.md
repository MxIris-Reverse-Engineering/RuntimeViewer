# Draft - Report navigator：后台索引与语料构建的状态搬进侧栏

- **状态**: In Progress
- **创建日期**: 2026-09-30
- **最后更新**: 2026-10-05
- **关联提案**: [draft-find-navigator](draft-find-navigator.md)（语料构建的状态来源）、[0002-background-indexing](0002-background-indexing.md)（被替换的 toolbar 按钮与弹窗）

## 摘要

toolbar 上的 Background Indexing 按钮和它的弹窗去掉，换成侧栏的第四个分页，照 Xcode 26 的 Report navigator
做：一列条目，后台索引的批次和 Find 语料库的构建各是一类，可展开看每个镜像的状态与进度；有任何一项在跑时，
分页图标带一个活动标记。起因是用户实测（2026-09-30）：5 个镜像索引完，Find 只报「4 images not yet
searchable」，而 4 个语料库其实正在排队构建，App 里没有任何地方能看出来。

## 方案

**布局照用户导出的 Xcode 26 Report navigator view hierarchy 实现**（`Xcode-ReportNavigator.viewhierarchy`，2026-10-01
提供）。只搬侧栏那一列，不搬 Xcode 选中条目后在编辑区打开的日志页；内容区不加新页面类型，选中一行什么也不打开。

- **挂载**：两层侧栏各加第四个 `TabViewItem`（`receipt` 符号，Xcode 自己的 Report navigator 图标），共用同一份状态，与
  Find 分页的模式一致：`SidebarRootRoute` / `SidebarRuntimeObjectRoute` 各加 `.reports` = `.select(index: 3)`，
  `SidebarRoute.showReports` 转给屏幕上那一层，`MainRoute.reports` 先展开侧栏再转发。主菜单入口是
  **View ▸ Show Report Navigator（⌘9）**，放在 Show Sidebar 之后——Xcode 的位置与快捷键。
- **页面**（`ReportViewController<Route>`，App target `Reports/`）：一列 `StatefulOutlineView`（source list，行高 24、缩进 14，
  macOS 26 起用 `SidebarTableRowView`），底部 44 pt 的栏：左边一个动作按钮（菜单：Cancel All / Clear History / Open Settings…，
  无事可做的项置灰），右边 `FilterSearchField`（占位 "Filter"），过滤框里一个时钟开关。什么都没有时整页显示 "No Reports"。
  行的右键菜单：能撤回的工作给 Cancel，「Turned off in Settings」行给 Open Settings…；双击该行也打开设置。
- **树的形状**：两类工作各是一个第一层行——**Background Indexing** 与 **Searchable Interfaces**，与弹窗的 ACTIVE / HISTORY 分组
  不同，进行中与已结束的放在同一类下面、最新的在上。索引：先是在跑的批次（按开始先后倒序），再是 history；批次下挂它的镜像，
  Always Index 只有一个镜像的批次不再挂子行（弹窗的扁平化保留），这个镜像失败时批次行自己写 "Failed" 并带上失败原因。语料：先是排队与打印中的镜像（打印中的在前，其余按名字），
  再是 `finishedBuilds`。某一类没有任何内容时整类不出现。
- **行**（`ReportCellView`）照 Xcode 的 `DVTTableCellViewOneLine`：16 pt 图标；标题在 x = 19；标题之后紧跟次要色的说明文字；
  最右 16 pt 的状态位——在跑时是小号 spinner（Xcode 的 `IDELogNavigatorStatusView`），失败时是红色 `xmark.octagon.fill`，
  tooltip 是失败原因。**进度不用进度条**，写在说明文字里（"37% · 950 of 2559"、"3 of 12"）——Xcode 的行没有进度条。
  结束的行说明里是结束时间（"Today, 10:23"），取消 / 失败的写 "Cancelled · …" / "Failed · …"；行的 tooltip 是镜像路径，
  建好的语料再加对象数与大小。
- **列表的数据**：每行一个 `ReportCellViewModel`（`RuntimeViewerApplication/Reports/`），按 `ReportNodeIdentifier` 缓存、跨重建
  复用。图标、标题、说明、状态与 tooltip 合成一个 `Appearance`，只挂一个 `@RxObserved`（规矩见
  [0005](0005-cellvm-appearance-single-observed.md)）；cell 在 `bind(to:)` 里绑这一条流，只重设变了的部分——进度直接落到
  屏幕上的行，不需要大纲重载。
  树本身是值类型 `ReportNode`，按 RxAppKit 0.6.0 的节点约定：`==` 与哈希只取标识（NSOutlineView 只为相等的项保住展开状态，
  大纲每次查找都要哈希一个 item），`isContentEqual` 递归比较整棵子树的形状与各行的 cell ViewModel 是否同一个对象（适配器只在
  根层问它，再据此决定要不要 `reloadData`）。大纲开着 `StatefulOutlineView.preservesSelectedItemAcrossReloads`，重载后选中留在
  原来的项上。原计划的三种 CellViewModel 合成了一种：Xcode 每一行的构成都一样。
  大纲用 `StatefulOutlineView`：带分组行的 source list，正是 2026-09-27 那份已解决问题描述的行高估算风险形状。
- **功能关闭时**：在该类下面放一行 "Turned off in Settings"（右键 / 双击打开设置），而不是整页占位——另一类的工作照常可见。
  索引与语料各看自己的开关（`settings.indexing.isEnabled`、`settings.search.isCorpusEnabled`）。
- **过滤栏**：文字过滤保留标题匹配的行及其祖先；时钟只留**进行中**的工作——在跑的批次与其未结束的镜像、排队与打印中的语料。
  Xcode 的时钟是「只看最近的」，这里的报告只活在本次会话里，「最近」没有意义，换成用户真正要找的「还在跑的」。
  过滤文字与时钟状态由输入写进 ViewModel 自己的状态（初值：空文字、时钟关），大纲从这两个状态算出来，不直接合并输入：
  过滤框的 `rx.stringValue` 只在用户输入时发值，没碰过的过滤框什么也不发，直接拿它合并会让大纲一直空着（见决策日志）。
- **语料条目与取消语义**：每个镜像一行，排队写 "Waiting"，打印中写百分比与对象数；取消只撤回本文档的订阅——别的文档还订着时
  构建继续；取消不是粘性的，下一个触发源（索引完成、transformer 变化、开关切换）会重新请求。被取消的那一行进 history。
- **语料状态的来源与归属**：`FindCorpusCoordinator` 暴露 `buildStatesByImagePath: [String: RuntimeInterfaceCorpusBuildState]`
  与 `finishedBuilds`（built / failed / cancelled 的历史，newest first，与索引 history 同样封顶），都是 `@RxObserved`，由它发出的
  每个构建请求的 `onProgress` 与任务结果驱动，进度按 16 ms 合并后再发。启动与换引擎时先用 `interfaceCorpusCoverage()` 补一次快照，
  把别的文档已经开始的构建也算进来；**合并规则**：快照不覆盖本文档请求已经写入的状态；快照里没有完成时间，别的文档先建好的镜像
  放进 `finishedBuilds` 时排在本文档条目之后、不按时间排，**每个镜像只学一次**——Clear History 清掉的不会被下一次快照带回来，
  镜像的语料从引擎里消失后才可能再被学到。**驱逐后状态过期**：store 的预算驱逐与 `evict` 都不发事件，Reports 页出现时与每次构建
  结束后重取一次 coverage；让 store 发驱逐事件是后续项。Clear History 同时清索引协调器的 history 与 `finishedBuilds`。
- **活动信号只算一处**：`DocumentState.reportActivity: Driver<Bool>`（索引协调器的 `aggregateState.hasActiveBatch` ∨
  `FindCorpusCoordinator.hasActiveBuild`，后者即任一语料 pending / building）。
- **活动标记的绑定位置**：`TabViewItem` 带一个可选的 `activity: Driver<Bool>`，`TabViewController` 在 `setTabViewItems` 时订阅、
  挂在自己的 dispose bag 上，状态存在 controller 里，每次重设分段图后重新套上；普通图与选中图（`setImage` /
  `setAlternateImage`）一起换。分段控件的图是模板图，带颜色的标记会被染成单色，所以标记是从图标右上角**挖出**的一个圆点，
  模板着色后照样看得出来。
- **删除**：`BackgroundIndexingToolbarItem`（含其同名标识符常量）、`MainRoute.backgroundIndexing(sender:)`、
  `MainCoordinator` 的 `.backgroundIndexing` 转场、`MainToolbarController` 里的五处（属性、默认与允许标识符列表、
  `itemForItemIdentifier`、常量）、`MainWindowController` / `MainViewModel` 的点击信号、弹窗 VC / VM / 节点。toolbar 不允许用户
  自定义，没有持久化配置会因标识符消失出问题。
- **测试**：`ReportViewModelTests`（真实引擎：结束的批次与建好的语料各在自己那一类下；关掉的功能只显示一行、打开后消失；
  打印进度只改行自己的 cell、树不变；从行上取消语料构建后它以 cancelled 进 history；Clear History 清空两类；
  分页的活动标记随进行中的工作出现、Cancel All 后消失；过滤栏没碰过时大纲照样有行；纯函数：文字过滤与时钟过滤）。顺带测出两个已有缺陷，修复与回归测试同批：
  `FindCorpusCoordinatorTests.clearedHistoryStaysCleared`、`RuntimeInterfaceCorpusStoreTests.queuedBuildOutlivesBuilder`
  （见决策日志）。App target 没有单元测试 target，AppKit 一侧只做了编译验证；用户把 App 跑起来后看到大纲是空的，修复与回归测试
  `outlineShowsBeforeFilterBarIsTouched` 见决策日志。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-30 | Created as Draft | 用户：「这个可以和后台索引放一起展示，刚好可以把 Xcode 的 Report Navigator 搬过来，toolbar 那个后台索引去掉」。 |
| 2026-09-30 | 只搬侧栏列表，内容区不加详情页 | 用户在提问轮选定。 |
| 2026-09-30 | 分页图标上加活动标记，不在 toolbar 放活动文字 | 用户在提问轮选定；toolbar 按钮今天没有任何进度绑定（提案 0002 写的进度叠层并不存在），去掉它不丢功能。 |
| 2026-09-30 | 落在 `feature/find-navigator`，不进 3.0.0 | 用户：「这些改动有点大，把 Find 以及后续功能都放回原来的分支吧，next 分支 reset 回去，不打算 3.0.0 版本发布这个功能」。 |
| 2026-09-30 | 第一轮审查：逐条列出弹窗行为的去留；语料 history 归 `FindCorpusCoordinator`、Clear History 清两边；活动信号只在 `DocumentState` 算一次；换图接口两张图都换；删掉 App target 的测试承诺；菜单位置交用户 | 原稿漏了 disabled 占位、空闲文案、百分比副标题与 Always Index 扁平化的去留，语料 history 无归属，两层各自合成活动信号会漂移，App target 没有单元测试 target。 |
| 2026-10-01 | 语料状态的来源先随 Find 提案 §1.1 第 4 条落地；本提案的布局仍等 view hierarchy | `FindCorpusCoordinator` 已发布 `buildStatesByImagePath`、`finishedBuilds`（元素 `FindCorpusFinishedBuild`，built / failed / cancelled，100 条封顶）与 `hasActiveBuild`，并提供 `cancelBuild(of:)`、`clearFinishedBuilds()`、`refreshCoverage()`；进度 16 ms 合并、快照合并与驱逐后重取都按上面「语料状态的来源与归属」实现，Find 的摘要栏已经在用。Report navigator 的 ViewModel 直接绑这些，不再另起状态。盘上没有 Xcode 26 Report navigator 的导出，已请用户导出。 |
| 2026-09-30 | 第二轮审查：删除清单补 `MainCoordinator` 转场；列表改 CellViewModel 逐行绑定；语料进度 16 ms 合并；活动标记的订阅放进 `TabViewController` 而非 coordinator，状态在重设分段后重套；写明取消语义、快照合并规则、驱逐后重取 coverage、语料开关的占位；大纲用 `StatefulOutlineView`；树的形状列为待定 | 审查指出弹窗靠逐行驱动器刷新而草案没搬、语料进度会比索引事件更密、coordinator 订阅状态改视图不合本仓库 MVVM-C、驱逐是静默的、语料开关关着时用户看不出为什么搜不到。 |
| 2026-10-01 | 状态 Draft → In Progress；布局照用户提供的 Xcode 26 Report navigator hierarchy | 用户：「开始实现提案」，并给出 `/Users/JH/Downloads/Xcode-ReportNavigator.viewhierarchy`。 |
| 2026-10-01 | 树的形状：Background Indexing 与 Searchable Interfaces 两个第一层行，进行中与已结束的同在一类下、最新在上 | Xcode 的 Report navigator 按「对象」分第一层（scheme / package），每层下面最新的在上，不分 active / history；语料与索引是两件独立的事，各自一类。 |
| 2026-10-01 | 进度写进说明文字，不用进度条；结束时间写成 "Today, 10:23" | Xcode 的行（`DVTTableCellViewOneLine`）只有图标、标题、次要文字与右侧状态位，没有进度条；照搬它的行就没有放进度条的位置。 |
| 2026-10-01 | 过滤栏的时钟表示「只看进行中的」（排队的也算），不是 Xcode 的「只看最近的」 | 报告只活在本次会话里，「最近」区分不出什么；用户打开这一页多半是想知道还有什么在跑。 |
| 2026-10-01 | 菜单入口：View ▸ Show Report Navigator（⌘9） | 提案留给用户的选择；用户没有另外指定，取 Xcode 自己的位置与快捷键（View ▸ Navigators ▸ Show Report Navigator，⌘9），⌘9 在本应用里没有被占用。 |
| 2026-10-01 | 三种 CellViewModel 合成一种 `ReportCellViewModel`；功能关闭时在该类下放一行而不是整页占位 | Xcode 每行的构成一样，分三种只会复制三份同样的属性；整页占位会把另一类的工作也挡住。 |
| 2026-10-01 | 修：Clear History 之后，下一次 coverage 刷新把清掉的语料当作「别的文档建的」重新列回 history | `ReportViewModelTests` 测出：`mergeCoverage` 只看 `finishedBuilds` 里有没有这个镜像，清空后每个还在引擎里的语料都会被「学」回来；而 Reports 页每次出现、每次构建结束都会刷新。`FindCorpusCoordinator` 记住列过的镜像（Clear History 不清这份记录，语料从引擎消失时才移出），回归测试 `clearedHistoryStaysCleared` 修前红、修后绿。 |
| 2026-10-01 | 修：语料 store 对引擎的引用从 `unowned` 改为 `weak`，找不到引擎的构建按取消结束 | 测试并行跑时进程崩在 `RuntimeInterfaceCorpusStore.run` 的 `swift_abortRetainUnowned`：引擎带着排队的构建被释放，`stop()` 安排的驱逐还没到，正在跑的构建一结束 `pump()` 就拉起下一个，读到已释放的引擎。回归测试 `queuedBuildOutlivesBuilder` 修前崩、修后绿。同一写法的 `RuntimeBackgroundIndexingManager.engine` 没改：换引擎时协调器会持有旧引擎先取消它的全部批次，App 里的路径有保护，改它要动 `main` 上的代码，另议。 |
| 2026-10-01 | 修：过滤栏没碰过之前，Report 页的大纲一直是空的；过滤文字与时钟状态改存在 ViewModel 自己的状态里 | 用户把 App 跑起来：分页上的活动圆点亮着，大纲却空着，"No Reports" 也没出现。`ReportViewModel` 用 `Driver.combineLatest` 把节点与 `input.filterString`、`input.showsOnlyInProgress` 合在一起，要等每一路都来过值才输出；页面的过滤文字来自 `FilterSearchField.rx.stringValue`，RxCocoa 没有这个成员，落到 RxAppKit 的 key-path 控件属性上——只在控件发出 action（用户输入）时发值，订阅时不发当前值。"No Reports" 绑的是未过滤的节点，所以它照样被藏起来。ViewModel 测试给的是 `.just("")`，订阅即有值，没测出来。改法照 `FindViewModel`：输入写进带初值的 `@RxObserved` 状态，大纲从状态算。回归测试 `outlineShowsBeforeFilterBarIsTouched` 用页面自己的 `FilterSearchField` 作过滤输入、时钟输入不发值：修前 10 秒等不到任何行，修后 0.58 秒；另跑了一个只把时钟换成 `.just(false)`（页面用 `startWith(false)` 给了初值）的临时对照，修前同样等不到，确认卡住大纲的就是过滤框。横向排查：Find 页的 ViewModel 本来就把过滤文字存成状态；没有别的 ViewModel 直接合并过滤框的输入。 |
| 2026-10-05 | 行的显示内容合成一个 `Appearance`，`ReportCellViewModel` 只留一个 `@RxObserved`；`update(...)` 不等才整体赋值一次，cell 只重设变了的部分 | 用户指出：行是一行一个实例、成百上千，原来的五个 `@RxObserved` 一经 cell 绑定就是五个 relay，各带一把锁、跟着行一直活着，每个 `asDriver()` 在行显示期间再加一把。[0005](0005-cellvm-appearance-single-observed.md) 早定过这条规矩，但没写进 AGENTS.md，「Cell ViewModel wrapper」一节反而教每个显示属性一个 `@RxObserved`，这里就是照着写的；同批把那一节改掉。cell 逐部分比较是为了保住原来「只有变了的那部分才重设」：运行中的行每秒更新多次，标题、图标、tooltip 与状态位不动。新测试 `ReportCellViewModelTests`（多处改动只发一个事件、重复内容不发事件），临时改成逐字段赋值时两条都红。批量导出的两种行按同一规矩一起改了，记在 0005 的补记里。 |
| 2026-10-08 | 修：别的窗口改了 transformer、语料被驱逐时，经连接的构建不再记成 Failed；构建命令的回复改成结果值 `built` / `cancelled` / `imageNotIndexed` | PR #121 审查 PR121.30：store 替所有订阅者放弃构建时，订阅者收到 `CancellationError`，可它跨连接后只剩一段描述，协调器的 `.failure(is CancellationError)` 分支永远匹配不上，My Mac（经 XPC service）上就多出一条「Failed: …Swift.CancellationError error 1.」。服务端改为回 `.cancelled` 这个值，公开 API 在调用方进程里还原成 `CancellationError`，协调器不用改。复现测试 `FindCorpusCoordinatorRemoteTests.storeCancellationIsNotAFailure` 修前红（状态与历史里各一条 Failed）、修后绿。连接中断时在途构建各记一条 Failed 的同类留给 PR121.05 的「引擎已重置」信号一起做。 |
| 2026-10-08 | 修：Report 的 Cancel 撤回到服务进程；关窗收拢成 `DocumentState.documentWillClose()`，只关已经建过的成员，关掉的文档不再请求语料 | PR #121 审查 PR121.09：撤回只取消了本进程的 Task，My Mac（转发给 XPC service）上服务端照建，下次刷新 coverage 那一行又以 Building 回来，再点 Cancel 什么也不做。PR121.29 的取消协议让撤回经 `cancelRequest` 到达服务端，协调器的撤回路径不用改。关窗：协调器加 `documentWillClose()`，撤回全部请求、停掉事件泵与订阅，此后别的窗口改设置、换引擎都不再让它请求；`DocumentState` 的三个惰性成员改为可选后备存储，`Document.close()` 只调 `documentWillClose()`，不再为了关闭而新建 Find 会话与协调器。复现测试 `FindCorpusCoordinatorRemoteTests.cancelReachesTheServingProcess`（修前取消 5 秒后 service 仍在建，刷新后那一行回来）与 `DocumentStateLifecycleTests`（修前关窗新建了会话、关窗后引擎照建、拨一下开关又请求了两个镜像）。 |
| 2026-10-09 | `ReportNode` 的 `==` 只比标识，`isContentEqual` 递归比较整棵子树；`StatefulOutlineView` 加默认关闭的 `preservesSelectedItemAcrossReloads`，Report 页打开 | PR #121 审查 PR121.53：分叉前三个 workspace 已解析到 RxAppKit 0.6.0，它的重载适配器只在根层问 `isContentEqual`，而 `ReportNode` 只比直接子节点的标识，批次下的镜像行一变（过滤、时钟）大纲就不重载；合成的整树 `==` 又让子树变了的行在 `reloadData` 之后回来是折叠的。改成 RxAppKit 测试里 `DiffNode` 的约定，另把 cell ViewModel 的同一性算进内容（一行换了 cell ViewModel 必须重载，屏上的 cell 才会改绑）。只改身份 `==` 之后先跑了选中那条测试：AppKit 的 `reloadData` 按行号保留选中，最新的批次插在最上面时高亮落到了新批次上，所以加了这个开关——重载前记下选中的项，重载后用 `row(forItem:)` 选回，不滚动；侧栏自己恢复选中，开关默认关。不改用 `.diffable`：它也只对根层出 changeset，类别有内容变化就是 `elementUpdated`，照样退回 `reloadData`。`ReportOutlineBindingTests` 在真实大纲上修前三条全红（过滤后仍是 5 行、类别与批次被折叠、选中丢失），修后全绿；AGENTS.md「Differentiable conformance」补上值类型树节点的约定。 |
| 2026-10-09 | 只有一个镜像的 Always Index 批次失败时，批次行显示这个镜像的失败原因；「是否扁平化」收拢成 `ReportOutline.showsItems(of:)` | PR #121 审查 PR121.56：扁平化之后镜像没有自己的行，它的 `.failed(message:)` 无处显示，批次行只写 "1 of 1 images failed to index"，而这恰恰是用户最需要原因的时候（多半是条目写错了）；旧弹窗列的是 `路径 — 原因`。只在批次已结束时这样显示。`ReportViewModelTests.flattenedAlwaysIndexFailureShowsItsReason` 修前红、修后绿。 |

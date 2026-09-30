# Draft - Report navigator：后台索引与语料构建的状态搬进侧栏

- **状态**: Draft
- **创建日期**: 2026-09-30
- **最后更新**: 2026-09-30
- **关联提案**: [draft-find-navigator](draft-find-navigator.md)（语料构建的状态来源）、[0002-background-indexing](0002-background-indexing.md)（被替换的 toolbar 按钮与弹窗）

## 摘要

toolbar 上的 Background Indexing 按钮和它的弹窗去掉，换成侧栏的第四个分页，照 Xcode 26 的 Report navigator
做：一列条目，后台索引的批次和 Find 语料库的构建各是一类，可展开看每个镜像的状态与进度；有任何一项在跑时，
分页图标带一个活动标记。起因是用户实测（2026-09-30）：5 个镜像索引完，Find 只报「4 images not yet
searchable」，而 4 个语料库其实正在排队构建，App 里没有任何地方能看出来。

## 方案

**布局照用户导出的 Xcode 26 Report navigator view hierarchy 实现**（待用户提供；Find 分页照 Find navigator
的 hierarchy 做过一次，方法相同）。只搬侧栏那一列，不搬 Xcode 选中条目后在编辑区打开的日志页；内容区不加新页面类型。
hierarchy 到手之前本提案不进 Accepted。

- **挂载**：两层侧栏各加第四个 `TabViewItem`，共用同一份状态，与 Find 分页的模式一致（`SidebarRootRoute` /
  `SidebarRuntimeObjectRoute` 各加 `.reports` = `.select(index: 3)`，`SidebarRoute.showReports`，`MainRoute.reports`
  从主菜单到达）。**菜单位置待用户定**：Find 的菜单项在 Edit ▸ Find 里，Reports 不是查找动作；候选是 Navigate 菜单
  （Reveal in Sidebar Navigator 所在）或 View 菜单。
- **列表**：照 AGENTS.md 的表格约定重做，不把弹窗的「枚举节点 + 反查驱动器」原样搬过去——弹窗之所以有
  `batch(for:)` / `item(for:)` 两个逐行驱动器，是 RxAppKit 的 `elementUpdated` 只做 `reloadItem`、不重走 `viewFor`，行内容
  不会更新；语料行的「building(built, total) + 进度条」会撞上同一个问题。改为每行一个 CellViewModel
  （`ReportBatchCellViewModel` / `ReportItemCellViewModel` / `ReportCorpusBuildCellViewModel`，进度与状态是 `@RxObserved`，
  cell 在 `bind(to:)` 里绑定），`ReportViewModel<Route>` 与分组、排序逻辑住在 `RuntimeViewerApplication`。
  大纲用 `StatefulOutlineView`：这是带分组行的 source list，正是 2026-09-27 那份已解决问题描述的行高估算风险形状
  （弹窗当时的「不改」结论是在 320 pt 高、非 source list 下测的）。
- **树的形状待定**（随 hierarchy 定）：语料构建是与索引并列的顶层类，还是挂在 ACTIVE / HISTORY 之下。弹窗现有行为逐条去留：
  Always Index 组跳过批次层直接挂镜像——保留；「Background indexing is disabled」占位 + Open Settings——保留，只盖索引那一类；
  语料那一类同样有自己的开关（`settings.search.isCorpusEnabled`），关着时给「Searchable corpus is disabled」+ Open Settings；
  「No active indexing tasks」空闲文案——改为整页空闲文案（两类都空）；聚合百分比副标题——去掉，进度在条目上；
  动作 Cancel batch / Cancel All / Clear History / Open Settings——保留，Close 随弹窗消失。
- **语料条目**：每个镜像一行，状态 pending / building(built, total) / built / failed / cancelled，构建中带进度条，可取消。
  **取消语义**：只撤回本文档的订阅——别的文档还订着时构建继续；取消不是粘性的，下一个触发源（索引完成、transformer 变化、
  开关切换）会重新请求。行显示 cancelled 进 history，再次请求时回到 pending，写进 UI 文案与测试。
- **语料状态的来源与归属**：`FindCorpusCoordinator` 暴露 `buildStatesByImagePath: [String: RuntimeInterfaceCorpusBuildState]`
  与 `finishedBuilds`（built / failed / cancelled 的历史，newest first，与索引 history 同样封顶），都是 `@RxObserved`，由它发出的
  每个构建请求的 `onProgress` 与任务结果驱动。**进度节流**：store 每 8 个对象报一次，并行打印后 ObjC 这种小对象会报得更密，
  每条都过 XPC、上主线程改字典、连带刷新大纲与分页图标——协调器按索引协调器同样的 16 ms 合并后再发。
  启动与换引擎时先用 `interfaceCorpusCoverage()` 补一次快照，把别的文档已经开始的构建也算进来（本文档对全部已索引镜像
  都有订阅，之后的进度会自己到）；**合并规则**：快照不覆盖本文档请求已经写入的状态；快照里没有完成时间，别的文档先建好的
  镜像放进 `finishedBuilds` 时排在本文档条目之后、不按时间排。**驱逐后状态过期**：store 的预算驱逐与 `evict` 都不发事件，
  `built` 会一直挂着——Reports 页出现时与每次构建结束后重取一次 coverage；让 store 发驱逐事件是后续项。
  Clear History 由 `ReportViewModel` 同时清索引协调器的 history 与 `finishedBuilds`。
- **活动信号只算一处**：`DocumentState` 提供只读的 `reportActivity: Driver<Bool>`（索引协调器的 `aggregateState.hasActiveBatch`
  ∨ 任一语料构建 pending / building）。
- **活动标记的绑定位置**：不在 coordinator 里订阅 Rx 改视图（本仓库只有 `MainCoordinator` 为路由扇出订阅过 Rx，UI 绑定都在
  VC 的 `setupBindings`），改为 `TabViewController` 暴露「按下标绑定活动状态」的入口，订阅挂在它自己的 `disposeBag` 上，
  coordinator 在 `.set` 时把 `documentState.reportActivity` 交进去。标记状态存在 `TabViewController` 里，`setTabViewItems`
  每次重设全部分段图之后重新套上；换图同时换 `setImage(_:forSegment:)` 与 `setAlternateImage`。分段控件的图是模板图，
  带颜色的标记会被着色成单色——标记形状按 hierarchy 与用户确认为准，在这个限制内选。「该不该带标记」的判断是
  `RuntimeViewerApplication` 里的纯函数，测试落在那里——App target 没有单元测试 target。
- **删除**：`BackgroundIndexingToolbarItem`（含其同名标识符常量）、`MainRoute.backgroundIndexing(sender:)`、
  `MainCoordinator` 的 `.backgroundIndexing` 转场、`MainToolbarController` 里的五处（属性、默认与允许标识符列表、
  `itemForItemIdentifier`、常量）、`MainWindowController` / `MainViewModel` 的点击信号、弹窗 VC / VM。测试目录没有引用；
  toolbar 不允许用户自定义，没有持久化配置会因标识符消失出问题。
- **测试**：`ReportViewModelTests`（节点由索引协调器的 batches / history 与语料状态合成；分组与排序；动作转发；Clear History
  清两边；取消后的行状态）、`FindCorpusCoordinatorTests` 加「构建进度与结果反映在 `buildStatesByImagePath` / `finishedBuilds`」、
  「进度合并」、「快照不覆盖已写入的状态」，活动标记判断的纯函数。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-30 | Created as Draft | 用户：「这个可以和后台索引放一起展示，刚好可以把 Xcode 的 Report Navigator 搬过来，toolbar 那个后台索引去掉」。 |
| 2026-09-30 | 只搬侧栏列表，内容区不加详情页 | 用户在提问轮选定。 |
| 2026-09-30 | 分页图标上加活动标记，不在 toolbar 放活动文字 | 用户在提问轮选定；toolbar 按钮今天没有任何进度绑定（提案 0002 写的进度叠层并不存在），去掉它不丢功能。 |
| 2026-09-30 | 落在 `feature/find-navigator`，不进 3.0.0 | 用户：「这些改动有点大，把 Find 以及后续功能都放回原来的分支吧，next 分支 reset 回去，不打算 3.0.0 版本发布这个功能」。 |
| 2026-09-30 | 第一轮审查：逐条列出弹窗行为的去留；语料 history 归 `FindCorpusCoordinator`、Clear History 清两边；活动信号只在 `DocumentState` 算一次；换图接口两张图都换；删掉 App target 的测试承诺；菜单位置交用户 | 原稿漏了 disabled 占位、空闲文案、百分比副标题与 Always Index 扁平化的去留，语料 history 无归属，两层各自合成活动信号会漂移，App target 没有单元测试 target。 |
| 2026-09-30 | 第二轮审查：删除清单补 `MainCoordinator` 转场；列表改 CellViewModel 逐行绑定；语料进度 16 ms 合并；活动标记的订阅放进 `TabViewController` 而非 coordinator，状态在重设分段后重套；写明取消语义、快照合并规则、驱逐后重取 coverage、语料开关的占位；大纲用 `StatefulOutlineView`；树的形状列为待定 | 审查指出弹窗靠逐行驱动器刷新而草案没搬、语料进度会比索引事件更密、coordinator 订阅状态改视图不合本仓库 MVVM-C、驱逐是静默的、语料开关关着时用户看不出为什么搜不到。 |

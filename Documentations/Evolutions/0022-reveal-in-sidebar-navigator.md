# 0022 - Reveal in Sidebar Navigator

- **状态**: Implemented
- **创建日期**: 2026-09-25
- **最后更新**: 2026-09-25

## 摘要

仿 Xcode 的「Reveal in Project Navigator」，加一条命令「Reveal in Sidebar Navigator」（⇧⌘J）：在侧栏的对象列表里
选中内容区正在显示的对象，并把它滚到可见处。侧栏本来就会跟随内容区——`SidebarRuntimeObjectListViewModel` 订阅
`documentState.$selectedRuntimeObject`，换对象时自动滚动、高亮——但只在对象**变化**时触发一次。之后用户把列表滚走、
折叠了父节点或分组、输入搜索词或设了 Filter Scope 把那一行挡住、切到 Bookmarks 分页、或者收起了整个侧栏，就再没有
办法让它重新对准当前对象。这条命令补的就是这件事。只在侧栏当前 image 的范围内揭示：对象属于别的 image 时命令不可用。

## 方案

**入口。** `MainMenuController` 新增顶层菜单「Navigate」，放在 View 与 Window 之间（Xcode 的位置），只有一项
「Reveal in Sidebar Navigator」，快捷键 ⇧⌘J（Xcode 同款，本 App 与 UIFoundation 的标准菜单都没有占用）。动作沿
responder chain 送到 key 文档窗口的 `MainWindowController`，与标签页那几项菜单走同一条路。

**何时可用。** 内容区正在显示一个对象，且它属于侧栏当前 image（`selectedRuntimeObject.imagePath ==
currentImageNode.path`）。判断写成 `DocumentState` 上的只读属性，`MainWindowController.responds(to:)` 据此让菜单项
置灰。空标签页、侧栏停在 image 列表根、或者经链接 / Inspector 跳到了别的 image 的对象，都是置灰。这里的路径比较与
`SidebarRuntimeObjectViewModel.applySpecializationAdded` 里 `parent.imagePath == self.imagePath` 是同一个假设。

**揭示做什么**，按顺序：

1. 侧栏收起时先展开（`MainCoordinator` 对 split view 第 0 项做 CocoaCoordinator 的 `.expand(itemAt:)`）。
2. 侧栏在 Bookmarks 分页时切回对象列表分页（`SidebarRuntimeObjectCoordinator` 已有的 `.select(index: 0)`）。
3. 那一行被搜索词或 Filter Scope 挡住时，清空搜索词、重置 Scope。只在对象确实在这份列表里时才清，找不到就不动过滤条件。
4. 展开它所在的分组（`Objective-C Class` 这类 section 标题可以被折叠）和各级父节点，滚到可见处（已可见就不滚），选中。
5. 键盘焦点移到侧栏列表，之后可以直接用方向键继续浏览。

对象已加载的列表里找不到它时发提示音（`NSSound.beep()`）。列表还在加载时，揭示请求挂起，加载完再执行；再次发出的
请求会取代挂起的那个。

**分层。** 不新增 `SelectionRoute`：揭示不改 `DocumentState` 的任何状态，而 `SelectionRoute` 的每个 case 都是一次状态
变更。链路是 `MainWindowController.revealInSidebarNavigator(_:)` → `MainRoute.revealInSidebarNavigator`（`MainCoordinator`
返回 `.multiple(.expand(itemAt: 0), .trigger(.revealSelectedRuntimeObject, on: sidebarCoordinator))`）→
`SidebarRoute.revealSelectedRuntimeObject`（macOS 专用新 case，转给当前 image 的页面）→
`SidebarRuntimeObjectRoute.revealSelectedRuntimeObject`（先 `.select(index: 0)`，再调列表 ViewModel）→
`SidebarRuntimeObjectListViewModel.revealSelectedRuntimeObject()` 解析出行对应的 cell ViewModel、必要时清掉过滤条件 → 列表
ViewController 展开、滚动、选中、取焦点。清过滤条件（`clearFilter()`）放在基类 `SidebarRuntimeObjectViewModel`，搜索词和
Scope 都归它管；基类 ViewController 收到 `filterCleared` 时把搜索框清空，并把空串并进搜索词输入流，否则之后切换 filter
mode 时 `combineLatest` 会把旧搜索词再送一次。这条命令与现有的自动跟随共用 `findCell(for:in:)` 与
`selectRowBringingIntoView(_:)`，但各走各的信号：自动跟随有 `distinctUntilChanged()`，同一个对象不会再触发第二次。

**先后顺序靠的是这几点**，改动其中任何一层前先看这里：

- CocoaCoordinator 的 `.multiple` 在上一步的 completion 里才执行下一步，而 `.expand(itemAt:)` 的 completion 在展开动画
  结束后才调，所以揭示发生在侧栏已经展开之后。但 `.route(on:to:)` 在**构造**父转场时就调用子 coordinator 的
  `prepareTransition`，所以向 ViewModel 发请求放在子转场的 perform 闭包里，而不是写在 `prepareTransition` 里。
- ViewModel 等的是 `filteredNodes` 的发射，且只认 `loadState == .loaded` 之后的那些：重载时 `.loaded` 先于新 cell 写入
  （同一个 main-actor 块里），按 `loadState` 唤醒会拿旧 cell 去揭示。判断本身再跳一轮主队列，因为清过滤会给
  `filteredNodes` 重新赋值，在同一次发射里重入这个 relay。
- 清过滤是同步的（没有搜索词、没有 Scope 时 `scheduleRefilter()` 走同步快路径），outline 的重载与
  `StatefulOutlineView` 结束过滤时的展开 / 选中恢复都在这一步里做完；ViewController 的揭示处理经 `emitOnNextMainActor`
  晚一轮执行，所以一定落在切分页和这次重载之后，不会被恢复逻辑冲掉。
- 分组是值类型，outline 按相等性（只比 `kind`）找它，与 RxAppKit 的 sections 适配器重载后展开全部分组用的是同一条路。

**验证。** `RuntimeViewerApplicationTests` 里新增两组：`DocumentStateCurrentImageTests`（可用性判断：同 image、别的
image、image 里没有对象、空标签页、image 列表根）；`SidebarRuntimeObjectListViewModelTests` 的六条揭示测试——对象已是
当前选中时照样发出（连发两次都答）、被搜索词挡住时先清再揭示、被 Scope 挡住时同样、列表加载完之前的请求挂起到加载后、
不在列表里时报失败且不清过滤条件、没有当前对象时什么都不发。

2026-09-25 实测（`USING_LOCAL_DEPENDENCIES=1`，独立 scratch 目录）：全量 229 个测试首轮 228 过、1 个失败——「加载前的
请求」那条测试先发请求后订阅，而输出是冷的，请求在没人订阅时就被丢了；改成先同步订阅再发请求后，两组 19 个测试全部
通过。App 里 ViewController 在 `setupBindings` 时就已订阅，不受这个问题影响。两轮前后 Debug 设置文件的 SHA 不变。
App 按 `RunScript.sh` 的步骤（`RuntimeViewer-Debug.xcworkspace`、`RuntimeViewer macOS`、Debug-arm64e，先编并暂存 Catalyst
helper 与模拟器载荷）编译通过，改动的文件没有新警告。展开侧栏、切分页、滚动、焦点属于 AppKit 行为，没有自动化测试；
用户在 App 里试过后同意合入。

**不做。** 对象属于别的 image 时切过去（见决策日志）；image 列表根那一层的选中同步；内容区右键菜单里的入口；iOS 版。
跳到别的 image 的对象后，侧栏上一行的旧高亮会留着，这是现有行为，本提案不动。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-25 | Created as Draft | 用户：「加一个reveal in sidebar navigator，类似xcode的 reveal in project navigator，选中并滚动当前content内容的sidebar item」 |
| 2026-09-25 | 只在侧栏当前 image 内揭示，对象属于别的 image 时命令置灰 | 用户选定。另两个选项被否决：切到对象所在 image 并保留标签页与历史（要新增一条不清空历史的换 image 路由，改 `currentImageNode` 的语义）；走现有的换 image 流程（会关掉所有标签页、清空历史） |
| 2026-09-25 | 在 `feature/reveal-in-sidebar-navigator`（从 `next` 切出）上实现，完成后合回 `next` | 用户选定。依赖 `next` 独有的 `MainMenuController` 与侧栏改动，进不了 `main` |
| 2026-09-25 | 菜单位置、快捷键、清过滤条件、焦点移到侧栏、找不到时发提示音 | 未询问，参照 Xcode 自行决定，写在「方案」里供用户否决 |
| 2026-09-25 | Draft → Accepted → In Progress | 用户批准方案（「ok」），开始实现 |
| 2026-09-25 | In Progress → Implemented，合入 `next`，编号 0022 | 用户在 App 里试过：「可以了，合过来吧」。编号取所有远程与本地分支上提案编号的最大值（0021）加一 |
| 2026-09-25 | 不另写实现说明或使用指南，术语表不加条目 | 下一次改这块要知道的先后顺序已写在本篇「方案」里；「Reveal in Sidebar Navigator」是菜单命令名，不是项目术语 |

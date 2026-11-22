# 2026-11-22 侧栏对象列表的选中过一会儿自己消失：后台索引每个批次结束都把列表整个换新

**调查日期：** 2026-11-22
**修复落地：** 本日。`RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectViewModel.swift`（重载时沿用已列出的
cell、列表没变就不发布、已在屏幕上的列表重载时不切到加载页）、`Sidebar/RuntimeObject/SidebarRuntimeObjectViewController.swift`
（打开 `preservesSelectedItemAcrossReloads`）。回归测试 `SidebarSelectionAcrossEngineReloadTests`（`RuntimeViewerAppUITests`）
**所属分支：** `next`
**Severity：** Major —— 刚进入一个镜像时，侧栏里选中的行隔几秒就丢，后台索引期间反复发生
**触发场景：** 用户反馈：刚进入 image，选中一个 runtime object，过一会儿选中效果消失；不是变灰，是整个选中状态没了；过一段时间
再点就正常了。用户怀疑是焦点被抢

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 对象列表里选中的行，没有任何点击就失去选中（`selectedRow` 为 -1），后台索引跑完之后不再发生 |
| **影响范围** | 侧栏的对象列表与书签页（同一个基类），所有 engine；后台索引在跑时最明显——刚启动、刚开窗口、Always Index |
| **根因** | 每个后台索引批次结束，engine 都重载一次数据（`reloadDataAfterBackgroundIndexing()` → `reloadData(isReloadImageNodes: false)` → `.fullReload`）。对象列表收到后重新取对象，**给每一行新建一个 cell ViewModel**，RxAppKit 的分节适配器随即 `reloadData()`。cell 是按指针判等的 `NSObject`，`NSOutlineView` 认不出原来选中的那一项，选中被清掉；列表自己的「选中跟随当前对象」（`selectCell`）只在文档换对象时触发，重载之后不会再选回去 |
| **不是焦点** | 焦点离开列表时选中画成灰色（`NSTableRowView.isEmphasized` 为假），这次是选中本身没了 |
| **Status** | **Fixed** |

---

## 根因

### 谁在重载

`RuntimeBackgroundIndexingManager.startBatch` 的驱动任务在每个批次结束时调 `engine.reloadDataAfterBackgroundIndexing()`，engine
广播 `.fullReload(isReloadImageNodes: false)`。`SidebarRuntimeObjectViewModel` 订阅了 engine 的 `dataChangePublisher`，
收到 `.fullReload` 时只要没有正在进行的重载就 `scheduleReload()`。a132af9f（2026-05-23）为这里加的守卫只挡住「两次重载同时进行、
后完成的覆盖先完成的」那一种；第一次加载完成之后再来的广播，照样整表重载一遍。

### 重载为什么丢选中

`reloadData()` 把取到的对象逐个包进新的 `SidebarRuntimeObjectCellViewModel`，`filteredNodes` 随之发出新数组，分节适配器
（RxAppKit 0.6.0 的 `RxNSOutlineViewSectionedAdapter`）不做差分，每次都 `outlineView.reloadData()`。新数组里的 cell 与旧的
不是同一个对象，`NSOutlineView` 找不到原来选中的项。`SidebarSelectionAcrossEngineReloadTests` 在修复前实测：列表内容一字未变，
重载之后 `selectedRow` 是 -1，选中被清空，而不是落到别的行上。

`StatefulOutlineView` 早有 `preservesSelectedItemAcrossReloads`，重载前记下选中的项、重载后用 `row(forItem:)` 找回来，但它要求
新树里还是同一个项，而且侧栏一直没打开它——它的说明写着「侧栏自己恢复选中」。侧栏的恢复是 `SidebarRuntimeObjectListViewModel` 的
`selectCell`：`selectedRuntimeObject` 变了才在 `$nodes` 里找对应的 cell，找到一次（`take(1)`）就结束，列表之后换了新 cell 不会再选。

### 为什么过一阵就好了

索引批次都结束之后，engine 不再广播，列表不再重载，这时选中的行就留得住。

## 修复

`SidebarRuntimeObjectViewModel.reloadData()`：

- **沿用已列出的 cell。** 重载取到的每个对象，按 `StableID`（对象的 key 加父节点指纹，顶层为 0）找已列出的 cell，找到就留下它、
  把新对象赋给它（内容变了才重建它下面的行，子行的 cell 同样沿用），找不到才新建。一个 cell 最多被沿用一次。
- **列表没变就什么都不发。** 每个对象都已列出、位置不变、内容相同（`hasSameContent(as:)`），而且这次重载没经过加载页，就不赋值
  `nodes`、不重新过滤，outline 不会重载。经过加载页的重载照旧发布：等 reveal 的订阅要等下一个值。
- **已在屏幕上的列表重载时不切到加载页。** 原来每次重载都先置 `.loading`，超过 0.5 秒就把列表换成进度页，选中和焦点跟着离开窗口。
  现在只有还没有内容可显示的列表（第一次加载、Load now 之后）才显示进度页。

`SidebarRuntimeObjectViewController` 打开 `preservesSelectedItemAcrossReloads`：列表真的变了（例如重载多列出一个对象）时，
outline 照旧整表重载，选中的 cell 还在新树里，按项找回；AppKit 自己只保留行号，或者干脆清掉。

## 验证

- `SidebarSelectionAcrossEngineReloadTests`：真实的私有 engine、真实的 `SidebarRuntimeObjectListViewModel`（对象由测试给定），
  按侧栏的方式绑到 `StatefulOutlineView`，用 `engine.reloadData(isReloadImageNodes: false)` 模拟批次结束。两条：列表不变时选中留在
  原对象上；重载在选中行上方多出一个对象时选中仍在原对象上。修复前两条都失败（`selectedRow` 为 -1），修复后通过。
  没有窗口：选中与重载都是 outline 的数据，开窗口会把测试放到屏幕上。
- `SidebarRuntimeObjectTextFilterTests`「the filter stays in force when the list loads again…」原来靠「重载会造出新 cell」判断重载
  结束，改为让重载多列出一个被过滤条件挡住的对象，等它出现在列表里再断言。
- 在最终代码上按 `--filter Sidebar` 跑两个测试 target：`RuntimeViewerAppCoreTests` 25 个套件 111 条、`RuntimeViewerAppUITests`
  3 个套件 4 条，全部通过。App target 里的那一行没有单独编译（同一属性在 `ReportViewController` 中已这样使用），之后用户在 App
  里看过效果。

## 留着没动的

- 列表变了、同时过滤或 Filter Scope 生效时，`StatefulOutlineView` 在过滤期间不做按项恢复，选中仍可能丢；只发生在重载真的改了
  列表的时候。
- 图像列表（`SidebarRootViewModel`）在镜像树重新发布时同样整表新建 cell；后台索引的重载不重新发布镜像树，进入镜像后这一页也不在
  屏幕上，所以与本问题无关。

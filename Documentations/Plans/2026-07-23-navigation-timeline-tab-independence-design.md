# 导航时间线与 Tab 解耦（Xcode 式全局历史）

- 日期：2026-07-23
- 状态：已实施
- 相关：`351f119a`（tab bar 初版，rebind 语义）、`e4a97fef`（tab 按 identity 匹配）

## 动机

Tab bar 初版（`351f119a`）让所有 tab 共享文档级的一份导航历史，任何 tab
操作（新建、Open in New Tab、切换、关闭）都会把 `selectionStack` 重置为目标
tab 的单条记录。结果是：从 RuntimeObjectList 打开一个新 tab，toolbar 的
back/forward 历史当场清空，切回原 tab 也无法恢复。

## 语义模型

采用 Xcode 式的**全局导航时间线**：历史与 tab 是两个独立机制。

- **时间线**（`DocumentState.selectionStack` + `selectionIndex`）：按浏览顺
  序记录用户看过的每一个对象，无论通过 sidebar 点击、content 链接、
  Open in New Tab 还是切 tab 到达。tab 操作不再清空它。
- **Tab**（`DocumentState.tabs`）：纯展示槽位，每个 tab 冻结一个 `object`，
  不持有自己的历史。
- **`selectedRuntimeObject`**：从「历史光标的计算属性」提升为独立的
  `@Observed` 存储属性，是显示层（content / inspector / sidebar 高亮 /
  toolbar 副标题 / MCP 上报）的唯一数据源。导航路由从光标写入它，tab
  路由从目标 tab 的 `object` 写入它。

### 各路由行为

| 路由 | 时间线 | `selectedRuntimeObject` / 活动 tab |
|---|---|---|
| `push` | 截断 forward 分支后追加（栈顶重复只移光标） | 都改为新对象（写通） |
| `backward` / `forward` / `jump` | 只移光标 | 都改为光标对象（落在活动 tab） |
| `switchTab` | 截断 forward 后记录目标 tab 的对象（同 push） | = tab.object |
| `closeTab`（关活动 tab） | 同 `switchTab`（目标为邻居） | = 邻居对象 |
| `openInNewTab` | 截断 forward 后记录，不清栈 | 新 tab 与 selected 均为该对象 |
| `newTab` | 仅截断 forward，不清栈 | `nil`（placeholder） |
| `switchImage` / `switchEngine` | 清空（对象跨 image 无效） | 重置为单个空 tab |

### 空 tab 的 back 特例

`newTab` 后 `selectedRuntimeObject == nil` 而光标仍停在最近浏览的条目上
（「悬停在时间线之上」）。此时：

- 第一次 `backward` 先回到光标条目本身，而不是跳过它；
- `canGoPrevious` 从 index 0 起就为 true；
- 历史菜单快照用 `currentIndex == items.count` 编码悬停态，back 菜单以光标
  条目为首行；`jump` 允许同 index 跳转以恢复光标条目。

## 关键取舍

1. **切 tab 记入历史**（vs 只截断不记录）：记录后 back 总能按实际浏览顺序
   回退，包括切走前看的对象；不记录则 back 会跳过当前显示对象。选择前者
   （与 Xcode 一致）。
2. **back/forward 落在活动 tab**：回溯到的记录可能产生自其它 tab 的浏览轨
   迹，写通会改写活动 tab 的内容与标题——全局时间线的固有行为，非 bug。
3. **连续重复折叠**：`push` 与切 tab 若目标已在栈顶则只移光标，避免历史菜
   单出现相邻重复行。
4. **`syncActiveTabObject` 写通无需按路由区分**：tab 路由先把
   `selectedRuntimeObject` 设为目标 tab 的对象，写通的「已一致即跳过」
   guard 自然使其成为 no-op；导航路由则借写通更新活动 tab。

## 影响面

- `RuntimeViewerApplication/DocumentState.swift` — 存储属性化、路由重写、
  `rebindHistory` 删除，新增 `cursorObject` / `syncSelectionFromCursor` /
  `truncateForwardBranch` / `pushOntoTimeline` / `rejoinTimeline` /
  `resetHistory`
- `RuntimeViewerApplication/SelectionRoute.swift`、`DocumentTab.swift` —
  文档注释按新语义重写
- `RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift`
  — 高亮观察源由 `combineLatest($selectionStack, $selectionIndex)` 简化为
  `$selectedRuntimeObject`
- `RuntimeViewerUsingAppKit/Main/MainViewModel.swift` — 同上简化；
  `isSavable` 改跟随 `selectedRuntimeObject`（空 tab 禁用导出）；
  `canGoPrevious` 与历史菜单快照加入空 tab 悬停态
- `RuntimeViewerUsingAppKit/Main/NavigationHistorySnapshot.swift` —
  `currentIndex` 允许 `items.count` 悬停态，`backwardItems` 用 `prefix`
- `RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`、
  `Sidebar/SidebarCoordinator.swift` — 注释更新，fan-out 逻辑不变（读
  `selectedRuntimeObject`，语义自动正确）

MCP（`AppMCPBridgeDocumentProvider`）、`ContentCoordinator` /
`InspectorCoordinator` 直接读 `selectedRuntimeObject`，零改动。

## 升级注意

`RuntimeViewer-Debug.xcworkspace` 的 SPM 状态若仍 pin UIFoundation 0.13.2
会在 trait 校验（`TabBar` vs `TabsControl`）处失败且无法自行更新：需同时
更新 workspace `Package.resolved` 的 pin 并删除 DerivedData
`SourcePackages` 中的旧 checkout 与 `workspace-state.json` 条目后重新解析
（同 `e4a97fef` 的处理）。

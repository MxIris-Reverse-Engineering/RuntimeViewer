# 编辑栏路径栏（jump bar）功能地图

- **核对基准**: `2ecf759e`（`next`，提交于 2026-11-13）——下面每个 `file:line` 都对照过这个 commit，之后的改动从这里对账
- **提案**: [`0092-editor-jump-bar`](../Evolutions/0092-editor-jump-bar.md)（Implemented）
- **规则**: 根目录 `AGENTS.md` 里 Manual Loading 与「历史条目可以是镜像」两条；`RuntimeViewerUsingAppKit/AGENTS.md` 的 *Filter fields, filter bars and pop-up paths*（路径项）与 *Editor panes*（两条栏的布局）
- **术语**: 路径栏、镜像页、Manual Loading 见 [术语表](../Glossary.md)

## 这是什么

每个编辑栏（pane）顶部一条 Xcode 式的路径，例如 `My Mac › Dyld Shared Cache › System › … › AppKit › NSView`。点任一段，弹出能替换它的同级项：目录逐层展开；选镜像就在这一栏打开**镜像页**（没索引的先索引，进度显示在这一栏）；选对象就在这一栏打开它。侧栏始终不动。当前标签什么都没打开时不显示这条栏。控件是 AppKitPlus 的 `NSPopUpPathControl`（Xcode `DVTPathControl` 的移植，Find 的模式路径也在用）。

附带的一件事：用户自己触发的加载与索引记进 Report navigator 的第四类 **Manual Loading**。

## 代码在哪

```
RuntimeViewerPackages/Sources/RuntimeViewerApplication/      logic, unit-tested
├── EditorArea/
│   ├── JumpBar/
│   │   ├── EditorJumpBarLocation.swift    what a pane points at: nothing / image / object
│   │   ├── EditorJumpBarChoice.swift      what was chosen + where to open it → SelectionRoute
│   │   ├── EditorJumpBarItem.swift        one path component: source / folder / image / object
│   │   ├── EditorJumpBarItemStore.swift   one per document: builds the tree lazily, reads objects
│   │   └── EditorJumpBarAdapter.swift     ties the store to NSPopUpPathControl
│   ├── EditorPaneBarMetrics.swift         heights and paddings of the tab bar and the jump bar
│   ├── EditorPaneViewModel.swift          jump bar inputs/outputs, tab bar visibility
│   ├── NavigationEntry.swift              a history step: an object, or an image
│   └── EditorArea.swift                   open(_ entry:) puts an image step into a tab's history
├── SelectionRoute.swift                   the .openImage route
├── Content/ContentImageViewModel.swift    the image page: indexing state machine
├── ManualLoading/                         Manual Loading records
└── Reports/                               the Report's fourth category
RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/ImageIndexingProgressView.swift   shared with the sidebar
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/           views
├── EditorArea/EditorPaneViewController.swift   EditorPaneJumpBarView, layout of both bars
├── EditorArea/EditorAreaCoordinator.swift      makes the store, hands it to every pane
└── Content/
    ├── ContentCoordinator.swift                the fourth scene: the image page
    └── ContentImageViewController.swift        the image page's view
```

## 关键流程

### 1. 标签的内容变了，路径跟着变

1. 当前标签历史的当前条目换成 `EditorJumpBarLocation` — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/EditorPaneViewModel.swift:174`
2. 位置是 `.nothing`（空标签）时整条栏隐藏 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/EditorPaneViewModel.swift:185`
3. 视图把位置交给 adapter — `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/EditorPaneViewController.swift:272`
4. adapter 向 store 要路径末端那一项，设成控件的 `selectedItem` — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarAdapter.swift:73`
5. store 找到或建出镜像项与对象项，镜像的对象还没读就顺手读 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarItemStore.swift:108`
6. 只读**已索引**镜像的对象，没索引就等引擎的「已索引」通知；路径栏自己从不触发索引 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarItemStore.swift:312`

### 2. 在菜单里选一个还没索引的镜像

1. 控件回调 adapter：先把选中项放回原位，再按修饰键（⌥ 下一栏、⇧⌥ 新标签）发出 `EditorJumpBarChoice` — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarAdapter.swift:88`
2. 这一栏先拿焦点（`.focusEditorPane`），再发路由 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/EditorPaneViewModel.swift:160`
3. 选择变成 `.openImage(path, in:)` — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarChoice.swift:27`
4. 镜像条目进入标签历史；不发 `.switchImage`，所以侧栏不动 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift:528`
5. 翻成内容路由 `.image` — `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/EditorAreaCoordinator.swift:101`
6. 内容区进入镜像页，每次选择都新建 ViewModel（失败后再选一次就是重试）— `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentCoordinator.swift:124`
7. 已索引直接读对象，否则记进 Manual Loading 再索引 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentImageViewModel.swift:106`
8. 已加载的只建对象，没加载的先加载 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentImageViewModel.swift:180`；只有对端是本 App 自带的服务（`.local`、`.file`）时加载才带进度 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngine+ImageIndexing.swift:43`
9. 引擎报告「已索引」，store 读到对象挂到镜像下，末段「No Selection」的菜单随之有了内容 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarItemStore.swift:332`

### 3. 两条栏怎么摆

1. 标签栏只在某一栏有两个以上标签时显示，各栏一起显示或隐藏 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/EditorPaneViewModel.swift:178`
2. 两条栏的高度与内边距都由 `EditorPaneBarMetrics` 算：控件行 28 点，路径栏底边一条 1 点的线 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/EditorPaneBarMetrics.swift:17`
3. 视图照它排两条栏，各自背后的 scroll pocket 跟着栏一起显隐 — `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/EditorPaneViewController.swift:167`
4. 标签栏隐藏时，关闭按钮挪到路径栏最前面 — `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/EditorPaneViewController.swift:207`

## 地标

- `EditorJumpBarItemStore`：每个文档一份，由 `EditorAreaCoordinator` 惰性建立、交给每一栏（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/EditorAreaCoordinator.swift:32`）。跟随文档的 Engine，镜像列表变了就整棵重建并发出 `treeRebuilt`。功能里最复杂的一块。
- `EditorJumpBarAdapter`：唯一碰 `NSPopUpPathControl` 的地方；路径由 ViewModel 决定，控件只负责显示与报告选择。
- `EditorJumpBarItem`：四种内容；镜像是 document root（菜单里没有子菜单，选中即跳）。
- `ContentImageViewModel`：镜像页的状态 `starting` / `indexing` / `indexed` / `failed`，进度按 `withLoadingPlaceholder` 的时机出现，一闪而过的索引不闪进度。
- `DocumentState.recordingManualLoad(ofImageAt:_:)`（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/ManualLoading/DocumentState+ManualLoading.swift:14`）：所有手动加载都经过它。入口有六个：
  - 侧栏 Load now — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectViewModel.swift:806`
  - 侧栏打开未索引镜像 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift:278`
  - Load Frameworks… — `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:261`
  - 镜像页 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentImageViewModel.swift:113`
  - 内容区（经 `indexImageForUser(at:)`）— `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentTextViewModel.swift:196`
  - Find 交叉引用查询（同上）— `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Find/FindSession.swift:933`
- `ManualImageLoadCoordinator`：按 Engine 共享，放在 `RuntimeEngineBackgroundWork` 里；进行中时算进 `isWorkInProgress`，App 不进 App Nap。

## 测试

都在 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/`：

- `EditorJumpBarTests`：路径怎么构成、菜单列什么、对象读到前后同一个项、未索引镜像等通知、换 Engine 重建、选中后路径放回。
- `EditorPaneBarMetricsTests`：两条栏的高度与控件行居中。
- `EditorPaneViewModelTests`、`EditorAreaRoutingTests`、`NavigationHistoryTests`：显隐规则、`.openImage` 路由、镜像条目进历史。
- `ContentImageViewModelTests`：镜像页的索引状态机。
- `ManualImageLoadTests`：Manual Loading 记什么、不记什么。

## 在做的事

- 提案还没收尾：界面没在 App 里点过，大镜像（SwiftUI 约 1.4 万个对象）的对象菜单有多快也没实测；慢的话改用控件的 popover 呈现（带过滤框）。
- 后续项：成员段（光标所在成员）、⌃4–⌃6 打开各段菜单、Related Items；未聚焦栏的 8 点箭头与灰色图标（要 AppKitPlus 加栏级的激活状态）；工具栏活动显示跟进 Manual Loading。

## 复杂度热点

- **项的身份**：控件按指针比较路径项，所以同一个节点必须始终是同一个对象。对象读到之前先挂在镜像下，读到后保留同一个项、挪到外层类型下面并发出 `itemsMoved` — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarItemStore.swift:358`
- **读对象的竞态**：先问「已索引吗」得到否、索引恰好随后完成时，那次通知会被错过。`imagesIndexedWhileReading` 记下读的途中来的通知，读完发现没索引就再读一次 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarItemStore.swift:315`。时序竞争复现不稳定，没有测试。
- **选中后立刻放回**：控件先自己选中再通知代理，adapter 在回调第一行把当前位置的项放回去，否则会闪一下被选中的项 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarAdapter.swift:89`
- **按规范路径找镜像**：从对象找镜像节点要用 Engine 的规范路径（模拟器的 `DYLD_ROOT_PATH`），镜像树里没有的镜像挂在来源下面 — `RuntimeViewerPackages/Sources/RuntimeViewerApplication/EditorArea/JumpBar/EditorJumpBarItemStore.swift:241`
- **有意与 Xcode 不同的居中**：没有标签栏时控件行放在栏顶与底边线正中，Xcode 是贴着栏顶；栏高仍照 Xcode。理由在提案决策日志。

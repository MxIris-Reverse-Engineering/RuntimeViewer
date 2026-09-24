# 2026-09-24 侧栏点击后高亮变灰、右键菜单要点很多次：焦点停在了导航页面的容器上

**调查日期：** 2026-09-23 ～ 2026-09-24
**修复落地：** 本日。RuntimeViewer 侧：`Base/TabViewController.swift`（把 `preferredFirstResponder` 转交给当前
tab，并挡掉不接受焦点的视图）、`Sidebar/RuntimeObject/SidebarRuntimeObjectViewController.swift` 与
`Sidebar/Root/SidebarRootViewController.swift`（列表在窗口里时指向自己的 outline）。AppKitPlus 侧：提案 0041
（`preferredFirstResponder` 的默认值以视图自己的 `acceptsFirstResponder` 为闸门），已推到 AppKitPlus `main`，
随下一个 AppKitPlus 版本发布
**所属分支：** `next`（AppKitPlus 导航控制器只在 next 这条线上，`main` 仍是 UXKit）
**Severity：** Major —— 侧栏每次导航之后，选中行都画成非激活的灰色，右键菜单时有时无
**触发场景：** 用户反馈 ——「Sidebar 点击后高亮立刻消失，而且右键菜单非常难点，要点很多次才弹出菜单」

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 打开一个镜像后，在对象列表里点行：行被选中，但画成灰色（窗口是 key）；右键行经常不出菜单 |
| **影响范围** | 所有经 AppKitPlus 导航控制器 push / pop / set 进来的页面，只要焦点原本就在导航控制器里面。侧栏最明显，因为每次打开镜像都会 push |
| **根因** | AppKitPlus 的 `NSNavigationController` 在转场结束时把第一响应者设成新页面的 `preferredFirstResponder`，而它的默认值（AppKitPlus 0019，2026-08-19 起）恒为页面的根视图 —— 一个普通容器。**只要第一响应者是表格的某个祖先容器，AppKit 就不会在用户点击行时把焦点交给那张表，右键行也打不开表格的菜单** |
| **Status** | **Fixed** —— RuntimeViewer 让侧栏页面把焦点直接交给列表；AppKitPlus 改默认值，普通容器不再被设成第一响应者 |

---

## 根因

### 谁把焦点放到了容器上

在 `MainWindow` 上用 KVO 监听 `firstResponder`，每次变化打出调用栈，用户照常操作一遍：

```
#1 MainWindow -> StatefulOutlineView        event=leftMouseDown   ← 点根目录，命中的就是 outline 本身
#2 StatefulOutlineView -> NSPLLayerBackedView owner=SidebarNavigationController
       -[NSNavigationController(Transitioning) _beginTransitionWithContext:operation:]   ← 双击打开镜像，push 开始
#3 NSPLLayerBackedView -> NSPLLayerBackedView owner=SidebarRuntimeObjectTabViewController
       -[_NSViewControllerTransitionContext completeTransition:]                         ← push 结束
（之后在对象列表里点了三行：hit-test 都落在 cell 里的 VStackView / Label 上，第一响应者一次也没变）
```

push 开始时导航控制器把焦点暂存在自己的视图上，结束时交给新页面的 `preferredFirstResponder`，也就是
`SidebarRuntimeObjectTabViewController` 的根视图。此后点行，焦点始终停在这个容器上。

### 为什么容器持有焦点会同时毁掉点击取焦和右键菜单

一个纯 AppKit 探针复现了两个症状，不经过 RuntimeViewer、UIFoundation 或 AppKitPlus 的任何代码：窗口里一张
view-based `NSOutlineView`，cell 是嵌套 stack view 里的图标加文字（与 `RuntimeObjectCellView` 同构）。同一个
二进制按 SDK 27 编译、再用 `vtool` 改标为 SDK 26 各跑一遍，macOS 27.0（26A428），窗口为 key：

| 点击前的第一响应者 | 左键点行内文字 | 左键点行尾空白 | 右键点行内文字 |
|---|---|---|---|
| 表格的祖先容器视图 | 行被选中，**焦点不动** | 行被选中，**焦点不动** | **菜单不打开** |
| 窗口本身 | 焦点移到表格 | — | — |
| 表格本身 | — | — | 菜单打开 |

两个 SDK 结果完全相同，所以**这不是 macOS 27 SDK 把控件改走手势识别器的那次点击路由改动**，而是「第一响应者
是祖先容器」这个状态本身的后果。「右键要点很多次才出来」是同一件事：只有当焦点因为别的操作离开了那个容器，
右键才恢复正常。

容器自己也接不住键盘事件 —— 事件只沿响应链往上走，不会进到它包着的表格 —— 所以把焦点交给它没有换来任何
东西。

### 为什么会有这个默认值

AppKitPlus 最初照搬 UXKit，以控制器的 `acceptsFirstResponder` 为闸门；`NSViewController` 继承的是 NO，于是
结果恒为 `nil`，焦点落到窗口上。0019 认为「导航后键盘焦点掉出页面」，把闸门拿掉、改为恒返回页面视图 ——
也就是这次的根因。窗口持有焦点时点表格一切正常（上表第二行），所以 0019 之前反而没有这个问题。

---

## 修复

- **RuntimeViewer**：`TabViewController` 把 `preferredFirstResponder` 转交给当前 tab 的页面，并且不接受焦点
  的视图一律不转交（返回 `nil`，窗口成为第一响应者）—— 这样在 AppKitPlus 发版之前也不会把容器交出去。
  侧栏两个列表页面（`SidebarRuntimeObjectViewController`、`SidebarRootViewController`）在 outline 位于窗口
  里时答 outline：打开镜像、返回根目录之后列表直接有焦点，高亮是强调色，方向键可用。镜像还在加载时
  outline 不在窗口里，答 `nil`，用户点一下行即取得焦点。
- **AppKitPlus**（提案 0041，commit `9b3cd24`）：默认值改为「视图接受焦点才返回它，否则 `nil`」，所有页面、
  所有下游都不再把普通容器设成第一响应者。RuntimeViewer 要在升到包含它的 AppKitPlus 版本之后才用上这一层；
  侧栏不依赖它。

---

## 验证

- AppKitPlus `NSNavigationFirstResponderTests`：push 普通页面后第一响应者是窗口、push 指定了表格的页面后是那张
  表、被取消的 push 同样遵守规则等 6 项；其中「push 普通页面」与「取消 push 留下普通页面」两项在修复前失败、
  修复后通过。全量 2547 项通过；另有 9 项（显示器数为 0、Core Animation 动画完成回调超时）在不含本修复的
  基线上同样失败，是运行环境问题。
- 探针（上表）证明焦点在表格或窗口上时点击取焦与右键菜单都正常。
- RuntimeViewer 侧编译通过。**没有能锁住它的测试缝隙**：App target 没有视图控制器级别的测试 target，回归测试
  落在 AppKitPlus（机制与默认值）。真实 App 里的最终确认由用户运行 Debug 构建完成。

---

## 排查中的弯路

- **窗口不在前台时复现不了。** 起初用 lldb 往后台运行的 App 里注入点击，为了模拟「用户一直在侧栏里操作」先
  手动把 outline 设成了第一响应者 —— 恰好绕开了触发条件，于是连点几次焦点都没丢。真正的前提是焦点**停在
  容器上**，而那只在导航转场之后出现。
- **macOS 27 SDK 的点击路由改动是个诱人的解释**（右键调用栈里就有 `-[NSControl(_NSTracking) rightMouseDown:]`），
  但探针把二进制改标成 SDK 26 后结果一模一样，排除了它。

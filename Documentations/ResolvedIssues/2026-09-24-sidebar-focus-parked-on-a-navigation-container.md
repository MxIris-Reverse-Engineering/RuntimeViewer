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
**后续更正：** 同日。初版在「根因」里写了「与 macOS 27 的点击路由改动无关」，依据是改标 SDK 26 结果不变 ——
那只排除了按 SDK 切换的行为。用户在 macOS 26 上用改动前的代码验证没有这个问题，重查后确认：左键不取焦是
macOS 27 系统（不分 SDK）把表格点击改走手势识别器之后才出现的，见「macOS 26 为什么没有这个问题」

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 打开一个镜像后，在对象列表里点行：行被选中，但画成灰色（窗口是 key）；右键行经常不出菜单 |
| **影响范围** | 所有经 AppKitPlus 导航控制器 push / pop / set 进来的页面，只要焦点原本就在导航控制器里面。侧栏最明显，因为每次打开镜像都会 push |
| **根因** | AppKitPlus 的 `NSNavigationController` 在转场结束时把第一响应者设成新页面的 `preferredFirstResponder`，而它的默认值（AppKitPlus 0019，2026-08-19 起）恒为页面的根视图 —— 一个普通容器。**第一响应者是表格的某个祖先容器时，右键点行内文字打不开表格的菜单；在 macOS 27 上，左键点行也不再把焦点交给那张表**，因为 macOS 27 的表格点击改由手势识别器处理，而它只为 Sidecar 触摸取焦 |
| **系统版本** | macOS 27 起出现，与编译用的 SDK 无关。macOS 26 上表格自己的 `mouseDown:` 每次点击都会取焦，把这个状态掩盖了 |
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

### 容器持有焦点时，左键和右键各发生了什么

一个纯 AppKit 探针复现了两个症状，不经过 RuntimeViewer、UIFoundation 或 AppKitPlus 的任何代码：窗口里一张
view-based `NSOutlineView`，cell 是嵌套 stack view 里的图标加文字（与 `RuntimeObjectCellView` 同构）。同一个
二进制按 SDK 27 编译、再用 `vtool` 改标为 SDK 26，在 macOS 27.0（26A428）和 macOS 26.6.2（25G83）上各跑一遍，
窗口为 key。同一系统上两个 SDK 的结果完全相同；两个系统之间只有左键不同：

| 系统 | 点击前的第一响应者 | 左键点行内文字 | 左键点行尾空白 | 右键点行内文字 |
|---|---|---|---|---|
| macOS 27.0 | 表格的祖先容器视图 | 行被选中，**焦点不动** | 行被选中，**焦点不动** | **菜单不打开** |
| macOS 27.0 | 窗口本身 | 焦点移到表格 | — | — |
| macOS 27.0 | 表格本身 | — | — | 菜单打开 |
| macOS 26.6.2 | 表格的祖先容器视图 | 焦点移到表格 | 焦点移到表格 | **菜单不打开** |
| macOS 26.6.2 | 表格本身 | — | — | 菜单打开 |

- **右键**是「第一响应者是祖先容器」这个状态本身的后果，两个系统一样。「右键要点很多次才出来」也是它：只有当
  焦点因为别的操作离开了那个容器，右键才恢复正常。macOS 26 上用户感觉不到，因为第一次左键点行就已经把焦点
  移进了表格。
- **左键**只在 macOS 27 上不取焦，原因见下一节。

容器自己也接不住键盘事件 —— 事件只沿响应链往上走，不会进到它包着的表格 —— 所以把焦点交给它没有换来任何
东西。

### macOS 26 为什么没有这个问题

两个系统在这条路径上只有一处不同。下面的地址来自 AppKit 反编译（27.0 即本机的 26A428；26.6 取自归档的 dyld
shared cache，与在 26.6.2 上用 lldb 抓到的偏移一致），调用栈来自在两台机器上用 lldb 跑同一个探针。

1. **相同的部分。** 窗口处理鼠标按下时，只在命中视图自己接受焦点时才把焦点交给它（27.0
   `-[NSWindow _handleLeftMouseDownEvent:isDelayedEvent:]` 在 0x1859dbc2c 调 `makeFirstResponder:`，26.6
   `-[NSWindow(NSEventRouting) _handleMouseDownEvent:isDelayedEvent:]` 在 0x184b87a6c，条件相同）。命中测试要
   经过 `-[NSTableView _validateHitTest:]`（两版代码一致）：当前第一响应者是命中视图的祖先时，它原样返回命中
   视图，不改判给表格。所以焦点停在祖先容器上、点中行内文字标签时，命中视图是标签，标签不接受焦点，窗口这一关
   不动焦点。焦点在窗口上时命中会被改判给表格，窗口直接把焦点交给表格 —— 即上表「窗口本身」一行。
2. **macOS 26.6。** 鼠标按下事件照常送到标签的 `mouseDown:`，标签不处理，沿响应链转发到
   `-[NSTableView mouseDown:]`。后者只要窗口是 key、表格接受焦点，就 `makeFirstResponder:self`（0x184c890cc），
   不看当前焦点在谁身上，焦点就此被纠正：

   ```
   -[NSWindow _realMakeFirstResponder:]                ← 参数是 NSOutlineView
   -[NSTableView mouseDown:] + 2956
   -[NSOutlineView mouseDown:] + 76
   （forwardMethod × 4：沿响应链转发）
   -[NSTextField mouseDown:] + 280
   -[NSWindow(NSEventRouting) _handleMouseDownEvent:isDelayedEvent:] + 3696
   ```

3. **macOS 27.0。** 表格在 `-[NSTableView _commonTableViewInit]` 里装上一组手势识别器
   （`_createTableViewGestureRecognizers`），点击由 `NSTableView.tapGestureRecognizer` 接走，`mouseDown:` 根本不
   被调用 —— 在 `-[NSTextField mouseDown:]`、`-[NSControl(_NSTracking) mouseDown:]`、`-[NSOutlineView mouseDown:]`、
   `-[NSTableView mouseDown:]` 上下断点，一次都没命中。处理函数 `-[NSTableView _tapGestureRecognized:]`
   （0x1857f1864）照样选中行，但只有识别器的 `_touchDevice` 非空 —— 也就是点击来自 Sidecar 触摸 —— 时才
   `makeFirstResponder:self`（判断在 0x1857f1d20 ～ 0x1857f1d3c）；鼠标点击时 lldb 打出来是 `nil`：

   ```
   -[NSTableView _tapGestureRecognized:]               ← 识别器 NSTableView.tapGestureRecognizer，_touchDevice 为 nil
   -[NSOutlineView _tapGestureRecognized:] + 232
   -[NSTableView _handleTapGestureRecognizer:] + 156
   -[NSApplication(NSResponder) sendAction:to:from:] + 540
   …
   -[_NSGFGestureEnvironment _updateGestureRecognizer:] + 68
   ```

**这是系统行为，与编译用的 SDK 无关。** 装手势识别器的路径上没有任何 SDK 版本判断，唯一的退出条件是子类覆写
了 `mouseDown:`（`_subclassOverrides_mouseDown`；这时控制台会打出 "Gesture recognizer support has been disabled
because NSTableView subclass … overrides either mouseDown: or mouseDragged:"）。`StatefulOutlineView` 和它的父类
`OutlineView`（UIFoundation）都没有覆写 `mouseDown:`，所以走新路径。

**官方出处。** [TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support)
说 macOS 27 的 AppKit 继续把输入处理统一到手势识别器上；手势识别器不走响应链，按下时从命中视图往上一路收集到
窗口 —— 点在标签上也由表格的识别器处理，就是这个原因；并写明 "For container views such as NSTableView and
NSCollectionView, similar tracking loop fallback paths exist"，即上面那个退出条件。TN3212、
[WWDC26 session 289](https://developer.apple.com/videos/play/wwdc2026/289/) 与 macOS 27 release notes 的 AppKit、
NSGestureRecognizer 两节都**没有**提到「鼠标点击不再让表格成为第一响应者」。

这也解释了时间线：把焦点停在容器上的默认值 2026-08-19 就随 AppKitPlus 0019 进来了，但在 macOS 26 上每次点击
都被表格自己纠正，要到 macOS 27 才暴露出来。

### 为什么会有这个默认值

AppKitPlus 最初照搬 UXKit，以控制器的 `acceptsFirstResponder` 为闸门；`NSViewController` 继承的是 NO，于是
结果恒为 `nil`，焦点落到窗口上。0019 认为「导航后键盘焦点掉出页面」，把闸门拿掉、改为恒返回页面视图 ——
也就是这次的根因。窗口持有焦点时点表格一切正常（上表「窗口本身」一行），所以 0019 之前反而没有这个问题。

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
- **不采用 TN3212 给的退路。** 让 outline 子类覆写 `mouseDown:` 能退回旧路径、找回 macOS 26 的点击取焦，但
  TN3212 和 WWDC26 session 289 都把旧路径定为兼容路径、要求迁走（289：「Prioritize user intent over tracking
  loops」）。让焦点一开始就在列表上、不依赖点击取焦，与新模型一致。

---

## 验证

- AppKitPlus `NSNavigationFirstResponderTests`：push 普通页面后第一响应者是窗口、push 指定了表格的页面后是那张
  表、被取消的 push 同样遵守规则等 6 项；其中「push 普通页面」与「取消 push 留下普通页面」两项在修复前失败、
  修复后通过。全量 2547 项通过；另有 9 项（显示器数为 0、Core Animation 动画完成回调超时）在不含本修复的
  基线上同样失败，是运行环境问题。
- 探针（上表）：焦点在表格或窗口上时，点击取焦与右键菜单都正常。在 macOS 26.6.2 上，焦点停在容器上时左键照常
  取焦、右键同样打不开菜单 —— 左键这一半是 macOS 27 的变化，右键这一半两边一样。
- macOS 27.0 上用 lldb 断在 `-[NSTableView _tapGestureRecognized:]`：每次左键都由
  `NSTableView.tapGestureRecognizer` 触发，`_touchDevice` 为 `nil`，四个 `mouseDown:` 实现从未被调用。
- RuntimeViewer 侧编译通过。**没有能锁住它的测试缝隙**：App target 没有视图控制器级别的测试 target，回归测试
  落在 AppKitPlus（机制与默认值）。真实 App 里的最终确认由用户运行 Debug 构建完成。

---

## 排查中的弯路

- **窗口不在前台时复现不了。** 起初用 lldb 往后台运行的 App 里注入点击，为了模拟「用户一直在侧栏里操作」先
  手动把 outline 设成了第一响应者 —— 恰好绕开了触发条件，于是连点几次焦点都没丢。真正的前提是焦点**停在
  容器上**，而那只在导航转场之后出现。
- **把「改标 SDK 26 结果不变」当成了「与 macOS 27 的点击路由改动无关」。** 右键调用栈里有
  `-[NSControl(_NSTracking) rightMouseDown:]`，一度怀疑是 macOS 27 SDK 把控件改走手势识别器那次改动；探针改标
  SDK 26 后结果不变，就把它排除了。但改标 SDK 只能排除按 SDK 切换的行为（控件那一半，
  `-[NSControl(_NSTracking) mouseDown:]` 里确实有 SDK 判断），排除不了系统本身的变化，而表格这一半恰恰不看
  SDK。初版笔记因此写错了结论，直到用户在 macOS 26 上用改动前的代码验证没有问题才重查。**怀疑是系统行为变化
  时，要在旧系统上跑同一个探针做对照。**

# 2026-09-25 侧栏按住拖动不再逐行选中：macOS 27 的表格拖动只在多选时跟随指针

**调查日期：** 2026-09-25
**修复落地：** 本日，`RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/StatefulOutlineView.swift` 覆写
`mouseDown(with:)`（只调 `super`），回归测试 `StatefulOutlineViewTrackingLoopTests`
**所属分支：** `next`
**Severity：** Minor —— 点选、导航、键盘都正常，但「按住往下拖、拖到哪选到哪、拖出底边自动滚动继续选」这个操作没了
**触发场景：** 用户反馈 ——「26 上鼠标按住向下滑动是可以触发选中事件的，一直向下滑就会一直滚动，你滑到哪就选中哪一行，
现在没有这个功能了」（在 [2026-09-24 的焦点修复](2026-09-24-sidebar-focus-parked-on-a-navigation-container.md)之后注意到，与它无关）

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 在侧栏列表里按住一行往下拖：macOS 26 上选中跟着指针逐行走，拖出底边时列表自动滚动、选中继续跟；macOS 27 上选中停在开始拖动的那一行，列表照样滚动 |
| **影响范围** | 所有单选（`allowsMultipleSelection == false`）、拖动不走拖放的 `NSTableView` / `NSOutlineView`。RuntimeViewer 里是侧栏的镜像列表和对象列表（`StatefulOutlineView`）；可重排的两个书签列表拖动就是拖放，不受影响 |
| **根因** | macOS 27 把表格的鼠标拖动交给 `NSTableView.mousePanGestureRecognizer`，它的处理函数只在 `allowsMultipleSelection` 为真时把选中扩展到指针下的行；自动滚动每一跳里的选中更新也有同样的判断 |
| **系统版本** | macOS 27 起出现，与编译用的 SDK 无关，与第一响应者是谁也无关 |
| **Status** | **Fixed** —— `StatefulOutlineView` 覆写 `mouseDown(with:)`，AppKit 因此不给它装表格的手势识别器，退回 macOS 26 的跟踪循环 |

---

## 根因

地址来自 AppKit 27.0 反编译（本机 26A428，与归档的 dyld shared cache 同一个 UUID），均已对照汇编。

### macOS 27 的拖动路径

1. **装识别器。** `-[NSTableView _createTableViewGestureRecognizers]`（0x1857F9678）给每张表装 7 个识别器，其中
   `NSTableView.mousePanGestureRecognizer` 是一个只收鼠标（`allowedTouchTypes = 0`、`buttonMask = 1`）的
   `NSPanGestureRecognizer`，目标是 `_handleMousePanGestureRecognizer:`（0x1857FA108）。
2. **定模式。** 手势开始时 `_resolveMousePanModeAtBeganForGR:requireModifierForDragSelect:`（0x1857F9EF0，鼠标
   路径传 `NO`）决定这次拖动是什么：数据源实现了拖放写入方法、且按在行的拖动区里 → 拖放；否则 → 拖动选中。
   侧栏两个普通列表的数据源（RxAppKit 的 `OutlineViewAdapter`）不实现拖放，走拖动选中；可重排的书签列表走拖放，
   不受这个问题影响。
3. **拖动选中。** `-[NSTableView _handleDragSelectionGestureRecognizer:]`（0x1857FA234）：
   - 开始：`_userClickRow:…` 选中**识别那一刻**指针所在的行，记下此时的选中；
   - 拖动中：先读 `_tvFlags` 的第 27 位（0x1857FA428 `LDRB W8, [X8,#3]` / `TBZ W8, #3`），为 0 就跳过
     `_extendSelectionToRow:fromSelection:modifierFlags:`。这一位就是 `allowsMultipleSelection`：它的 getter
     （0x1851D8BE8）是 `LDRB W8, [X8,#3]` / `UBFX W0, W8, #3, #1`。之后**无条件**
     `_startAutoscrollWithGestureRecognizer:onTick:`，起一个 0.05 秒的 `NSTimer`；
   - 结束：发送 `action`，停止自动滚动。
4. **自动滚动。** 每一跳 `_dragSelectAutoscrollTickForGR:`（0x1857F14F4）先 `autoscrollForGestureRecognizer:`
   滚动，再做同样的多选判断才更新选中。

所以单选表格里，选中定在拖动开始的那一行；指针越过边缘时列表照样滚，选中不动。

**退出条件。** 装识别器的路径上没有 SDK 判断。唯一的退出条件是子类覆写了 `mouseDown:`：
`_subclassOverrides_mouseDown`（0x1857F9BDC，`_NSSubclassOverridesSelector(NSTableView, [self class], mouseDown:)`）
为真时，`_installTableViewGestureRecognizersIfNeeded`（0x1857F952C）一个识别器都不装，并以 error 级别打一次日志
"Gesture recognizer support has been disabled because NSTableView subclass %@ overrides either mouseDown: or
mouseDragged:"（是否打过记在实例自己的 `_tvFlagsExtra` 里，所以是每个实例一次）。这就是 TN3212 说的
"For container views such as NSTableView and NSCollectionView, similar tracking loop fallback paths exist"。

### macOS 26

拖动由 `-[NSTableView mouseDown:]` 的跟踪循环处理：单选时把选中移到指针下的行，拖出边缘时滚动并继续选中。
这一侧只有下面的实测，没有反编译跟踪循环。

---

## 实测

一个纯 AppKit 探针，不经过 RuntimeViewer、UIFoundation 或 RxAppKit 的任何代码：窗口里一张 view-based
`NSOutlineView`，60 行，cell 是嵌套 stack view 里的图标加文字，与 `RuntimeObjectCellView` 同构；文字标签按
UIFoundation `Label` 的方式创建和配置（`init(frame:)`、自定义 cell 类、不可编辑、无背景、无边框），实测不可选、
不接受焦点。用 `NSApp.postEvent` 发合成事件：`leftMouseDown` 按在某行文字上，之后每 80 毫秒一个
`leftMouseDragged`，最后 `leftMouseUp`，每次拖动之后记下选中。同一个二进制在 macOS 26.6.2（25G83）与
macOS 27.0（26A428）上各跑一遍，窗口为 key：

| 用例 | macOS 26.6.2 | macOS 27.0 |
|---|---|---|
| 单选，焦点在容器；按第 2 行，依次拖过第 3～7 行 | 选中依次为 3 4 5 6 7 | 选中依次为 3 3 3 3 3 |
| 单选，焦点在列表；同上 | 3 4 5 6 7 | 3 3 3 3 3 |
| 多选，焦点在列表；同上 | 扩展为 2…7 | 扩展为 3…7 |
| 单选，子类覆写 `mouseDown:`；同上 | 3 4 5 6 7 | 3 4 5 6 7 |
| 单选；按第 10 行，拖过第 12、14、16 行，再停在列表下方 1 秒 | 滚动 742 pt，选中到第 47 行 | 滚动 570 pt，**选中停在第 12 行** |
| 同上，子类覆写 `mouseDown:` | 滚动 742 pt，选中到第 47 行 | 滚动 758 pt，选中到第 47 行 |

- **与焦点修复无关**：焦点在容器（修复前的状态）和在列表（修复后）结果相同，两个系统都是。
- **合成拖动确实驱动了识别器**：多选对照组在 27 上逐步扩展。27 上普通 outline 有 7 个识别器，覆写
  `mouseDown:` 的子类是 0 个。
- **与 SDK 无关**：同一个二进制用 `vtool` 改标为 SDK 26，在 27 上的输出逐字相同。
- 27 上按在第 2 行、选中却落在第 3 行：手势在第一次拖动之后才被识别，开始时取的是那时的指针位置。真实拖动的
  第一段位移只有几个点，通常仍在按下的那一行里，所以用户看到的是「停在按下的那一行」。

---

## 修复

- **`StatefulOutlineView` 覆写 `mouseDown(with:)`，只调 `super`。** AppKit 因此不给它装表格的手势识别器，整张表
  退回 macOS 26 的跟踪循环：拖动时选中跟随指针，拖出边缘自动滚动并继续选中。侧栏四个列表都用它，一起退回：
  镜像列表和对象列表找回拖动选中；两个书签列表的拖动排序也改由跟踪循环处理，与 macOS 26 相同。
- **顺带找回点击取焦。** 跟踪循环里的 `-[NSTableView mouseDown:]` 每次点击都让表格成为第一响应者，
  [2026-09-24](2026-09-24-sidebar-focus-parked-on-a-navigation-container.md) 那次「macOS 27 上左键点行不取焦」对这
  两个列表也就不再成立。那次加的 `preferredFirstResponder` 保留：导航一结束列表就有焦点，不点也能用方向键；
  「焦点停在容器上时右键点行内文字打不开菜单」两个系统都有，与手势路径无关，也仍然靠它避免。
- **代价。** 这是 TN3212 定的兼容路径。这两个列表收不到原生的 Sidecar 触控，触摸只能经系统的鼠标模拟到达；
  将来 AppKit 只在手势路径上做的改进也用不上。每个实例创建时控制台有一条上面那句 error 级日志，属预期。
- **为什么不在手势路径上补。** 表格的拖动识别器与它的处理函数都是私有的，没有公开的挂点。要保留手势路径，只能
  自己再加一个 pan 识别器、和私有识别器同时识别，并在每一跳自动滚动之后按指针位置重选一行 —— 代码多、依赖私有
  识别器的行为，换来的只是 Sidecar 触控。覆写 `mouseDown:` 三行代码，原样恢复 26 的行为。
- **推翻了前一天的决定。** 2026-09-24 那篇因为「让焦点一开始就在列表上」在手势路径上就能解决点击取焦，明确不采用
  这条退路。拖动跟随没有这样的解法，所以这次采用；那篇已补注。

---

## 验证

- **回归测试** `StatefulOutlineViewTrackingLoopTests`（`RuntimeViewerApplicationTests`，只在 macOS 27 及以后运行）：
  先确认普通 `NSOutlineView` 装有 `NSTableView.mousePanGestureRecognizer` —— 这些名字是私有的，AppKit 哪天改名，
  测试会在这一步失败，而不是什么都不查就通过 —— 再断言 `StatefulOutlineView` 一个 `NSTableView.*` 识别器都没有。
  不带覆写时失败，`StatefulOutlineView` 身上是全部 7 个（swipe、longTouchPress、dragTouch、mousePan、
  extendSelection、tap、doubleTap）；带上覆写后通过，同一次运行里 `StatefulOutlineViewAutosaveTests` 的 5 项照常
  通过。不用合成拖动做测试：那要求窗口是 key，测试进程保证不了。
- **构建方式**：next 眼下按远程依赖解析编不过（`RuntimeViewerCore` 用到的 `ObjCImplementationClasses` 找不到），
  测试用 `USING_LOCAL_DEPENDENCIES=1` 走 `.worktrees/` 下的本地 checkout，在独立的 scratch 目录里编。
- **探针**（上表）：覆写 `mouseDown:` 的子类在 macOS 27 上恢复逐行跟随，拖出底边时自动滚动并继续选中。
- 真实 App 里的确认由用户运行 Debug 构建完成。

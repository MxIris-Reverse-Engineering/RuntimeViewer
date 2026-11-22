# 2026-11-22 macOS 26 上开不了新窗口、开文件后随机闪退：独立 scroll pocket 发了 macOS 27 才有的消息

**调查日期：** 2026-11-22
**修复落地：** UIFoundation 0.50.1（`ScrollPocketView` 先查 AppKit 有没有再发），RuntimeViewer 抬到 0.50.1，随 3.0.0-beta.11 发布
**Severity：** High —— macOS 26 上 3.0.0-beta.10 开不了任何文档窗口，开文件之后还会随机闪退
**触发场景：** macOS 26.6.2（25G83）、原生 arm64 与 Rosetta 下的 3.0.0 beta.10（build 20261121.23.41）：欢迎窗口里按 ⌘N、点 File › New，或 ⌘O 选中文件后点 Open

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 新窗口不出现，仍停在欢迎窗口，AppKit 记 `-[NSScrollPocket setAllowsSeparator:]: unrecognized selector sent to instance`，进程还在。另有三份崩溃报告：主线程 `EXC_BAD_ACCESS`（SIGSEGV），栈顶是 `swift_task_isCurrentExecutorWithFlagsImpl` → `SerialExecutorRef::isMainExecutor()` → `swift_getObjectType` / `SerialExecutor._isSameExecutor`，出事地址是 `0x88`、`0x48`、`0xffffa058` 这类垃圾值；一次在打开面板变成 key window 时的通知里，一次在 ⌘N 的 `Document.init` 里，一次在 Dock 点击的 reopen 里 |
| **影响范围** | 3.0.0-beta.10 的全部 macOS 26 用户（26.0 到 26.7）。beta.9 没有这段代码；macOS 15 不建独立 pocket，macOS 27 有这两个方法，都不受影响 |
| **根因** | UIFoundation 0.50.0 的 `ScrollPocketView` 初始化时直接设 `NSScrollPocket.allowsSeparator`，这个属性和 `backdropGroupName` 都是 macOS 27 才加的。编辑区工具栏下的那块 pocket（`ToolbarScrollPocketContainerView`）和每个编辑栏后面的 pocket（`EditorPaneViewController`）在 `#available(macOS 26.0, *)` 下建，于是在 macOS 26 上每建一个窗口都抛 Objective-C 异常 |
| **Status** | **Fixed** —— UIFoundation 0.50.1 两个属性都先查 `responds(to:)`，私有头文件把它们标成 macOS 27 起可用；RuntimeViewer 清单下限与四份锁文件抬到 0.50.1 |

---

## 根因

### 开不了窗口

- **只有 macOS 27 的 `NSScrollPocket` 有这两个成员。** 逐版类导出（`ipsw class-dump`，26.0、26.3、26.6、27.0）：26.x 的 pocket
  有 `edge`、`style`、`captureView` 和私有的 `_showSeparatorsOnHardPocket`，没有 `allowsSeparator`，也没有 `backdropGroupName`；
  27.0 起两者都有。26.6、26.7 的整个 shared cache 里根本没有 `setAllowsSeparator:` 这个字符串。
- **私有头文件把整个类标成 macOS 26 起可用。** `NSScrollPocket.h` 只在类上写了 `API_AVAILABLE(macos(26.0))`，成员没有单独标，
  编译器就不会要求 `#available(macOS 27.0, *)`。UIFoundation 的其余私有封装都先查 `instancesRespond(to:)`（它的
  `ScrollPockets.md`「坑」一节写明了这条），只有 0.50.0 新加的 `ScrollPocketView` 漏了。
- **异常被 AppKit 接住，窗口就没了。** ⌘N 走 `newDocumentWithoutPointerAnimation(_:)`，在菜单动作里同步建窗口；异常一路展开到
  `-[NSApplication run]`，被它记下后继续跑，所以进程活着，只是 `makeWindowControllers()` 没做完。

### 随后的闪退

- **崩溃栈说明主线程上留着一份失效的执行器记录。** 反汇编 26.6 的 `swift_task_isCurrentExecutorWithFlagsImpl`：偏移 +72 是
  `currentExecutor.isMainExecutor()` 的返回点，而 `currentExecutor` 取自 `ExecutorTrackingInfo::current()`（线程局部变量）。
  三份报告里，这次检查都发生在普通的菜单动作、通知回调或 Apple Event 里，栈上没有任何 Swift 任务在跑，这份记录本该为空；
  它非空、指向的内容又是垃圾，只能是某个早已返回的任务留下的，指向的栈帧已经被别的调用覆盖。
- **开文件时窗口是在 Swift 任务里建的。** `DocumentController.openDocument(withContentsOf:display:completionHandler:)`
  把文件交给 `FileController`，在 `Task { … }` 里 `await` 打开，再 `makeWindowControllers()`。主线程执行这个任务时，运行时在
  `swift_job_run` 的栈帧上装好执行器记录；异常从建窗口处直接展开出 `swift_job_run`，跳过了卸下记录的那一步（运行时不带
  C++ 异常的清理），线程局部变量就一直指着那块已经失效的栈。之后主线程上任何一次「是否在主线程」的检查（`@MainActor` 闭包
  的入口检查、`MainActor.assumeIsolated` 等）都去读它：内容碰巧还像个执行器就过，不像就崩。所以闪退是随机的、晚于异常的，
  ⌘N 这种同步路径只抛异常、不留后遗症。
- **一条异常、两种现象。** 反馈者没能确认那两次闪退与这条异常有关；上面的机制把它们连上了：同一个异常在同步路径上只让窗口
  消失，在任务里还会弄坏并发运行时的状态。

## 修复

UIFoundation 0.50.1：

- `ScrollPocketView.allowsSeparator` / `backdropGroupName` 的读写和初始化里那一次设置，都先查 pocket 的 `responds(to:)`；
  macOS 26 上分别读回 `false` 和 `nil`、赋值不起作用。
- `NSScrollPocket.h` 把这两个属性标成 `API_AVAILABLE(macos(27.0))`，以后谁直接用，编译器都会要求 `#available`。
- 回归测试 `ScrollPocketTests`「A scroll pocket view leaves alone the members macOS 26's pocket lacks」：用 Objective-C 运行时
  造一个 `NSScrollPocket` 子类（像 KVO 造子类那样；Swift 子类不行，AppKit 的 pocket 是 Swift 写的，Swift 子类会在 AppKit 的
  初始化里崩），照 macOS 26 回答 `responds(to:)` 与 `instancesRespond(to:)`，并记下发给缺失成员的每条消息。修复前记下
  `setAllowsSeparator:` 两次、`setBackdropGroupName:` 一次，修复后为空。整套 `ScrollPocketTests` 19 条在 MacBook 上通过，
  全部 trait 的构建在 Ultra 上通过。

RuntimeViewer：`RuntimeViewerPackages/Package.swift` 的下限、两个 workspace 与两个包的四份锁文件抬到 0.50.1，`AGENTS.md` 的
依赖下限一段写明原因。

## 横向排查

对 beta.10 发布包里的每个 Mach-O，取它 `__objc_methname` 里的选择器名，与 macOS 27.2 和 26.6 两个 shared cache 里所有像选择器的
字符串比较：在 27.2 里有、26.6 里没有的共 96 个，去掉发布包自己定义的方法后剩 47 个。逐个对照源码：

- 真正发给系统对象、又没有防护的只有 `allowsSeparator` / `setAllowsSeparator:` 这一处。
- AppKitPlus 0.23.0 的 `preferredImageVisibility`（`NSMenuItem`）与 `effectIsInteractive`（`NSGlassEffectView`）都在
  `@available(macOS 27.0, *)` 里；`_applicableImageWithLogging:` 先查 `respondsToSelector:`。
- 其余是发布包自己的属性名、动作名或它实现的委托方法，碰巧与 macOS 27 某处重名。

`backdropGroupName` 的选择器在 26.6 里别的类上就有，这个办法查不出来，是对着 26.6 的类导出看出 `NSScrollPocket` 没有它的；
RuntimeViewer 没有调用它，修复照样补上了防护。

## 没做的验证

- **没有在 macOS 26 上实测修复。** Ultra 与 MacBook 都是 macOS 27.2，也没有 macOS 26 的虚拟机；修复只在 27.2 上用模拟 26 的
  pocket 测过。beta.11 发出后要请反馈者在 macOS 26 上确认：⌘N 与 ⌘O 都能开窗口，开过文件之后不再闪退。
- **macOS 26 上独立 pocket 的样子没看过**：分隔线画不画由 26 的 AppKit 自己决定（它只有私有的 `_showSeparatorsOnHardPocket`）。

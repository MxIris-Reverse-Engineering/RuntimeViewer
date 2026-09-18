# 2026-09-18 Debug-arm64e 装不上 helper daemon：变体标志翻得比窗口恢复晚

**调查日期：** 2026-09-18
**修复落地：** 本日，分支 `next`
**Severity：** Medium —— 只影响 Debug-arm64e，且只在「上次退出时留着文档窗口」的那些启动中出现；一旦中招，Settings 里的 Install 按钮整个会话都装不上 daemon，而状态行看起来完全正常
**触发场景：** Debug-arm64e 构建的 App，上次退出时有打开的文档窗口（macOS 会恢复它）；到 Settings 点 Install

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | Settings 的 Helper Service 一行报 `Operation failed: The operation couldn't be completed. Unable to read plist: dev.mxiris.runtimeviewer.service.plist`；但 App bundle 里只有 `dev.arm64e.mxiris.runtimeviewer.service.plist`，而状态行显示的又是正常的 "Service is not installed." |
| **影响范围** | 仅 Debug-arm64e；Release 的服务名是编译期常量，Debug（非 arm64e）本来就用那个名字，都不受影响 |
| **根因** | `runtimeViewerIsARM64EVariant = true` 写在 `applicationDidFinishLaunching` 里，而窗口恢复跑在它**之前**；恢复出来的文档窗口一路解析到 `HelperServiceManager`，它的 installer 把当时（还是 `false`）算出来的 plist 名存进了一个 `SMAppService` 对象，此后整个进程都用那个对象装 daemon |
| **Status** | **Fixed** —— 标志改到 `AppDelegate.main()` 最前面；`RuntimeViewerCommunication` 现在会检测「名字发出去之后才翻标志」并 assert |

---

## 现象

Debug-arm64e 的 App，打开 Settings → Helper Service，点 Install：

```
Helper Service
Operation failed: The operation couldn't be completed. Unable to read plist:
dev.mxiris.runtimeviewer.service.plist                                [Install]
```

两处不对劲：

1. App bundle 的 `Contents/Library/LaunchDaemons/` 里只有一个文件，叫 `dev.arm64e.mxiris.runtimeviewer.service.plist`。报错里那个名字（少了 `arm64e.`）是**非 arm64e** 变体的，bundle 里根本没有。
2. 可状态行显示的是 "Service is not installed." —— 如果名字真的错了，状态查询也该一起错。

第 2 点是这个 bug 难找的全部原因：`HelperServiceManager` 里查状态走的是 `Self.helperServiceDaemon`，一个**每次现算**的 computed property，所以它永远用对的名字；只有 install / uninstall / reinstall 走 `installer`，而 `installer` 是 `init` 里建好存起来的。

## 根因

### 标志本身是对的，是翻得太晚

先排除了最容易怀疑的两件事：`RUNTIMEVIEWER_ARM64E` 这个编译条件在工程级 `Debug-arm64e` 配置里定义着（所有 target 继承），反汇编 `applicationDidFinishLaunching` 也能看到对全局变量的写入。挂到跑着的 App 上直接读那个全局变量：

```
(lldb) memory read -s1 -fu -c1 0x10B9E24D0     # runtimeViewerIsARM64EVariant
0x10b9e24d0: 1
```

是 `true`。可同一个进程里，`HelperServiceManager` 的 installer 存的却是：

```
(lldb) expr -l swift -O -- Mirror(reflecting: <installer>).children…
- "daemon = LaunchDaemon(dev.mxiris.runtimeviewer.service.plist)"
```

两者矛盾只有一种解释：installer 是在标志翻成 `true` **之前**建的。

### 谁在那之前把它建了出来

在 `HelperServiceManager.shared` 的一次性初始化函数上下断点，拿到完整调用链：

```
AppDelegate.main()                              AppDelegate.swift:43
  └ NSApplication.run()
      └ -[NSApplication _handleAEOpenEvent:]           ← open-application Apple Event
          └ NSPersistentUIManager restoreAllPersistentState…
              └ +[NSDocumentController restoreWindowWithIdentifier:…]
                  └ Document.makeWindowControllers()           Document.swift:20
                      └ MainCoordinator.init                   MainCoordinator.swift:35
                          └ MainWindowController.setupBindings MainWindowController.swift:99
                              └ MainViewModel.transform        MainViewModel.swift:301
                                  └ @Dependency(\.runtimeEngineManager)
                                      └ RuntimeEngineManager.observeDaemonAvailability()
                                                               RuntimeEngineManager.swift:321
                                          └ @Dependency(\.helperServiceManager)
                                              └ HelperServiceManager.init()
                                                               HelperServiceManager.swift:91
```

**窗口恢复由 `NSApplication.run()` 内部的 open-application Apple Event 驱动，落在 `applicationDidFinishLaunching` 之前。** 恢复出来的文档窗口建 coordinator，coordinator 建 `MainViewModel`，`MainViewModel.transform` 解析 `RuntimeEngineManager`，后者在 `init` 里订阅 daemon 可用性通知，于是解析 `HelperServiceManager`，于是 `SMAppServiceDaemonInstaller(plistName: "dev.mxiris.runtimeviewer.service.plist")`。

等 `applicationDidFinishLaunching` 终于跑到第一行、把标志翻成 `true`，installer 已经存好了。

所以：**没有窗口可恢复的那些启动（干净启动、或上次退出时没开窗口）是正常的**，这也是为什么它不是每次都复现。

### 另外三个入口点都没这个问题

daemon 写在 `main.swift` 的顶层语句，注入用的 server 写在 `RuntimeViewerServer.main()` 第一行，Catalyst 插件写在 `AppKitPluginImpl.init()` 第一行 —— 都在各自进程的最早期。只有 App 把它放进了生命周期回调。

## 修复

### 1. 标志移到 `AppDelegate.main()` 最前面

`AppDelegate` 自带 `@main` 和 `static func main()`，项目里本来就把「必须抢在 AppKit 之前」的一次性设置放在那儿（`SystemAutoFillMenuSuppression` 是既有的例子）。变体选择现在是那里的第一条语句，早于 `NSApplication.shared`、早于主菜单、早于 `run()`。

### 2. 「发出去之后才翻」现在会当场报错

光把它移早，挡不住下一个人再移回去，也挡不住有谁在更早的位置读名字。`RuntimeViewerCommunication` 里那对全局变量改成了一个值类型 `RuntimeViewerVariantSelection` 的门面：它记住名字有没有被读出去过，一旦在那之后收到一个**不同**的变体选择，就通过 `runtimeViewerLateVariantSelectionHandler` 报出来，默认实现是 `assertionFailure`。诊断信息里带上「已经发出去的是哪个名字」，因为那才是要去追的线索。

重复选同一个值、以及压根不选（非 arm64e 构建的常态）都不报，避免误报。整块仍然是 `#if DEBUG` 的，Release 的服务名还是编译期常量。

一个附带后果：**读名字现在会写状态**（每个读者都要留下「名字已发出」这个记号），所以那个全局状态加了锁 —— 原来它是 `nonisolated(unsafe)` 的裸 `Bool`，无同步也没关系，现在两个线程同时第一次读就可能把记号丢掉，检测跟着失效。读名字不在任何热路径上（XPC 建连、装 daemon 时才读），这点开销无所谓。

### 3. 回归测试

`RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/VariantSelectionOrderingTests.swift`，6 条，针对 `RuntimeViewerVariantSelection` 这个值类型，所以不碰进程级状态、可并行。

**说明一下测试覆盖的边界**：启动顺序本身（窗口恢复早于 `applicationDidFinishLaunching`）是 AppKit 的行为，没法在单元测试里重建，所以测试覆盖的是**检测机制**，不是顺序。红绿验证方式是把检测条件短路掉（`arrivesTooLate = false && …`），确认「读之后翻转要被报出来」那条测试确实失败：

```
􀢄  Test "Selecting the arm64e variant after a read is reported, and names what was handed out"
    recorded an issue: Expectation failed: (diagnosticMessage → nil) != nil
EXIT=1
```

恢复后 194 条通信模块测试全绿。

### 验收

单元测试覆盖不到启动顺序，所以修复本身是在构建产物上验收的。

变体选择现在是进程里最早执行的几条语句之一 —— 断点命中时整个调用栈只有三层，`SystemAutoFillMenuSuppression` 都还没轮到：

```
frame #0: runtimeViewerIsARM64EVariant.setter(newValue=true)  RuntimeRequestResponse.swift:29
frame #1: static AppDelegate.main()                           AppDelegate.swift:43
frame #3: main
```

而 installer 现在拿到的是对的名字（修复前这里是 `dev.mxiris.runtimeviewer.service.plist`）：

```
(lldb) breakpoint set --file SMAppServiceDaemonInstaller.swift --line 14
frame #0: SMAppServiceDaemonInstaller.init(plistName="dev.arm64e.mxiris.runtimeviewer.service.plist")
```

## 排除过的假设

记下来省得下次重走：

- **`RUNTIMEVIEWER_ARM64E` 没定义 / 没传到 App target** —— 解析 `project.pbxproj` 确认工程级 `Debug-arm64e` 配置里有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG RUNTIMEVIEWER_ARM64E $(inherited)"`，八个 target 全部继承；反汇编 `applicationDidFinishLaunching` 能看到对 `…IsARM64EVariantSbvau` 的调用。
- **`#if DEBUG` 在 SwiftPM 包里没生效，走了 Release 的常量分支** —— 包侧符号表里有 `runtimeViewerIsARM64EVariant`，说明走的是 DEBUG 分支。
- **进程里有两份 `RuntimeViewerCommunication`，各自一个全局变量** —— bundle 内含该服务名字符串的二进制有 6 个，但 App 进程只加载其中一个（主 dylib），另外几个分属 daemon / CLI / 注入 payload / Catalyst 插件，都是别的进程。
- **bundle 里缺 plist，或 plist 名字生成错了** —— `Contents/Library/LaunchDaemons/` 里正好一个文件，名字和 `Label` / `MachServices` 三处一致，全是 arm64e 的。

## 相关

- `Documentations/ResolvedIssues/2026-09-09-catalyst-helper-wrong-daemon.md` —— 同一个变体标志的另一种翻车方式：Catalyst helper 当时压根没翻它，于是和 App 连到了不同的 daemon。那次的结论是「第四个入口点也得翻」，这次的结论是「翻的时机也算入口点的一部分」。

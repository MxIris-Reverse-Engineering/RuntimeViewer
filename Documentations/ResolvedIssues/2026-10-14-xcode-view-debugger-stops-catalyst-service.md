# 2026-10-14 从 Xcode 调试运行时看不到「My Mac (Mac Catalyst)」：Xcode 的视图调试库让 Catalyst service 起不来

**调查日期：** 2026-10-14
**处理落地：** 本日，`next`（文档；问题不在本仓库的代码里）
**Severity：** Medium —— 只影响从 Xcode 带调试器运行；发布版、`RunScript.sh`、从 Finder 打开都不受影响
**触发场景：** 合入 [0051](../Evolutions/0051-catalyst-xpc-service.md) 后，在 Xcode 里 Run「RuntimeViewer macOS」

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | `RuntimeViewerCatalystService` 进程在，「My Mac (Mac Catalyst)」始终不出现，也没有「Mac Catalyst Runtime Unavailable」通知。`sample` 显示 service 的主线程停在 `dyld4::prepare` → `dyld4::halt` → `abort_with_payload`，`main` 一行没跑 |
| **影响范围** | 从 Xcode 带调试器运行 App 时的 Catalyst service。App 等的 `hello` 永远等不到回复：进程被调试器扣着、没有退出，连接收不到中断 |
| **根因** | Xcode 调试 App 时会自动附加到它内嵌的 XPC service，并把 App 会话算好的 `DYLD_INSERT_LIBRARIES` 原样给它，里面有 macOS 版视图调试库 `libViewDebuggerSupport.dylib`。这个库在 Mac Catalyst 进程里缺符号，dyld 在 `main` 之前中止进程 |
| **Status** | **Worked around** —— 每台机器设一次 Xcode 的 user default `DBGViewDebuggerInsertDylibOnDemand`，Xcode 就不在启动时注入视图调试库，改为抓视图层级时按需载入。写进了 `README.md` 的 Troubleshooting 与 `AGENTS.md` |

---

## 复现

service 的环境里有 Xcode 注入的变量（`ps eww -p <pid>` 可见）：`DYLD_INSERT_LIBRARIES` 依次是 `libLogRedirect.dylib`、
`libBacktraceRecording.dylib`、`libMainThreadChecker.dylib`、`/usr/lib/libRPAC.dylib` 和
`MacOSX.platform/Developer/Library/Debugger/libViewDebuggerSupport.dylib`，与 App 进程里的完全相同；`DYLD_FRAMEWORK_PATH` /
`DYLD_LIBRARY_PATH` 指向各个 Build Products 目录。dyld 的检查发生在 `main` 之前，与是不是 launchd 拉起无关，所以在终端里直接运行
service 的可执行文件就能复现：

- 不带这些变量：dyld 通过，进程一直跑到 libxpc 说「An XPC Service cannot be run directly」——直接运行 XPC service 的正常结局。
- 带上全部变量：

  ```
  dyld[89237]: Symbol not found: _OBJC_CLASS_$_ABPeoplePickerView
    Referenced from: …/MacOSX.platform/Developer/Library/Debugger/libViewDebuggerSupport.dylib
    Expected in:     /System/iOSSupport/System/Library/Frameworks/AddressBook.framework/Versions/A/AddressBook
  ```

  Catalyst 进程里 AddressBook 解析到 iOSSupport 那一份，它没有 macOS 才有的这个类。
- 只去掉视图调试库、其余照旧：dyld 通过。其余几个库都只有 macOS 平台，但 macOS 的库本来就可以载入 Catalyst 进程（plugin 就是这么载入的），
  出问题的只有视图调试库，因为它要 AddressBook 里的 macOS 类。

## 为什么不能只给 service 换成 Catalyst 版

逆向 Xcode 26.6（17F113）的 DebuggerFoundation（UUID `17DC2A75-46B5-3EF5-A85D-A2C3135B77FB`）与 DVTFoundation，地址取自
`/Volumes/RE/Xcode/26.6/` 下的 dump，伪代码与汇编都核对过：

- `-[DVTAbstractMacDevice viewDebuggerDylibPathWithOptions:]`（DVTFoundation `0x4FCBC`）：options 里 `DBGViewDebuggerUseMacCatalystVariant`
  为真就选 `libViewDebuggerSupport_macCatalyst.dylib`，否则选 `libViewDebuggerSupport.dylib`。
- `+[DBGViewDebuggerAddition _viewDebuggingDylibPath:]`（DebuggerFoundation `0x3AF44`）：只有
  `-[IDELaunchSession dbg_usesMacCatalystViewDebugging]`（`0x3DF1C`）为真才设上那个键；后者在目标是 Mac 时读**启动会话二进制**的
  Mach-O 平台，6（Mac Catalyst）为真。所以 Xcode 本来会按平台选，但 service 拿到的注入与 App 一字不差，沿用的是 App（macOS）会话的结论。
- Catalyst 版只有 `MACCATALYST` 平台，主 App 载不进去，没法全局换。`_viewDebuggingDylibPath:` 开头读的 user default
  `DBGLibViewDebuggerSupportPath` 可以直接指定库，但只在 `runtimeInternalStateContains:4`（Apple 内部状态）时生效。

## 处理

- `-[DBGViewDebuggerAddition _shouldLoadDylibOnLaunchOfLaunchSession:forLaunchParameters:]`（`0x3BD6C`）在
  `_shouldSkipDylibLoadingOnLaunchDueToUserDefault`（`0x3BE20`，读 `DBGViewDebuggerInsertDylibOnDemand`）为真时返回 NO，
  `adjustedLaunchParametersForLaunchParameters:`（`0x3B88C`）就不往 `DYLD_INSERT_LIBRARIES` 里加视图调试库。
- 抓视图层级时，`_loadViewDebuggingDylibIfNecessary`（`0x3AC90`）经调试会话的 `requestLoadDylibAtPath:completionBlock:` 按需载入，
  App 的 Debug View Hierarchy 照常可用。
- 每台机器一次：

  ```bash
  defaults write com.apple.dt.Xcode DBGViewDebuggerInsertDylibOnDemand -bool YES
  ```

  用户在自己的 Xcode 上设好后回复「可以了」。Xcode 27.0 的 DebuggerFoundation 里同样有这个键名，逻辑只在 26.6 上看全了。
- 没有改 scheme：关掉「Debug XPC services」会让两个 service 都没法自动附加调试器，关掉视图调试会让主 App 失去它，这个开关两样都保住。

## 遗留

App 这边对内嵌 service 的首次连接没有超时：service 卡住（像这次被调试器扣住，或将来启动代码里出现死锁）时，Catalyst 引擎既不出现，
也不报错。helper App 那条路有 15 秒握手超时。要不要补，未定。

# Draft - 越狱版 RV iOS：枚举设备进程并注入

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-10-01
- **最后更新**: 2026-10-04
- **所属愿景**: 无
- **关联提案**: [0014](0014-inject-ios-simulator-process.md)（模拟器注入；本提案是它明确列为非目标的「真机」那一半）
- **实现分支 / PR**: `feature/jailbroken-ios-injection`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

给 RV iOS 增加一个**越狱版独立 target**：它能枚举设备上的全部进程，并把
`RuntimeViewerServer`（iphoneos 切片）注入到任意同 uid 的进程里，使那个进程作为独立 engine
出现在宿主 RuntimeViewer 的引擎列表中。现有的非越狱版不变，继续只服务自己进程。

宿主侧新增一条 attach 路径：从 GitHub release 下载越狱版 IPA 供用户装进设备，连上之后通过
**既有的 Bonjour 通道**请求进程列表、由用户挑选目标、再把注入请求委派给设备上的越狱版执行。

关键结论是 **iOS 上不需要 macOS 那套 `SMAppService` 特权 daemon + XPC 委派**：实测一个
uid 501 的 App 只要带三条 entitlement 就能自己完成枚举与注入。这让 iOS 侧的架构比 macOS 侧
简单一层，且**不绑定 vphone** —— 同一套设计在任意越狱真机上成立。

## 动机

### 现在 iOS 侧只能看自己

`RuntimeViewerServer/RuntimeViewerServer.swift:52` 按**编译期**条件分流，iOS 分支建的是
一个服务**自己这个进程**的 engine：

```swift
#if os(macOS) || targetEnvironment(macCatalyst)
    // SandboxProbe → localSocket 或 remote(XPC)
#else
    // Bonjour：name/identifier 取自本进程
#endif
```

所以把 RV iOS 装进一台设备，宿主能看到的只有 RV iOS 自己。实测 vphone guest 里有 **434 个
进程**，其余 433 个一个都看不到——而逆向的价值恰恰在于观察**别人**的进程（SpringBoard、
系统 daemon、用户自己的 app）。

### 0014 把真机列为非目标，而真机级场景现在日常可得

提案 0014「支持注入 iOS Simulator 进程」的非目标一节写着「**不支持 iOS 真机**。真机走的是
Bonjour + 手动集成 payload 那条路」。那个判断在当时成立：真机要越狱、要配环境，不是日常可得的
观察环境。

vphone（Apple `com.apple.private.virtualization.security-research` 平台上的虚拟 iPhone）改变了
这个前提——它在 iOS 眼里就是真机（`iPhone99,11` / `VPHONE600AP`），随时可重启、SIP 与 AMFI
已放开，但**宿主的 `task_for_pid` 够不着它**（guest 有独立内核，其进程不是宿主进程）。于是
0014 那条「宿主侧注入」的路径对它完全不适用，必须在设备内部完成注入。

### 为什么值得做，以及为什么现在做

能力的两头都已经具备，缺的只是把它们接起来：

- **注入器**：MachInjector 可移植到 iOS，改动只有 5 处表层（见前期调研），无一行逻辑改动。
- **通道与身份**：0014 已经建好「设备做 Section、进程做条目」的 Bonjour 身份方案
  （`rv-device-id` / `rv-proc-name` / `rv-proc-pid`）与 `awaitInjectedBonjourEngine`，
  正是「一台设备上多个被注入进程」所需要的形状，可直接复用。

## 前期调研

本节全部是 2026-10-01 的实测结论，除显式标注为推测者外都已验证。

### MachInjector 能在 iOS 用（已验证，含端到端注入）

移植所需改动只有 5 处，**没有一行逻辑改动**。代码在 MachInjector 的 spike 分支
`feature/ios-support`（worktree `.worktrees/MachInjector-IOSPort`，尚未并入 `main`）：

| 改动 | 内容 |
|---|---|
| 新增 `Sources/MachInjector/MIMachVMCompat.h` | iOS 下自带 `mach_vm_*` 原型 |
| 4 个 `.m` | `<mach/mach_vm.h>` → 该兼容头 |
| 2 个 `.m` | `<Cocoa/Cocoa.h>` → `<Foundation/Foundation.h>`（实测不 load-bearing） |
| 1 处 | `<bsm/libbsm.h>` → `<mach/task_info.h>`（只为 `audit_token_t`） |
| `Package.swift` | `platforms` 加 `.iOS(.v15)` |

**两个 SDK 陷阱**（都是「头缺失但符号导出」）：

- `mach/mach_vm.h` 在 iOS SDK 里**存在，但整个文件只有一行 `#error mach_vm.h unsupported.`**
  —— 所以 `__has_include` 探测会误报成功，必须用平台条件而非头存在性判断。
- `libproc.h` 在 iOS SDK 里**根本没有**。

而两者的符号都在公开 `usr/lib/libSystem.B.tbd` 里导出、可直接对公开 SDK 链接：
`_mach_vm_allocate` / `_write` / `_protect` / `_read_overwrite`、`_task_for_pid`、
`_thread_create_running`、`_thread_convert_thread_state`、`_sandbox_extension_consume`、
`_proc_listallpids` / `_proc_name` / `_proc_pidpath` / `_proc_pidinfo`。`libproc` 那组在
macOS 头上的可用性标注还是 `__IPHONE_2_0` / `__IPHONE_4_1` —— Apple 自己认为它们是 iOS API，
只是不发头文件。原型必须**从 macOS 头逐字抄**：`mach_vm_read` 系列第一个参数是
`vm_map_read_t` 而非 `vm_map_t`，抄错会编过然后行为错。

**必须编 arm64e。** `loader_arm64.s` 的 `paciza` / `pacibsp` 要 pauth 特性；实测
**macOS 的 arm64 target 允许这些指令、iOS 的 arm64 不允许**，所以这个约束在 macOS 上永远不会
暴露。arm64e 下 shellcode 产物 3992 字节，与 macOS 一致。

**remap 路径在 iOS 上不可用**：`Loader/build_loader.sh` 用 `clang -dynamiclib -arch arm64
-arch arm64e` 且不带 `-target` / `-isysroot`，内嵌的 loader 是 macOS dylib。该路径能编过但
不能用；本提案只走 dlopen 路径（与 0014 对异构目标的结论一致）。

**macOS 构建无回归**：`swift build` 退出码 0。

### 权限边界：沙盒是唯一闸门，注入额外只需 `task_for_pid-allow`

七个变体实测，被注入靶子（10 个系统 daemon）**全部存活**：

| 沙盒逃逸 | task-port entitlement | 容器化 | 枚举进程 | 注入 |
|---|---|---|---|---|
| — | 无 | true | ❌ `EPERM` | ❌ |
| — | `platform-application` + `task_for_pid-allow` + `com.apple.system-task-ports` | true | ❌ `EPERM` | ❌ |
| ✅ | 无 | false | ✅ | ❌ |
| ✅ | `platform-application` | false | ✅ | ❌ |
| ✅ | `com.apple.system-task-ports` | false | ✅ | ❌ |
| ✅ | **`task_for_pid-allow`** | false | ✅ | **✅** |

三条结论：

1. **沙盒逃逸（`no-sandbox` + `no-container`）是两种能力的共同必要条件。** 容器化状态下
   `proc_listallpids` 一律 `EPERM`，task-port entitlement 加了也无效——前两行行为完全一致。
2. **枚举只需沙盒逃逸**，不需要任何 task-port entitlement。
3. **注入额外且仅需 `task_for_pid-allow`** —— 越狱界的老写法。Apple 的
   `com.apple.system-task-ports` **不管用**，`platform-application` 也不管用。

所以最小 entitlement 集是三条，正是越狱安装器（TrollStore 一类）本来就会授予的：

```xml
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>task_for_pid-allow</key><true/>
```

**注入方的身份边界**：root 能注入 uid 501 进程；uid 501 + 沙盒逃逸也能注入 uid 501 进程
（**所以 root 非必需**）；但 uid 501 **注入不了 uid 0 进程**（拿不到 task port）。

**不需要 macOS 那套架构。** macOS 侧靠 `SMAppService` 装特权 daemon、App 经 XPC
（`RuntimeViewerMachServiceName` / `HelperPeer`）委派 daemon 注入；iOS 上 App 自己就能做，
`swift-helper-service` / `HelperServiceManager` / Mach service 整层都不需要。

### 枚举能力（已验证）

uid 501 + 沙盒逃逸的 App 实测：`proc_listallpids` 返回 438 个 pid，`proc_name` 438/438 成功，
`proc_pidpath` 437/438 成功（缺的那个应为 pid 0，无可执行路径）。数据足够驱动一个进程选择器。

### payload 投放路径（已验证）

被注入进程需要能 `dlopen` 到 payload。`/private/var/tmp/` 实测可用——4 次注入全部成功，
且带沙盒逃逸的 App 能往那里写。**不要放 App 自己的 bundle 或容器里**：目标进程未必读得到
另一个 App 的容器。

**这 4 次验证的范围要说清楚**：注的是一个自带的测试 dylib，它没有任何 `@rpath` 依赖，所以这组
数据只证明了「路径可写、目标可 dlopen」，**没有**证明真正的 payload 能加载——后者多一条
`@rpath/libswiftCompatibilitySpan.dylib`，是落地时才发现并单独处理的（见决策日志）。真 payload
的端到端加载属第 8 步。

### vphone 侧（已验证，与本提案的耦合面）

- **私有 Virtualization entitlement 只在 `vphone-vm` 上**（`com.apple.private.virtualization`、
  `com.apple.private.virtualization.security-research` 等）。源码侧确认整个 vphone 仓库只有两个
  `.entitlements` 文件，其 Launchpad 自己一个都没有。**RuntimeViewer 不需要任何
  Virtualization 权限**，因为它不启动 VM。
- **拖拽安装是 vphone 内建功能**：`VPhoneVirtualMachineView` 注册 `.fileURL` 拖拽，
  `.ipa` / `.tipa` 走 `control.installIPA`，内部用 VSOCK 上的 HTTP 上传，**无大小限制**、
  **不需要 `--api-listen`**。它从拖拽 pasteboard **立即**读取 `.fileURL`，所以拖拽源必须提供
  真实落盘文件，不能用 `NSFilePromiseProvider`。
- **`vphone.sock` 单条请求上限 1 MiB**（源码 `maximumRequestLength = 1 << 20`），且
  `files.write` 是 `.atomic` 覆盖写、**无 append 语义**（实测 `append` / `mode` / `offset`
  三种写法都被忽略）。所以经 socket 推一个几十 MB 的 IPA 不可行。
- **`apps.install` 会无条件递归删除源文件**，且 `defer` 注册在安装调用之前，**失败也删**。

### 可直接复用的既有件

- `RuntimeEngineManager.awaitInjectedBonjourEngine(name:processIdentifier:timeout:)`（0014 产物）
  —— 按 pid 轮询 `bonjourRuntimeEngines`，正是「注入完等它出现」所需。
- 0014 的 Bonjour 身份方案（`rv-device-id` 作 `hostID`、`rv-proc-name` 作条目名、
  `rv-device-id`+`rv-proc-pid` 作去重键）—— 一台设备多个被注入进程会自动并进同一个 Section。
- `AttachToProcessViewModel` 已按平台分叉成 `attachToLocalProcess` / `attachToSimulatorProcess`，
  新增第三支符合既有结构。
- 架构文档速查表指定的 RPC 扩展点：`RuntimeEngine.CommandNames` +
  `RuntimeEngine.registerSharedHandlers`（ProxyServer 自动继承，所以经另一台 Mac 转发的镜像
  引擎也能用这三条新命令）。

### 进程选择器的现状（`RunningApplicationKit`，上游是本人的库）

选择器来自 `Mx-Iris/RunningApplicationKit`，经 `RuntimeViewerUI` 的
`@_exported import` 透出。现状：

| 层 | 状态 |
|---|---|
| `RunningItem` | **已经是协议**（`processIdentifier` / `name` / `icon` / `architecture` / `isSandboxed` / `platform`），但 `import AppKit` 且 `icon` 是 `NSImage?` |
| `RunningItemPickerViewController<Item: RunningItem>` | 888 行，泛型**已经架在该协议上**，但是 **internal**，纯 AppKit（`NSTableView` + `NSTableViewDiffableDataSource`） |
| 数据源 | **硬编码在两个具体子类里**（`RunningApplicationPickerViewController` 走 NSWorkspace、`RunningProcessPickerViewController` 走 BSD sysctl），没有来源抽象 |
| package | `platforms: [.macOS(.v11)]`，macOS-only |

**RuntimeViewer 侧的集成面只有两个文件**：`AttachToProcessViewController` 持有
`RunningPickerTabViewController`（Applications / Processes 两个 tab）并实现其 `Delegate` 的三个
回调；`AttachToProcessViewModel` 的 `Input.attachToProcess` 已经是 `Signal<any RunningItem>`。

**所以 ViewModel 层本来就是抽象的** —— 它只认 `any RunningItem` 这个存在类型。要动的是
UI 层与数据源层，业务层不受影响。这决定了本提案的抽象只做数据源一层（见替代方案考量）。

### 真机 payload 能构建（2026-10-02 补测，撤销一条误报的前置）

此前记录的「`RuntimeViewerMobileServer` 以 `generic/platform=iOS` 构建时，`swift-async-algorithms`
报 `returning 'result' as a 'sending' result risks causing data races`」**是用错入口造成的**。

| 入口 | 结果 |
|---|---|
| `RuntimeViewerServer/RuntimeViewerServer.xcodeproj`（独立工程） | ❌ 挂 —— 但 **macOS 目标也挂**，且挂在更前面的 `SwiftyXPC` 上（`stored properties cannot be marked unavailable with '@available'`） |
| `RuntimeViewer-Debug.xcworkspace`（`RunScript.sh:263` 实际用的那个） | ✅ `EXIT=0` |

两条结论：

1. **这不是 iOS 特有问题**，而是那个独立 `.xcodeproj` 自带的 `Package.resolved` 整体陈旧
   （`swift-async-algorithms` 钉在 1.1.1，上游已到 1.1.7；那段代码正是被 upstream `#399`
   「Fix a data race error with the internal `Optional.takeSending`」与 `#419` 改掉的）。
   `MachOSwiftSection` 声明的是 `from: "1.0.4"`，1.1.7 完全在允许范围内。
   官方构建从不走这个入口（`RunScript.sh` 用 `-workspace RuntimeViewer-Debug.xcworkspace`），
   所以这份陈旧锁文件一直没人撞到。**它是一个独立的小问题，与本提案无关，不在本次范围内。**
2. **真机 payload 实测可构建，且能构建成 arm64e。**

| 构建 | 产物 | `lipo -info` | `LC_BUILD_VERSION` |
|---|---|---|---|
| 默认（`ARCHS_STANDARD`） | 53 MB | `arm64` | `platform 2`（PLATFORM_IOS）/ `minos 15.0` / `sdk 27.0` |
| **`ARCHS=arm64e`** | 55 MB | **`arm64e`** | 同上 |

**`ARCHS_STANDARD` 在 iphoneos 上就是 `arm64`，不含 arm64e** —— 工程里写的是
`ARCHS = $(ARCHS_STANDARD)`，所以越狱版那条构建路径必须显式传 `ARCHS=arm64e`。SwiftPM 那一侧
不用额外处理：`RuntimeViewer-Debug.xcworkspace` 的 `WorkspaceSettings.xcsettings` 已经带
`iOSPackagesShouldBuildARM64e = true`。

**待定（落地第 3 步时确认）**：payload 要不要跟注入器一样强制 arm64e。注入器必须 arm64e 是已验证
的硬约束（pauth 指令），但 payload 是被 `dlopen` 进目标进程的 dylib，它的架构要求取决于目标进程
的架构而不是注入器的。iOS 系统进程是 arm64e，所以**倾向于编 arm64e**（架构对齐无歧义，且代价只有
2 MB）；「arm64 dylib 能不能 dlopen 进 arm64e 进程」这一条**未实测**，不拿它当依据。

## 提议方案

### 一、RV iOS 新增越狱版独立 target

新建 target（暂名 `RuntimeViewerUsingUIKitJailbroken`），与现有 `RuntimeViewerUsingUIKit`
并存：

- 代码经 synchronized folder 共享；差异只在 entitlements、bundle identifier、图标与一个
  编译期能力开关。
- 独立 bundle identifier，使两个版本能**同时装在一台设备上**。
- 带上面那三条 entitlement；非越狱版一条都不带。
- 只在本仓库的 GitHub release 分发，**不进 App Store、不随 RV macOS 打包**。

### 二、三条新 RPC 命令

加在 `RuntimeEngine.CommandNames` 与 `registerSharedHandlers`：

- **`injectionCapability`** —— **连接的另一端有没有注入能力**，以及没有的话是为什么。
  **每个引擎都注册它**（包括非越狱版 iOS 与 macOS）—— 注册是为了**别人**镜像自己时能有答案；
  宿主对自己本机的引擎**不发这条查询**，见下面的短路规则。
- `processList` —— 该引擎所在那台机器上的进程清单
- `injectIntoProcess` —— 把 payload 注入指定 pid

**命名刻意不带 `device`**：同一套命令既服务 iOS 设备，也服务「同步过来的 Mac Engine」——
对后者，`processList` 是对端 Mac 的进程、注入由对端的特权 daemon 执行。叫 `deviceXxx` 会在
第二种场景里立刻变成错名字。命名风格与既有的 `imageList` / `loadImage` /
`runtimeObjectsInImage` 一致。

**每个引擎自己回答自己的能力**，判据按它所在的平台与安装状态：

| 引擎 | `injectionCapability` 的答案取决于 |
|---|---|
| 本机 / Catalyst / iOS 模拟器 | 特权 daemon 是否已安装（`HelperServiceManager` 知道） |
| iOS 设备 | **是不是越狱版**（非越狱版如实答「需越狱版」） |
| 同步来的 **Mac Engine** | **对端那台 Mac 是否装了 daemon** |
| 同步来的 **iOS** | **那台 iOS 是不是越狱版** |

后两行**不需要为镜像写任何特殊逻辑**：镜像引擎的查询经 `.directTCP` 送到对端的
`RuntimeEngineProxyServer`，而它自动继承共享命令表，于是答案就是**最远那一端自己的答案**，
一路原样转发回来。这正是把能力做成一条命令、而不是在 UI 里 `switch` 引擎种类的理由。

### 三、宿主侧新增一条 attach 路径

1. 一个「获取越狱版 RV iOS」入口：从 GitHub release 下载 IPA 到本地，落盘后供用户拖到
   vphone 窗口（或自行用越狱安装器装到真机）。
2. 连上之后，Attach to Process 先发 `injectionCapability` 判断对端能否注入；能则发 `processList`
   取**该设备**的进程清单（绝不列本机进程），显示选择器。
3. 用户挑选目标 → 发 `injectIntoProcess(pid)`。
4. 越狱版把内嵌 payload **连同它的 `@rpath` 依赖**暂存到 `/private/var/tmp/RuntimeViewerPayload/`
   并注入（布局见「payload 内嵌与暂存」）。
5. 宿主用 `awaitInjectedBonjourEngine` 等被注入进程广播，出现后作为同一设备 Section 下的
   新条目展示。

### 四、选择器：只抽数据源，按选中引擎整体切换

**上游（`RunningApplicationKit`）只做一件事：把数据源抽出来。** 加一个 item source 协议，让
「进程清单从哪来」成为注入点；现有的 NSWorkspace 与 BSD sysctl 两种来源各自成为它的实现，
远端设备进程成为第三种。同时把那个泛型 picker 从 internal 改为 public、items 由外部注入。
**AppKit UI 原样不动，package 继续 macOS-only。**

**宿主侧按选中引擎分四种：**

| 选中的引擎 | 目标进程在哪 | Attach to Process 这个 toolbar item |
|---|---|---|
| 本机 / Catalyst / iOS 模拟器 | **这台 Mac**（都是宿主进程） | 可用，打开今天的本机 picker，逐像素不变 |
| iOS 设备，**越狱版** | 另一台机器，对端能注入 | 可用，打开**该设备的进程列表** |
| iOS 设备，**非越狱版** | 另一台机器，对端无注入能力 | **disabled** |
| **远程同步来的镜像引擎** | 另一台 Mac 转发来的 | **disabled** |

**注入不可用时直接 disable toolbar item，不弹任何提示。** 这是 Mac 原生的表达方式——动作不可用
就是控件不可用，用户不需要先点一下才被告知做不到。原因挂在 **tooltip** 上（文案由
`injectionCapability` 的 `reason` 提供），这样解释不丢，又不打断操作。项目里已有自定义 tooltip
的既有做法可以复用（见 [`draft-runtime-object-icon-tooltips`](draft-runtime-object-icon-tooltips.md)
用的 `UIFoundationAppleInternal` 的 `customTooltipStyle` 与 `CustomToolTipManager`）。

**连带后果：「获取越狱版」的入口不能再挂在提示里了**，因为提示不存在了。**假设（可改）**：
放成 Attach to Process 的**同级菜单项**（「Get Runtime Viewer for Jailbroken iOS…」），始终可用，
不随引擎变灰——它是一个获取动作，不是对当前引擎的操作。

第一行的判据不是枚举引擎种类，而是**「目标是不是宿主进程」** —— 这正是宿主侧注入能成立的
充要条件，也正是 `InjectionTargetPlatform` 已经表达的那件事（`macOS` / `macCatalyst` /
`iOSSimulator` 都是宿主进程，真机不是）。所以它应该是引擎上的一个派生属性，而不是散在 UI 里的
一串 `if`。

第二行的语义是「你对哪台设备 attach，就只看得到那台设备的进程」，不需要额外解释。

第三、四行**不打开空列表、也不给一次注定失败的注入** —— 能力由 `injectionCapability` 查得，
不是猜的；查不到或答案不是 `.available` 就 disable。

### 短路规则：目标是宿主进程时，整条远端链路都不介入

**第一行（本机 / Catalyst / iOS 模拟器）完全走今天的代码，一次 RPC 都不发。** 清单直接取本机
现有的 NSWorkspace / BSD sysctl 两种来源，能力由本机的 `HelperServiceManager` 当场回答。

理由是**不破坏现有功能的体验**：这条路今天是「打开即出列表」，若为了形式统一而插一次
`injectionCapability` 往返，等于给一个已经好用的功能凭空加上延迟和一个新的失败模式（查询超时
怎么办？对端是自己又怎么会查不到？）。统一抽象的收益在远端，成本不该由本机这条路付。

落到代码上，判据是**「目标是不是宿主进程」**这个引擎派生属性：

- 是 → 本机分支，与今天逐像素一致，不碰 `injectionCapability` / `processList`；
- 不是 → 远端分支，才有查询与 `processList`。

**`injectionCapability` 仍然由本机引擎注册**，但那是给*别人*用的：当这台 Mac 的引擎被另一台 Mac
镜像过去时，对方要靠这条命令问出「你那边装了 daemon 吗」。自己问自己没有意义。

### 门禁要是一次能力探测，不是一串引擎种类判断

第四行（镜像引擎）**本次只做占位**，但它的实现方式直接决定将来解禁的代价，所以这里要写清楚。

镜像引擎的数据平面是「本机 → `.directTCP` client → 对端 Mac 的 `RuntimeEngineProxyServer` →
被代理的引擎」。而本提案的三条新命令走 `registerSharedHandlers`，**ProxyServer 是自动继承
共享命令表的**（架构文档速查表的既有保证）。这意味着一台**被转发的越狱 iOS 设备引擎**，很可能
本来就能应答 `injectionCapability` / `processList` / `injectIntoProcess` —— 转发对它们是透明的。

**这是推测，必须实测，不得当成已知。** 真正需要额外工作的是另一种镜像：目标是**对端 Mac 自己的
宿主进程**，那要对端的特权 daemon 配合、要在对端暂存 payload，与本提案的设备注入是两件事。

所以门禁实现成**一次能力探测**（对端有没有注册注入命令），而不是 `switch` 引擎种类：

- 镜像的越狱设备引擎若实测能应答，占位提示会**自己消失**，不需要再改 UI 代码；
- 对端 Mac 宿主进程的注入仍然探测为不支持，如实提示。

**本次刻意对镜像引擎短路成占位、不发探测**，理由是不想在没实测过的链路上给出一个可能失败的
注入入口。解禁的前提是一次端到端实测（两台 Mac + 一台越狱设备），列为后续提案。

### 非目标

- **不实现宿主侧注入设备进程。** 宿主没有 guest/设备进程的 task port，这条路物理上不存在。
- **不做 root 目标。** uid 501 注入不了 uid 0 进程（已实测）。要覆盖 root daemon 需要在设备里
  以 root 运行注入器（越狱 bootstrap 的 LaunchDaemon），属于另一个提案。
- **不用 vphone 的 `processes.list` 取进程表。** 那样会把本功能绑死在 vphone 上；自己枚举已验证
  可行且能搬到真机。
- **不依赖 vphone 的 RPC / HTTP API 做安装。** 用它内建的拖拽安装，耦合面最小。
- **不把 IPA 内置进 RV macOS。** 用户已定为 release 下载。
- **不改 remap 路径。** iOS 上内嵌 loader 是 macOS dylib，本次只走 dlopen。
- **不把 `RunningApplicationKit` 拆成平台中立 core + AppKit backend。** 只抽数据源。拆分见
  替代方案考量——当前没有任何非 AppKit 前端要消费它，拆了也没人用。
- **不在同一个 picker 里并列三个 tab。** 选中设备引擎时整体切换，不做「本机两个 tab 旁边加一个
  Device tab」。
- **不实现远程（镜像）引擎的注入，连代码都不写。** 本次只给占位提示。被转发的越狱设备引擎很
  可能已经能应答那三条命令（ProxyServer 自动继承共享命令表），但**未实测**；而「注入对端 Mac
  自己的宿主进程」要对端 daemon 配合、要在对端暂存 payload，是另一件事。解禁需要一次两台
  Mac + 一台越狱设备的端到端实测，**整块列为后续提案**。本次留下的只有两样东西：那条占位
  提示，和一个不会妨碍将来解禁的能力模型（`injectionCapability` 经 ProxyServer 转发天然可用）。
- **不改动本机那条 attach 路径。** 目标是宿主进程时整条远端链路不介入，一次 RPC 都不发，
  行为与今天逐像素一致——这是「不破坏现有功能体验」的硬要求，不是顺带的优化。
- **不改 payload 的构建方式。** 真机 payload 已验证能构建（见「前期调研」最后一节），
  本次只是在越狱版 target 里引用它，不新增构建脚本、不改 `RunScript.sh` 现有的模拟器那一支。

### 前置依赖（不在本提案范围）

只剩一条：**`MachInjector` 的 iOS 支持要合入上游并发版**。提案已写在那个仓库
（`Documentations/Evolutions/draft-ios-support.md`，状态 Draft），实测改动已提交在它的
`feature/ios-support` 分支。在它发版之前，本仓库的开发可以用 `USING_LOCAL_DEPENDENCIES=1`
走本地 checkout —— `RunScript.sh:127` 的注释正好把这个场景写成了典型例子
（「MachInjector reached through swift-helper-service is the usual case」）。

原先这里还列了第二条「修 `RuntimeViewerMobileServer` 的 iphoneos 构建」。**那一条是误报，已撤销**，
原因见下一节。

## 详细设计

### 新命令签名

**以下是实现后的真实形态。** 初稿这一节写错了三处 API，纠正记在决策日志里：`CommandNames` 是
`String, CaseIterable` 的 **enum**（不能用 extension 加「case」），命令协议叫
`RuntimeEngineRequest`（带 `associatedtype Response`，没有 `RuntimeRequest` / `RuntimeResponse`
这两个类型），而 `InjectionTargetPlatform` 是 `#if os(macOS)` 且在 macOS-only 模块里、**连 iOS
真机的 case 都没有**（`PLATFORM_IOS` = 2 落在 `.unsupported(2)`），所以当不了跨平台的门禁类型。

三条命令作为 case 直接加进 `RuntimeEngine.CommandNames`：

```swift
enum CommandNames: String, CaseIterable {
    // ... 既有 case ...
    case injectionCapability
    case processList
    case injectIntoProcess
}
```

模型落在 `RuntimeViewerCore/Sources/RuntimeViewerCore/Injection/`：

```swift
public enum RuntimeInjectionAvailability: Codable, Hashable, Sendable {
    case available
    case requiresJailbrokenVariant
    case helperDaemonNotInstalled
    case unsupported(reason: String)

    public var isAvailable: Bool { ... }

    /// 没注册 service 的进程答什么。三个平台含义不同，所以不是一个常量。
    public static var withoutInjectionService: RuntimeInjectionAvailability { ... }
}

public struct RuntimeProcess: Codable, Hashable, Sendable {
    public enum Injectability: Codable, Hashable, Sendable {
        case injectable
        case requiresRootOnTarget
        case notInjectable(reason: String)
        public var isInjectable: Bool { ... }
    }
    public let processIdentifier: pid_t
    public let name: String
    public let executablePath: String?
    public let userIdentifier: uid_t
    public let injectability: Injectability
}

public enum RuntimeProcessInjectionResult: Codable, Hashable, Sendable {
    case injected
    case taskPortUnavailable(reason: String)   // MachInjector code 3
    case targetRefusedPayload(reason: String)  // MachInjector code 18
    case failed(code: Int, reason: String)
    public var isInjected: Bool { ... }
}
```

请求类型按既有写法，`RuntimeViewerCore/RuntimeEngine+InjectionRequests.swift`：

```swift
extension RuntimeEngine {
    struct InjectionCapabilityRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.injectionCapability.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeInjectionAvailability
    }
    struct ProcessListRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.processList.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeProcess]
    }
    struct InjectIntoProcessRequest: RuntimeEngineRequest {
        let processIdentifier: pid_t
        static var commandName: String { CommandNames.injectIntoProcess.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeProcessInjectionResult
    }
}
```

三条都加进 `registerSharedHandlers`，于是 `RuntimeEngineProxyServer` 自动转发。

### 平台实现挂在哪：沿用 `engineListProvider` 那条既有接缝

`RuntimeViewerCore` 里**不放任何平台相关的注入代码** —— 它还要为 watchOS / tvOS / visionOS 构建，
那些平台上既没有 MachInjector 也没有 daemon。注入实现由持有它的进程注册进来：

```swift
public protocol RuntimeInjectionService: Sendable {
    func injectionAvailability() async -> RuntimeInjectionAvailability
    func processList() async throws -> [RuntimeProcess]
    func inject(intoProcessWithIdentifier processIdentifier: pid_t) async -> RuntimeProcessInjectionResult
}

extension RuntimeEngine {
    public static var injectionService: (any RuntimeInjectionService)?
}
```

这不是新发明的模式 —— `RuntimeEngine` 已经有 `static var engineListProvider` /
`engineListChangedHandler`（注释写的就是「Callback for serving engine list requests. Set by
RuntimeEngineManager.」），同样是「引擎按请求代答、但自己不拥有」的能力。

**`static` 而非 per-engine**：注入能力是机器的属性，同一进程服务的每个引擎答案都一样。宿主问
*远端*引擎时拿到的是那台机器自己的值，走的是连接而不是这个变量。

**`nil` 是有意义的状态，不是未初始化**：iOS 非越狱版就是刻意不注册。各平台此时答什么由
`withoutInjectionService` 决定，而它三个分支含义不同 —— iOS 上答 `requiresJailbrokenVariant`
（有补救动作）；macOS 上 App 总会注册 service、由那个 service 自己报
`helperDaemonNotInstalled`，所以到这里意味着没人接线，答 `unsupported` 并如实说明，**不能谎报
成缺 daemon**（那会把用户送去重装一个装了也没用的东西）；其余平台是真没有实现。

### 调用侧：能力查询不抛，另两条抛

```swift
extension RuntimeEngine {
    public func injectionAvailability() async -> RuntimeInjectionAvailability   // 不抛
    public func processList() async throws -> [RuntimeProcess]
    public func inject(intoProcessWithIdentifier processIdentifier: pid_t) async throws -> RuntimeProcessInjectionResult
}
```

**能力查询刻意不抛。** 它决定一个控件 enable 与否，每个调用方都只会把抛出的错误变成同一件事
（「当作不可用」），所以这件事做一次、做在这里。顺带解决一个兼容问题：**比这三条命令更早构建的
对端没有这个 handler，dispatch 会失败** —— 而那与「对端不能注入」不可区分，含义也相同。

另两条抛，因为调用到它们时门禁已经放行，这时的失败是用户需要看到的真失败，不是一种要渲染的状态。
注入的「抛」与「返回失败结果」含义不同：抛是请求没送达，结果是注入本身有了结论。

### 枚举实现

iOS SDK 无 `libproc.h`，自带原型（与 `MIMachVMCompat.h` 同一手法）：

```c
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
```

`proc_listallpids(NULL, 0)` 返回的是容量提示而非精确数量，要按它分配后再取实际返回值。

### payload 内嵌与暂存

越狱版用**常规的 target dependency + Embed Frameworks** 内嵌 `RuntimeViewerServer.framework`
（iphoneos 切片，`arm64 arm64e`），落在 bundle 的 `Frameworks/` 下。macOS 侧那套「脚本构建 →
固定路径暂存 → copy phase」是被 Xcode 拒收跨平台内嵌内容逼出来的，越狱版自己是 iOS，不受这条限制。

注入前把 payload 暂存到目标进程读得到的地方 —— **不是单个 Mach-O，而是一个目录**：

```
/private/var/tmp/RuntimeViewerPayload/
    RuntimeViewerServer              ← 注入这个绝对路径
    Frameworks/
        libswiftCompatibilitySpan.dylib   ← 不拷它,目标 dlopen 必失败
        …                                  ← App bundle 里其余内嵌库
```

这个布局不是随意定的：payload 自己的 run-path 里有 `@loader_path/Frameworks`，而 loader 就是
暂存出来的那个副本，所以依赖放在同名子目录里即可被解析，**不需要改写二进制**。为什么必须拷依赖
见决策日志里 `libswiftCompatibilitySpan.dylib` 那条 —— 简短版：它是 Swift 的向后部署垫片，
iOS 26.5 的系统里有、iOS 27 里没有，赌系统自带会得到一个随设备版本漂移的 bug。

逻辑落在 `RuntimePayloadStaging`，**刻意不加 iOS 编译门**，以便在 macOS 上用真实文件系统测
（布局错了的表现是在别的进程里 `dlopen` 失败，是整个功能最难观测的位置）。

### 选择器的数据源抽象（上游 `RunningApplicationKit`）

形状上只加一个「清单从哪来」的注入点，并把泛型 picker 公开：

```swift
/// 一批可供挑选的条目从哪来。现有的两种来源（NSWorkspace / BSD sysctl）各自成为它的实现，
/// 远端那一端的进程是第三种。
public protocol RunningItemSource<Item>: Sendable {
    associatedtype Item: RunningItem
    /// 取一次完整清单。远端实现在这里走一次 RPC。
    func loadItems() async throws -> [Item]
}

/// 原本 internal，改为 public 并接受外部注入的来源。
open class RunningItemPickerViewController<Item: RunningItem>: NSViewController { … }
```

**清单永远来自被选中引擎所在的那台机器，绝不是本机。** 这条对两种远端都成立：选中 iOS 设备
引擎时列的是那台 iOS 的进程；选中**同步来的 Mac Engine** 时列的是**对端那台 Mac** 的进程。
本机的 NSWorkspace / BSD sysctl 两种来源只在「目标就是宿主进程」那一类引擎下使用。把本机进程
显示在一个远端目标的选择器里，是本设计明确要避免的错误——用户会挑一个本机 pid 去注入另一台
机器。

**可注入性由远端判定，不由宿主猜。** 只有远端知道自己的 uid、entitlement 与 daemon 状态，
所以每个条目自带判定结果（见下面 `RuntimeProcess` 的 `injectability`）。实测依据：uid 501 的
越狱版 App **注入不了 uid 0 的进程**，若把 root daemon 原样列出来，用户挑中的每一个都注定
失败。

**不可注入的条目显示但不可选中，不隐藏。** 隐藏会让「为什么我看不到 SpringBoard」变成一个
无法回答的问题；显示并标灰既不误导也可诊断。

**这个机制上游已经有一半了**：`RunningItemPickerViewController` 已有
`func shouldSelect(item: Item) -> Bool`（默认 `true`）并已接在 `tableView(_:shouldSelectRow:)` 上。
要补的是两件：

1. **视觉那一半** —— `shouldSelectRow` 返 `false` 只是让行选不中，行**看起来仍然正常**。要让
   「显示但不可选」读得出来，cell 得跟着变灰，所以渲染侧要认这个状态。
2. **特殊进程规则** —— 库里**现在没有**对 `kernel_task`（pid 0）、`launchd`（pid 1）这类进程的
   任何处理，本机 picker 今天是可以选中它们然后注入失败的。这条规则加在上游，**本机那条路
   因此一并受益**。

远端条目的 `injectability` 映射到同一个 `shouldSelect` 钩子上——宿主不需要为远端再发明一套
禁用机制。

**`icon` 保持 `NSImage?` 不变。** 远端进程（系统 daemon）本来就没有图标，远端实现返回 `nil`；
将来若要显示 app 图标，走 `RuntimeRemoteEngineDescriptor.iconData` 已有的「随描述符带 PNG
字节、由宿主解码」那条路，不需要改协议。这也是本次不动模型层的理由之一。

远端进程的条目类型住在 RuntimeViewer 侧，不进上游库：

```swift
struct RuntimeRemoteRunningItem: RunningItem {
    let process: RuntimeProcess
    var processIdentifier: pid_t { process.processIdentifier }
    var name: String { process.name }
    var icon: NSImage? { nil }
    var architecture: Architecture? { nil }
    var isSandboxed: Bool { false }
    /// 远端报的平台，决定行与角标怎么画。
    var platform: Platform?
}
```

### 宿主侧落点

`AttachToProcessViewModel` 新增 `attachToRemoteProcess`，与既有两支并列。它不探沙盒
（`SandboxProbe` 只用于在 XPC 与 localhost socket 间选择，设备 payload 两个都不走）、不起
本地 engine，注入后直接等 `awaitInjectedBonjourEngine`。

`AttachToProcessViewController` **先看目标是不是宿主进程**，只有不是时才走远端那套：

| 选中的引擎 | 发不发 RPC | toolbar item / 打开什么 |
|---|---|---|
| 目标是宿主进程（本机 / Catalyst / 模拟器） | **不发** | 可用 → 今天的 `RunningPickerTabViewController`，逐像素不变 |
| 远端 iOS 设备 | `injectionCapability` → `.available` | 可用 → `RuntimeRemoteRunningItemSource`（内部发 `processList`）驱动的单列表 picker |
| 远端 iOS 设备 | `injectionCapability` → 其余 | **disabled**，原因进 tooltip |
| 远程同步来的镜像引擎 | **不发** | **disabled**，tooltip 写「暂不支持远程注入」 |

第一行与第四行都**不发任何查询**：前者因为答案在本机手里（见短路规则），后者因为远程注入
本次不实现。于是**本次真正会发出这三条命令的只有「远端 iOS 设备」这一类**。

能力查询是**随引擎选中而异步发出**的，不是点 toolbar item 时才发——否则 disable 状态无从提前
决定。答案回来之前 toolbar item 按 disabled 呈现（保守方向：宁可晚一点变可用，也不要给一个
点下去才失败的按钮）。

**`Input.attachToProcess` 的类型不变**，仍是 `Signal<any RunningItem>` —— 这是集成面只有两个
文件、业务层零改动的原因。

## 替代方案考量

**宿主经 vphone 的 `processes.list` 取进程表。** 数据更全（含内存、CPU、jetsam 优先级）且由
root 采集、零不确定性。否决理由：把功能绑死在 vphone 上，真机没有那个 socket；而自己枚举已
实测可行。

**宿主经 vphone RPC / HTTP API 安装 IPA。** 否决理由：socket 单请求 1 MiB 装不下 IPA 且无
append；HTTP `PUT /v1/files/content` 要求 VM 以 `--api-listen` 启动，而 Launchpad GUI 走的
`vm start` 没有这个选项。而拖拽安装内建、无大小限制、不需要任何 flag。

**socket 分块推 + 设备内自带工具拼装。** 可行（已验证能以 root 跑 LaunchDaemon 执行自带
二进制），但要求 RV 随包分发一个带私有 entitlement 的 ad-hoc 签名 iOS Mach-O，公证风险高，
且只为绕开 1 MiB 限制。拖拽方案让这整块消失。

**照搬 macOS 的 `SMAppService` daemon + XPC 委派。** 否决理由：实测不需要——uid 501 的 App
带三条 entitlement 即可自行枚举与注入。多一个 daemon 等于多一层可坏的东西。

**把越狱版 IPA 内置进 RV macOS。** 离线可用、版本永远匹配，但 RV macOS 装包要大几十 MB。
用户选择 release 下载。

**给 RV iOS 加一个 build configuration 而非独立 target。** 改动更小，但两个版本 bundle
identifier 相同、不能共存于一台设备。用户选择独立 target。

**把 `RunningApplicationKit` 拆成平台中立 core + AppKit backend。** 模型层去掉 `NSImage`，
列表状态（排序 / 过滤 / 选中）与渲染分离，package 不再 macOS-only，将来可接 SwiftUI 或 UIKit
前端。否决理由：**当前没有任何非 AppKit 前端要消费它** —— RV iOS 只负责提供数据与执行注入，
它自己不需要进程选择器。为一个还不存在的消费者去拆一个 888 行的 AppKit 视图控制器，是把成本
提前付掉而收益待定。数据源抽象已经足够接上远端来源，且那是真正缺的那一层。留档以备将来真有
第二个前端时重新评估。

**在现有 picker 旁边加第三个 Device tab。** 用户仍在一个 picker 里，三种来源并列。否决理由：
tab 的语义会变得自相矛盾——Applications / Processes 是「本机」的两种视角，Device 是「另一台
机器」，三者不在同一个维度上；而且选中设备引擎时本机那两个 tab 对用户毫无意义。整体切换让
「对哪台设备 attach 就只看那台的进程」这件事不需要解释。

**另起一个「Attach to Device Process…」菜单项。** 两条入口彻底分开、互不影响。否决理由：
用户要做的事是同一件（挑一个进程去 attach），分成两个入口等于把「目标在哪台机器上」这个
本该由当前选中引擎回答的问题丢回给用户。

## 影响

### 用户可见变化

- RV iOS 多一个**越狱版**，只在 GitHub release 提供；非越狱版行为完全不变。
- **Attach to Process 这个 toolbar item 从此会随选中引擎 disable**，四种形态见「提议方案 / 四」
  的表：目标跑在这台 Mac 上（本机 / Catalyst / 模拟器）时可用且与今天逐像素一致；iOS 越狱版设备
  可用、打开该设备的进程列表；iOS 非越狱版与远程镜像引擎 **disabled**，原因写在 tooltip 里。
  **不弹任何提示框**。注入成功后被注入进程作为同一设备 Section 下的新条目出现。
- **进程列表里 `kernel_task`、`launchd` 这类特殊进程从此显示但不可选中**（上游改动，**本机那条
  路一并受益**）。今天它们可以被选中，然后注入失败。

### 一处确实失效的既有行为，以及替代路径

**今天的 Attach to Process 与选中的引擎完全无关**（已查证：`MainViewModel` 里唯一的门是
`SIPChecker.isDisabled()`，`attachItem` 没有任何 `isEnabled` 控制）。所以选中一个 iOS 引擎时，
今天照样能 attach 本机进程；本提案把 toolbar item 按引擎 disable 之后，**这条路没了**。

这是**有意的语义收紧**，不是疏漏：attach 从此表示「在当前引擎所在那台机器上挑一个进程」，而
不是「不管你在看哪台机器，总是挑本机进程」。后者在只有本机引擎的年代没有歧义，有了设备引擎
之后就成了一个会让人挑错机器的设计。

**替代路径**：先把引擎切回「My Mac」（或任意宿主进程引擎），toolbar item 立刻可用，行为与今天
完全一致。切换引擎本来就在 toolbar 上，不是隐藏操作。

**顺带记一笔 SIP 那条门的不一致**：SIP 开着时现在是弹错误提示，而本提案对「不可用」的处理是
disable + tooltip。两种表达同一件事会显得随意。**假设（可改）**：把 SIP 这条也改成 disable +
tooltip，与新门禁统一；若你希望 SIP 保持弹提示（它更像「环境没配好」而非「此引擎不支持」），
说一声。

### 可发现性

- 「获取越狱版 RV iOS」放在那条「不支持注入」的提示旁边——那是用户唯一会在此刻追问「怎么才能
  注入」的位置，也是本功能唯一的发现点。
- 不新增设置项，也不新增菜单项。入口仍是今天的 Attach to Process，**三种形态由当前选中引擎
  自动决定**，用户不需要先知道自己该走哪条路。
- 能力由 `injectionCapability` 这条命令查得，不是用户要配置的开关；每个引擎自己回答自己。

### 数据与配置兼容

无迁移。不改文档格式、偏好设置、钥匙串。越狱版用独立 bundle identifier，与非越狱版的数据
互不影响；两者可同时安装。

### 平台与最低版本

- 宿主 RuntimeViewer 最低版本不变。
- 越狱版 RV iOS 受 `RuntimeViewerServer` 的 `IPHONEOS_DEPLOYMENT_TARGET = 15.0` 约束。
- **仅 arm64e**（PAC 指令所需），即 A12 及以后的设备；vphone guest 满足。
- 运行期前提：设备已越狱且安装方式能授予那三条 entitlement。

### 发布

- **越狱版不走 App Store**，只在本仓库 release 分发。它带的三条私有 entitlement 决定了这一点，
  不是分发策略的选择。
- 越狱版用 ad-hoc 签名 + 显式 entitlements（`codesign -s - --entitlements` 接受任意
  entitlement，不需要 provisioning profile）。走 Xcode 正常 Run 装进去的版本**注入不了**，
  这一点要写进使用指南。
- **不影响宿主的公证与 Sparkle 流程**：因为 IPA 不内置进 RV macOS，宿主包里不会出现带私有
  entitlement 的嵌套可执行内容。
- 宿主新增网络访问（下载 release）。RuntimeViewer 未沙盒化，无需新增 entitlement。

## 落地步骤

1. **MachInjector 的 iOS 支持并入上游。** 把 spike 分支 `feature/ios-support` 的 5 处改动按
   MachInjector 自己 `CLAUDE.md` 的规矩走一份提案后并入 `main`，发版。验证标准：macOS
   `swift build` 无回归 + iOS arm64e 能编出 `libMachInjector.a`。
2. ~~（前置，不在本提案）修 `RuntimeViewerMobileServer` 的 iphoneos 构建。~~
   **已撤销 —— 误报。** 2026-10-02 补测：经 `RuntimeViewer-Debug.xcworkspace` 构建
   `generic/platform=iOS` 为 `EXIT=0`，加 `ARCHS=arm64e` 同样通过。原先的失败来自那个独立
   `.xcodeproj` 的陈旧 `Package.resolved`，而官方构建从不走它。详见「前期调研」最后一节。
3. **新建越狱版 target**，含 entitlements、独立 bundle identifier、图标，和一个编译期能力开关。
   验证标准：两个版本都能构建，越狱版的 `dump-entitlements` 含那三条。
   **并把 payload 内嵌进去**：越狱版与 payload 同属 iOS，所以这里**可以**用常规的
   target dependency + Embed Frameworks，不必走 macOS 那套「脚本构建 → 固定路径暂存 →
   copy phase」（那是被 Xcode 拒收跨平台内嵌内容逼出来的）。payload 落在 `Frameworks/`，
   `ARCHS[sdk=iphoneos*] = arm64 arm64e`。验证标准：产物里 `Frameworks/RuntimeViewerServer.framework`
   存在、两个切片都在、能力门禁不再报「缺 payload」。
4. **实现设备侧枚举**（自带 `libproc` 原型）与**注入**（调 `MIMachInjector`，payload 暂存到
   `/private/var/tmp/`），注册三条 RPC 命令。带单测：`libproc` 原型的声明与 macOS 头一致、
   错误码映射正确。
5. **`RunningApplicationKit` 的上游改动。** ✅ **已实现并发版 `0.7.0`**(提案见该仓库
   `Documentations/Evolutions/0003-injected-item-source.md`;83 个测试全绿,原有 69 个未改)。
   **落地形态与下面写的不同** —— 公开面小得多,见决策日志 2026-10-02 那条:没有公开泛型
   picker,而是给门面 `RunningPickerTabViewController` 加 `Configuration.tabs` 与
   `processItemSource`。本仓库的依赖已从临时分支 pin 换回 `from: "0.7.0"`。
   原计划的三件事：①加 `RunningItemSource`、把泛型 picker 改
   public 并接受外部注入的 items，现有两种来源各自成为其实现；②`shouldSelect(item:)` 已存在且已
   接在 `shouldSelectRow` 上，补上**渲染侧的变灰**（现在返 `false` 只是选不中，行看起来仍正常）；
   ③加**特殊进程规则**，`kernel_task`（pid 0）/ `launchd`（pid 1）显示但不可选中——库里现在没有
   任何此类处理，本机 picker 今天可以选中它们然后注入失败。该仓库也有自己的
   `Documentations/Evolutions/`（已有 0001、0002），这是公开 API 变更，**要在那边单独走一份
   提案**后合入并发版。验证标准：RuntimeViewer 侧两个 tab 除「特殊进程变灰」外行为不变（它的
   `PickerStructureTests` / `ListRowLayoutTests` 继续全绿），并给特殊进程规则补单测。
6. **宿主侧 attach 路径** ✅ **已实现**(门禁 + 选择器整体切换 + 远端 attach)。先按「目标是不是宿主进程」分流——是则原样走今天的本机分支、**一次
   RPC 都不发**；不是才 `attachToRemoteProcess` + `injectionCapability` + `processList`（远端清单
   只来自远端，不混入本机进程）。镜像引擎短路成占位，不实现。按项目规矩给新 ViewModel 补
   `RuntimeViewerApplicationTests` 契约测试。
   **本步的验收标准里要有一条回归项**：选中本机 / Catalyst / 模拟器引擎时，Attach to Process
   的行为与改动前逐像素一致，且不产生任何新的网络往返。
7. **「获取越狱版」入口**：从 release 下载 IPA、落盘、提供拖拽源（真实文件 URL，不能用
   file promise）。要处理「宿主版本与 IPA 版本不匹配」的提示。
8. **端到端验证**：vphone guest 里装越狱版 → 列进程 → 挑一个 → 注入 → 浏览它的 ObjC/Swift
   接口 → 断开 → 重注入。**注意不要用 SpringBoard 判断「浏览接口」这一项**（0014 已记：它的
   主二进制是空壳，没有 `__objc_classlist`，显示为空是正确结果）；用 `backboardd` 这类。
9. **收尾判断**（结果写进决策日志，不允许沉默跳过）：
   - 配套文档：几乎确定要写**使用指南**（越狱版怎么装、为什么 Xcode 装的不行、三条
     entitlement 各管什么），以及**实现说明**（两个 SDK 头缺失陷阱、arm64e 约束、权限矩阵）。
   - 新术语：`no-sandbox` / `no-container` / `task_for_pid-allow` 是既有越狱术语而非项目自造词，
     但「越狱版」作为一个**产品变体名**可能需要进术语表，落地时判定。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-01 | Created as Draft | 起因是「代码注入适配 vphone」。调查后确认：宿主侧注入对 vphone 物理上不成立（guest 独立内核，宿主无 task port），必须在设备内部注入。随后逐级实测把 MachInjector 移植 iOS、枚举、注入、安装四件事全部验通，范围收敛为「给 RV iOS 加一个越狱版 + 宿主加一条 attach 路径」。 |
| 2026-10-01 | 实测推翻「iOS 需要 macOS 那套 daemon + XPC」 | 原以为 iOS 也要像 macOS 一样靠特权 daemon 代做注入。实测 uid 501 的 App 带三条 entitlement 即可自行完成枚举与注入，`SMAppService` / Mach service / `HelperServiceManager` 整层在 iOS 上不需要。这是本提案架构比 macOS 简单一层的原因。 |
| 2026-10-01 | 权限矩阵定稿：沙盒是唯一闸门，注入额外只需 `task_for_pid-allow` | 七个变体对照实测。两个反直觉结论：(a) 容器化状态下 task-port entitlement **完全无效**，加三个和不加行为一致；(b) 注入**只认** `task_for_pid-allow`，Apple 的 `com.apple.system-task-ports` 和 `platform-application` 都不管用。最小集因此是三条，正是越狱安装器本来就会给的，所以本设计不绑 vphone。 |
| 2026-10-01 | 一个被排查陷阱坑过的教训 | 一次 mobile 身份注入失败被误判为权限问题，实际是目标 pid 已退出。是对照组（同目标换 root）报出**不同错误码**才暴露的。判定权限结论前必须确认目标存活；`code=3`（task_for_pid 失败）与 `code=28`（端口无效）含义不同。 |
| 2026-10-01 | 否决「用 vphone 的 `processes.list` 取进程表」 | 数据更全且零不确定性，但会把功能绑死在 vphone 上，真机没有那个 socket。自己枚举已实测可行（438 个进程，名字全中），通用性优先。 |
| 2026-10-01 | 安装方式定为 vphone 内建拖拽 | 评估过三条：socket 分块（1 MiB 上限 + 无 append，还要自带带私有 entitlement 的二进制，公证风险高）、`--api-listen` HTTP（Launchpad GUI 起的 VM 没有这个 flag）、拖拽（内建、无大小限制、无 flag、几乎不耦合 vphone 协议）。选拖拽。顺带记下：vphone 从 pasteboard **立即**读 `.fileURL`，所以必须给真实落盘文件，不能用 file promise。 |
| 2026-10-01 | 用户决策三项 | ①IPA 不内置进 RV macOS，改为从 GitHub release 下载；②越狱版用**独立 target**（可与非越狱版共存于一台设备），而非新增 build configuration；③iphoneos payload 的构建问题单独处理，本提案假设它已修好。 |
| 2026-10-02 | 补入 UI 范围，并查清选择器现状 | 用户追加要求：注入入口只在选中 iOS 引擎时出现，且 `RunningApplicationKit`「要抽象一下，AppKit 作为后端」。查证后发现抽象负担比预期小：`RunningItem` **已经是协议**、泛型 picker **已经架在它上面**，`AttachToProcessViewModel` 的输入**已经是 `any RunningItem`**；真正缺的只有数据源抽象（来源硬编码在两个具体子类里）。RuntimeViewer 侧集成面只有两个文件，业务层零改动。 |
| 2026-10-02 | 用户决策两项：抽象只做数据源、picker 整体切换 | ①「抽象」取**最小读法**——只加 `RunningItemSource` 并把泛型 picker 公开，AppKit UI 与模型层（含 `icon: NSImage?`）都不动，package 继续 macOS-only；拆成平台中立 core + AppKit backend 被否，理由是当前没有任何非 AppKit 前端要消费它，为不存在的消费者拆 888 行 VC 是提前付成本。②选中 iOS 设备引擎时**整个 picker 换成设备进程列表**，而不是加第三个 tab 或另起菜单项——tab 的三个来源不在同一维度上（两个「本机视角」+ 一个「另一台机器」），整体切换让「对哪台设备 attach 就只看那台的进程」不需要解释。 |
| 2026-10-02 | UI 判据定为「目标是不是宿主进程」，分三种形态 | 用户给出更清楚的判据：**能在 Mac 上运行的 TargetEngine 才显示注入界面**，iOS 非越狱版**直接提示不支持**，只有越狱版支持注入。这比我原先写的「选中 iOS 设备引擎就换 picker」准确——它的本质是「宿主侧注入能成立当且仅当目标是宿主进程」，而这正是 `InjectionTargetPlatform` 已经表达的区分（`macOS` / `macCatalyst` / `iOSSimulator` 都是宿主进程，真机不是）。因此它应落成引擎上的一个派生属性，而不是散在 UI 里的一串 `if`。非越狱版那条刻意**不打开空列表、也不给注定失败的注入**。 |
| 2026-10-02 | 镜像引擎列为第四种形态，本次只占位 | 用户指出远程同步来的镜像引擎**也有注入能力，但尚未实现**，先给「暂不支持远程注入」的占位。顺带发现一件值得记下的事：镜像的数据平面是 `.directTCP` → 对端 `RuntimeEngineProxyServer`，而 ProxyServer **自动继承共享命令表**，所以被转发的越狱设备引擎**很可能本来就能应答那三条新命令**——转发对它们是透明的。但这是推测、未实测，所以本次刻意对镜像引擎**短路成占位、不发探测**，不在没验过的链路上给出可能失败的入口。因此门禁要实现成**一次能力探测**而非 `switch` 引擎种类：将来实测通了，占位提示自己消失，不必再改 UI。真正另需工作的是「注入对端 Mac 自己的宿主进程」，那要对端 daemon 配合 + 在对端暂存 payload，属另一件事。 |
| 2026-10-02 | 能力探测升为一条显式命令，三条命令并改名去掉 `device` | 用户定下：命令表加一条**查询对端有没有注入能力**的命令，而不是靠「对端有没有注册某条命令」隐式推断。显式查询的好处是答案能带原因（`requiresJailbrokenVariant` / `helperDaemonNotInstalled` / `unsupported`），而「装个越狱版就行」与「这平台没这条路」对用户是两回事，布尔值表达不了。各引擎自答：本机看 daemon 装没装、iOS 看是不是越狱版、同步来的 Mac Engine 看**对端那台 Mac** 的 daemon、同步来的 iOS 看**那台 iOS** 是不是越狱版——后两者不需要为镜像写特殊逻辑，ProxyServer 转发即得最远端自己的答案。同时把 `deviceProcessList` / `injectIntoDeviceProcess` 改名为 `processList` / `injectIntoProcess`：它们同样服务「同步来的 Mac Engine」，带 `device` 在那个场景里立刻是错名字。 |
| 2026-10-02 | 远端清单只来自远端，且可注入性由远端判定 | 用户要求「数据源要提供对方能注入的数据源，不要显示当前机器的」。两层含义都落进设计：①清单永远来自被选中引擎所在那台机器——选同步来的 Mac Engine 列的是**对端 Mac** 的进程，本机的 NSWorkspace / BSD sysctl 两种来源只服务「目标就是宿主进程」那一类；把本机进程混进远端选择器会让用户拿本机 pid 去注另一台机器。②每个条目自带 `injectability`，**由远端填**——只有远端知道自己的 uid、entitlement 与 daemon 状态。实测依据：uid 501 的越狱版注入不了 uid 0 进程，原样列出 root daemon 等于摆一堆注定失败的目标。**假设（可改）**：不可注入的标灰不隐藏，因为隐藏会让「为什么看不到 SpringBoard」无法回答。 |
| 2026-10-02 | 本机路径短路：目标是宿主进程时一次 RPC 都不发 | 用户要求本机进程（含 Mac 与模拟器）**直接用现有数据源，不要让对方提供**，以免破坏现有体验。采纳，并提升为硬要求而非优化：那条路今天是「打开即出列表」，为形式统一插一次 `injectionCapability` 往返等于给一个已经好用的功能凭空加延迟和新的失败模式（查询超时怎么办？自己问自己有什么意义？）。统一抽象的收益在远端，成本不该由本机付。落地判据是「目标是不是宿主进程」这个引擎派生属性：是则走今天的分支、完全不碰新命令。**本机引擎仍注册 `injectionCapability`**，但那是给*别人*镜像自己时用的。落地步骤第 6 步因此加了一条回归验收：本机 attach 行为逐像素不变且无新增网络往返。 |
| 2026-10-02 | 远程同步的实现本次完全不写 | 用户明确「远程同步的实现暂时不用写，那是以后的事」。于是镜像引擎这一类本次只留两样东西：占位提示，以及一个不妨碍将来解禁的能力模型（`injectionCapability` 经 ProxyServer 转发天然可用，解禁时不必改模型）。连带结果：**本次真正会发出那三条命令的只有「远端 iOS 设备」一类引擎**——本机短路、镜像占位，两头都不发。 |
| 2026-10-02 | 不可用改为 disable toolbar item，不弹提示 | 用户定下：注入不可用时直接 disable toolbar item，省掉提示。采纳——这是 Mac 原生表达（动作不可用就是控件不可用，用户不该点一下才被告知做不到），原因挂 tooltip，解释不丢又不打断操作；项目里已有自定义 tooltip 的既有做法可复用。**连带后果**：「获取越狱版」的入口不能再挂在提示里了（提示不存在了），改为 Attach to Process 的同级菜单项、始终可用——它是获取动作，不是对当前引擎的操作（标为假设，可改）。 |
| 2026-10-02 | 查证发现一处真实的行为收紧，已如实留档 | 实现这条 disable 规则前查了现状：**今天的 Attach to Process 与选中引擎完全无关**，唯一的门是 `SIPChecker.isDisabled()`，`attachItem` 没有任何 `isEnabled` 控制。所以按引擎 disable **会拿掉一个现有能力**——今天选中 iOS 引擎照样能 attach 本机进程。判定为**有意的语义收紧**：attach 从此表示「在当前引擎所在那台机器上挑进程」，而「不管在看哪台机器总是挑本机」在有了设备引擎之后会让人挑错机器。替代路径是把引擎切回 My Mac（toolbar 上的常规操作）。顺带记下 SIP 那条门用的是弹提示、与新门禁的 disable 不一致，是否统一列为待决。 |
| 2026-10-02 | 特殊进程显示但不可选中，上游改动因此变三件 | 用户要求把 `kernel_task` / `launchd` 这类特殊进程 disable 掉、显示但不可选中。查证：上游**已有** `shouldSelect(item:)` 并已接在 `tableView(_:shouldSelectRow:)` 上，所以机制现成；缺的是①**渲染侧变灰**（返 `false` 只是选不中，行看起来仍正常）与②**特殊进程规则本身**（库里现在没有任何此类处理）。远端条目的 `injectability` 映射到同一个钩子，宿主不必为远端再发明一套禁用机制。**本机那条路一并受益**：今天它可以选中 launchd 然后注入失败。 |
| 2026-10-02 | 上游改动变成两处 | 除 MachInjector 外，`RunningApplicationKit` 也要改（加数据源抽象 + 公开泛型 picker）。该仓库同样有自己的 `Documentations/Evolutions/`，且这是公开 API 变更，所以要在那边单独走提案。本提案的落地步骤因此多出一条，且两处上游都得先发版才能动宿主侧。 |
| 2026-10-02 | 状态 Draft → Accepted，开始实现 | 用户批准并要求开工。实现落在 `feature/jailbroken-ios-injection`（worktree `.worktrees/RuntimeViewer-JailbrokenIOSInjection`，基线 `next` @ 968b20e7）。两处仍未决的假设（SIP 那条门是否也改成 disable + tooltip、「获取越狱版」入口的位置）不阻塞落地步骤 1–6，按提案里已写的假设实现，第 7 步前再确认。 |
| 2026-10-02 | 撤销「iphoneos payload 构建失败」这条前置 —— 是我用错了构建入口 | 原记录说真机 payload 以 `swift-async-algorithms` 的并发错误构建失败，并把它列为整条链的前置。补测推翻：那是用独立 `RuntimeViewerServer.xcodeproj` 构建的结果，而**它的 macOS 目标也挂**，且挂在更前面的 `SwiftyXPC` 上 —— 说明问题是那个工程自带的 `Package.resolved` 整体陈旧（async-algorithms 钉 1.1.1，上游 1.1.7 已修掉那段代码），不是 iOS 特有。改用 `RunScript.sh:263` 实际使用的 `RuntimeViewer-Debug.xcworkspace` 后 `EXIT=0`。**教训：复现失败前先确认自己用的是官方构建路径**，否则会把别人的陈旧锁文件当成自己的阻塞。 |
| 2026-10-02 | payload 的 arm64e 要显式指定，并留下一个未实测的待定 | 工程写的是 `ARCHS = $(ARCHS_STANDARD)`，而 `ARCHS_STANDARD` 在 iphoneos 上**不含 arm64e**，所以默认产物是 arm64。传 `ARCHS=arm64e` 同样构建通过（55 MB，`platform 2` / `minos 15.0`）。SwiftPM 侧不用额外处理 —— Debug workspace 已带 `iOSPackagesShouldBuildARM64e = true`。**倾向编 arm64e**（iOS 系统进程是 arm64e，架构对齐无歧义，代价 2 MB）；「arm64 dylib 能不能 dlopen 进 arm64e 进程」未实测，不拿它当依据，落地第 3 步时定。 |
| 2026-10-02 | MachInjector 的 iOS 提案已落盘，成为唯一剩下的前置 | 在 `MachInjector` 仓库建 `Documentations/Evolutions/draft-ios-support.md`（Draft，待批准），实测改动提交在它的 `feature/ios-support` 分支（`81aaaba`），macOS 构建与 28 个测试全绿。该提案比 spike 多一项决定：**remap 路径在 iOS 上按 `#if TARGET_OS_OSX` 整体关掉**，理由是它内嵌的 loader 是 macOS dylib、只能在运行时失败，编译期不存在优于运行时失败，顺带去掉 11167 行 dylib 字节。上游发版前本仓库用 `USING_LOCAL_DEPENDENCIES=1` 开发。 |
| 2026-10-02 | 详细设计里有三处 API 写错，已按真实代码重写 | 初稿的签名是凭印象写的，落地时逐条对不上：①`CommandNames` 是 `String, CaseIterable` 的 **enum**，`extension … { static let … }` 加不进「case」，只能直接加 case；②命令协议叫 `RuntimeEngineRequest`（带 `associatedtype Response`），代码里**没有** `RuntimeRequest` / `RuntimeResponse` 这两个类型；③`InjectionTargetPlatform` 是 `#if os(macOS)` 且在 macOS-only 模块 `RuntimeViewerHelperClient` 里，而且**连 iOS 真机的 case 都没有**（`PLATFORM_IOS` = 2 落在 `.unsupported(2)`，那是「没有对应 payload 切片」而不是「这是真机」）—— 所以它当不了跨平台门禁的判据，门禁属性必须落在 Core。 |
| 2026-10-02 | 平台实现沿用 `engineListProvider` 的既有接缝，不新发明机制 | 注入实现由进程注册：`RuntimeEngine.injectionService`（`static`，因为注入能力是机器的属性，同进程每个引擎答案相同）。`RuntimeViewerCore` 里不放任何平台相关注入代码 —— 它还要为 watchOS / tvOS / visionOS 构建。`nil` 是**有意义的状态**：iOS 非越狱版刻意不注册。各平台此时的答案由 `withoutInjectionService` 给，三个分支含义不同，**macOS 上不能谎报成缺 daemon**（那会把用户送去重装一个装了也没用的东西），要如实答「没人接线」。 |
| 2026-10-02 | 能力查询定为不抛，并顺带解决旧对端兼容 | `injectionAvailability()` 返回值而不抛：它决定控件 enable 与否，每个调用方都只会把错误变成同一件事（当作不可用），所以做一次、做在 Core。连带好处是**比这三条命令更早构建的对端没有这个 handler、dispatch 会失败**，而那与「对端不能注入」不可区分、含义也相同，于是旧对端自动降级为不可用，不需要版本协商。另两条照常抛 —— 调用到它们时门禁已放行，那时的失败是真失败。 |
| 2026-10-02 | 越狱版 target 落地,名为 `RuntimeViewerUsingUIKit-JB` | 用户在 Xcode 里 Duplicate 出 target,我接着配置。Xcode 的复制品有三处必须修:①复制出的 Info.plist 文件引用是**绝对路径**(钉死在一个 worktree,别人检出即坏)——改成相对路径并重命名为 `RuntimeViewerUsingUIKit-Jailbroken-Info.plist`;②`PRODUCT_BUNDLE_IDENTIFIER` 与非越狱版**完全相同**,两个版本无法共存——新增 `RUNTIME_VIEWER_APP_{DEBUG,RELEASE}_JAILBROKEN_BUNDLE_IDENTIFIER` 两个变量;③`CODE_SIGN_ENTITLEMENTS` 仍指向共享的空 entitlements 文件。另外把 `ENABLE_APP_SANDBOX` 置 `NO` —— 它会生成 `com.apple.security.app-sandbox`,与 `no-sandbox` 直接矛盾。两个 app target 共用同一个 `fileSystemSynchronizedGroups`,所以不需要维护文件清单。 |
| 2026-10-02 | 签名刻意设为 Manual + `CODE_SIGNING_ALLOWED = NO` | Xcode 签不出那三条私有 entitlement(没有 provisioning profile 授予),所以这个 target **永远不由 Xcode 安装**。设成 Automatic 会让它悄悄取得一个开发 profile、把 entitlements 剥掉,产出一个看起来正常、却恰好少了全部能力的包 —— 那种失败很难自查。Manual + 禁止签名让它在构建期就说清楚。 |
| 2026-10-02 | 能力开关实现为 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 的 `RUNTIME_VIEWER_JAILBROKEN` | 注册代码(`InjectionServiceRegistrar`)放在三个 target 共用的同步目录里,整体包在这个条件后面。非越狱版因此既不链 `RuntimeViewerDeviceInjection` 也不注册任何东西,`RuntimeEngine.injectionService` 保持 `nil` —— 那正是让它如实回答 `requiresJailbrokenVariant` 的状态,而不是注册一个永远答「不可用」的实现。 |
| 2026-10-02 | payload 缺失单独成一种不可用原因 | 一个 entitlement 齐全但没内嵌 payload 的构建,**能枚举但注不进去**,这是它自己的失败,和「还在容器里」不是一回事。把两者合成一句会把用户送去重装,而问题在 build phase。所以 `injectionAvailability()` 先查 payload 在不在,给出单独的原因。 |
| 2026-10-02 | 下游集成挖出 MachInjector 0.6.0 的一个 bug,已发 0.6.1 | 提案和 MachInjector 的 README 都写「iOS 必须 arm64e」,**那对运行成立、对构建不成立**:Xcode 的 `iOSPackagesShouldBuildARM64e` 是往包的架构里**追加** arm64e 而非替换 arm64,所以即使 App target 钉 `ARCHS = arm64e`,包仍两份一起编,arm64 那份在 `loader_arm64.s` 上报 `instruction requires: pauth`,整个构建挂。修法是在两个 `.s` 的 `#ifdef __arm64__` 内加 `.arch_extension pauth`;实测 10 个切片全部汇编通过,**arm64e 的 `__DATA` 字节逐字节不变**。macOS 永远看不到这个 —— 它的 arm64 基线是 armv8.3,iOS 的要覆盖 A7–A11。 |
| 2026-10-02 | `ARCHS` 必须写在 target 上,不能写在 xcodebuild 命令行 | 第一次试图用命令行 `ARCHS=arm64e`,结果宿主宏可执行文件(`MemberwiseInitMacros` / `PerceptionMacros`)也被强制成 arm64e 而找不到,构建失败。命令行设置会到达**每一个** target —— 项目的 `RunScript.sh:218-224` 早就写明了这点并特意改用 `EXCLUDED_ARCHS`,是我没照做。 |
| 2026-10-02 | 一次假绿:手工改 pbxproj 把四个设置写到了 `buildSettings` 字典外面 | 追加位置落在闭合的 `};` 之后,Xcode 当成 `XCBuildConfiguration` 的游离键,构建看不见。`BUILD SUCCEEDED` 照样出现,但产物是 arm64、**`RUNTIME_VIEWER_JAILBROKEN` 从未被定义**(registrar 编译成空的)。两个巧合把失效伪装成了成功:`CODE_SIGNING_ALLOWED` 我在命令行也传了,`ONLY_ACTIVE_ARCH = NO` 恰好是该 destination 的默认值。是去查产物架构才掉出来的。**教训:改完构建设置先 `-showBuildSettings` 查解析值,再构建;绿灯不证明设置生效。** |
| 2026-10-02 | payload 内嵌走常规 target dependency,**不照搬 macOS 那套暂存脚本** | macOS 侧之所以要「脚本构建 → 固定路径暂存 → copy phase」,是因为 Xcode 拒绝把 iOS-family 内嵌内容挂成 macOS App target 的依赖(项目 `CLAUDE.md` 已记)。越狱版自己就是 iOS,这条限制不存在,于是改用最普通的 `PBXTargetDependency` + Embed Frameworks。差别不只是少写一个脚本:**陈旧 payload 这个失败模式整类消失**——macOS 那边 copy phase 无法分辨暂存路径上的产物是不是本次构建的,所以 `RunScript.sh` 要在 payload 构建失败时**主动清空**暂存目录;依赖关系让构建系统自己保证时序。跨工程引用是现成的:UIKit 工程早已把 `RuntimeViewerServer.xcodeproj` 作为子工程引入,两个 `PBXReferenceProxy` 都在,本次只补了一个 `proxyType = 1` 的 proxy。 |
| 2026-10-02 | payload 定为 **fat(arm64 + arm64e)**,推翻上面「倾向编 arm64e」那条待定 | 当时待定的问题是「arm64 dylib 能不能 dlopen 进 arm64e 进程」。真正该问的是反过来那一半:**iOS 上系统进程是 arm64e,而所有第三方 App 是 arm64**(App Store 不分发 arm64e)。只带 arm64e 就注不进任何第三方 App,只带 arm64 就注不进 `backboardd` 这类系统进程——两种都砍掉一半目标。所以 payload 必须两个切片都有,代价是 Debug 下体积翻倍(55 MB → 约 110 MB)。注入器自己仍是 arm64e-only(App target 按 Xcode 的安全设置参考「Apps stay arm64e-only」),**但「arm64e 进程里的注入器能否注入 arm64 目标」尚未实测**,留到第 8 步;那是 MachInjector 的 shellcode 问题,与 payload 架构是两件事。 |
| 2026-10-02 | 架构写在 `ARCHS[sdk=iphoneos*]` 上,刻意不碰 Distribution 配置 | payload target(`RuntimeViewerMobileServer`)是**共享**的:macOS App 的模拟器 payload 和对外发布的 XCFramework 都用它。条件写成 `[sdk=iphoneos*]` 后模拟器与 Catalyst 原样不动(实测仍为 `arm64 x86_64`),而 Distribution 配置**一行不改**——XCFramework 由 `BuildRuntimeViewerServerXCFramework.sh` 以 Distribution 构建,对外发布的 iOS 切片因此保持 arm64,不会因为本提案变成 fat。Debug 还额外需要 `ONLY_ACTIVE_ARCH[sdk=iphoneos*] = NO`:工程级 Debug 是 `YES`,接着真机构建时只会编设备自身那一个架构,arm64 切片会**静默**消失。 |
| 2026-10-02 | 实测:`ENABLE_POINTER_AUTHENTICATION` 不控制 PAC 代码生成 | 先按 Xcode 自带的安全构建设置参考(「`ENABLE_POINTER_AUTHENTICATION = YES` Builds for arm64e pointer signing」)给 payload 也加了这条,随后发现**越狱版 App target 自己这条是 `NO`**,而它上一轮已经编出过 arm64e 产物。去数产物里的 PAC 指令:主二进制 31 条、debug dylib 345432 条(`pacibsp` / `retab` / `braa` 一类),`cpusubtype 2 / caps 0x80` 与系统 arm64e 二进制一致。结论:PAC 代码生成跟的是 `arm64e-apple-ios` 三元组,那个设置管的是别的事。**所以把它撤掉了**——留一条实测证明为空操作的设置,下一个读到的人会当它是关键。顺带确认上一轮验证的 arm64e 产物是有效的,不是「挂着 arm64e 名字的非 PAC 二进制」。 |
| 2026-10-02 | payload 放 `Frameworks/` 而不是跟 macOS 一样放 `Resources/` | iOS App bundle 是平的,`Bundle.main.resourceURL` 就是 bundle 根,所以 macOS 侧 `url(forResource:withExtension:)` 那套到 `Frameworks/` 里的东西是看不见的。两个选择里取了 iOS 的惯例位置,registrar 改用 `Bundle.main.privateFrameworksURL`。注意**宿主侧仍然是 `Resources/`**(`RuntimeInjectClient` 只会去那里找),两边不统一是有意的,各自随各自平台的惯例。 |
| 2026-10-02 | 记下一个留给第 7 步的隐患:payload 的 `SKIP_INSTALL = NO` | 项目 `CLAUDE.md` 已记过同类坑:带产物的 target 若 `SKIP_INSTALL = NO`,归档时会把自己装进 archive,archive 就不再是 app archive、导出直接失败。payload target 为了发 XCFramework 必须 `SKIP_INSTALL = NO`,而它现在是越狱版的依赖。**普通构建不受影响**(该设置只在 install / archive 动作生效),但第 7 步真要用 `xcodebuild archive` 打 IPA 时会撞上,届时要么用 `-exportArchive` 之外的打包方式,要么在归档命令里覆盖它。先留档,不提前改共享 target。 |
| 2026-10-02 | `otool -L` 查出 payload 有一条非系统依赖,暂存逻辑整体重做 | 内嵌成功后去查产物的加载命令,发现 payload 依赖 `@rpath/libswiftCompatibilitySpan.dylib` —— Swift 的 `Span` 向后部署垫片,因为 payload 的部署目标(15.0)早于把 `Span` 并进 `libswiftCore` 的那个版本,Xcode 于是链接工具链副本并把它内嵌进 App bundle。**原来的 `stagePayload()` 只拷那一个 Mach-O**,目标进程 `dlopen` 时会在自己的 `@executable_path/Frameworks` 里找这个 dylib,找不到。这条差点漏掉的原因很值得记:它的第一条 run-path 是 `/usr/lib/swift`,而**iOS 26.5 的 `/usr/lib/swift` 里确实有这个 dylib、iOS 27 里没有了**(SDK 里对应的 `.tbd` 已改成指向 `libswiftCore` 的别名)—— 所以在 26.5 上测会通过,在 27 上失败,是个按设备版本漂移的 bug。macOS 侧从来没撞上:macOS 27 仍自带它。**修法不改二进制**:payload 本来就带 `@loader_path/Frameworks` 这条 run-path,所以把依赖拷到暂存目录下一个叫 `Frameworks` 的子目录里即可自洽。 |
| 2026-10-02 | 暂存逻辑抽成 `RuntimePayloadStaging`,跨平台以便可测 | 沿用本模块里枚举器的既有先例(刻意不加 iOS 门以便在 macOS 上测)。理由在这里更强:布局错了的表现是**在别人的进程里** `dlopen` 失败,栈上没有我们的帧,是整个功能最难看出错的地方。配 11 个测试,钉住的是会被将来的人改坏的那几条不变量:payload 在暂存根、依赖在 `Frameworks/` 子目录、依赖目录名必须等于 run-path 里那个词、payload 自己的 `.framework` 不重复拷(否则白拷一百多 MB)、权限 0o755、重复暂存可行且不动暂存目录里别人的文件、上游删掉的依赖不会在暂存副本里残留。 |
| 2026-10-02 | 依赖选择取「全拷,排除 payload 自己」而非解析 load command | 更精确的做法是读 payload 的 `LC_LOAD_DYLIB` 只拷实际需要的(App 已经依赖 MachOKit,做得到)。没选它:多拷的那几百 KB 什么都不值,而「将来上游新增一条依赖、只在别人进程里以 `dlopen` 失败的形式暴露」这个代价很高。精确性在这里不是收益方向,冗余才是。 |
| 2026-10-02 | 上游 `RunningApplicationKit` 已实现,但公开面比本提案设想的小一个数量级 | 本提案原话是「把泛型 picker 公开」。落地时发现这句的代价被低估了:**Swift 要求公开类里的每个 `override` 也必须公开**,于是公开泛型 picker 会连带把四十来个 subclass hook、`BaseConfiguration`、`PickerField` 全部推上公开 API —— 更糟的是让 `didConfirm(item:)` / `loadItems()` 变成**外部可调用**,等于绕过 picker 直接触发代理回调。改成走那个库已有的门面模式:`RunningPickerTabViewController` 新增 `Configuration.tabs`(单个 tab 时不再套 `NSTabViewController`,直接托管那一个列表)和 `processItemSource` 一个初始化参数,三个 picker 全部保持 internal。上游提案:`RunningApplicationKit` 仓库的 `0003-injected-item-source.md`,已合入 `main` 并发版 `0.7.0`,83 个测试全绿(原有 69 个一字未改,正是本步的验收标准)。 |
| 2026-10-02 | 不把本机两种数据源改造成 `RunningItemSource` 的实现 | 本提案原话是「现有的两种来源各自成为它的实现」。不照做:进程选择器的刷新是**增量**的(diff 新增/消失的 pid,避免每 2 秒重建四百个对象),而 `loadItems() async throws -> [Item]` 是全量快照语义。套上去等于把一条调过的性能路径换掉,换来的只有形式统一 —— 而本步的验收标准恰恰是「现有两个 tab 行为不变」,改造它是唯一可能破坏该标准的动作。 |
| 2026-10-02 | 不另造 `RuntimeRemoteRunningItem`,改为公开 `RunningProcess.init` | 本提案草拟过一个宿主侧的 `RunningItem` 实现。实现时发现没必要:`RunningProcess` 是纯数据结构、字段齐全(含 `platform`),公开它的 memberwise init 就够了。少一个平行类型,而且列、角标、排序、右键菜单全部直接复用。 |
| 2026-10-02 | 门禁的分流判据落成 `RuntimeEngine.injectionTargetsRunOnThisMachine`,`nonisolated` | 读 `source` 而不做探测:这是「连接通向哪里」的属性,发任何东西之前就已知。`local` / `remote`(XPC 只能到自己 bundle 里的服务)/ `localSocket`(本机已注入的进程,含模拟器)为本机;`bonjour` / `directTCP` 跨网络接口 —— **即使走 loopback 也算远端**,因为进程表归对端所有。`nonisolated` 是必要的:UI 要在显示任何东西之前选分支,让它 `await` 引擎就把这个属性存在的意义(省掉那次往返)又抵消了。switch 不带 `default`,新增 source case 会编译失败,配 8 个测试写明新 case 该落在哪一边。 |
| 2026-10-02 | SIP 那条待决项定了:统一成 disable + tooltip,**且只在「目标是本机进程」那一支生效** | 之前列为待决。按用户定的原则(「动作不可用就是控件不可用」)统一是显然的,但查实现时发现一个更实质的问题:**原来的 SIP 检查无条件拦在点击处**,所以选中一台 iOS 设备引擎时也会弹「请关闭 SIP」—— 而那台设备自己做注入,与本机 SIP 状态毫无关系。所以 SIP 不是按钮整体的门,而是本机那一支的门。 |
| 2026-10-02 | 镜像引擎按提案所述短路成占位,不发探测 | `isMirrored` 问的是引擎管理器而不是引擎本身:引擎「怎么来的」是管理器掌握的事实,`RuntimeSource` 表达不了 —— 镜像引擎的 `directTCP` source 和直连的长得一样。 |
| 2026-10-02 | RunningApplicationKit 依赖临时钉到分支,**已换回版本号 `from: "0.7.0"`** | 用户定的:先把依赖换成 `feature/injected-item-source` 分支跑通,合并后再换回版本号。分支 pin 不可复现,**绝不能进发布归档** —— `Package.swift` 里那条依赖上曾留了注明这件事的注释,现已随分支 pin 一并删除。上游分支已 fast-forward 合入 `main` 并打 `0.7.0`,四个 `Package.resolved`(Debug / Distribution / Packages / CommandLine)全部重新解析过。顺带发现两件事:上游提案的「方案 二/三」还在描述那条被撤回的公开 picker 方案(**那次 commit message 声称提案已记下撤回,实际只记在 CLAUDE.md 里**),已改写并落地编号 0003;Distribution 与两个包级锁文件早已对不上各自的 manifest(UIFoundation 要求 ≥0.37.0 却钉着 0.32.0,MachInjector 要求 ≥0.6.0 却钉着 0.5.1),这次解析一并补齐 —— 对不上的锁文件会被 SwiftPM 直接忽略重算,等于没有锁。 |
| 2026-10-02 | 真机注入后怎么被认领:查清了,复用模拟器那条路 | 上一轮报告里列为待查项。宿主用 `{deviceID}-{pid}` 匹配注入后冒出来的 Bonjour 端点,所以注入**之前**就得知道设备 ID。唯一诚实的来源是 `engine.bookmarkScope` 的 `.identified(.bonjour(deviceID:…))` —— 它把设备 ID 当成可选值携带。**不能用 `hostInfo.hostID`**:对端不发布该键时它会回落到 instance ID 甚至显示名,拿那个去匹配会把本次请求配到另一个进程上。设备 ID 缺失时宁可报错也不猜。注入后等待直接复用 `awaitInjectedBonjourEngine`:真机 payload 和模拟器 payload 走的是同一段代码(`RuntimeViewerServer.swift` 里非 macOS 那一支),广播方式完全一致,所以不需要新机制。 |
| 2026-10-02 | 远端条目的可注入性存在宿主侧,未知 pid 答「不可注入」 | picker 的行类型(`RunningProcess`)描述一个进程,不描述对它的判断,所以判断由 `RemoteProcessItemSource` 在取清单时记下、再经 `shouldSelect` 答回去(同时变灰)。未知 pid 答 `false`:既覆盖清单到达前那一小段,也是安全方向 —— 给出一个对端没有背书的目标,结果是注入失败而不是一个灰行。 |
| 2026-10-02 | **设备进程清单只有真实数量的 ¼,且丢的全是低 pid** —— `proc_listallpids` 的返回值是个数不是字节数 | 真机上暴露:408 个进程只到达 102 个,最小的 pid 三百多,`launchd`(1)、`SpringBoard`(34)、`backboardd`(69) 全不见,于是**唯一能注进去的那类目标(daemon)恰好全被藏起来了**。根因是 `processIdentifiers()` 把第二次调用的返回值当字节数又除了一次 `MemoryLayout<pid_t>.size`,而 `proc_listallpids` 内部已经除过 `sizeof(int)`。在 macOS 上实测:`proc_listallpids(nil,0)` = 1501、带缓冲区调用 = 1482(`ps` 报 1480),现有代码会报 370。内核**按 pid 倒序写入**,所以截断保留的是高位那一截 —— 这就是「只剩新进程」的由来。代码里那句「the kernel has been observed to return a byte count」的注释把一个错误认知写死了,是它导致了这次多余的除法。回归测试断言清单里有 pid 1:launchd 必定存在、必定是第一个被截掉的,与机器上有多少进程无关。 |
| 2026-10-02 | **挂起的 App 注不进去**,报的却是无信息的 `injection timed out` | 真机上第一次注入 `Preferences`(560)失败。逐项排除后定位:`MIMachInjector.m` 注入后等远程线程回报 `MI_INJECTION_DONE` 的预算是 `usleep(10000)` + 10×`usleep(20000)` = **210 毫秒**;而 iOS 会挂起后台 App,挂起进程的线程不被内核调度,引导线程永远跑不到设置标志那一步。证据链:payload 已暂存到盘上(77 MB + `Frameworks/`,权限 0755)、`task_for_pid` 成功(否则是另一个错误码)、靶子毫发无伤仍活着、驻留仅 1 MB 说明 payload 没载入。判据是 jetsam band:挂起的 App 在 band 0、个位数 MB、几乎无 CPU,`backboardd` 在 band 30、127 MB。**这是设计缺口而非环境怪癖** —— 用户从进程表里挑的 App 大概率就是挂起的。调大 210 ms 没用,挂起的进程等多久都不会醒。待定方案见「未决」。 |
| 2026-10-02 | **真机端到端跑通了(对允许 bind 的目标)** —— 注入 → payload 启动 → 广播 → 宿主连接 → **浏览到目标进程里的接口** | vphone guest(iOS 26.6.2)实测:注入 `chronod`(115)后,Mac 的引擎选择器出现 `chronod` 并**分组在 `iphone` 下**(分组键是 `rv-device-id`,所以设备身份是一致的 —— 我此前怀疑它不一致,**推断错误,已推翻**);进去后从设备的 dyld shared cache 读出 `ActivityKit` 的完整 Swift 类型树(enum/struct/泛型角标齐全)。**注意 `chronod` 主二进制本身显示「不含任何类」是正确结果**,daemon 的主二进制常是薄壳,类在它链接的框架里 —— 和 0014 记过的 SpringBoard 是同一个陷阱,判断「浏览接口」是否可用时不能用主二进制。 |
| 2026-10-02 | **实测:`bind()` 被禁的进程里,向外 `connect()` 是放行的** —— 反向连接的前提成立,而且现成的传输层就能用 | 为此写了一次性探针(`SandboxReachabilityProbe`,不进功能分支),故意打一个没人监听的端口,让失败方式本身成为答案:`ECONNREFUSED` = 沙盒放行、对端拒绝,`EPERM` = 沙盒拦下。在 `dasd`(内核日志同时记下 `deny(1) network-bind`,对照组成立)里:`raw-connect` 到**回环**与到 **Mac 的局域网地址**都是 `errno 61 Connection refused`,即两者都放行。Network.framework 同样放行 —— `[C1 … lo0]` 与 `[C2 … en0]` 两条流都走到 `flow:failed_connect, error Connection refused`。(探针本身漏了一个状态:`NWConnection` 把「被拒」报成 `.waiting` 而非 `.failed`,而处理只覆盖了 `.ready/.failed/.cancelled`,所以这两行没打出来 —— 是测量的缺陷,不是平台的。)**关键附带发现**:`RuntimeLocalSocketConnection` 是裸 BSD socket(`socket(AF_INET, SOCK_STREAM, 0)`)、不走 Network.framework,因此完全绕开 NECP —— 而日志里所有 `NECP … Operation not permitted` 全部出在监听那条路上。所以 macOS 为同一个理由已经在用的那个传输层,本来就能在 iOS 上用。失败链条在日志里完整可见:`nw_listener_socket_inbox_create_socket bind(15,…) failed [1]` → `Bonjour listener failed` → `failed to create runtime engine`。目标统计更新为 7 个里 3 个允许 bind(chronod、sharingd、identityservices)、4 个被禁(searchpartyd、mediaplaybackd、backboardd、dasd)。 |
| 2026-10-02 | **认领失败的真因确认:`localDeviceID` 在别人的进程里逐个目标而异** | 引擎选择器里出现了**两个都叫 `iphone` 的分组** —— `chronod` 独占一组,`RuntimeViewer JB` 与 `sharingd` 同在另一组。分组键就是 `rv-device-id`,所以 `chronod` 里算出的设备 ID 与 App 的**不同**,而 `sharingd` 里算出的**相同**;后者的认领随即成功(面板不再报错,直接切过去)。这证实了 `RuntimeNetworkBonjour+LocalIdentity.swift` 注释里预言的那条路:MobileGestalt 答得上来就用它,答不上来退到 keychain 里的 UUID,而**从别人的进程里查 keychain 按进程解析**。注释称这条路「目前不可达而非被防住,靠两道闸」—— 真机上第一道闸(`SIMULATOR_UDID`)根本不存在,只剩 MobileGestalt 一道,而它取决于目标进程的 entitlement:`sharingd` 本职处理设备身份,答得上来;`chronod` 答不上来。**这坐实了落地步骤的第一步(注入时把身份显式交给 payload)修的正是真问题,不再是推断。**(过程更正:我曾因一张只显示单个分组的截图撤回过这个推断,撤错了。) |
| 2026-10-02 | 但 attach 面板仍报超时 —— **引擎来了,认领没认出来** | 同一次注入:宿主 30 秒内没把新引擎认成「刚请求的那个」,弹出 `bonjourEngineNeverAdvertised`,而引擎其实已经连上并可用。已排除的:设备身份不一致(分组证明一致)、payload 启动慢(设备日志显示 `Attach successfully` → `Did Launch` 仅一秒)。剩下两种可能未分清:`{deviceID}-{pid}` 这个 key 逐字对不上,或宿主侧 `connect()` 握手比 30 秒慢(引擎要**握手完成后**才进入 `bonjourRuntimeEngines`,即可被认领的列表)。分清需要一次带 `dns-sd -Z` 的注入,直接读 payload 广播的 TXT。 |
| 2026-10-02 | **payload 继承的是目标进程的沙盒,而 iOS daemon 普遍禁止 `network-bind`** —— 本提案「payload 自己广播 Bonjour」的前提在真机上不成立 | 真机实测,内核直接给出判据:注入 `searchpartyd`(159)后 payload 启动、随即 `Listener failed: NWError 1 (Operation not permitted)`,内核日志 `Sandbox: searchpartyd(159) deny(1) network-bind local:*:55330`。注入 `chronod`(115)则**允许**绑定、注册成功;`mediaplaybackd`(346)同样被拒,`sharingd`(74)允许。**四个目标里两个被拒,所以不能假定目标能监听**,不是偶发,是**逐个目标而异**:payload 跑在目标的沙盒里,能不能监听取决于那个 daemon 的 profile,而 `network-bind` 恰是 iOS daemon 最常被禁的一项。模拟器验不出来:模拟器 guest 的沙盒宽松得多。**本仓库已有现成的先例**:macOS 那条路遇到目标沙盒阻断 XPC 时,回退到「只需要向外 `connect()`」的本地 socket(`RuntimeViewerServer.swift` 里那个 `SandboxProbe.isMachLookupBlocked` 分支);iOS 这条路没有任何回退,只会监听。方向因此是让 payload **反向连接**注入方(App 自己不受沙盒限制、也有本地网络授权),而不是自己开监听 —— 但这会改变谁监听谁连接,宿主侧的 `awaitInjectedBonjourEngine` 认领假设也要跟着改,属于架构级改动,未实施。 |
| 2026-10-02 | 即使目标允许绑定,注入后宿主仍拿不到引擎;**疑为设备 App 自己抢走了唯一的连接名额**(未证实) | `chronod` 那次:payload 注册成功(`DNSServiceRegister … REGISTERED`,端口 55329),**一秒后注销**(`STOP -- duration: 1s`),而服务端的 `connect()` 正是等到有人连上才返回 —— 时间戳与 "Did Launch" 对齐,说明确实有人连上了。但宿主报 `bonjourEngineNeverAdvertised`。怀疑对象:`RuntimeNetworkConnection` 的监听器**接受一个连接就自我取消**(「Stop accepting new connections immediately」),只有一个名额;而浏览端只过滤掉**本进程自己**的广播(`instanceID == localInstanceID`),payload 是另一个进程,所以**设备上的 RV App 看得见也会去连它**,同机必然快过跨网络的 Mac。模拟器同样验不出:模拟器里没有第二个 RV 实例在浏览。证实需要一次目标允许绑定的注入 + `level:"all"` 的日志,看 `Accepted new Bonjour connection` 的对端是谁。 |
| 2026-10-02 | 注入失败的提示文案是模拟器专用的,真机上是错的 | 弹窗写「A **simulator** payload does not connect back…」并建议跑 `xcrun simctl spawn <udid> log show`。那条路的文案被原样复用到设备路径上,建议与操作对真机都不适用。 |
| 2026-10-02 | 远端行有三个字段刻意留空,`platform` 整个不配置 | 跨连接取不到图标;对端不报告内核实际运行的架构;沙盒状态也不报告 —— `isSandboxed: false` 渲染出来是**没有**沙盒角标,而那个角标只在为真时出现,所以这正是「未报告」的诚实呈现。`platform` 字段连配置都不加:一台设备上每个进程平台相同,那一列区分不了任何东西(它存在的意义是在 Mac 上区分模拟器进程与宿主进程)。 |
| 2026-10-02 | 两处映射没有单测,如实记下 | `AttachToProcessViewModel` / `MainViewModel` / `RemoteProcessItemSource` 都住在 App target,而**这个 target 没有测试 bundle**(工程里唯一的测试 target 是 `RuntimeViewerSourceEditorBridgeTests`)。这是既有结构,不在本提案范围内改。因此落地步骤 6 原写的「补 `RuntimeViewerApplicationTests` 契约测试」在这里不适用 —— 真正可测的部分已经测了:门禁的分流判据在 `RuntimeViewerCoreTests`(8 例),选择器的两条可选性规则与数据源在上游仓库(14 例)。剩下的映射只能靠第 8 步端到端覆盖。 |
| 2026-10-02 | sheet 把引擎**持住**,不在确认时重读 | 读自己写的代码时发现的一个窄口子:选择器用「打开 sheet 那一刻的引擎」列清单,而 ViewModel 原本在用户确认时才去读 `documentState.runtimeEngine`。两者可以不一致 —— 对端断开后被替换会在 sheet 打开期间换掉文档的引擎 —— 而用户挑的那个 pid **只在它被列出来的那台机器上有意义**。重读等于拿另一台机器进程表里的标识符去注入当前选中的引擎,正是本设计一再要避免的那类错误。改成由协调器把同一个引擎传给两半。 |
| 2026-10-02 | 顺带在真实构建里验证了模拟器切片未受影响 | 为了拿一个干净的绿灯,把模拟器 payload 建出来暂存到 copy phase 期望的位置。产物是 `x86_64 arm64` —— 这比之前只用 `-showBuildSettings` 查解析值更硬地证明了 `ARCHS[sdk=iphoneos*]` 那条改动没有碰到模拟器与 Catalyst 切片。 |
| 2026-10-04 | 打包固化成仓库里的 `BuildJailbrokenIPAScript.sh` | 越狱版的签名**不可能**交给 Xcode（五条 entitlement 没有任何 provisioning profile 授予，target 因此带 `CODE_SIGNING_ALLOWED = NO`、产物是未签名的），所以它从来是「`xcodebuild` 构建 → `vphone-cli sign` 逐个签 → 手工 zip 成 `Payload/`」三段手工操作，此前只存在于一个一次性脚本里。固化时把原先写死的三处改成现读：**bundle identifier 从产物 `Info.plist` 读**（Debug 是 `dev.JH…`、Release 是 `com.JH…`，写死一个会在另一个配置上签错身份）；**要签的 Mach-O 用 `find` + `file` 现找**（内嵌框架随包依赖图变，写死清单会静默过期，而漏签一个框架的表现是设备上启动失败、离脚本很远）；**校验用的 entitlement 清单从 entitlements 文件自己读**（一次性脚本那条 grep 漏匹配了 `com.apple.multitasking.unlimitedassertions`，五条只显示四条，得另外手工核对，现在加一条就自动纳入校验且少一条直接失败）。另加两条原先没有的检查：主可执行必须有 **arm64e** 切片（没有就注不进系统进程），以及 entitlements 从**打好的 .ipa** 里读回来核对，因为被安装的是 .ipa 而不是暂存目录。只删 `__preview.dylib`、保留 `.debug.dylib`：`otool -L` 查过，主可执行真的链接后者，删了起不来。默认 `Debug`，因为那是真机验证过的配置。 |
| 2026-10-04 | **越狱版只能用带 `iOSPackagesShouldBuildARM64e` 的 workspace 构建** —— `RuntimeViewer.xcworkspace` 不带，用它构建必在链接载荷时失败 | 写打包脚本时默认选了 `RuntimeViewer.xcworkspace`（主 workspace，远程 pin，看起来是最中立的选择），构建跑了十分钟后死在 `RuntimeViewerMobileServer` 的链接步：`Undefined symbols for architecture arm64e`，点名 `RuntimeViewerCore.RuntimePayloadRendezvous`、`RuntimeViewerCommunication.RuntimeNetworkBonjour`、`OSToolbox.LoggableMacro` —— 即它链接的每个 SwiftPM 包产物都没有 arm64e 切片。根因是**那是个 workspace 级设置**：三个 workspace 里只有 `-Debug` 和 `-Distribution` 的 `WorkspaceSettings.xcsettings` 写了 `iOSPackagesShouldBuildARM64e=true`，主 workspace 没有。越狱版 App 是 `ARCHS = arm64e`、载荷是 `arm64 arm64e`，两者都要包产物有 arm64e，所以这个开关对本变体是硬前提。**错误信息里没有任何一个字指向 workspace**，而代价是一次完整冷编，所以脚本里加了一条前置检查：workspace 的 settings 不含这个键就立刻失败并说明换哪个。脚本默认因此改为 `RuntimeViewer-Debug.xcworkspace`。验收（走 Debug workspace 重跑）：主可执行 `arm64e`、载荷 `arm64 arm64e`、四个内层 Mach-O 各自有签名、五条 entitlement 从打好的 .ipa 里逐条读回来全部命中、被跟踪的 `Package.resolved` SHA 未变。 |
| 2026-10-05 | 打包脚本不再写死 `vphone-cli`，签名器改为 `vphone-cli` / `ldid` 二选一、按装了哪个自动挑，`--signer` 可指定 | 用户在一台没装 `vphone-cli` 的机器上跑脚本直接被拒。而脚本自己的注释早就写明 `vphone-cli sign` 写出来的字节和 `ldid -S -M -K -I` 一样 —— 既然等价，就没有理由把唯一的那个包装器设成硬前提。实测 `ldid` 这条路：主执行档 `ldid -S<ent> -I<id>` 后 `codesign -dv` 显示 `Identifier` 与 `CodeDirectory` 都正确嵌入，五条 entitlement 能被脚本原有的 `codesign -d --entitlements -` 校验步骤完整读回；胖二进制（载荷 arm64 + arm64e）两个 slice 都签上。`codesign` 在 stderr 报的 `no signature` 指的是没有 CMS 证书签名，伪签名本来就没有，和原注释说的「`codesign --verify` 按设计就会拒」是同一件事，不影响校验。顺带把 `--help` 的 `sed -n '2,28p'` 改成按 `set -euo` 定位 —— 写死的行号在这次改动里当场就过时了，而且是静默截断用法说明。 |

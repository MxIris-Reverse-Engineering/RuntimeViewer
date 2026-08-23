# 0013 - 支持注入 iOS Simulator 进程

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-08-18
- **最后更新**: 2026-08-22
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `feature/inject-ios-simulator-process`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

让 Attach to Process 能把 `RuntimeViewerServer` payload 注入到 iOS Simulator 进程里。

当前这条路不但不通，而且**每试一次就打崩一个模拟器进程**：注入器把自己（宿主 macOS）地址空间里的
函数地址写进 shellcode，交给模拟器进程去执行；模拟器进程有独立的 dyld shared cache，同一地址落在
完全不相干的代码上。本提案分两步：先加平台守卫止血，再把符号解析从「在注入器身上 `dlsym`」改成
「针对目标进程解析」，并补齐 payload 投递与通信通道。

## 动机

### 现在会崩

Attach to Process 的进程列表来自宿主的运行进程枚举，模拟器进程（SpringBoard 及模拟器内的一切 app）
都在列表里，看上去可选。选中之后走 `AttachToProcessViewModel.transform(_:)`
（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Attach Process/AttachToProcessViewModel.swift:64`）
→ `RuntimeInjectClient.injectApplication(pid:dylibURL:remapEntrySymbol:)` → daemon 侧
`InjectionStrategy.initialAttempt(forTarget:payloadPath:)` 选路 → `MIMachInjector.injectToPID:dylibPath:error:`。

2026-08-18 一次操作打崩了三个 SpringBoard（pid 42475 / 74181 / 32662，崩溃报告在
`~/Library/Logs/DiagnosticReports/SpringBoard-2026-08-18-1125{06,07,08}.ips`），全部
`EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x10`。

用户看到的错误是 `task_for_pid(74181): (os/kern) failure`。**这条是二次失败，不是原因**：该消息格式
只存在于 `MIMachInjectorRemap.m:1071`（dlopen 路径写的是 `could not retrieve task port for pid: %d`，
async 路径写的是 `Failed to get task port for pid %d`）。实际顺序是 —— dlopen 注入把目标打崩 →
注入器等 `MI_INJECTION_DONE` 标志超时 → daemon 回退到 remap 路径 → 目标已死 → `KERN_FAILURE`。

### 为什么值得做

模拟器是 iOS 逆向最常用的观察环境，且比真机宽松得多（SIP 已关、无需 developer disk image、
进程随时可重启）。payload 侧的能力其实**已经具备**：`RuntimeViewerMobileServer` target 的
`SUPPORTED_PLATFORMS` 已包含 `iphonesimulator`，且与 macOS 版共享同一份
`RuntimeViewerServer/RuntimeViewerServer/main.m`，dlopen 入口（`__attribute__((constructor))`）
和 remap 入口（`runtime_viewer_server_start`）都在。缺的只有注入这一段。

## 前期调研

### 崩溃根因（已查证，寄存器级）

`MIMachInjector.m` 在**注入器自己的地址空间**解析三个符号，再 `memcpy` 进 shellcode 写到目标：

```objc
// MIMachInjector.m:229-231
uint64_t pcfmt_address           = ptrauth_strip(dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"), ...);
uint64_t dlopen_address          = ptrauth_strip(dlsym(RTLD_DEFAULT, "dlopen"), ...);
uint64_t sandbox_consume_address = ptrauth_strip(dlsym(RTLD_DEFAULT, "sandbox_extension_consume"), ...);
```

`loader_arm64.s` 的 shellcode 入口把参数摆好后 `blr` 过去：

```asm
add    x0, sp, #0x8          // &thread
mov    x1, x8                // attr = NULL  (x8 = 0)
adr    x2, __thread_entry    // start_routine
mov    x3, x8                // arg  = NULL
adr x9, ___patch_pthread_create
ldr x9, [x9]
blr x9
```

三份崩溃报告的寄存器与之逐项吻合：

| 寄存器 | 三份报告实测 | shellcode 预期 |
|---|---|---|
| `x0` | `sp + 8`（三份一致） | `add x0, sp, #0x8` |
| `x1` | `0` | `attr = NULL` |
| `x3` | `0` | `arg = NULL` |
| `x2` | `0x1071f8050` / `0x108534050` / `0x107f58050` | `__thread_entry`，三份全是 16KB 页对齐 + `0x50`，而该标号在 shellcode 内的偏移正是 `0x50`（基址由 `mach_vm_allocate` 给出，必然页对齐） |
| `pc` | `0x180188ed4` = 模拟器 cache 里 `libdispatch` 的 `dispatch_once` | —— |
| `lr` | `0x1890c3480`（三份一致） | —— |
| `far` | `0x10` | —— |

宿主实测（同一 boot session，`kern.boottime` = 2026-08-17 08:59:48，shared cache slide 未变）：

```
libsystem_pthread.dylib          base = 0x1890bb000
pthread_create_from_mach_thread       = 0x1890c347c   （偏移 0x847c）
```

`lr - 0x1890c347c = 4`，**三份报告全部如此**。即：远程线程跳到注入器算出的
`0x1890c347c`，在模拟器进程里那个地址属于 `Network.framework`，执行第一条指令（4 字节）就是个分支，
跳进模拟器的 `dispatch_once`；此时 `x1` 还是 loader 给 `pthread_create_from_mach_thread` 准备的
`attr = NULL`，`dispatch_once` 把它当 block 解引用 `+0x10` 取 invoke 指针 → `SIGSEGV at 0x10`。

**排除 remap 路径**：`loader_arm64_remap.s` 的 `_remap_stage1_entry` 先 `bl _apply_fixups`，
之后 `x0 = &_cfg_pthread_out`（`__DATA` 内地址，不是 `sp+8`）。形状对不上。

`MIMachInjectorRemap.m` 的第 3 / 4 / 5 步（`FindLibObjCMapImages()`、
`dlopen("/usr/lib/swift/libswiftCore.dylib")` 后取 `swift_register*`、
`dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread")`）是同一个病，只是本次没执行到。

### 模拟器进程的镜像布局（`vmmap` 实测，只读）

对运行中的 `gamecontrollerd`（pid 12708，iOS 26.5 模拟器）实测：

```
__TEXT  100d94000-100e3c000   /usr/lib/dyld                                     ← 宿主 dyld
__TEXT  100f58000-100f94000   /usr/lib/system/libsystem_kernel.dylib            ← 宿主
__TEXT  100ff4000-101044000   RuntimeRoot/usr/lib/dyld_sim
__TEXT  101158000-101168000   /usr/lib/system/libsystem_pthread.dylib           ← 宿主，独立映射
__TEXT  180075000-1800a01d3   RuntimeRoot/usr/lib/system/libdyld.dylib          ← 模拟器 cache
__TEXT  180185000-1801cb000   RuntimeRoot/usr/lib/system/libdispatch.dylib      ← 模拟器 cache
__TEXT  1a2c33000-1a2c37674   RuntimeRoot/usr/lib/system/libsystem_sandbox.dylib← 模拟器 cache
```

**关键事实：`libsystem_pthread` 与 `libsystem_kernel` 用的是宿主 macOS 那一份**（线程与系统调用
必须走宿主内核），只是装在不同地址。所以 `pthread_create_from_mach_thread` 这一半不需要解析模拟器
cache，只需要知道它在目标进程里的加载基址 —— 那个基址就在目标的镜像列表里。

**但偏移不能照抄注入器自己那一份**（2026-08-23 实测更正，原文的算法是错的，见决策日志）。
`/usr/lib/system/libsystem_pthread.dylib` 是 universal 文件，两个 slice 的符号偏移并不相同：

```
arm64  slice:  _pthread_create_from_mach_thread @ 0x7d84
arm64e slice:  _pthread_create_from_mach_thread @ 0x847c      ← 差 0x6f8
```

注入器进程用的是宿主 shared cache 里那份（arm64e，实测偏移 `0x847c`）；模拟器进程是 arm64，
它那份 `libsystem_pthread` 独立映射、偏移是 `0x7d84`。拿宿主偏移去加目标基址，落点会比正确地址
高 0x6f8 字节 —— 正好落在函数体中间，跳过去照样崩，而且症状与「地址完全解析错」难以区分。

```
注入器（arm64e，来自宿主 cache）：  0x188dd9000 + 0x847c = 0x188de147c
目标（arm64，独立映射）：          0x104f84000 + 0x7d84 = 0x104f8bd84   ← 正确
                                   0x104f84000 + 0x847c                  ← 照抄宿主偏移会得到这个，错
```

另两个符号在模拟器 cache 里，需要解析 cache 文件。

### 模拟器 shared cache（已定位）

```
/Library/Developer/CoreSimulator/Caches/dyld/25F84/com.apple.CoreSimulator.SimRuntime.iOS-26-5.23F77/
  dyld_sim_shared_cache_arm64        2.8 GB
  dyld_sim_shared_cache_arm64.01     442 MB
  dyld_sim_shared_cache_arm64.map    417 KB   （文本，逐镜像段地址表）
  dyld_sim_shared_cache_arm64.atlas
```

路径规律：`.../Caches/dyld/<宿主 build>/<SimRuntime 标识>/dyld_sim_shared_cache_<arch>`。

`.map` 里的地址与上面 `vmmap` 实测**完全一致**（libdyld `0x180075000`、libdispatch `0x180185000`、
libsystem_sandbox `0x1a2c33000`），说明该次运行 cache slide 为 0。**但不可假设恒为 0**，实现仍需从
目标进程读取实际 slide。

`dyld_sim` 本体是 stripped（`nm` 无输出），不能靠它拿符号。

### 依赖已具备的能力

- **MachOKit 支持 dyld shared cache**，且项目已在用：
  `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift:189` 使用 `DyldCacheLoaded.current`。
  解析磁盘上的 cache 走 `DyldCache`。
- **payload 侧已支持模拟器**：`RuntimeViewerServer.xcodeproj` 的 `RuntimeViewerMobileServer` target，
  `SUPPORTED_PLATFORMS = "appletvos appletvsimulator iphoneos iphonesimulator watchos watchsimulator xros xrsimulator"`，
  `IPHONEOS_DEPLOYMENT_TARGET = 15.0`，与 macOS 版共享 `fileSystemSynchronizedGroups`（同一份源码）。
  `BuildRuntimeViewerServerXCFramework.sh` 已能构建全平台 XCFramework。
- **通信通道已经就位，且已支持模拟器**（2026-08-18 复核，此前判断有误，见决策日志）。
  `RuntimeViewerServer.swift:52` 按**编译期**条件分流，不是运行期探测：

  ```swift
  #if os(macOS) || targetEnvironment(macCatalyst)
      // SandboxProbe → localSocket 或 remote(XPC)
  #else
      // Bonjour
  #endif
  ```

  `RuntimeViewerMobileServer` 编出来的 payload 落在 `#else`，走 **Bonjour**，与 localSocket 无关。
  而 Bonjour 这条路本身已经把模拟器当一等场景：
  `RuntimeNetworkBonjour.isSimulatorKey = "rv-sim"`（`RuntimeNetwork.swift:79`），广播时按
  `RuntimeDeviceMetadata.current.isSimulator` 置位（`:177-178`），宿主侧
  `MainViewModel.swift:125` 用它区分设备图标；`localHostName` 也有
  `#if !targetEnvironment(simulator)` 分支。
  既有用法是 `RuntimeViewerUsingUIKit/App/AppDelegate.swift:27` —— 在模拟器里跑 RuntimeViewer 的
  iOS app，广播 Bonjour 由宿主 macOS 版发现。**payload 侧与通道侧都已经跑通过，缺的只有投递方式。**

### 现状的两个缺口

- **投递**：app bundle 里只有 macOS payload。实测
  `/Library/Frameworks/RuntimeViewerServer.framework/RuntimeViewerServer` 三个 slice
  （x86_64 / arm64 / arm64e）`vtool -show-build` 全部是 `platform MACOS`，没有 `IOSSIMULATOR`。
- **策略选路没有平台维度**：`InjectionStrategy.initialAttempt(forTarget:payloadPath:)`
  （`../swift-helper-service/Sources/HelperServices/InjectionService/Implementation/InjectionStrategy+Probe.swift`）
  只探 seatbelt 的 `file-map-executable`，不看目标平台，也不看目标 payload 是否匹配。

### 可行性验证：已通过（2026-08-18 实测）

落地步骤 1 已执行完毕，**结论是这条路完全走得通**。

构建：`xcodebuildmcp simulator build --scheme RuntimeViewerMobileServer`（sibling workspace，
独立 DerivedData）产出
`Debug-iphonesimulator/RuntimeViewerServer.framework/RuntimeViewerServer` ——
`platform IOSSIMULATOR` / `minos 15.0` / `sdk 26.5`，arm64，adhoc 签名，
`_runtime_viewer_server_start` 与 `_swift_initializeRuntimeViewerServer` 两个入口符号俱在，
动态依赖全部落在模拟器 runtime 自带的系统库内（唯一的 `@rpath/libswiftCompatibilitySpan.dylib`
是 weak）。

注入：用 lldb attach 一个**系统 daemon**（`gamecontrollerd`，pid 58675，iOS 26.5 模拟器）后
`expr (void*)dlopen(payload, RTLD_NOW)`。刻意不用 SpringBoard。

| 检查项 | 结果 | 证据 |
|---|---|---|
| dyld 是否接受该 payload | **通过** | `dlerror()` 返回 `NULL`；`vmmap` 显示四个段已映射（`__TEXT 108ef0000-10a098000` 等） |
| Swift runtime 是否起来 | **通过** | os_log 三条齐全：`Attach successfully`(14:34:29.306) → `RuntimeViewerServer Will Launch`(14:34:30.015) → `RuntimeViewerServer Did Launch`(14:34:33.180)，无异常分支 |
| Bonjour 能否广播 | **通过** | `dns-sd -B _runtimeviewer._tcp local` 在 14:34:31.199 出现 `Add … iPhone 17 Pro` |
| 宿主能否连回 | **通过** | 宿主 `RuntimeViewer[26880]`：`[C2 Bonjour#62d518f4] start` → `resolver:receive_bonjour` → `Socket received CONNECTED event` → `ready`，端口 52406 与目标侧 listener 端口一致 |
| 目标进程是否存活 | **通过** | 注入后进程状态 `Ss`，未崩溃，无新崩溃报告 |

**一个容易误读的现象**：Bonjour 广播在 14:34:32.365 就 `Rmv` 了，看着像失败，其实是成功后的正常
收尾。目标侧日志显示顺序是 `[L1] Handling inbound connection [C1 …:52406]` →
`nw_listener_cancel_block_invoke [L1] cancel` → `[L1] reporting state cancelled` ——
listener 收到宿主的连接后主动 cancel，不再接受新连接，Bonjour 注册随之撤销。连接本身
（`[C1 …] reporting state ready`）是活的。

**据此推翻前一版的担忧**：注入目标是没有 `NSLocalNetworkUsageDescription`、进程沙盒也不同的系统
daemon，Bonjour 照样工作 —— 模拟器上本地网络权限不构成障碍。

连接实际走 link-local：目标侧 `local: 169.254.175.207:52406`（`lo0`），宿主侧经 `en21` 连入。
与真机 Bonjour 是同一机制，不是模拟器特有路径。

### 阻塞问题：iOS 端的 Bonjour 身份是设备级的，装不下「一台设备多个进程」

2026-08-18 复验发现的**新阻塞项**，比原提案预估的范围更大。

**成因**：iOS 分支的身份设计假设「一台 iOS 设备上只有一个嵌入 Server 的 app」——
这在原场景（`RuntimeViewerUsingUIKit` 自带 Server）下成立，注入打破了它。
`RuntimeViewerServer.swift` 的 `#else` 分支：

```swift
let name = RuntimeNetworkBonjour.localHostName      // 设备名，如 "iPhone 17 Pro"
let deviceID = DeviceIdentifier.uniqueDeviceID      // MobileGestalt UDID，设备级
runtimeEngine = RuntimeEngine(source: .bonjour(name: name, identifier: .init(rawValue: deviceID), role: .server))
```

对照 macOS 分支用的是 `processName` + `processIdentifier`（进程级），iOS 分支两个字段**都是设备级**。

**后果不止于显示错乱**。宿主的 `RuntimeEngineManager.connectToBonjourEndpoint(_:attempt:)`
（`:234`）用 **Bonjour 服务名**做去重键：

```swift
guard !knownBonjourEndpointNames.contains(endpoint.name) else {
    #log(.info,"Skipping duplicate Bonjour endpoint: \(endpoint.name) ...")
    pendingReconnectEndpoints[endpoint.name] = endpoint
    return
}
```

同一台模拟器上注入的第 2 个及以后的进程，服务名与第 1 个完全相同，会被判为「重复端点」并塞进
`pendingReconnectEndpoints` 等第一个断开后才重连 —— 而 `pendingReconnectEndpoints` 也按 name 键，
多个进程还会互相覆盖。**第二个进程永远连不上。**

**实测**（2026-08-18，同一台 iPhone 17 Pro 模拟器，`launchd_sim` 42417）：

| 进程 | pid | 结果 |
|---|---|---|
| `gamecontrollerd` | 58675 | `TCP …:52406->…:52407 (ESTABLISHED)` |
| `nanoappregistryd` | 3964 | `TCP *:56487 (LISTEN)` —— 一直挂着，无人连接 |

`dns-sd` 显示两次广播的 Instance Name 都是 `iPhone 17 Pro`；宿主日志：

```
15:34:01.096  Discovered new endpoint: iPhone 17 Pro, instanceID: 390EDC20-5C21-4955-8DF4-5A27478EB365
15:34:01.098  Skipping duplicate Bonjour endpoint: iPhone 17 Pro, queueing for reconnect after current engine terminates
```

**一个可用的现成材料**：TXT 里的 `rv-instance-id` 对每个进程**已经是不同值**了 ——
`localInstanceID` 走 `UserDefaults.standard`，注入到不同宿主进程时落在不同的 preferences 域。
去重逻辑没有用它，用的是 name。但直接改用它并不合适：其语义是「安装实例」而非「进程」，
且**有副作用** —— 会往被注入进程的 preferences 里写 `RuntimeViewer.localInstanceID`
（注入 SpringBoard 就是往 SpringBoard 的 plist 写）。

### 仍未验证（推测，留待落地时验掉）

可行性已经确立，剩下两条只影响**注入器实现细节**，不影响提案成立：

1. ~~**arm64 目标上 shellcode 的 PAC 指令**~~ —— **已验，2026-08-23**。原文：`loader_arm64.s` 含
   `paciza` / `pacibsp` / `retab`，按 ARM 规范 PAC enable 位关闭时退化为无操作，推测无害，但 lldb
   走的是 dyld 自己的 `dlopen`、没经过 shellcode，所以未被覆盖。
   接入 `MITargetSymbolResolver` 后的第一次真实注入把这条验掉了：目标返回了它自己
   `dlerror()` 的文本（`MIMachInjectorErrorTargetRefusedToLoadDylib`）。要产生这条消息，
   shellcode 必须在目标里依次跑完 `pthread_create_from_mach_thread` → `dlopen` → `dlerror` →
   写回 report block，四个地址全部来自目标符号表。**PAC 指令没有构成障碍**。
   （那次注入本身仍失败，原因是投的是 macOS slice —— 见决策日志 2026-08-23 的「dyld_sim 路径规则」条。）
2. **sandbox extension token 跨平台是否有效**。`sandbox_extension_issue_file_to_process` 发的是
   宿主 sandbox 的 token，模拟器进程 consume 时走的是模拟器 cache 里的 `libsystem_sandbox`；
   底层仍是宿主内核的 sandbox，推测兼容。本次 lldb 路径同样绕开了它。

## 提议方案

分两个阶段，阶段一独立可交付。

### 阶段一：平台守卫（止血）

在 daemon 侧注入入口加一道守卫：读目标进程主可执行文件的 `LC_BUILD_VERSION` platform，与宿主平台
不一致时**直接抛出说人话的错误并中止**，不进入 `task_for_pid` / `thread_create_running`。同时在
Attach to Process 列表里把跨平台进程标为不可用并给出原因。

这一步的价值与阶段二无关：当前状态下每次误操作都会打崩一个模拟器进程，且 shellcode 页与自旋的
mach thread 会永久留在目标里（`MIMachInjector.m` 的 cleanup 注释里明确说不回收）。

### 阶段二：让 dlopen 路径支持 iOS Simulator 目标

1. **符号解析改为针对目标进程**。新增一个解析器，输入 task port，输出目标进程里三个符号的绝对地址。
2. **按目标 arch 分流 thread state 构建**。arm64 目标不做 PAC 签名。
3. **payload 按目标平台选片**，并把 `iphonesimulator` slice 投递到目标可读的位置。
4. **身份改造：设备做 Section、进程做条目**。让同一台模拟器上被注入的多个进程并入一个 Section，
   而不是各成一个同名 Section。这是复用 Bonjour 通道带来的必修项 —— 与注入器完全解耦，
   可独立交付并用 lldb 单独验证。

### 非目标

- **不支持 iOS 真机**。真机走的是 Bonjour + 手动集成 payload 那条路，与本提案无关。
- **不支持 x86_64 模拟器**。Apple Silicon 上模拟器进程是 arm64（崩溃报告 `"arch": "arm64"` 已确认），
  Intel 宿主不在本次范围。
- **不改 remap 路径**。remap 路径同样有「宿主地址喂给目标」的问题（还多出 `map_images` 与
  `swift_register*` 两组），但它的修法要连 chained fixups 与 runtime handoff 一起重做，量级不同。
  本次让模拟器目标**只走 dlopen 路径**；若目标拒绝 dlopen，如实报错而非回退 remap。
  **已兑现（2026-08-23）**：`InjectionService` 在目标平台与 daemon 平台不同时把 remap 回退关掉，
  错误里连带说明为什么没有第二次尝试。留了一个口子 —— 调用方仍可显式 pin remap，
  否则这条路径修好之后没有任何办法验证它 —— 但 daemon 会记一行「大概率会打死目标」。
- **第一版只做 iOS Simulator**。tvOS / watchOS / visionOS 模拟器在设计上不排斥（cache 路径规律相同），
  但不在本次验证范围，不声称支持。
- **不做「注入后自动重连」**。模拟器进程重启后 pid 变化，本次不处理会话恢复。

## 详细设计

### 目标进程符号解析

新增 `MITargetSymbolResolver`（Objective-C，随 MachInjector 一起演进），职责是把「符号名」解析成
「目标进程里的绝对地址」：

```objc
/// Resolves a symbol to its address *inside a target process*, which may run a
/// different dyld shared cache than the injector (iOS Simulator targets do).
@interface MITargetSymbolResolver : NSObject

/// Snapshots the target's loaded-image list and shared-cache slide.
/// Fails if the task port is dead or `dyld_all_image_infos` cannot be read.
+ (nullable instancetype)resolverForTask:(mach_port_t)task
                                   error:(NSError **)error;

/// Absolute address of `symbolName` in the target, or 0 if not found.
- (uint64_t)addressOfSymbol:(NSString *)symbolName
                   inImage:(NSString *)imageSuffix
                     error:(NSError **)error;

/// The target's Mach-O cputype / cpusubtype, for PAC and slice decisions.
@property (nonatomic, readonly) cpu_type_t targetCPUType;
@property (nonatomic, readonly) cpu_subtype_t targetCPUSubtype;

@end
```

内部按符号所属镜像分两条路：

| 符号 | 所属镜像 | 解析方式 |
|---|---|---|
| `pthread_create_from_mach_thread` | 宿主 `/usr/lib/system/libsystem_pthread.dylib`（目标里独立映射） | 从目标 image list 取该镜像的加载基址，再解析**目标进程内存里**那份 Mach-O 的 `LC_SYMTAB` 求偏移。**不得**使用注入器自身的偏移 —— arm64 与 arm64e slice 的偏移不同（`0x7d84` / `0x847c`），而注入器与目标未必同 arch |
| `dlopen` | 模拟器 cache 的 `libdyld.dylib` | MachOKit 解析 `dyld_sim_shared_cache_<arch>` 的导出，得到 unslid 地址；加上目标 cache slide |
| `sandbox_extension_consume` | 模拟器 cache 的 `libsystem_sandbox.dylib` | 同上 |

目标侧的两项输入都来自 `dyld_all_image_infos`：

```objc
struct task_dyld_info dyldInfo;
mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
task_info(task, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
// mach_vm_read dyldInfo.all_image_info_addr →
//   infoArray        : 逐 image 的 imageLoadAddress + imageFilePath
//   sharedCacheSlide : cache 的 slide
//   sharedCacheBaseAddress
```

~~**待验证的实现风险**~~ —— **已验证通过，2026-08-23**：`TASK_DYLD_INFO` 返回的就是 `dyld_sim`
维护的那一份，退路不需要了。对 iOS 18.5 模拟器的 `peopled` 实测（只读探针）：

```
sharedCacheSlide     = 0x0
sharedCacheBaseAddr  = 0x180000000
infoArrayCount       = 580     → 576 个模拟器镜像 + 3 个宿主镜像
宿主镜像恰好是：libsystem_platform / libsystem_kernel / libsystem_pthread
```

`libsystem_pthread.dylib` 在镜像列表里、加载基址可直接读出，分流设计因此成立。

两个容易误判的点：

- `dyldPath` 字段读出来是宿主的 `/usr/lib/dyld`，尽管镜像列表是模拟器的 —— **不能用它判断目标
  是不是模拟器进程**。
- `sharedCacheSlide` 这次是 0，与 `.map` 文件一致，但仍须从进程读取，不得写死。

cache 文件路径由目标进程可执行路径推导（`.../Runtimes/<name>.simruntime/...` → SimRuntime 标识）
或直接读 `CoreSimulator` 的 device plist，两者都比硬编码稳。

### thread state 按 arch 分流

`MIMachInjector.m` 现在无条件给 PC 做 PAC 签名：

```objc
__darwin_arm_thread_state64_set_pc_fptr(thread_state,
    ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0));
```

原计划按 `resolver.targetCPUSubtype` 分流：目标是 `CPU_SUBTYPE_ARM64E` 时保持现状；目标是
`CPU_SUBTYPE_ARM64_ALL` 时直接写裸地址，且跳过 `thread_convert_thread_state`（那是 arm64e 的机制）。

**实测下来这项分流不是必需的（2026-08-23）。** 上面那段无条件 PAC 签名的代码原样未改，
就把 arm64 的模拟器 SpringBoard 注入成功了（payload 启动三条日志齐全，目标存活）。
**原因未查明** —— 可能是签名位对该目标恰好无害，也可能被链路上某处消化掉了。故：

- 分流**降级为可选优化**，不再是本提案的落地项；
- 但**不删除本节** —— 一旦出现「shellcode 在某类 arm64 目标上跳飞」的症状，这里是第一个该查的地方；
- 同理，不含 `paciza` / `pacibsp` / `retab` 的 arm64 shellcode 变体也不做，留作同一场景的后备。

在有实测反例之前，凭推理去改一段已经验证可用的 thread state 构建，风险大于收益。

### payload 选片与投递

`RuntimeInjectClient` 现在固定投递到 `/Library/Frameworks/RuntimeViewerServer.framework`
（`serverFrameworkDestinationURL`）。改为按目标平台选择来源与目的地：

```swift
/// The payload slice matching a target process's platform.
public enum PayloadPlatform: Sendable {
    case macOS
    case iOSSimulator
}

public func serverFrameworkSourceURL(for platform: PayloadPlatform) -> URL?
public func serverFrameworkDestinationURL(for platform: PayloadPlatform) -> URL
```

`iphonesimulator` slice 作为独立 framework 随 app 分发。安装目的地需要满足两个条件：
模拟器进程能读、且注入器能写。

**「模拟器进程的文件系统视图是宿主的」已实测成立**（2026-08-23，对 iOS 18.5 模拟器的 `mobiletimerd`
用 lldb 逐个 `dlopen` 不存在的路径，读 `dlerror()` 的 `tried:` 列表）。`dyld_sim` 对**任何**绝对路径
都按同一套顺序尝试：

1. `<RuntimeRoot>` + 原路径
2. **原路径本身（宿主视图）**
3. `.framework` 路径额外再试 `<RuntimeRoot>/System/Library/Frameworks/<Name>.framework/<Name>`

测了 `/Library/Frameworks`、`/System/Library/Frameworks`、`/usr/lib`、`/Users/Shared`、`/tmp`、
`/Volumes/…`、`/Applications` 七个前缀，行为一致。**所以投递目录的选择是自由的**，
`/Library/Frameworks/` 可以直接用。

落地时的取舍：**不另起子目录，改用同级的兄弟 bundle**
`/Library/Frameworks/RuntimeViewerServer-iphonesimulator.framework`。子目录会让 daemon 的
`FileOperationRequest.copy` 多承担一层 `mkdir -p`；兄弟命名不需要新建目录，且后缀跟随 Xcode 的
SDK 名，将来加 `-appletvsimulator` 无需再发明约定。两个 slice **不能合成一个 fat binary** ——
它们架构相同、只差 `LC_BUILD_VERSION` 的 platform，这正是 fat 格式无法表达、而 `.xcframework`
要拆成多个文件的原因。

payload 由 `RuntimeViewerMobileServer` scheme 以 `generic/platform=iOS Simulator` 构建，
在主 app 之前，产物由主 app 的 **`Embed iOS Simulator Payload`** build phase 改名嵌入
`Contents/Resources/`。**必须是 build phase 而非事后拷贝**：`Resources` 下的一切都被 app 的
代码签名 seal，签完再塞文件会让签名失效，进而破坏 `SMAppService` 的 daemon 注册。
它也**不能**建模成 target dependency —— Xcode 把 iOS-family framework 视作 macOS app target
拒收的嵌入内容，与 Catalyst helper 同一个约束，所以顺序由 `RunScript.sh` / `ArchiveScript.sh` 保证。

### 通信通道：不需要新增，但宿主侧的会话建立要绕开注入路径的假设

payload 侧无需改动 —— `RuntimeViewerMobileServer` 走的是编译期就定死的 Bonjour 分支，
与 `SandboxProbe` / `localSocket` 完全无关（见前期调研）。

要改的是**宿主侧**。`AttachToProcessViewModel.transform(_:)` 现在的流程是：

```swift
let isSandbox = SandboxProbe.isRuntimeViewerServiceMachLookupBlocked(pid: ...)
try await runtimeEngineManager.launchAttachedRuntimeEngine(name:identifier:isSandbox:)
try await runtimeInjectClient.injectApplication(pid:dylibURL:remapEntrySymbol:)
try await runtimeEngineManager.confirmAttachedRuntimeEngineConnected(name:identifier:isSandbox:)
```

它预设「注入方会连到宿主为这次注入专门起的 XPC / socket 端点」。模拟器目标不会 —— 它会去广播
Bonjour，由既有的 Bonjour 发现流程接管。所以模拟器目标要走一条独立的会话建立路径：
跳过 `launchAttachedRuntimeEngine` / `confirmAttachedRuntimeEngineConnected` 那对调用，
改为注入后等待 Bonjour 侧出现对应的新 engine。

**已落地（2026-08-23）。** `AttachToProcessViewModel.transform(_:)` 按 `payloadPlatform` 分成两个方法：

- `attachToLocalProcess` —— 原流程原样保留（探沙盒 → 起 engine → 注入 → 确认连回），
  失败时拆掉自己起的那个 engine。
- `attachToSimulatorProcess` —— 注入 → `awaitInjectedBonjourEngine(name:processIdentifier:timeout:)`。
  不起 engine，失败时也没有 engine 要拆。**沙盒探测一并跳过**：`SandboxProbe` 存在的意义是在
  XPC 与 localhost socket 两种 transport 间做选择，而模拟器 payload 两个都不用。

`awaitInjectedBonjourEngine` 落在 `RuntimeEngineManager`：按 pid 轮询 `bonjourRuntimeEngines`
（0.5 秒一次，默认 30 秒超时）。**匹配用 pid 而非服务名** —— 模拟器进程是宿主的真实进程，
payload 在 TXT 里发布的 pid 就是被注入的那个，端点键形如 `{deviceID}-{pid}`；
deviceID 是含短横线的 UUID，所以取最后一个 `-` 分段比较，而不是做后缀匹配。
超时错误单独一个 case，提示里点明「模拟器的启动日志在 `xcrun simctl spawn <udid> log show`，
宿主的 `log show` 看不到」—— 这是本次排查里实际踩过的坑。

**这里没有新增任何通道代码**：2026-08-23 的实机验证中，payload 一广播，用户宿主上正在运行的
RuntimeViewer 就自动连上了。要改的从来不是「怎么连」，而是「别再去建那条用不上的 engine」。

### 引擎身份：设备做 Section，进程做条目 —— 与 Mac 完全对齐

已定方向（2026-08-18 用户拍板）：**不为模拟器发明新的展示结构，直接复用 Mac 那套。**

宿主的 `rebuildSections()`（`RuntimeEngineManager.swift:952`）本来就是按
`engine.hostInfo.hostID` 分组、拿 `hostInfo.hostName` 当 Section 标题：

```swift
let hostID = engine.hostInfo.hostID
if let index = hostIDToIndex[hostID] { /* 并入已有 Section */ }
else { sections.append(RuntimeEngineSection(hostName: engine.hostInfo.hostName, hostID: hostID, engines: [engine])) }
```

Mac 本机注入多个进程时，各 engine 共享本机 `hostInfo` → 落在同一个 Section，条目名是各自的进程名
（`launchAttachedRuntimeEngine(name:identifier:)` 传的是进程名 + pid）。**模拟器要的就是这个形状**，
一台模拟器设备一个 Section，下面列出被注入的各个进程。

当前实现落不到这个形状，是因为三个字段全取错了层级：

| 字段 | 现状 | 应为 |
|---|---|---|
| `hostInfo.hostID`（Section 分组键） | `endpoint.instanceID`，而 `localInstanceID` 走 `UserDefaults.standard`，注入后每个进程一个值 → **每个进程各成一个同名 Section** | 设备级 ID |
| `source.bonjour(name:)`（条目标题） | `RuntimeNetworkBonjour.localHostName`，设备名 | 进程名 |
| `knownBonjourEndpointNames`（去重键） | `endpoint.name`，即设备名 → 第 2 个进程被判重复、连不上 | 进程级唯一键 |

注意 `source.bonjour(name:)` 同时是 mDNS 广播的 Instance Name：
`RuntimeNetworkConnection.swift:375` 把它存为 `serviceName`，`:401` 交给
`RuntimeNetworkBonjour.makeService(name:)`。所以它必须全局唯一，不能直接拿进程名（同设备可能有重名进程，
跨设备更会撞）。**展示名与广播名要拆开**：广播名只管唯一，展示名从 TXT 取。

#### TXT record 调整

| key | 状态 | 用途 |
|---|---|---|
| `rv-host-name` | 已有 | Section 标题（设备名） |
| `rv-model-id` / `rv-os-ver` / `rv-sim` | 已有 | Section 图标与设备元数据 |
| `rv-device-id` | **新增** | `DeviceIdentifier.uniqueDeviceID`（MobileGestalt UDID）→ `hostInfo.hostID`，Section 分组键 |
| `rv-proc-name` | **新增** | engine 条目标题 |
| `rv-proc-pid` | **新增** | 与 `rv-device-id` 合成进程级唯一键 |
| `rv-instance-id` | 已有，语义收窄 | 仅保留给 engine mirroring 的环检测（`buildEngineDescriptors` 的 `originChain`），不再充当 `hostID` |

#### payload 侧（`RuntimeViewerServer.swift` 的 `#else` 分支）

广播名改为进程级唯一，展示信息走 TXT：

```swift
// 广播名：唯一即可，不面向用户
let serviceName = "\(DeviceIdentifier.uniqueDeviceID)-\(ProcessInfo.processInfo.processIdentifier)"
runtimeEngine = RuntimeEngine(
    source: .bonjour(name: serviceName, identifier: .init(rawValue: serviceName), role: .server)
)
```

`makeService(name:)` 补写 `rv-device-id` / `rv-proc-name` / `rv-proc-pid` 三个 key。

**`localInstanceID` 的副作用要一并处理**：它经 `UserDefaults.standard` 持久化，注入场景下会往
**被注入进程**的 preferences 写 `RuntimeViewer.localInstanceID`（注入 SpringBoard 就是写 SpringBoard 的
plist）。注入路径下改为内存计算、不落盘。

#### 宿主侧（`RuntimeEngineManager.connectToBonjourEndpoint(_:attempt:)`）

```swift
// 去重键从服务名换成进程级唯一键
let endpointKey = endpoint.uniqueKey            // rv-device-id + rv-proc-pid，回退到 endpoint.name
guard !knownBonjourEndpointKeys.contains(endpointKey) else { … }

let remoteHostInfo = RuntimeHostInfo(
    hostID: endpoint.deviceID ?? endpoint.instanceID ?? endpoint.name,   // 设备级 → 同设备并入一个 Section
    hostName: endpoint.hostName ?? endpoint.name,                        // 设备名 → Section 标题
    metadata: endpoint.deviceMetadata ?? .current
)
let runtimeEngine = RuntimeEngine(
    source: .bonjour(name: endpoint.processName ?? endpoint.name,        // 进程名 → 条目标题
                     identifier: .init(rawValue: endpointKey),
                     role: .client),
    hostInfo: remoteHostInfo,
    originChain: [endpoint.instanceID ?? endpoint.name]                  // 环检测仍用 instanceID
)
```

`pendingReconnectEndpoints` 的键同步改为 `endpointKey`，否则同设备的多个进程仍会互相覆盖。

`RuntimeNetworkEndpoint` 增加 `deviceID` / `processName` / `processIdentifier` 三个字段，
由 `RuntimeNetworkBonjour` 从 TXT 解析（对照已有的 `instanceID(from:)` / `hostName(from:)` /
`deviceMetadata(from:)`）。

#### 向后兼容

旧 peer（含真机上尚未更新的 app）不带新 key，解析结果为 `nil`，全部字段按上面的 `??` 链回退到当前行为：
`hostID = instanceID`、条目名 = 服务名、去重键 = 服务名。行为与今天一致，不需要为它们保留分支。

真机场景自然跟着受益：同一台真机上若出现多个 Server（多个 app，或将来真机注入），也会并进同一个
Section 而不是各成一个同名 Section。

## 替代方案考量

**只加守卫，不支持模拟器。** 成本最低，但把能力永久关死。守卫本身仍然要做，所以这不是替代方案而是
阶段一；把它当终点则是放弃一个 payload 侧已经具备的能力。

**用 lldb / debugserver 注入。** 模拟器进程可以直接 `lldb -p <pid>` 然后
`expr (void *)dlopen("...", 2)`，完全绕开 shellcode、PAC 和符号解析。否决理由：引入对 Xcode 工具链
的运行期依赖，attach 会暂停目标且与用户自己的调试会话抢占，错误处理只能靠解析 lldb 的文本输出。
作为**验证手段**它很有用（可以用来先确认 payload 在模拟器里能否加载、能否连回宿主），但不适合做产品路径。

**用 `simctl spawn` 在模拟器里起一个独立 server 进程。** 绕开注入，直接在模拟器里跑一个进程。
否决理由：那个进程只能观察自己，而 Attach to Process 的价值恰恰在于观察**别人**的进程 ——
SpringBoard、系统 daemon、用户自己的 app。这解决的是另一个问题。

**把 payload 做成 `DYLD_INSERT_LIBRARIES` 随 app 启动注入。** `simctl launch` 支持传环境变量，
对「用户自己的 app」够用。否决理由：只覆盖启动时刻，无法 attach 到已经在跑的进程，
且对系统进程（SpringBoard）不适用。可以作为将来的补充入口，不是本提案的替代。

**先修 remap 路径而不是 dlopen 路径。** 否决理由：remap 路径要额外解决 `map_images` 与三个
`swift_register*` 的跨进程解析、chained fixups 按目标 PAC 密钥重签、以及 runtime handoff，
量级远大于 dlopen 路径；而模拟器目标 SIP 已关、library validation 场景与 macOS 系统 app 不同，
dlopen 被拒的概率低得多。先走简单且测试更充分的那条。

## 影响

### 用户可见变化

- **阶段一**：Attach to Process 列表中的模拟器进程标为不可用，附一句原因（当前是选中即崩）。
  行为从「打崩目标进程」变为「明确拒绝」。
- **阶段二**：模拟器进程恢复可选，注入成功后与注入 macOS app 一样出现在引擎列表里，
  Sidebar / Inspector 的使用方式没有差别。

用户没有「原有操作习惯」因此失效 —— 当前这条路本来就不可用。

### 可发现性

不新增菜单项或设置项。模拟器进程本来就在 Attach to Process 列表里，本提案只是让它从「假可用」
变成「真可用」（中间经过一个「明确不可用」的阶段）。

阶段二落地后，列表项需要能看出这是模拟器进程（与同名的 macOS 进程区分），建议在行内标注 runtime
名称（如 `iOS 26.5`）。

### 数据与配置兼容

无迁移。不新增偏好设置、不改文档格式、不动钥匙串。

已安装的 `/Library/Frameworks/RuntimeViewerServer.framework`（macOS payload）继续按原样使用；
模拟器 payload 是并列新增，不覆盖它。

### 平台与最低版本

- RuntimeViewer 自身的最低系统版本不变。
- 新增运行期前提：目标模拟器 runtime 必须已安装（cache 文件存在）。缺失时按「不可用 + 原因」处理，
  不崩不静默。
- 模拟器侧最低版本受 `RuntimeViewerMobileServer` 的 `IPHONEOS_DEPLOYMENT_TARGET = 15.0` 约束。
- 仅 Apple Silicon 宿主（arm64 模拟器进程）。

### 发布

- **不需要**新 entitlement 或隐私清单条目 —— 注入能力本来就依赖已有的 root helper 与 SIP 关闭。
- **app 体积增加**：需要随包分发 `iphonesimulator` slice 的 `RuntimeViewerServer.framework`。
- 公证与 Sparkle 流程不受影响；`ArchiveScript.sh` 需要把新 payload 纳入打包。

## 落地步骤

1. ~~**验证可行性**（阻塞后续所有步骤）~~ —— **已完成，2026-08-18，全部通过**，详见前期调研的「可行性验证」。原文：用 lldb 手工把 `iphonesimulator` slice 的 payload
   `dlopen` 进一个模拟器进程，逐项确认：(a) dyld 是否接受该 payload（平台、代码签名、AMFI）；
   (b) 加载后 `swift_initializeRuntimeViewerServer` 是否跑起来（os_log 里的
   `Attach successfully` / `RuntimeViewerServer Did Launch`）；(c) 该进程的 Bonjour 广播是否出现在
   宿主（`dns-sd -B _runtimeviewer._tcp local`），以及宿主 RuntimeViewer 是否把它列为 engine。
   先拿一个无关紧要的模拟器进程试，**不要**拿 SpringBoard。
   **(c) 不通则本提案的价值基础不成立**，需要先解决通道再谈注入。
2. ~~**身份改造**（主仓库，与注入器解耦，优先做）~~ —— **已完成并实机验证，2026-08-23**
   （代码 2026-08-22）。验证方式：用 lldb 把步骤 7 产出的 `iphonesimulator` payload 分别
   `dlopen` 进同一台 iOS 18.5 模拟器的两个系统 daemon（`mobiletimerd` / `nanoprefsyncd`），
   两者在宿主 RuntimeViewer 中**并入同一个 Section**、各成一条以进程名标题的条目 ——
   正是本步骤要达成的形状。同批确认 `SIMULATOR_UDID` 确实存在于每个模拟器进程的环境中
   且同设备取值一致（见 `Documentations/KnownIssues/2026-08-22-simulator-injection-identity-findings.md`
   的 SIMID.5）。原文：TXT 新增 `rv-device-id` / `rv-proc-name` /
   `rv-proc-pid`；payload 广播名改为进程级唯一；宿主 `hostID` 取设备级、条目名取进程名、
   去重键与 `pendingReconnectEndpoints` 键改为进程级唯一键；`localInstanceID` 在注入路径下不落盘。
   改完即可用 lldb 注入同设备两个进程，验证它们并入同一个 Section。
   落地时相对提案多出两项，见决策日志 2026-08-22 两条：descriptor 必须自带 `hostID`，
   以及 `localDeviceID` 在模拟器上优先取 `SIMULATOR_UDID`。
3. ~~**阶段一：平台守卫**~~ —— **已完成，2026-08-23**（宿主侧随步骤 7 落地，daemon 侧随本条）。
   落地形态与原文有出入，两处都记在决策日志里：
   - **宿主侧**在挑切片时就拒绝没有对应 payload 的目标（tvOS / watchOS / visionOS 模拟器），
     不再把最近的切片交给 dyld 去拒。
   - **daemon 侧**比较的是「payload 的 platform」与「目标的 platform」是否相等，
     而不是原文说的「与宿主平台不一致就抛错」—— 后者会把注入模拟器进程这件事本身也挡掉，
     正是本提案要支持的场景。同时新增第二道：**目标平台与 daemon 平台不同时禁用 remap 回退**，
     兑现「非目标」一节里「若目标拒绝 dlopen，如实报错而非回退 remap」那条。
   - 「Attach to Process 列表标注不可用」**未做** —— 现在是点了才报错，而不是事先置灰。
4. ~~**打通跨仓库联调路径**~~ —— **大半已消解，2026-08-23 复核**。原文称
   `swift-helper-service/Package.swift:136` 的 MachInjector local path 指向的目录不存在、因此吃
   远程 pin `from: "0.5.0"`；该目录现已存在（git 干净、tag `0.5.0`），`USING_LOCAL_DEPENDENCIES=1`
   下 `swift package show-dependencies` 确认 RuntimeViewer → swift-helper-service → MachInjector
   整条链都解析到本地路径。
   ~~**剩余一项**：`RunScript.sh` / `ArchiveScript.sh` 都不传 `USING_LOCAL_DEPENDENCIES`~~ ——
   **已补，2026-08-23**：两个脚本都加了 `--local-deps`，默认关闭。`ArchiveScript.sh` 的注释里
   额外写明「发布正常不该用它，main 必须能对着已发布的 pin 编过」，它只服务于「依赖还没发版时
   本地验证一次 release 构建」。
5. **`MITargetSymbolResolver`**（MachInjector）：读目标 `dyld_all_image_infos`、镜像列表、cache slide；
   宿主同文件镜像解析**目标进程内存里**那份的 `LC_SYMTAB`（不得用注入器自身的偏移，见决策日志
   2026-08-23），cache 内镜像走 MachOKit 解析。带单测。
6. ~~**`MIMachInjector` 接入 resolver**~~ —— **已完成，2026-08-23**。原文还要求「按目标 cpusubtype
   分流 thread state 构建」，**实测表明不需要**，已降级为可选优化，理由见「详细设计 / thread state
   按 arch 分流」。PAC 指令行为随第一次真实注入一并验掉（见「仍未验证」第 1 条）。
7. ~~**payload 选片与投递**~~ —— **已完成，2026-08-23**。原文：`BuildRuntimeViewerServerXCFramework.sh`
   产物纳入 app 打包，`RuntimeInjectClient` 按平台选源与目的地。
   落地形态：新增 `InjectionTargetPlatformProbe`（读目标 `LC_BUILD_VERSION`）与 `PayloadPlatform`
   （我们有哪些 slice）两个类型，`RuntimeInjectClient` 的四个 URL API 全部改为按平台取值；
   payload 由 `RuntimeViewerMobileServer` 构建、经 `Embed iOS Simulator Payload` build phase
   嵌入签名前的 app bundle。两个 probe 的取舍与实测见「详细设计 / payload 选片与投递」。
   **顺带覆盖了步骤 3 的宿主侧一半**：目标平台没有对应 slice（tvOS / watchOS / visionOS 模拟器）时
   直接抛错，不再把最近的 slice 交给 dyld 去拒。daemon 侧的守卫仍未做。
   验证：单测 21 项（含用真实 simruntime 二进制验平台识别）；构建出的 slice 是 `platform 7` /
   arm64 / ad-hoc 签名、两个入口符号俱在；用 lldb 把它 `dlopen` 进真实模拟器 daemon
   `mobiletimerd`，`dlerror()` 为 `NULL`、`dlsym` 解出入口地址，模拟器侧 os_log 三条齐全
   （`Attach successfully` → `Will Launch` → `Did Launch`）。
8. **端到端验证**：SpringBoard + 一个用户 app，注入、浏览 ObjC/Swift 接口、断开、重注入。
   **注入这一项已通过（2026-08-23）**：经完整产品路径（Attach to Process → daemon → `MIMachInjector`
   的 dlopen 路径，非 lldb）注入 iOS 18.5 模拟器的 **SpringBoard**，payload 启动三条日志齐全
   （`Attach successfully` → `Will Launch` → `Did Launch`，19:30:21–19:30:22），目标进程存活。
   **这是本提案的闭环** —— 动机一节里被打崩三次的正是 SpringBoard。

   **浏览接口一项也已通过**，验证对象是 `backboardd`（类型信息完整）。**不要用 SpringBoard 判断这一项** ——
   它的主二进制是个壳（249 KB，**根本没有 `__objc_classlist` 段**），实现都在它加载的
   SpringBoardHome / SpringBoardUI / SpringBoardFoundation 等框架里，所以主二进制显示为空是正确结果，
   不是注入或引擎故障。作为对照，`backboardd` 是 2.5 MB、`__objc_classlist` 0x558 字节（171 个类）。

   剩余未验：断开、重注入，以及用户自己安装的 app（非系统 daemon）。
9. ~~**收尾判断**~~ —— **已判定，2026-08-23**，两条结论都记在决策日志里：
   - **实现说明：写了。**
     [`ResolvedIssues/2026-08-23-simulator-injection-host-address-fallacy.md`](../ResolvedIssues/2026-08-23-simulator-injection-host-address-fallacy.md)。
     放 `ResolvedIssues/` 而非新建 `Internal/` —— 项目既有的文档结构里，该目录的定位就是
     「已定位并修复的疑难问题纪要，含根因与验证过程」，正好是这份东西。
   - **术语表：不建。** `dyld_sim` / `RuntimeRoot` / `SimRuntime` 都是 Apple 的既有术语而非
     项目自造词，且已在实现说明里就地解释；本项目也没有 `Glossary.md` 的既有传统，
     为三个词新起一份索引收益不抵维护成本。若日后这些词在多篇文档间反复出现再重新评估。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-18 | Created as Draft | 起因是注入模拟器进程打崩三个 SpringBoard。定位到根因为「注入器把自身地址空间的符号地址喂给目标进程」，dlopen 与 remap 两条路径同病。提案范围定为：先加平台守卫止血，再让 dlopen 路径支持 iOS Simulator 目标。 |
| 2026-08-18 | Accepted | 用户批准开工，并指定先执行落地步骤 1（验证通信通道可行性）再进入编码。三条「尚未验证」的推测按提案原定顺序逐条验掉。 |
| 2026-08-18 | 修正通信通道设计 | 开工后复核 `RuntimeViewerServer.swift:52` 发现：payload 的通道选择是**编译期**分流，MobileServer 走 Bonjour，与 `localSocket` 无关；且 Bonjour 路径已把模拟器当一等场景（`rv-sim` TXT key、`RuntimeViewerUsingUIKit` 既有用法）。原设计「模拟器目标强制走 localSocket」作废，改为「payload 侧不动，宿主侧改会话建立路径」。真正的通道风险随之从「能不能连」变为「注入进系统进程后 Bonjour 还灵不灵」。 |
| 2026-08-18 | 落地步骤 1 通过 | lldb 把 `iphonesimulator` payload `dlopen` 进系统 daemon `gamecontrollerd`：加载成功、Swift runtime 起来、Bonjour 广播出现、宿主 `RuntimeViewer` 连接建立（端口 52406 双向对上）、目标进程存活。可行性确立，提案进入实现阶段。顺带推翻「系统进程缺少 `NSLocalNetworkUsageDescription` 会挡住 Bonjour」的担忧。 |
| 2026-08-18 | 发现阻塞项：身份是设备级 | 用户指出注入多个进程后全部显示为模拟器设备名。复验确认成因是 iOS 分支的 Bonjour `name` 与 `identifier` 都取设备级值（原场景「一台设备一个 app」的遗留假设），且宿主 `connectToBonjourEndpoint` 用服务名做去重键 —— 后果不只是显示错乱，**第二个进程根本连不上**（实测 `nanoappregistryd` 停在 LISTEN）。进程级身份的三点取舍待拍板。 |
| 2026-08-18 | 定案：设备做 Section，进程做条目 | 用户拍板「跟 Mac 一样」——不新增展示结构，复用 `rebuildSections()` 既有的「hostID 分组 + hostName 标题」。落到三处改动：TXT 新增 `rv-device-id`/`rv-proc-name`/`rv-proc-pid`；payload 广播名改为进程级唯一（展示名与广播名拆开）；宿主 `hostID` 取设备级、条目名取进程名、去重键与 `pendingReconnectEndpoints` 键改为进程级唯一键。旧 peer 靠 `??` 链回退，无需兼容分支。 |
| 2026-08-22 | 落地步骤 2 代码完成 | 改动落在八个文件：`RuntimeNetwork.swift`（三个 TXT key、`localDeviceID` / `localProcessName` / `localServiceName`、`isRunningInsideInjectedProcess`、endpoint 的 `uniqueKey`）、`RuntimeSource.swift`（bonjour client 的 `identifier` 改用 id 而非 name）、`RuntimeRemoteEngineDescriptor.swift`（新增 `hostID`）、`RuntimeEngineManager.swift`（去重键、`hostID`、条目名、teardown 键）、payload 与 iOS app 的广播名、`Package.swift`（Communication 依赖 Utilities）。新增 `BonjourProcessIdentityTests`（7 项）与 descriptor 的 `hostID` 往返测试。验证：`RuntimeViewerCommunication` / `RuntimeViewerApplication` / `RuntimeViewerMobileServer`（iphonesimulator）均编译通过，通信测试 107 项、mirror registry 12 项全绿。**注意所有构建都要 `USING_LOCAL_DEPENDENCIES=1`**，否则走 remote pin 会报 `TypeDefinition` / `demangleAsNodeTransient` 缺失，与本改动无关。 |
| 2026-08-22 | 提案外的必需修正：descriptor 自带 `hostID` | 提案只说宿主直连时 `hostID` 取设备级，漏了**镜像**路径：`handleEngineListChanged` 的 engineFactory 用 `descriptor.originChain.first` 当 `hostID`，而 originChain 装的是 instanceID。两者在「一台设备一个安装」时恰好相等，改成设备级后就分叉了 —— 同一台远程设备的直连 engine 与镜像 engine 会落进两个 Section，且 `deduplicateForwardedMirrors` 靠 `hostInfo.hostID == section.hostID` 找同 Section 本地路由，去重随之失效，用户会看到重复条目。修法是给 descriptor 加 `hostID` 字段（`@Default("")`，旧 peer 解码为空串后回退 `originChain.first`），发送端填 `engine.hostInfo.hostID`。环检测仍用 originChain，不受影响。 |
| 2026-08-22 | 提案外的落地取舍：`localDeviceID` 优先 `SIMULATOR_UDID` | 提案写的是直接用 `DeviceIdentifier.uniqueDeviceID`。但它在 MobileGestalt 无答案时回退到 keychain UUID，而 keychain 查询是**从被注入进程里**发起的，可能按进程解析 —— 那会把一台模拟器重新拆成「每个注入进程一个 Section」，正是本次要消除的症状。故模拟器上先读 CoreSimulator 注入到每个进程环境里的 `SIMULATOR_UDID`，真机维持原路径。`SIMULATOR_UDID` 的实际存在性尚未实测（本机当前无 booted 模拟器，且启动模拟器需单独授权），留待步骤 8 端到端验证时确认；即便缺失也只是退回原路径，不会更差。 |
| 2026-08-22 | 已知取舍：`clearAllWithHostID` 的前缀现在是设备级 | `hostID` 转为设备级后，`engineID = "{hostID}/{localID}"` 的前缀也随之设备级，于是「某个 bonjour engine 断开」会让 `clearAllWithHostID` 清掉**同设备所有**镜像。当前不可触发：走这条路要求对端支持 engine sharing 并返回非空 descriptor，而 iOS payload 不注册 engine list handler，一律被判为 `directBonjourEngines`。正确修法是让 mirrorRegistry 改用 engine 级键，属于架构改动，不在本次范围。裁决与复核判据记于 `Documentations/KnownIssues/2026-08-22-simulator-injection-identity-findings.md`。 |
| 2026-08-23 | 落地步骤 5 的前置风险已验掉 | 用只读探针对 iOS 18.5 模拟器的 `peopled` 实测 `TASK_DYLD_INFO`：拿到的**就是 `dyld_sim` 维护的那一份**（580 个镜像中 576 个属于模拟器 RuntimeRoot），`sharedCacheBaseAddress = 0x180000000`、slide 为 0，且三个宿主镜像恰好是 `libsystem_platform` / `libsystem_kernel` / `libsystem_pthread`。`MITargetSymbolResolver` 的分流设计因此成立，提案原定的退路（从 `dyld_sim` 的 `__DATA` 段自行定位）不需要了。另记两个易误判点：`dyldPath` 读出来是宿主的 `/usr/lib/dyld`，不能用它判断目标是否模拟器进程；slide 虽为 0 但仍须从进程读取。 |
| 2026-08-23 | 修正详细设计：宿主符号的偏移不能照抄注入器自身 | 实测发现 `/usr/lib/system/libsystem_pthread.dylib` 的 arm64 与 arm64e slice 中 `_pthread_create_from_mach_thread` 偏移不同（`0x7d84` vs `0x847c`）。注入器用的是宿主 cache 里的 arm64e 那份，而模拟器进程是 arm64、独立映射，因此原设计「宿主 `dlsym` 地址减宿主基址得偏移，再加目标基址」会算出偏高 0x6f8 字节的地址 —— 落在函数体中间，跳过去同样崩，且症状与「地址完全解析错」难以区分，属于评审阶段看不出、只在实现后才发作的坑。改为解析**目标进程内存里**那份 Mach-O 的 `LC_SYMTAB` 求偏移：不依赖宿主状态，也不必假设目标 map 的是 cache 还是磁盘文件，且与另两个符号共用同一套 Mach-O 解析。前期调研与详细设计中相应的算式一并更正（原文保留在正文中并标注为错）。 |
| 2026-08-23 | daemon 侧平台守卫落地，且守的东西与提案原文不同 | 提案原文写的是「读目标 platform，**与宿主平台不一致**时抛错」。照写会把注入模拟器进程本身挡掉 —— 那正是本提案要支持的场景。实际实现比较的是「**payload 的 platform** 与**目标的 platform**」是否相等：这是真正会出错的那一对，且对将来新增的平台自动成立。守卫刻意**不把平台值映射成命名枚举**，只做数值比较 —— 命名一遍等于在第二个进程里重复宿主挑切片时已经做过的判断，两份迟早漂移。另一条取舍：**读不到平台时不拦**。守卫是第二道防线而非决策本身，「看不清就一律拦下」会把每个解析不了的目标变成注入失败。 |
| 2026-08-23 | 模拟器目标禁用 remap 回退，兑现「非目标」一节的承诺 | `InjectionService` 原本 dlopen 失败就回退 remap。remap 路径在**注入器自己**的进程里解析符号再把地址交给目标 —— 对共享同一份 shared cache 的另一个 macOS 进程成立，对 `dyld_sim` 加载的模拟器进程不成立，地址落在无关内存上，目标当场死（pid 62869 就是这么没的）。现在目标平台与 daemon 平台不同时直接关掉回退，并在错误里说明为什么没有第二次尝试 —— 否则「只试了一次」看起来像 bug。**留了显式 pin 的口子**：修好这条路径之后总得有办法验证它，但 daemon 会记一行预警。注意 dlopen 路径本身没动 —— 它已经改成对着目标自己的符号表解析（`MITargetSymbolResolver`），所以被关掉的只是回退。 |
| 2026-08-23 | 步骤 9 收尾判断：实现说明写、术语表不建 | **实现说明写了**，落在 `ResolvedIssues/2026-08-23-simulator-injection-host-address-fallacy.md`。选这个目录而不是按全局默认规则新建 `Internal/`：项目已有自己的文档结构，`ResolvedIssues/` 的既有定位（「已定位并修复的疑难问题纪要，含根因与验证过程」）恰好匹配，另起并行目录只会稀释。内容取舍是只写「代码里看不出来」的部分 —— 根因的三个变体（宿主地址、切片平台、通道走错）各自的判据，以及三个诊断陷阱（256 字节截断的 dlerror 看起来像完整答案、模拟器 os_log 不在宿主 log store、SpringBoard 空壳会给出假故障信号）。**术语表不建**：`dyld_sim` / `RuntimeRoot` / `SimRuntime` 是 Apple 既有术语而非项目自造词，已在实现说明里就地解释，且本项目无 `Glossary.md` 传统。 |
| 2026-08-23 | 步骤 4 收尾：`--local-deps` 开关 | `RunScript.sh` / `ArchiveScript.sh` 加 `--local-deps`，设置时导出 `USING_LOCAL_DEPENDENCIES=1`，默认关闭。动机是这个缺口的症状特别难自查 —— 忘记带环境变量时构建**静默**走远程 pin，表现为「我改了本地 MachInjector 但没反应」，看不出是构建吃错了依赖。`ArchiveScript.sh` 那份注释额外声明发布不该用它（main 必须能对着已发布的 pin 编过），它只用于依赖未发版时本地验证 release 构建。 |
| 2026-08-23 | 步骤 8 的「浏览接口」通过，并记下一个会误判的对照 | 注入 `backboardd` 后类型信息完整，这一项通过。**同时记下：不能拿 SpringBoard 判断这一项** —— 它的主二进制 249 KB 且连 `__objc_classlist` 段都没有（实现在 SpringBoardHome / SpringBoardUI 等框架里），注入后主二进制显示为空是正确结果。这个对照值得留档：SpringBoard 是最直觉的验证对象，而它恰好会给出「注入成功但看起来什么都没有」的假故障信号。`backboardd` 2.5 MB / `__objc_classlist` 0x558 字节（171 个类）是合适的对照物。 |
| 2026-08-23 | 端到端打通：产品路径注入 SpringBoard 成功 | 走完整产品路径（Attach to Process → daemon → `MIMachInjector` dlopen，非 lldb）注入 iOS 18.5 模拟器的 SpringBoard，payload 三条启动日志齐全、目标存活 47 分钟以上。**提案闭环** —— 动机一节的起因就是注入模拟器进程打崩三个 SpringBoard，落地步骤 1 当时还特意写「先拿无关紧要的进程试，不要拿 SpringBoard」。同时确认 dlopen 路径成功、未触发 remap 回退。**顺带否掉了一项原定落地内容**：提案要求按 cpusubtype 分流 thread state（arm64 目标写裸地址、跳过 `thread_convert_thread_state`），但那段无条件 PAC 签名的代码**原样未改**就成功了。原因未查明，故降级为可选优化并保留该节作为「shellcode 在 arm64 目标上跳飞」时的第一排查点 —— 在有实测反例前，凭推理去改一段已验证可用的 thread state 构建，风险大于收益。 |
| 2026-08-23 | 模拟器目标的会话建立落地 | 实机验证暴露出这件事比提案预想的小得多：payload 广播后宿主**自动**连上了，既有 Bonjour 发现流程原样接管，不需要任何新通道代码。于是改动收敛为「attach 流程别再去建那条用不上的 XPC engine」—— `AttachToProcessViewModel` 按 payload 平台分成 `attachToLocalProcess` / `attachToSimulatorProcess` 两个方法，后者注入完直接等 `RuntimeEngineManager.awaitInjectedBonjourEngine`。匹配用 pid 不用服务名（模拟器进程是宿主真实进程，pid 一致），且因为端点键里的 deviceID 是含短横线的 UUID，取最后一个分段比较而非后缀匹配。沙盒探测在模拟器分支一并跳过 —— 它只用来在 XPC 与 socket 之间选，而模拟器 payload 两个都不走。 |
| 2026-08-23 | 落地步骤 2 实机验证通过，SIMID.5 一并关闭 | 步骤 7 产出可用 payload 后，步骤 2 挂了一整天的「双进程实机验证」终于具备条件。把 payload 分别 `dlopen` 进同一台模拟器的 `mobiletimerd` 与 `nanoprefsyncd`，两者在宿主 RuntimeViewer 中并入同一个 Section（用户实机确认）—— 进程级唯一广播名、设备级 `hostID`、进程级去重键三项改造同时成立。顺带读到两个进程的环境里都有相同的 `SIMULATOR_UDID`，与 `simctl` 报的设备 UDID 一致，`localDeviceID` 优先读它的取舍（2026-08-22 那条）得到证实，KnownIssues 的 SIMID.5 关闭。**注意宿主是自动连上的**：payload 广播后既有的 Bonjour 发现流程直接接管，宿主侧没有为此写任何新代码 —— 这也说明「模拟器目标的会话建立」要做的不是新增通道，而是让 attach 流程别再去建那条用不上的 XPC engine。 |
| 2026-08-23 | 落地步骤 5/6 生效，PAC 疑虑消解 | `MITargetSymbolResolver` 接入 `MIMachInjector` 后的第一次真实注入：目标返回了自己 `dlerror()` 的文本（`MIMachInjectorErrorTargetRefusedToLoadDylib`），而修复前的症状是 `could not get thread state: (ipc/send) invalid destination port` —— shellcode 跳飞、目标当场崩。能产生 dlerror 文本，意味着 shellcode 在目标里跑完了 `pthread_create_from_mach_thread` → `dlopen` → `dlerror` → 写 report 四步，四个地址全部由 resolver 从目标符号表解出。**顺带把「仍未验证」第 1 条（arm64 目标上的 PAC 指令）验掉了**。那次注入最终仍失败并打崩目标，但成因是另外两件事：投的是 macOS slice，以及模拟器目标仍会回退 remap。 |
| 2026-08-23 | 推翻一个中途做出的错误判断：`/Library/Frameworks` 并未被 `dyld_sim` 劫持 | 上一条那次失败的 `dlerror` 被 256 字节的 report 缓冲截断在**第一个**候选路径内部，只看得到 `<RuntimeRoot>/Library/Frameworks/…`，据此一度判定「模拟器进程的文件系统视图不是宿主的、提案的投递路径假设被推翻」。实测否掉了这个判断：对 `mobiletimerd` 逐个 `dlopen` 不存在的路径读 `tried:` 全列表，`dyld_sim` 对**任何**前缀都是先试 RuntimeRoot 版本、**再试宿主原路径**，七个前缀行为一致。提案原假设成立，投递目录的选择是自由的。真正的失败原因是 slice 平台不匹配（装在那里的是 `platform 1` 的 macOS slice）。**教训是截断的诊断信息比没有信息更危险** —— 它看起来像完整答案。 |
| 2026-08-23 | MachInjector：dlerror report 缓冲 256 → 2048 字节 | 上一条的直接产物。dyld 的拒绝消息会列出它试过的每一条路径，单是一条模拟器路径就超过 200 字符，256 字节切在第一个候选中间，恰好隐藏了「后面还试了什么、每个为什么被拒」这唯一有用的部分。report block 本来就是目标进程里一次独立的 `mach_vm_allocate`、已经占满一页，在页内扩大字段零成本。同步路径与 async notepad 同病，一并改。带回归测试（旧尺寸下失败）。 |
| 2026-08-23 | 落地步骤 7 完成，并顺带覆盖步骤 3 的宿主侧一半 | 新增 `InjectionTargetPlatformProbe`（读目标 `LC_BUILD_VERSION`，不用可执行文件路径判断 —— RuntimeRoot 前缀只认得出系统 daemon，用户自己装的 app 跑在设备 data 容器里没有这个标记）与 `PayloadPlatform`（这份构建有哪些 slice）。两者刻意分开：前者描述目标**是什么**，后者描述我们**能给什么**，缺口处就是显式拒绝的位置 —— tvOS / watchOS / visionOS 模拟器是完全可读的目标但没有对应 slice，现在如实报错，而不是把最近的 slice 交给 dyld 去拒（那正是上一次打崩进程的路径）。daemon 侧的守卫仍未做。 |
| 2026-08-23 | 落地步骤 4 复核：联调路径已通，但构建脚本仍缺开关 | 提案原文称 MachInjector 的 local path 指向的目录不存在、因此吃远程 pin。复核发现该目录现已存在（git 干净、tag `0.5.0`），`USING_LOCAL_DEPENDENCIES=1` 下 `swift package show-dependencies` 确认 RuntimeViewer → swift-helper-service → MachInjector 整条链解析到本地路径，步骤 4 的阻塞已消失。**但 `RunScript.sh` / `ArchiveScript.sh` 都不传该环境变量**，实机 daemon 仍会吃远程 pin，改本地 MachInjector 不生效 —— 验证注入器改动前需先给脚本加开关（或构建时手动带上）。 |

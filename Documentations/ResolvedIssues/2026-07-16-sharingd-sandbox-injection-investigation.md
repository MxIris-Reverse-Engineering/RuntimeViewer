# sharingd 代码注入调查纪要

**日期**：2026-07-16
**背景**：用户报告 attach `sharingd` 时注入失败——首次超时，重试报端口被占用。

## 症状

1. 第一次 attach `sharingd`：injection RPC 显示成功，但主 App 等不到对端 socket 回连，10 秒后 `handshakeTimedOut`。
2. 立刻重试 attach 同一目标：`bind()` 报 `EADDRINUSE`——上次的 socket server 没被释放。

## 症状 2 的根因与修复（Socket 泄漏）

`RuntimeLocalSocketServerConnection` 的 accept loop 在 `accept()` 里阻塞时通过 `[weak self]` 之上的栈帧对连接对象持一个强引用，注入失败后主 App 端只从 `attachedRuntimeEngines` 数组 `removeAll`，**从未调用 `engine.stop()`**——因此 `shutdown()` / `close()` 不发生、`accept()` 不被踢醒、端口被死死钉住。又因为 LocalSocket 端口是从 identifier（PID 字符串）确定性哈希计算的，同一目标的重试永远撞同一个端口。

**修复**（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineManager.swift`）：
- 新增 `stateObservationTokens: [ObjectIdentifier: Disposable]`，以 engine 身份存放状态订阅（模仿现有 `bonjourHeartbeatTasks`）。
- `observeRuntimeEngineState` 不再把订阅丢进共享 `rx.disposeBag`——每个订阅每 engine 独立存放，顺带修掉「每建一个 engine 就往共享 disposeBag 泄漏一条订阅」。
- `terminateRuntimeEngine` 显式：先取消该 engine 的 observation token，再从数组移除，最后 `Task { await engine.stop() }` 释放底层 socket。取消先于 stop 是为了避免 `stop()` 发出的 `.disconnected` 重入 terminate 造成重复通知。

**兜底**（`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`）：
- 给 `RuntimeEngine` actor 加 `deinit { connection?.stop() }`，覆盖绕过 terminate 直接丢引用的路径。

**效果**：注入失败走 catch → terminate → `stop()` 立刻 `shutdown/close(serverSocketFD)` → 踢醒 parked 的 `accept()` → 端口立即释放，同一会话重试不再 EADDRINUSE。

Debug-arm64e 全量构建通过，零新增 warning。

## 症状 1 的根因调查（三轮实证）

问题演变为：**为什么注入 sharingd 时对端从不回连？**

### 实验 1 — 排除签名差别

- 硬件：SIP disabled，boot-args 无 `amfi_get_out_of_my_way`（AMFI 全局 disabled 是自然状态）。
- C1（控制组）：dev 签名 probe → benign victim → ✅ 成功。
- T1：dev 签名 probe → sharingd → ❌ `dlopen failed: file system sandbox blocked mmap()`。
- T2：**Apple 签名的 `libRemoteInjectionPayload.dylib`** → sharingd → ❌ **同样** `sandbox blocked mmap()`。

**结论 1**：不是 payload 签名的问题。AMFI/library-validation 在这台机器上已全局关闭（`amfid` 日志明写 `library validation is globally disabled`），签名根本没被检查到。真正拦下 dlopen 的是 seatbelt sandbox。

### 实验 2 — 尝试 `sandbox_extension_issue_file_to_process`

- IDA 反编译 Xcode 的 `DVTInstrumentsFoundation`，`-[RemoteBundleLoader scheduleLibraryLoad:...]` 使用 `sandbox_extension_issue_file_to_process`（把 token 绑定到目标进程的 audit token），class `APP_SANDBOX_READ`，flag `SANDBOX_EXTENSION_DEFAULT`。
- 本地 patch MachInjector 使用相同 API，重跑测试。
- T1：patched 注入器 + dev probe → sharingd → ❌ **仍然失败**，sandbox log 精确报告：`Sandbox: sharingd(593) deny(1) file-map-executable <path>`。

**关键发现**：失败操作是 **`file-map-executable`**（不是 `file-read-data`）。`APP_SANDBOX_READ` extension 只覆盖 `file-read*` 类操作，**不覆盖** `file-map-executable`。是否绑定 audit token 无关紧要。

### 实验 3 — 直接读 sharingd sandbox profile

`/System/Library/Sandbox/Profiles/com.apple.sharingd.sb` 关键规则：

```scheme
(deny default)
(deny dynamic-code-generation file-map-executable nvram*)   ; 全局 deny
(allow file-map-executable                                   ; 白名单 5 个 System 子路径
    (subpath "/System/Library/Address Book Plug-Ins")
    (subpath "/System/Library/Components/AudioCodecs.component")
    (subpath "/System/Library/CoreServices/Encodings")
    (subpath "/System/Library/Filesystems/NetFSPlugins")
    (subpath "/System/Library/Video/Plug-Ins"))
(allow file-read*                                            ; extension 只作用于 read
    (extension "com.apple.app-sandbox.read") ...)
```

**结论 2**：sharingd profile **硬编码 5 个系统路径白名单**，其余路径的 `file-map-executable` 全部 deny，且**不接受任何 sandbox extension**。任何 dlopen 路径注入都是死路——无关签名、无关 extension class、无关是否绑定 audit token。

### 实验 4 — 排除「Xcode 能注入 sharingd」的假设

用户报告「Xcode attach sharingd 是成功的」。用 `sudo lldb -p 593` attach 后：
- `image list` 全部 920 个模块中无 `libRemoteInjectionPayload.dylib`、无 `DVTInstrumentsFoundation`、无匿名可执行段。
- 在 lldb 里执行 `p (void*)dlopen("...probe.dylib", 1)` 返回 NULL，`dlerror` 明写 `file system sandbox blocked mmap()`。

**结论 3**：Xcode 的「attach」实际上是 **lldb debugger attach**，走 `task_for_pid` + Mach exception port，**没有注入任何 payload**。所以「Xcode 能成功」这一表象跟代码注入无关。

## 最终结论

**sharingd 无法通过传统的 `dlopen` 路径注入代码**——不论 payload 签名如何，不论用什么 API 发放 sandbox extension，都会被 seatbelt profile 里硬编码的 `file-map-executable` 白名单拦截。这不是 bug，是 Apple 有意的安全策略：仅允许 sharingd 加载 5 个特定的系统扩展点。

## Round 1 落地的改进（除 socket 修复外）

### 1. MachInjector 改用 `sandbox_extension_issue_file_to_process`

同时改造 sync (`MIMachInjector.m`) 和 async (`MIMachInjectorAsync.m`) 两条路径：
- 先 `task_for_pid` → `task_info(TASK_AUDIT_TOKEN)` 取目标 audit token
- 再 `sandbox_extension_issue_file_to_process(APP_SANDBOX_READ, dylibPath, 0, auditToken)`
- audit 失败时 fallback 到旧的 `sandbox_extension_issue_file`

对 sharingd 无效（profile 不 honor extension for `file-map-executable`），但对**其他严格 seatbelt daemon**（profile 结构不同、依赖 emitting audit token 校验的）可能救活注入。上游到 MachInjector 仓库。

### 2. `AttachedEngineHandshakeError` 文案改进

`handshakeTimedOut` 的错误描述扩写，明确指出：
- 注入 RPC 返回成功但对端 dlopen 静默失败是最常见原因；
- 明确点名系统 seatbelt daemon（sharingd、rapportd 等）是「无法注入」的一类目标；
- 提示常规 App 目标应检查 `get-task-allow` 和 framework 路径可读性。

这只是「让用户看到有信息量的错误」的临时改进。彻底解决要把 `MIInjectionResult.remoteErrorMessage`（远端 dlerror 输出）端到端从 helper 一路传回 App——涉及 InjectionService protocol 改动，工程较大，放到 Round 3 与新注入路径一起做。

## 后续（Round 2 及以后）

sharingd 这类目标不是完全没救——`mach_vm_remap` 是「内存到内存」的映射，绕过 seatbelt 对 `file-map-executable` 的检查。Xcode 的 `RemoteInjectionAgent` 用的正是这条路径：将注入器进程里已 `dlopen` 的 payload 的 `__TEXT` 段 remap 到目标。

- **设计文档**：`Documentations/Plans/2026-07-16-sharingd-injection-via-mach-vm-remap-design.md`
- **Round 2 POC 实证纪要**：`Documentations/ResolvedIssues/2026-07-17-mach-vm-remap-poc-milestones.md`

Round 2 已完成 M1/M2 里程碑（sharingd 内 Swift `@_cdecl` 入口成功执行并发出 os_log marker），M3 定位到最后一个 blocker（libobjc image 注册），进入 Phase 2 工程化。

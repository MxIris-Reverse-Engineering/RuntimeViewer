# 2026-07-14 注入 seatbelt 守护进程（rapportd）后 XPC 回连被沙盒拒绝

**调查日期：** 2026-07-14
**修复落地：** 本日
**Severity：** Major —— 对 seatbelt-profiled 系统守护进程注入后完全无法建立回连
**触发场景：** 现场反馈 —— 注入 `rapportd` 后报错：

```
Connection state -> disconnected with error: XPC error: The operation couldn't be completed.
                    (SwiftyXPC.XPCError error 2.) (source: rapportd)
RuntimeViewerServer failed to create runtime engine: SwiftyXPC.XPCError.connectionInvalid
```

初始怀疑：「是不是 rapportd 这个守护进程不能用 XPC」，且「看了 rapportd 不是沙盒二进制」。

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 注入 rapportd 后，注入端建立 XPC 回连时立即 `connectionInvalid` |
| **误判点** | rapportd 无 `com.apple.security.app-sandbox` entitlement，被误认为「不受沙盒约束」 |
| **真因** | rapportd 跑在 seatbelt profile（`com.apple.rapportd.sb`，`(deny default)`）里，mach-lookup 只放行 Apple 白名单，第三方 Mach service 名一律拒绝 |
| **为何 socket 可行** | 同一 profile 有 `(allow network*)`；localSocket 只需 `connect()` 到 127.0.0.1，不碰 mach-lookup / 文件 |
| **Status** | **Fixed** —— 用 `sandbox_check` 运行时探测替换 entitlement 判断，命中沙盒即回退 socket |

---

## 根因

### 两套沙盒，别混为一谈

macOS 上有两种独立的沙盒机制：

1. **App Sandbox** —— 由 `com.apple.security.app-sandbox` entitlement 触发，有容器，活动监视器「沙盒」列显示「是」。Mac App Store 应用等使用。
2. **Platform / seatbelt profile 沙盒** —— 由具名 `.sb` profile 在启动时套上（经 `seatbelt-profiles` entitlement 或 LaunchDaemon plist 或进程内 `sandbox_init`），无容器，活动监视器那一列常显示「否」。Apple 系统守护进程几乎全用这套。

rapportd 属于第 2 种。它**没有** `com.apple.security.app-sandbox`（所以「看起来不是沙盒二进制」），但系统为它准备了 `/System/Library/Sandbox/Profiles/com.apple.rapportd.sb`：

```scheme
(deny default)                    ; 默认全拒
...
(allow mach-lookup                ; mach-lookup 仅白名单放行
    (global-name "com.apple.airportd")
    (global-name "com.apple.cloudd")
    ...几十个 Apple 自家服务...
)
(allow network*)                  ; 网络操作全放行 ← socket 可行的关键
```

`com.mxiris.runtimeviewer.service`（及 arm64e 变体 `dev.mxiris…` / `dev.arm64e.mxiris…`）都不在 mach-lookup 白名单里。

反向印证：rapportd 的 entitlements 里那一大串 `com.apple.security.exception.mach-lookup.global-name` 是**沙盒例外**entitlement，只有在进程处于沙盒中时才有意义 —— 其存在本身就证明 rapportd 被沙盒约束。

### 沙盒是按进程强制的，注入不逃逸

seatbelt 由内核（Sandbox.kext）按**进程**强制。rapportd 一旦以该 profile 启动，进程内所有代码 —— 包括注入进去的 `RuntimeViewerServer.framework` —— 都受同一 profile 管制。注入不新建进程、不换沙盒上下文。

于是注入端 `RuntimeXPCServerConnection` → `HelperPeerServer` 执行 `xpc_connection_create_mach_service(RuntimeViewerMachServiceName, …)` 时，内核比对 rapportd 沙盒：`(deny default)` 且不在白名单 → 拒绝 mach-lookup → XPC 立刻把连接置 invalid → `connectionInvalid`。

### 旧判断为何漏掉 rapportd

XPC-vs-socket 由宿主端与注入端**各自独立**判断，两边必须一致；而两处旧逻辑都只看 `com.apple.security.app-sandbox`：

| 位置 | 文件 | 旧逻辑 | 对 rapportd |
|---|---|---|---|
| 注入端选路 | `RuntimeViewerServer.swift` | `LSBundleProxy.forCurrentProcess()?.isSandbox` | nil/false → 选 XPC（错） |
| 宿主端选路 | `AttachToProcessViewModel.swift` → `RuntimeEngineManager.launchAttachedRuntimeEngine(isSandbox:)` | `RunningProcess.isSandboxed` → `BSDProcess.isSandboxed(pid:)`，仍只读 `app-sandbox` key | false → 起 XPC client（错） |

两边一致地错，都走了被 seatbelt 拦死的 XPC。

---

## 修复

思路：**不再从 entitlement 推断沙盒，而是用 SPI `sandbox_check` 直接问内核「该 pid 能否 mach-lookup 我们的服务」**。命中拒绝就回退 localSocket。宿主端探 `targetPID`、注入端探 `getpid()`，问的是同一进程的同一操作，结论必然一致，从根上消除两边分歧。该判断对旧场景是严格超集：

- 未沙盒 app → `0`（允许）→ 仍走 XPC
- App Sandbox app → 拒 → 仍走 socket（与旧行为一致）
- seatbelt 守护进程（rapportd 等）→ 拒 → **新**走 socket

### 改动清单（6 处文件）

1. **`RuntimeViewerCore/Sources/RuntimeViewerCoreObjC/include/RuntimeViewerCoreObjC.h` / `.m`**
   新增 C shim `RVSandboxCheckGlobalName(pid, operation, globalName)`，在 C 里包 SPI `sandbox_check`。**必须用 C shim**：`sandbox_check` 是变参函数，arm64 变参 ABI 把变参放在栈上，无法用 Swift `@convention(c)` 函数指针表达；由 C 编译器生成调用才正确。带 `SANDBOX_CHECK_NO_REPORT` 抑制探测产生的沙盒违规日志。

2. **`RuntimeViewerCore/Package.swift`**
   给 `RuntimeViewerCommunication` target 加依赖 `RuntimeViewerCoreObjC`（无环：`RuntimeViewerCore` 本就同时依赖两者）。

3. **`RuntimeViewerCore/Sources/RuntimeViewerCommunication/SandboxProbe.swift`（新增）**
   `SandboxProbe.isMachLookupBlocked(pid:globalName:)` 与便捷方法 `isRuntimeViewerServiceMachLookupBlocked(pid:)`。`sandbox_check` 返回 `0`=允许（或未沙盒）、正值=拒绝、`-1`=错误；取 `result > 0` 为「被拦」，错误按未拦处理以保留 XPC 默认。

4. **`RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift`（注入端）**
   用 `SandboxProbe.isRuntimeViewerServiceMachLookupBlocked(pid: getpid())` 替换 `LSBundleProxy.isSandbox` 选路；删掉不再使用的 `import LaunchServicesPrivate`。

5. **`RuntimeViewerUsingAppKit/.../Attach Process/AttachToProcessViewModel.swift`（宿主端）**
   不再读 RunningApplicationKit 的 `isSandboxed`，改用对 `runningItem.processIdentifier` 的探测；加 `import RuntimeViewerCommunication`。

---

## 验证

### 构建

`./RunScript.sh --no-launch`（Debug-arm64e）→ **`** BUILD SUCCEEDED **`**，六处改动全部编过（含注入端 `RuntimeViewerServer` 与主 app）。

一条良性链接告警：`RuntimeViewerCoreObjC.o was built with class_ro_t pointer signing enabled, but previous .o file was not`。分析：
- 同 target 里本就有同类告警（`LaunchServicesPrivate.o`），非本次新引入的类别。
- `otool` / `nm` 确认 `RuntimeViewerCoreObjC.o` 无 `__objc_classlist` 段、无任何 `_OBJC_CLASS` 符号，只有三个 C 函数 —— 不含 ObjC class metadata，没有可被错误签名的 `class_ro_t`。该告警纯属 SwiftPM 与 arm64e Xcode target 的编译 flag 不一致，无运行时风险。

### `sandbox_check` 行为（对真实 rapportd pid 实测）

| 探测对象 | 服务名 | 返回 | 预期 |
|---|---|---|---|
| rapportd | `com.mxiris.runtimeviewer.service` | `1` | 拒绝 ✓ |
| rapportd | `dev.mxiris.runtimeviewer.service` | `1` | 拒绝 ✓ |
| rapportd | `dev.arm64e.mxiris.runtimeviewer.service` | `1` | 拒绝 ✓ |
| rapportd | `com.apple.cloudd`（白名单内） | `0` | 允许 ✓（证明探测能区分，非恒拒） |
| 自身（未沙盒） | `com.mxiris.runtimeviewer.service` | `0` | 允许 ✓ |

坐实两个承重假设：rapportd 沙盒确实拒绝我们的 mach-lookup（根因），且 `SandboxProbe` 对其返回 `true` 从而切到 socket；对普通进程返回 `false`，XPC 行为不变。

### 尚未覆盖

完整的「注入 rapportd → socket 回连成功 → 拉到 runtime 数据」端到端往返需 SIP 关闭 + 运行 app + 实注入，属运行时验证，需在目标环境自行跑一遍确认。代码层与 SPI 行为层已验证。

---

## 影响面 / 取舍

- **行为超集**：仅改变「被沙盒拦 mach-lookup」进程的选路（App Sandbox + seatbelt 守护进程），未沙盒进程一律不变。
- **不改依赖**：按约定不动 RunningApplicationKit，宿主端改为自行探测，`RunningProcess.isSandboxed` / `RunningApplication.isSandboxed` 不再参与选路。
- **SPI 依赖**：新增对 `sandbox_check` 的依赖。项目本就大量使用 SPI（`LSBundleProxy`、`csops`、MobileGestalt 等），风格一致。
- **仍可能受限的场景**：即便切到 socket，若某目标 seatbelt profile 未放行 `network*`，socket 同样会被拦。rapportd 因 `(allow network*)` 可行；其它守护进程需各自看 profile。

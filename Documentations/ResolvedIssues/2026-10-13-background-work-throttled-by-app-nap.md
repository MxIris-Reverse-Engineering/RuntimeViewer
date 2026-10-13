# 2026-10-13 切到别的 App 后，后台索引与语料构建慢了四到十倍：App Nap 让本地引擎服务失去了提升

**调查日期：** 2026-10-13
**修复落地：** 本日，`next`
**Severity：** Medium —— 功能正常但慢：用户一切走，Find 的语料和后台索引就慢四到十倍（SwiftUI 的语料 18 秒变 187 秒），而用户正是在等它们的时候切走的
**触发场景：** 文档打开后，Always Index 的批次或 Find 的语料还在跑，用户切到别的 App；约 30 秒后系统让 RuntimeViewer 进入 App Nap

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | Report navigator 里 5 个镜像（AppKit、SwiftUI、SwiftUICore、libswiftCore、Foundation）的语料从 14:44 到 14:50 才陆续建完；同一份代码的计时探针在终端里跑 Debug，语料合计 53 秒 |
| **影响范围** | 在本地引擎 XPC 服务里跑、而 App 在等的全部工作：后台索引、语料构建，以及下文「同类」里列的几条。引擎还在 App 进程里跑时（[0037](../Evolutions/0037-local-runtime-xpc-service.md) 之前），App Nap 直接压的是 App 自己的线程——14:54 App 处于 App Nap 时，`ps` 看到它的优先级同样是 4——所以多半不是 0037 引入的，只是换了一条路；进程内的情形没有实测 |
| **根因** | 服务是 launchd 的 adaptive job，没被提升时就是 Darwin 后台档（优先级 4、只用效率核）。它的提升来自 App 挂在它上面、尚未回复的请求，前提是 App 在给出 importance；App 进了 App Nap 就不再给出 |
| **Status** | **Fixed** —— 文档有后台工作在进行时（`DocumentState.reportActivity`），App 持有一个 user-initiated 的 process activity，App 因此不进 App Nap，服务一直被提着；工作一结束就放掉 |

---

## 根因

### 服务的优先级跟着挂着的请求走

- **launchd 把服务当作 adaptive job。** `launchctl print pid/<App pid>/dev.JH.RuntimeViewerLocalRuntimeService` 里是
  `spawn type = adaptive (6)`；runningboardd 对它记的是 `Ignoring role changes because this process is not role managed`，
  不按 App 的前后台给它定角色。
- **adaptive 没被提升就是后台档。** XNU `osfmk/kern/task_policy.c`：「Adaptive daemons are DARWIN_BG unless boosted」。
  Darwin 后台档把线程优先级压到 4，Apple Silicon 上只排到效率核——这台 M1 Max 是 8 个性能核加 2 个效率核。
- **提升挂在请求上。** `xpcservice.plist(5)`：App 发来的消息会提升服务，提升的寿命与消息（或由它创建的回复）相同。
  SwiftyXPC 到回复时才 `xpc_dictionary_create_reply(original)`（`XPCConnection.swift`），所以请求在处理期间一直被持有。
  App 等的工作都是这样的请求：语料构建是 `buildInterfaceCorpus`，从排队到建完一直挂着；后台索引在 App 进程里的
  `RuntimeBackgroundIndexingManager` 对每个镜像发一次 `loadImageForBackgroundIndexing`，索引完才回复。

### App Nap 截断了这条链

同一个文件里，App 是否算 live importance donor 的判定：App 处于 suppression（即 App Nap）时，只要
`task_policy_suppression_flags` 带 `TASK_POLICY_SUPPRESSION_NONDONOR` 就不算——而默认值正是
`TASK_POLICY_SUPPRESSION_IOTIER2 | TASK_POLICY_SUPPRESSION_NONDONOR`。不在前台但没进 App Nap 的 App 仍然算 donor。
所以用户切走本身没事，30 秒后 App Nap 生效那一刻，App 挂着的每个请求都不再提升服务，服务落回后台档。

探针是终端里的普通进程，既不是 adaptive job，也不会进 App Nap，所以 10-13 上午报的「Debug 104→53 秒」一直是满速的数字。

## 现场证据

**时间线**（runningboardd 统一日志，App pid 48529，服务 pid 48546）：

| 时间 | 事件 |
|---|---|
| 14:44:24.866 | App 到前台（`Set darwin role to: UserInteractiveFocal`） |
| 14:44:26.564 | 服务启动 |
| 14:44:32.176 | 用户切走（`UserInteractiveNonFocal`） |
| 14:45:01.642 | App Nap 生效（`Set AppNap state: … active:Y … cpu:Y`） |
| 14:46:29 | 开始打印 SwiftUI 的语料 |
| 14:49:36.353 | SwiftUI 语料建完 |
| 14:50:21.956 | 用户切回，App Nap 解除（`active:N`） |
| 14:50:30.018 | AppKit 语料建完 |

**服务自己的日志**（`RuntimeInterfaceCorpusStore` 的 info 级「Built corpus … in X s」，只在内存里留一阵，要尽快取）：

| 镜像 | App 里 | 探针（Debug，同一 MachOSwiftSection `10341963`） |
|---|---|---|
| SwiftUI | 187.4 秒 | 18.1 秒 |
| AppKit | 53.7 秒 | 12.7 秒 |

SwiftUI 慢得更多，是因为那段时间两个效率核还要分给别的镜像的索引；AppKit 打印时其余工作都已结束，53.7 秒与 98 秒
效率核 CPU（见下）摊到两个空闲效率核上大致相符。

**服务的线程**：14:54 服务空闲时 `ps -M` 看到它的全部线程都是优先级 4。

**复现**：同一个探针套上 `taskpolicy -b`（把进程放进 Darwin 后台档），线程同样是优先级 4：

| 阶段（AppKit） | 正常（负载约 8） | `taskpolicy -b`（负载 33 降到 8） |
|---|---|---|
| 加载与索引 | 27.96 秒墙钟，27.92 秒 CPU | 304.97 秒墙钟，112.31 秒 CPU（0.37 核） |
| 语料 | 12.71 秒墙钟，39.90 秒 CPU（3.14 核） | 149.34 秒墙钟，98.31 秒 CPU（0.66 核） |

同样的工作在效率核上要多花 2.5 到 4 倍的 CPU 时间；负载高时后台档连两个效率核也分不满，所以比 App 里还慢。

## 修复

- **`BackgroundWorkProcessActivity`**（`RuntimeViewerApplication`）订阅 `DocumentState.reportActivity`（有索引批次在跑，
  或有语料在排队、在打印），为真时 `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`，
  变假、文档关闭、对象释放三种情况都 `endActivity`。不论信号报多少次，同一时刻只持有一个 activity。
- **`DocumentState.backgroundWorkProcessActivity`** 与两个协调器一样按需创建，由 `Document.makeWindowControllers`
  在两个协调器之后触发，`documentWillClose()` 关掉。
- **为什么是 `.userInitiatedAllowingIdleSystemSleep`**：user-initiated 让 App 不进 App Nap；允许系统空闲睡眠，不为索引
  让 Mac 一直醒着。这组选项还包含禁止 sudden termination 与 automatic termination，App 本来就没声明支持这两项
  （`Info.plist` 里没有 `NSSupportsSuddenTermination` / `NSSupportsAutomaticTermination`），所以退出行为不变。
- **代价**：后台工作进行期间 App 不会被 App Nap 降速，耗电相应多一些；工作结束即恢复，空闲的文档照常进 App Nap。

**不采用的做法：**

- **在服务的 `Info.plist` 里写 `XPCService._ProcessType = Interactive`**，让服务永远不降档。Apple 自己的几个 XPC 服务
  用了这个私有键（Virtualization 的 `EventTap` / `Installation`、`GPUToolsReplayService`、`PerformanceTraceService`），
  第三方服务写了是否生效没有验证；而且服务从此完全不受系统节能约束，App 被用户隐藏、甚至没在等任何东西时也一样。
- **在 XPC 连接层按在途请求持有 activity。** 覆盖面更大，但把「哪些工作值得让 App 保持清醒」这个 App 层的决定放进了
  传输层；引擎在进程内跑时同样需要它，与传输无关。
- **提高语料构建任务的 QoS。** Darwin 后台档对全部线程一律封顶，QoS 改多高都一样。

## 验证

- **测试**：`BackgroundWorkProcessActivityTests` 四条——跟随信号只持有一个 activity、关闭文档即放掉且之后不再持有、
  对象释放时放掉、在真实引擎上建 Foundation 语料期间持有并在全部建完后放掉；`DocumentStateLifecycleTests` 加一条断言：
  关闭从未打开过的文档不会创建它。把 `DocumentState` 的接线临时换成恒为 `false`，最后那条集成测试即失败（两处期望落空），
  还原后通过。整个 `RuntimeViewerApplicationTests`（479 个）只有 `SidebarRootViewModelTests.clickingImageSwitchesDocument`
  一条失败，它在满载时本来就偶发失败，单独重跑三次都通过，也不经过这次改动的代码。
- **App 内复测**：待补。

## 同类，未修

以下工作同样在服务里跑、App 同样在等，但不在 `reportActivity` 里，App 进 App Nap 时应当同样会慢，均未实测：

- **导出 interface 与批量导出**：用户发起后切走等它导出完，是常见用法。
- **MCP 桥**：请求来自 LLM 客户端，用户这时多半就在那个客户端里，RuntimeViewer 很可能正处于 App Nap。
- **CLI host**：App 作为 `runtime-viewer-cli` 的 host 时，请求来自终端，情形同上。

# 2026-07-14 注入连接被拒后 engine 残留、无 UI 提示、界面无反馈

**调查日期：** 2026-07-14
**修复落地：** 本日
**Severity：** Major —— 注入回连失败时静默残留一个死 engine，用户既看不到错误也看不到进度
**关联：** 承接 [seatbelt daemon injection socket fallback](2026-07-14-seatbelt-daemon-injection-socket-fallback.md)。那篇解决「rapportd 该走 socket」；本篇解决「无论何种原因回连失败时，attach 流程的清理与反馈」。

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 注入目标后对端未连回来时，`RuntimeEngineManager` 永久保留该 engine，无错误弹窗，attach sheet 也无 loading（像卡死） |
| **根因** | `connect()` 只建「本地半连接」并乐观置 `.connected`，不等对端握手；清理与掉线通知只挂在永不到来的 `.disconnected` 上 |
| **适用范围** | 所有 attach/注入失败（sandbox 拒绝、注入失败、目标崩溃等），非 rapportd 专属 |
| **Status** | **Fixed** —— 注入后加握手确认探针 + 超时；失败则报错并 `terminate`；attach sheet 加 loading |

---

## 根因

以 attach 注入为例（`AttachToProcessViewModel` → `RuntimeEngineManager.launchAttachedRuntimeEngine`）：

1. **`connect()` 只建本地那一半，且乐观报 `.connected`。** `RuntimeEngine.connect()`（`RuntimeEngine.swift:267-277`）client 角色下，`communicator.connect` 建好连接对象后**立刻** `stateSubject.send(.connected)`：
   - localSocket client → 实为 `RuntimeLocalSocketServerConnection.start()`，只 `bind()`/`listen()`，未等 socket client accept；
   - remote(XPC) client → 只连上 helper broker，未等注入端 `ServerLaunched`。

   两种情况 `connect()` 都不抛异常。

2. **注入排在 `launchAttachedRuntimeEngine` 之后。** ViewModel 先 launch（建 socket server / broker）再 `injectApplication`。对端只可能在注入之后才连回来。

3. **对端连不回来 → 本地半连接仍「活着」→ 永不产生 `.disconnected`。** socket server 仍在 listen、XPC broker 连接仍有效，`handleConnectionStateChange` 收不到 `.disconnected(error:)`。

4. **清理与掉线通知只挂在 `.disconnected` 上。** `observeRuntimeEngineState`（`RuntimeEngineManager.swift`）只有 `.disconnected` 分支才 `terminateRuntimeEngine` + `notifyDisconnected`。于是 engine 永久残留、无提示。真正的错误（如注入端的 `connectionInvalid`）只落在目标进程日志里，宿主无通道接收。

5. **附带：假「已连接」。** 乐观 `.connected` 还会触发 `notifyConnected`。

---

## 修复

按「改动面小、不动 `connect()` 乐观语义」的取舍：

### 1. 握手确认探针 + 超时（`RuntimeEngineManager`）

新增 `confirmAttachedRuntimeEngineConnected(name:identifier:isSandbox:timeout:)`：注入后调用，对 engine 发轻量 `requestEngineList` round-trip 探针，成功即确认对端在，失败/超时则抛 `AttachedEngineHandshakeError`。

关键实现细节（`pollUntilPeerAnswers`）：

- **轮询**吸收「注入后对端才连回来」的窗口。socket server 在无 peer 时 `sendMessage` **立即抛 `notConnected`**（`RuntimeForwardingConnection.swift:55`），重试直到注入端 connect。
- **独立 deadline（`AsyncStream` 竞速，取先到者）**：XPC 传输**忽略** per-request timeout（`RuntimeConnection` 默认 `sendMessage(name:timeout:)`），单次探针可能永久阻塞。用「探针 Task」与「超时 Task」向同一 `AsyncStream` 竞速、取第一个 yield，即便探针 hang 也能按 deadline 返回，**放弃**（不 await）卡住的探针。

### 2. attach 流程接线（`AttachToProcessViewModel`）

- 注入后 `try await runtimeEngineManager.confirmAttachedRuntimeEngineConnected(...)`；失败落入既有 catch → `terminateAttachedRuntimeEngine` + `errorRelay.accept`（基类自动弹 `NSAlert`）。
- 顺带修正既有 bug：catch 对 `RunningApplication` 曾用 `bundleIdentifier` 去 terminate，与 launch 用的 `processIdentifier` **不一致**导致清理落空。现统一 `identifier = runningItem.processIdentifier.description`，launch/confirm/terminate 三处一致。

### 3. Loading 反馈（`AttachToProcessViewModel` + `AttachToProcessViewController`）

- ViewModel：`@Observed private(set) var isAttaching` + `override var delayedLoading { $isAttaching.asDriver() }`，在 Task 首尾 `isAttaching = true` / `defer { false }`（沿用 `ExportingConfigurationViewModel` 范式）。
- VC：`override var shouldDisplayCommonLoading { true }`，基类自动把 `delayedLoading` 绑到 `CommonLoadingView`。确认探针最长等 `timeout`（默认 10s），全程 spinner，界面不再像卡死。

---

## 验证

- **构建**：`./RunScript.sh --no-launch`（Debug-arm64e）→ `Build Succeeded`，零 error。
- **编译坑（已修）**：`SandboxProbe` 的 public 方法参数最初用 `pid_t`，因 `RuntimeViewerCommunication` 开了 `.internalImportsByDefault`（`import Foundation` 为 internal），`pid_t` 在 public 签名不可见而报错；改用 stdlib 的 `Int32`（`pid_t` 即 `Int32` typealias，调用方全部传 Int32，等价）。`RuntimeViewerApplication` 未开该特性，故 `RuntimeEngineManager` 里 public 的 `TimeInterval` / `LocalizedError` 无碍。
- **尚未覆盖**：真实注入目标 → 探针成功/超时 → alert + 清理的端到端验证需运行时环境（SIP 关闭 + 真实注入），建议在目标机跑一遍确认。

---

## 影响面 / 取舍

- 不动 `RuntimeEngine` 的乐观 `.connected` 语义（改动面大、波及 bonjour/mirroring，风险高），仅在 attach 流程外挂确认。
- 探针用现成的 `requestEngineList`（注入端 server 角色装有 `.engineList` handler，返回空数组也算 round-trip 成功）。
- 超时默认 10s：够注入端加载 + 连回来，又不至于让用户等太久。

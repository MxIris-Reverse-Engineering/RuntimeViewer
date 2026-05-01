# 2026-04-30 Engine Mirroring Routing Findings

**调查日期：** 2026-04-30
**触发场景：** 现场反馈 —— "iOS 设备连上之后侧边栏一直 loading；MacBook 熄屏断开时设备名 engine 漏出来"
**日志：** `RuntimeViewer-Apple-Vision-Pro.log`、`RuntimeViewer-JH's-iPhone-Pro.log`、`RuntimeViewerLocalHost.log`
**当时拓扑：**

| 主机 | 角色 | instanceID |
|---|---|---|
| JH's Mac Studio Ultra (LocalHost) | observer | `6E51668E-3E56-4819-A5AE-3CEABA831163` |
| JH's Mac mini | engine sharing peer | `A9645927-5603-496A-AB44-A74DEEBB1AC2` |
| JH's Virtual Machine 1 | engine sharing peer | `F571760B-3D4E-4C11-9A2A-FEDA461FE68B` |
| JH's MacBook Pro | engine sharing peer | `007224B9-819B-4FE1-9BC7-B5D3D840474C` |
| jhs-iphone-pro | direct-bonjour leaf | `9806B1D7-CCEE-4266-BC4C-B4D0EEDC106A` |
| Apple Vision Pro | direct-bonjour leaf | （类似） |

相关链路与角色定义见 `Documentations/EngineMirroringWalkthrough.md`。

## 一览

| Class | Count | Notes |
|---|---:|---|
| Major | 2 | iOS/visionOS 永久 loading；leaf disconnect 后设备名 mirror 漏出 |

## 如何使用本文

- 每条 issue 有稳定 ID `EM.<N>`，可在 commit message 中引用（`fix(EM.1): …`）。
- "Reproduction" 列追踪是否产出了失败用例：
  - **Pending** — 尚未尝试
  - **Manual** — 仅靠现场或手动多设备复现
  - **N/A** — 结构性问题，靠 grep 验证即可
- 修复落地后在对应行加上 `Fixed by <commit>`，**不要删除**记录。

---

## Issue EM.1 — iOS / visionOS 侧边栏永久 loading

| 字段 | 内容 |
|---|---|
| **Severity** | Major |
| **Where** | `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineManager.swift:217-237` |
| **Reproduction** | Manual（iOS / visionOS 与本机仅有 awdl0 直连可达时复现） |
| **Status** | **Fixed by `6063be3`** —— `sendRequest<Response>` 加可选 timeout（nil 保留原行为），`requestEngineList()` 默认 5s；超时后外层 catch 走 `directBonjourEngines.insert` 路径。顺带修了 `sendSemaphore` 在 throw 路径上未 release 的 leak（之前每次 timeout/写失败都会占住一个 slot，阻塞后续 `sendRequest<Response>`）。 |

### 现象

iPhone / Vision Pro 在侧边栏正常出现一个 section，但 section 下的 engine 永远停在 loading 骨架屏，没有任何数据。

### 证据

LocalHost 日志中，每个直连 Bonjour peer 都打了 `requesting engine list from <peer>`，但只有 Mac 系 peer 配对出现 `received N descriptors from <peer>`：

| Line | Event |
|---:|---|
| 5046 | `[EngineMirroring] requesting engine list from jhs-iphone-pro...` |
| 8954 | `[EngineMirroring] requesting engine list from Apple Vision Pro...` |
| 696 | `[EngineMirroring] received 5 descriptors from JH's Mac mini` ✓ |
| 1668 | `[EngineMirroring] received 2 descriptors from JH's Virtual Machine 1` ✓ |
| 6422 / 7710 | `[EngineMirroring] received 1 descriptors from JH's MacBook Pro` ✓ |

`grep "received .* descriptors from jhs-iphone-pro"` 与 `grep "received .* descriptors from Apple Vision Pro"` 命中 **0** 行。

`RuntimeEngineManager.swift:220` 的 `try await runtimeEngine.requestEngineList()` 在 iOS / visionOS 这两条路径上**永久挂起** —— 没有 timeout，没有抛错，整个 inner Task 永远不 resume。

### Response 为什么没到

LocalHost 日志 line 297，由 Network.framework 在 `bonjour.jhs-iphone-pro` 进入 `connecting` 时打印：

```
nw_endpoint_flow_failed_with_error
  [C13.1.1.1 fe80::5066:8dff:fe93:df05%awdl0.51265
   in_progress channel-flow
   (...interface: awdl0[802.11]...)]
  already failing, returning
```

Mac Studio 跟 iPhone 的 Bonjour TCP 连接走 **awdl0**（Apple Wireless Direct Link）。Mac↔Mac 走 `en0`，响应正常；iOS / visionOS 没有有线网卡，awdl0 是唯一可达路径。

iPhone 端日志相互印证 —— iPhone 成功 *handle* 了 engineList 请求并回写了 94 字节响应，紧接着把 1.8 MB 的 `imageList` + `imageNodes` 通过同一连接写出去：

```
20:27:11.970 [iPhone] Handling request: ...engineList → returning 0 descriptors
20:27:11.970 [iPhone] Sending 94 bytes
20:27:11.970 [iPhone] Sent request: ...engineList
20:27:13.252 [iPhone] Sent request: ...reloadData (after imageList=91kB, imageNodes=1707kB)
20:27:24.338 [iPhone] tcp_output flags=[R.] state=CLOSED         ← 11s 后
20:27:24.341 [iPhone] nw_read_request_report Receive failed with error "Operation timed out"
```

11 秒内没有任何入站包 → iPhone 端 TCP read timeout 并 RST。iPhone 写出去的字节没有任何一个在 Mac Studio 的同一 connection 上产生 `Received N bytes` —— awdl0 channel-flow 在以 silently dropping 入站包的方式 failing。

### 侧边栏为什么仍然显示 iPhone section

可见的 "jhs-iphone-pro" section **不是**本地直连 engine —— 而是从 Mac mini 通过 engine sharing 推过来的转发 mirror：

```
descriptor: 9806B1D7.../bonjour.jhs-iphone-pro
            host:192.168.50.99 port:51274           （Mac mini 的 PROXY）
            originChain: 9806B1D7..., A9645927...   （iPhone, Mac mini）
```

`rebuildSections`（RuntimeEngineManager.swift:730-731）会隐藏所有不在 `directBonjourEngines` 中的 client `bonjour.*` engine，而 `directBonjourEngines.insert` 只在 hung 住的 `requestEngineList` future settle 后才执行。所以本地通往 iPhone 的直连 engine 一直不可见；section 完全由通过 Mac mini 的 mirror engine 渲染。

但 Mac mini 自己的 `bonjour.jhs-iphone-pro` engine 走的也是同样的 awdl0 通道连 iPhone，Mac mini PROXY relay 回来的也是空数据 → 侧边栏永久 loading。

### 根因

两个互相叠加的问题：

1. **`requestEngineList` 没有 timeout**（RuntimeEngineManager.swift:220）。当响应被 awdl0 静默丢弃时，await 永不 settle，永不 resolve 到 `[]`，永不抛错。`directBonjourEngines.insert(...)` 永不执行。本地直连 engine 永远隐藏。
2. **awdl0 channel-flow 不稳** —— 当 iOS/visionOS 仅 awdl0 可达时容易出现。属于 framework 层面的问题，超出 app 控制；但 app 因为 (1) 对它的反应非常糟糕。

### 修复建议

`connectToBonjourEndpoint` 内部的最小改动：

```swift
let descriptors = try await withTimeout(seconds: 5) {
    try await runtimeEngine.requestEngineList()
}
```

timeout 触发时走现有的 catch 分支，已经会 `directBonjourEngines.insert(...)` 并 rebuild。本地直连 engine 立即可见，侧边栏渲染依靠现有 message handlers 后续推过来的数据。

这**不**修 awdl0 不稳的问题 —— `imageList` / `imageNodes` 仍可能到不了 —— 但去掉了「永久挂起」这个失败模式，让用户至少能看到点东西，且语义上跟空 descriptors 路径一致。

超出本 finding 范围但值得后续跟踪：
- 检测到仅 awdl0 可达的路径时拒绝 Bonjour，要求用户配置 IP。`NWParameters.requiredInterfaceType = .wifi` 显式跳过 awdl0。
- iOS 端把 1.7 MB 的 `imageNodes` 分块带 ack/resume，避免单次大包卡死 awdl0。

### 复现

Manual：把 iOS / visionOS peer 跟本机放在仅靠 awdl0 直连可达的网络环境（host 和 peer 没有共享 Wi-Fi 基础设施）；观察侧边栏 section 出现但永远不填充。在 60 秒窗口内 grep `requesting engine list from` 与 `received .* descriptors from` 即可看到一一对应被打破。

---

## Issue EM.2 — 设备名 mirror engine 在 leaf 断连后漏入侧边栏

| 字段 | 内容 |
|---|---|
| **Severity** | Major |
| **Where** | `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineManager.swift:478-501` 与 `RuntimeEngineMirrorRegistry.swift:137-150` |
| **Reproduction** | Manual（3 主机拓扑：本机、中介 peer、leaf peer，leaf 断连） |
| **Status** | Fixed —— `cleanupMirroredEnginesOnDisconnect` Case 2 现在同时跑 `clearAllOwnedBy` 与新增的 `clearAllWithHostID`，覆盖中介与叶子两种拓扑；`RuntimeEngineMirrorRegistryTests` 增补了 3 条 leaf-disconnect 单测。 |

### 现象

MacBook（关 lid / 进入睡眠）从网络上掉线时，本机侧边栏中它对应的 section 多了一个名字就叫 `JH's MacBook Pro` 的 engine —— 即一行 engine 的 display name 跟设备名一模一样。视觉上看起来像 section header 漏到了 engine 列表里。

### 证据

LocalHost 日志，第一次 MacBook 断连前后：

| Line | Event |
|---:|---|
| 7224 | `Endpoint removed: JH's MacBook Pro` |
| 7330 | `Connection state -> disconnected (source: JH's MacBook Pro)` |
| 7344 | `emitted 11 engines: ..., tcp.JH's MacBook Pro.192.168.50.99.51279`（mirror 仍在） |
| 7362 | `rebuildSections: 5 sections — ..., JH's MacBook Pro(1)` |

剩下的那 1 个 engine 是 `tcp.JH's MacBook Pro.192.168.50.99.51279`：

- `source` = `.directTCP(name: "JH's MacBook Pro", host: 192.168.50.99, port: 51279, role: .client)`
- `source.description` = `"JH's MacBook Pro"`
- `hostInfo.hostID` = `007224B9-...`（MacBook 的 instanceID，取自 descriptor 的 `originChain[0]`）

这条 engine 来自 **Mac mini**（`A9645927-...`）push 的 descriptor，因此 `mirrorRegistry.ownership[engineID] = "A9645927-..."`。

### 根因

`cleanupMirroredEnginesOnDisconnect`（RuntimeEngineManager.swift:478-501）的 Case 2 只调了 `clearAllOwnedBy(hostID: runtimeEngine.hostInfo.hostID)`：

```swift
let peerRemovals = mirrorRegistry.clearAllOwnedBy(
    hostID: runtimeEngine.hostInfo.hostID  // "007224B9-..."
)
```

`clearAllOwnedBy`（`RuntimeEngineMirrorRegistry.swift:137-150`）按 **ownership** 匹配，即 *直接上游* —— descriptor 的推送方。这条 mirror 的 ownership 是 `A9645927-...`（Mac mini），不是 `007224B9-...`（MacBook）。所以 `clearAllOwnedBy("007224B9-...")` 不会动它。

而 `bonjour.JH's MacBook Pro` 从 `bonjourRuntimeEngines` 中移除后，`deduplicateForwardedMirrors`（RuntimeEngineManager.swift:775-808）就失去了原本压制这条 mirror 的钩子：

```swift
let localRouteNames = Set(
    runtimeEngines.filter {
        engine.hostInfo.hostID == section.hostID && (
            systemRuntimeEngines.contains(...) ||
            attachedRuntimeEngines.contains(...) ||
            bonjourRuntimeEngines.contains(...)        // ← MacBook 的 bonjour engine 之前在这里
        )
    }.map { $0.source.description }                    // ← 之前包含 "JH's MacBook Pro"
)
```

本地直连 engine 还活着时，`localRouteNames` 包含 `"JH's MacBook Pro"`，同名 mirror 被过滤掉。lid close 把这条 engine 从 `bonjourRuntimeEngines` 移除，`localRouteNames` 变空，mirror 通过 dedup 过滤 —— **漏出来**。

理论上 Mac mini 最终会感知到 MacBook 不可达，push 一份新的 descriptor list（不含 MacBook），`mirrorRegistry.reconcile` 把这条删掉。但是：

- 这是间接路径，依赖 peer 主动驱动；
- Mac mini 跟 MacBook 之间也可能挂在 awdl0（视配置而定），延长 stale 时间；
- 这个窗口期内侧边栏就是错的。

### 注释为什么跟当前 bug 矛盾

`cleanupMirroredEnginesOnDisconnect` 上方注释（lines 461-477）解释了为什么 *旧实现* 用 `hostInfo.hostID` 匹配：

> The old implementation matched by `engine.hostInfo.hostID == runtimeEngine.hostInfo.hostID`,
> which both wiped too little (transitive mirrors were missed because their hostInfo.hostID
> is the original host C, not the direct upstream B) ...

旧行为对**中介节点断连**这一情形是错的（B 断连 → 通过 B 的 transitive C-mirror 应该被清，但它们的 `hostInfo.hostID == C ≠ B`）。

新基于 ownership 的行为在中介情形下正确，但又对**叶子节点断连**情形错了（C 断连 → 通过 B 转发的 C-engine mirror 的 `ownership == B ≠ C`）。

两种情形需要 **不同** 的 key。只挑其中一个就一定漏另一个。

### 修复建议

`cleanupMirroredEnginesOnDisconnect` 的 Case 2 改为同时跑两次查找，并对结果取并集：

```swift
let disconnectedHostID = runtimeEngine.hostInfo.hostID

let peerRemovals   = mirrorRegistry.clearAllOwnedBy(hostID: disconnectedHostID)        // 中介节点路径
let originRemovals = mirrorRegistry.clearAllWithHostID(hostID: disconnectedHostID)    // 叶子节点路径
let allRemovals    = peerRemovals + originRemovals
```

`clearAllWithHostID` 是 `RuntimeEngineMirrorRegistry` 的新方法，按 `engineID` 前缀匹配（回忆 `engineID = "{hostID}/{localID}"`）：

```swift
@discardableResult
public func clearAllWithHostID(hostID: String) -> [ReconcileOutcome.Removal] {
    let prefix = "\(hostID)/"
    let affectedIDs = engines.keys.filter { $0.hasPrefix(prefix) }
    var removals: [ReconcileOutcome.Removal] = []
    for id in affectedIDs {
        if let engine = engines.removeValue(forKey: id) {
            removals.append(.init(engineID: id, engine: engine))
        }
        ownership.removeValue(forKey: id)
    }
    return removals
}
```

注意：`clearAllWithHostID` **不要**碰 `lastDescriptorIDsBySource`。dedup 缓存按直接上游 hostID 索引；leaf 断连不会 invalidate 任何 source 的缓存。（而 `clearAllOwnedBy` 会清掉对应 source 的缓存 —— 这对中介节点断连是正确的。）

如果 MacBook 通过 peer 重新可达（Mac mini 看到它回来），Mac mini 会 push 新的 descriptor list，`reconcile` 会重新创建 mirror。

### 复现

线缆/Wi-Fi 直连 leaf C（如 MacBook），加一个会 mirror C 并 push descriptor 给本机的中介 Mac peer B。验证 `mirrorRegistry.engines` 中确实存在 `engineID` 以 C 的 instanceID 开头、`ownership` 是 B 的 instanceID 的 entry。然后关 C 的 lid（或杀 C 的 app）让本机到 C 的直连 engine 断开。检查：

- `mirroredEngines` —— entry 还在
- `runtimeEngineSections` —— C 的 section 仍在列，mirror 可见
- 只有等 B 重新 push 一份不含这条 entry 的 list 才会消失

---

## Status table

| ID | Title | Severity | Reproduction | Fix |
|---|---|---|---|---|
| **EM.1** | iOS / visionOS 侧边栏永久 loading（awdl0 + 无 timeout） | Major | Manual（仅 awdl0 直连） | **Fixed by `6063be3`** — `sendRequest<Response>` 支持可选 timeout，`requestEngineList()` 默认 5s；顺手修了 `sendSemaphore` 在 throw 路径上的 leak |
| **EM.2** | leaf 断连后设备名 mirror 漏入侧边栏 | Major | Manual（3 主机拓扑） | **Fixed** — `cleanupMirroredEnginesOnDisconnect` Case 2 同时调 `clearAllOwnedBy` + `clearAllWithHostID`，叶子断连按 `engineID` 前缀清理；3 条新单测 |

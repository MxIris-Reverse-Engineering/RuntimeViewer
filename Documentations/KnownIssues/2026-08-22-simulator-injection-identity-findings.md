# 模拟器注入身份改造的自查裁决 — 2026-08-22

提案 [0013](../Evolutions/0013-inject-ios-simulator-process.md) 落地步骤 2「身份改造」实现完成后，
对改动引入的语义变化做的自查。**这不是一轮 code review**，而是「把 `hostInfo.hostID` 从进程级
（instanceID）改成设备级（deviceID）」这一个动作的连带影响排查 —— 凡是拿 `hostID` 当键的地方
都要重新问一遍「它现在还成立吗」。

ID 形式 `SIMID.<N>`。审查基线：分支 `feature/inject-ios-simulator-process` @ `93956a6b` +
未提交的身份改造改动。

## 已修（同批次）

| ID | 严重度 | 摘要 | 修复 |
|---|---|---|---|
| SIMID.1 | Major | 镜像路径的 `hostID` 与直连路径分叉：`handleEngineListChanged` 的 engineFactory 拿 `descriptor.originChain.first` 当 `hostID`，而 originChain 装的是 **instanceID**。改动前两者恰好相等（一台设备一个安装），改成设备级后同一台远程设备的直连 engine 与镜像 engine 落进两个 Section，且 `deduplicateForwardedMirrors` 靠 `hostInfo.hostID == section.hostID` 找同 Section 的本地路由，去重随之失效，用户看到重复条目 | `RuntimeRemoteEngineDescriptor` 新增 `hostID`（`@Default("")`），发送端填 `engine.hostInfo.hostID`，接收端空串时回退 `originChain.first`；测试 `codableHostID` + `codableWithMissingFields` 的 `hostID == ""` 断言 |
| SIMID.2 | Major | `RuntimeSource.identifier` 对 bonjour client 返回 `"bonjour.\(name)"`，而 name 已改成对端的**进程显示名**，两个进程可以同名 —— 它是通知去重键和 engine mirroring 注册表的键，同名即碰撞 | 改用 `id.rawValue`（进程级唯一键）。对旧行为等价：改动前 client 的 identifier 就是 `endpoint.name`，回退链下 `uniqueKey == name`；测试 `sourceIdentifierIgnoresDisplayName` |
| SIMID.3 | Minor | `terminateRuntimeEngine` 从 source 解构 `name` 去清 `knownBonjourEndpointKeys` / `pendingReconnectEndpoints`，而这两张表现在按 `uniqueKey` 键；name 改成进程名后清不掉，engine 断开后同一端点再也连不回来 | 改为解构 `identifier`（连接时就是拿 `endpointKey` 填的） |

## 不修（裁决留档）

### SIMID.4 — `clearAllWithHostID` 的前缀现在是设备级

**问题**：`engineID = "{hostID}/{localID}"`。`hostID` 转设备级后前缀也随之设备级，于是
「某一个 bonjour engine 断开」会让 `cleanupMirroredEnginesOnDisconnect` 里的
`clearAllWithHostID(hostID: disconnectedHostID)` 清掉**同一台设备上所有**engine 的镜像，
而不只是断开那一个的。

**四问**：

1. **能复现吗** —— 当前不能。要走到这条路，对端必须支持 engine sharing 并对
   `requestEngineList` 返回**非空** descriptor 列表。iOS payload（`RuntimeViewerServer.swift`
   的 `#else` 分支）从不注册 engine list handler，请求超时后宿主一律把它塞进
   `directBonjourEngines`，那些 engine 在 `mirrorRegistry` 里没有任何条目。Mac 之间倒是支持
   engine sharing，但本机 engine 的 `hostInfo` 走 `RuntimeEngine.init` 的默认值
   `hostID = localInstanceID`，一台 Mac 上所有 engine 共享同一个值 —— 改动前后都是如此，
   没有变化。
2. **main 上是否也有** —— 否。main 上 `hostID` 是 instanceID，同设备多个注入进程各拿到不同
   instanceID，前缀天然互不相同。这是本次改动新引入的可能性。
3. **值不值得修** —— 现在不值。触发面为空（见第 1 条），而正确的修法是让 `mirrorRegistry`
   改用 engine 级键而非从 `engineID` 前缀反推归属，属于架构改动，量级远超本次范围；
   在触发面为空的前提下先记账更划算。
4. **以前修过吗** —— 这段代码本身就是一次修复的产物，但修的是**相反方向**的问题。
   `clearAllWithHostID` 由 `b350f8c1`（2026-05-01，追踪为
   [EM.2](2026-04-30-engine-mirroring-routing-findings.md)）引入：当时 leaf peer 整机掉线
   （MacBook 合盖）后，经由中介 forward 过来的镜像清不掉 —— `clearAllOwnedBy` 按
   **ownership**（直接上游）匹配，而 forwarded mirror 的 ownership 是中介而非叶子。修法就是
   补一条按 `engineID` 前缀（`"{hostID}/"`）匹配的清理路径。

   **所以它的设计前提是「hostID 标识一台主机，主机下线则其下全部镜像作废」。** 那个前提在
   `hostID = instanceID` 的年代靠「一台设备一个安装」勉强成立；换成真正的设备级 ID 后前提
   反而更贴合注释原文，但同时引入了它当初没有的情形 —— **一台主机上有多个可独立下线的进程**。
   EM.2 修的是「整机掉线清不干净」，本条担心的是「单进程掉线清过了头」，方向相反，
   不是同一问题的回归。

**复核判据（下次触发前必须重新裁决）**：只要出现下面任一条，本裁决即失效 ——

- iOS / 模拟器 payload 开始注册 engine list handler（返回非空 descriptor）；
- 出现「同一台远程设备上多个 Bonjour server 进程」且其中之一支持 engine sharing 的拓扑；
- `RuntimeEngine.init` 的默认 `hostInfo.hostID` 从 `localInstanceID` 改成设备级值 ——
  那会让一台 Mac 上的多个注入 engine 也落进同一前缀。

## 尚未验证（留待端到端）

### SIMID.5 — `SIMULATOR_UDID` 的实际存在性

`RuntimeNetworkBonjour.localDeviceID` 在模拟器上先读进程环境里的 `SIMULATOR_UDID`，读不到
才回退 `DeviceIdentifier.uniqueDeviceID`。这个优先级是为了绕开
`DeviceIdentifier` 的 keychain 回退 —— 从被注入进程里发起的 keychain 查询可能按进程解析，
那会把一台模拟器重新拆成「每个注入进程一个 Section」，正是本次要消除的症状。

**本机当前无 booted 模拟器，且启动模拟器需单独授权，故未实测。** 风险有界：即使
`SIMULATOR_UDID` 不存在，也只是退回原路径，不会比不加这一层更差。留待提案 0013 落地步骤 8
的端到端验证一并确认。

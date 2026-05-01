# Engine Mirroring Walkthrough

跨主机 RuntimeEngine 共享系统的 read-only 走读：四类 engine 集合如何拼起来、Bonjour 如何建立管理通道、runtime 数据如何通过 proxy 层流动。读 `RuntimeEngineManager.swift`、`RuntimeEngineProxyServer.swift`、`RuntimeEngineMirrorRegistry.swift` 时可以当 reference 来用。

针对此设计的具体 bug 调查见 `Documentations/KnownIssues/2026-04-30-engine-mirroring-routing-findings.md`。

## 1. 总览：四类 Engine + 两种角色

`RuntimeEngineManager`（singleton, `@MainActor`）持有四类 engine 集合（`RuntimeEngineManager.swift:23-32`）：

| 集合 | 来源 | 作用 |
|---|---|---|
| `systemRuntimeEngines` | 本机 `.local` + Mac Catalyst 客户端 | 自己跑出来的 engine |
| `attachedRuntimeEngines` | 注入到其他进程的 engine（XPC 或 LocalSocket） | 本机已注入应用的 runtime |
| `bonjourRuntimeEngines` | Bonjour 发现到的对端「管理通道」 | 跟其他设备的 control link |
| `mirroredEngines` | 通过 Bonjour 对端转发过来、本机用 `.directTCP` 回连其代理的 engine | 远端共享给我的 engine |

`runtimeEngines`（`:262-264`）是上面四个的拼接，对外统一暴露的读侧投影。

每台设备同时扮演两个角色：

- **Server 端** —— 把自己手上的 engine（system/attached/远端 mirror）通过每个 engine 一个 `RuntimeEngineProxyServer` 监听 TCP 端口对外共享。
- **Client 端** —— 发现对端、拉对端的 engine 列表、通过 directTCP 回连对端代理。

## 2. Bonjour 管理通道

### 2.1 自己作为 Server

`init()` 第一件事就是 `startBonjourServer()`（`:128, :168-184`）：

- 用机器名（`SCDynamicStoreCopyComputerName`）创建 `.bonjour(role: .server)` 的 RuntimeEngine，`pushesRuntimeData: false`。纯控制平面。
- TXT record 里带 `localInstanceID`，用来识别「这条 endpoint 是不是我自己」。
- 故意先启 server 再启 browser，确保 browser 看到自家 endpoint 时 TXT 已就绪。

### 2.2 自己作为 Client

`browser.start(...)`（`:130-153`）：

- 发现新 endpoint：忽略 instanceID 等于自己的，否则调用 `connectToBonjourEndpoint`。
- endpoint 移除：**不**清 `knownBonjourEndpointNames`。NWListener 接受连接后服务会重新注册，会出现 endpoint flap，这里清掉会导致重复连接。真正清除时机由 `terminateRuntimeEngine` 在真正 disconnect 时处理。

### 2.3 `connectToBonjourEndpoint`（`:188-252`）

1. **重名去重**（`knownBonjourEndpointNames`）：同一个 name 已有 engine 时，把新 endpoint 暂存进 `pendingReconnectEndpoints`。这是为 iOS 后台挂起场景设计的 —— iOS server 恢复后会重新广告，旧的 NWConnection 还没超时。
2. **创建 client 端 engine**：用 `endpoint.instanceID` 作为 `hostID`，`originChain = [instanceID]`。
3. 连接成功后调用 `requestEngineList()`：
   - **0 个 descriptor**：远端不支持 engine sharing（典型是 iOS、被注入的 App），加入 `directBonjourEngines`，让 `rebuildSections` 直接显示。
   - **>0 个 descriptor**：交给 `handleEngineListChanged` 走 mirror 流程。
4. **指数退避重试**：失败时 2s/4s/8s 共 3 次。

### 2.4 终止 —— `terminateRuntimeEngine(for:)`（`:306-337`）

- 是 Bonjour client 角色就清 `knownBonjourEndpointNames`，并把 `pendingReconnectEndpoints` 里同名的拿出来准备重连。
- 是 sandbox socket 客户端就删持久化记录。
- 移除对应集合里的 engine、清 icon cache、清 `directBonjourEngines` 中的 ObjectIdentifier。
- 最后如果有 pending 重连，`Task` 异步重新 `connectToBonjourEndpoint`。

## 3. Server 端：把自己的 engine 共享出去

### 3.1 每个 engine 一个 Proxy Server

`updateProxyServers(for:)`（`:595-647`）监听 `rx.runtimeEngines`（四个集合的 combineLatest）变化：

- 移除已不存在 engine 的 proxy。
- 给新 engine 起一个 `RuntimeEngineProxyServer`，但**跳过 `bonjourServerEngine`**（它本身就是管理通道，没必要再代理）。
- proxy 在后台 task 里 `start()`，启好之后立刻把更新后的 descriptor 列表 `pushEngineListChanged` 给所有连进来的 Bonjour client。

### 3.2 `RuntimeEngineProxyServer`

每个实例代理**一个 RuntimeEngine** 的 actor，定义在 `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift`：

- `start()`（`:36-71`）：监听 `.directTCP(role: .server)` 端口（OS 分配），拿到 `host:port` 后被 `buildEngineDescriptors` 读取以填入 descriptor 的 `directTCPHost` / `directTCPPort`。
- 客户端连上后（`statePublisher == .connected`）：
  - `setupRequestHandlers()`（`:117-170`）：注册一堆请求处理器，把 client 发来的请求**转发到 engine**：`runtimeObjectsInImage`、`runtimeInterfaceForRuntimeObjectInImageWithOptions`、`runtimeObjectHierarchy`、`loadImage`、`imageNameOfClassName`、`memberAddresses`，以及 AppKit-only 的 `iconRequestCommand`。
  - `setupPushRelay()`（`:215-251`）：订阅 `engine.imageNodesPublisher` / `engine.reloadDataPublisher`，把变更推给客户端。
  - `sendInitialData()`（`:73-107`）：主动把当前 `imageList` + `imageNodes` + `reloadData` 一次性发过去，避免客户端连上后看到空白。

### 3.3 构造 descriptor

`buildEngineDescriptors()`（`:522-554`）：

```
engineID         = "{engine.hostInfo.hostID}/{engine.source.identifier}"  // 全局唯一
originChain      = engine.originChain + [localInstanceID]                // 把自己 append 进去做环路检测
direct{Host,Port} = proxy.host / proxy.port
iconData         = proxy.iconData()
```

`bonjourServerEngine` 与没有 proxy 的 engine 都会被跳过。

### 3.4 主动推送时机

`startSharingEngines()`（`:556-593`）设置三个推送源：

1. `RuntimeEngine.engineListProvider`：被远端调用 `requestEngineList()` 时返回 descriptors。
2. `RuntimeEngine.engineListChangedHandler`：接收远端 push 过来的列表（client 路径，见 §4）。
3. `bonjourServerEngine.statePublisher` 变成 `.connected`（有 client 接进来）时立即 push 一次当前列表。

加上 §3.1 里 proxy 启好后会主动 push，覆盖了「客户端连进来」「engine 列表变化」「proxy 就绪」三个时机。

## 4. Client 端：把对端的 engine mirror 过来

### 4.1 入口

`handleEngineListChanged(descriptors, from: engine)`（`:656-719`）来自两条路径：

- 主动拉：`connectToBonjourEndpoint` 里 `requestEngineList()` 的返回值（`:220, :229`）。
- 被动收：远端 server 通过 `pushEngineListChanged` 推过来（`:562-567`）。

把所有调度协议工作交给 `mirrorRegistry.reconcile(...)`，自己只负责副作用（启停 engine、icon 缓存、`mirroredEngines` 同步）。

### 4.2 `RuntimeEngineMirrorRegistry`

纯状态容器，定义在 `RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineMirrorRegistry.swift`，被故意设计成不依赖网络栈以便单测。三块状态：

- `engines: OrderedDictionary<engineID, RuntimeEngine>` —— 当前 mirror 出来的 engine。
- `ownership: [engineID: 直接上游 hostID]` —— 是从哪个 peer 那转发过来的（注意是**直接**上游，不是 originChain 的最初源头）。
- `lastDescriptorIDsBySource: [hostID: Set<engineID>]` —— 每个直接上游上次 push 的 ID 集合，用于跨 push 去重。

### 4.3 `reconcile(...)` 规则（`:69-110`）

按顺序：

1. **环路检测**：丢弃 `originChain.contains(localInstanceID)` 的 descriptor。比如 A→B→A 这种回环，descriptor 经 B 转一圈再回到 A 时 A 自己已经在 chain 里了。
2. **每源 dedup**：本次 newIDSet 跟该 source 上次完全相同就 `.skippedDuplicate` 直接返回。
3. **每源 reconcile**：删掉「之前由该 source 拥有但本次不在新列表里」的 engine —— **只动这个 source 拥有的**，不会误伤别的 peer 的 mirror。
4. **先到先得添加**：`engines[engineID] != nil` 就跳过；不会因为 B 又转了一遍 C 就把 A 已经有的 C mirror 替换掉。

`handleEngineListChanged` 拿到 `.applied(removed:added:)` 后：

- 对 `removed` 调 `engine.stop()` + 清 icon cache。
- 对 `added` 创建 directTCP engine（`source: .directTCP`）、建立观察、写入 icon、`connect()`。
- 把 `mirrorRegistry.engines` 同步到 `mirroredEngines` 触发 UI 更新。

### 4.4 mirror 用的就是 §3.2 那个 proxy

注意 `engineFactory` 里给 mirror 用的 source（`:670-675`）：

```swift
.directTCP(name: descriptor.source.description,
           host: descriptor.directTCPHost,
           port: descriptor.directTCPPort,
           role: .client)
```

这个 host/port 就是远端 `RuntimeEngineProxyServer` 监听的地址。所以 mirror engine 一旦 `connect()`，就直接连到对端进程内那个 actor，所有 runtime 请求/推送都经它转给真正的 engine。**Bonjour 那条管理通道只用来传 descriptor 列表**，runtime 数据流是另开 directTCP 的。

## 5. 断连清理：两种情形

`cleanupMirroredEnginesOnDisconnect(of:)`（`:478-501`）在 engine 状态变 `.disconnected` 时跑（`:451`）。注释里专门解释过为什么按下面两种情形分：

- **情形 1**：断的 engine 本身就是个 mirrored entry（也就是它跟 proxy 的 directTCP 挂了）→ `clearOwnMirror(matching:)` 只清这一项，不动 dedup cache。
- **情形 2**：断的是直接 peer（Bonjour client / system engine），它之前向我们 push 过 descriptor → `clearAllOwnedBy(hostID:)` 把所有 ownership = 这个 peer 的 mirror 全清掉。

情形 2 的关键点（`:471-477` 注释）：A→B→C 链路里 B 挂了，A 必须把对 C 的 mirror 也清掉，因为没有 B 就到不了 C。但是这里**只能用「直接上游 = B 的 hostID」匹配**，不能用 mirror 自身 `hostInfo.hostID`（那是 C），否则会漏掉。

`clearAllOwnedBy` 还会清掉对应 source 的 dedup cache，让重连后能接受新 push。

中介节点断连与叶子节点断连之间 cleanup 路径不对称的具体 bug，见 `KnownIssues/2026-04-30-engine-mirroring-routing-findings.md` 的 EM.2。

## 6. Section 构建：UI 怎么呈现

`rebuildSections()`（`:723-755`）：

1. 遍历 `runtimeEngines`，按 `hostInfo.hostID` 分组。
2. **隐藏纯管理 Bonjour client engine**：在 `bonjourRuntimeEngines` 里、且不在 `directBonjourEngines` 里的，跳过 —— 因为它的内容已经通过 mirror 暴露了。
3. **保留 directBonjourEngines**：远端没返回 descriptors 的那种（iOS、注入 App），用 Bonjour 通道直接当 runtime 通道展示。
4. 调用 `deduplicateForwardedMirrors`。

### 6.1 转发回环去重

`deduplicateForwardedMirrors(in:)`（`:775-808`）解决一个具体问题：A 已经直连 B 的 iPhone，B 把这条直连**当作自己的一个 engine 转发**给 A，A mirror 之后会在同一 section 里看到「直连」和「绕道 B 走过来的」两份名字相同的项。

策略：

- 收集本 host 下所有「本地路径」的 source description（system + attached + bonjour，包括被 `rebuildSections` 隐藏的管理通道 bonjour engine —— 因为 forwarded mirror 重复的就是这些路径）。
- 把 mirror 中跟这些本地路径同名的丢掉。
- **故意放在 section 构建步而不是 reconcile/connect 里**：这样 `mirrorRegistry` 仍然保留备用路由，本地直连一旦掉，下一次 `rebuildSections` mirror 就会重新出现，不用等 upstream 重新 push。

注意：这个 dedup 依赖本地直连路径仍然存在。本地直连断开后 `localRouteNames` 缩小，原先被压制的同名 mirror 会浮现 —— 具体故障场景见 `KnownIssues/2026-04-30-engine-mirroring-routing-findings.md` 的 EM.2。

## 7. 关键不变量

1. **engineID = `{hostID}/{source.identifier}`** 是跨主机的唯一 key。`source.identifier` 单独是每台主机本地 proxy 表的 key。
2. **管理通道（Bonjour）和数据通道（directTCP）分开**：Bonjour 只传 control 消息和 descriptor list；runtime 数据走每个 engine 自己的 proxy 端口。
3. **`mirrorRegistry.ownership` 记录的是直接上游**，不是原始 host。Transitive cleanup 在中介节点断连时正确传播；叶子节点断连需要另一条路径（`engineID` 前缀匹配）。
4. **`originChain` 携带环路检测面包屑**：push 时 append，receive 时检查。多跳 loop-back descriptor 直接丢。
5. **每源增量 reconcile + 先到先得添加**：两个 peer 同时报告同一个 engine 不会互相覆盖；先到的那个拿到所有权。当所有者掉线时另一个 peer 在 `lastDescriptorIDsBySource` 里的旧报告**不会**自动重新创建 entry —— 它必须重新 push 一次。

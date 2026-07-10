# RuntimeViewerCommunication 连接实现 & RuntimeEngineManager / ProxyServer 架构

本文档分两大部分：

1. **`RuntimeViewerCommunication` 里的各种连接实现** —— 统一抽象、五种传输、消息通道与线路协议。
2. **`RuntimeEngineManager` / `RuntimeEngineProxyServer` 架构** —— 引擎的发现、连接、共享（Sharing）与镜像（Mirroring）拓扑。

代码位置：
- 通信层：`RuntimeViewerCore/Sources/RuntimeViewerCommunication/`
- 引擎与代理：`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`、`RuntimeEngineProxyServer.swift`
- 引擎管理器：`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineManager.swift`、`RuntimeEngineMirrorRegistry.swift`

---

# 第一部分：RuntimeViewerCommunication 连接实现

## 1. 总览：一个协议，五种传输

整个通信层围绕单一协议 `RuntimeConnection` 建立。上层（`RuntimeEngine`）永远只面对这个协议，不关心底下究竟是 XPC、TCP 还是 stdin/stdout。选择哪种传输由工厂 `RuntimeCommunicator` 根据 `RuntimeSource` 决定。

```
                        ┌─────────────────────────────────┐
                        │          RuntimeEngine          │   上层业务
                        │   (只依赖 RuntimeConnection 协议) │
                        └───────────────┬─────────────────┘
                                        │ connect(to: RuntimeSource)
                                        ▼
                        ┌─────────────────────────────────┐
                        │        RuntimeCommunicator       │   工厂 / 分发
                        │   switch source → 具体 Connection │
                        └───────────────┬─────────────────┘
                                        │ 返回 any RuntimeConnection
        ┌───────────────┬───────────────┼───────────────┬────────────────┐
        ▼               ▼               ▼               ▼                ▼
  ┌───────────┐  ┌────────────┐  ┌─────────────┐ ┌────────────┐  ┌────────────┐
  │  XPC      │  │  Network   │  │ LocalSocket │ │ DirectTCP  │  │   Stdio    │
  │ Connection│  │ Connection │  │ Connection  │ │ Connection │  │ Connection │
  └─────┬─────┘  └──────┬─────┘  └──────┬──────┘ └─────┬──────┘  └─────┬──────┘
        │               │               │              │               │
    HelperPeer      NWConnection     BSD socket     NWConnection    FileHandle
    (Mach XPC)      + Bonjour        (127.0.0.1)    (host:port)     (pipe)
```

### 传输选型对照

| Source | 传输 | 典型场景 | 沙盒兼容 | 需要配置 |
|--------|------|----------|:---:|----------|
| `.remote` | XPC Mach Service | 同机跨进程（需特权 helper）、代码注入非沙盒 App | ❌ | helper 安装 |
| `.bonjour` | Bonjour + NWConnection | iOS/visionOS 设备 ↔ Mac（局域网自动发现） | ❌ | `NSBonjourServices` |
| `.localSocket` | TCP `127.0.0.1` | 注入到**沙盒** App | ✅ | 无 |
| `.directTCP` | 直连 TCP `host:port` | 已知地址直连 / 引擎镜像代理 | ✅ | 无 |
| `.stdio` | stdin/stdout 管道 | CLI 工具、Language Server | ✅ | 无 |

> `.local`（同进程）在 `RuntimeCommunicator` 中直接抛 `localConnectionNotSupported` —— 本地引擎不走连接层，直接在 `RuntimeEngine` 内联执行。

---

## 2. 核心抽象

### 2.1 `RuntimeConnection` 协议（`RuntimeConnection.swift`）

所有传输实现都满足这一协议，提供三类能力：

**① 状态观测**
```swift
associatedtype StatePublisher: Publisher<RuntimeConnectionState, Never>
var statePublisher: StatePublisher { get }
var state: RuntimeConnectionState { get }
func stop()
```
状态机只有三态（`RuntimeConnectionState.swift`）：`.connecting → .connected → .disconnected(error:)`。

`statePublisher` 通过关联类型声明，各实现以 `some Publisher<RuntimeConnectionState, Never>` 返回私有的 `CurrentValueSubject`（SwiftUI `View.body` 式的 opaque witness）——订阅方拿不到 `send` 能力，subject 的可变性被完全封在实现内部。在 `any RuntimeConnection` 上访问时被擦除为 `any Publisher<RuntimeConnectionState, Never>`，直接 `.sink` 即可。

**② 发送消息（多种重载）**
- 即发即忘：`sendMessage(name:)` / `sendMessage(name:request:)`
- 请求-响应（按名字）：`sendMessage<Response>(name:)`、带 `timeout:` 版本
- 请求-响应（类型化）：`sendMessage<Request: RuntimeRequest>(request:)`，返回 `Request.Response`

**③ 注册处理器**
- `setMessageHandler(name:)`（按名字）
- `setMessageHandler(requestType:)`（类型化 `RuntimeRequest`）

`timeout` 的语义值得注意：基于 `RuntimeMessageChannel` 的传输（Network / LocalSocket / DirectTCP / Stdio）会**真正实现**每请求超时；XPC 没有原生的每请求截止时间，协议默认扩展会**忽略** `timeout` 直接转发无超时版本。

### 2.2 `RuntimeConnectionInfo`
把传输相关的本地端点信息（`host` / `port`）透出，避免上层向下强转。只有 `RuntimeDirectTCPServerConnection` 返回非 nil —— 这正是 ProxyServer 拿到自己监听端口的入口（第二部分会用到）。

### 2.3 `RuntimeSource`（`RuntimeSource.swift`）—— 连接的"身份"

`RuntimeSource` 是一个 `Codable` / `Hashable` 的枚举，描述**连接目标的身份**（稳定、可持久化、可做等值/哈希）。五个 case 对应五种传输，每个都带 `role: .client / .server`。

关键设计——**Business Role（业务角色）≠ Socket Role（套接字角色）**：

| Role | 业务角色 | 套接字角色 | 使用者 |
|------|---------|-----------|--------|
| `.client` | 客户端（发查询） | **Server**（bind/listen） | 主 App |
| `.server` | 服务端（处理查询） | **Client**（connect） | 被注入代码 |

这个反转是 `localSocket` 的核心（详见 §3.3）。

### 2.4 `RuntimeConnectionCredential`（`RuntimeConnectionCredential.swift`）—— 会话级凭证

`RuntimeSource` 是稳定身份，但有些连接还需要一个**每会话临时解析**的凭证（由服务发现或前一次握手产生），它不应参与身份的等值/哈希，因此拆成独立的可选参数：

| Source | Credential | 是否必需 |
|--------|-----------|---------|
| `.bonjour` + `.client` | `.bonjour(NWEndpoint)` | 必需（端点由 `NWBrowser` 运行时产出） |
| `.remote` + `.client`（重连） | `.xpcServer(HelperPeerEndpoint)` | 可选（直连重连已注入进程） |
| 其它 | `nil` | — |

### 2.5 `RuntimeCommunicator`（`RuntimeCommunicator.swift`）—— 工厂

一个纯 `switch source` 分发器。它的职责是：解析 role、注入 credential、处理 localSocket 的角色反转、按平台裁剪（`#if os(macOS)` / `#if canImport(Network)`），最终产出一个 `any RuntimeConnection`。上层调用永远是同一句：

```swift
let connection = try await communicator.connect(to: source, credential: ..., modifier: ...)
```

`modifier` 闭包在连接激活**之前**运行，用来预先安装业务处理器——顺序至关重要（见 §3.1 XPC 两阶段）。

---

## 3. 五种连接实现详解

### 3.0 两条实现路线

实现分成两族（没有基类继承，全部是协议组合）：

```
RuntimeConnection (protocol, associatedtype StatePublisher)
├── RuntimeForwardingConnection (protocol, associatedtype Connection)   ← 转发协议
│     · 协议扩展把所有 sendMessage/setMessageHandler 重载
│       转发给 underlyingConnection（协议只要求 { get }）
│     · underlyingConnection 负责真正的收发 + RuntimeMessageChannel 组帧
│     · 各实现类自持 private stateSubject，以 some Publisher 作 witness
│     │
│     ├── RuntimeNetworkClient/ServerConnection      → RuntimeNetworkConnection
│     ├── RuntimeLocalSocketClient/ServerConnection  → RuntimeLocalSocketConnection
│     ├── RuntimeDirectTCPClient/ServerConnection    → RuntimeDirectTCPConnection
│     └── RuntimeStdioClient/ServerConnection        → RuntimeStdioConnection
│
└── RuntimeXPCConnection (直接实现 RuntimeConnection)                   ← 特殊
      ├── RuntimeXPCClientConnection
      └── RuntimeXPCServerConnection
```

- **走 `RuntimeForwardingConnection` 的四族**：共享 `RuntimeUnderlyingConnection` 协议 + `RuntimeMessageChannel`（JSON + `\nOK` 组帧）。它们的差异只在"字节怎么进出"（socket / NWConnection / FileHandle）。
- **状态发布分两种模式**：纯转发型（NetworkClient、DirectTCPClient、Stdio 两个）在 init 里订阅 underlying 的 `statePublisher` 原样桥接进自己的 subject；编排型（NetworkServer、DirectTCPServer、LocalSocket 两个）过滤/重译 underlying 状态（预就绪握手不外发、监听器重启补 `.connecting`），跨重连维持稳定的状态序列。
- **XPC 独立成族**：因为它委托给 `HelperPeer` 库（`HelperPeerClient` / `HelperPeerServer`），后者自己管握手、重连、状态流，所以 XPC 适配器不需要 `RuntimeMessageChannel`。

---

### 3.1 XPC 连接（`RuntimeXPCConnection.swift`，仅 macOS）

**用途**：主 App ↔ Mac Catalyst helper；特权操作；注入非沙盒 App 后的重连。

`RuntimeXPCConnection` 是 `HelperPeer.PeerConnection` 的薄适配器：把 peer 的 `AsyncStream<PeerConnectionState>` 桥接成 Combine 的 `CurrentValueSubject<RuntimeConnectionState>`，所有 `sendMessage` 直接转发给 `peer`。

**两个子类 = 两种 peer 角色**：

- `RuntimeXPCClientConnection`（主 App 侧，`HelperPeerClient`）
  - **初次握手** `init(identifier:modifier:)`：连特权 helper → 注册自己的 listener 端点 → 等 server 的 `ServerLaunched`。
  - **直连重连** `init(identifier:serverEndpoint:modifier:)`：App 重启后已知 server 端点（来自注入端点注册表），跳过 broker 握手直连并发 `ClientReconnected`。
- `RuntimeXPCServerConnection`（服务提供方，`HelperPeerServer`）
  - 从 broker 取 client 端点 → 反向直连 → 发 `ServerLaunched` → 把自己的 listener 端点注册进 Mach Service 的"注入端点注册表"（`announceListenerEndpoint`），供 App 下次重启直连重连。

**两阶段初始化（load-bearing）**：顺序必须是
```
init lib peer → super.init → modifier(装业务处理器) → peer.activate()
```
`peer.activate()` 才会激活 listener / 发 `ServerLaunched`。若把握手塞进 lib peer 的 init，对端会在本侧处理器就位**之前**就开始发业务请求——这正是 Catalyst 连接与代码注入回归 bug 的根因，靠两阶段拆分修复。

XPC 独特点：**不可重连**（SwiftyXPC 限制），只能销毁重建；`sendMessage(timeout:)` 忽略超时。

---

### 3.2 Network / Bonjour 连接（`RuntimeNetworkConnection.swift`）

**用途**：iOS/visionOS 设备 ↔ Mac，通过 Bonjour 局域网自动发现。

```
┌─────────────────┐                       ┌─────────────────┐
│   iOS 设备       │   ① Bonjour Browse    │      Mac        │
│                 │ ────────────────────> │                 │
│  NetworkClient  │                       │  NWListener     │
│  (NWConnection) │ <── ② TCP Connect ─── │  (广播服务)      │
│                 │ ═══ ③ Messages ══════ │  NetworkServer  │
└─────────────────┘                       └─────────────────┘
```

底层 `RuntimeNetworkConnection` 包一个 `NWConnection`：
- TCP keepalive（idle 2s / interval 2s / count 3）+ `noDelay`，`includePeerToPeer = true`（启用 AWDL 点对点），`serviceClass = .responsiveData`。
- **`.waiting` 容忍窗口**：本地网络权限弹窗 / DNS 解析 / 网络切换期间会短暂进入 `.waiting`，代码给 10 秒容忍再判失败，避免误杀。
- 服务发现与广播在 `RuntimeNetwork.swift`：`RuntimeNetworkBrowser`（`NWBrowser`）+ Bonjour TXT 记录（携带 `localInstanceID`、hostName、机型、系统版本、是否模拟器）。
- 服务类型 `_runtimeviewer._tcp`。`localInstanceID` 持久化在 UserDefaults，用于**过滤自己**和镜像时的环路检测。

两个子类：`RuntimeNetworkClientConnection`（用发现到的 `NWEndpoint` 主动连）、`RuntimeNetworkServerConnection`（起 `NWListener` 广播 + accept）。

---

### 3.3 LocalSocket 连接（`RuntimeLocalSocketConnection.swift`）—— 沙盒注入专用

**用途**：把 dylib 注入到**沙盒** App（Numbers、Pages……）后与之通信。这是最巧妙的一族。

**为什么用 TCP localhost 而不是 XPC / Unix Socket？**

| 方式 | 沙盒兼容 | 免配置 |
|------|:---:|:---:|
| XPC Mach Service | ❌ | ✅ |
| Bonjour/Network | ❌（需 `NSBonjourServices`） | ❌ |
| Unix Domain Socket | ❌（路径受限） | ✅ |
| **TCP Localhost** | **✅** | **✅** |

**套接字角色反转（核心）**：沙盒 App 不能 `bind()`（EPERM），但能 `connect()`。而被注入代码正是跑在沙盒里，所以：

```
┌─────────────────────────┐                    ┌─────────────────────────┐
│  RuntimeViewer 主 App    │                    │   目标进程（沙盒）        │
│  业务角色: Client(发查询) │   ① 起 socket server │                        │
│  套接字:   SERVER        │   ② 注入 dylib       │                         │
│  (bind/listen OK)       │ ─────────────────> │  业务角色: Server(处理)   │
│                         │                    │  套接字:   CLIENT         │
│                         │ <──── ③ connect ───│  (沙盒里 connect OK)      │
│  sendMessage(request)   │ ──── request ────> │  handleMessage(request)  │
│  receive(response)      │ <─── response ─────│  return response         │
└─────────────────────────┘                    └─────────────────────────┘
```

因此 `RuntimeCommunicator` 在 `.localSocket` 分支做了反转：
- `.client`（业务） → `RuntimeLocalSocketServerConnection`（套接字 server）
- `.server`（业务） → `RuntimeLocalSocketClientConnection`（套接字 client）

**端口发现——确定性哈希，零文件 IO**：沙盒隔离无法共享 `/tmp`，于是两端各自用 djb2 哈希从 identifier 算出**同一个**端口：
```
port = djb2(identifier) % 16383 + 49152   // 动态端口区 49152–65535
```
见 `RuntimeLocalSocketPortDiscovery.computePort`。

**其它工程细节**：
- 底层 `RuntimeLocalSocketConnection` 用裸 BSD socket + 独立 `readQueue`/`writeQueue`，`TCP_NODELAY` 关 Nagle。
- 收包循环对 `EINTR`/`EAGAIN`/`EWOULDBLOCK` 重试（注入进程里信号频繁），对端关闭 → `.peerClosed`。
- `stop()` 先 `shutdown(SHUT_RDWR)` 再 `close()`，可靠唤醒阻塞在另一线程的 `recv()`。
- 客户端 `RuntimeLocalSocketClientConnection` 内置**重连循环**（500ms 间隔）+ `pendingHandlers` 快照，断线后自动重连并重装处理器，用自持的 private `stateSubject` 跨重连桥接状态。

---

### 3.4 DirectTCP 连接（`RuntimeDirectTCPConnection.swift`）

**用途**：已知 `host:port` 直连，无需 Bonjour。**引擎镜像的 ProxyServer 就用它**（第二部分核心）。

```
┌─────────────────────┐                    ┌─────────────────────┐
│  Client App         │   TCP Connect      │  Server App         │
│  输入/扫码 host:port │ ─────────────────> │  显示 IP:Port / 二维码│
│  NWConnection       │ ═══ Messages ═════  │  NWListener         │
└─────────────────────┘                    └─────────────────────┘
```

与 Bonjour 版同为 `NWConnection`，但**不需要** `NSBonjourServices` / `NSLocalNetworkUsageDescription`：

| 方式 | iOS 需要的权限 |
|------|--------------|
| Bonjour Browse | `NSBonjourServices` + `NSLocalNetworkUsageDescription` |
| **Direct TCP** | **无**（只要 host:port） |

- `RuntimeDirectTCPServerConnection`：`NWListener`，端口传 `0` 则系统自动分配。**关键：`connectionInfo` 返回 `(host, port)`**——ProxyServer 靠它把实际监听端口透出去写进引擎描述符。
- `waitForConnection` 参数：`true` 阻塞到首个 client 连上；`false`（ProxyServer 用）listener `.ready`（拿到端口）即返回，异步 accept。
- `host` 由 `getLocalIPAddress()` 解析局域网 IP。

---

### 3.5 Stdio 连接（`RuntimeStdioConnection.swift`）

**用途**：CLI 工具、Language Server（LSP）等通过管道通信的场景。

```
┌─────────────────┐                    ┌─────────────────┐
│  Parent Process │                    │  Child Process  │
│  outputHandle ──┼──── stdin ───────> │  inputHandle    │
│  inputHandle  <─┼──── stdout ─────── │  outputHandle   │
└─────────────────┘                    └─────────────────┘
```

底层 `RuntimeStdioConnection` 持两个 `FileHandle`（in/out），独立 `readQueue` 读取，同样用 `RuntimeMessageChannel` 组帧。子类 `RuntimeStdioClientConnection`（父进程，读子进程 stdout / 写子进程 stdin）与 `RuntimeStdioServerConnection`（子进程，用标准 `.standardInput`/`.standardOutput`）。

---

## 4. 消息通道与线路协议（`RuntimeMessageChannel.swift` + `RuntimeNetwork.swift`）

除 XPC 外的四族共享 `RuntimeMessageChannel`，负责**组帧、编解码、请求路由、超时**。

### 4.1 线路格式

每条消息是一个 JSON 编码的 `RuntimeRequestData`，以 `\nOK` 结尾定界：
```
{"identifier":"com.example.Request","data":"<base64>","nonce":"..."}\nOK
```

`RuntimeRequestData`（在 `RuntimeNetwork.swift`）字段：
- `identifier`：命令名。
- `data`：内层 payload 的 JSON。
- `nonce`：**每次往返的路由键**。让多个同名并发请求不在 pending 表里撞车——因此 `sendSemaphore` 不必端到端串行化往返。对端处理器必须原样回显 nonce；缺省则回退用 `identifier`（旧版单飞行行为）。
- `isError`：标记响应体装的是 `RuntimeNetworkRequestError` 而非期望的 `Response`，让 `sendRequest` 能把远端失败还原成真正的 error，而不是一个 `DecodingError` 或全 optional 的"假成功"。

### 4.2 关键机制

- **`ReceiveBuffer` + `scannedPrefix`**：跨多次 append 记住已扫描偏移，把分块到达的大消息从 O(n²) 降到 O(n)。
- **`pendingRequests`（Mutex）**：按路由键存 `PendingRequest`（continuation + 超时 Task）。成功/写失败路径会**取消定时器**，避免已完成请求的孤儿定时器误伤后来同名请求。
- **`onMessageReceived`** 回调把完整帧交给分发逻辑：先看是否命中某个 pending（响应），否则查 handler（请求）。
- 处理器注册表 `messageHandlers`、received 流 `SharedAsyncSequence` 均用 `Mutex` 保护，`AsyncSemaphore` 序列化发送。

### 4.3 `RuntimeRequest` / `RuntimeResponse`（`RuntimeRequestResponse.swift`）

- 非 macOS：`RuntimeRequest: Codable & Sendable`，带 `associatedtype Response: RuntimeResponse` 与 `static var identifier`。
- macOS：`RuntimeRequest` **refine** `HelperCommunication.Request`，于是任何 daemon-bound 业务请求能直接挂到 `HelperService` / `HelperPeer` 上。
- 同文件还定义了跨进程共享的 Mach 服务名 `RuntimeViewerMachServiceName`（Debug 下按 arm64e 变体切换）与协议版本 `RuntimeViewerServiceVersion`。

---

# 第二部分：RuntimeEngineManager / ProxyServer 架构

## 5. 三层职责划分

引擎侧有三个协作角色，请先记住它们的分工：

| 角色 | 位置 | 职责 |
|------|------|------|
| **`RuntimeEngine`**（actor） | `RuntimeViewerCore` | 单个运行时的连接 + 数据（imageList / imageNodes / 查询 RPC）。既能当 server 也能当 client。 |
| **`RuntimeEngineProxyServer`**（actor） | `RuntimeViewerCore` | 给**一个** engine 套一层 DirectTCP server，把它转成可被远端直连、镜像的服务。 |
| **`RuntimeEngineManager`**（@MainActor class） | `RuntimeViewerApplication` | 全局单例。发现/生命周期/分组，编排 Sharing（server 侧）与 Mirroring（client 侧）。 |

`RuntimeEngineManager` 通过 `@Dependency(\.runtimeEngineManager)` 注入（遵循项目单例规范，`shared` 为 `fileprivate`）。

---

## 6. 整体架构图

```
                          ┌──────────────────────────────────────────────────┐
                          │              RuntimeEngineManager (@MainActor)     │
                          │                    单例 · 全局编排                  │
                          │                                                    │
   Bonjour 发现            │  @Published systemRuntimeEngines   [local, catalyst]│
  ┌──────────────┐        │  @Published attachedRuntimeEngines [注入的 App]     │
  │ NWBrowser    │───────>│  @Published bonjourRuntimeEngines  [局域网对端]     │
  │(RuntimeNetwork│  端点   │  @Published mirroredEngines        [镜像来的引擎]   │
  │  Browser)    │        │  @Published runtimeEngineSections  [按 host 分组 UI]│
  └──────────────┘        │                                                    │
                          │  ┌────────────────┐    ┌─────────────────────────┐ │
                          │  │ proxyServers    │    │ RuntimeEngineMirror     │ │
                          │  │ [id: ProxyServer]│    │ Registry (纯状态/可测)  │ │
                          │  └───────┬────────┘    └────────────┬────────────┘ │
                          └──────────┼──────────────────────────┼──────────────┘
                                     │ 每个本地引擎一个           │ reconcile 镜像
         ┌───────────────────────────┘                          │
         ▼  Sharing（server 侧）                                  ▼ Mirroring（client 侧）
  ┌─────────────────────┐                              ┌──────────────────────────┐
  │ RuntimeEngineProxy  │   DirectTCP(host:port)       │ 收到 RuntimeRemoteEngine  │
  │ Server (actor)      │ <═══════════════════════════ │ Descriptor → 建 directTCP │
  │  · 包住一个 engine   │      远端 Mac 直连过来          │   client engine 直连回去   │
  │  · 起 DirectTCP srv  │ ═══════════════════════════> │  → 放进 mirroredEngines   │
  │  · 转发 RPC + 推送    │      转发运行时数据/推送         │                          │
  └──────────┬──────────┘                              └──────────────────────────┘
             │ 代理
             ▼
      ┌──────────────┐
      │ RuntimeEngine │  真正持有运行时数据的引擎
      │  (被代理者)   │
      └──────────────┘


        引擎清单在 Bonjour 通道上双向流动：
        ┌──────────────┐   engineList (请求/心跳)    ┌──────────────┐
        │ 本机 Manager  │ ──────────────────────────>│ 对端 Manager  │
        │ (Bonjour       │ <──── engineListChanged ── │ (Bonjour      │
        │  client)       │        (server 主动推送)    │  server)      │
        └──────────────┘                             └──────────────┘
```

---

## 7. `RuntimeEngineManager` 逐部分详解

### 7.1 五个引擎集合

Manager 把所有引擎按来源分成五组 `@Published`，`runtimeEngines` 计算属性是前四组之和：

- **`systemRuntimeEngines`**：`.local`（本机同进程）+ Mac Catalyst client 引擎。启动时 `launchSystemRuntimeEngines()` 建立。
- **`attachedRuntimeEngines`**：注入到别的 App 得到的引擎——非沙盒走 XPC（`.remote`），沙盒走 localSocket。支持从持久化记录**重连已注入进程**（`reconnectInjectedXPCEngines` 读 Mach Service 注册表；`reconnectInjectedSocketEngines` 读本地 JSON 并 `kill(pid,0)` 探活）。
- **`bonjourRuntimeEngines`**：Bonjour 发现的对端。默认作为**管理型连接**（只跑引擎清单交换）在 UI 里隐藏；若对端不支持引擎共享（返回 0 个描述符）则升级为 `directBonjourEngines` 直接展示。
- **`mirroredEngines`**：经由引擎共享协议**镜像**来的远端引擎（`OrderedDictionary<engineID, Engine>`），由 `RuntimeEngineMirrorRegistry` 管理。
- **`runtimeEngineSections`**：面向 UI 的最终产物，按 `hostID` 把引擎聚成分组（`rebuildSections()`）。

### 7.2 Bonjour 发现与连接

`init` 里**先起 Bonjour server 再起 browser**（保证本机 TXT 记录里的 `localInstanceID` 在被发现前已注册），browser 回调中：
- 用 `instanceID == localInstanceID` **过滤自己**。
- `connectToBonjourEndpoint` 建 `.bonjour(role: .client)` 引擎并连接。
- **韧性设计**（`Documentations/Plans/2026-03-03-bonjour-reliability.md` 的落地）：
  - `knownBonjourEndpointNames` 去重 + `pendingReconnectEndpoints` 处理"旧引擎还在拆、同名端点又冒出来"（iOS 后台恢复重广播）。
  - 连接失败指数退避重试（2s/4s/8s，`maxRetryAttempts = 3`）。
  - 连上后 `requestEngineList` 前**预留 2s**让对端的初始 `imageList`（常 >1MB）在 AWDL 通道上排空，避免小 RPC 排在大传输后超时。

### 7.3 心跳（AWDL 假死检测）

AWDL 路由的对端（iOS/visionOS/tvOS）即使进程已死，TCP keepalive 探针仍被主机内核应答，`NWConnection` 永远不 `.disconnected`。为此 `startBonjourHeartbeat` 每 30s 重发 `engineList`，连续 2 次超时（每次 15s 容忍 AWDL 拥塞）就 `stop()` 引擎，走正常断开路径清掉僵尸条目。

### 7.4 状态观测与断开清理

`observeRuntimeEngineState` 订阅每个引擎的 `statePublisher`：
- `.connected` → 通知 `runtimeConnectionNotificationService`。
- `.disconnected` → `cleanupMirroredEnginesOnDisconnect` + `terminateRuntimeEngine`，并且只有当该 host **彻底从 sidebar 消失**（`runtimeEngineSections` 里不再有它）时才发"断开"通知——避免直连 Bonjour 掉线但同一对端仍有转发镜像可见时的自相矛盾提示。

---

## 8. Sharing（server 侧）：把本地引擎变成可镜像的服务

`startSharingEngines()` 装了三样东西：

1. **`RuntimeEngine.engineListProvider`** = `buildEngineDescriptors`：为每个本地引擎（除 Bonjour server 自身、且必须**已有 ProxyServer**）产出一个 `RuntimeRemoteEngineDescriptor`：
   ```
   engineID      = "{hostID}/{localID}"          全局唯一
   directTCPHost = proxy.host                     ← 来自 ProxyServer 的 connectionInfo
   directTCPPort = proxy.port
   originChain   = engine.originChain + [localInstanceID]   ← 追加自己，供环路检测
   iconData      = proxy.iconData()               App 图标 PNG
   ```
2. **`updateProxyServers(for:)`**：订阅 `rx.runtimeEngines`，为每个新引擎起一个 `RuntimeEngineProxyServer`（存入 `proxyServers[id]`），引擎消失则 `stop()` 并移除。Proxy 在 detached task 里 `start()`（不阻塞主 actor），起好后重新 `buildEngineDescriptors` 并通过 Bonjour server 引擎 `pushEngineListChanged` 推给已连的对端。
3. **Bonjour server 引擎连上事件** → 立即推当前引擎清单。

即：**每个本地引擎 → 一个 ProxyServer（DirectTCP 服务） → 一个描述符 → 通过 Bonjour 清单广播出去**。

---

## 9. `RuntimeEngineProxyServer` 逐部分详解

`RuntimeEngineProxyServer` 是一个 actor，把**单个** engine 包装成远端可直连的服务。

### 9.1 启动
```swift
connection = try await communicator.connect(
    to: .directTCP(name: id, host: nil, port: 0, role: .server),
    waitForConnection: false)          // 拿到端口即返回，异步 accept
host = connection.connectionInfo.host  // ← 就是 §3.4 里 DirectTCP server 透出的地址
port = connection.connectionInfo.port
```

### 9.2 客户端连上后（`statePublisher == .connected`）做三件事

1. **`setupRequestHandlers`** —— 调 `RuntimeEngine.registerSharedHandlers(on:engine:)`。这是**与 `RuntimeEngine` 自己 server 臂完全相同的共享命令集**（imageList / loadImage / runtimeObjectsInImage / specialize……）。共享注册表消除了"每加一条命令就要在两处并行改"的隐患。此外 Proxy 独有一条 `iconRequestCommand`，把 App 图标 PNG 发给连上的 client。
2. **`setupPushRelay`** —— 订阅被代理 engine 的 `imageNodesPublisher` 和 `dataChangePublisher`，把变化实时转发给远端 client。**每次 `.connected` 都会先 `pushRelaySubscriptions.removeAll()`** 再重挂，避免重连叠加导致同一变化被发 N 次。
3. **`sendInitialData`** —— 连上瞬间先把当前 `imageList` / `imageNodes` / 一个 `.fullReload` 推过去做首屏。

一句话：**ProxyServer = DirectTCP server + 把远端 RPC 桥到本地 engine + 把本地 engine 的推送转发给远端**。

---

## 10. Mirroring（client 侧）：把远端引擎搬进本地列表

当本机作为 Bonjour client 从对端收到引擎清单（`requestEngineList` 应答，或对端主动 `engineListChanged` 推送），进入 `handleEngineListChanged` → `RuntimeEngineMirrorRegistry.reconcile`。

对每个描述符：**用它的 `directTCPHost:directTCPPort` 建一个 `.directTCP(role: .client)` 引擎，直连回对端的 ProxyServer**，连上后放进 `mirroredEngines`。于是对端的运行时在本机 UI 里就像本地引擎一样可浏览。

### 10.1 `RuntimeEngineMirrorRegistry`（纯状态，可单测）

把原先内联在 Manager 里的字典写操作抽出来，三块状态：
- `engines: [engineID: RuntimeEngine]` —— 镜像实例。
- `ownership: [engineID: 直接上游 hostID]` —— 记录"这条镜像是从哪个直连对端转发来的"。先到先得：两个对端报同一 engineID，第一个占有。
- `lastDescriptorIDsBySource: [hostID: Set<engineID>]` —— 每源去重缓存。

`reconcile` 四步：
1. **环路检测**：丢弃 `originChain` 已含 `localInstanceID` 的描述符（防止 A→B→A 兜圈）。
2. **每源去重**：该源本次 ID 集合与上次相同 → `skippedDuplicate` 整体跳过。
3. **每源 reconcile**：移除"此源先前拥有、本次不再出现"的引擎。
4. **新增**（先到先得，engineID 已存在则跳过）。

### 10.2 断开清理的两种拓扑（`cleanupMirroredEnginesOnDisconnect`）

镜像可以级联（A → B → C）。断开一个直连对端时要同时覆盖两种角色：
- **中间节点断开**（B 在转发别人的引擎给我）：`clearAllOwnedBy(hostID:)` —— 删 `ownership == B` 的全部。
- **叶子节点断开**（C 自己的引擎可能经别的转发者到我，`ownership ≠ C`）：`clearAllWithHostID(hostID:)` —— 删 `engineID` 前缀为 `C/` 的全部。

两者匹配键不相交，并集覆盖所有拓扑；registry 对重叠是幂等的。

### 10.3 分组去重（`deduplicateForwardedMirrors`）

同一台对端我既直连、又收到别人转发的镜像时会出现重名重复条目。`rebuildSections` 后做一步过滤：同一 section 内，若一个镜像的显示名与本机对该 host 的**直连路由**同名，则丢弃镜像（保留直连）。放在分组步骤而非 reconcile 里，是为了让 registry 保留备用路由——直连一断，下一次 `rebuildSections` 镜像立刻补位，无需等上游重推。

---

## 11. 端到端数据流：一次跨 Mac 镜像

以「Mac-A 直连了一台 iPhone，Mac-B 想通过 Mac-A 看到这台 iPhone」为例，串起全部组件：

```
 iPhone ──Bonjour──> Mac-A                         Mac-A ──Bonjour──> Mac-B
 ───────────────────────────                       ─────────────────────────────
 ① Mac-A 的 Manager 发现 iPhone，                    ⑤ Mac-B 的 Manager 发现 Mac-A，
   建 .bonjour client 引擎并连上                        建 .bonjour client 引擎并连上
 ② Manager 为该引擎起 ProxyServer                     ⑥ requestEngineList → 收到 Mac-A
   （DirectTCP server, 拿到 host:port）                  的描述符（含 iPhone 引擎，
 ③ buildEngineDescriptors 产出描述符                     directTCPHost = Mac-A 的 Proxy 地址）
   engineID = "iPhoneHostID/local"                   ⑦ reconcile：环路/去重通过 → 新增
   directTCP = Mac-A_Proxy:port                        ⑧ 用该 host:port 建 .directTCP client
 ④ 通过 Bonjour server 引擎                              引擎，直连回 Mac-A 的 ProxyServer
   pushEngineListChanged 给 Mac-B                     ⑨ ProxyServer 把 RPC 桥到它代理的
                                                         iPhone 引擎；推送实时转发
                                                      ⑩ Mac-B 的 mirroredEngines 里出现
                                                         iPhone，UI 分组展示
```

数据平面（浏览类/成员地址等 RPC、imageNodes/dataChange 推送）全程走 **DirectTCP**（Mac-B ↔ Mac-A 的 Proxy ↔ iPhone 引擎）；控制平面（引擎清单）走 **Bonjour**。descriptor 里的 `originChain` 一路追加各跳的 `localInstanceID`，任何一跳发现自己已在链里就丢弃，杜绝环路。

---

## 12. 速查表

| 我想…… | 看这里 |
|--------|--------|
| 新增一种传输 | 实现 `RuntimeConnection`（或走 `RuntimeForwardingConnection` + `RuntimeUnderlyingConnection`），在 `RuntimeSource` 加 case，在 `RuntimeCommunicator.connect` 加分支 |
| 改线路格式 / 组帧 | `RuntimeMessageChannel.swift` + `RuntimeRequestData`（`RuntimeNetwork.swift`） |
| 加一条业务 RPC 命令 | `RuntimeEngine.CommandNames` + `RuntimeEngine.registerSharedHandlers`（Proxy 自动继承） |
| 调 Bonjour 发现/心跳/重试参数 | `RuntimeEngineManager` 顶部的 static 常量 |
| 理解镜像/断开/去重规则 | `RuntimeEngineMirrorRegistry`（纯逻辑，有单测）+ `Documentations/EngineMirroringWalkthrough.md` |
| 沙盒注入端口/角色反转 | `RuntimeLocalSocketConnection.swift` 顶部文档 + `RuntimeLocalSocketPortDiscovery` |
```

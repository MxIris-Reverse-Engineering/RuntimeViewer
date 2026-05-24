# Helper Service Extraction Implementation Plan

**Goal:** 把 `RuntimeViewerService` daemon 单类 + `RuntimeViewerHelperClient` 三个单例 + `RuntimeViewerCommunication` 内的 daemon 通信 Request 整合进相邻库 `swift-helper-service`,并把该库以薄包装方式集成回 RuntimeViewer。`RuntimeXPCConnection` 保留为 `RuntimeConnection` 协议的 adapter,内部委托给 lib 新的 `HelperPeerClient` / `HelperPeerServer`。

**Architecture:** 详见 design doc。lib 收纳"SMAppService.daemon 安装、broker 注册表、broker peer 反向连+reconnect、版本对账"通用骨架;业务逻辑(`OpenApplication`、`InjectedEndpoint` PID 监控、注入、文件操作)继续留在本仓,实现成 `HelperService` 由 lib `HelperServer` 装配。

**Tech Stack:** SwiftyXPC, SMAppService(macOS 13+), DispatchSource, Swift Concurrency, AsyncStream, Combine(仅 adapter 内桥接), Observation, MachInjector。

**Design spec:** `Documentations/Plans/2026-05-23-helper-service-extraction-design.md`

**Cross-repo scope:**
- `/Volumes/Repositories/Private/Personal/Library/macOS/swift-helper-service`(lib)
- `/Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer`(本仓)
- workspace `../MxIris-Reverse-Engineering.xcworkspace` 已挂 lib 本地路径,SPM 解析时优先 local。

**Execution principle:** 按 Phase 顺序推进;每个 Phase 内部步骤完成后整个工作区可编译,可独立 commit。Phase 0 是 lib 侧准备工作,Phase 1-3 是 RuntimeViewer 侧改造,Phase 4 是 Catalyst helper,Phase 5 是验证。

---

## Phase 0 — lib `swift-helper-service` 端新增能力

> Repo: `/Volumes/Repositories/Private/Personal/Library/macOS/swift-helper-service`. 本 Phase 结束后 `swift build` 通过,新 module `HelperPeer` 编译成功,RuntimeViewer 仍未引用。

### Task 0.1 — `HelperCommunication` access level 提升 + `FetchVersionRequest`

**Files:**
- Modify: `Sources/HelperCommunication/XPCExtensions.swift`
- Create: `Sources/HelperCommunication/FetchVersionRequest.swift`

- [ ] **Step 0.1.1**:把 `sendMessage<Request:>` / `setMessageHandler<Request:>` 两个扩展从 `package func` 改为 `public func`。`Request` 协议本身公开,这两个扩展是配套使用所必须。
- [ ] **Step 0.1.2**:新建 `FetchVersionRequest.swift`,identifier `com.JH.HelperCommunication.FetchVersion`,Response 含 `let version: String`,全部 `public`。
- [ ] **Step 0.1.3**:`swift package update && swift build 2>&1 | xcsift`。

### Task 0.2 — 新建 broker 行为扩展(`XPCConnection+MainService`)

**Files:**
- Create: `Sources/HelperCommunication/XPCConnection+MainService.swift`

- [ ] **Step 0.2.1**:新建文件,在 `extension SwiftyXPC.XPCConnection` 上加 4 个 `public` 方法:`pingHelperTool()`、`registerEndpoint(_:machServiceName:identifier:)`、`fetchEndpoint(machServiceName:identifier:) -> XPCEndpoint`、`listHelperServerInfos() -> [HelperServerInfo]`。方法体内部使用 `package` 的 `FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest` / `HelperServerInfo`,因为同模块所以可访问;public 入口只接受 `String` 二元组,封装 `HelperServerInfo` 构造细节。
- [ ] **Step 0.2.2**:`swift build` 通过。

### Task 0.3 — `HelperServer` / `MainService` 增加 `version` 参数 + handler

**Files:**
- Modify: `Sources/HelperServer/HelperServer.swift`
- Modify: `Sources/HelperServices/MainService/MainService.swift`

- [ ] **Step 0.3.1**:`HelperServer.init` 加 `version: String` 参数,放在 `services:` 之前。把 version 传给 `MainService(version:)`。
- [ ] **Step 0.3.2**:`MainService` 加 `private let version: String`,init 接 version。`setupHandler(_:)` 内追加 `handler.setMessageHandler { (request: FetchVersionRequest) -> FetchVersionRequest.Response in .init(version: version) }`。
- [ ] **Step 0.3.3**:`swift build` 通过。

### Task 0.4 — `HelperClient.fetchToolVersion` + `XPCConnection.Error.indicatesOutdatedPeer`

**Files:**
- Modify: `Sources/HelperClient/HelperClient.swift`
- Create: `Sources/HelperClient/XPCConnectionError+OutdatedPeer.swift`

- [ ] **Step 0.4.1**:`HelperClient` 加 `public func fetchToolVersion() async throws -> String`,委托 `toolConnection?.sendMessage(request: FetchVersionRequest()).version`,无连接时抛 `Error.invalidConnection`。
- [ ] **Step 0.4.2**:新建 `XPCConnectionError+OutdatedPeer.swift`,`extension SwiftyXPC.XPCConnection.Error { public var indicatesOutdatedPeer: Bool }`(只在 `.unexpectedMessage` 时返回 true)。
- [ ] **Step 0.4.3**:`swift build` 通过。

### Task 0.5 — 新建 `SMAppServiceDaemonInstaller` actor

**Files:**
- Create: `Sources/HelperClient/SMAppServiceDaemonInstaller.swift`

- [ ] **Step 0.5.1**:文件级 `@available(macOS 13, *)`,声明 `public actor SMAppServiceDaemonInstaller`。属性:`private let daemon: SMAppService`(由 `SMAppService.daemon(plistName:)` 构造)、`private var continuation: AsyncStream<SMAppService.Status>.Continuation?`。
- [ ] **Step 0.5.2**:`public init(plistName: String)`,内部 `self.daemon = SMAppService.daemon(plistName: plistName)`。
- [ ] **Step 0.5.3**:`public var currentStatus: SMAppService.Status { daemon.status }`。
- [ ] **Step 0.5.4**:`public var statusStream: AsyncStream<SMAppService.Status>`,init 时建一份 `AsyncStream { continuation in ... }` 并 yield 初始 status,后续 register/unregister 完成时显式 yield 新值。
- [ ] **Step 0.5.5**:`public func register() async throws { try daemon.register(); continuation?.yield(daemon.status) }`。
- [ ] **Step 0.5.6**:`public func unregister() async throws { try await daemon.unregister(); continuation?.yield(daemon.status) }`。
- [ ] **Step 0.5.7**:`public func refresh() async { continuation?.yield(daemon.status) }`,允许调用方主动触发刷新(例如响应 NSWorkspace 通知)。
- [ ] **Step 0.5.8**:`public func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }`,nonisolated。
- [ ] **Step 0.5.9**:`HelperClient` 加工厂方法 `public func daemonInstaller(plistName: String) -> SMAppServiceDaemonInstaller`(`@available(macOS 13, *)`)。
- [ ] **Step 0.5.10**:`swift build` 通过。

### Task 0.6 — 新建 `HelperPeer` module 的内置 Request

**Files:**
- Create: `Sources/HelperPeer/PeerHandshakeRequests.swift`
- Modify: `Package.swift`(加 target + product)

- [ ] **Step 0.6.1**:`Package.swift` 加 `.library(name: "HelperPeer", targets: ["HelperPeer"])` 和 `.target(name: "HelperPeer", dependencies: ["HelperCommunication", .product(name: "SwiftyXPC", package: "SwiftyXPC")])`。
- [ ] **Step 0.6.2**:创建 `PeerHandshakeRequests.swift`,`package struct ServerLaunchedNotification` 和 `package struct ClientReconnectedNotification`,均 `Codable, HelperCommunication.Request`,Response = `HelperCommunication.VoidResponse`,各自 identifier `com.JH.HelperPeer.ServerLaunched` / `com.JH.HelperPeer.ClientReconnected`,payload 含 `let endpoint: SwiftyXPC.XPCEndpoint`。
- [ ] **Step 0.6.3**:`swift build --target HelperPeer` 通过。

### Task 0.7 — 新建 `PeerConnection` 协议 + `PeerConnectionState`

**Files:**
- Create: `Sources/HelperPeer/PeerConnectionState.swift`
- Create: `Sources/HelperPeer/PeerConnection.swift`

- [ ] **Step 0.7.1**:`PeerConnectionState.swift` — `public enum PeerConnectionState: Sendable { case connecting, connected, disconnected(any Error), cancelled }`。`Error` 不要求 Sendable 用 `any Error` + 类型擦除。
- [ ] **Step 0.7.2**:`PeerConnection.swift` — 定义 `public protocol PeerConnection: Actor, Sendable` 接口:
  - `var stateStream: AsyncStream<PeerConnectionState> { get }`
  - `var listenerEndpoint: SwiftyXPC.XPCEndpoint { get async }`
  - `@discardableResult func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response`
  - `func setMessageHandler<Request: HelperCommunication.Request>(_ requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) async`
  - `func cancel() async`
- [ ] **Step 0.7.3**:`swift build` 通过。

### Task 0.8 — 实现 `HelperPeerClient` actor

**Files:**
- Create: `Sources/HelperPeer/HelperPeerClient.swift`

设计要点:
- 持有 `listener: SwiftyXPC.XPCListener`(anonymous)、`serviceConnection: SwiftyXPC.XPCConnection`、`peerConnection: SwiftyXPC.XPCConnection?`(可变,reconnect 时替换)、`services: [HelperService]`、`stateContinuation`。
- 初次握手 init:open anonymous listener → 在 listener 上挂 `PingRequest` handler + `ServerLaunchedNotification` handler(收到时建立 `peerConnection`)→ `serviceConnection.pingHelperTool()` → `serviceConnection.registerEndpoint(listener.endpoint, machServiceName:, identifier:)` → 让 services 各自 `setupHandler(self)` → `listener.activate()`。状态 `.connecting`,handler 收到 ServerLaunched 后 ping peer → 设 `.connected`。
- reconnect init:open anonymous listener → 在 listener 上挂 PingRequest handler → 直连 `serverEndpoint` → ping → `peerConnection.sendMessage(request: ClientReconnectedNotification(endpoint: listener.endpoint))` → `listener.activate()` → `.connected`。
- `send<Request:>`:必须有 peer connection;`setMessageHandler<Request:>`:挂到 listener;`cancel`:取消 listener + peerConnection + serviceConnection + stateContinuation.finish + 终止状态 yield `.cancelled`。

- [ ] **Step 0.8.1**:文件框架 + actor 字段 + state stream 构造。
- [ ] **Step 0.8.2**:初次握手 `init(machServiceName:isPrivilegedHelperTool:identifier:services:)`。
- [ ] **Step 0.8.3**:reconnect `init(machServiceName:isPrivilegedHelperTool:identifier:serverEndpoint:services:)`。
- [ ] **Step 0.8.4**:`PeerConnection` 协议方法实现(`send` / `setMessageHandler` / `cancel` / `listenerEndpoint`)。
- [ ] **Step 0.8.5**:`HelperHandler` 适配 — `HelperPeerClient` 内部对 `services` 调 `setupHandler(_:)` 时,传给 service 的 handler 实例需要能挂到 listener。复用 `HelperServer.swift` 中 `extension SwiftyXPC.XPCListener: HelperHandler` 这个 extension(目前 internal),提升为 `package extension` 放到 HelperPeer 也可访问。或者:在 HelperPeer 内复制一份相同的 extension(简单干净,不交叉依赖)。
- [ ] **Step 0.8.6**:`swift build --target HelperPeer` 通过。

### Task 0.9 — 实现 `HelperPeerServer` actor

**Files:**
- Create: `Sources/HelperPeer/HelperPeerServer.swift`

设计要点:
- 持有 `listener` + `serviceConnection` + `peerConnection: SwiftyXPC.XPCConnection?`(可变,被 ClientReconnected 替换)+ `services` + stateContinuation + `identifier: String` + `machServiceName: String`。
- init:open anonymous listener → 挂 PingRequest handler + `ClientReconnectedNotification` handler(收到时替换 peerConnection 并 yield `.connected`)→ services `setupHandler(self)` → `serviceConnection.pingHelperTool()` → `serviceConnection.fetchEndpoint(machServiceName:identifier:)` 拿 host endpoint → 主动 `.remoteServiceFromEndpoint(...)` 连 host → ping → `peerConnection.sendMessage(request: ServerLaunchedNotification(endpoint: listener.endpoint))` → `serviceConnection.registerEndpoint(listener.endpoint, machServiceName:, identifier:)` (供 host 重启 reconnect 直连用) → `listener.activate()` → `.connected`。

- [ ] **Step 0.9.1**:文件框架 + actor 字段。
- [ ] **Step 0.9.2**:`init` 完整流程。
- [ ] **Step 0.9.3**:`PeerConnection` 协议方法实现。
- [ ] **Step 0.9.4**:`swift build --target HelperPeer` 通过。

### Task 0.10 — lib CLAUDE.md 同步更新

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 0.10.1**:更新 "Module layout" 章节,加入 `HelperPeer` 描述(broker peer 反向连+reconnect 信令握手的抽象,业务 RPC 通过 `services: [HelperService]` 挂载)。
- [ ] **Step 0.10.2**:更新 "Conventions" 章节,显式说明 `package` 注册表 Request 通过 `XPCConnection` public 行为扩展(`pingHelperTool` / `registerEndpoint` / `fetchEndpoint` / `listHelperServerInfos`)间接调用,不暴露 Request 类型本身。
- [ ] **Step 0.10.3**:新增 "Versioning" 小节描述 `HelperServer.init(... version:)` 与 `HelperClient.fetchToolVersion()` + `XPCConnection.Error.indicatesOutdatedPeer`。
- [ ] **Step 0.10.4**:新增 "Installation" 小节描述两种安装路径并存 — `installTool(name:)`(SMJobBless,legacy)与 `daemonInstaller(plistName:)`(SMAppService.daemon,macOS 13+)。

### Task 0.11 — 新建 lib `Tests/` target

**Files:**
- Modify: `Package.swift`
- Create: `Tests/HelperCommunicationTests/InProcessBroker.swift`(shared 测试基础设施)

- [ ] **Step 0.11.1**:`Package.swift` 加 `.testTarget(name: "HelperCommunicationTests", dependencies: ["HelperCommunication", .product(name: "SwiftyXPC", package: "SwiftyXPC")])` 与 `.testTarget(name: "HelperPeerTests", dependencies: ["HelperPeer", "HelperCommunication", "HelperCommunicationTests", .product(name: "SwiftyXPC", package: "SwiftyXPC")])`。`HelperPeerTests` 依赖 `HelperCommunicationTests` 以复用 `InProcessBroker`。
- [ ] **Step 0.11.2**:创建 `InProcessBroker.swift`:`final class InProcessBroker` 包装一个 `SwiftyXPC.XPCListener(type: .anonymous)`,内部实现 `MainService` 等价语义(`endpointByInfo: [HelperServerInfo: XPCEndpoint]`,`Ping/FetchEndpoint/RegisterEndpoint/ListServerInfos` 四个 handler)。暴露 `var endpoint: SwiftyXPC.XPCEndpoint` 与 `func shutdown()`。
- [ ] **Step 0.11.3**:`swift test --target HelperCommunicationTests 2>&1 | xcsift`,空 suite 跑通,确认 testTarget 配置正确。

### Task 0.12 — `HelperCommunicationTests` 单元测试

**Files:**
- Create: `Tests/HelperCommunicationTests/CodableTests.swift`
- Create: `Tests/HelperCommunicationTests/OutdatedPeerTests.swift`
- Create: `Tests/HelperCommunicationTests/XPCConnectionExtensionTests.swift`

- [ ] **Step 0.12.1**:`CodableTests.swift` — 用 swift-testing `@Test`,覆盖 `VoidResponse` / `PingRequest` / `FetchVersionRequest`(及其 `Response`)的 `Codable` 往返;断言 `Request.identifier` 字符串以 `com.JH.HelperCommunication.` 起头。
- [ ] **Step 0.12.2**:`OutdatedPeerTests.swift` — 构造各种 `SwiftyXPC.XPCConnection.Error` case,断言只有 `.unexpectedMessage` 时 `indicatesOutdatedPeer == true`,其它 case 全部 false。
- [ ] **Step 0.12.3**:`XPCConnectionExtensionTests.swift` — 启动 `InProcessBroker`,从一个 `XPCConnection(type: .remoteServiceFromEndpoint(broker.endpoint))` 调:
  - `pingHelperTool()` → broker 端收到 PingRequest。
  - `registerEndpoint(_:machServiceName:"x",identifier:"y")` → broker 内 `endpointByInfo[HelperServerInfo(name:"x",identifier:"y")]` 写入。
  - `fetchEndpoint(machServiceName:"x",identifier:"y")` → 返回上一步写入的 endpoint。
  - `listHelperServerInfos()` → 返回包含上面 info 的数组。
- [ ] **Step 0.12.4**:`swift test 2>&1 | xcsift` 全绿。

### Task 0.13 — `HelperPeerTests` 集成测试

**Files:**
- Modify: `Sources/HelperPeer/HelperPeerClient.swift`(加测试用 init,`@_spi(Testing)`)
- Modify: `Sources/HelperPeer/HelperPeerServer.swift`(同上)
- Create: `Tests/HelperPeerTests/HandshakeTests.swift`
- Create: `Tests/HelperPeerTests/ReconnectTests.swift`
- Create: `Tests/HelperPeerTests/BidirectionalRPCTests.swift`
- Create: `Tests/HelperPeerTests/StateStreamTests.swift`

- [ ] **Step 0.13.1**:在 `HelperPeerClient` / `HelperPeerServer` 加 `@_spi(Testing) public init(toolEndpoint: SwiftyXPC.XPCEndpoint, identifier: String, services: [HelperService] = []) async throws`(以及 reconnect 变体)。实现走 `XPCConnection(type: .remoteServiceFromEndpoint(toolEndpoint))` 替代 mach service 连接;其它握手流程一致。
- [ ] **Step 0.13.2**:`HandshakeTests` — `TC-1 初次握手`:起 `InProcessBroker`,起 `HelperPeerServer(toolEndpoint:identifier:services:[FakeService])`,起 `HelperPeerClient(toolEndpoint:identifier:services:[])`,断言双方 state 序列经过 `.connecting → .connected`,client 通过 `send(FakeRequest())` 调用,server `FakeService` handler 收到并返回。
- [ ] **Step 0.13.3**:`ReconnectTests` — `TC-2 reconnect by endpoint`:基于 TC-1 拓展,client `cancel()`,新起 `HelperPeerClient(toolEndpoint:identifier:serverEndpoint:server.listenerEndpoint, services:[])`,断言 server 收到 `ClientReconnectedNotification`、内部 peer connection 替换,业务 RPC 继续可用。
- [ ] **Step 0.13.4**:`BidirectionalRPCTests` — `TC-3`:client 和 server 各挂一个 `HelperService`,互相 `send`,断言双向 RPC 全部成功。
- [ ] **Step 0.13.5**:`StateStreamTests` — `TC-4` `cancel()` 之后 state stream `.cancelled` 然后 finish,后续 `send` 抛错;`TC-5` broker `shutdown()` 后双方 state 转 `.disconnected(_)`(error case 不强断言具体类型,只断言 case 是 `disconnected`)。
- [ ] **Step 0.13.6**:`swift test 2>&1 | xcsift` 全绿。

### Task 0.14 — lib CLAUDE.md 同步更新(原 0.10 续:补 Tests 说明)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 0.14.1**:更新 CLAUDE.md "Build & Test" 章节,把"there are currently no `Tests/` targets" 改为说明 `HelperCommunicationTests` + `HelperPeerTests` 已就位,执行命令 `swift test 2>&1 | xcsift`。
- [ ] **Step 0.14.2**:在 Conventions / 内部 API 章节说明 `@_spi(Testing)` init 仅供 lib 自身 test 使用,不属于 public API。

### Task 0.15 — 提交 lib 改动

- [ ] **Step 0.15.1**:`swift build && swift test 2>&1 | xcsift` 全绿。
- [ ] **Step 0.15.2**:commit 信息:`feat(HelperPeer): add brokered peer connection, daemon installer, version reconcile, tests`。

---

## Phase 1 — `RuntimeViewerCommunication` 协议合并 + adapter 重构

> Repo: 本仓。本 Phase 结束后 `RuntimeViewerCore` + `RuntimeViewerPackages` 全工作区编译通过,业务逻辑暂时仍走 `RuntimeViewerService` 单类 daemon(等 Phase 2 拆),只是 RuntimeXPCConnection 内部已经换成 `HelperPeerClient/Server`。

### Task 1.1 — `RuntimeViewerCore` Package.swift 加 lib 依赖

**Files:**
- Modify: `RuntimeViewerCore/Package.swift`

- [ ] **Step 1.1.1**:沿用 `RuntimeViewerPackages/Package.swift` 中已有的 `Package.Dependency.package(local:remote:)` 工厂(若 RuntimeViewerCore 没有,先复制过来或抽出一个 shared `Common.swift`)。加入 `swift-helper-service` 依赖,local 路径 `MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("swift-helper-service")`,remote 路径暂未发布则 fallback 到本地。
- [ ] **Step 1.1.2**:`RuntimeViewerCommunication` target 的 `dependencies` 加 `.product(name: "HelperCommunication", package: "swift-helper-service")` 与 `.product(name: "HelperPeer", package: "swift-helper-service")`(都用 `.when(platforms: [.macOS, .macCatalyst])`)。
- [ ] **Step 1.1.3**:`swift package update && swift build 2>&1 | xcsift`。

### Task 1.2 — 协议合并 `RuntimeRequest: HelperCommunication.Request`

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeRequestResponse.swift`

- [ ] **Step 1.2.1**:加 `import HelperCommunication`。改 `public protocol RuntimeRequest: HelperCommunication.Request { associatedtype Response: RuntimeResponse }`。
- [ ] **Step 1.2.2**:改 `public protocol RuntimeResponse: Codable, Sendable {}`(加 `Sendable`)。`VoidResponse` 不变,因为 value type 已隐式 `Sendable`。
- [ ] **Step 1.2.3**:`swift build` 通过。预期 `Connection` 系列文件无需修改,Request 系列文件 / Test 文件可能需要少量 `Sendable` 显式标注。

### Task 1.3 — 删除被 lib 覆盖的 4 个 Request 文件

**Files:**
- Delete: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/PingRequest.swift`
- Delete: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/FetchEndpointRequest.swift`
- Delete: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/RegisterEndpointRequest.swift`
- Delete: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/FetchServiceVersionRequest.swift`

- [ ] **Step 1.3.1**:删上述 4 个文件。
- [ ] **Step 1.3.2**:全工作区 grep `RuntimeViewerCommunication.PingRequest|\bPingRequest\b` `\bRegisterEndpointRequest\b` `\bFetchEndpointRequest\b` `\bFetchServiceVersionRequest\b`,替换:
  - `PingRequest` → `HelperCommunication.PingRequest`(在 daemon 链路与 Connection peer 链路两处)
  - `RegisterEndpointRequest(identifier:, endpoint:)` 调用点(在 `RuntimeXPCConnection` 内部)Phase 1.5 改造时会一并删除,这里先保留编译错误也无所谓 — 因为 RuntimeXPCConnection 整文件下一步要重写。
  - `FetchEndpointRequest(identifier:)` 同上。
  - `FetchServiceVersionRequest()` 在 `HelperServiceManager.checkServiceVersionAndReinstallIfNeeded` 内,改 `HelperCommunication.FetchVersionRequest()` 并取 `.version`。Response 类型相应改名。
- [ ] **Step 1.3.3**:删 `RuntimeViewerCommunicationTests/RequestTests.swift` 中针对这 4 个 Request 的测试用例,或改为针对 lib 等价物。

### Task 1.4 — 删除 RuntimeViewerCommunication 自带 SwiftyXPC extension

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeXPCConnection.swift`(L379-392)

- [ ] **Step 1.4.1**:删 `extension SwiftyXPC.XPCConnection.sendMessage<Request: RuntimeRequest>(request:)` 和 `extension SwiftyXPC.XPCListener.setMessageHandler<Request: RuntimeRequest>(requestType:handler:)`。lib 已提为 public,且 `RuntimeRequest: HelperCommunication.Request`,自动兼容。
- [ ] **Step 1.4.2**:`swift build` 此时会因 RuntimeXPCConnection L102 / L124 / L270 / L308 / L343 / L352 / L370 各处引用已删除的 `PingRequest`/`RegisterEndpointRequest`/`FetchEndpointRequest` 而报错。继续 Task 1.5 一并修。

### Task 1.5 — `RuntimeXPCConnection` 重写为 HelperPeer adapter

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeXPCConnection.swift`

设计要点:
- `RuntimeXPCConnection`(base)字段简化为:`let identifier: RuntimeSource.Identifier`、`let peer: any PeerConnection`、`let stateSubject: CurrentValueSubject<RuntimeConnectionState, Never>`、`let stateBridgeTask: Task<Void, Never>`。删 `listener` / `serviceConnection` / `connection` 三件 raw SwiftyXPC 字段。
- init 注入 `peer`;构造 stateBridgeTask:`for await state in peer.stateStream { stateSubject.send(mapped) }`。
- `RuntimeConnectionState` 映射:`.connecting → .connecting`、`.connected → .connected`、`.disconnected(err) → .disconnected(error: .xpcError(err.localizedDescription))`、`.cancelled → .disconnected(error: nil)`。
- `sendMessage<Request: RuntimeRequest>(request:)` 转发 `peer.send(request)`。
- `setMessageHandler<Request: RuntimeRequest>(requestType:handler:)` 转发 `await peer.setMessageHandler(requestType, handler: handler)`。
- `stop()` 转发 `await peer.cancel(); stateBridgeTask.cancel()`。
- untyped `sendMessage(name:)` / `setMessageHandler(name:)` 几个重载:先 grep 实际 callers,确认能否全部去掉。若有少量保留需求(如 `serverLaunched` / `clientConnected` / `clientReconnected` 之类信令),由于这部分握手已由 lib `HelperPeer*` 接管,**`CommandIdentifiers` 枚举可以全部删除**;若是业务 RPC,需在该 PR 内补 RuntimeRequest 包装。

- [ ] **Step 1.5.1**:`rg -n 'RuntimeXPCConnection.*sendMessage\(name:'`、`rg -n 'CommandIdentifiers\.'`、`rg -n 'setMessageHandler\(name:'` — 在本仓全部 callers 排查,产出文件级 caller 清单(写入下一个 sub-step 的 description)。
- [ ] **Step 1.5.2**:根据 caller 清单决定 untyped 接口的处理方式(删除 / 保留 / 类型化包装)。
- [ ] **Step 1.5.3**:重写 `RuntimeXPCConnection` base class 与两个子类 `RuntimeXPCClientConnection` / `RuntimeXPCServerConnection`,init 内部分别构造 `HelperPeerClient`(两个 init,对应初次握手与已知 endpoint reconnect)与 `HelperPeerServer`。
- [ ] **Step 1.5.4**:删除 `CommandIdentifiers` 枚举(若 1.5.2 确认无残留 caller)。
- [ ] **Step 1.5.5**:`XPCListenerEndpointProviding` 协议保留:`var xpcListenerEndpoint: SwiftyXPC.XPCEndpoint { get }`,实现改为 async wrapper(用 `Task { await peer.listenerEndpoint }` 同步阻塞拿一次,或者改协议为 async — 倾向改协议;具体决策在 Step 实施时按 caller 改动量评估)。
- [ ] **Step 1.5.6**:`swift build` 通过。

### Task 1.6 — `Requests/InjectedEndpointInfo.swift` 等业务 Request 验证不动

**Files:**
- Verify only: `RuntimeViewerCore/Sources/RuntimeViewerCommunication/Requests/InjectedEndpointInfo.swift`、`RegisterInjectedEndpointRequest.swift`、`FetchAllInjectedEndpointsRequest.swift`、`RemoveInjectedEndpointRequest.swift`、`OpenApplicationRequest.swift`、`InjectApplicationRequest.swift`、`FileOperationRequest.swift`

- [ ] **Step 1.6.1**:无需修改。验证:这些 Request 仍 `: Codable, RuntimeRequest`,且因 `RuntimeRequest: HelperCommunication.Request`,daemon 端 lib HelperService 可以挂 handler;Response 内嵌类型(如 `FetchAllInjectedEndpointsRequest.Response`)若仍 `: RuntimeResponse`,则继承链:`RuntimeResponse: Codable, Sendable`,满足 `HelperCommunication.Request.Response: Codable & Sendable`。`swift build` 通过即视为验证完成。

### Task 1.7 — 调整 `RuntimeViewerCommunicationTests`

**Files:**
- Modify: `RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/RequestTests.swift`
- Create: `RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/RuntimeRequestProtocolMergeTests.swift`

- [ ] **Step 1.7.1**:`RequestTests.swift` 删除针对已淘汰 Request 的测试组:`PingRequest` / `FetchEndpointRequest` / `RegisterEndpointRequest` / `FetchServiceVersionRequest`。保留 6 个业务 Request 的 `Codable` 往返断言不动:`OpenApplicationRequest` / `InjectApplicationRequest` / `FileOperationRequest` / `RegisterInjectedEndpointRequest` / `FetchAllInjectedEndpointsRequest` / `RemoveInjectedEndpointRequest`。
- [ ] **Step 1.7.2**:`RuntimeRequestProtocolMergeTests.swift` 新建,验证协议合并兼容性:
  - `@Test func runtimeRequestSatisfiesHelperCommunicationRequest()`:通过赋值 `let _: any HelperCommunication.Request = OpenApplicationRequest(url: URL(fileURLWithPath: "/"), callerPID: 0)` 等编译期断言,证实任意 `RuntimeRequest` 子类型自动满足 `HelperCommunication.Request`。
  - `@Test func voidResponseSatisfiesBothProtocols()`:断言 `VoidResponse()` 同时是 `RuntimeResponse` 与 `Codable & Sendable`,可作 `HelperCommunication.Request.Response`。
  - `@Test func runtimeRequestIdentifierNamespaceStable()`:断言 `OpenApplicationRequest.identifier == "com.JH.RuntimeViewerService.OpenApplicationRequest"` 等 6 个业务 Request 的 identifier 字符串不变(防止意外改动)。
- [ ] **Step 1.7.3**:`RuntimeStdioConnectionTests.swift` 已有的 `EchoRequest` / `EchoResponse` / `AddRequest` / `AddResponse` 是测试内部 RuntimeRequest 子类型,验证 Connection 链路上 `RuntimeRequest: HelperCommunication.Request` 协议合并不破坏现有用法:确保该测试文件在协议合并后仍编译通过、`@Test` 全部通过,必要时把 `EchoResponse` / `AddResponse` 加 `Sendable`(因 `RuntimeResponse: Codable, Sendable` 收紧)。
- [ ] **Step 1.7.4**:`xcodebuild test -workspace ../MxIris-Reverse-Engineering.xcworkspace -scheme "RuntimeViewer macOS" -only-testing:RuntimeViewerCommunicationTests 2>&1 | xcsift` 全绿(或 `swift test 2>&1 | xcsift` 在 `RuntimeViewerCore` 仓内跑)。

### Task 1.8 — Commit Phase 1 改动

- [ ] **Step 1.8.1**:`xcodebuild -workspace ../MxIris-Reverse-Engineering.xcworkspace -scheme "RuntimeViewer macOS" -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | xcsift` 全绿。
- [ ] **Step 1.8.2**:commit 信息:`refactor(communication): adopt swift-helper-service Request and HelperPeer abstractions`。

---

## Phase 2 — daemon target `RuntimeViewerService` 拆 service + 改 `main.swift`

> 本 Phase 结束后 daemon 二进制由 `HelperServer + [services]` 装配,功能不变。`RuntimeViewerServiceVersion` bump 到 `"1.1.0"` 以触发现网自动重装。

### Task 2.1 — `RuntimeViewerPackages` 加 lib 依赖

**Files:**
- Modify: `RuntimeViewerPackages/Package.swift`

- [ ] **Step 2.1.1**:`dependencies:` 加 `swift-helper-service` local + remote(沿用 `MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath`)。
- [ ] **Step 2.1.2**:`RuntimeViewerService` target dependencies 加 `.product(name: "HelperServer", package: "swift-helper-service")` + `.product(name: "HelperService", package: "swift-helper-service")` + `.product(name: "HelperCommunication", package: "swift-helper-service")`。
- [ ] **Step 2.1.3**:`RuntimeViewerHelperClient` target dependencies 加 `.product(name: "HelperClient", package: "swift-helper-service")` + `.product(name: "HelperCommunication", package: "swift-helper-service")`。
- [ ] **Step 2.1.4**:`swift package update` + 工作区编译验证。

### Task 2.2 — 拆出 `ApplicationsService`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerService/ApplicationsService.swift`

- [ ] **Step 2.2.1**:文件级 `#if os(macOS)`;`@Loggable public actor ApplicationsService: HelperCommunication.HelperService`。
- [ ] **Step 2.2.2**:`private var launchedApplicationsByCallerPID: [pid_t: [NSRunningApplication]] = [:]`;`private var workspaceMonitor: Task<Void, Never>?`。
- [ ] **Step 2.2.3**:`public init()` + `public func setupHandler(_ handler: some HelperHandler) async`,在 setupHandler 内挂 `OpenApplicationRequest` handler(原 RuntimeViewerService.openApplication 实现)。
- [ ] **Step 2.2.4**:`public func run() async throws`,启动 `workspaceMonitor` Task,监听 `NSWorkspace.didTerminateApplicationNotification`,caller PID 退出时终止其拉起的子 app(原 RuntimeViewerService.main 内 for-await 块的实现)。
- [ ] **Step 2.2.5**:`swift build` 通过。

### Task 2.3 — 拆出 `InjectedEndpointRegistryService`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerService/InjectedEndpointRegistryService.swift`

- [ ] **Step 2.3.1**:`@Loggable public actor InjectedEndpointRegistryService: HelperCommunication.HelperService`。
- [ ] **Step 2.3.2**:字段 `private var injectedEndpointsByPID: [pid_t: InjectedEndpointInfo] = [:]`、`private var processMonitorSources: [pid_t: any DispatchSourceProcess] = [:]`。
- [ ] **Step 2.3.3**:setupHandler 挂 `RegisterInjectedEndpointRequest` / `FetchAllInjectedEndpointsRequest` / `RemoveInjectedEndpointRequest` 三个 handler(原 RuntimeViewerService 的对应实现搬过来,逻辑不变,只是改成 actor 隔离)。
- [ ] **Step 2.3.4**:`startMonitoringProcess(pid:)` / `removeInjectedEndpointEntry(pid:)` 私有方法。
- [ ] **Step 2.3.5**:`swift build` 通过。

### Task 2.4 — 拆出 `InjectionService`(本仓版)与 `FilesService`(本仓版)

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerService/InjectionService.swift`
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerService/FilesService.swift`

- [ ] **Step 2.4.1**:`InjectionService` actor — setupHandler 挂 `InjectApplicationRequest`(identifier 仍是 `com.JH.RuntimeViewerService.InjectApplication`),内部 `try await MainActor.run { try MachInjector.inject(pid:dylibPath:) }`。
- [ ] **Step 2.4.2**:`FilesService` actor — setupHandler 挂 `FileOperationRequest`(identifier 仍是 `com.JH.RuntimeViewerService.FileOperationRequest`),switch 各操作分支。
- [ ] **Step 2.4.3**:`swift build` 通过。

### Task 2.5 — 删除原 `RuntimeViewerService.swift` 单类

**Files:**
- Delete: `RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift`

- [ ] **Step 2.5.1**:删文件。`swift build` 通过(因为已经被 4 个 service 取代,daemon main.swift 在下个 step 改写)。

### Task 2.6 — 改写 daemon `main.swift`

**Files:**
- Modify: `RuntimeViewerUsingAppKit/com.mxiris.runtimeviewer.service/main.swift`
- Modify: `RuntimeViewerUsingAppKit/com.JH.RuntimeViewerService/main.swift`

- [ ] **Step 2.6.1**:两份 main.swift 改为 `@main struct ... { static func main() async throws { ... } }` 形式,内部用 `HelperServer(serverType: .machService(name: RuntimeViewerMachServiceName), version: RuntimeViewerServiceVersion, services: [ApplicationsService(), InjectedEndpointRegistryService(), InjectionService(), FilesService()])` + `await server.activate()` + `await ApplicationsService.run()`(把 workspace 监听放进 service.run,daemon 在 `RunLoop.current.run()` 之前 await 所有 service.run)。
- [ ] **Step 2.6.2**:bump `RuntimeViewerServiceVersion` 从 `"1.0.0"` → `"1.1.0"`(在 `RuntimeViewerCore/Sources/RuntimeViewerCommunication/RuntimeRequestResponse.swift`)。
- [ ] **Step 2.6.3**:Xcode project 验证两个 service main.swift 都编译进对应 binary;若有未自动收录的新文件,通过 `xcodeproj` MCP 加 reference。
- [ ] **Step 2.6.4**:`xcodebuild build -scheme RuntimeViewerUsingAppKit ...`(workspace 上下文)通过。

### Task 2.7 — Commit Phase 2

- [ ] **Step 2.7.1**:`xcodebuild -workspace ... -scheme "RuntimeViewer macOS" ... build` 全绿。
- [ ] **Step 2.7.2**:commit 信息:`refactor(daemon): split RuntimeViewerService into HelperService actors and use HelperServer`。

---

## Phase 3 — `RuntimeViewerHelperClient` 单例瘦身

> 本 Phase 结束后 client target 委托 lib `HelperClient` + `SMAppServiceDaemonInstaller` 完成所有 daemon 通信与安装。Observable 状态壳保留,业务接口不变。

### Task 3.1 — `HelperServiceManager` 改造

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/HelperServiceManager.swift`

- [ ] **Step 3.1.1**:加 `import HelperClient`,持有 `private let helperClient = HelperClient()` 与 `private let installer = SMAppServiceDaemonInstaller(plistName: <DEBUG/RELEASE plist>)`(@available 包裹)。
- [ ] **Step 3.1.2**:删 `connectionLock: Synchronization.Mutex<XPCConnection?>` 与 `connectionIfNeeded()`。
- [ ] **Step 3.1.3**:`reconnect` / `invalidateConnection` 委托 helperClient 内部连接管理(若 helperClient 需要重新 `connectToTool`,在这里调)。
- [ ] **Step 3.1.4**:`manageHelperService(action:)` 委托 `installer.register()` / `installer.unregister()` / `installer.currentStatus`。`status: SMAppService.Status` 仍由本类 `@Observable` 状态,在每次 action 后 `await installer.currentStatus` 更新。
- [ ] **Step 3.1.5**:`checkServiceVersionAndReinstallIfNeeded()` 改用 `helperClient.fetchToolVersion()`。`errorIndicatesOutdatedBinary(_:)` 改为 `(error as? SwiftyXPC.XPCConnection.Error)?.indicatesOutdatedPeer ?? false`(lib 提供的统一判定)。
- [ ] **Step 3.1.6**:`performFileOperation(_:)` 改为 `try await helperClient.sendToTool(request: FileOperationRequest(operation: operation))`。
- [ ] **Step 3.1.7**:`uninstallLegacyService()` 保留,删 plist 那步改 `helperClient.sendToTool(request: FileOperationRequest(operation: .remove(url: Self.legacyPlistFileURL)))`。
- [ ] **Step 3.1.8**:`refreshAllStatus()` / `checkLegacyServiceStatus()` 保留,文案更新逻辑保留。`@Dependency` 入口保留。
- [ ] **Step 3.1.9**:`swift build` 通过。

### Task 3.2 — `RuntimeHelperClient` / `RuntimeInjectClient` 改薄包装

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/RuntimeHelperClient.swift`
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/RuntimeInjectClient.swift`

- [ ] **Step 3.2.1**:`RuntimeHelperClient` 删 `connectionLock` 与 `connectionIfNeeded`,通过 `helperServiceManager` 暴露的 lib `HelperClient`(或独立持有一个 HelperClient)调 `sendToTool`。`launchMacCatalystHelper()` → `try await helperClient.sendToTool(request: OpenApplicationRequest(url:, callerPID:))`。
- [ ] **Step 3.2.2**:`observeStatusChange()` 行为保留(订阅 `helperServiceManager.status`)。
- [ ] **Step 3.2.3**:`RuntimeInjectClient` 同上瘦身。`injectApplication` / `installServerFramework` / 三个 InjectedEndpoint CRUD 各改成 `helperClient.sendToTool(request: ...)`。
- [ ] **Step 3.2.4**:`@Dependency` 注入入口与外部 caller 接口签名保持不变。
- [ ] **Step 3.2.5**:`swift build` 通过。

### Task 3.3 — Commit Phase 3

- [ ] **Step 3.3.1**:`xcodebuild ... build` 全绿。
- [ ] **Step 3.3.2**:commit 信息:`refactor(helper-client): delegate daemon install + comms to swift-helper-service HelperClient`。

---

## Phase 4 — Catalyst helper 改造

> 检查 `RuntimeViewerCatalystHelper.app` 的 broker 注册代码,改用 `HelperServer(serverType: .plain(...))`。

### Task 4.1 — caller 调研

- [ ] **Step 4.1.1**:`rg -n 'RegisterEndpointRequest|FetchEndpointRequest|listener.endpoint' RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelperPlugin RuntimeViewerPackages/Sources/RuntimeViewerCatalystExtensions`。
- [ ] **Step 4.1.2**:阅读现有 Catalyst helper 启动流程,确认它如何向 daemon 注册自己 endpoint、host app 又如何通过 broker 拿到它的 endpoint。产出 caller 文件清单与最小改动方案(填入下一个 sub-step)。

### Task 4.2 — 改造 Catalyst helper

**Files:** TBD by 4.1.2

- [ ] **Step 4.2.1**:用 `HelperServer(serverType: .plain(name: RuntimeViewerMachServiceName, identifier: "catalyst-helper"), version: RuntimeViewerServiceVersion, services: [<Catalyst helper 业务 service>])` + `await server.connectToTool(machServiceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true)` + `await server.activate()` 替代原 broker 注册代码。
- [ ] **Step 4.2.2**:host app 通过 `helperClient.availableServerInfos()` 找到 `HelperServerInfo(name: RuntimeViewerMachServiceName, identifier: "catalyst-helper")` → `helperClient.connectToServer(info:)`,拿到 SwiftyXPC.XPCConnection 后业务调用(若已有上层封装,保持封装入口)。
- [ ] **Step 4.2.3**:Xcode build Catalyst helper target + 主 app target,确认 mach service identifier、entitlements、code signing requirement 与 lib 工作正常。

### Task 4.3 — Commit Phase 4

- [ ] **Step 4.3.1**:`xcodebuild -workspace ... -scheme "RuntimeViewer macOS" ... build` + Catalyst helper scheme 单独 build 全绿。
- [ ] **Step 4.3.2**:commit 信息:`refactor(catalyst-helper): use HelperServer .plain for broker registration`。

---

## Phase 5 — 手工 smoke test 验收

> 代码改动结束。本 Phase 不写代码,在真机/虚机上跑核心流程,确认行为不退化。

### Task 5.1 — daemon 自动重装

- [ ] **Step 5.1.1**:卸载本地 daemon → Debug 启动主 app → `HelperServiceManager.status` 变 `.notRegistered` → 用户点击 install → 系统设置授权 → status `.enabled` → daemon `MainService.fetchToolVersion` 返回 `1.1.0`,version check 通过。
- [ ] **Step 5.1.2**:把 `RuntimeViewerServiceVersion` 临时改成 `"1.1.1"`,重建主 app,启动:`fetchToolVersion` 返回 `1.1.0` ≠ 期望,自动 unregister + register。两次 status 切换都被 Observable 捕获到 UI(`Settings > Helper Service` 页),用户被提示重启 app。

### Task 5.2 — Catalyst helper broker

- [ ] **Step 5.2.1**:主 app 触发"打开 catalyst 源" → daemon `ApplicationsService.openApplication` 启动 catalyst helper → catalyst helper `HelperServer(.plain).connectToTool` 完成,register 自己 endpoint → 主 app `helperClient.availableServerInfos()` 列出 catalyst helper info → `connectToServer(info:)` → 业务通信 OK。

### Task 5.3 — 注入与 inject endpoint 注册表

- [ ] **Step 5.3.1**:主 app 通过 helper 注入到目标 app → 目标 app 内 `RuntimeXPCServerConnection`(adapter)启动 `HelperPeerServer` → broker handshake 完成 → 目标 app `InjectClient.registerInjectedEndpoint(pid:, appName:, bundleIdentifier:, endpoint:)` 写入 daemon `InjectedEndpointRegistryService`。
- [ ] **Step 5.3.2**:重启主 app → `fetchAllInjectedEndpoints` 返回上次注入的 endpoint → host 用 `HelperPeerClient(serverEndpoint:)` 直接 reconnect → 目标 app 收 `ClientReconnectedNotification` 替换 peer connection → state 变 `.connected` → 业务通信 OK。

### Task 5.4 — 文件操作 / framework 安装

- [ ] **Step 5.4.1**:`RuntimeInjectClient.installServerFramework()` 复制 RuntimeViewerServer.framework 到 `/Library/Frameworks/` → 文件存在,签名通过。
- [ ] **Step 5.4.2**:`HelperServiceManager.uninstallLegacyService()` 在有 legacy plist 时正确移除。

### Task 5.5 — 退化场景与 fallback

- [ ] **Step 5.5.1**:断网/无 daemon 场景:`HelperServiceManager.checkServiceVersionAndReinstallIfNeeded()` 返回 `.versionQueryFailed(_)`,不触发 unregister(transient error 容忍)。
- [ ] **Step 5.5.2**:杀掉 daemon 进程 → host 下次发请求 → lib `HelperClient` errorHandler 触发 → `HelperServiceManager.reconnect()` 重建连接 → 状态恢复。

---

## 跨 repo 提交顺序与发布策略

1. **lib(Phase 0)**先 commit 到 `swift-helper-service` main 分支,**不 tag 不发版**。RuntimeViewer 本地 workspace 通过相对路径直接吃到改动。
2. **本仓(Phase 1-4)**在一个 branch(建议 `refactor/extract-helper-service`)上依次推进,每个 Phase 一个 commit。Phase 完成后可以 push 到 fork 触发 ultrareview / CI。
3. **冒烟测试通过(Phase 5)**后再决定:
   - 是否在 `swift-helper-service` 打 tag(例如 `v0.2.0`),并把 RuntimeViewer `Package.swift` 的 remote fallback 版本号同步到该 tag。
   - 是否合 RuntimeViewer branch 到 `main`。

## Plan 内未决细节

下列项在 Plan 标注但具体决策延后到对应 Step 实施时再敲定:

- **Task 0.8 Step 5**:`HelperPeer` 内 `XPCListener: HelperHandler` extension 是新建一份还是把 lib `HelperServer.swift` 内的 internal extension 提为 `package`。两种都可行,实施时选简单的。
- **Task 1.5 Step 5**:`XPCListenerEndpointProviding.xpcListenerEndpoint` 协议是否改为 async getter。看本仓 caller 数量决定。
- **Task 1.5 Step 2**:untyped `sendMessage(name:)` callers 实际数量。grep 结果可能让 1.5.4 的 "删除 CommandIdentifiers" 决策有变。
- **Task 2.6**:daemon 二进制有两个(debug `com.JH.RuntimeViewerService` 与 release `com.mxiris.runtimeviewer.service`)。两份 main.swift 是否完全相同;若不同需要保留差异。

## Phase 完成度自检清单

- [ ] Phase 0 完成:lib `swift build && swift test 2>&1 | xcsift` 全绿(含 `HelperCommunicationTests` + `HelperPeerTests`),`HelperPeer` module 可用,RuntimeViewer 未被触动。
- [ ] Phase 1 完成:工作区编译通过,`RuntimeRequest: HelperCommunication.Request` 协议合并落地,`RuntimeXPCConnection` adapter 内部跑 HelperPeer,`RuntimeViewerCommunicationTests`(含新增 `RuntimeRequestProtocolMergeTests`)全绿。`RuntimeViewerService.swift` 单类此时仍存在(还未触动 daemon),但 Communication 这边已经能和 lib 协议互通。
- [ ] Phase 2 完成:daemon 二进制由 HelperServer + services 装配,版本号 1.1.0,功能等价。工作区构建全绿。
- [ ] Phase 3 完成:client 单例瘦身,SMAppService.daemon 安装走 lib,版本对账走 lib。工作区构建全绿。
- [ ] Phase 4 完成:Catalyst helper 走 lib HelperServer(.plain)。工作区构建全绿。
- [ ] Phase 5 完成:手测全部场景通过(daemon 重装 / Catalyst helper broker / 注入 + reconnect / 文件操作 + framework 安装 / 退化场景 fallback),可发版/合并。

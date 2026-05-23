# Helper Service Extraction Design

## 背景

`RuntimeViewerPackages` 当前有三个紧密相关的 target,共同负责"特权 helper 守护进程 + 客户端 XPC 通信"这条链路:

| Target | 角色 | 主要内容 |
|---|---|---|
| `RuntimeViewerService` | daemon 端库,被 `RuntimeViewerService` 可执行二进制(`com.mxiris.runtimeviewer.service`)直接 `main()` | 单一 `final class RuntimeViewerService` 在一个 mach service listener 上挂 10 个 handler — broker、注入、文件操作、版本上报、被注入端点注册表 + PID 监控、NSWorkspace 进程终止跟踪 |
| `RuntimeViewerHelperClient` | host app 端库 | 三个 `@unchecked Sendable` 单例:`HelperServiceManager`(SMAppService.daemon 安装/卸载/状态/版本对账/legacy plist 清理,`@MainActor @Observable`)、`RuntimeHelperClient`(包 `OpenApplicationRequest`)、`RuntimeInjectClient`(包注入 + framework 安装 + 被注入端点注册表 CRUD) |
| `RuntimeViewerServiceHelper` | host app 端 ObjC 桥 | `RVLegacyHelperTool.m`,只调用 `SMJobRemove` 卸载老 plist |

与此同时,本仓外存在一个相邻库 `/Volumes/Repositories/Private/Personal/Library/macOS/swift-helper-service`,定位是"基于 `SwiftyXPC` 的特权 helper + 类型化 XPC 框架",已经实现了:

- `HelperCommunication`:`Request<Response>` 协议、`VoidResponse`、`PingRequest`、`HelperServerInfo`、内部注册表 Request(`FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest`,`package` 可见性);
- `HelperService` / `HelperHandler` / `HelperServerType`:可插拔服务协议;
- `HelperServer`(actor):自动 prepend 一个内置 `MainService` 作为 endpoint registry,支持 `.machService(name)` 和 `.plain(name, identifier)` 两种监听模式,`.plain` 时会反向连接 tool 注册自身 endpoint;
- `HelperClient`(actor):基于 `SMJobBless` 安装 helper tool、维护 tool 连接与 per-server 连接、`sendToTool/sendToServer` 类型化收发;
- 已落地两个 service(均按 `Interface` / `Implementation` 拆分):`InjectionService`(MachInjector 包装)与 `FilesService`(FileManager 包装)。

两边大量概念是同构甚至完全重复的:`RuntimeRequest` ↔ `Request`、自定义 `VoidResponse` ↔ lib `VoidResponse`、`endpointByIdentifier` ↔ `MainService` 注册表、`HelperServiceManager` 的连接生命周期 ↔ `HelperClient` 的连接生命周期、`RegisterEndpointRequest`/`FetchEndpointRequest` 一对一等价。本设计的目标是**把这部分通用骨架收纳到 lib,把 RuntimeViewer 业务专属的部分留在本仓**,并通过两个新的 lib API 把"应用 ↔ 被注入 app"这条 broker peer 通信链也升格成 lib 提供的标准能力,使 RuntimeViewer 不再重复维护两套等价的 XPC 抽象。

## 设计目标

1. **lib 收纳通用骨架**:SMAppService.daemon 安装方式、helper 版本对账协议、broker peer 反向连接 + reconnect 信令握手,这些是任何特权 helper + 跨进程业务通信场景都会用到的。
2. **业务专属逻辑留在本仓**:`OpenApplication` + NSWorkspace 进程终止跟踪、被注入端点 PID 监控注册表、legacy plist `SMJobRemove` 等仅 RuntimeViewer 有的需求继续放在本仓内。
3. **业务 Request identifier 保留 `com.JH.RuntimeViewerService.*` 命名空间**,避免引入"为了走 lib 改 identifier"的多余兼容性负担(daemon 二进制本身因为重构必须重装,这部分代价无可避免)。
4. **保留 `RuntimeXPCConnection` 作为 `RuntimeConnection` 协议的薄 adapter**,内部委托给 lib 新的 `BrokeredPeerClient` / `BrokeredPeerServer`。上层(`RuntimeEngine` / `RuntimeCommunicator`)对 connection 的使用方式不变。
5. **lib 不对外暴露不必要的内部 Request 类型**(`FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest` / `MainService` / `HelperTool` 维持 `package`),改为通过 public 行为方法间接调用。
6. **lib 不与任何 UI 框架绑定**:状态发布使用 `AsyncStream`,不引入 `Combine` / `Observation` 依赖。RuntimeViewer 在 adapter 内部把 stream 桥接到 Combine。

## 范围

**In scope**

- lib 新增 `HelperPeer` module + `SMAppServiceDaemonInstaller` + `FetchVersionRequest` + 4 个 broker 行为扩展 + `package → public` 提升。
- RuntimeViewerCommunication 把 `RuntimeRequest` 合并到 lib `Request` 之下;删除被 lib 覆盖的 4 个 Request 文件;`RuntimeXPCConnection.swift` 改为 BrokeredPeer 的 adapter。
- `RuntimeViewerService` target:拆解单一 final class 为多个 `HelperService` 实现 + 改写 daemon `main.swift`。
- `RuntimeViewerHelperClient` target:`HelperServiceManager` 委托 lib 安装/版本对账,`RuntimeHelperClient`/`RuntimeInjectClient` 降级为薄包装,删自管连接锁。
- `RuntimeViewerCatalystHelper` 内 broker 注册代码改用 `HelperServer(serverType: .plain(...))`。
- `RuntimeViewerCore/Package.swift` 与 `RuntimeViewerPackages/Package.swift` 增补 `swift-helper-service` 依赖。

**Out of scope**

- 其它 `Connection` 实现(`RuntimeNetworkConnection` / `RuntimeLocalSocketConnection` / `RuntimeStdioConnection` / `RuntimeDirectTCPConnection`)— 它们不走 daemon broker,不在搬迁范围内,本次只确认 `RuntimeRequest` 协议合并不会破坏它们。
- `RuntimeConnection` 协议是否抽进 lib —— 不抽,lib 只覆盖 XPC peer 这一条路径。
- 重新设计 daemon 与 host app 之间的协议;identifier 策略保持现状。

## 现状梳理

### 两边架构对照

```
swift-helper-service (lib)              RuntimeViewer (本仓)
─────────────────────────────           ──────────────────────────────
HelperCommunication                     RuntimeViewerCommunication
  Request<Response>            ←→         RuntimeRequest
  VoidResponse                 ←→         VoidResponse
  PingRequest                  ←→         PingRequest (Requests/)
  FetchEndpointRequest (pkg)   ←→         FetchEndpointRequest (Requests/)
  RegisterEndpointRequest(pkg) ←→         RegisterEndpointRequest (Requests/)
  HelperServerInfo                        (单 String identifier)
  XPCExtensions (sendMessage,
    setMessageHandler — pkg)

HelperService                           (无对应抽象)
  HelperService protocol
  HelperHandler protocol
  HelperServerType enum

HelperServer (actor)                    RuntimeViewerService (final class)
  自动 prepend MainService                  endpointByIdentifier
  支持 .plain + connectToTool                injectedEndpointsByPID
  注册 endpoint                              processMonitorSources
                                            launchedApplicationsByCallerPID
                                            NSWorkspace 监听
                                            10 个 handler 直接挂 listener
                                            FetchServiceVersion handler

HelperClient (actor)                    HelperServiceManager (@MainActor @Observable)
  installTool (SMJobBless)                 SMAppService.daemon 安装/卸载
  connectToTool / sendToTool               Synchronization.Mutex<XPCConnection?>
  connectToServer / sendToServer           checkServiceVersionAndReinstallIfNeeded
  availableServerInfos                     uninstallLegacyService
                                          RuntimeHelperClient (单独包 OpenApplication)
                                          RuntimeInjectClient (注入 + framework + endpoint registry)

InjectionService (Interface/Impl)        (daemon final class 内的 inject handler,
FilesService (Interface/Impl)             daemon final class 内的 file op handler)
MainService (pkg, endpoint registry)
```

### 关键差异

1. **协议名 / 命名空间**:lib 的内置 Request 用 `com.JH.HelperCommunication.*` 和 `com.JH.HelperService.<area>.*`;RuntimeViewer 统一 `com.JH.RuntimeViewerService.*`。
2. **安装方式**:lib `HelperClient.installTool(name:)` 走 `SMJobBless`(macOS 13 已 deprecated);RuntimeViewer 早已迁到现代 `SMAppService.daemon(plistName:)`。
3. **业务能力缺口**:
   - `OpenApplicationRequest` + `launchedApplicationsByCallerPID` + `NSWorkspace.didTerminateApplicationNotification` 监听 — lib 没有。
   - `injectedEndpointsByPID` + `DispatchSourceProcess` PID 监控 — lib 没有。
   - `FetchServiceVersionRequest` 与 mismatch → auto-reinstall — lib 没有。
   - legacy plist `SMJobRemove` — lib 不该有(Objective-C 桥)。
4. **broker peer 通信链**:`RuntimeXPCConnection` 同时承担 `host ↔ daemon broker` 与 `host ↔ 被注入 target app` 两条 XPC 通道。lib `HelperClient.connectToServer(info:)` 已经覆盖"通过 broker 拿对端 endpoint 直连"语义,但没有覆盖反向连 + `serverLaunched` / `clientReconnected` 信令握手与 reconnect 时 peer connection 替换 — 这是 RuntimeViewer 业务用到、其他特权 helper 场景也会用到的通用能力,可以收纳。
5. **状态发布**:`RuntimeXPCConnection` 用 Combine `CurrentValueSubject`;`HelperServiceManager` 用 `@Observable`。lib 应当只暴露 `AsyncStream`,由调用方桥接。
6. **同名重复**:`VoidResponse` 两边各一份,合并 `RuntimeRequest: HelperCommunication.Request` 后,业务 Request 文件可以选择性使用 lib `VoidResponse`(全限定),`RuntimeViewerCommunication.VoidResponse` 保留给 Connection 链路上的 RuntimeRequest 子类使用。

## 设计方案

### 总体形状

- lib 收纳"特权 helper 安装、broker 注册表、broker peer 反向连接 + reconnect、版本对账"这一整层 IPC 骨架。
- RuntimeViewer 把业务请求保留在自己仓内,所有 daemon-side handler 实现成 `HelperService`;所有 client-side 单例改成对 lib `HelperClient` 的薄包装。
- `RuntimeRequest` 升格为 `HelperCommunication.Request` 的子协议,Connection 链路上(`RuntimeXPCConnection` 业务 RPC、`RuntimeNetwork/LocalSocket/Stdio/DirectTCP` 等)的现有用法全部继续工作,daemon 通信请求由于继承链自动满足 lib 协议,可以直接被 lib HelperService 挂载。
- `RuntimeXPCConnection` 不删:它继续是 `RuntimeConnection` 的实现,内部把 broker 与业务握手委托给 lib 的 `BrokeredPeerClient` / `BrokeredPeerServer`。

### lib 新增 / 改动

#### A. 新 module `HelperPeer`(独立 SPM target)

依赖 `HelperCommunication` + `SwiftyXPC`。位置 `Sources/HelperPeer/`。

```swift
// HelperPeer/PeerConnectionState.swift
public enum PeerConnectionState: Sendable {
    case connecting
    case connected
    case disconnected(any Error)
    case cancelled
}

// HelperPeer/PeerConnection.swift
public protocol PeerConnection: Actor, Sendable {
    var stateStream: AsyncStream<PeerConnectionState> { get }
    @discardableResult
    func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response
    func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    ) async
    func cancel() async
    // 暴露自身 listener endpoint,业务层若需要把 endpoint 放进自己的 Request payload(例如 RuntimeViewer 的 InjectedEndpointInfo)时使用。
    var listenerEndpoint: SwiftyXPC.XPCEndpoint { get async }
}

// HelperPeer/BrokeredPeerClient.swift
public actor BrokeredPeerClient: PeerConnection {
    /// 初次握手流程:open anonymous listener → connect tool → ping → register own endpoint → 等 server 发 ServerLaunched 反向连过来。
    public init(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        identifier: String,
        services: [HelperService] = []
    ) async throws

    /// reconnect 流程:open anonymous listener → 直接连给定 server endpoint → ping → 发 ClientReconnected 通知 server 替换 peer connection。
    public init(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        identifier: String,
        serverEndpoint: SwiftyXPC.XPCEndpoint,
        services: [HelperService] = []
    ) async throws
}

// HelperPeer/BrokeredPeerServer.swift
public actor BrokeredPeerServer: PeerConnection {
    /// open anonymous listener → connect tool → ping → fetch client endpoint → 主动连 client → 发 ServerLaunched(自己的 endpoint)
    /// → register 自己 endpoint(用于 host 重启时直接 reconnect)→ 注册 ClientReconnected handler。
    public init(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        identifier: String,
        services: [HelperService] = []
    ) async throws
}
```

内置握手 Request(`package`,不对外暴露):

```swift
// HelperPeer/PeerHandshakeRequests.swift (package)
package struct ServerLaunchedNotification: Codable, HelperCommunication.Request {
    package static let identifier = "com.JH.HelperPeer.ServerLaunched"
    package typealias Response = HelperCommunication.VoidResponse
    package let endpoint: SwiftyXPC.XPCEndpoint
}

package struct ClientReconnectedNotification: Codable, HelperCommunication.Request {
    package static let identifier = "com.JH.HelperPeer.ClientReconnected"
    package typealias Response = HelperCommunication.VoidResponse
    package let endpoint: SwiftyXPC.XPCEndpoint
}
```

业务 RPC handler 通过 `services: [HelperService]` 数组挂载(与 `HelperServer` 完全一致),也支持 init 之后 `setMessageHandler(_:handler:)` 运行时再加。

#### B. `HelperCommunication`:public 化 + broker 行为扩展

- `XPCExtensions.swift` 中 `extension SwiftyXPC.XPCConnection.sendMessage<Request:>` 与 `extension SwiftyXPC.XPCListener.setMessageHandler<Request:>` 从 `package` 提升到 `public`。**理由**:`HelperCommunication.Request` 协议本就是 `public`,要让外部代码使用此协议必须配套提供 public 的发送/接收扩展。这不属于内部 Request 类型泄露。
- 新文件 `XPCConnection+MainService.swift`,提供 4 个 public 行为扩展(实际请求类型仍 `package`):

```swift
public extension SwiftyXPC.XPCConnection {
    func pingHelperTool() async throws
    func registerEndpoint(_ endpoint: SwiftyXPC.XPCEndpoint, machServiceName: String, identifier: String) async throws
    func fetchEndpoint(machServiceName: String, identifier: String) async throws -> SwiftyXPC.XPCEndpoint
    func listHelperServerInfos() async throws -> [HelperServerInfo]
}
```

#### C. `HelperCommunication`:版本对账

```swift
// HelperCommunication/FetchVersionRequest.swift
public struct FetchVersionRequest: Codable, Request {
    public static let identifier = "com.JH.HelperCommunication.FetchVersion"
    public struct Response: Codable, Sendable {
        public let version: String
    }
    public init() {}
}
```

`HelperServer.init` 新增参数 `version: String`,内部把版本注入 `MainService`;`MainService` 增加对应 handler。`HelperClient` 增加:

```swift
public extension HelperClient {
    func fetchToolVersion() async throws -> String
}
```

同时把"`unexpectedMessage` 表示老二进制,其它一律视作 transient" 的判定逻辑作为 lib `XPCConnection.Error` 的扩展提供,例如 `var indicatesOutdatedPeer: Bool`,供调用方用于区分"该自动重装"和"忽略本次故障"。

#### D. `HelperClient`:新增 SMAppService.daemon 安装路径

新文件 `HelperClient/SMAppServiceDaemonInstaller.swift`(`@available(macOS 13, *)`):

```swift
@available(macOS 13, *)
public actor SMAppServiceDaemonInstaller {
    public init(plistName: String)
    public var currentStatus: SMAppService.Status { get async }
    public var statusStream: AsyncStream<SMAppService.Status> { get async }   // poll-based 或基于显式 refresh
    public func register() async throws
    public func unregister() async throws
    public func openLoginItemsSettings()
}
```

工厂入口 `HelperClient.daemonInstaller(plistName:)` 返回该 actor。lib 不抬最低版本,API 用 `@available` 门控;`HelperClient` 上的 `installTool(name:)` SMJobBless 路径保留。

#### E. 维护:`HelperServer` `services:` 参数顺序

`HelperServer.init` 在 `MainService` 之后追加用户传入的 services。`MainService` 增加 ping/version handler,登录到 listener 的次序由 `HelperServer` 内部决定。这一点保持现状不变。

### RuntimeViewerCommunication 改动

#### A. 协议合并

```swift
// RuntimeRequestResponse.swift
import HelperCommunication   // 新增

public protocol RuntimeRequest: HelperCommunication.Request {
    associatedtype Response: RuntimeResponse
}

public protocol RuntimeResponse: Codable, Sendable {}   // +Sendable

public struct VoidResponse: RuntimeResponse {           // 保留(给 Connection 链路 RuntimeRequest 用)
    public init() {}
    public static let empty: VoidResponse = .init()
}
```

`RuntimeRequest` 通过协议继承自动获得 `Codable, Sendable, static var identifier: String, associatedtype Response`(后者复合约束:同时满足 `RuntimeResponse` 与 `Codable & Sendable`,因为 `RuntimeResponse: Codable, Sendable`)。

#### B. 删除被 lib 覆盖的 Request 文件

- `Requests/PingRequest.swift` — daemon 链路与 Connection peer 链路均改用 `HelperCommunication.PingRequest`。
- `Requests/FetchEndpointRequest.swift` — 由 lib `BrokeredPeerServer` 内部发起,host/server 都不直接发。
- `Requests/RegisterEndpointRequest.swift` — 同上,由 `BrokeredPeerClient` 内部发起。
- `Requests/FetchServiceVersionRequest.swift` — 改用 lib 新 `FetchVersionRequest`。

#### C. 保留的 Request 文件(不动)

- `OpenApplicationRequest.swift` / `InjectApplicationRequest.swift` / `FileOperationRequest.swift` / `RegisterInjectedEndpointRequest.swift` / `FetchAllInjectedEndpointsRequest.swift` / `RemoveInjectedEndpointRequest.swift` / `InjectedEndpointInfo.swift`。
- identifier 保持 `com.JH.RuntimeViewerService.*`。
- 由于 `RuntimeRequest: HelperCommunication.Request`,daemon 端 lib `HelperService.setupHandler` 可直接挂这些 Request。

#### D. 删除自带的 XPC extension

`RuntimeXPCConnection.swift` 文件末尾两个 `extension SwiftyXPC.XPCConnection.sendMessage<Request: RuntimeRequest>` / `setMessageHandler<Request: RuntimeRequest>` 删除 — lib 把 `sendMessage<Request: HelperCommunication.Request>` / `setMessageHandler<Request:>` 提为 public 后,RuntimeRequest 子类自动可用。

#### E. `RuntimeXPCConnection` adapter 化

`RuntimeXPCConnection.swift` 保留,但内部不再持有 `SwiftyXPC.XPCListener` / `SwiftyXPC.XPCConnection`(三件),而是持有一个 `any PeerConnection`(lib actor):

```swift
class RuntimeXPCConnection: RuntimeConnection, @unchecked Sendable {
    fileprivate let identifier: RuntimeSource.Identifier
    fileprivate let peer: any PeerConnection
    fileprivate let stateSubject: CurrentValueSubject<RuntimeConnectionState, Never>
    // 用 Task 把 peer.stateStream 桥接到 stateSubject,生命周期跟 self 走。

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        try await peer.send(request)
    }
    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: ...) async {
        await peer.setMessageHandler(requestType, handler: handler)
    }
    func stop() async { await peer.cancel() }
    // ...
}

final class RuntimeXPCClientConnection: RuntimeXPCConnection {
    init(identifier:, modifier:) async throws {
        let client = try await BrokeredPeerClient(
            machServiceName: RuntimeViewerMachServiceName,
            isPrivilegedHelperTool: true,
            identifier: identifier.rawValue,
            services: []
        )
        super.init(identifier: identifier, peer: client)
        // modifier(self) 注册业务 handler 等
    }
    init(identifier:, serverEndpoint:, modifier:) async throws {
        let client = try await BrokeredPeerClient(... serverEndpoint: serverEndpoint ...)
        super.init(identifier: identifier, peer: client)
    }
}

final class RuntimeXPCServerConnection: RuntimeXPCConnection {
    override init(identifier:, modifier:) async throws {
        let server = try await BrokeredPeerServer(...)
        super.init(identifier: identifier, peer: server)
    }
}
```

untyped `sendMessage(name:)` / `setMessageHandler(name:)` 重载在 `RuntimeXPCConnection` 现有公开接口中存在(用于 RuntimeConnection 协议外部直接发 raw 命令);搬到 lib peer 之后这些 untyped 入口要么 1)在 `PeerConnection` 协议上加 raw `sendMessage(name:)` 方法、2)`RuntimeXPCConnection` 保留对 SwiftyXPC 的 limited untyped 透传(从 peer 拿原始 connection)、3)审计 callers 看是否都能改成类型化 Request。本设计倾向 3 — adapter 阶段对 callers 做一次梳理,把残余的 untyped 调用收敛为 Request。具体 caller 列表在 Plan 阶段产出。

### Daemon target(`RuntimeViewerService`)改动

#### A. 删除单文件 final class

`RuntimeViewerService.swift` 删除,把其中 10 个 handler 拆成 4 个 `HelperService` 实现 + 由 lib `MainService` 接管 broker + 由 lib `HelperServer` 接管版本上报。

#### B. 新增 4 个 service 文件(均在 `RuntimeViewerService` target 内)

- `ApplicationsService.swift`(`actor`): handle `OpenApplicationRequest`,持有 `launchedApplicationsByCallerPID: [pid_t: [NSRunningApplication]]`,启动一个 Task 监听 `NSWorkspace.didTerminateApplicationNotification`,caller PID 退出时终止其拉起的子 app。
- `InjectedEndpointRegistryService.swift`(`actor`): handle `RegisterInjectedEndpointRequest` / `FetchAllInjectedEndpointsRequest` / `RemoveInjectedEndpointRequest`,持有 `injectedEndpointsByPID: [pid_t: InjectedEndpointInfo]` + `processMonitorSources: [pid_t: any DispatchSourceProcess]`。
- `InjectionService.swift`(本仓版,**不复用 lib 的 `InjectionServiceImplementation`**,因 identifier 命名空间不同): handle `InjectApplicationRequest`,内部仍 `MachInjector.inject(pid:dylibPath:)`。
- `FilesService.swift`(本仓版,同上): handle `FileOperationRequest`。

#### C. daemon `main.swift` 改写

`RuntimeViewerUsingAppKit/com.mxiris.runtimeviewer.service/main.swift`:

```swift
import HelperService
import HelperServer
import HelperCommunication
import RuntimeViewerCommunication
import RuntimeViewerService

@main
struct RuntimeViewerServiceMain {
    static func main() async throws {
        try autoreleasepool {
            let server = try await HelperServer(
                serverType: .machService(name: RuntimeViewerMachServiceName),
                version: RuntimeViewerServiceVersion,
                services: [
                    ApplicationsService(),
                    InjectedEndpointRegistryService(),
                    InjectionService(),
                    FilesService(),
                ]
            )
            await server.activate()
            RunLoop.current.run()
        }
    }
}
```

debug 的 `com.JH.RuntimeViewerService/main.swift` 同步改造。

### Client target(`RuntimeViewerHelperClient`)改动

#### A. `HelperServiceManager`(`@MainActor @Observable`,保留)

- 删去自带的 `connectionLock: Synchronization.Mutex<XPCConnection?>` 与 `connectionIfNeeded()` 方法。
- 持有一个 `HelperClient`(lib actor)实例。`reconnect` / `invalidateConnection` 委托 lib。
- 持有一个 `SMAppServiceDaemonInstaller`(lib actor)实例。`manageHelperService(action:)` 委托 lib `register/unregister`,本类只翻译 `SMAppService.Status` → Observable 的 `status` / `message` 文案。
- `checkServiceVersionAndReinstallIfNeeded()` 改用 `HelperClient.fetchToolVersion()`;"outdated binary vs transient"判断使用 lib `XPCConnection.Error.indicatesOutdatedPeer`。
- `uninstallLegacyService()` 保留(`LegacyHelperTool.uninstall(withServiceName:)` 调用本仓 ObjC `RuntimeViewerServiceHelper`,通过 lib 的 `FileOperationRequest` 删除老 plist)。
- legacy plist URL / `SMAppService.daemon(plistName:)` 这些常量留在本类。

#### B. `RuntimeHelperClient` / `RuntimeInjectClient`

- 删去自管 `connectionLock`,共享 `HelperServiceManager` 持有的 lib `HelperClient`。两者改成对 `client.sendToTool(request:)` 的薄包装,只保留业务方法(`launchMacCatalystHelper` / `injectApplication` / `installServerFramework` / `registerInjectedEndpoint` 等)。
- 二者作为 `@Dependency` 注入点继续存在,但内部实现降级为 ~30 行。

### Catalyst helper 改动

`RuntimeViewerCatalystHelper` 当前应有一段 broker 注册代码(向 daemon 发 `RegisterEndpointRequest`)。改成创建一个 `HelperServer(serverType: .plain(name: RuntimeViewerMachServiceName, identifier: "catalyst-helper"), services: [...])` 并调 `connectToTool(machServiceName: ..., isPrivilegedHelperTool: true)`。具体 caller 在 Plan 阶段查阅 Catalyst helper 源码后产出文件级动作。

### Package 依赖布线

- `RuntimeViewerCore/Package.swift`:加 `swift-helper-service` 依赖,`RuntimeViewerCommunication` target 依赖 `HelperCommunication` 与 `HelperPeer`。沿用现有 `Package.Dependency.package(local:remote:)` 工厂提供 local + remote fallback,local 路径为 `MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("swift-helper-service")`。
- `RuntimeViewerPackages/Package.swift`:同样加该依赖。`RuntimeViewerService` target 依赖 `HelperServer` + `HelperService` + `HelperCommunication`;`RuntimeViewerHelperClient` target 依赖 `HelperClient` + `HelperCommunication`。`RuntimeViewerCatalystExtensions` 视情况依赖 `HelperPeer`(若 Catalyst helper 改造涉及 RuntimeXPCConnection 的话,实际由 RuntimeViewerCommunication 间接引入即可)。

## Identifier 策略

- **业务 Request**:`OpenApplication` / `InjectApplication` / `FileOperation` / `Register/Fetch/Remove InjectedEndpoint*` / `FetchAllInjectedEndpoints` 保持 `com.JH.RuntimeViewerService.*` 命名空间不变。这些 Request 由本仓内的 4 个 `HelperService` 实现挂载,lib 不感知具体 identifier。
- **broker 内部 Request**:由 lib 的 `MainService` 与 `HelperPeer` 处理,identifier 为 `com.JH.HelperCommunication.*` / `com.JH.HelperPeer.*`,host app / daemon / Catalyst helper / 被注入 app 各端会一同更新到使用 lib 内部 identifier。**此处 identifier 变化是 daemon broker 链路上的协议变更**,daemon 二进制必须重装才能与新 host 通信 — 但 daemon 二进制本身就因为换骨架而必须重装,这并不增加额外升级成本。
- **PingRequest**:Connection 链路上原本走 `com.JH.RuntimeViewerService.Ping` 的位置全部改用 `com.JH.HelperCommunication.Ping`(lib `PingRequest`)。被注入 target app 与 host app 来自同一份代码、一同更新,无版本错配问题。

## 兼容性 & 升级路径

| 资产 | 旧 | 新 | 升级路径 |
|---|---|---|---|
| daemon 二进制 | `final class RuntimeViewerService`,`RuntimeViewerServiceVersion = "1.0.0"` | `HelperServer + [services]`,`RuntimeViewerServiceVersion = "1.1.0"`(或更高) | host `HelperServiceManager.checkServiceVersionAndReinstallIfNeeded()` 检测到版本不一致(老 daemon 收到新 `FetchVersionRequest` 会返回 `unexpectedMessage` → 触发 `indicatesOutdatedPeer` 分支)→ 自动 unregister + register 新 daemon |
| Catalyst helper | 在 host app bundle 内,随主 app 一同更新 | 同上,改用 `HelperServer(.plain)` | 不需要专门升级路径,跟随主 app 安装 |
| `com.JH.RuntimeViewerService.*` 业务 identifier | 保持 | 保持 | 无变化 |
| `com.JH.RuntimeViewerService.Ping` / `FetchEndpoint` / `RegisterEndpoint` / `FetchServiceVersion` | 旧 daemon 与旧 host 之间用 | 删除,改 lib identifier | 旧 host ⇄ 新 daemon 或新 host ⇄ 旧 daemon 均不兼容,但这条线只在重装窗口期短暂存在,版本对账会强制重装收敛 |
| legacy `/Library/LaunchDaemons/com.JH.RuntimeViewerService.plist` | `RuntimeViewerServiceHelper.RVLegacyHelperTool.SMJobRemove` | 同 | 不变,仍由本仓 ObjC 桥处理 |

## 测试策略

测试在两个 repo 内分层覆盖,**lib 端测试随 Phase 0 落地,RuntimeViewer 端测试随 Phase 1 落地**,不堆到最后。

### lib `swift-helper-service` 端

lib 当前**没有 `Tests/` target**,本次新增。`Package.swift` 加 `.testTarget(name: "HelperCommunicationTests", ...)` 和 `.testTarget(name: "HelperPeerTests", ...)` 两个 target,使用 swift-testing(macOS 11+ 可用)。

**`HelperCommunicationTests`(单元)**

覆盖目标:协议契约 + 序列化 + XPCConnection 扩展行为。

- `VoidResponse` / `PingRequest` / `FetchVersionRequest` 的 `Codable` 往返(`JSONEncoder` + `JSONDecoder` 编码后再解码,值等价)。
- `FetchVersionRequest.Response` 字段 `version` 序列化稳定。
- `Request.identifier` 静态字符串与命名空间约定一致(`com.JH.HelperCommunication.*`)。
- `XPCConnection.Error.indicatesOutdatedPeer` 在 `.unexpectedMessage` 时返回 true,其它所有 case 返回 false。
- `XPCConnection+MainService` 4 个扩展方法的语义(`pingHelperTool` / `registerEndpoint` / `fetchEndpoint` / `listHelperServerInfos`):使用 in-process anonymous `XPCListener` 模拟 daemon broker,挂 PingRequest / FetchEndpointRequest / RegisterEndpointRequest / ListServerInfosRequest 这几个 handler 后,从客户端 XPCConnection 调用上述扩展方法,断言 broker 端收到对应请求且响应正确。**这套 in-process broker fake 是 HelperPeerTests 的共享基础设施**,抽到 `Sources/HelperCommunicationTests/InProcessBroker.swift`。

**`HelperPeerTests`(集成)**

覆盖目标:`BrokeredPeerClient` / `BrokeredPeerServer` 的握手 + reconnect + state stream + 业务 RPC handler。

测试基础设施:由于 mach service 需要 plist 注册,test 环境跑不动,采用**in-process anonymous broker**:测试用 `XPCListener(type: .anonymous)` + 内置 MainService 行为(register / fetch / list)起一个 broker,把它的 endpoint 注入到 `BrokeredPeerClient` / `BrokeredPeerServer` 的 init —— 这意味着 lib 需要在 `BrokeredPeerClient` / `BrokeredPeerServer` 上额外提供一组**测试用 init**,接受 `toolEndpoint: SwiftyXPC.XPCEndpoint` 代替 `machServiceName: String + isPrivilegedHelperTool: Bool`,在 internal/`@testable` 可见性下使用。

测试用例:

- **TC-1 初次握手**:起 in-process broker,起 `BrokeredPeerClient`,起 `BrokeredPeerServer`,断言双方 state 序列 `.connecting → .connected`;client 通过 `send(...)` 发自定义业务 Request,server 端 `HelperService.setupHandler` 注册的 handler 收到并响应。
- **TC-2 reconnect by endpoint**:在 TC-1 基础上,client `cancel()`,新起一个 `BrokeredPeerClient(... serverEndpoint: server.listenerEndpoint, ...)` 直接 reconnect,断言:server 端 `ClientReconnectedNotification` handler 被触发、peer connection 替换、state 重新到 `.connected`、业务 RPC 继续可用。
- **TC-3 双向业务 RPC**:client 和 server 各挂一个自定义 Request handler(via `services: [HelperService]`),互相发送,断言双向均成功(覆盖"既是 client 又是 server"的反向 RPC)。
- **TC-4 state stream cancel**:`cancel()` 之后 state stream 推 `.cancelled` 然后 finish,后续 `send(...)` 抛错。
- **TC-5 broker 失活**:broker `cancel()` 之后 client/server `send(...)` 抛 XPC 连接错误,state 转 `.disconnected(_)`。

**`HelperClientTests`(可选,跳过)**

`SMAppServiceDaemonInstaller` 涉及 `SMAppService.daemon(plistName:)` 系统调用,test 环境无法注册真实 daemon。该 actor 留给 Phase 6 手测覆盖,不写自动化。同理 `HelperClient.installTool(name:)`(SMJobBless)不写。

### RuntimeViewer 端

复用现有 `RuntimeViewerCommunicationTests` target,**不新增 target**。

**`RequestTests.swift` 调整**

- 删除针对 `PingRequest` / `FetchEndpointRequest` / `RegisterEndpointRequest` / `FetchServiceVersionRequest` 的 4 组 case(这些 Request 文件已被删,改用 lib 等价物;lib 那边已经有等价测试)。
- 保留并验证 6 个业务 Request 的 `Codable` 往返:`OpenApplicationRequest` / `InjectApplicationRequest` / `FileOperationRequest` / `RegisterInjectedEndpointRequest` / `FetchAllInjectedEndpointsRequest` / `RemoveInjectedEndpointRequest`。

**新增 `RuntimeRequestProtocolMergeTests.swift`**

验证 `RuntimeRequest: HelperCommunication.Request` 协议合并后的兼容性,**这是合并最容易回归的地方,必须有自动化覆盖**。

- 任意继承 `RuntimeRequest` 的 struct 自动满足 `HelperCommunication.Request`(编译期断言:`func _: some HelperCommunication.Request = OpenApplicationRequest(url:..., callerPID:0)`)。
- `RuntimeResponse: Sendable` 后,`VoidResponse` 同时是 `RuntimeResponse` 和 `HelperCommunication.VoidResponse` 满足的所有约束。
- Connection 链路(`RuntimeXPCConnection` 之外的 RuntimeRequest 子类,例如 tests 内 `EchoRequest`)的行为不变:`RuntimeStdioConnectionTests` 必须仍然通过。

**`RuntimeXPCConnection` adapter 自测(可选)**

- 验证 `RuntimeXPCConnection.statePublisher` 桥接 lib `PeerConnectionState` → `RuntimeConnectionState` 映射正确。可以用 lib 在 `HelperPeerTests` 里抽出来的 `InProcessBroker` 通过本仓的 test target 间接复用(需要把它放到 `@testable import HelperPeer` 暴露的位置,或者 lib 单独提供一个 `HelperPeerTesting` library 给外部 test 用)。
- 该测试如果实施复杂度高,**可以延后**;Connection 链路的端到端行为由 Phase 6 手测兜底。

### 不在自动化测试覆盖范围内

下述场景**仅 Phase 6 手测覆盖**:

- 真实 SMAppService.daemon 安装/卸载/状态翻译(需系统权限)。
- 真实 mach service broker 上的 host-target app 通信。
- daemon `RuntimeViewerServiceVersion` mismatch → 自动 unregister + register 完整流程。
- legacy plist `SMJobRemove` 卸载。
- MachInjector 真实注入 + RuntimeViewerServer.framework 拷贝到 `/Library/Frameworks/`。
- Catalyst helper 实际启动。
- `DispatchSourceProcess` PID 监控真实子进程退出。

## 风险与待定

1. **`HelperServer` 现签名变更**:`init(serverType:services:)` → `init(serverType:version:services:)`。lib 内部其它 caller 不存在(只在 Plan 中提供),lib `CLAUDE.md` 与 README 需要同步更新。本 PR 在 lib 端做,RuntimeViewer 端会直接用新签名。
2. **lib `package → public` 提升**:lib 的 `CLAUDE.md` 显式声明"registry types are intentionally `package`"。新方案保持注册表 Request 类型 `package`,只把 `sendMessage<Request:>` / `setMessageHandler<Request:>` 提为 public(协议公开的必要附属能力),`HelperServerInfo.init` 维持 `package`(仅 lib 内部通过新加的 broker 行为扩展构造)。lib `CLAUDE.md` 需要补充这一点说明,以免后人误以为可以放开 registry Request。
3. **`AsyncStream` 桥接细节**:RuntimeXPCConnection adapter 内,Task 监听 `peer.stateStream` → `stateSubject` 的 Combine 桥接,需要处理 actor 析构时 cancel Task 的生命周期管理。设计上 adapter 使用 `@unchecked Sendable` final class,内部 `Task` 在 `stop()` 中显式 cancel,并在 deinit 中兜底。
4. **`PeerConnection` 上的 raw `sendMessage(name:)` 入口**:`RuntimeXPCConnection` 当前对外暴露多个 untyped `sendMessage(name:)` / `setMessageHandler(name:)` 重载。Plan 阶段先 grep 实际 callers,确认是否都能改成类型化 Request;若有少量保留需求,在 `PeerConnection` 上以 `package` extension 暴露给 adapter,不进入 lib 公开 API。
5. **SMAppService.daemon 状态变化检测**:`SMAppService.Status` 没有 KVO/notification,需要靠主动 refresh。lib `SMAppServiceDaemonInstaller.statusStream` 通过 register/unregister 操作前后显式刷新 + 调用方主动 `refresh()` 推送,而不是 polling。RuntimeViewer 的 `HelperServiceManager` 已经是按需 refresh 的模式,迁移成本低。
6. **`Synchronization.Mutex`(macOS 15+)**:RuntimeViewer 当前用,lib 不用(actor 已经线性化访问)。`HelperServiceManager` 改造后不再需要这个依赖,可以删除相关 `import Synchronization`。
7. **测试可见性**:`BrokeredPeerClient` / `BrokeredPeerServer` 测试用 `init(toolEndpoint:)` 走 `@_spi(Testing)` 或 `internal + @testable`,不进入 public API。
8. **`@Loggable` macro**:RuntimeViewer 各处使用 `@Loggable` / `#log(.info,...)` 风格(`FoundationToolbox` 提供)。lib 端只用 `OSLog.Logger`,迁移 daemon 代码到 lib 时把 `@Loggable` 替换为标准 `Logger`,但 RuntimeViewer 仓内的 service 文件保留 `@Loggable` 风格不变。

## 验收标准

1. lib `swift build && swift test 2>&1 | xcsift` 全绿,新 `HelperCommunicationTests` + `HelperPeerTests` 通过,`@available(macOS 13, *)` 不污染最低版本。
2. RuntimeViewer 全工作区构建成功(`xcodebuild -workspace ../MxIris-Reverse-Engineering.xcworkspace -scheme "RuntimeViewer macOS" -configuration Debug`),`RuntimeViewerCommunicationTests` 通过。
3. daemon 重装后 host app `HelperServiceManager.status` 正确翻译为 enabled;版本对账走过一次自动 reinstall 路径(手测)。
4. 主 app 注入 / 被注入端点 reconnect / Catalyst helper 启动 / 文件操作 等核心场景手测通过。
5. `RuntimeRequest` 旧 callers(`RuntimeNetworkConnection` 等)行为不变,Tests/`RequestTests.swift` + `RuntimeStdioConnectionTests.swift` + `RuntimeRequestProtocolMergeTests.swift` 通过。

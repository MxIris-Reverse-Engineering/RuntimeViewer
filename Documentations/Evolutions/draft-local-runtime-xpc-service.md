# Draft - 本地运行时引擎搬进内嵌 XPC service

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-09-21
- **最后更新**: 2026-09-21
- **所属愿景**: 无
- **关联提案**: [draft-engine-management-module](draft-engine-management-module.md)（本提案借它开出的 `RuntimeEngineManagerConfiguration` 与 `RuntimeResourceLocating` 两条缝，不另起炉灶）、[0014](0014-inject-ios-simulator-process.md)（注入路径不受影响，但其 `SandboxProbe` 说明了为什么 service 不能开沙盒）
- **实现分支 / PR**: `feature/local-runtime-xpc-service`（worktree `.worktrees/RuntimeViewer-LocalRuntimeXPCService`），从 `next` 切出；PR 待定
- **配套文档**: 待定 —— 落地时更新 [`CommunicationAndEngineArchitecture.md`](../CommunicationAndEngineArchitecture.md) §1 传输对照表、§3 新增一节 XPC service 连接、§5 / §7 系统引擎的构成，以及 `AGENTS.md` 的 Application Targets 与 Architecture 两节

## 摘要

RuntimeViewer 的「My Mac」运行时引擎（`RuntimeEngine.local`）今天跑在 App 自己的进程里：用户选中的每一个镜像都由 App 进程 `dlopen`，ObjC / Swift 元数据索引也在 App 进程里做。一个坏 Mach-O、一段会崩的镜像构造函数、一次 ObjC 类名冲突，都直接带走整个 App，没有任何恢复余地。本提案把这台引擎搬进一个随 App 打包的**普通 XPC service**（`RuntimeViewerLocalRuntimeService.xpc`，`Contents/XPCServices/` 下，launchd 按需拉起）：不需要 Mach service，不需要特权 helper daemon。App 侧引擎的身份仍然是 `.local`——UI、书签、侧栏 autosave key、发给 Bonjour 对端的引擎描述符全部不变——只是 App 进程里的这台引擎把工作转发给 service（由进程自己的 `Info.plist` 决定，不加配置项）；App 与 service 之间用 SwiftyXPC 直连，沿用现有「名字 + Codable」消息模型与共享命令表。service 崩溃后同一个引擎对象自动重连，已加载镜像丢失、文档回到镜像列表根并发一条系统通知。iOS App、包测试与 `runtime-viewer-cli` 的独立 host 继续使用进程内引擎。

## 动机

**本地引擎与 App 同生共死，是当前架构里唯一没有隔离的运行时。** 其它来源早已各自在别的进程里：Mac Catalyst 运行时在 `RuntimeViewerCatalystHelper.app`，注入的目标在目标进程，iOS 在设备上。只有「My Mac」例外——它是 App 进程自己：

- `RuntimeEngine.local`（`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:96-102`）是一个静态单例，`connect(credential:)`（`RuntimeEngine.swift:288-342`）在没有 `remoteRole` 时走末尾分支直接 `observeRuntime()`。
- `loadImage(at:)` 的本地实现 `_loadImage`（`RuntimeEngine.swift:898-907`）调用 `DyldUtilities.loadImage(at:)`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift:220-233`），即在**当前进程**里 `dlopen(path, RTLD_LAZY)`。镜像的 `__attribute__((constructor))`、ObjC `+load`、Swift 全局初始化全部在 App 进程里跑；它们 `abort()`、访问坏指针、或者注册一个与 App 已有类同名的 ObjC 类，App 就没了。
- 随后 `objcSectionFactory.section(for:)` / `swiftSectionFactory.section(for:)` 在 App 进程里解析并索引元数据。MachOKit / MachOSwiftSection 面对畸形二进制的每一处崩溃都是 App 崩溃；`git log` 里 `3916932e fix(inject): stop the platform probe crashing on a hostile fat header` 是同类问题在注入探针上的一次实例。
- 所有已索引镜像的声明图与 `NodeStore` 都常驻 App 进程；`RuntimeEngine.releaseIndexedSections()` 的注释（`RuntimeEngine.swift:387-402`）专门解释了为什么要显式释放它们——「anything that outlives the stop while holding the engine … would otherwise keep the entire indexed graph of every image the user ever opened resident」。搬出去之后这部分内存跟着 service 走，service 退出即归零。

用户对此的判断是「`RuntimeEngine` 的 local 很危险」，并明确要求用**普通 XPC service** 解决，不要 Mach service 与 daemon。

## 前期调研

以下事实均已在代码或依赖源码中核实；标注「推测」的除外。

### 1. 现状代码怎么走的

1. **App 侧引用 `RuntimeEngine.local` 的地方只有三处，其余都在 iOS / 测试 / CLI**：
   `DocumentState.runtimeEngine` 的默认值（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift:23`）、`MainViewModel` 的默认选中引擎与名称缓存（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift:101,103`）、`RuntimeEngineManager.launchSystemRuntimeEngines()` 把它追加进 `systemRuntimeEngines`（`RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/RuntimeEngineManager.swift:513-522`）。iOS App 在 `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/AppDelegate.swift:15` 预热它；`RuntimeViewerApplicationTests` 通过 `withSharedLocalEngineLock` 与 `TestRuntimeEngine` 依赖它；CLI 的 `LocalSourceResolver`（`RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Execution/SourceResolving.swift:34-49`）与 `.headlessHost` 配置的管理器各自持有一台进程内引擎。
2. **client / server 分工已经存在，且按 `source.remoteRole` 判定**：`dispatch(_:)`（`RuntimeEngine.swift:796-808`）与进度版 `dispatch(_:onProgress:)`（`RuntimeEngine.swift:824-852`）在 `remoteRole.isClient` 时序列化转发，否则执行本地 `perform(on:)`；`setupMessageHandlerForClient()`（`RuntimeEngine.swift:447-470`）接收 `imageList` / `imageNodes` / `dataDidChange` / `imageDidLoad` / `progressEvent` 推送；`broadcast(_:)`（`RuntimeEngine.swift:542-563`）与 `sendRemoteImageDidLoadIfNeeded`（`RuntimeEngine.swift:586-596`）只在 server 角色下发推送。**共享命令表** `RuntimeEngine.registerSharedHandlers(on:engine:)`（`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineRequest.swift:149`）把每个请求注册成 `engine.dispatch(request)`（`RuntimeEngineRequest.swift:102-110`），所以把一台 *client* 引擎再包一层对外服务时请求会继续向上游转发——链式代理已经在 Mac Catalyst helper 上验证过（`RuntimeEngineRequest.swift:112-121` 的注释）。
3. **`RuntimeEngineProxyServer`（`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift:17-260`）就是「把一台进程内引擎放到一条连接上对外服务」**：client 连上后注册共享命令表、转发 `imageNodes` / `imageList` / `dataDidChange` 推送、发送初始数据。它写死了 `.directTCP` 传输，并且**不转发 `imageDidLoad`**（`setupPushRelay` 只订阅 `imageNodesPublisher` 与 `dataChangePublisher`）。
4. **管理器对「引擎断连」的处理是一刀切删除**：`RuntimeEngineManager.handleStateChange(_:of:)` 收到 `.disconnected` 即 `cleanupMirroredEnginesOnDisconnect` + `terminateRuntimeEngine(for:)` + 发 `.hostDisconnected` 事件（`RuntimeEngineManager.swift:1019-1055`，`eventSubject.send(.hostDisconnected` 在 :1049）。对本地引擎照搬这条路径，service 一崩「My Mac」就从来源列表里消失。
5. **工具栏只在引擎从列表消失时显示断开**：`MainViewModel` 的 `SwitchSourceState.isDisconnected` 由「选中引擎不在 `runtimeEngineSections` 里」推出（`MainViewModel.swift:300-320`）。引擎留在列表里自动重连时，工具栏不会闪断开态。
6. **文档层已有一条「换引擎即整体重置」的路径可复用**：`SelectionRouter.contextTrigger(.switchEngine)`（`DocumentState.swift:177-186`）清 `currentImageNode`、导航历史与 tab；其守卫 `if documentState.runtimeEngine === engine, currentImageNode == nil, selectionStack.isEmpty { return }` 恰好让「同一引擎但正在浏览镜像」的情形走完整重置。
7. **管理器已有配置缝**：`RuntimeEngineManagerConfiguration`（`RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/RuntimeEngineManagerConfiguration.swift:10-50`）区分 `.application` 与 `.headlessHost`；`RuntimeResourceLocating`（`RuntimeViewerPackages/Sources/RuntimeViewerHelperClient/RuntimeResourceLocating.swift:14-22`）负责「按 App bundle 定位资源」，CLI 进程没有 bundle 时返回 `nil`。
8. **`DocumentState` 由 App 的 `Document` 直接构造**（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift:13`，`DocumentState.init()` 在 `DocumentState.swift:11`），`RuntimeViewerApplication` 在 macOS 上已依赖 `RuntimeViewerEngineManagement`（`RuntimeViewerPackages/Package.swift`，`RuntimeViewerApplication` target 的条件依赖）。

### 2. 现有 XPC 连接为什么不能直接用

`RuntimeXPCConnection`（调研时的名字，落地时改名 `RuntimeXPCMachServiceConnection`，见决策日志；`RuntimeViewerCore/Sources/RuntimeViewerCommunication/Connections/RuntimeXPCConnection.swift`）是 `HelperPeer` 的薄适配：`RuntimeXPCClientConnection.init` 构造 `HelperPeerClient(machServiceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true, …)`（:170-179），握手、端点交换、`ServerLaunched` / `ClientReconnected` 通知全部经过特权 helper daemon 这个中介。`RuntimeCommunicator.connect(to:)` 对 `.local` 直接抛 `localConnectionNotSupported`（`RuntimeCommunicator.swift:74-76`）。`RuntimeSource.isXPC` 的注释「XPC connections cannot be reconnected … must be destroyed and recreated」（`RuntimeSource.swift:144-153`）描述的是这条经 broker 的路径，不适用于下面的具名 XPC service。

### 3. 上游能力：SwiftyXPC 原生支持普通 XPC service

SwiftyXPC 已是间接依赖（`swift-helper-service/Package.swift:131` 引 `MxIris-macOS-Library-Forks/SwiftyXPC`；Debug workspace 的 `Package.resolved` 钉在 revision `7cd9e094`）。它提供：

- `XPCListener.ListenerType.service`（`Sources/SwiftyXPC/XPCListener.swift:24-31`）：service 侧监听器，`activate()` 走 `xpc_main`（:262-282），**每条新进连接在接受时复制监听器上已登记的 `messageHandlers` 与 `errorHandler`**（:271-278），所以业务 handler 必须在 `activate()` 之前登记；该监听器不能 `cancel()` / `suspend()`（`fatalError`）。
- `XPCConnection.ConnectionType.remoteService(bundleID:)`（`Sources/SwiftyXPC/XPCConnection.swift:46-52, 101`）：App 侧按 service 的 bundle identifier 建连，底层 `xpc_connection_create(bundleID, nil)`。
- 名字消息 API `setMessageHandler(name:handler:)` 与 `sendMessage(name:request:)`（`XPCConnection.swift:154-227, 310-390`），请求 / 响应均为 `Codable`，与 `RuntimeConnection` 协议同形；client 侧同样能 `setMessageHandler`，一条连接双向可用，service 推送不需要第二条连接。
- 中断语义：`XPCError.connectionInterrupted` 的文档写明「The connection is still live even in this case, and resending a message will cause the service to be launched on-demand」（`Sources/SwiftyXPC/XPCError.swift:14-17`）；连接层事件经 `handleEvent` 转给 `errorHandler`（`XPCConnection.swift:486-489`），正在等待回复的 `sendMessage` 以该错误抛出（`XPCConnection.swift:355-360`）。`connectionInvalid` 才是终态。

### 4. 平台事实

- **XPC service 只能被「自己 bundle 里带着它」的进程找到。** Apple 对 `NSXPCConnection.init(serviceName:)` 的说明是「XPC services are helper processes that are usually part of your application bundle」，查找基于调用进程的 main bundle（framework 内嵌的 service 亦然）。`runtime-viewer-cli` 是 `Contents/Applications/` 下的裸可执行文件，测试进程是 `xctest`，二者的 main bundle 都不是 App，拿不到 `Contents/XPCServices/` 下的 service。iOS 没有 XPC service（SwiftyXPC 整个模块 `#if os(macOS) || targetEnvironment(macCatalyst)`）。
- **项目里没有任何 `.xpc` target**：`RuntimeViewerUsingAppKit.xcodeproj` 的产物类型只有 application / bundle / tool（`project.pbxproj` 的 `PBXNativeTarget` 列表）。与 Catalyst helper、Simulator 载荷不同，macOS XPC service 是普通 target 依赖，Xcode 自己构建并用「Embed XPC Services」阶段嵌入，`RunScript.sh` / `ArchiveScript.sh` 无需改动。
- **App 已带 `com.apple.security.cs.disable-library-validation`**（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.entitlements`），否则 hardened runtime 下 `dlopen` 非 Apple / 非同 Team 签名的镜像会被拒绝。service 接管 `dlopen` 后必须带同一条。
- **bundle identifier 按配置区分**：`Configurations/CodeSigning.xcconfig:7-9` 定义了 Debug / Debug-arm64e / Release 三个 App ID（`dev.JH.RuntimeViewer`、`dev.JH.RuntimeViewer.arm64e`、`com.JH.RuntimeViewer`）。XPC service 按 App 实例查找，三个变体各带各的 `.xpc`，不会像 Mach service 名那样串台（对比 `Documentations/ResolvedIssues/2026-09-09-catalyst-helper-wrong-daemon.md`）。

### 5. 尚待验证（推测，实施第一步先证实）

- *推测（高置信）*：SwiftyXPC 的 `XPCConnection` 在收到 `.connectionInterrupted` 后无需重建即可继续 `sendMessage`，且这次发送会让 launchd 重新拉起 service——这是 libxpc 对具名 service 的既定语义，SwiftyXPC 的错误文档也这么写，但本仓库尚未在真实 `.xpc` 上实测。若不成立，重连改为「丢弃旧 `XPCConnection`、新建一条」，对本提案其它部分无影响。
- *推测*：XPC service 进程在 App 退出（最后一条连接失效）后由 launchd 终止，不需要 App 主动杀它。落地时用 Activity Monitor 确认。

## 提议方案

1. **新增 Xcode target `RuntimeViewerLocalRuntimeService`**（产物类型 XPC service），随 App 嵌入到 `Contents/XPCServices/RuntimeViewerLocalRuntimeService.xpc`，链接 `RuntimeViewerCore` 与 `RuntimeViewerCommunication`。它的 `main.swift` 只做三件事：构造一台**进程内** `RuntimeEngine(source: .local)` 并 `connect()`，用新的 `RuntimeLocalRuntimeServiceHost` 把它放到 `XPCListener(type: .service)` 上对外服务，然后 `activate()`（`xpc_main`，不返回）。
2. **`RuntimeEngine.local` 自己决定连不连 service**：`.local` 仍是身份，不加执行方式枚举、不加配置项。`RuntimeEngine.local` 的静态初始化用 `LocalRuntimeService.embeddedServiceCredential` 连接——进程自己的 `Info.plist` 里有 `RuntimeViewerLocalRuntimeServiceBundleIdentifier` 就得到 `.xpcService(.bundleIdentifier(id))`，走现成的 client 路径（建连、装 client handler、观察连接状态），`dispatch` 转发请求；没有就是 `nil`，走今天的进程内路径。App 有这个键，service 进程、CLI 独立 host、Catalyst helper、iOS、测试都没有，天然各归各位。身份、书签 scope、`identifier`、UI 图标——因为 `source` 未变而原样保留。（聚合改法，见决策日志。）
3. **通信层新增一对 `RuntimeConnection` 实现**：`RuntimeXPCServiceClientConnection`（App 侧，包一条 `XPCConnection(type: .remoteService(bundleID:))`）与 `RuntimeXPCServiceListenerConnection`（service 侧，包一个 `XPCListener`）。二者直接建在 SwiftyXPC 上，不经 `HelperPeer`，不经 daemon。`RuntimeConnectionCredential` 加 `.xpcService(target)`，`RuntimeCommunicator.connect(to: .local, credential:)` 带它时交出连接（评审后改法，见决策日志）。
4. **从 `RuntimeEngineProxyServer` 抽出 `RuntimeEngineConnectionServer`**：「在一条连接上服务一台引擎」的共同部分（注册共享命令表、转发四种推送、推初始数据），ProxyServer 与新 host 共用；顺手补上 ProxyServer 今天漏掉的 `imageDidLoad` 转发。
5. **握手与初始数据**：握手是传输层自己的 `hello` 消息（`RuntimeXPCServiceConnection.helloMessageName`），client 建连时和每次重连时发；listener 收到即认领 peer 并报 `.connected`，host 在这个状态变化上推 imageList / imageNodes / `.fullReload`——与 TCP 共享今天给新 client 推初始数据是同一条机制。引擎不知道有握手这回事。
6. **崩溃恢复**：全在 `RuntimeXPCServiceClientConnection` 里。它把 `.connectionInterrupted` 报成 `.disconnected(error:)`，然后自己重发 `hello`（退避 1s / 2s / 4s 共三次），成功即报 `.connected`；三次都失败则停在 `.disconnected`，之后任何一条消息先补一次 `hello` 再发。引擎只看到连接 `.disconnected → .connected`，和别的传输回来时一样；管理器本来就不观察 `.local` 的状态，所以不会删它。文档层看到自己引擎「由不可用回到可用」后走 `.switchEngine` 重置回镜像列表根；通知服务直接观察 `RuntimeEngine.local` 的这条边沿发系统通知。打崩 service 的那次 `loadImage` 以错误返回给调用方，不重试。
7. **管理器与 App 层不动**：管理器、配置、事件、资源定位器、`Document`、CLI 都是原样——「My Mac」仍是 `RuntimeEngine.local`，只是它在 App 里连的是 service。App 侧唯一的行为改动是「Load Frameworks…」改走 `engine.loadImage(at:)`（原来是在 App 进程里 `Bundle.load`）。

### 非目标

- **不改 iOS App、包测试、`runtime-viewer-cli` 独立 host**：三者继续用进程内 `.local`（见前期调研 §4 的查找规则）——它们的 bundle 里没有 service 键，`RuntimeEngine.local` 自动留在进程内。
- **不新增 `RuntimeSource` case，不改任何线路协议或引擎描述符**：对端（含旧版本 iOS / macOS）看到的「My Mac」与今天完全一致。
- **不动 Mac Catalyst helper、特权 daemon、注入流程、Bonjour 与镜像逻辑**。
- **不自动重新加载崩溃前已加载的镜像**（用户已否决，见决策日志）。
- **不给 service 开 App Sandbox**：引擎要读任意路径的 Mach-O 并 `dlopen`，沙盒下 `file-map-executable` 会拒绝（0014 的 `SandboxProbe` 记录了这一点）。
- **不提供「回退到进程内」的设置开关**：留着开关等于留着危险路径；调试需要时用测试与 CLI 独立 host 已有的进程内引擎。
- **不搬 MCP bridge**：它用的是文档的引擎，自动跟着走。

## 详细设计

### 1. 通信层（`RuntimeViewerCommunication`，仅 macOS）

`Package.swift` 给 `RuntimeViewerCommunication` 加一条对 `SwiftyXPC` 产品的直接依赖（同一个 fork、同一 revision，不引入新版本）。

```swift
// Connections/RuntimeXPCServiceConnection.swift
#if os(macOS)

/// Where an XPC-service client connects to.
public enum RuntimeXPCServiceTarget: Sendable, Hashable {
    /// The embedded service, looked up by launchd in the calling process's bundle.
    case bundleIdentifier(String)
    /// An anonymous listener living in some process — the test seam: both ends
    /// of a `RuntimeXPCService*Connection` pair can then sit in one `xctest`.
    case anonymousListener(RuntimeXPCServiceEndpoint)
}

/// A `Sendable` wrapper over SwiftyXPC's `XPCEndpoint`, so SwiftyXPC stays
/// an implementation detail of this module's public surface.
public struct RuntimeXPCServiceEndpoint: Sendable { … }

/// App side. One `XPCConnection`, activated in `init`, kept for the life of
/// the engine. `init` ends with a `hello` round trip — reaching the service
/// is what makes this a connection. An interruption (SwiftyXPC
/// `XPCError.connectionInterrupted`) is reported as `.disconnected(error:)`,
/// then the connection reattaches on its own: `hello` after 1 s / 2 s / 4 s,
/// and once those are spent, one more `hello` in front of the next message.
/// `.connected` follows the `hello` that gets through.
public final class RuntimeXPCServiceClientConnection: RuntimeXPCServiceConnection {
    init(target: RuntimeXPCServiceTarget, modifier: ((RuntimeXPCServiceClientConnection) async throws -> Void)?) async throws
    var isUsable: Bool   // false after stop() or connectionInvalid — the two terminal cases
    func stop()          // cancels the reattach and the XPCConnection
    // sendMessage / setMessageHandler: JSON payload in, RuntimeXPCServiceReplyFrame out
}

/// Service side. Wraps an `XPCListener` (`.service` in the real service,
/// `.anonymous` in tests). Handlers registered here land on every accepted
/// connection; the `hello` handler the listener installs itself adopts the
/// sender as the peer pushes go to and reports `.connected` — every newly
/// adopted peer, a replacing one included. That transition is what the host
/// pushes its current data on.
public final class RuntimeXPCServiceListenerConnection: RuntimeXPCServiceConnection {
    static func embeddedService() throws -> Self        // XPCListener(type: .service)
    static func anonymous() throws -> (Self, endpoint)  // the test seam
    func activate()   // must run after every setMessageHandler — SwiftyXPC copies handlers at accept time
}

#endif
```

状态映射：client 侧 `errorHandler` 收到 `.connectionInterrupted` → `.disconnected(error: .xpcError(…))` 并启动重连；`.connectionInvalid` → `.disconnected(error:)` 且标记终态（不再重连）；任一往返成功（首先是 `hello`）→ `.connected`。service 侧：认领新 peer → `.connected`；peer 的 `errorHandler` 报错 → `.disconnected`。**握手与重连到此为止**——引擎那一侧只看到 `.disconnected → .connected`。

`RuntimeConnectionCredential` 加一个 case，`RuntimeCommunicator` 不加新入口：

```swift
public enum RuntimeConnectionCredential {
    …
    case xpcService(RuntimeXPCServiceTarget)   // macOS
}
// connect(to: .local, credential: .xpcService(target)) → RuntimeXPCServiceClientConnection
// connect(to: .local)                                   → 仍抛 localConnectionNotSupported
```

`.local` 本身不描述传输；要连哪个 service 是会话级信息，与 Bonjour 端点同属凭证，所以分发留在工厂那一个 `switch` 里。

### 2. 引擎（`RuntimeViewerCore`）

引擎本体不出现任何 XPC 类型。三处改动：

- `connect(credential:)` 新增分支：`source == .local` 且带凭证时，记 `forwardsToLocalService = true`、`stateSubject.send(.connecting)`，然后走与 `.client` 角色**同一段** `connectAsClient(credential:)`（`communicator.connect(to: .local, credential:)`，modifier 里 `setupMessageHandlerForClient()` + `observeConnectionState(connection)`）→ `stateSubject.send(.connected)`。不带凭证的 `.local` 不变（`observeRuntime()` → `.localOnly`）。
- 只读属性 `forwardsRequests: Bool` = `source.remoteRole?.isClient == true || forwardsToLocalService`。`dispatch(_:)` 与 `dispatch(_:onProgress:)` 的 `remoteRole.isClient` 判断改用它；`broadcast` / `sendRemoteImageDidLoadIfNeeded` 的 server 判断不动（service 里那台引擎是进程内引擎，对外推送由 `RuntimeEngineConnectionServer` 负责）。
- `RuntimeEngine.local` 的静态初始化改为 `connectReportingFailure(credential: LocalRuntimeService.embeddedServiceCredential)`。

`LocalRuntimeService`（`RuntimeViewerCore/LocalRuntimeService/LocalRuntimeService.swift`）是 XPC service 在 Core 里的唯一落点：

```swift
public enum LocalRuntimeService {
    /// The app Info.plist key naming the embedded service's bundle identifier.
    public static let bundleIdentifierInfoDictionaryKey = "RuntimeViewerLocalRuntimeServiceBundleIdentifier"
    /// The service this process's bundle declares, or nil.
    public static var embeddedServiceBundleIdentifier: String?
    /// What RuntimeEngine.local connects with: .xpcService(.bundleIdentifier(id)), or nil.
    public static var embeddedServiceCredential: RuntimeConnectionCredential?
}
```

为什么读 `Info.plist` 而不是让 App 启动时设一个全局开关：开关必须「先设后读」，而 `RuntimeEngine.local` 谁先碰到谁触发连接——arm64e 变体开关就栽过这个跟头（[2026-09-18-arm64e-variant-selected-after-window-restoration](../ResolvedIssues/2026-09-18-arm64e-variant-selected-after-window-restoration.md)）。bundle 本身就是配置：launchd 只在调用进程自己的 bundle 里找内嵌 service，所以「bundle 里有没有这个键」与「这个进程能不能连到 service」是同一件事。

- **声明了 service 却连不上，不回退**：`hello` 拿到 `XPCError.connectionInvalid`（只会出现在没把 service 嵌进去的坏构建里）时，`connectReportingFailure` 记 error 日志，引擎停在 `.connecting`、每个请求报 `senderConnectionIsLose`。不静默退回进程内——那正是要消除的危险路径。
- **重连不在引擎里**：见 §1 的 client 连接。引擎对连接状态的反应是现成的 `handleConnectionStateChange`：`.disconnected` → `stateSubject.send(.disconnected)`，`.connected` → `stateSubject.send(.connected)`。
- `reloadData(isReloadImageNodes:)`：在转发引擎上转发（`ReloadDataRequest` 进共享命令表），本地臂改名 `reloadLocalData`，见决策日志。
- **`RuntimeEngineConnectionServer`**（新文件，从 `RuntimeEngineProxyServer` 抽出）：

```swift
public actor RuntimeEngineConnectionServer {
    public init(engine: RuntimeEngine, connection: any RuntimeConnection, label: String)
    public func registerRequestHandlers()   // RuntimeEngine.registerSharedHandlers
    public func installPushRelay()          // imageNodes / dataChange (+ imageList on fullReload) / imageDidLoad
    public func sendInitialData() async     // imageList, imageNodes, fullReload
    public func stop()
}
```

  `RuntimeEngineProxyServer` 改为持有一个它，只保留 directTCP 建连、图标应答与描述符相关逻辑，行为不变（多出的 `imageDidLoad` 转发是修正，不是回归）。

- **`RuntimeLocalRuntimeServiceHost`**（`LocalRuntimeService/RuntimeLocalRuntimeServiceHost.swift`，`#if os(macOS)`）：`init(engine:connection:)` 接一个 `RuntimeXPCServiceListenerConnection`（service 里用 `.embeddedService()`，测试里用 `.anonymous()`），`start()` 先 `engine.connect()`、再登记命令表与推送转发、再订阅 listener 的 `statePublisher`——每次变 `.connected`（一个 client 认领成功）就 `sendInitialData()`；`activate()` 才是 `xpc_main`。service 的 `main.swift` 在后台 Task 里 `await start()`，主线程用信号量等它结束后再 `activate()`——不能在顶层 `await` 之后直接进 `xpc_main`，那会从主队列正在执行的 block 里调用 `dispatch_main`。

### 3. XPC service target

- 目录 `RuntimeViewerUsingAppKit/RuntimeViewerLocalRuntimeService/`：`main.swift`、`Info.plist`（`XPCService` 字典：`ServiceType = Application`，`RunLoopType` 取默认 `dispatch_main`）、`RuntimeViewerLocalRuntimeService.entitlements`（hardened runtime 下 `com.apple.security.cs.disable-library-validation = true`，不开沙盒）。
- `Configurations/CodeSigning.xcconfig` 新增三个 `RUNTIME_VIEWER_LOCAL_RUNTIME_SERVICE_*_BUNDLE_IDENTIFIER`，值为对应 App ID 加 `.LocalRuntimeService`；App 的 `Info.plist` 加键 `RuntimeViewerLocalRuntimeServiceBundleIdentifier` 指向它，运行时由 `LocalRuntimeService.embeddedServiceBundleIdentifier` 从 `Bundle.main` 读出——与 Catalyst helper 记录 `RuntimeViewerServiceName` 是同一手法。
- 部署目标与 App 同为 macOS 15.0。**架构跟 App 的切片走，不跟 daemon 走**：Debug-arm64e 配置下 App 本身是 arm64（`ENABLE_POINTER_AUTHENTICATION = NO`），只有 daemon 与注入载荷是 arm64e；今天在 App 进程里跑的本地引擎就是 arm64 的，service 保持同样的设置即可，加载能力不变。
- App target 加对该 target 的依赖与「Embed XPC Services」拷贝阶段（`dstSubfolderSpec = 16`）。项目文件改动按 `xcode-build-and-test` skill 规定的工具走。

### 4. 引擎管理（`RuntimeViewerEngineManagement`）

**不改。** 管理器一直只是把 `RuntimeEngine.local` 追加进 `systemRuntimeEngines`、从不观察它的状态，这两点在 service 版本里正好都是对的：追加的还是同一个对象（它自己决定连哪里），不观察意味着 service 退出时引擎不会被当成「对端没了」删掉。第一版实现里的配置项 `localEngineExecution`、`localRuntimeEngine` 属性、`RuntimeResourceLocating.localRuntimeServiceBundleIdentifier`、`.localRuntimeRestarted` 事件在聚合时全部撤掉（见决策日志）。无头 CLI host 的 `Bundle.main` 是裸可执行文件，没有那个键，自动留在进程内。

### 5. 应用层（`RuntimeViewerApplication` / App target）

- `DocumentState.init(runtimeEngine: RuntimeEngine = .local)`：默认值不变，参数只为测试注入引擎；`Document` 不传。
- `DocumentState` 订阅自己引擎的 `statePublisher`：`isReady` 由 `false` 变回 `true` 时，对自己触发 `.switchEngine(runtimeEngine)`——路由自己的 guard 让「什么都没开」时成为 no-op，首次连接因此不算重启。用 `isReady` 而不是具体 case，进程内引擎 `stop()` → `connect()` 得到的是 `.localOnly`，测试可以不依赖 XPC 复现这条路径。
- `RuntimeConnectionNotificationService.start()` 除订阅管理器事件外，直接观察 `RuntimeEngine.local.statePublisher`：`.disconnected` 之后的第一个 `.connected` 发「Local Runtime Restarted」通知；首次 `.connected` 不发。
- `MainViewModel`：「Load Frameworks…」改走 `documentState.runtimeEngine.loadImage(at:)`；其余不动。
- 后台索引：`RuntimeBackgroundIndexingCoordinator` 在引擎重启后不能沿用崩溃前的「已索引」结论。落地时核对它是否缓存了 `isImageIndexed` 结果；若有，引擎重新就绪时清空。

### 6. 错误呈现

client 连接把 `XPCError.connectionInterrupted` 包成 `RuntimeConnectionError.xpcError("The local runtime exited while handling this request.")`，让 `errorRelay` 弹出的 alert 说清楚发生了什么，而不是一句 `Connection interrupted`。

### 7. 测试

- `RuntimeViewerCommunicationTests/RuntimeXPCServiceConnectionTests`：用 `.anonymous` 监听器 + `.anonymousListener(endpoint)` 目标，在测试进程内跑通请求 / 响应、service→client 推送、状态映射、`.local` 经凭证取连接。
- `RuntimeViewerCommunicationTests/RuntimeXPCServiceClientConnectionReattachTests`：建连即 `.connected`（`hello` 已发）；`simulateInterruptionForTesting()` 后 `.disconnected` → 自动 `hello` → `.connected`；`setHelloFailureForTesting` 让三次都失败后停下、下一条消息先补 `hello`；`stop()` 后不重连。真实 XPC 连接只有 service 进程真的死了才报中断，所以中断用 `@testable` 缝模拟。
- `RuntimeViewerCoreTests/RuntimeLocalRuntimeServiceHostTests`：`RuntimeLocalRuntimeServiceHost` 喂匿名监听器，`.local` 引擎以 `.xpcService(.anonymousListener(…))` 凭证 `connect`：收到 service 的 imageList / imageNodes、`loadImage(libobjc)` 经转发完成且 dlopen 只发生在 host 引擎、`imageDidLoad` 回推、第二个 client 也拿到初始数据、不带凭证的 `.local` 留在进程内。
- `RuntimeViewerApplicationTests/DocumentStateEngineRestartTests`：`DocumentState` 在引擎 `stop()` → `connect()` 后回到根（进程内引擎即可）；首次连接不重置；换引擎后跟着换。
- **人工验收**（写进落地步骤）：Activity Monitor 里 `kill -9` service 进程 → App 存活、侧栏回根、收到通知、再点 Foundation 能重新加载；加载一个构造函数里 `abort()` 的测试 dylib → alert 报错、App 存活。

## 替代方案考量

- **新增 `RuntimeSource.xpcService(name:identifier:role:)`**：语义上与 `.remote` 平行，`RuntimeCommunicator` 顺势接入。否决：约 10 处 `switch` 要改，`identifier`、`RuntimeBookmarkScope`、发给对端的描述符三处都得伪装成 `.local` 才能保住兼容——旧版本对端解不出新 case 时整张引擎列表解码失败。三处伪装说明身份本来就是 `.local`，变的只是执行方式。
- **`NSXPCConnection` + `@objc` 协议**：Apple 官方样板。否决：每条命令一个协议方法，与现有名字消息、进度 token 路由、共享命令表全部不合，等于重写请求层。
- **XPC 只负责拉起进程，数据走 localhost TCP（`RuntimeDirectTCPConnection` + `RuntimeEngineProxyServer`）**：复用最多。否决：多一条 socket 与两套生命周期，XPC 退化成启动器，崩溃恢复要同时处理两条通道。
- **经特权 daemon 的 `HelperPeer`（今天 Catalyst helper 的路）**：否决：用户明确不要 Mach service 与 daemon；而且没装 helper 的用户会连「My Mac」都没有。
- **`Process` 子进程 + `RuntimeStdioConnection`**：不依赖 XPC，CLI 独立 host 将来也能用。否决（本次）：子进程生命周期、僵尸进程、崩溃后的重拉都要自己管，launchd 免费提供的正是这些；记录在此作为 CLI host 日后隔离本地引擎的候选。
- **自动重新加载崩溃前的镜像**：体验最顺。否决：重放可能再次触发同一崩溃，且要在 App 侧维护一份「已加载集合」与 service 的真实状态赛跑。
- **不自动恢复、加「Restart Local Runtime」菜单项**：最可控。否决：用户得自己动手；有限重试 + 按需重连覆盖了同样的场景且不加 UI。

## 影响

### 用户可见变化

- 正常使用下无变化：「My Mac」的名称、图标、位置、镜像列表、加载与浏览行为都与今天相同。
- Activity Monitor 里会多一个 `RuntimeViewerLocalRuntimeService` 进程，索引占用的内存记在它名下而不是 App。
- 本地运行时崩溃时 App 不再退出：侧栏回到镜像列表，收到一条「Local runtime restarted」系统通知，之前加载的镜像需要重新加载；导致崩溃的那次加载以错误 alert 结束。
- 每个请求多一次 XPC 往返。Mac Catalyst 运行时走的就是同类路径，量级可接受；落地时用 Instruments 对比一次 Foundation 的加载与类列表耗时。

### 可发现性

无新增入口、无设置项。默认开启且不提供关闭开关（见非目标）。

### 数据与配置兼容

- 书签与侧栏 autosave 的键由 `RuntimeBookmarkScope.Identity.local` 派生，`source` 未变，键不变。
- `settings.json`、文档格式、接口缓存不受影响。
- 发给 Bonjour 对端的引擎描述符不变，旧版本对端照常镜像这台引擎。

### 平台与最低版本

- macOS 最低版本仍为 15.0；service target 与 App 同一部署目标。
- iOS App 行为不变（继续进程内）。Mac Catalyst helper 不变。

### 发布

- 新增一个嵌套 bundle：`ArchiveScript.sh` 的 `-exportArchive` 与公证会一并处理嵌入的 XPC service，无需改脚本；Sparkle 更新包里它随 App 一起打包。
- service 的 entitlements：hardened runtime + `disable-library-validation`（与 App 一致），不开沙盒；无新增隐私清单条目（落地时对照 App 现有声明复核一次）。
- `main` 上必须能对着已发布的远端 pin 编译：SwiftyXPC 已在 `Package.resolved` 里，本提案只是把间接依赖变成直接依赖，不需要新版本。

## 落地步骤

每一步单独可构建、可验证。

1. **通信层**：`RuntimeXPCServiceTarget` / `RuntimeXPCServiceEndpoint`、`RuntimeXPCServiceClientConnection` / `RuntimeXPCServiceListenerConnection`、`RuntimeConnectionCredential.xpcService`；`Package.swift` 加 SwiftyXPC 直接依赖。测试：匿名监听器上的连接对。**先在这一步用真实 `.xpc`（一个只回 echo 的临时 service，不进仓库）证实前期调研 §5 的两条推测**，把结论写回本提案。
2. **引擎与 service host**：`.local` 带凭证走 client 路径、`forwardsRequests`、`LocalRuntimeService`、`RuntimeEngineConnectionServer` 抽取（ProxyServer 改用）、`RuntimeLocalRuntimeServiceHost`。测试：匿名监听器上的端到端；重连在通信层单独测。
3. **service target**：目录、`Info.plist`、entitlements、xcconfig 的 bundle ID、App Info.plist 键、目标依赖与嵌入阶段。验收：`./RunScript.sh --no-launch` 后 `Contents/XPCServices/RuntimeViewerLocalRuntimeService.xpc` 存在且 `lipo -info` 含 arm64e；`codesign -dv` 显示 hardened runtime 与 entitlements。
4. **引擎管理**：不改。跑一遍 CLI 包测试确认独立 host 仍在进程内。
5. **应用层**：`DocumentState` 重置、通知服务直接观察本地引擎、`MainViewModel` 的 Load Frameworks、后台索引缓存核对。测试：DocumentState 重置。
6. **人工验收**：`kill -9` service；构造函数 `abort()` 的 dylib；Instruments 对比加载耗时；Activity Monitor 确认 App 退出后 service 消失。
7. **文档**：`CommunicationAndEngineArchitecture.md` §1 / §3 / §5 / §7、`AGENTS.md`（Application Targets 加 service；Architecture 说明本地引擎在进程外）、`Documentations/README.md` 与提案索引；本提案状态推进并补决策日志。

### 验证记录（2026-09-21）

| 步骤 | 状态 | 证据 |
|------|------|------|
| 1 通信层 | 完成 | `RuntimeXPCServiceConnectionTests` 7 例 + `RuntimeXPCServiceClientConnectionReattachTests` 4 例通过（匿名监听器上的往返、推送、远端错误、终态、无 handler、`.local` 经凭证取连接；建连即 `hello`、中断后自动重连、三次失败后按需补 `hello`、`stop()` 后不重连） |
| 2 引擎与 service host | 完成 | `RuntimeLocalRuntimeServiceHostTests` 4 例通过：收到 service 的初始数据、`loadImage` 经转发完成且 dlopen 只在 host 引擎、第二个 client 也拿到初始数据、不带凭证的 `.local` 留在进程内；`InjectedEndpointAnnouncementTests` 改名后通过。`RuntimeEngine` 里不再有任何 XPC 类型 |
| 3 service target | 完成 | `DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer ./RunScript.sh --no-launch` 通过；产物 `Contents/XPCServices/RuntimeViewerLocalRuntimeService.xpc`：`CFBundleIdentifier` = `dev.JH.RuntimeViewerLocalRuntimeService.arm64e`、`XPCService.ServiceType` = Application、`lipo` 为 arm64（与 App 切片一致）、`codesign` 带 `runtime` 标志与 `disable-library-validation`、无沙盒；App `Info.plist` 的 `RuntimeViewerLocalRuntimeServiceBundleIdentifier` 已填入同一 ID。本机默认 `Xcode.app`（26.6）编不过 `next`：工作区钉的 UIFoundation 0.34.0 用了 macOS 27 API，与本提案无关 |
| 4 引擎管理 | 完成（不改） | 管理器、配置、事件、资源定位器、CLI 两个文件全部回到 `next` 原样；CLI 包 121 例通过（独立 host 仍进程内） |
| 5 应用层 | 完成 | `DocumentStateEngineRestartTests` 3 例通过（回根、首次连接不重置、换引擎跟着换）；`RuntimeViewerPackages` 全量 277 例通过（比第一版少的 3 例是撤掉的管理器测试）；`Document.swift` 回到原样，`MainViewModel` 只剩 Load Frameworks 一处改动 |
| 6 人工验收 | **未做，留给用户** | `kill -9` service、构造函数 `abort()` 的 dylib、Instruments 对比、App 退出后 service 消失——都要在真实 App 里做，agent 不启动 GUI |
| 7 文档 | 完成 | 架构文档 §1 / §3.0 / §3.6 / §5 / §7.1 / §12、`AGENTS.md`、术语表、提案索引 |

`RuntimeViewerCore` 全量 483 例中另有 1 例失败：`RelationshipsEquivalenceSnapshotTests` 的 Swift 基线（`Decimal.FormatStyle` 被渲染成 `NSDecimal.FormatStyle`）。在未改动的 `next` 检出上同样失败，是本地 MachOSwiftSection / swift-demangling 检出相对基线的漂移，与本提案无关。

前期调研 §5 的两条推测（中断后同一条 `XPCConnection` 可续用并由 launchd 重拉 service；App 退出后 service 自行消失）**仍是推测**：它们只能在真实 App 里验证，随第 6 步一起做。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计需要一篇实现说明：「service 侧 handler 必须在 `activate()` 前登记」「`hello` 既是握手也是重连探针」「`RuntimeEngine.local` 为什么读自己的 `Info.plist` 决定去向」都是从签名看不出来的契约。
- **有没有引入新术语** —— `RuntimeLocalRuntimeService`（本地运行时 service）需登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-21 | Created as Draft | 用户原话：「目前 RuntimeEngine 的 local 很危险，改成启动一个轻量的 XPCService 来解决，不需要 MachService 和 daemon，普通的 XPCService 即可」。 |
| 2026-09-21 | 引擎身份保留 `.local`，新增执行方式维度 | 用户在「保留 `.local` + 执行方式」与「新增 `RuntimeSource.xpcService`」之间选前者：UI、CLI `--source local`、书签 / autosave 键、对端描述符全部不变，避免三处伪装与旧对端解码失败。 |
| 2026-09-21 | 传输用 SwiftyXPC 直连 | 否决 `NSXPCConnection` + `@objc` 协议（重写请求层）与「XPC 只拉起、数据走 TCP」（两套生命周期）。 |
| 2026-09-21 | 崩溃后同一引擎对象自动重连，镜像丢失、发系统通知 | 否决「自动重放已加载镜像」（可能再次触发崩溃）与「手动重启菜单」（要用户动手）。打崩 service 的那次 `loadImage` 以错误返回，不重试。 |
| 2026-09-21 | 只改 macOS App | iOS 无 XPC service；测试进程与 CLI 独立 host 拿不到 App 包里的 `.xpc`。App 在跑时 CLI 走 App host，本就受保护。 |
| 2026-09-21 | 重连后文档回到镜像列表根 | 复用 `.switchEngine` 重置路径；否决「保持原地按需重载」（请求路径加逻辑、大镜像重载像卡住、会再次加载打崩 service 的镜像）与「只弹通知」。 |
| 2026-09-21 | 重试策略：3 次退避后按需重连 | 否决无限重试（起不来时后台空转）与失败即停 + 菜单项（多一个 UI 入口）。 |
| 2026-09-21 | 默认假设（用户确认「不反对即采用」） | service 不开沙盒、hardened runtime 带 `disable-library-validation`；target 名 `RuntimeViewerLocalRuntimeService`，bundle ID 按配置挂在 App ID 下；service 侧复用「进程内引擎 + 共享命令表」；`RuntimeEngine.local` 保留给 iOS / 测试 / CLI；分支从 `next` 切出；提案同批更新架构文档与 `AGENTS.md`。 |
| 2026-09-21 | Draft → Accepted → In Progress | 用户审阅后回复「可以开始，target 帮你创建好了」：批准实施，并已在 Xcode 里创建 `RuntimeViewerLocalRuntimeService` target（Xcode 模板产物，见落地步骤 3 的调整）。 |
| 2026-09-21 | Xcode 模板的 target 设置改了四处 | 模板默认 `ENABLE_APP_SANDBOX = YES` / `REGISTER_APP_GROUPS = YES`——按非目标去掉沙盒；加 entitlements 文件与 `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION`；bundle ID 从字面量改为 `CodeSigning.xcconfig` 的三个变量；模板 `main.swift` 用的是系统的 `XPCListener(service:)` Swift API，整个换成 SwiftyXPC 路线。模板生成的 `RuntimeViewerLocalRuntimeServiceTypes.swift` 删除。 |
| 2026-09-21 | service 的架构跟 App 切片一致（arm64），不做 arm64e | 提案初稿写「Debug-arm64e 必须产出 arm64e 的 service」是错的：该配置下 App 自己就是 arm64，本地引擎一直以 arm64 运行；service 沿用即可。详细设计 §3 已改。 |
| 2026-09-21 | `reloadData(isReloadImageNodes:)` 改为在转发引擎上转发 | 实现时发现它直接读**本进程**的 dyld 列表并覆盖 `imageList`——放在转发引擎上会把 App 自己的镜像列表写进 service 的镜像。新增 `reloadData` 命令进共享命令表，公开方法变 `async`，本地臂改名 `reloadLocalData`。Catalyst client 引擎顺带受益。 |
| 2026-09-21 | 「Load Frameworks…」改走 `engine.loadImage(at:)` | 原实现是 `Bundle(url:).loadAndReturnError()`——在 App 进程里 `dlopen`，正是本提案要消除的路径。改为取 bundle 的 `executableURL` 交给文档的引擎加载。 |
| 2026-09-21 | `attachClient` 既是握手也是重连探针 | `RuntimeXPCServiceListenerConnection` 以第一条进来的消息认领 peer，所以 client 建连后必须先说话；让这句话顺便带回快照，重连时同一条消息即可判定 service 活着并同步状态。 |
| 2026-09-21 | 不另写实现说明；术语已登记 | 从签名看不出来的契约（handler 先于 `activate()`、`attachClient` 一句两用、本地引擎断连豁免、`main.swift` 的信号量）全部写进了 `CommunicationAndEngineArchitecture.md` §3.6 与 §5，再写一篇只会复述；「本地运行时 service」「执行方式（`LocalExecution`）」两条已进 `Glossary.md`。 |
| 2026-09-21 | 评审改法：XPC service 连接走 `credential:`，不另开工厂入口 | 用户指出 `RuntimeCommunicator.connect(to:)` 的 `.local` 分支正是该放逻辑的地方。原先另起 `connectToXPCService(_:)` 只因 `.local` 没有关联值；而 `RuntimeConnectionCredential` 本来就是给「不属于身份、连接时才有」的信息用的（Bonjour 端点、XPC 重连端点）。改为加 `.xpcService(target)` 凭证，`.local` 带它时交出连接，不带仍抛错；引擎与测试缝相应改调 `connect(to:credential:)`。行为不变，`RuntimeXPCServiceConnectionTests` 加一例覆盖两条路径。 |
| 2026-09-21 | 独立 `swift build` 的前置条件：`.worktrees/swift-helper-service` 符号链接 | 从任何 worktree 单独解析 `RuntimeViewerCore` 都会失败（远端 `swift-helper-service` 0.3.3 依赖 branch 版的 MachInjector，SwiftPM 拒绝稳定版依赖不稳定版），与本提案无关；按 `create-worktree` skill 补了指向 `Personal/Library/macOS/swift-helper-service` 的链接后通过。首次解析还要 `--manifest-cache none`，否则回放补链接前的求值。 |
| 2026-09-21 | 评审改法：XPC 逻辑从 `RuntimeEngine` 撤出，聚合到两个家 | 用户两条意见：「不要把 xpc 的逻辑往 Engine 塞」「xpc 改的地方太多了，要聚合起来」。散落的根因是 App 里「My Mac」必须是不同于 `RuntimeEngine.local` 的实例，于是管理器、配置、事件、资源定位器、`Document`、`MainViewModel`、`DocumentState` 注入、CLI 穷举全跟着改。改为 `RuntimeEngine.local` 自己按进程 bundle 决定连不连 service 后，这些全部回到 `next` 原样。XPC 逻辑只剩两处：`RuntimeXPCServiceConnection.swift`（传输 + `hello` + 重连）与 `RuntimeViewerCore/LocalRuntimeService/`（`Info.plist` 键与凭证、service 侧 host）。引擎删掉 `LocalExecution`、connector 测试缝、重连状态机、`attachClient` 与 `RuntimeEngineSnapshot`、`dispatch` 里的按需重连；术语表撤掉「执行方式（`LocalExecution`）」。 |
| 2026-09-21 | 握手降为传输层 `hello`，重连搬进 client 连接 | 引擎不该知道 XPC：`attachClient` 快照握手换成 `RuntimeXPCServiceConnection.helloMessageName`，listener 认领 peer 时报 `.connected`，host 借此推初始数据（TCP 共享给新 client 推初始数据的同一机制）；退避重连与按需补 `hello` 全在 `RuntimeXPCServiceClientConnection`。引擎只看到 `.disconnected → .connected`。 |
| 2026-09-21 | `.local` 连不连 service 由进程 `Info.plist` 决定，不加配置项 | 否决「App 启动时设全局开关」（先设后读的时序坑，arm64e 变体开关的前车之鉴）与保留 `LocalEngineExecution` 配置（管理器不再需要造引擎）。bundle 即配置：launchd 只在调用进程自己的 bundle 里找 service。代价：Core 里出现一次 `Bundle.main` 读取（`LocalRuntimeService.embeddedServiceBundleIdentifier`）。 |
| 2026-09-21 | 重启通知改由通知服务直接观察 `RuntimeEngine.local` | 管理器从不观察 `.local`，为它加观察 + 事件 + CLI 穷举是三处散落；通知服务本就是「连接事件 → 系统通知」的落点，直接看引擎状态的 `.disconnected → .connected` 边沿即可。 |
| 2026-09-21 | `RuntimeXPCConnection` 改名 `RuntimeXPCMachServiceConnection` | 用户要求：两族 XPC 连接并存后，经 daemon 的那族按传输实质命名（Mach service），子类同步为 `RuntimeXPCMachServiceClientConnection` / `RuntimeXPCMachServiceServerConnection`。历史文档（Plans / ResolvedIssues / KnownIssues）里的旧名保留，它们记录的是当时的状态。 |

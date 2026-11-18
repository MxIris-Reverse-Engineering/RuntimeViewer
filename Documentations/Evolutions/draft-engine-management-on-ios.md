# Draft - 引擎管理在 iOS 上可用

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-18
- **最后更新**: 2026-11-18
- **所属愿景**: [iOS 版功能对齐](../Visions/IOSFeatureParity.md)（第一步）
- **关联提案**: [0035-engine-management-module](0035-engine-management-module.md)（把引擎管理抽成无 UI 模块）、[0069-file-mode](0069-file-mode.md)（文件模式）、[0081-shared-cache-images-across-engines](0081-shared-cache-images-across-engines.md)（系统镜像跨引擎共享）
- **实现分支 / PR**: `feature/engine-management-on-ios`（worktree `.worktrees/RuntimeViewer-EngineManagementOnIOS`），做完一次合进 `next`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

让 `RuntimeViewerEngineManagement` 在 iOS（含越狱版）与 visionOS 上编译并可用，Mac 上的行为一点不变。只属于 macOS 的三块——内嵌 XPC service、特权 helper daemon、Mac Catalyst——收进带 `.live` 的闭包接缝，iOS 上的 `.live` 是「没有这项能力」；配置新增「浏览局域网」与「服务端推送运行时数据」两个开关和一份 iOS 用的 `.deviceApplication`；iOS 上文件引擎直接在 App 进程里读。iOS app 把今天手工建的两个引擎（本机引擎、给 Mac 连的 Bonjour 服务端）交给管理器启动，Mac 看到的设备与今天一样。在设备上自己附加进程、iOS 的界面都不在这一篇。

## 动机

完整动机见愿景《[iOS 版功能对齐](../Visions/IOSFeatureParity.md)》。这一步特有的：

- 愿景的第四步（AppCore 放开平台限定）里有 6 个文件卡在 `RuntimeEngineManager` 上，第五步的切换来源、文件模式也都要它。管理器不在 iOS 上可用，后面每一步都动不了。
- 管理器整个只在 macOS 上编（五个文件第一行都是 `#if os(macOS)`），可真正的 macOS 依赖只占约 350 / 2272 行。为了这 15% 把其余 85% 也挡在 iOS 外面，iOS app 只好自己手工建引擎（`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/AppDelegate.swift:26-51`），和 Mac 走两套代码。

## 前期调研

**管理器里只属于 macOS 的地方**（逐处核对过，行号指 `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/RuntimeEngineManager.swift`）：

| 位置 | 用到什么 | 只在 macOS 的原因 |
|------|----------|-------------------|
| `:6` | `import ServiceManagement` | 文件里没有用到，iOS SDK 也没有这个框架 |
| `:12-13` | `import RuntimeViewerHelperClient`、`RuntimeViewerCatalystExtensions` | 两个模块只在 AppKit 平台链接（`Package.swift:567-568`），HelperClient 的 8 个文件都是 `#if os(macOS)` |
| `:98-100` | `fileEngineCredential` 默认值调 `RuntimeFileService.credential(for:)` | `RuntimeFileService` 与 `RuntimeFileServiceHost` 是 `#if os(macOS)`（XPC 那一层） |
| `:209-218` | `@Dependency` 的 `helperServiceManager`、`runtimeHelperClient`、`runtimeInjectClient` | key 声明在 HelperClient |
| `:282-343` | `MacCatalystLaunching.live`：`MacCatalystRuntimeService.embeddedServiceCredential`、经 daemon 启动 helper | Catalyst 与 helper daemon |
| `:372` | `RuntimeSharedCacheEligibility.live.sharesThisProcessSharedCache()` | 探针 `ProcessTranslationProbe`、`ProcessEnvironmentProbe` 在 HelperClient |
| `:405`、`:421-428` | 订阅 `helperServiceManager.daemonAvailabilityPublisher`（`AnyPublisher<Void, Never>`，`HelperServiceManager.swift:86`） | helper daemon |
| `:1430-1465` | `reconnectInjectedXPCEngines()`：`runtimeInjectClient.fetchAllInjectedEndpoints()`、`.xpcServer` 凭据 | helper daemon 的注册表；`RuntimeConnectionCredential.xpcServer` 本身是 `#if os(macOS)`（`RuntimeConnectionCredential.swift:33-51`） |

其余全部与平台无关：Bonjour 发现与心跳、镜像、共享、分区、`.injectedTCP` 的注入设备引擎（`:957-1197`）、socket 记录（`:220-271`，Application Support 与 `kill(pid, 0)` 在 iOS 上都有）、文件引擎的簿记（`:2074-2250`）。`RuntimeSource.remote`、`.localSocket` 这些 case 在所有平台都存在，只是 `.remote` 在 macOS 之外连接时抛 `remoteConnectionNotSupportedOnThisPlatform`，所以 `launchAttachedRuntimeEngine` 等附加 Mac 进程的方法在 iOS 上能编、只是没人调。

**其余四个文件**：`RuntimeEngineManagerConfiguration.swift`、`RuntimeEngineManagerEvent.swift` 全是值类型，只因为周围都是 macOS 才被挡住；`RuntimeSharedCacheEligibility.swift` 的规则本身是纯函数，只有 `.live` 的两个探针在 HelperClient；`RuntimeProcessAttacher.swift` 几乎全是 macOS 传输（helper 安装载荷、XPC 或 localhost socket、iOS 模拟器的 Bonjour），留在 macOS。

**`.local` 在 iOS 上本来就在进程里跑**：`RuntimeLocalService.embeddedServiceCredential` 在 macOS 之外返回 `nil`（`RuntimeViewerCore/.../LocalService/RuntimeLocalService.swift:40-45`），管理器的 `launchSystemRuntimeEngines()` 只是把 `.local` 加进列表（`:635-645`）。

**Bonjour 服务端一次只接一个客户端**：`RuntimeNetworkServerConnection` 接受第一个连接后立刻 `listener.cancel()`，直到那个客户端断开才重新监听（`RuntimeViewerCore/.../Network/RuntimeNetworkServerConnection.swift:165-176`、`:240-275`）。今天只有 Mac 浏览，设备只被连；设备要是也浏览，就会去连 Mac 的服务端，占掉 Mac 唯一的连接位。这是 iOS 上关掉浏览的原因。

**管理器与 iOS app 的服务端有两处不同**：

1. **名字**：管理器用同步的 `RuntimeNetworkBonjour.localServiceName`（`:462`），iOS app 用 `await RuntimeNetworkBonjour.resolvedServiceName()`。前者在 iPhone 上退回机型名（`"iPhone (RuntimeViewer)"`），后者是用户给设备起的名字；只有不认 TXT 记录的旧版 Mac 读这个名字，但它拿去当窗口标题和侧栏的 autosave key，换了名字会丢状态（`RuntimeNetworkBonjour+LocalIdentity.swift:110-150`）。在 macOS 上两者相同（同一处文档注释）。
2. **推不推送运行时数据**：管理器的服务端是 `pushesRuntimeData: false`（`:464`），只管引擎列表——Mac 的引擎经代理服务端给对端镜像；iOS app 的服务端用默认的 `true`，Mac 连上来直接看设备的运行时，初次连接就收到 `imageList` 推送（`:194-200` 的注释）。iOS 上不共享引擎，服务端必须推送。

**Mac 上服务端引擎必须同步创建**：`startSharingEngines()` 在 `init` 里紧跟着 `startBonjourServer()` 执行，并立刻读 `bonjourServerEngine` 订阅它的状态（`:1771-1780`）。把创建推迟到异步解析名字之后，Mac 上的共享就订阅不到，所以只在 iOS 上先解析名字。

**文件在进程里读**：`RuntimeEngine(reading:engineID:hostInfo:)`（`RuntimeViewerCore/.../File/RuntimeEngine+File.swift:13-36`）同步建好 `RuntimeFileImageCatalog` 并以它为镜像索引，`connect()` 不带凭据即启动；`RuntimeFileImageCatalog`、`RuntimeDirectoryImageScanner` 都没有平台限定。它与 Mac 上 `.file` 引擎的契约不同：Mac 上先返回一个「转发给 service」的引擎、窗口先开、文件在 service 里读，引擎可以挂起（停掉 service 进程、释放内存）与换配对的 cache 后重读，且始终是同一个对象（`:2111-2250`）；进程内的引擎在建好时就已读完，没有进程可停。测试里在本进程供文件的做法用的是 XPC 匿名监听（`FileEngineManagementTests.swift:200-228`），iOS 上没有。

**现有接缝**：`MacCatalystLaunching`（`:282-343`，测试用它不碰 daemon 就驱动两条启动路径）、`fileEngineCredential`（`:98`，测试用它从匿名监听供文件）、`sharedCacheEligibility`（`:73`）、`init` 的 `startupHandler`（`:365-375`，配置测试用它断言启动步骤）。用到它们的测试：`RuntimeEngineManagerMacCatalystLaunchTests`、`FileEngineManagementTests`、`RuntimeEngineManagerConfigurationTests`、`RuntimeSharedCacheEligibilityTests`、`SharedCacheOwnersWiringTests`，以及 AppCore 的 `RuntimeFileEngineParkingTests`（设 `fileEngineCredential`）。

**iOS 工程**：`RuntimeViewerUsingUIKit.xcodeproj` 是 Xcode 27 的 `project.xcproj` 文本格式，三个 target（iOS、越狱版、visionOS）编同一个源码目录，各自在 `package-product-members` 里列链接的包产品（`project.xcproj:103-117` 一带），目前没有 `RuntimeViewerEngineManagement`。这个工程不在 Tuist 描述里。

## 提议方案

1. **配置**：`RuntimeEngineManagerConfiguration` 新增 `browsesForPeers` 与 `bonjourServerPushesRuntimeData`，构造器里都带默认值（`true`、`false`），已有调用点不用改，`.application` 与 `.headlessHost` 的值不变。新增 `.deviceApplication`：广播、服务端推送运行时数据、启动系统引擎；不浏览、不共享、不重连注入的进程。`RuntimeEngineManager.shared` 在 macOS 上仍是 `.application`，其他平台是 `.deviceApplication`。
2. **接缝**（照已有写法，每处一个带 `.live` 的值，`.live` 按平台给）：
   - `MacCatalystLaunching` 改为可选，macOS 之外 `.live` 是 `nil`；helper daemon 的可用性订阅并进 `MacCatalystLaunching.HelperApplication`，管理器不再直接持有 `helperServiceManager`。
   - `fileEngineCredential` 换成 `FileReading`：`.inFileService(credential:)`（macOS 的 `.live`，行为不变）或 `.inThisProcess`（其他平台的 `.live`）。
   - `RuntimeSharedCacheEligibility` 放开平台限定，macOS 之外 `.live` 是 `.unavailable`（两个探针都答不知道），于是没有分区、不共享。
   - 注入过的 Mac 进程的 XPC 重连留在 macOS；iOS 上 `.deviceApplication` 根本不选这一步。
3. **只在 macOS 上编的部分集中到一个文件** `RuntimeEngineManager+PlatformServices.swift`：上面各个 `.live` 的两个平台分支、`reconnectInjectedXPCEngines()`。它用到的几个主文件成员从 `private` 放宽到 `internal`。helper 的三个依赖改在用它们的方法里就地 `@Dependency`（`MacCatalystLaunching.live` 已经这样做）。
4. **放开平台限定**：Configuration、Event、Manager、Eligibility 去掉 `#if os(macOS)`；删掉没用的 `import ServiceManagement`；两个 macOS 模块的 import 只在 macOS 上写。`RuntimeProcessAttacher` 仍只在 macOS 上编。
5. **服务端**：推不推送运行时数据跟配置走；名字在 macOS 上照旧同步取，iOS 上先 `await resolvedServiceName()` 再建服务端。
6. **iOS 上读文件**：`startReading(_:)` 在后台用 `RuntimeEngine(reading:hostInfo: .files)` 建引擎、`connect()`，读完才返回；读不了就抛错、不留在列表里。这种引擎不挂起（`suspendFileEngine` 不做事、`isFileEngineSuspended` 恒为假）；对已在列表里的文件换配对的 cache 时抛 `RuntimeFileEngineError.dependencyCacheFixedInThisProcess`，留给 iOS 文件模式的界面那篇再定。
7. **iOS app 换用管理器**：`AppDelegate` 在两处注册之后解析 `@Dependency(\.runtimeEngineManager)`，删掉手工建的 Bonjour 服务端；三个 target 都链接 `RuntimeViewerEngineManagement`。界面不变：`SceneDelegate` 照旧在 `.local` 上建 `DocumentState`。

### 非目标

- **在设备上自己附加进程**：另起一篇，和 iOS 的附加界面一起做（要新写「设备给自己注入」的流程，载荷经回环地址连回来）。
- **iOS 上浏览局域网**：等 Bonjour 服务端能同时接多个客户端再开。
- **iOS 上共享系统镜像、派生数据**：本篇不开。
- **AppCore 链接管理器**：AppCore 与 AppUI 对 `RuntimeViewerEngineManagement` 的依赖仍只在 AppKit 平台（`Package.swift:422,460,487`），那 6 个文件放开是愿景第四步的事。
- **iOS 的任何界面变化**。
- **Mac 上的任何行为变化**，包括命令行 host。
- **Bonjour 服务端改成多客户端**、任何线路协议或 `RuntimeSource` 的变化。

## 改动地图

`EM/` 指 `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/`，`EMT/` 指 `RuntimeViewerPackages/Tests/RuntimeViewerEngineManagementTests/`。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `EM/RuntimeEngineManagerConfiguration.swift` · `RuntimeEngineManagerConfiguration` | 修改 | 加 `browsesForPeers`、`bonjourServerPushesRuntimeData`（构造器带默认值）；加 `.deviceApplication`；`startupSteps` 只在 `browsesForPeers` 时含 `.bonjourBrowser`；文档注释里「浏览不是开关」那句改掉 | iOS 不浏览、服务端要推送 | 1 |
| `EMT/RuntimeEngineManagerConfigurationTests.swift` | 修改 | 加 `.deviceApplication` 的启动步骤断言；`.application`、`.headlessHost` 的断言不动 | 守住 Mac 不变 | 1 |
| `EM/RuntimeEngineManager.swift` · `MacCatalystLaunching` | 修改 | `HelperApplication` 加 `daemonBecameAvailable: @MainActor () -> AnyPublisher<Void, Never>`；`.live` 搬走；管理器持有 `MacCatalystLaunching?` | 管理器不再直接碰 helper daemon | 2 |
| `EM/RuntimeEngineManager.swift` · `RuntimeEngineManager` | 修改 | `init` 的 `macCatalystLaunching` 参数改可选；`observeDaemonAvailability()` 改订阅 `helperApplication.daemonBecameAvailable()`；删除三个 helper 的 `@Dependency` 存储属性；`fileEngineCredential` 换成 `fileReading: FileReading`；`startReading` / `suspendFileEngine` / `resumeFileEngine` / `isFileEngineSuspended` 加进程内分支；`relaunchMacCatalystRuntimeEngine()` 在没有 Catalyst 时不做事 | 平台差异收进接缝 | 2 |
| `EM/RuntimeEngineManager.swift` · `RuntimeFileEngineError` | 修改 | 加 `.dependencyCacheFixedInThisProcess` | 进程内引擎不能换配对 | 2 |
| `EM/RuntimeEngineManager+PlatformServices.swift` | 新增 | `MacCatalystLaunching.live`、`FileReading.live`、`RuntimeSharedCacheEligibility.live` 的两个平台分支；`reconnectInjectedXPCEngines()`（只在 macOS）；文件开头写明「只属于某个平台的东西都在这里」 | 平台代码集中在一处 | 2 |
| `EM/RuntimeEngineManager.swift` · 若干成员 | 修改 | `reconnectInjectedXPCEngines()` 用到的成员从 `private` 放宽到 `internal`（`attachedRuntimeEngines` 的写、`observeRuntimeEngineState`、`rebuildSections` 等，以实际编译为准） | 跨文件扩展要用 | 2 |
| `EM/RuntimeSharedCacheEligibility.swift` · `RuntimeSharedCacheEligibility` | 修改 | 加 `.unavailable`；`.live` 搬到平台文件；去掉 HelperClient 的 import | 规则与平台无关 | 2 |
| `EMT/RuntimeEngineManagerMacCatalystLaunchTests.swift` | 修改 | 构造 `HelperApplication` 时给 `daemonBecameAvailable`；加「daemon 可用时重启 Catalyst 引擎」「没有 Catalyst 时只起 `.local`」 | 新接缝的行为 | 2 |
| `EMT/FileEngineManagementTests.swift` | 修改 | `fileEngineCredential` 改 `fileReading = .inFileService { … }`；加进程内读的用例 | 新接缝的行为 | 2 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/RuntimeFileEngineParkingTests.swift` | 修改 | 同上的改名 | 跟着改名 | 2 |
| `EMT/RuntimeSharedCacheEligibilityTests.swift` | 修改 | 加 `.unavailable` 不共享、不放行任何来源 | 新值的行为 | 2 |
| `EM/RuntimeEngineManager.swift`、`EM/RuntimeEngineManagerConfiguration.swift`、`EM/RuntimeEngineManagerEvent.swift`、`EM/RuntimeSharedCacheEligibility.swift` | 修改 | 去掉 `#if os(macOS)`；删 `import ServiceManagement`；HelperClient、CatalystExtensions 的 import 包进 `#if os(macOS)`；`shared` 按平台选配置；`RuntimeEngineManagerEvent.catalystHelperUnavailable` 的注释写明 macOS 之外不会发 | iOS 能编 | 3 |
| `EM/RuntimeEngineManager.swift` · `startBonjourServer()` | 修改 | `pushesRuntimeData` 取配置；macOS 上照旧同步用 `localServiceName`，其他平台先 `await resolvedServiceName()` 再建 | 与 iOS app 今天的服务端一致；Mac 上共享要同步读到服务端 | 3 |
| `EMT/` 新增 `RuntimeEngineManagerDeviceConfigurationTests.swift` | 新增 | 用 `.deviceApplication` 与 iOS 的接缝值在 Mac 上建管理器：系统引擎只有 `.local`、不重连、文件在进程里读 | iOS 路径在 Mac 上测到 | 3 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/AppDelegate.swift` | 修改 | 删 `remoteRuntimeEngine` 与手工建服务端的 `Task`；注册之后解析 `@Dependency(\.runtimeEngineManager)` 并持有；保留后台预热 `.local` | iOS app 换用管理器 | 4 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit.xcodeproj/project.xcproj` | 修改 | 三个 target 的 `package-product-members` 加 `RuntimeViewerEngineManagement` | 链接管理器 | 4 |
| `AGENTS.md`（根）· Package Structure | 修改 | `RuntimeViewerEngineManagement` 一行补上「也在 iOS 与 visionOS 上编，只属于 macOS 的部分在 `RuntimeEngineManager+PlatformServices.swift`」 | 文档同步 | 3 |
| `Documentations/Visions/IOSFeatureParity.md` | 修改 | 相关提案表加本篇 | 愿景索引 | 1 |
| `RuntimeProcessAttacher.swift` | 不动 | 仍只在 macOS 上编 | 附加另起一篇 | — |

## 架构图

改了什么：

```text
RuntimeViewerEngineManagement
├─ RuntimeEngineManagerConfiguration      - #if os(macOS)
│    + browsesForPeers
│    + bonjourServerPushesRuntimeData
│    + static deviceApplication            (advertise + push, no browse / share / reconnect)
├─ RuntimeEngineManagerEvent              - #if os(macOS)
├─ RuntimeSharedCacheEligibility          - #if os(macOS)   + static unavailable
├─ RuntimeEngineManager                   - #if os(macOS)   - import ServiceManagement
│    - @Dependency helperServiceManager / runtimeHelperClient / runtimeInjectClient
│    ~ macCatalystLaunching: MacCatalystLaunching?
│        ~ HelperApplication + daemonBecameAvailable
│    - fileEngineCredential   + fileReading: FileReading (.inFileService(credential:) | .inThisProcess)
│    ~ startBonjourServer(): pushesRuntimeData from configuration; iOS awaits resolvedServiceName()
│    ~ shared: .application on macOS, .deviceApplication elsewhere
├─ + RuntimeEngineManager+PlatformServices.swift
│    #if os(macOS): MacCatalystLaunching.live, FileReading.live (file service),
│                   RuntimeSharedCacheEligibility.live (probes), reconnectInjectedXPCEngines()
│    #else:         nil, .inThisProcess, .unavailable
└─ RuntimeProcessAttacher                 (unchanged, macOS only)

RuntimeViewerUsingUIKit (iOS / jailbroken / visionOS)
└─ AppDelegate   - hand-built Bonjour server engine   + @Dependency(\.runtimeEngineManager)
```

iOS 上启动时谁做什么：

```text
AppDelegate.didFinishLaunching
├─ InjectionServiceRegistrar.registerIfAvailable()
├─ RuntimeCrossReferences.install()
├─ SuspensionPreventionRegistrar.registerIfAvailable()
├─ background: _ = RuntimeEngine.local
└─ runtimeEngineManager  (RuntimeEngineManager.shared, .deviceApplication)
     ├─ startBonjourServer()   await resolvedServiceName() → RuntimeEngine(.bonjour(role: .server), pushesRuntimeData: true)
     │                         ← the Mac connects here, exactly as today
     ├─ (no browser)
     └─ launchSystemRuntimeEngines()   systemRuntimeEngines = [.local]   (macCatalystLaunching == nil)
```

## 详细设计

**配置**：

```swift
public struct RuntimeEngineManagerConfiguration: Sendable, Hashable {
    public var advertisesOverBonjour: Bool

    /// Whether the Bonjour server engine serves this process's own runtime to
    /// the peer that connects, pushing its image list on connect. Off on the
    /// Mac, whose engines peers mirror through proxy servers; on for a device,
    /// whose peers inspect it directly.
    public var bonjourServerPushesRuntimeData: Bool

    /// Browse for peers and connect to each. Off on a device: a Bonjour server
    /// takes one client at a time, so a device that connected to a Mac would
    /// take the connection that Mac's other peers need.
    public var browsesForPeers: Bool

    public var sharesEnginesWithPeers: Bool
    public var launchesSystemEngines: Bool
    public var reconnectsInjectedEngines: Bool

    public init(
        advertisesOverBonjour: Bool,
        bonjourServerPushesRuntimeData: Bool = false,
        browsesForPeers: Bool = true,
        sharesEnginesWithPeers: Bool,
        launchesSystemEngines: Bool,
        reconnectsInjectedEngines: Bool
    )

    public static let application: Self   // unchanged
    public static let headlessHost: Self  // unchanged

    /// The iOS, iPadOS and visionOS app: advertises this device's runtime for
    /// a Mac to inspect and brings up `.local`; neither browses, shares nor
    /// reconnects injected processes.
    public static let deviceApplication = Self(
        advertisesOverBonjour: true,
        bonjourServerPushesRuntimeData: true,
        browsesForPeers: false,
        sharesEnginesWithPeers: false,
        launchesSystemEngines: true,
        reconnectsInjectedEngines: false
    )
}
```

**文件读取的接缝**：

```swift
extension RuntimeEngineManager {
    /// Where a file engine's file is read.
    enum FileReading {
        /// In an instance of the app's file service, reached with the
        /// credential this returns. `nil` when the process embeds no file
        /// service, which `startReading(_:)` reports as
        /// `RuntimeFileEngineError.serviceUnavailable`.
        case inFileService(credential: @MainActor (RuntimeFile) throws -> RuntimeConnectionCredential?)

        /// In this process, by an engine made with `RuntimeEngine(reading:)`.
        /// The file is read before `startReading(_:)` returns, and the engine
        /// is never suspended nor paired with another dependency cache.
        case inThisProcess
    }
}
```

`startReading(_:)` 的进程内分支：

```swift
case .inThisProcess:
    let engine = try await Task.detached(priority: .userInitiated) {
        try RuntimeEngine(reading: file, hostInfo: .files)
    }.value
    try await engine.connect()
    filesByEngineID[engine.engineID] = file
    fileRuntimeEngines.append(engine)
    fileReadsByEngineID[engine.engineID] = Task {}   // already read
    rebuildSections()
    return engine
```

`RuntimeEngine` 能不能从 detached 任务里交出来（是否 `Sendable`），实现时核对；不能就在主 actor 上建、把目录的构建挪进去的办法另议并记入决策日志。

**Catalyst 启动的接缝**：

```swift
struct MacCatalystLaunching {
    struct HelperApplication {
        var launch: @MainActor () async throws -> Void
        var terminate: @MainActor () async -> Void
        var handshakeTimeout: TimeInterval
        /// Fires when the helper daemon is installed again or becomes enabled,
        /// which is when a helper launched against the old daemon has to go.
        var daemonBecameAvailable: @MainActor () -> AnyPublisher<Void, Never> = { Empty().eraseToAnyPublisher() }
    }
    var makeConnectedEngine: @MainActor () async throws -> RuntimeEngine
    var helperApplication: HelperApplication?
    // `static var live: MacCatalystLaunching?` lives in RuntimeEngineManager+PlatformServices.swift
}
```

`launchSystemRuntimeEngines()`：加 `.local`；`macCatalystLaunching` 为 `nil` 时不起 Catalyst 的任务。`observeDaemonAvailability()` 只在 `macCatalystLaunching?.helperApplication` 存在时订阅它的 `daemonBecameAvailable()`。

**共享缓存资格**：

```swift
extension RuntimeSharedCacheEligibility {
    /// For a process that cannot probe others: it shares nothing and lends
    /// to no engine.
    static let unavailable = RuntimeSharedCacheEligibility(isTranslated: { _ in nil }, environment: { _ in nil })
}
```

`sharesThisProcessSharedCache()` 在 `isTranslated(getpid()) == nil` 时为假，于是 `sharedCachePartition` 为 `nil`、`currentSharedCacheOwners()` 为 `nil`，不共享。

**服务端**：

```swift
private func startBonjourServer() {
    #if os(macOS)
    // Synchronous on the Mac: `startSharingEngines()` reads the server engine
    // right after this returns. The two names are the same on macOS.
    makeBonjourServerEngine(named: RuntimeNetworkBonjour.localServiceName)
    #else
    Task { @MainActor in
        makeBonjourServerEngine(named: await RuntimeNetworkBonjour.resolvedServiceName())
    }
    #endif
}
```

`makeBonjourServerEngine(named:)` 建 `RuntimeEngine(source: .bonjour(name:identifier:role: .server), pushesRuntimeData: configuration.bonjourServerPushesRuntimeData)` 并 `connect()`，与今天 `:463-476` 相同。名字的取法用 `#if` 而不是接缝：iOS 上解析出的设备名在 Mac 上测不到。

**iOS app**：

```swift
@Dependency(\.runtimeEngineManager) private var runtimeEngineManager  // resolved after the registrations

func application(_:didFinishLaunchingWithOptions:) -> Bool {
    InjectionServiceRegistrar.registerIfAvailable()
    RuntimeCrossReferences.install()
    SuspensionPreventionRegistrar.registerIfAvailable()
    DispatchQueue.global().async { _ = RuntimeEngine.local }
    _ = runtimeEngineManager   // starts the Bonjour server and `.local`
    return true
}
```

`@Dependency` 存储属性在首次读取时才解析，所以在注册之后第一次读它，就保证了「先注册命令、再有引擎连上」的顺序（根 `AGENTS.md`「Injection commands」）。

## 替代方案考量

- **只用 `#if` 拆文件**：改得最少，但 iOS 的路径（没有 Catalyst、进程内读文件、不共享）只能靠 iOS 构建验证，测试覆盖不到。选定的是接缝。
- **把 macOS 传输拆成独立模块**：管理器模块里不留 `#if`，但多一个模块，App 与命令行 host 的接线都要改。
- **一个汇总的「平台服务」结构体**代替几个分散的接缝：读起来集中，但已有的 `MacCatalystLaunching`、`fileEngineCredential`、`sharedCacheEligibility` 都是分开的，测试也分别替换它们；合并要改动所有这些测试而不带来新行为。
- **iOS 上进程内也起一个「服务」，保留 Mac 的转发契约**（窗口先开、可挂起、可换配对）：要在 Core 里新加一种进程内的连接与凭据，超出本篇；进程内读的契约差异只在 iOS 的文件模式界面出现，那篇再看是否值得。
- **iOS 上浏览，同时把服务端改成多客户端**：本篇会变大，而且改的是 Core 的连接层；iOS 上还没有切换来源的界面，浏览的结果没人用。
- **iOS 上也用同步的 `localServiceName`**：设备名会退回机型名，旧版 Mac 的窗口标题与侧栏状态跟着变。

## 影响

### 用户可见变化

无。Mac 上一切照旧；iOS app 界面不变，Mac 连设备、看设备运行时、往设备进程里注入，都与今天相同。

### 可发现性

无新功能。

### 数据与配置兼容

设备广播的名字与身份不变（同一个 `resolvedServiceName()`，同样的 TXT 记录），Mac 上按设备记的书签与侧栏状态照常对得上。管理器在 iOS 上会读写 Application Support 下的 socket 记录文件的路径，但 `.deviceApplication` 不重连注入的进程，不会写入。

### 平台与最低版本

`RuntimeViewerEngineManagement` 从只在 macOS 上编变为 macOS、iOS、visionOS 都编；最低版本仍是包的 iOS 18、visionOS 2。Mac Catalyst 与 tvOS 上没有任何 target 链接它，不保证编过。

### 发布

不需要新的权限或 entitlement；不影响公证与 Sparkle。iOS 越狱版照旧用 `BuildJailbrokenIPAScript.sh` 打包。

## 落地步骤

1. **配置与启动步骤**（已完成）—— 改动地图里 `RuntimeEngineManagerConfiguration`、它的测试、愿景的相关提案表
   - 行为：`applicationConfigurationStartsEverythingInTheSameOrder`
   - 行为：`headlessHostConfigurationIsUnchanged`
   - 行为：`deviceApplicationStartsServerAndSystemEnginesOnly`
   - 行为：`configurationWithoutBrowsingSkipsTheBrowser`
2. **平台接缝与进程内读文件** —— `MacCatalystLaunching`、`FileReading`、`RuntimeSharedCacheEligibility.unavailable`、新的 `RuntimeEngineManager+PlatformServices.swift`、成员放宽、三份测试与 AppCore 的改名（此时整个模块仍只在 macOS 上编，全部在 Mac 上测）
   - 行为：`systemEnginesWithoutMacCatalystAreLocalOnly`
   - 行为：`relaunchWithoutMacCatalystDoesNothing`
   - 行为：`daemonBecomingAvailableRelaunchesTheHelperEngine`
   - 行为：`fileReadInThisProcessIsReadBeforeStartReadingReturns`
   - 行为：`fileThatCannotBeReadInThisProcessIsNotListed`
   - 行为：`fileEngineReadInThisProcessIsNeverSuspended`
   - 行为：`changingTheDependencyCacheOfAFileReadInThisProcessThrows`
   - 行为：`unavailableEligibilitySharesNothing`
   - 行为：`fileServiceReadingIsUnchanged`（现有用例改名后照过）
3. **放开平台限定** —— 四个文件去掉 `#if os(macOS)`、import 调整、`shared` 按平台、`startBonjourServer()`、新的设备配置测试、根 `AGENTS.md`
   - 行为：`engineManagementBuildsForIOSAndVisionOS`（Ultra 上以 iOS 模拟器与 visionOS 为目标编译该模块）
   - 行为：`bonjourServerPushesRuntimeDataOnlyWhenConfigured`
   - 行为：`deviceConfiguredManagerOnMacListsOnlyLocal`
   - 行为：`macAppAndCommandLineHostBuildUnchanged`
4. **iOS app 换用管理器** —— `AppDelegate.swift`、`project.xcproj`
   - 行为：`iOSAppBuildsForAllThreeTargets`（visionOS 的 SDK 不在 Ultra 上时记下，只编前两个）
   - 行为：`macStillConnectsToTheDeviceAndInjects`（由用户在 vphone 上看）

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：接缝的用法写在类型的文档注释里，「只属于某个平台的东西都在 `+PlatformServices.swift`」写进根 `AGENTS.md`。
- **有没有引入新术语** —— 预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-18 | Created as Draft | 愿景《iOS 版功能对齐》的第一步：引擎管理要在 iOS 上可用，后面几步才动得了 |
| 2026-11-18 | 选定（协作 agent 代用户选，推荐项）：在设备上自己附加进程另起一篇 | 与 iOS 的附加界面一起做；这一篇只让管理器在 iOS 上可用，Mac 行为不变 |
| 2026-11-18 | 选定（协作 agent 代用户选，推荐项）：平台差异用带 `.live` 的闭包接缝，macOS 实现留在同一模块 | 照已有的 `MacCatalystLaunching` 与 `fileEngineCredential`，iOS 的路径在 Mac 上的测试里也能跑 |
| 2026-11-18 | 选定（协作 agent 代用户选，推荐项）：iOS app 换用管理器，但不浏览局域网 | Bonjour 服务端一次只接一个客户端，设备去连 Mac 会占掉 Mac 唯一的连接位 |
| 2026-11-18 | 选定（协作 agent 代用户选，推荐项）：非交互验证，设备上由用户看 | Ultra 上编 iOS 包与 iOS app、在 Mac 上跑覆盖 iOS 路径的测试；vphone 上 Mac 能否连上设备由用户确认 |
| 2026-11-18 | 自定：服务端名字在 iOS 上用 `resolvedServiceName()`、推送运行时数据、不共享 | 与 iOS app 今天的服务端一致，Mac 看到的设备不变；随决定一起列出，由协作 agent 代用户确认 |
| 2026-11-18 | 自定：iOS 上不重连注入的进程、不共享系统镜像 | 附加另起一篇；随决定一起列出，由协作 agent 代用户确认 |
| 2026-11-18 | 自定：iOS 上不会走的 macOS 功能（XPC 重连）与服务端名字的取法用 `#if`，不做接缝 | 接缝用于 iOS 上行为不同、需要在 Mac 上测到的路径；这两处在 iOS 上没有路径可测 |
| 2026-11-18 | 自定：进程内读的文件引擎读完才返回、不挂起、不能换配对 | 不改 Core 的连接层；契约差异只在 iOS 文件模式的界面出现，那篇再定 |
| 2026-11-18 | 提交为 Draft，未批准 | 标着「代用户选」「代用户确认」的几行，是另一台 Mac 上的协作 agent 代用户作答的；用户决定提案先保持 Draft 推到 next，实现交给那台 Mac 上的 agent |
| 2026-11-18 | Accepted | 用户批准，由 Ultra 上的会话接手实现。功能分支从 `origin/next` 切出，而不是本机的 `next`：本机 `next` 上有一个自 11-15 起有意留着没推送的提交（离线文件的镜像树），不该随这条分支推上去；两者改的文件不重叠。 |

# Draft - 引擎管理下沉为无 UI 模块 `RuntimeViewerEngineManagement`

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **所属愿景**: [无头 RuntimeViewer](../Visions/HeadlessRuntimeViewer.md)
- **关联提案**: [0014](0014-inject-ios-simulator-process.md)（attach 流程的 Simulator 一半来自它，本提案把它搬家）、[draft-runtime-bookmark-scope](draft-runtime-bookmark-scope.md)（同一批被搬的文件上有它的改动）、[draft-command-line-interface-multi-source](draft-command-line-interface-multi-source.md)（本提案的第一个 GUI 之外的消费者）
- **实现分支 / PR**: `feature/engine-management-module`（worktree `.worktrees/RuntimeViewer-EngineManagementModule`），**从 `next` 切出**（理由见「落地步骤」）；PR 待定
- **配套文档**: 待定 —— 落地时更新 `CommunicationAndEngineArchitecture.md` §5 / §7 与 `EngineMirroringWalkthrough.md` 的模块定位

## 摘要

把 `RuntimeEngineManager` 及其伙伴（`RuntimeEngineMirrorRegistry`、`RuntimeEngineSection`）从
`RuntimeViewerApplication` 搬进 `RuntimeViewerPackages` 的新 target `RuntimeViewerEngineManagement`，
该模块不依赖 AppKit、RxSwift、`RuntimeViewerArchitectures` 与 `RuntimeViewerSettings`。搬家的同时
开三条缝：一份 `RuntimeEngineManagerConfiguration` 决定「Bonjour 广播 / 引擎共享 / 系统引擎 /
重连已注入进程」各自开不开；一个 `RuntimeResourceLocating` 让注入载荷与 Catalyst helper 的路径
不再写死 `Bundle.main`；一个 `RuntimeProcessAttacher` 承接目前散在 App target
`AttachToProcessViewModel` 里的注入收尾流程。App 层只保留图标、Rx 桥接与系统通知。**App 的
行为零变化。**

## 动机

完整动机见愿景《无头 RuntimeViewer》「现状与代价」。这一步特有的理由只有一条：**没有它，任何
GUI 之外的进程都拿不到本地以外的来源。** 命令行工具的多来源提案
（[draft-command-line-interface-multi-source](draft-command-line-interface-multi-source.md)）与将来
的 MCP 无头化都以它为前置。用户已选定「先抽模块，再建 CLI」，否决了「CLI 直接链
`RuntimeViewerApplication`」（愿景取舍一）。

## 前期调研

1. **UI 耦合点是可数的**（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineManager.swift`，1245 行）：
   AppKit 只用于图标缓存（:66 `engineIconCache: [String: NSImage]`、:890-899 用
   `NSRunningApplication` / `NSWorkspace.shared.icon(forFile:)`、:1110 把描述符的 `iconData` 转
   `NSImage`）；RxSwift 只用于 `rx.runtimeEngines` / `rx.runtimeEngineSections` 两个 `Driver` 桥接
   （:957-979、:1223-1238）。四个 `@Dependency`（:119-128）里 `helperServiceManager` /
   `runtimeHelperClient` / `runtimeInjectClient` 都来自无 UI 的 `RuntimeViewerHelperClient`，只有
   `runtimeConnectionNotificationService` 属于 UI 层。
2. **`init` 把一切一口气启动**（:176-216）：`startBonjourServer()`（:178）→ 浏览器 →
   `launchSystemRuntimeEngines()`（:208）→ `startSharingEngines()`（:215），没有任何配置点。
   `launchSystemRuntimeEngines()`（:356-373）把 `.local` 与 Catalyst 引擎串在一个 `throws` 流程里，
   Catalyst helper 拉不起来整段失败。
3. **消费者只有三处**：`RuntimeViewerUsingAppKit/.../Attach Process/AttachToProcessViewModel.swift`、
   `RuntimeViewerUsingAppKit/.../Main/MainViewModel.swift`、同目录的 `RuntimeEngineMirrorRegistry.swift`。
   既有测试 `RuntimeEngineMirrorRegistryTests`、`InjectedBonjourEngineMatchingTests`
   （`RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/`）随模块一起搬。
4. **attach 的收尾在 App target 里**（`AttachToProcessViewModel.swift:60-140`）：读目标进程的
   `LC_BUILD_VERSION` 选载荷平台 → 把载荷装进 `/Library/Frameworks` → 用
   `SandboxProbe.isMachLookupBlocked`（:95）决定 XPC 还是本地 socket → `launchAttachedRuntimeEngine`
   → 注入 → `confirmAttachedRuntimeEngineConnected`；Simulator 目标则读 `SIMULATOR_UDID` → 注入 →
   `awaitInjectedBonjourEngine`。`SandboxProbe` 在 Core 的 `RuntimeViewerUtilities`，
   `ProcessEnvironmentProbe` 在 `RuntimeViewerHelperClient`，都无 UI。
5. **`RuntimeConnectionNotificationService` 持有 `UNUserNotificationCenter.current()`**
   （`RuntimeViewerApplication/Engine/RuntimeConnectionNotificationService.swift:4,17`）。
   *推测（高置信，实现时用裸可执行文件复核一次）*：没有 bundle 的进程里这一句抛
   `bundleProxyForCurrentProcess is nil`。它必须留在 App 层。
6. **载荷与 Catalyst helper 都靠 `Bundle.main` 定位**：`RuntimeInjectClient.serverFrameworkSourceURL`
   （`RuntimeViewerHelperClient/RuntimeInjectClient.swift:104`）与
   `RuntimeViewerCatalystHelperLauncher.helperURL`（`RuntimeHelperClient.swift:71-74`，
   `Contents/Applications/RuntimeViewerCatalystHelper.app`）。
7. **helper daemon 的连接与状态是两回事**：连接只按 Mach service 名
   （`HelperServiceManager.ensureConnectedToTool()`，`HelperServiceManager.swift:79-86`），daemon 侧
   `codeSigningRequirement: nil`（`swift-helper-service/Sources/HelperServer/HelperServer.swift:23-25`）；
   状态查询 `SMAppService.daemon(plistName:)`（:29）则要求 plist 在 `Bundle.main` 里。本提案不动
   这两处，只记录：GUI 之外的进程能连、查不到状态。
8. **架构文档把它定位在 UI 层**：`Documentations/CommunicationAndEngineArchitecture.md` §5 三层表
   写明 `RuntimeEngineManager` 位于 `RuntimeViewerApplication`；`EngineMirroringWalkthrough.md`
   按该文件的行号引用。两份同批次更新。
9. **`next` 比 `origin/main` 多 214 个提交，其中 19 个改动了要搬的文件**（`Engine/`、
   `RuntimeViewerHelperClient/`、`Attach Process/`）：0014 的 Simulator attach（`0dc1f084`、
   `610e9d9c`）、bookmark scope（`0c34e8b1`）、Bonjour 身份（`abc1a96c`、`dd372031`）等。

## 提议方案

新 target `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/`，依赖
`RuntimeViewerCore`、`RuntimeViewerCommunication`、`RuntimeViewerHelperClient`、
`RuntimeViewerCatalystExtensions`、`swift-dependencies`、`OrderedCollections`、`FoundationToolbox`；
整体 `#if os(macOS)`，平台条件与 `RuntimeViewerHelperClient` 相同。文件尽量原样移动，让 git 识别为
rename，行为差异只来自下面三条缝与两处拆分。

- **配置缝**：`RuntimeEngineManagerConfiguration`，App 用 `.application`（全开），无头进程用
  `.headlessHost`（不广播、不共享、启动系统引擎、重连已注入进程）。
- **资源定位缝**：`RuntimeResourceLocating`，默认实现就是 `Bundle.main`，App 行为不变。
- **attach 缝**：`RuntimeProcessAttacher`，`AttachToProcessViewModel` 缩成调用方。
- **两处拆分**：`launchSystemRuntimeEngines()` 拆成「`.local`（不会失败）」与「Catalyst
  （尽力而为，失败只记日志并发事件）」；`runtimeConnectionNotificationService` 依赖删除，改为
  `eventPublisher`，通知服务留在 App 层订阅。图标缓存搬到 App 层的 `RuntimeEngineIconProvider`。

### 非目标

- 不改 Bonjour 重试、心跳、镜像去重、断连清理的任何逻辑；这些代码原样搬。
- 不改 `RuntimeEngine`、`RuntimeSource`、任何线路协议。
- 不把模块搬进 `RuntimeViewerCore`（它依赖 `RuntimeViewerHelperClient`，平台下限也不同）。
- 不在本提案里写任何命令行代码。

## 详细设计

### 1. `RuntimeEngineManager` 的四处改动

```swift
public struct RuntimeEngineManagerConfiguration: Sendable {
    /// Start the Bonjour server so peers can discover this process.
    public var advertisesOverBonjour: Bool
    /// Wrap every local engine in a `RuntimeEngineProxyServer` and publish descriptors to peers.
    public var sharesEnginesWithPeers: Bool
    /// Bring up `.local` and the Mac Catalyst client engine on start.
    public var launchesSystemEngines: Bool
    /// Reconnect previously injected processes from the endpoint registry and the socket record file.
    public var reconnectsInjectedEngines: Bool

    public static let application: Self = .init(advertisesOverBonjour: true, sharesEnginesWithPeers: true, launchesSystemEngines: true, reconnectsInjectedEngines: true)
    public static let headlessHost: Self = .init(advertisesOverBonjour: false, sharesEnginesWithPeers: false, launchesSystemEngines: true, reconnectsInjectedEngines: true)
}

public enum RuntimeEngineManagerEvent: Sendable {
    case engineConnected(RuntimeEngine)
    case hostDisconnected(hostName: String)
    case catalystHelperUnavailable(any Error)
}

@MainActor
public final class RuntimeEngineManager {
    fileprivate static let shared = RuntimeEngineManager(configuration: .application)

    public let configuration: RuntimeEngineManagerConfiguration
    public init(configuration: RuntimeEngineManagerConfiguration)

    /// Connection-level events; the app turns them into user notifications.
    public var eventPublisher: AnyPublisher<RuntimeEngineManagerEvent, Never> { get }

    /// Icon bytes carried by a mirrored engine's descriptor. Decoding into `NSImage` is the app's job.
    public func remoteIconData(for engine: RuntimeEngine) -> Data?
}
```

- `init` 按配置决定 `startBonjourServer()` / `startSharingEngines()` / `launchSystemRuntimeEngines()`
  / 两个 `reconnectInjected*` 是否执行；浏览器始终启动。
- `@DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeEngineManager.shared })` 留在模块内，
  `shared` 用 `.application`。无头进程在入口 `prepareDependencies { $0.runtimeEngineManager =
  RuntimeEngineManager(configuration: .headlessHost) }` 覆盖——符合 `AGENTS.md`「Singletons &
  Dependency Injection」。
- `engineIconCache`、`cacheLocalAppIcon`、`cachedIcon(for:)` 搬到 `RuntimeViewerApplication` 新增的
  `@MainActor final class RuntimeEngineIconProvider`（订阅 `$attachedRuntimeEngines` 与
  `$mirroredEngines`，对 mirrored 调 `remoteIconData(for:)`）。`MainViewModel` 改从它取图标。
- `extension Reactive where Base: RuntimeEngineManager` 原样搬到 `RuntimeViewerApplication`。
- `RuntimeConnectionNotificationService` 改为订阅 `eventPublisher`；`.engineConnected` /
  `.hostDisconnected` 的触发时机与今天 `observeRuntimeEngineState` 里的调用点一一对应。

### 2. `RuntimeResourceLocating`（放在 `RuntimeViewerHelperClient`）

```swift
public protocol RuntimeResourceLocating: Sendable {
    /// The payload bundle shipped inside the app, per platform slice.
    func payloadFrameworkSourceURL(for platform: PayloadPlatform) -> URL?
    /// `RuntimeViewerCatalystHelper.app` inside the app's `Contents/Applications`.
    var catalystHelperApplicationURL: URL? { get }
}

public struct ApplicationBundleResourceLocator: RuntimeResourceLocating {
    public init(applicationBundleURL: URL)
}

extension DependencyValues {
    @DependencyEntry(liveValue: ApplicationBundleResourceLocator(applicationBundleURL: Bundle.main.bundleURL))
    public var runtimeResourceLocator: any RuntimeResourceLocating
}
```

`RuntimeInjectClient.serverFrameworkSourceURL(for:)` 与 `RuntimeViewerCatalystHelperLauncher.helperURL`
改为读这个依赖。其它定位方式（按 bundle identifier 找已安装的 App、从自身可执行路径向上找 `.app`）
由消费它的提案自己提供实现，本提案只开缝。

### 3. `RuntimeProcessAttacher`

```swift
@MainActor
public final class RuntimeProcessAttacher {
    public struct Target: Sendable, Hashable {
        public let name: String
        public let processIdentifier: pid_t
    }
    public enum Transport: Sendable { case xpc, localSocket, simulatorBonjour }
    public struct Outcome: Sendable {
        public let engine: RuntimeEngine
        public let transport: Transport
        public let payloadPlatform: PayloadPlatform
    }

    public init(
        engineManager: RuntimeEngineManager,
        injectClient: RuntimeInjectClient,
        sandboxProbe: @Sendable (pid_t) -> Bool = { SandboxProbe.isMachLookupBlocked(pid: $0, globalName: RuntimeViewerMachServiceName) },
        environmentProbe: @Sendable (pid_t) -> [String: String]? = ProcessEnvironmentProbe.environment(ofProcess:)
    )

    public func attach(_ target: Target) async throws -> Outcome
    public func detach(_ target: Target) async
}
```

流程与 `AttachToProcessViewModel.swift:60-140` 逐行等价；两个 probe 以闭包注入，只为让「按探测
结果选传输」这段决策能在测试里不依赖真实进程。`AttachToProcessViewModel` 缩成「收集输入 →
`attacher.attach` → 关 sheet / `errorRelay`」。

## 替代方案考量

- **只给 `RuntimeEngineManager` 开缝、不搬模块。** 消费者仍要链整个 `RuntimeViewerApplication`
  （RxSwift、AppKit、UIFoundation、Ifrit、fuzzy-search）。用户在愿景取舍一里否决。
- **搬进 `RuntimeViewerCore`。** Core 的平台下限是 macOS 10.15 且多平台，而本模块依赖
  `RuntimeViewerHelperClient`（macOS 15，`RuntimeViewerPackages`）；要么把 HelperClient 一起搬，
  要么在 Core 里再开平台条件，两者都比一个新 target 贵。
- **把配置做成运行时可变。** 广播与共享一旦启动就有对端依赖，运行时关掉要处理断连清理；
  当前没有任何消费者需要中途切换，构造时定死即可。

## 影响

### 用户可见变化

无。这是行为零变化的搬迁；attach、Bonjour、Catalyst、镜像的表现与今天一致。

### 可发现性

不适用。

### 数据与配置兼容

不改任何落盘格式。`injected-socket-endpoints.json` 的读写代码原样搬入模块，路径不变。

### 平台与最低版本

新 target 与 `RuntimeViewerHelperClient` 同为 macOS-only、macOS 15+。iOS / Catalyst 侧不受影响
（`RuntimeViewerApplication` 里这部分本来就在 `#if os(macOS)` 内）。

### 发布

无新增权限、entitlement 或隐私清单条目；不影响公证与 Sparkle。

## 落地步骤

**分支基线**：从 `next` 切。调研 9 说明要搬的文件在 `next` 上比 `main` 多 19 个提交，从 `main`
切会与它们逐个冲突；代价是向 `main` 交付要排在 0014 与 bookmark scope 之后。动手前按
`create-worktree` skill 再确认一次。

1. 新建 target，原样搬入三个类型与两份测试；补 `RuntimeEngineIconProvider` 与 Rx 桥接扩展；
   `RuntimeConnectionNotificationService` 改订阅 `eventPublisher`。构建通过、测试通过。
2. 加 `RuntimeEngineManagerConfiguration`，`init` 分支化；拆 `launchSystemRuntimeEngines()`。
   新增 `RuntimeEngineManagerConfigurationTests`：用注入的记录型 seam 断言 `.headlessHost` 不启动
   Bonjour 服务端与引擎共享、`.application` 全启动。
3. 加 `RuntimeResourceLocating`，两个 `Bundle.main` 调用点改走依赖。
4. 加 `RuntimeProcessAttacher`，`AttachToProcessViewModel` 缩成调用方。新增决策测试：沙盒 →
   localSocket、非沙盒 → XPC、Simulator → Bonjour、缺 `SIMULATOR_UDID` 报错。
5. 文档：`CommunicationAndEngineArchitecture.md` §5 表与 §7、`EngineMirroringWalkthrough.md` 的
   模块定位与行号、`AGENTS.md` Package Structure 列表。
6. 验证：`RunScript.sh --no-launch` 通过；两个包 `swift test` 通过；手动跑一次 App：attach 一个
   本地进程、看到 Bonjour 对端、Catalyst 引擎出现——这三条是被搬动逻辑的活体检查。

**收尾时必须判断**：配套文档——不另写实现说明，两份既有架构文档的更新即是；术语表——本提案
不引入新术语。

### 实现记录（2026-09-06）

- 步骤 1–5 已在 `feature/engine-management-module` 上完成。新 target 含 `RuntimeEngineManager`、
  `RuntimeEngineMirrorRegistry`、`RuntimeEngineSection`、`RuntimeEngineManagerConfiguration`、
  `RuntimeEngineManagerEvent`、`RuntimeProcessAttacher`；`RuntimeViewerHelperClient` 新增
  `RuntimeResourceLocating`；`RuntimeViewerApplication/Engine/` 新增 `RuntimeEngineIconProvider` 与
  `RuntimeEngineManager+Reactive`，`RuntimeConnectionNotificationService` 改订阅事件。
- 测试：`RuntimeViewerEngineManagementTests`（搬入的两套 + `RuntimeEngineManagerConfigurationTests`
  + `RuntimeProcessAttacherTests`）与 `RuntimeViewerHelperClientTests`（新增
  `ApplicationBundleResourceLocatorTests`）共 62 项通过；`RuntimeViewerApplicationTests` 177 项回归通过。
  均以 `swift test` 原始退出码判定，运行前后 `RuntimeViewer-Debug/settings.json` 校验和未变。
- 步骤 6 的构建部分：`RunScript.sh --no-launch --derived-data <独立目录>` 跑通 Catalyst helper 与模拟器
  载荷两步；主 App 第一次在「Embed Catalyst Helpers」拷贝阶段失败，原因是新 worktree 里没有 gitignored 的
  staged helper（`RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper.app`，平时由 `ArchiveScript.sh`
  写入），把本次 DerivedData 里 `Debug-arm64e-maccatalyst` 的产物 `ditto` 过去后重跑主 App，
  `** BUILD SUCCEEDED **`。与本提案代码无关。
- 步骤 6 的活体检查（attach 本机进程、看到 Bonjour 对端、Catalyst 引擎出现）需要在真实 App 里做，
  尚未进行，等用户在 Debug 构建里验证。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-06 | Created as Draft | 从单篇草案「RuntimeViewer 命令行工具」拆出，用户要求「这个改动很大，要分 3-4 个提案」 |
| 2026-09-06 | 先抽模块，再建 CLI | 用户选定（愿景取舍一）。否决「CLI 直接链 `RuntimeViewerApplication`」 |
| 2026-09-06 | 模块名 `RuntimeViewerEngineManagement`，放 `RuntimeViewerPackages`，保留 `@MainActor` 与 Combine `@Published` | 用户在收尾确认轮确认。搬迁不改并发模型，回归面最小 |
| 2026-09-06 | 分支从 `next` 切 | 调研 9 |
| 2026-09-06 | Accepted | 用户：「开始实现第一份提案」 |
| 2026-09-06 | In Progress | 从 `next`（`eab7eecb`）切出 `feature/engine-management-module` 开工 |
| 2026-09-06 | `hostDisconnected` 携带 `source` 与 `error`，而非草案里的 `hostName` | 通知文案「Lost connection to X: error」两样都要；`engineConnected` 按草案传引擎 |
| 2026-09-06 | attach 的传输决策抽成纯函数 `RuntimeProcessAttacher.route(for:payloadPlatform:sandboxProbe:environmentProbe:)`，两个探测提前到装载荷之前 | 决策表可以在没有 helper daemon 与活体目标时测试；两个探测都是本机只读，提前不改变结果，只让「无法路由」的目标不必先装一遍载荷 |
| 2026-09-06 | `launchSystemRuntimeEngines()` 拆分后，Catalyst helper 失败不再连带跳过已注入进程重连 | 原先二者串在一个 `throws` 流程里，是失败路径上的一处潜在遗漏；成功路径行为不变 |
| 2026-09-06 | `init` 增加内部 `startupHandler` 测试缝；`RuntimeEngineManagerConfigurationTests` 走真正的初始化器断言步骤映射 | 不启动 Bonjour、不碰 helper daemon 就能验证「配置 → 启动步骤」 |
| 2026-09-06 | `AppDelegate.applicationDidFinishLaunching` 新增一行 `runtimeConnectionNotificationService.start()` | 事件不重放，通知服务要在连接任务跑起来前订阅；符合 AppDelegate 一行调用的约定 |
| 2026-09-06 | `Driver` 订阅改为 Combine `sink`（同步、`willSet` 时刻）；`subscribeOnNextMainActor` 改为 `sink` + `Task { @MainActor }` | 与被替换的 RxSwiftPlus 语义一一对应；`detach(_:)` 因只做同步终止而不再 `async` |
| 2026-09-06 | `launchAttachedRuntimeEngine` / `awaitInjectedBonjourEngine` 改为 `@discardableResult` 返回引擎 | `RuntimeProcessAttacher.Outcome.engine` 需要；既有调用方不受影响 |

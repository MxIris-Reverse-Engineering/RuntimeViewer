# Draft - `runtime-viewer-cli` 多来源：全部运行时来源、attach 与 App 充当 host

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **所属愿景**: [无头 RuntimeViewer](../Visions/HeadlessRuntimeViewer.md)
- **关联提案**: 依赖 [draft-engine-management-module](draft-engine-management-module.md) 与 [draft-command-line-interface-foundation](draft-command-line-interface-foundation.md)；[0014](0014-inject-ios-simulator-process.md)（Simulator attach 的语义）；[draft-runtime-bookmark-scope](draft-runtime-bookmark-scope.md)（`sources` 输出的稳定身份）
- **实现分支 / PR**: `feature/command-line-interface-multi-source`（worktree `.worktrees/RuntimeViewer-CLIMultiSource`），从基础提案的 `feature/command-line-interface`（`6c7bc74f`）切出并合入抽模块提案的 `feature/engine-management-module`（`2214167c`）。没有按草案「在 `feature/command-line-interface` 上继续」：前两篇尚未合入 `next`，在基础提案的分支上继续会把抽模块提案的提交带进去；两篇合入 `next` 后本分支可直接合入。PR 待定
- **配套文档**: [`Guides/CommandLineInterface.md`](../Guides/CommandLineInterface.md) 新增「来源怎么解析」「App 优先与接管」「手动验证清单」并改写契约与已知的坑；术语表 [`Glossary.md`](../Glossary.md) 新增「host takeover（App 优先）」

## 摘要

让 CLI 覆盖 GUI 支持的全部运行时来源。独立 host 换上 `RuntimeViewerEngineManagement` 的
`RuntimeEngineManager`（`.headlessHost` 配置），`SourceResolving` 换成按 selector 在管理器的四组引擎
里找的实现；新增 `sources` / `attach` / `detach` 三条命令；独立 host 通过 `RuntimeResourceLocating`
找到已安装的 RuntimeViewer.app 取注入载荷与 Catalyst helper。同时实现「App 优先」：App 启动即
充当 host（新控制器 `CommandLineHostController`），发现独立 host 就接管；App 退出后下一条命令
再拉起独立 host，已注入的进程走既有注册表重连。

## 动机

完整动机见愿景《无头 RuntimeViewer》「现状与代价」。这一步特有的理由：基础提案落地后 CLI 只能
看本机进程内引擎，与 `swift-section` 的差距仅在运行时与 ObjC；注入正在运行的进程、看 Simulator
与 iOS 设备上的运行时才是 RuntimeViewer 的差异化，用户明确要求「GUI 支持的都要支持」。App 优先
与多来源绑在一篇里，因为它解决的正是多来源带来的问题：两个进程同时做 Bonjour 客户端与注入者。

## 前期调研

1. **抽模块提案交付的缝**：`RuntimeEngineManagerConfiguration.headlessHost`（不广播、不共享、启动
   系统引擎、重连已注入进程）、`RuntimeResourceLocating`、`RuntimeProcessAttacher`、
   `eventPublisher`。本提案是它们在 GUI 之外的第一个消费者。
2. **基础提案交付的缝**：`SourceResolving`、`SourceSelector` 全集（`local` / `catalyst` / `pid:` /
   `process:` / `engine:`）、`shutdownHost(.applicationTakeover)` 的接收端、`HostKind.application`。
3. **helper daemon 不校验客户端签名**（`swift-helper-service/Sources/HelperServer/HelperServer.swift:23-25`），
   连接只按 Mach service 名（`HelperServiceManager.swift:79-86`）；Debug / Release 的 service 名分开
   （`RuntimeViewerCommunication/RuntimeRequestResponse.swift:18-27`）。独立构建的 CLI 能用已安装的
   daemon，Debug 的 CLI 天然只配 Debug 的 App。
4. **daemon 状态查询依赖 `Bundle.main` 里的 plist**（`SMAppService.daemon(plistName:)`，
   `HelperServiceManager.swift:29`）。独立 host 查不到状态，只能靠连接是否成功判断；缺 daemon 时
   `ensureConnectedToTool()` 抛错，attach 与 Catalyst 据此报「helper 不可用，请在 App 的
   Settings → Helper Service 安装」。
5. **载荷装到 `/Library/Frameworks` 后由目标进程 `dlopen`**（`RuntimeInjectClient.swift:80-98`）；
   载荷源文件在 App 包内。独立 host 需要 App 包路径。
6. **已注入进程的重连路径已存在**：`reconnectInjectedXPCEngines`（读 Mach Service 注册表）与
   `reconnectInjectedSocketEngines`（读 `~/Library/Application Support/RuntimeViewer/injected-socket-endpoints.json`
   并 `kill(pid, 0)` 探活），`RuntimeEngineManager.swift:665-740`。App 与独立 host 交接时靠它们把
   引擎接回来。
7. **Bonjour 发现要时间**：`connectToBonjourEndpoint` 之后有 2 s 预留让对端排空初始 `imageList`
   （`RuntimeEngineManager.swift:161-172` 的常量注释）。`sources` 需要 `--wait`。
8. **Bonjour 身份是每进程一份**（`abc1a96c` feat(bonjour): give each advertising process its own
   identity）。独立 host 不广播，所以不会与 App 抢同一个服务名；作为客户端它有自己的
   `localInstanceID`，对端把它当成另一个 RuntimeViewer 实例——这是「App 优先」要避免的重复客户端。
9. **App 的 `AppDelegate` 约定**：每个生命周期职责一个 `@MainActor` 控制器，放
   `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/`，经 `@Dependency` 注册
   （`AGENTS.md`「AppDelegate Convention」）。

## 提议方案

- **独立 host**：入口 `prepareDependencies { $0.runtimeEngineManager = RuntimeEngineManager(configuration:
  .headlessHost); $0.runtimeResourceLocator = <按顺序解析的定位器> }`；`SourceResolving` 换成
  `EngineManagerSourceResolver`。
- **新命令**：`sources [--wait 秒]`、`attach <pid | name>`、`detach <selector>`。
- **App 充当 host**：`CommandLineHostController.start()` 在 `applicationDidFinishLaunching` 一行接入，
  用 App 自己的 `RuntimeEngineManager`（`.application` 配置）跑同一个 `CommandLineHostServer`；绑定前
  接管独立 host；`applicationWillTerminate` 收尾。
- **通知**：独立 host 没有 `RuntimeConnectionNotificationService`（抽模块提案已把依赖换成
  `eventPublisher`），事件只进 `host.log`。

### 非目标

- 不做 helper daemon 的安装 / 卸载 / 重装、不做 Simulator 安装器（愿景取舍五）。
- 不让独立 host 广播自己或共享引擎。
- 不做「允许命令行访问」开关与设置页（嵌入提案）；本提案里 App 总是充当 host。
- 不改 `RuntimeProcessAttacher` 的注入语义；CLI 的 attach 与 GUI 的 Attach Process 走同一段代码。

## 详细设计

### 1. 来源解析

```swift
@MainActor
public final class EngineManagerSourceResolver: SourceResolving {
    public init(engineManager: RuntimeEngineManager)
    /// `.local` → `systemRuntimeEngines` 里的 `.local`；`.macCatalyst` → 同组里 `source == .macCatalystClient` 的引擎；
    /// `.attachedProcess(pid)` / `.attachedProcessNamed` → `attachedRuntimeEngines` 按 `RuntimeSource` 的 identifier / name；
    /// `.engine(identifier)` → 四组里 `engineID` 相等者（Bonjour 直连与 mirrored 都靠它）。
    public func resolve(_ selector: SourceSelector) async throws -> RuntimeEngine
}
```

找不到时按 selector 报不同的 `sourceUnavailable` 文案：`catalyst` 提示 helper 未装或 helper 启动失败
（来自 `eventPublisher` 的 `.catalystHelperUnavailable`），`pid:` 提示先 `attach`，`engine:` 提示用
`sources --wait` 重新发现。

### 2. 新命令

```swift
case listSources(ListSourcesCommand)   // waitInterval: TimeInterval（默认 0；给 Bonjour 发现留时间）
case attach(AttachCommand)             // target: .processIdentifier(pid_t) | .processName(String)
case detach(DetachCommand)             // selector

public struct SourcesResult: Codable, Sendable {
    public struct Host: Codable, Sendable { public let hostID: String; public let hostName: String; public let engines: [Engine] }
    public struct Engine: Codable, Sendable {
        public let engineIdentifier: String
        public let displayName: String
        public let kind: String              // local / macCatalyst / attachedXPC / attachedSocket / bonjour / mirrored
        public let selector: String          // 可直接回填给 --source
        public let stableIdentity: String?   // bookmarkScope.identityRawValue
        public let isConnected: Bool
    }
    public let hosts: [Host]
}
```

- `sources` 按 `runtimeEngineSections` 分组输出；`--wait` 期间每 500 ms 重取一次，直到超时或列表
  连续两次不变。
- `attach` 走 `RuntimeProcessAttacher.attach`；按名字时用 helper 的 `ApplicationsService` 列进程，
  同名多个报错列出 pid。进度帧：安装载荷 / 注入 / 等待回连。成功输出新引擎的 selector
  （`pid:<n>`），Simulator 目标输出 `engine:<id>`（它的引擎经 Bonjour 回连，没有 pid selector）。
- `detach` 走 `RuntimeProcessAttacher.detach`。

### 3. 独立 host 的资源定位

`ApplicationBundleResourceLocator` 之上加解析顺序（放在 CLI 库里）：`--app-bundle` 参数 → 环境变量
`RUNTIME_VIEWER_APP_BUNDLE` → 自身所在的 `.app`（从可执行路径向上找，供嵌入提案使用）→ 按
bundle identifier 经 Launch Services（`LSCopyApplicationURLsForBundleIdentifier`）查已安装的 App
（Debug / Release 的 identifier 来自工程 xcconfig 的 `RUNTIME_VIEWER_APP_*_BUNDLE_IDENTIFIER`，
实现时取值）。四步落空时 attach 与 Catalyst 报 `appBundleNotFound`，本地与 Bonjour 来源不受影响。

### 4. App 充当 host 与接管

```swift
@MainActor
public final class CommandLineHostController {
    fileprivate static let shared = CommandLineHostController()
    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager
    public func start()   // applicationDidFinishLaunching
    public func stop()    // applicationWillTerminate
}
```

- `start()`：若 `host.sock` 可连且 `Welcome.hostKind == .standalone`，发 `shutdownHost(.applicationTakeover)`，
  等对方退出（上限 5 s，超时按 `host.json` 的 pid 发 `SIGTERM`），再绑定自己的 listener 并写
  `host.json`（`kind: application`）。若可连且已是 `.application`（另一个 App 实例），本实例不充当
  host，只记日志。
- `stop()`：关 listener，按 0006 守卫删自己写的文件。
- 客户端在命令中途掉线时的重试规则沿用基础提案：只读命令重试一次，`attach` / `export` 不重试。
- App 侧 `RuntimeEngineManager` 仍是 `.application` 配置，CLI 因而能看到 App 里已 attach 的进程与
  全部 Bonjour / mirrored 引擎。

### 5. 测试

- `EngineManagerSourceResolver`：五种 selector 的命中与未命中文案（用只含 `.local` 的真实管理器
  实例 + 注入的 attached / mirrored 列表）。
- `attach` 命令：对 `RuntimeProcessAttacher` 打桩，覆盖 pid / 名字 / 同名多个 / Simulator 输出
  `engine:` selector。
- 资源定位顺序：四级回退各一条，临时目录里造假 `.app`。
- 接管：假 socket 上模拟 `standalone` host，断言 App 发 `applicationTakeover`、等待、超时 `SIGTERM`
  分支；另一个 `.application` 存在时不绑定。
- 端到端：临时目录里的独立 host（`.headlessHost`）跑 `sources` 至少含 `local`；有 helper 的机器上
  手动验证 `attach` 一个本地进程与 Catalyst 出现（无法在 CI 自动化，写进指南的验证清单）。

### 实现记录（2026-09-06）

- 落地步骤 1–4 已在 `feature/command-line-interface-multi-source` 上完成。`RuntimeViewerCommandLine` 包
  新增对 `../RuntimeViewerPackages` 的依赖，只链 `RuntimeViewerEngineManagement` 与 `RuntimeViewerHelperClient`
  两个无 UI 产品（以及 swift-dependencies）。库里新增：`Execution/SourceCatalog.swift`（管理器四组引擎与
  sections 的值快照 `SourceCatalogSnapshot`、`SourceCatalog` 协议、`RuntimeEngineManagerCatalog`，以及
  `SourceKind` / selector 由 `RuntimeSource` 推导的规则）、`EngineManagerSourceResolver`（五种 selector 的
  纯函数 `lookup`、8 s 启动宽限、`sources` / `attach` / `detach`）、`ProcessAttaching`（`RuntimeProcessAttacher`
  的适配层，进度分三段）、`ProcessDirectory`（libproc 列进程）、`ApplicationBundleLocator`（四步找 App 包，
  Launch Services 经 `dlsym` 调用以免弃用警告；`AbsentApplicationBundleResourceLocator` 回答 `nil`）、
  `Host/HeadlessHostDependencies`（`host run` 的 `prepareDependencies`，管理器事件写进 `host.log`）、
  `Host/HostRetirement`（请 host 退出并等它真正退出，超时 `SIGTERM`；客户端换旧 host 与 App 接管共用）、
  `Host/HostTakeover`（App 侧的接管决策）。`Command` / `CommandResult` 各加三个 case，`CommandFailure.Code`
  加 `helperUnavailable` / `applicationBundleNotFound` / `processNotFound` / `ambiguousProcessName` /
  `attachFailed`，协议版本升到 2，工具版本 0.2.0。子命令 `sources [--wait]`、`attach <pid|名>`、
  `detach [<pid|selector>]`，`host run` 加 `--app-bundle` 与 `--local-only`。
- 抽模块提案的模块改了一处 API：`RuntimeProcessAttacher.attach(_:progress:)` 增加可选的阶段回调
  （`installingPayload` / `injecting` / `awaitingConnection`），默认 `nil`，GUI 调用方不受影响。
- App 侧：`RuntimeViewerUsingAppKit/.../App/CommandLineHostController.swift`（`@Dependency` 注册，
  `start()` 先 `HostTakeover.claim` 再用 App 的管理器起 `.application` 的 host，`stop()` 同步删自己的
  socket 与 `host.json`；`--options app` 走 `LiveApplicationOptionsReader` 读主 actor 上的实时设置），
  `AppDelegate` 两行；工程：两个 workspace 加 `RuntimeViewerCommandLine` 包引用，App target 链
  `RuntimeViewerCommandLineInterface`。
- 测试 `RuntimeViewerCommandLineTests` 新增：`SourceCatalogTests`（kind / selector 推导、五种 selector 的
  命中与未命中文案、隐藏的 Bonjour 管理连接仍可按 id 寻址、同名歧义）、`SourceResolverReadinessTests`
  （未连接的引擎报 `sourceUnavailable`、启动宽限内出现的引擎被等到）、`SourceCommandTests`（attach 按
  pid / 名字、大小写、歧义、不存在、已 attach 不重复注入、helper 不可用、Simulator 输出 `engine:`、注入
  失败、无注入器；detach 三类拒绝与成功；`sources --wait` 稳定后提前返回与不等待）、
  `ApplicationBundleLocatorTests`（四级顺序、不存在的候选被跳过、两种定位器）、`HostTakeoverTests`
  （无 host、接管独立 host 后 App 可绑定、另一个 App host 不动、客户端换掉旧协议的独立 host、同步删
  文件只删自己的），以及协议往返、文本渲染、端到端 `sources` / `attach` 被本地 host 拒绝的用例。
  共 103 项 / 14 个套件通过（`swift test` 原始退出码 0），运行前后 `RuntimeViewer-Debug/settings.json`
  校验和未变。
- 落地步骤 5 的活体检查（release 构建的工具，`RUNTIME_VIEWER_CLI_HOST_DIRECTORY=/tmp/rvcli-smoke3`，
  `host run --idle-timeout 25 --app-bundle <空的假 .app>` 前台跑真实的 `.headlessHost` 管理器）：
  `sources --wait 6` 在 3.6 s 列表稳定后返回，本机分组列出 `local`（已连接），并把此时正在运行的
  Release App 当作 Bonjour 对端、在第二个分组里列出它镜像过来的 `My Mac` 与 `My Mac (Mac Catalyst)`
  两个 `mirrored` 引擎；`interface NSObject --image libobjc.A` 正常；`--source catalyst` 报
  `sourceUnavailable` 并带上管理器记录的原因（假包里没有 Catalyst helper）；`attach 2000000000` /
  `attach NoSuchProcessXYZ` 报 `processNotFound`；`attach Finder` 通过 helper 预检、打印
  `preparing` / `installing payload` 进度后报 `applicationBundleNotFound`（假包无载荷，未注入）；
  `detach 1` 与 `--source pid:1` 报 `sourceUnavailable`；`host stop` 后进程退出、目录只剩 `host.pid`。
  `host.log` 第一行记录了 App 包来源。需要 helper daemon 与真实 App 包的部分（attach 成功、Catalyst、
  App 接管）按指南「手动验证清单」手动验证，本轮未做。

## 替代方案考量

方向性的（各跑各的 host）见愿景取舍三。本提案层面：

- **让独立 host 探测 App 是否在跑，主动让位。** 需要轮询或 NSWorkspace 通知，且独立 host 不带
  AppKit；由 App 启动时主动接管，独立 host 只需实现接收端，更简单也更确定。
- **`sources` 同步等满 `--wait`。** 列表稳定后提前返回，Bonjour 对端少时不用白等。
- **Simulator 目标也给 `pid:` selector。** 它的引擎是 Bonjour 回连的，identifier 是
  `{deviceID}-{pid}`（0014），pid 不足以唯一定位；沿用 `engine:`。

## 影响

### 用户可见变化

- CLI 新增 `sources` / `attach` / `detach`，`--source` 全部取值可用。
- App 运行期间在用户目录下多监听一个 Unix domain socket；无界面变化。

### 可发现性

`sources` 的输出直接给出可回填的 selector；使用指南新增「来源寻址」「App 优先与接管」两节。
App 充当 host 在本提案里无开关（开关随嵌入提案的设置页一起来）。

### 数据与配置兼容

`injected-socket-endpoints.json` 由 App 与独立 host 共用同一份代码读写；两者按「App 优先」不会
同时存活，并发写只在接管的几秒窗口内理论上可能，落盘已是原子写，最坏丢一条重连记录。

### 平台与最低版本

macOS 15+；attach 与 Catalyst 需要 App 已安装 helper daemon 且 SIP 按 README 要求关闭。

### 发布

无新增权限或 entitlement；独立 host 复用的是 App 安装好的 daemon 与载荷。

## 落地步骤

1. `EngineManagerSourceResolver` 与独立 host 的 `prepareDependencies`；`sources` 命令。
2. 资源定位顺序；`attach` / `detach` 命令与进度帧。
3. `CommandLineHostController`、接管、`AppDelegate` 两行接入；`AGENTS.md` AppDelegate Convention
   的示例列表加一行。
4. 测试；指南更新（来源寻址、App 优先与接管、手动验证清单）；README 一节补 attach 示例。
5. 验证：App 未运行时 `sources` 列出 `local`（有 helper 时含 `catalyst`）；`attach <pid>` 后
   `interface --source pid:<pid>` 可用；启动 App 后 `host status` 变为 `application` 且 `sources`
   能看到 App 里的引擎；退出 App 后下一条命令拉起独立 host 且 `pid:` 来源经重连仍可用。

**收尾时必须判断**：配套文档——指南更新即是；术语表——新增「host takeover（App 优先）」。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-06 | Created as Draft | 从单篇草案「RuntimeViewer 命令行工具」拆出，用户要求分 3-4 个提案 |
| 2026-09-06 | 来源范围为 GUI 支持的全部来源；App 优先 | 用户选定（愿景取舍三、五） |
| 2026-09-06 | 管理功能只带 attach 必需的 | 用户选定；helper 安装依赖 `SMAppService` 与 App bundle |
| 2026-09-06 | 独立 CLI 按 bundle identifier 定位 App，`--app-bundle` 可覆盖 | 用户在收尾确认轮确认 |
| 2026-09-06 | Accepted | 用户：「开始实现下一个提案，上一个提案的更改先提交」 |
| 2026-09-06 | In Progress；分支 `feature/command-line-interface-multi-source` 从 `feature/command-line-interface` 切出并合入 `feature/engine-management-module` | 前两篇尚未合入 `next`，草案里「在基础提案分支上继续」会把抽模块的提交混进那条分支 |
| 2026-09-06 | 协议版本升到 2，工具版本 0.2.0 | 新增三条命令；版本 1 的 host 收到会静默丢弃、客户端挂到超时。升版后客户端按既有规则自动换掉旧的独立 host |
| 2026-09-06 | `SourceResolving` 扩三个要求（`listSources` / `attach` / `detach`）而非另立协议 | 一个 host 一个 resolver；`LocalSourceResolver` 保留并对后两者回答 `sourceUnavailable` |
| 2026-09-06 | 解析走 `SourceCatalog` 快照 + 纯函数 `lookup`；attach 走 `ProcessAttaching` 缝；进程列表走 `ProcessDirectory` | 不起 Bonjour、不碰 helper daemon 就能测全部规则；管理器只在 `RuntimeEngineManagerCatalog` 一处被读 |
| 2026-09-06 | 刚创建的 resolver 有 8 s 启动宽限，未命中每 100 ms 重试 | 管理器异步起引擎（`.local` 立刻、Catalyst 与重连稍后），首条命令不因时序失败；代价是宽限内确实不存在的 `pid:` 要等到宽限结束才报错 |
| 2026-09-06 | `sources --wait` 列表连续 3 s 不变即提前返回 | 草案写「连续两次不变」（1 s），短于 Bonjour 握手（连接 + 2 s 预留 + engineList），会在对端还没接上时返回 |
| 2026-09-06 | 进程列表与名字用 libproc（`proc_listallpids` / `proc_name` / `proc_pidpath`），不用 helper 也不用 AppKit | helper daemon 没有列进程的 RPC（草案调研有误）；GUI 用的 RunningApplicationKit 是 AppKit 的 |
| 2026-09-06 | Launch Services 经 `dlsym` 调 `LSCopyApplicationURLsForBundleIdentifier` | 该函数在 macOS 12 弃用，替代品是 AppKit 的 `NSWorkspace`；不想为此让工具链 AppKit，也不想留一个永久的弃用警告 |
| 2026-09-06 | `RuntimeProcessAttacher.attach(_:progress:)` 加阶段回调（改抽模块提案的 API，默认参数保持兼容） | attach 的进度帧要从流程内部发出 |
| 2026-09-06 | `ApplicationOptionsReading.readGenerationOptions()` 改 `async`；App 充当 host 时用 `LiveApplicationOptionsReader` | App 内 `--options app` 应读内存里的实时设置（与内容面板同一份合并），且要在主 actor 上读 |
| 2026-09-06 | 请 host 退出的逻辑抽成 `HostRetirement`，退出判据加「进程不在」 | 实例锁到进程退出才释放，只等 socket 消失会让接替者拿不到锁；客户端换旧 host 与 App 接管共用一份 |
| 2026-09-06 | `detach` 只接受 attached 与 Bonjour 两类；`local` / `catalyst` / mirrored 报 `invalidArgument` | 后三类不是 attach 出来的，断开没有意义 |
| 2026-09-06 | `host run --local-only` 保留基础提案行为 | 调试与对照 |
| 2026-09-06 | App 的 `applicationWillTerminate` 同步删 socket 与 `host.json`，不 await server actor | 该回调不能等；socket 随进程关闭，删文件只是让下一条命令立刻知道没有 host |
| 2026-09-06 | App target 直接链 `RuntimeViewerCommandLineInterface`（连带 swift-argument-parser 进 App） | 库不拆；嵌入提案若在意体积再把命令行层拆出去 |
| 2026-09-06 | 接管的 `SIGTERM` 回退分支没有自动化测试 | 需要一个握手后不应答的外部进程；`HostRetirement` 对本进程内的 host 只看 socket、绝不发信号，测试里的 host 都在进程内 |
| 2026-09-06 | 收尾判断：配套文档 = 指南三节 + 契约 / 坑；术语表新增 host takeover | 见头部「配套文档」 |

# Draft - `runtime-viewer-cli` 多来源：全部运行时来源、attach 与 App 充当 host

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **所属愿景**: [无头 RuntimeViewer](../Visions/HeadlessRuntimeViewer.md)
- **关联提案**: 依赖 [draft-engine-management-module](draft-engine-management-module.md) 与 [draft-command-line-interface-foundation](draft-command-line-interface-foundation.md)；[0014](0014-inject-ios-simulator-process.md)（Simulator attach 的语义）；[draft-runtime-bookmark-scope](draft-runtime-bookmark-scope.md)（`sources` 输出的稳定身份）
- **实现分支 / PR**: 待定 —— 在 `feature/command-line-interface` 上继续，前两篇合入后开始
- **配套文档**: 待定 —— 落地时更新 `Guides/CommandLineInterface.md`（来源寻址、App 优先与接管）

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

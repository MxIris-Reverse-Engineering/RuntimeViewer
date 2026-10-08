# Draft - 把注入能力搬出 RuntimeViewerCore，并把命令表对外开放

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-06
- **最后更新**: 2026-10-06
- **所属愿景**: 无
- **关联提案**: [0014](0014-inject-ios-simulator-process.md)（注入 iOS Simulator 进程）、[draft-jailbroken-ios-injection](draft-jailbroken-ios-injection.md)（越狱 iOS 变体）、[draft-device-payload-reverse-connection](draft-device-payload-reverse-connection.md)（设备载荷反向连接）
- **实现分支 / PR**: `feature/jailbroken-ios-injection`
- **配套文档**: 待定 —— 落地时登记实现说明的链接

## 摘要

进程注入这个能力今天散落在 `RuntimeViewerCore` 的六个地方，而 Core 本身在 watchOS / tvOS / visionOS
上也构建，那里根本没有注入这回事。本提案把它整体搬进 `RuntimeViewerCore` package 新增的
`RuntimeViewerInjection` target，并为此把 Core 的命令表从封闭的 enum 改成**对外开放的注册机制**：
`RuntimeEngine.CommandNames`（`enum: String, CaseIterable`）变成 `RuntimeEngine.CommandName`
（带 `String` rawValue 的 struct，别的模块可以 extension 它），
`registerSharedHandlers` 里那张硬编码的请求类型清单变成「内置清单 + 进程级扩展表」。

搬迁与开放是一件事而不是两件：注入的请求类型离开 Core 之后，Core 的 `registerSharedHandlers`
再引用它们就是反向依赖，所以开放注册表不是顺手的清理，而是搬迁能成立的前提。

**线上格式一个字节都不变**：`CommandName` 保留原来的命名空间前缀，新模块声明的命令照旧拼成
`com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.<短名>`，已经装在真机上、验证过的 payload
与新 host 继续互通。

## 动机

### 注入逻辑住在一个它不属于的模块里

`RuntimeViewerCore` 声明的平台是 macOS 10.15 / iOS 13 / macCatalyst 13 / watchOS 6 / tvOS 13 /
visionOS 1（`RuntimeViewerCore/Package.swift`）。注入在这里面只有两条真实路径：iOS 上进程内的
MachInjector，macOS 上的特权 helper daemon。其余四个平台拿到的是一段永远回答
「不支持」的代码 —— `RuntimeInjectionAvailability.withoutInjectionService`
（`Injection/RuntimeInjectionAvailability.swift:52`）的 `#else` 分支就是为它们写的。

模块注释自己已经承认了这件事：

> `RuntimeViewerCore` holds none of the implementation on purpose. Injecting needs MachInjector
> linked into the process on iOS and the privileged helper daemon on macOS, while this module also
> builds for watchOS, tvOS and visionOS, where neither exists.
> —— `Injection/RuntimeInjectionService.swift:5`

实现确实不在 Core（在 `RuntimeViewerPackages` 的 `RuntimeViewerDeviceInjection`），但**协议、线上
类型、五个请求类型、进程级的 service 持有者、五个命令名和五行注册**都还在。Core 因此知道「注入」
这个概念，而它既不执行注入、也在一半平台上无法注入。

### 加下一个同类能力还得改 Core

今天把一个跨进程能力接进引擎，要动 Core 的三处：
`RuntimeEngine.CommandNames` 加 case（`RuntimeEngine.swift:51`）、写请求类型、在
`registerSharedHandlers` 末尾加注册行（`RuntimeEngineRequest.swift:176-180`）。那张清单现在长这样：

```swift
// RuntimeEngineRequest.swift:176
// Injection. Registered unconditionally, including by engines that
// cannot inject: …
register(InjectionCapabilityRequest.self, on: connection, engine: engine)
register(ProcessListRequest.self, on: connection, engine: engine)
register(ApplicationIconsRequest.self, on: connection, engine: engine)
register(InjectIntoProcessRequest.self, on: connection, engine: engine)
register(StopKeepingProcessAwakeRequest.self, on: connection, engine: engine)
```

`RuntimeEngineRequest` 协议的文档说「加一条命令等于声明一个 conformer 再往
`registerSharedHandlers` 追一行」—— 对 Core 内部的命令成立，对**别的模块**的命令不成立，因为那一行
要写在 Core 里。注入是第一个撞上这条边界的能力，不会是最后一个：
`RuntimeEngine.engineListProvider` / `engineListChangedHandler` 是同一类「外部填进来的能力」，
目前靠裸 `static var` 回调绕过了注册表。

### `CommandNames` 是封闭的，这就是搬不走的那堵墙

`enum CommandNames: String, CaseIterable` 不能被别的模块扩展。注入的五个 case 只能留在 Core，
或者新模块自己造一套字符串 —— 后者会让「命令名怎么拼」变成两份实现，而命令名是**跨构建的契约**：
编码方与解码方是不同的 build，在 iOS 上是不同的 app。现有测试正是为这件事写的：

> The command name is what the peer matches on. Renaming a `CommandNames` case silently renames
> the wire name with it, and a peer built before the rename then has no handler — a failure that
> only shows up between two different builds, which no single-process test would catch.
> —— `Tests/RuntimeViewerCoreTests/InjectionCommandWireFormatTests.swift:13`

## 前期调研

### 注入逻辑在 Core 里的六处落点

| 位置 | 内容 |
|------|------|
| `Sources/RuntimeViewerCore/Injection/RuntimeInjectionAvailability.swift`（75 行） | 能力枚举 + 每平台的 `withoutInjectionService` 默认值 |
| `Sources/RuntimeViewerCore/Injection/RuntimeInjectionService.swift`（94 行） | `RuntimeInjectionService` 协议与两个默认实现 |
| `Sources/RuntimeViewerCore/Injection/RuntimeProcess.swift`（145 行） | `RuntimeProcess`、`Injectability`、`RuntimeProcessInjectionResult` |
| `Sources/RuntimeViewerCore/Injection/RuntimePayloadRendezvous.swift`（186 行） | 会合点类型、`reachingThisProcess(from:)`、`stagedBesideImage(_:)` |
| `Sources/RuntimeViewerCore/RuntimeEngine+InjectionRequests.swift`（294 行） | 5 个请求类型、5 个 public 调用方法、`injectionTargetsRunOnThisMachine` |
| `RuntimeEngine.swift:51` / `:152` / `RuntimeEngineRequest.swift:176` | `CommandNames` 的 5 个 case、`static var injectionService`、5 行注册 |

测试两套：`InjectionCommandWireFormatTests.swift`（线上格式，含向后兼容用例）、
`InjectionTargetLocationTests.swift`（`injectionTargetsRunOnThisMachine` 按
`RuntimeSource` 逐 case 钉死）。

### `CommandNames` 的引用面

`RuntimeEngine.swift` 内 18 处、`RuntimeEngineConnectionServer.swift` 5 处、
`RuntimeEngineRequest.swift` 1 处、`RuntimeEngine+Requests.swift` 与
`RuntimeEngine+BackgroundIndexing.swift` 各若干（每个请求类型一处 `commandName`）。
绝大多数是 `.caseName` 形式的隐式成员引用 —— struct 的 `static let` 同样支持，所以这部分是
机械替换。真正要改签名的是五个
`setMessageHandlerBinding(forName: CommandNames, …)` 重载（`RuntimeEngine.swift:555-601`）
与五个 `RuntimeConnection.sendMessage(name: RuntimeEngine.CommandNames, …)` 便利方法
（`RuntimeEngine.swift:1252-1269`）。

### 命令 handler 的装配只有一个入口

三处 serve 路径最终都汇到 `RuntimeEngine.registerSharedHandlers(on:engine:)`：

- `RuntimeEngine.setupMessageHandlerForServer()`（`RuntimeEngine.swift:521`）
- `RuntimeEngineConnectionServer.registerRequestHandlers()`（`RuntimeEngineConnectionServer.swift:45`），
  它被 `RuntimeEngineProxyServer`（`:72`）和 `RuntimeLocalRuntimeServiceHost`（`:49`）用

所以扩展点只需要一个，不必在三处各开一次。

### 新 target 只能放在 `RuntimeViewerCore` package 里 —— 这是被约束锁死的

payload（`RuntimeViewerServer` / `RuntimeViewerMobileServer`）要读
`RuntimePayloadRendezvous.stagedBesideImage(#dsohandle)`
（`RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift:100`），而它的部署目标实测是
iOS 15.0 / macOS 10.15（`RuntimeViewerServer.xcodeproj/project.pbxproj`）。
`RuntimeViewerPackages` 的下限是 macOS 15 / iOS 18，装不下它。所以新 target 进
`RuntimeViewerCore` package，平台声明与 Core 一致。

### 「每个 serve 引擎的进程都要显式注册」无法靠链接自动达成

Core 今天无条件注册这五个 handler，所以每个 serve 引擎的进程自动都有。搬出去之后必须各自调用一次。
考虑过让新模块在加载时自注册（Objective-C `+load` 或 `__attribute__((constructor))`），**不可行**：
SwiftPM 把 target 编成静态库，若一个 object 文件里没有任何符号被引用，链接器不会把它拉进来，
constructor 也就不会存在。而恰好有四个 target 不引用任何注入符号（见下表的「只注册」行），
它们正是会被丢掉的那些。所以显式调用是唯一可靠的路径。

实测得出的 target 清单（九个）：

| Xcode target | 产物 | 与注入的关系 |
|---|---|---|
| `RuntimeViewerUsingAppKit` | macOS App | 既 serve（`RuntimeEngineProxyServer`）又 call（`MainViewModel.swift:426`、`RemoteProcessItemSource.swift:35`） |
| `RuntimeViewerLocalRuntimeService` | XPC service | 只 serve（`main.swift:16` → `RuntimeLocalRuntimeServiceHost`） |
| `RuntimeViewerCatalystHelperPlugin` | bundle | 只 serve（`AppKitPluginImpl.swift:51`，`source: .macCatalystServer`） |
| `RuntimeViewerCommandLineTool` | 工具 | call（`ProcessAttaching.swift`、`EngineManagerSourceResolver.swift`） |
| `RuntimeViewerUsingUIKit` | iOS App | 只 serve（`AppDelegate.swift:40`，Bonjour server engine） |
| `RuntimeViewerUsingUIKit-JB` | iOS App（越狱） | serve + 登记 service（`InjectionServiceRegistrar.swift:34`） |
| `RuntimeViewerUsingVision` | visionOS App | 只 serve |
| `RuntimeViewerServer` | framework（载荷） | serve + 读会合点 |
| `RuntimeViewerMobileServer` | framework（载荷） | 同上 |

### 一处与本提案无关但已查证的事实

`RuntimeInjectionAvailability.withoutInjectionService` 的注释说
「On macOS and Mac Catalyst the app always registers a service」，而全仓库搜索只找到
`RuntimeViewerUsingUIKit/.../InjectionServiceRegistrar.swift` 一处注册点 —— macOS 侧至今没有注册
`RuntimeInjectionService`，它的注入走的是 helper daemon 直连，不经这个协议。这条注释是前瞻而非现状。
本提案不动它，但搬迁时原样带过去，不要误读成「搬漏了一处注册」。

## 提议方案

### 一、`RuntimeEngine.CommandName`：带 String rawValue 的 struct

```swift
extension RuntimeEngine {
    public struct CommandName: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        /// 短名 —— 声明端写的就是这个，`imageList`、`processList` 之类。
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        /// 命名空间前缀。**不可更改**，哪一个模块声明的命令都用它。
        ///
        /// 它是线上契约的一半：peer 匹配的是拼好的整串，而已经装在真机上并
        /// 验证过的 payload 按这个前缀匹配。注入命令搬去另一个模块之后仍然
        /// 拼出同样的字符串，所以搬迁对线上格式是零改动 —— 这是故意的，
        /// 换一个「更干净」的前缀等于让每个已部署的 payload 变成旧版本 peer。
        public static let namespacePrefix = "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine."

        /// peer 匹配的完整字符串。
        public var commandName: String { Self.namespacePrefix + rawValue }

        public var description: String { commandName }
    }
}
```

类型 `public`（别的模块要 extension 它），**Core 自己的 30 多个常量保持 internal** —— 它们不是
API，开放出去等于把每个内部命令名变成改不得的公共符号。常量从 `RuntimeEngine.swift` 搬到
`RuntimeEngineCommandName.swift`，Core 内部的引用形式（`.imageList`）一字不改。

#### 顺带：`RuntimeEngineRequest` → `RuntimeEngineCommand`

协议的文档第一句本来就写着「A typed RuntimeEngine command」，它要求的属性叫 `commandName`，
它还带 `perform(on:)` —— 一个带行为的东西不是 request。本提案把周围全改成 command
（`CommandName`、`RuntimeEngineCommandRegistrar`、`addCommandExtension`、「命令表 / 命令扩展」），
只剩类型名还叫 Request，错配比改之前更刺眼；而且隔壁 `RuntimeViewerCommunication` 真有一个
`RuntimeRequest` 族（给特权 helper daemon 的 XPC 用），两个名字差一个词、意思差一层，
`RuntimeConnection` 的方法列表里还同时出现。

所以协议与 29 个遵循者一起改名，**不做半套**：

| 现在 | 改成 |
|---|---|
| `RuntimeEngineRequest` | `RuntimeEngineCommand` |
| `RuntimeEngineProgressRequest` | `RuntimeEngineProgressCommand` |
| `IsImageLoadedRequest` … 共 29 个 | `IsImageLoadedCommand` … |
| `RuntimeEngineRequest.swift` | `RuntimeEngineCommand.swift` |
| `RuntimeEngine+Requests.swift` | `RuntimeEngine+Commands.swift` |
| `RuntimeInjection+Requests.swift` | `RuntimeInjection+Commands.swift` |

29 个遵循者**没有一个是 public**（全是 internal `struct`），只有两个协议与 `RuntimeEngineEmpty`
是公共 API，消费方全在本仓库内。泛型参数顺手从单字母改成描述性名字：`dispatch<R: …>` →
`dispatch<Command: …>`，注册器的 `<Request: …>` → `<Command: …>`。

**三处不动，每处都有具体理由：**

- `RuntimeEngineProgressEnvelope` 的 `let request` 字段。它是 `Codable` 存储属性，属性名就是
  JSON 键，改它等于改线上格式。泛型参数改了，字段名没改，并在那里留了注释说明为什么。
- `RuntimeSpecializationRequest`（领域类型）与 `SpecializationRequestForCandidateRequest`
  里的**第一个** Request。替换按整标识符白名单做，不用后缀正则，所以只有末尾那个 Request 变成 Command。
- `RuntimeViewerCommunication` 的 `RuntimeRequest` / `RuntimeResponse` / `RuntimeRequestData` 整族。
  那是传输层的请求，名副其实。

`associatedtype Response` **保持不改**，没有改成 `Result`：`Result` 会遮蔽 `Swift.Result`
（这个仓库被同一类坑咬过一次 —— `Semantic` 遮蔽 `Error`，后来满处写 `Swift.Error`），而且
「Result」在本项目里已经是领域结果的意思（`RuntimeProcessInjectionResult`、
`RuntimeInterfaceExportResult`），偏偏 `InjectIntoProcessCommand` 的 Response 就是前者，
写成 `Command.Result = RuntimeProcessInjectionResult` 是「结果的结果」。`Response` 还与
Communication 侧的 `associatedtype Response: RuntimeResponse` 对齐 —— 这些命令确实走连接，
回来的确实是一个响应帧。

### 二、`RuntimeEngineCommandRegistrar`：外部模块唯一能摸到的东西

```swift
/// 把一组命令装到一条连接上。
///
/// 一个值而不是几个自由函数，因为它要穿过模块边界：外部模块拿到的只有它，
/// 拿不到连接，也拿不到引擎。
///
/// `@unchecked Sendable`：它的整个生命周期是一次同步的装配调用，从不跨越隔离域。
/// 标注只为了能作为 `@Sendable` 闭包的参数类型。
public final class RuntimeEngineCommandRegistrar: @unchecked Sendable {
    /// 已经装上的命令线名。重名检测的依据，也是测试断言的对象。
    public private(set) var installedCommandNames: Set<String> = [:]

    /// 装一条普通命令。
    ///
    /// 同名命令已经装过就**丢弃后者并记一条 `.fault`**。先到先得而非后来覆盖：
    /// 内置命令先装，所以一个外部模块无论有意无意都抢不走 Core 的命令名。
    public func register<Request: RuntimeEngineRequest>(_ requestType: Request.Type)

    /// 装一条带进度回传的命令。
    public func registerProgress<Request: RuntimeEngineProgressRequest>(_ requestType: Request.Type)
}
```

重名检测取代了今天那条靠 `CaseIterable.allCases` 查重的测试。它比测试强两处：捕的是运行时真实冲突，
而且覆盖**跨模块**的冲突 —— 两个互不知情的扩展模块撞上同一个短名，测试是看不见的。

### 三、进程级扩展表

```swift
extension RuntimeEngine {
    /// 追加一组由别的模块声明的命令。
    ///
    /// 每条新建立的连接都会装它们，次序是内置命令之后、扩展按注册先后。
    ///
    /// 幂等：同名扩展重复追加只保留第一次，所以 App 与它嵌入的 XPC service
    /// 各调一次是安全的。
    ///
    /// **必须在任何引擎建立连接之前调用。** 装配就发生在连接建立那一刻，没有
    /// 「事后补装」的路径 —— 补装要么重复安装 handler，要么要 Core 持有一张活跃
    /// 连接表，两者都比「在入口处调一次」贵。晚于首次装配的调用会记一条 `.error`，
    /// 因为它的症状（peer 在 host 看来像个旧版本）离原因太远，不留痕就只能靠猜。
    public static func addCommandExtension(
        named name: String,
        install: @escaping @Sendable (RuntimeEngineCommandRegistrar) -> Void
    )
}
```

`registerSharedHandlers` 随之变成：

```swift
static func registerSharedHandlers(on connection: any RuntimeConnection, engine: RuntimeEngine) {
    let registrar = RuntimeEngineCommandRegistrar(connection: connection, engine: engine)
    registerBuiltInHandlers(into: registrar)      // 今天那张清单，减去注入五行
    for commandExtension in commandExtensions {
        commandExtension.install(registrar)
    }
    markHandlersInstalled()
}
```

### 四、`RuntimeViewerInjection` target

`RuntimeViewerCore` package 新增 target 与同名 product，依赖 `RuntimeViewerCore` +
`RuntimeViewerCommunication`，平台声明随 package。文件：

| 文件 | 来源 |
|---|---|
| `RuntimeInjection.swift` | 新增 —— 命名空间、`service`、`install(service:)` |
| `RuntimeInjectionAvailability.swift` | 原样搬 |
| `RuntimeInjectionService.swift` | 原样搬 |
| `RuntimeProcess.swift` | 原样搬 |
| `RuntimePayloadRendezvous.swift` | 原样搬 |
| `RuntimeInjection+CommandNames.swift` | 新增 —— 5 个 `CommandName` 常量 |
| `RuntimeInjection+Requests.swift` | 从 `RuntimeEngine+InjectionRequests.swift` 拆出 5 个请求类型 |
| `RuntimeEngine+Injection.swift` | 从同一文件拆出 5 个 public 调用方法与 `injectionTargetsRunOnThisMachine` |

入口：

```swift
public enum RuntimeInjection {
    /// 这个进程自己的注入实现。
    ///
    /// 按进程而非按引擎：注入是机器的属性，这个进程 serve 的每个引擎给出同一个答案。
    /// host 问一个**远端**引擎时，拿到的是那台机器自己的值，走连接而不是走这里。
    ///
    /// `nil` 是一个有意义的状态，不是未初始化 —— 没有注入 entitlement 的 iOS
    /// 普通变体就是故意留空的，见 `RuntimeInjectionAvailability.withoutInjectionService`。
    public static private(set) var service: (any RuntimeInjectionService)?

    /// 把注入命令装进引擎的命令表，并（可选地）登记本进程的注入实现。
    ///
    /// **每个 serve 引擎的进程都要调用，包括不能注入的那些。** capability 查询正是
    /// host 用来得知「不能」的那条命令：没注册它的引擎，与一个旧到没有这条命令的
    /// peer 无法区分，于是一台明明装了正确变体的设备会被报成「问不出来」。
    ///
    /// 只作为 host 调用这些命令的进程调它也无害（幂等，且本地 service 为 `nil`
    /// 时每条命令都有诚实的空答案），所以规则就一条：**链接了这个模块就调一次**，
    /// 不必再判断自己是哪种角色。
    public static func install(service: (any RuntimeInjectionService)? = nil)
}
```

请求类型归到 `RuntimeInjection` 名下（`RuntimeInjection.ProcessListRequest`），不再是
`RuntimeEngine.ProcessListRequest`：往 Core 的类型里塞嵌套类型会让 `RuntimeEngine` 的命名空间
逐渐被不属于它的东西填满，而这是第一个扩展模块，它写成什么样，后面几个就照着写。

### 非目标

- **不动 `engineListProvider` / `engineListChangedHandler`。** 它们是同一类「外部填进来的能力」，
  但 `engineList` 是 server-only 命令、不在共享表里，改它要动引擎镜像那条线，与本提案无关。
- **不合并 `RuntimeViewerDeviceInjection`。** 它是 iOS 侧实现，依赖 MachInjector，留在
  `RuntimeViewerPackages`，只是改成依赖新 product。
- **不改任何线上格式。** 命令名、请求与响应的 JSON 形状全部保持，向后兼容的那些用例原样搬过去继续跑。
- **不补 macOS 侧的 `RuntimeInjectionService` 注册。** 见前期调研最后一条。
- **不改注入的任何行为。** 这是一次纯搬迁加一次机制开放。

## 详细设计

### 扩展表的存储与线程安全

```swift
extension RuntimeEngine {
    private struct CommandExtension {
        let name: String
        let install: @Sendable (RuntimeEngineCommandRegistrar) -> Void
    }

    private static let commandExtensionsLock = NSLock()
    private nonisolated(unsafe) static var registeredCommandExtensions: [CommandExtension] = []
    private nonisolated(unsafe) static var hasInstalledHandlersOnAnyConnection = false
}
```

用 `NSLock` 而不是 `Synchronization.Mutex`：后者要 macOS 15 / iOS 18，而这个 package 的下限是
macOS 10.15 / iOS 13。Core 现有的 `engineListProvider` 是裸 `static var` 无锁 —— 新表加锁是
提升而非与之不一致，不在本提案里顺手改旧的那两个。

### `install` 的时序诊断

`addCommandExtension` 在 `hasInstalledHandlersOnAnyConnection` 已为真时仍然追加（后续新建的连接
会装上它），同时记一条 `.error`，点名这个扩展在谁之后到场。这不是防御性编程 —— 这是本提案引入的
唯一一个新失效模式的唯一线索。

### `register` 的重名处理

```swift
public func register<Request: RuntimeEngineRequest>(_ requestType: Request.Type) {
    guard installedCommandNames.insert(Request.commandName).inserted else {
        #log(.fault, "命令名冲突，后注册的被丢弃：\(Request.commandName, privacy: .public)")
        return
    }
    connection.setMessageHandler(name: Request.commandName) { (request: Request) -> Request.Response in
        try await engine.dispatch(request)
    }
}
```

走 `engine.dispatch` 而非 `request.perform(on: engine)` 的理由不变，原注释
（`RuntimeEngineRequest.swift:106-120`，讲远端镜像与那次 `loadImage` 在错误进程里 dlopen 的回归）
随实现一并保留。

### 测试的搬迁与改写

- `InjectionCommandWireFormatTests` / `InjectionTargetLocationTests` → 新 testTarget
  `RuntimeViewerInjectionTests`。两套都用 `@testable import RuntimeViewerCore`，搬迁后
  改为普通 `import RuntimeViewerCore` + `@testable import RuntimeViewerInjection`
  （`RuntimeEngine.init(source:)`、`RuntimeSource` 都是 public）。
- 命令名断言照旧钉完整字符串（`prefix + "processList"`），这正是搬迁不改线上格式的证据。
- `allCases` 唯一性那条 → 改为对 `registrar.installedCommandNames` 的断言，外加一条新用例：
  故意注册一个与内置命令同名的请求类型，断言内置的那个仍在、后者被丢弃。
- Core 侧新增一小套 `RuntimeEngineCommandRegistryTests`：扩展表幂等、装配次序、重名丢弃。

### 九个 target 的接线

每个 target 在 `.xcodeproj` 里加 `RuntimeViewerInjection` 的 package product 依赖；
各进程入口加一行：

| 进程 | 调用位置 | 形式 |
|---|---|---|
| macOS App | `AppDelegate.main()`，在 `NSApplication.shared` 之前 | `RuntimeInjection.install()` |
| XPC service | `RuntimeViewerLocalRuntimeService/main.swift`，engine 构造之前 | `RuntimeInjection.install()` |
| Catalyst plugin | `AppKitPluginImpl.swift`，engine 构造之前 | `RuntimeInjection.install()` |
| CLI 工具 | `runtime-viewer-cli` 入口 | `RuntimeInjection.install()` |
| iOS / visionOS App | `AppDelegate`，`RuntimeEngine.local` 之前 | 经 `InjectionServiceRegistrar` |
| 越狱 iOS App | 同上 | `RuntimeInjection.install(service: RuntimeDeviceInjectionService(...))` |
| 载荷 | `RuntimeViewerServer.main()` 开头 | `RuntimeInjection.install()` |

`InjectionServiceRegistrar.registerIfAvailable()` 改写为：无条件 `RuntimeInjection.install(...)`，
`RUNTIME_VIEWER_JAILBROKEN` 决定 `service:` 传不传。它今天的文档注释已经说清为什么普通变体要
「什么都不注册」—— 改写后那句话要跟着变，因为普通变体从此也要注册**命令**，只是不注册 service。

## 替代方案考量

### Core 保留请求类型的空壳，只把实现搬走

请求类型留在 Core，`perform(on:)` 转发给一个 public 协议。好处是没有漏注册风险 —— Core 照旧无条件
装那五个 handler。**否**：这不满足「加新功能不用改 Core」。下一个同类能力还是要在 Core 里加
case、加空壳、加注册行，墙一点没拆，只是把注入这一块粉刷了一遍。

### 让 `RuntimeInjectionService` 的登记顺带注册命令

把两件事合成一个入口，少一个能忘的地方。**否**：没有 service 的进程（iOS 普通变体、XPC service、
Catalyst plugin、载荷）同样要注册命令 —— 这正是「capability 查询由每个引擎回答」的设计前提。
把注册绑在 service 上，就等于让这些进程全部退化成「旧版本 peer」。
最终采用的 `install(service:)` 是这个想法能走通的形状：一次调用，service 可选。

### 新 target 放进 `RuntimeViewerPackages`

那里已经有 `RuntimeViewerDeviceInjection`，放在一起更聚。**否**：载荷的部署目标是 iOS 15 /
macOS 10.15，而 `RuntimeViewerPackages` 的下限是 macOS 15 / iOS 18。这不是取舍，是硬约束。

### 给新模块自己的命令名前缀

`com.RuntimeViewer.RuntimeViewerInjection.` 这样的前缀更诚实地反映了命令住在哪。**否**：
前缀是线上契约的一半。已经装在真机上、经过验证的 payload 按旧前缀匹配，换前缀等于让它们
全部变成认不出新命令的旧 peer。模块归属的诚实度不值这个代价。

### 保留 `CommandNames` 复数名

引用点一字不改，diff 最小。**否**：一个单值类型叫复数，`RuntimeEngine.CommandNames.processList`
读起来是「命令名们点 processList」。改名是纯机械替换，一次付清。

### 让新模块在加载时自注册

`+load` 或 `__attribute__((constructor))` 免掉九处显式调用。**否**：实测不可行的理由见前期调研 ——
静态库里没有符号被引用的 object 文件不会被链接进来，而最需要自注册的四个 target 恰好正是不引用
任何注入符号的那些。

## 影响

### 用户可见变化

无。界面、交互、快捷键、菜单项一处不动，注入行为与成功率不变。

### 可发现性

无新功能，无新设置项。

### 数据与配置兼容

- **线上格式零改动**：命令名、请求与响应的 JSON 形状全部保持。已部署在真机上的 payload
  与新 host 继续互通，`rendezvous.json` 的键名不变。
- 偏好设置、文档、书签、钥匙串一概不涉及。

### 平台与最低版本

`RuntimeViewerInjection` 的平台声明与 `RuntimeViewerCore` package 一致
（macOS 10.15 / iOS 13 / macCatalyst 13 / watchOS 6 / tvOS 13 / visionOS 1）。
各 target 的部署目标不变。

### 发布

无新 entitlement、无隐私清单条目、不影响公证与 Sparkle。

**一个新的失效模式**，必须在验收里盯住：某个 serve 引擎的进程漏调
`RuntimeInjection.install()` 时**没有编译错误**，只有运行时表现 —— 那个 peer 在 host 看来
像个旧版本，注入入口被静默禁用。缓解是三层：规则简化成「链接了就调」（不必判断角色）、
重名/时序诊断留日志、验收阶段跑通 macOS App 的真实注入路径。

## 落地步骤

每一步单独构建通过，package 层测试绿。

1. **`CommandNames` → `CommandName`。** 常量搬到 `RuntimeEngineCommandName.swift`，类型改写，
   五个 `setMessageHandlerBinding` 重载与五个 `sendMessage` 便利方法换签名。注入五个常量此时
   仍留在 Core。`swift test` RuntimeViewerCore 绿。
2. **引入注册器与扩展表。** `RuntimeEngineCommandRegistrar`、`addCommandExtension`、
   `registerBuiltInHandlers`，`registerSharedHandlers` 改为遍历。注入五行此时仍在内置清单里，
   所以行为完全不变。新增 `RuntimeEngineCommandRegistryTests`。
3. **建 `RuntimeViewerInjection` target 与 product**，搬八个文件，Core 删尽注入痕迹
   （四个文件、`RuntimeEngine+InjectionRequests.swift`、五个 `CommandName` 常量、
   `static var injectionService`、五行注册）。建 `RuntimeViewerInjectionTests` 并搬两套测试。
   两个 package 的 `swift build --build-tests` + `swift test` 绿。
4. **`RuntimeViewerPackages` 接线。** `RuntimeViewerDeviceInjection` 与
   `RuntimeViewerEngineManagement` 加 `RuntimeViewerInjection` 依赖，补 `import`。
   `RuntimeViewerDeviceInjectionTests` / `RuntimeViewerEngineManagementTests` 绿。
5. **九个 Xcode target 加 package product 依赖**，各入口加 `RuntimeInjection.install(...)`，
   `InjectionServiceRegistrar` 改写并更新它的文档注释。
6. **构建验证**：两个 package 的 build + test，再 `RunScript.sh --no-launch` 证明 macOS App
   仍能编。iOS 越狱变体与载荷做静态核对（链接项与 install 调用点逐一比对清单），不在本批次跑
   `BuildJailbrokenIPAScript.sh`。
7. **文档**：`CLAUDE.md` 的 Package Structure 一节加 `RuntimeViewerInjection`，并把
   「每个 serve 引擎的进程都要 `RuntimeInjection.install()`」写成一条规则 —— 这正是「从 API
   签名看不出来的调用方契约」。提案状态改 Implemented 时判断要不要另写实现说明，以及
   `CommandName` / 命令扩展表是否算新术语。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-06 | Created as Draft | 用户要求：把注入逻辑从 RuntimeViewerCore 挪走、建新 target、`CommandNames` 改成带 String rawValue 的结构体并对外开放扩展，确保加新功能不用改 Core 内部实现。 |
| 2026-10-06 | 搬迁边界定为「全搬」 | 完整档澄清提问第 1 轮。`RuntimePayloadRendezvous` 与 `injectionTargetsRunOnThisMachine` 两个边界件都进新 target，Core 里不留一个注入字眼。代价是载荷 target 要新增链接 —— 已接受。 |
| 2026-10-06 | 开放机制定为「进程级扩展表 + 显式 install」 | 第 1 轮。否掉了「Core 保留 handler 装配只搬实现」（不满足需求）。接受「九处显式调用、漏调只在运行时表现」这个代价。 |
| 2026-10-06 | service 归属定为 `RuntimeInjection.install(service:)` | 第 1 轮。注册命令与登记 service 合成一次调用，少一个能忘的地方；没有 service 的进程调无参版本。 |
| 2026-10-06 | 另开一份提案，不并入 draft-jailbroken-ios-injection | 第 1 轮。那份讲功能，这份讲结构。 |
| 2026-10-06 | 唯一性由注册器当场拒绝重名保证 | 第 2 轮。取代 `CaseIterable.allCases` 查重的测试；运行时检测更强，且能捕跨模块冲突。先到先得，内置命令先装，所以外部模块抢不走 Core 的名字。 |
| 2026-10-06 | target 名定为 `RuntimeViewerInjection` | 第 2 轮。与 Core / Communication / Utilities 同一命名节奏；`RuntimeViewerDeviceInjection`（iOS 实现）保持分离。 |
| 2026-10-06 | pbxproj 由 agent 手改 | 第 2 轮。本会话无 Xcode MCP 工具；按现有 `RuntimeViewerCore` 链接条目的形状照抄三件套，改完先给用户看 diff。 |
| 2026-10-06 | 验证范围定为「package 层 build + test，再加 macOS App」 | 第 2 轮。iOS 越狱变体与载荷只做静态核对，不跑 `BuildJailbrokenIPAScript.sh`（排队耗时）。 |
| 2026-10-06 | 请求类型归 `RuntimeInjection` 名下 | 第 3 轮。否掉「继续 `extension RuntimeEngine` 嵌套」：别的模块往 Core 类型里塞嵌套类型会逐渐填满 `RuntimeEngine` 的命名空间，而这是第一个扩展模块，范式照它写。 |
| 2026-10-06 | `CommandName` 单数命名，Core 内置常量保持 internal | 第 3 轮。类型 public（外部要 extension），30+ 个内置常量不进公共 API。 |
| 2026-10-06 | 状态改 Accepted，开始实现 | 用户批准，按「落地步骤」的七步推进。 |
| 2026-10-06 | `RuntimeEngine.dispatch` 由 internal 改 public | 实现时发现的缺口：扩展模块不只要能**装** handler，还要能**发**自己声明的命令，否则只能做半个功能。三个重载一起开放，原注释（讲远端镜像与那次 `loadImage` 在错误进程里 dlopen 的回归）保留并补一句开放理由。 |
| 2026-10-06 | 要接线的 package 是四个而非三个 | `RuntimeViewerCommandLine` 也要加依赖 —— `runtime-viewer-cli` 是常驻 host，serve 引擎。而且它有**两个**入口点（package 的可执行目标，与 App 包里嵌的那份），两处都要调 install。 |
| 2026-10-06 | `withoutInjectionService` 的 macOS 注释就地改正 | 原注释写「macOS 上 app 总是注册一个 service，走到这个值说明没接线，是编程错误」。搬迁后每个 macOS 进程都按设计走到这个值（Mac 的注入走特权 helper daemon，不经这个协议），再留着那句话会把正确的调用读成 bug。只改注释，不补注册 —— 后者仍是非目标。 |
| 2026-10-06 | 注册器测试改钉 `isImageLoaded` | 初版钉了 `imageList`，但它是推送通道而非请求命令，从来不在注册器里，两条用例因此是假阳性/假阴性。换成内置清单真会装的命令名。 |
| 2026-10-06 | `RuntimeEngineRequest` → `RuntimeEngineCommand`，29 个遵循者一起改 | 协议文档第一句本来就叫它 command、要求的属性叫 `commandName`、还带 `perform(on:)`；本提案把周围全改成 command 之后错配更刺眼；且与 Communication 的 `RuntimeRequest` 族撞名。遵循者全是 internal，线上格式零影响。泛型参数顺手去掉单字母。 |
| 2026-10-06 | `associatedtype Response` 不改成 `Result` | `Result` 遮蔽 `Swift.Result`（本仓库有过 `Semantic` 遮蔽 `Error` 的前例），且「Result」在项目里已指领域结果 —— `InjectIntoProcessCommand` 的 Response 正是 `RuntimeProcessInjectionResult`。`Response` 也与 Communication 侧对齐。 |

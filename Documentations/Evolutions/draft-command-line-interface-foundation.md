# Draft - `runtime-viewer-cli` 基础：命令级协议、常驻 CLI host 与本地来源

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **所属愿景**: [无头 RuntimeViewer](../Visions/HeadlessRuntimeViewer.md)
- **关联提案**: [0006](0006-mcp-transport-bind-failure-teardown.md)（本地端点文件「谁绑定成功谁删」的守卫，本提案沿用）、[draft-command-line-interface-multi-source](draft-command-line-interface-multi-source.md)（在本提案的缝上接多来源与 App 充当 host）、[draft-command-line-interface-app-embedding](draft-command-line-interface-app-embedding.md)
- **实现分支 / PR**: 待定 —— 建议 `feature/command-line-interface`，从 `next` 切出（不依赖抽模块提案，但与之共享后续交付顺序）
- **配套文档**: 待定 —— 落地时登记 `Documentations/Guides/CommandLineInterface.md`

## 摘要

新建 SwiftPM 包 `RuntimeViewerCommandLine/`：库 `RuntimeViewerCommandLineInterface` 定义 Codable 的
命令与结果模型、Unix domain socket 上的长度前缀 JSON 协议、执行器、常驻 **CLI host** 的服务端与
客户端；薄可执行 `runtime-viewer-cli` 只做参数解析与渲染。第一条命令发现没有 host 就把它拉到
后台，host 空闲到期自动退出。本提案只接**本地进程内引擎**这一种来源，但把查询类命令全部做完：
`images` / `load` / `types` / `search` / `interface` / `hierarchy` / `relationships` / `members` /
`specialize` / `export` / `host`。来源解析留一个 `SourceResolving` 缝，多来源提案在上面替换实现。

落地后即满足用户最初的诉求：**不启动 App，`swift build` 出来的 CLI 就能查本机运行时。**

## 动机

完整动机见愿景《无头 RuntimeViewer》。这一步特有的理由：**它是四篇里唯一不依赖抽模块提案的
一篇**——本地引擎只需要 `RuntimeEngine(source: .local)`，`RuntimeViewerCore` 已能脱离 App 单独构建
（调研 2）——所以它能最早交付、最早让协议与 host 模型经受真实使用。

## 前期调研

1. **`RuntimeEngine` 的查询面已经完整，且全部经 `dispatch` 走请求对象**
   （`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`）：`isImageLoaded(path:)`（:833）、
   `loadImage(at:)`（:841）、`interface(for:options:)`（:867）、`objects(in:)`（:871）、
   `hierarchy(for:)`（:939）、`relationships(for:)`（:962）、`memberAddresses(for:memberName:)`（:970）、
   `exportInterfaces(with:reporter:)`（:1043）；泛型特化四个入口
   （`RuntimeEngine+GenericSpecialization.swift:15/36/66/92`）同样经 `dispatch`。执行器写成对着
   `RuntimeEngine` 的代码，将来换成远端引擎不用改。
2. **`RuntimeViewerCore` 能单独构建**：2026-09-06 实测 `swift build --package-path RuntimeViewerCore
   --scratch-path /tmp/claude/SwiftPM/RuntimeViewerCore --product RuntimeViewerCore` 退出码 0，
   136.88 s。
3. **无头引擎的最小配方已存在**：`RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Support/TestRuntimeEngine.swift:41-48`
   —— `RuntimeEngine(source: .local)` → `connect()` → `loadImage(at:)`。
4. **导出是 Core 的能力**：`RuntimeInterfaceExportConfiguration`（单文件 / 目录、`includeMetadata`）、
   `RuntimeInterfaceExportReporter`（`AsyncStream<RuntimeInterfaceExportEvent>`，阶段与逐对象事件）、
   `RuntimeInterfaceExportWriter` 产出 `<Image>.h` / `<Image>.swiftinterface` 或 `ObjCHeaders/` +
   `SwiftInterfaces/`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Export/`）。
5. **生成选项有现成的「全注释」预设** `GenerationOptions.mcp`
   （`Common/RuntimeObjectInterface+GenerationOptions.swift:19-43`）。App 自己的选项存于
   `AppDefaults.options`（`~/Library/Application Support/AppStorage`，
   `RuntimeViewerApplication/AppDefaults.swift:29-36,81`），transformer 配置存于 Settings
   （Debug 为 `RuntimeViewer-Debug/settings.json`，`RuntimeViewerSettings/Settings.swift:41`）。
   `GenerationOptions` 与 `Transformer.Configuration` 都是 Core 的 `Codable`，不链 UI 层也能读。
6. **MCP 工具面是现成的命令清单与词汇**：`MCPBridgeServer.swift` 的 `typeInterface` / `listTypes` /
   `searchTypes` / `listImages` / `searchImages` / `memberAddresses` / `loadImage` / `loadObjects`；
   `MCPRuntimeTypeInfo` 的字段 `name / displayName / kind / imagePath / imageName`
   （`MCPBridgeProtocol.swift:147-157`）。类型解析（先 `name` 后 `displayName`）与镜像短名解析
   （`resolveImagePaths` / `resolveImageNameFromImageList`）都有可照搬的规则。
7. **本地端点先例**：MCP 端口文件在 `~/Library/Application Support/RuntimeViewer/`
   （`MCPService.swift:66-73`），0006 规定只有绑定成功的实例才删文件；更早的 stdio MCP server 用
   长度前缀 JSON over TCP。
8. **同门 CLI 先例**：`swift-section` 用 swift-argument-parser 1.5.1，入口 `AsyncParsableCommand` +
   子命令数组（`MachOSwiftSection/Sources/swift-section/SwiftSectionCommand.swift`）。
   swift-argument-parser 已在本仓库的解析图中。
9. **测试进程与 Debug App 共用目录的教训**：记忆与 `AGENTS.md` Testing 一节都记着测试曾清掉
   Debug 设置。host 的文件目录必须有可注入的测试路径。

## 提议方案

```
   runtime-viewer-cli interface NSObject --image /usr/lib/libobjc.A.dylib
        │ 解析参数、把相对路径解析成绝对路径
        ▼
   CommandLineHostClient ── connect host.sock ──✗──▶ flock host.lock → 再试 → spawn `runtime-viewer-cli host`
        │ Command ─────────────────────────────▶ CommandLineHostServer
        │ ◀── Progress* / Result | Failure ───── CommandExecutor ── SourceResolving ── RuntimeEngine(.local)
        ▼
   渲染：文本 或 --json
```

- **包** `RuntimeViewerCommandLine/`（仓库根，与 `RuntimeViewerMCP/` 同级）：`.library(
  RuntimeViewerCommandLineInterface)` + `.executable(runtime-viewer-cli)`，平台 `macOS(.v15)`，依赖
  `../RuntimeViewerCore`、`swift-argument-parser`；沿用两个现有包的 `USING_LOCAL_DEPENDENCIES` 模板。
  可执行 target 只有 `main.swift`。
- **协议**：Unix domain socket，4 字节大端长度 + JSON 帧；`Hello` / `Welcome` 握手带协议版本。
- **host 生命周期**：文件在 `<AppSupport>/RuntimeViewer[-Debug]/CommandLineHost/`；单例靠
  `flock`；空闲（无连接且无在途命令）默认 600 s 退出；`shutdownHost` 消息带原因，其中
  `.applicationTakeover` 的接收端行为在本提案定义，发送端（App）在多来源提案实现。
- **执行器**：`CommandExecutor` 持一个 `SourceResolving`，本提案的 `LocalSourceResolver` 只认
  `.local`，其余 selector 报 `sourceUnavailable`。
- **命令**：见详细设计 §4；`--json` 输出结果模型本身。

### 非目标

- 不做 `.local` 以外的来源、不做 `sources` / `attach` / `detach`（多来源提案）。
- 不让 App 充当 host、不做接管的发送端（多来源提案）。
- 不做 Xcode target、不嵌 App 包、不做设置页（嵌入提案）。
- 不做交互式 shell；不做 ANSI 彩色输出；不发布独立二进制。

## 详细设计

### 1. 命令与结果模型

结果模型同时就是 `--json` 的输出；字段名与 `MCPRuntimeTypeInfo` 对齐。

```swift
public enum SourceSelector: Codable, Sendable, Hashable {
    case local                                      // "local"，默认
    case macCatalyst                                // "catalyst"      ┐
    case attachedProcess(processIdentifier: pid_t)  // "pid:1234"      │ 本提案一律 sourceUnavailable，
    case attachedProcessNamed(String)               // "process:Finder"│ 由多来源提案实现
    case engine(identifier: String)                 // "engine:<id>"   ┘
}

public enum Command: Codable, Sendable {
    case listImages(ListImagesCommand)           // source, loadedOnly, query
    case loadImage(LoadImageCommand)             // source, imagePath
    case listTypes(ListTypesCommand)             // source, image, kinds
    case searchTypes(SearchTypesCommand)         // source, image, query, isRegularExpression
    case interface(InterfaceCommand)             // source, image, typeName, options
    case hierarchy(HierarchyCommand)
    case relationships(RelationshipsCommand)
    case memberAddresses(MemberAddressesCommand) // + memberName
    case specialize(SpecializeCommand)           // typeName, image, arguments: [String: String], listOnly
    case export(ExportCommand)                   // image, outputDirectory（绝对路径）, objcFormat, swiftFormat, includeMetadata, options
    case hostStatus
    case shutdownHost(ShutdownReason)            // .userRequest | .applicationTakeover
    // 多来源提案追加：listSources / attach / detach
}

public enum GenerationOptionsChoice: Codable, Sendable { case `default`, full, application }

public struct CommandFailure: Codable, Sendable, Error {
    public enum Code: String, Codable { case sourceUnavailable, imageNotFound, typeNotFound, exportFailed, hostBusy, unsupportedProtocolVersion, internalError }
    public let code: Code
    public let message: String
}
```

`CommandResult` 一命令一 case；`TypeInfo { name, displayName, kind, imagePath, imageName }`、
`InterfaceResult { typeInfo, interfaceText }`、`ExportResult` 沿用 `RuntimeInterfaceExportResult` 的
五个计数。

### 2. 线路协议

```swift
enum ClientMessage: Codable { case hello(Hello); case command(requestIdentifier: UUID, Command); case cancel(requestIdentifier: UUID) }
enum HostMessage: Codable   { case welcome(Welcome); case progress(requestIdentifier: UUID, CommandProgress); case completed(requestIdentifier: UUID, CommandResult); case failed(requestIdentifier: UUID, CommandFailure) }

struct Hello: Codable   { let protocolVersion: Int; let clientVersion: String }
struct Welcome: Codable { let protocolVersion: Int; let hostVersion: String; let hostKind: HostKind; let processIdentifier: pid_t }
enum HostKind: String, Codable { case standalone, application }
```

- 帧：`UInt32` 大端长度 + JSON。`protocolVersion` 不等时客户端报错；host 是独立的就自动重启它
  （它是客户端自己拉起来的），是 App 的则提示更新 App。
- `export` 在完成前发 `progress`（沿用 `RuntimeInterfaceExportEvent` 的阶段与 `current/total`）。
- 客户端把所有路径解析成绝对路径再发送——host 的工作目录与客户端无关。
- 安全边界：socket 文件 `0600`；host 用 `LOCAL_PEERCRED` 核对对端 uid 等于自己。只服务同一用户。

### 3. host 生命周期

目录 `<AppSupport>/RuntimeViewer[-Debug]/CommandLineHost/`（Debug 后缀跟随 `RuntimeViewerSettings`
的目录约定），内有 `host.sock`、`host.lock`、`host.json`（`{pid, kind, version, startedAt}`）、
`host.log`。目录可注入（`CommandLineHostPaths(rootDirectory:)`），测试指向临时路径。

- **连接与拉起**（`CommandLineHostClient`）：`connect`；`ENOENT` / `ECONNREFUSED` → 对 `host.lock`
  取 `flock(LOCK_EX)` → 再 `connect` 一次（别的客户端可能刚拉起）→ 仍失败才 `posix_spawn` 自己的
  可执行文件带 `host --idle-timeout <秒>`（`POSIX_SPAWN_SETSID`，stdio 重定向到 `host.log`）→
  轮询 `host.sock` 最多 10 s → 释放锁。`--no-spawn` 关掉自动拉起。
- **单例**：host 存活期间对 `host.lock` 持共享锁之外的独占标记（`host.json` 写入 + 独占 `flock`
  在另一把 `host.pid` 锁上），两个 host 互斥。
- **空闲退出**：`activeConnections == 0 && inFlightCommands == 0` 持续 `idleTimeout`（默认 600 s；
  `--idle-timeout 0` 不退出；环境变量 `RUNTIME_VIEWER_CLI_IDLE_TIMEOUT` 改默认）即退出，退出前断开
  引擎、按 0006 的守卫删 socket 文件。计时器注入 `any Clock<Duration>`。
- **接收 `shutdownHost`**：`.userRequest` 与 `.applicationTakeover` 都是「不再接受新连接 → 等在途
  命令跑完 → 退出」；区别只在日志与 `host status` 的最后状态。
- **客户端重试**：命令中途掉线时，只对只读命令对新 host 重试一次；`export` 不重试。

### 4. 命令面

全局选项 `--source <selector>`（默认 `local`）、`--json`、`--timeout <秒>`、`--no-spawn`。

| 子命令 | 作用 | 引擎调用 |
|---|---|---|
| `images [--loaded] [--query q]` | dyld 可见镜像；`--loaded` 只列已解析的 | `imageList` / `loadedImagePaths` |
| `load <imagePath>` | 加载并解析 | `loadImage(at:)` + `objects(in:)` |
| `types [--image i] [--kind k]...` | 列类型；未加载的镜像自动加载（与 MCP 一致） | `objects(in:)` |
| `search <query> [--image i] [--regex]` | 子串或正则匹配类型名 | `objects(in:)` |
| `interface <type> [--image i] [--full \| --options app]` | 完整接口文本 | `interface(for:options:)` |
| `hierarchy <type>` / `relationships <type>` / `members <type> [--member m]` | 层级 / 关系 / 成员地址 | 对应方法 |
| `specialize <type> --image i [--list] [--argument Param=Type]...` | `--list` 列泛型参数与候选；否则 preflight 后输出特化接口 | `specializationRequest` / `runtimePreflight` / `specialize` |
| `export <image> --output dir [--objc single\|directory] [--swift single\|directory] [--no-metadata]` | 整镜像导出，进度到 stderr | `exportInterfaces(with:reporter:)` |
| `host status \| stop \| restart` | 独立 host 的查看 / 停止 / 重启 | — |

- 类型解析：先精确匹配 `name`，再 `displayName`；`--image` 接受完整路径或不带扩展名的短名，
  短名解析顺序照搬 `MCPBridgeServer.resolveImagePaths`。未给 `--image` 时在已加载镜像里找，一个
  也没加载时报 `imageNotFound` 并提示先 `load`。
- 生成选项：默认库默认值；`--full` = `.mcp`；`--options app` 让 host 只读地取 App 的持久化选项
  与 transformer 配置（用 Core 的 `Codable` 读文件，文件不存在即退回默认值）。
- 输出：`interface` 直接打印文本；列表类命令对齐的列；`--json` 时 stdout 只有一个 JSON 文档，
  错误也以 JSON 打到 stdout。
- 退出码：`0` 成功；`1` `CommandFailure`；`64` 参数错误（swift-argument-parser 默认）；`69` host
  不可达且无法拉起。

### 5. 测试（`RuntimeViewerCommandLineTests`，swift-testing）

- 协议：每个 `Command` / `CommandResult` 编解码往返；帧解析的半包与粘包；版本不匹配。
- host：可控 `Clock` 下的空闲退出（有连接不退、有在途不退、归零到期退）；假 spawner 下的
  「连不上 → 加锁 → 再试 → 拉起」序列；`shutdownHost` 两种原因的收尾。
- 端到端：测试进程内起一个绑到临时 socket 的 host，本地引擎按 `TestRuntimeEngine` 配方加载
  libobjc 与 Foundation，走真实客户端代码路径执行 `interface NSObject --image
  /usr/lib/libobjc.A.dylib --json`，断言含 `@interface NSObject`；`types` / `search` / `members` /
  `export` 各一条；文本渲染快照比对。

## 替代方案考量

方向性的（一次性进程、复用镜像协议、交互式 shell）见愿景取舍二、四。本提案层面：

- **用 XPC 做客户端↔host 通道。** 独立 host 不经 launchd 注册不了 Mach service，匿名端点需要中介
  交换；Unix domain socket 没有这些前置，且与 MCP bridge 先例同构。
- **客户端渲染放在 host。** host 回纯文本会让 `--json` 与文本两套逻辑都进 host，且 App 充当 host
  时要为 CLI 维护渲染代码；模型回客户端，渲染留在 CLI，App 只跑执行器。
- **把 `SourceSelector` 留到多来源提案再定义。** 那会让 `Command` 的每个 case 在下一篇改签名；
  现在定义全集、本提案只实现 `.local`，改动局部在 `SourceResolving` 实现。

## 影响

### 用户可见变化

新增命令行工具（仅 `swift build` 产物）。App 无任何变化。

### 可发现性

`runtime-viewer-cli --help`；README「Getting Started」新增「Command Line Interface」一节说明如何
构建与使用；使用指南 `Documentations/Guides/CommandLineInterface.md`。

### 数据与配置兼容

新文件集中在 `<AppSupport>/RuntimeViewer[-Debug]/CommandLineHost/`；`--options app` 只读 App 的文件。

### 平台与最低版本

macOS 15+（跟随 `RuntimeViewerPackages`，为多来源提案预留同一下限）。仅 macOS。

### 发布

本提案不产生随 App 分发的制品。

## 落地步骤

1. 新包骨架、命令与结果模型、帧编解码、`Hello` / `Welcome`。协议测试通过。
2. `CommandExecutor` + `LocalSourceResolver`，逐个接命令；端到端测试先覆盖 `interface` / `types`。
3. `CommandLineHostServer` / `CommandLineHostClient`、拉起与单例、空闲退出、`shutdownHost` 接收端。
   host 生命周期测试通过。
4. `main.swift` 与渲染器；`export` 进度；退出码。
5. 文档：新建 `Documentations/Guides/`（登记进 `Documentations/README.md` 目录表）与
   `Guides/CommandLineInterface.md`；README 新增一节与 Highlights 条目；`AGENTS.md` Package
   Structure 加新包。
6. 验证：`swift build -c release --product runtime-viewer-cli` 产出；无 App 时 `interface NSView
   --image AppKit` 能拉起 host 并输出；`host status` 显示 `standalone`；空闲到期后 `host.json` 消失。

**收尾时必须判断**：配套文档——使用指南必写（「相对路径在客户端解析」「Debug / Release 目录配对」
「空闲退出」都是签名看不出的契约）；术语表——引入「CLI host」「source selector」，落地时新建
`Documentations/Glossary.md` 登记。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-06 | Created as Draft | 从单篇草案「RuntimeViewer 命令行工具」拆出，用户要求分 3-4 个提案 |
| 2026-09-06 | 常驻 host + 命令级协议 | 用户选定（愿景取舍二、四）；「Helper」改称 CLI host 见愿景 |
| 2026-09-06 | 本提案只接 `.local`，但定义全部 `SourceSelector` 与全部查询命令 | 让它不依赖抽模块提案而能最早交付；selector 全集现在定，避免下一篇改 `Command` 签名 |
| 2026-09-06 | socket 目录带 Debug 后缀、空闲 600 s、`--json` 即结果模型、生成选项三档 | 用户在收尾确认轮确认 |

# 愿景：无头 RuntimeViewer

- **状态**: Draft
- **最后更新**: 2026-09-06
- **相关提案**: [draft-engine-management-module](../Evolutions/draft-engine-management-module.md)、[draft-command-line-interface-foundation](../Evolutions/draft-command-line-interface-foundation.md)、[draft-command-line-interface-multi-source](../Evolutions/draft-command-line-interface-multi-source.md)、[draft-command-line-interface-app-embedding](../Evolutions/draft-command-line-interface-app-embedding.md)

愿景**不做具体决定**，它划定一个方向的边界与取舍原则，让后续每个提案不必重新论证一遍。

## 这是什么领域

**不打开 RuntimeViewer 的窗口，也能用上它的每一项能力。**

**算在里面**：命令行工具 `runtime-viewer-cli`；承载它的常驻进程（下称 **CLI host**）；
让 GUI 之外的进程也能拿到全部运行时来源（本机进程内引擎、Mac Catalyst helper、注入的 macOS
进程、注入的 iOS Simulator 进程、Bonjour 对端与镜像引擎）的分层调整；今后把 MCP bridge
也搬出 App 进程。

**不算在里面**：接口怎么从运行时元数据生成（`RuntimeViewerCore`）、GUI 自身的信息架构、
特权 helper daemon 的安装与升级、Simulator 里的 RuntimeViewer 安装器。

一句话：**GUI 只是这些能力的一个前端，命令行与 MCP 是另外两个，三者共用同一台引擎管理
与同一套命令词汇。**

## 为什么值得系统性投入

今天 RuntimeViewer 的所有能力只经两条路触达：GUI，以及 GUI 进程内的 MCP bridge——后者的
每个工具都要一个 `windowIdentifier`（`RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPBridgeServer.swift:134-146`），
没有打开的文档窗口就一个类型也拿不到。脚本与批处理、无人值守的 agent 工作流、SSH 进来的
远程会话，三类场景全被挡在外面。本仓库自己的 `AGENTS.md`「SourceEditor Module」一节都要求
以「RuntimeViewer 的自有导出」为逆向前置材料，而这一步今天必须由人在 GUI 里点出来。

一个提案解决不了：把引擎管理从 UI 层搬出来是一篇，命令行工具的协议与常驻进程是一篇，
多来源与 App 共存是一篇，嵌进 App 包与设置页又是一篇，每篇都得能单独构建、单独验证。
不先定方向，四篇都要把「要不要常驻」「App 在跑时听谁的」「客户端说什么协议」重吵一遍。

## 现状与代价

多来源能力被 UI 层锁死。`RuntimeEngineManager`（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Engine/RuntimeEngineManager.swift`，
1245 行，`@MainActor` 单例）的 `init` 一口气启动 Bonjour 服务端、浏览器、系统引擎与引擎共享
（:176-216），没有任何一处能说「只做客户端、不广播自己」；它 `import AppKit`（图标）、
`import RuntimeViewerArchitectures`（Rx 桥接），依赖用 `UNUserNotificationCenter` 的
`RuntimeConnectionNotificationService`。注入的收尾一半还在 App target 的
`AttachToProcessViewModel`（`RuntimeViewerUsingAppKit/.../Attach Process/AttachToProcessViewModel.swift:60-140`）。

代价具体到两条：

1. **任何 GUI 之外的前端都只能拿到本地引擎。** 那只是同门 `swift-section` 的运行时版——
   RuntimeViewer 的差异化恰恰是注入正在运行的进程、看 Simulator 与 iOS 设备上的运行时。
2. **MCP 无头化被同一堵墙挡着。** 把 bridge 搬出 App 进程，遇到的正是同一批依赖。

## 根本的设计取舍

### 一、复用引擎管理：给 UI 层开缝，还是抽成无 UI 模块

**开缝**：CLI 直接链 `RuntimeViewerApplication`（MCP bridge 就是这么做的），给
`RuntimeEngineManager` 加几个开关。改动最小，但 CLI 带上 RxSwift、AppKit、UIFoundation 整套
依赖，UI 层继续持有本该是领域层的逻辑。

**抽模块**：发现、注入、重连、镜像、心跳搬进一个不依赖 UI 的模块，App 层只留图标、Rx 桥接与
系统通知。分层干净，代价是搬一个塞满 Bonjour / AWDL 可靠性补丁的大类，回归风险要靠测试兜。

### 二、进程模型：一次性进程，还是常驻 host

**一次性**：每条命令建连、查询、退出。零常驻状态，但同一镜像每次调用重新索引（Foundation
数秒），Bonjour 每次都要等发现。

**常驻 host**：一个后台进程持有引擎与索引，命令是短命的薄客户端。代价是多一套进程间协议与
生命周期（谁拉起、何时退出、怎么保证只有一个）。

### 三、与 App 共存：各跑各的，还是 App 优先

**各跑各的**：App 一行不改；但同一台 Mac 会出现两个 Bonjour 客户端、两个注入者，同一进程被
两边分别 attach 时的注册表行为未经验证。

**App 优先**：App 在跑时 App 就是 host，不在时才拉起独立 host。代价是 App 多一个本地监听，
以及独立 host 被 App 接管时的交接。

### 四、客户端协议：命令级，还是复用引擎镜像协议

**复用镜像协议**：host 用 `RuntimeEngineProxyServer` 在回环地址共享引擎，客户端按描述符建
DirectTCP 客户端引擎跑现有 RPC。查询零新协议；但每次调用两跳连接、每次接收 >1 MB 的初始
`imageList` 推送，attach / detach / shutdown 仍要新加消息。

**命令级**：客户端发 Codable 的命令，host 执行并回 Codable 的结果。要定义一套模型，但结果模型
同时就是 `--json` 的输出模型，也是将来 MCP 无头化可以直接复用的词汇。

### 五、能力边界：查询全覆盖，管理带多少

查询类能力（接口、层级、关系、成员地址、特化、导出）全部覆盖没有争议。管理类里，attach
必需的部分（把载荷装进 `/Library/Frameworks`）躲不掉；helper daemon 的安装 / 卸载依赖
`SMAppService` 与 App bundle，独立构建的 CLI 做不了，做了就是两种形态行为分叉。

### 六、交付形态：独立包、嵌入 App，还是都要

独立 SwiftPM 包 `swift build` 即可产出、不依赖 Xcode 工程；嵌入 App 包随 App 签名公证、能从
设置页装到 PATH、天然知道载荷与 Catalyst helper 在哪。两者的代码可以是同一份。

## 我们选的方向

以下六条均由用户于 2026-09-06 选定，各提案直接引用，不再论证。

**一、抽模块。** 新模块 `RuntimeViewerEngineManagement` 承载引擎管理；App 层只留图标、Rx
桥接与通知。

**二、常驻 host，自动拉起，空闲退出。** 第一条命令发现没有 host 就把它拉到后台；host 在规定
时间内没有连接也没有调用就自动退出。用户原话称之为 Helper，本愿景改称 **CLI host**，避免与
特权 helper daemon、Catalyst helper 混淆。

**三、App 优先。** App 在跑就由 App 充当 host；独立 host 只在 App 不在时存在，App 启动即接管。

**四、命令级协议。** Unix domain socket，长度前缀 JSON，Codable 的命令与结果；结果模型即
`--json` 输出模型；字段名与 MCP 的响应类型对齐，为 MCP 无头化铺路。

**五、查询全覆盖，管理只带 attach 必需的。** helper 安装与 Simulator 安装器仍由 App 完成。

**六、独立 SwiftPM 包与嵌入 App 包都要。** 同一份库代码，两个薄入口。

### 这个方向放弃了什么

- **CLI 的轻量。** 它链 `RuntimeViewerHelperClient` 与新模块，最低 macOS 15，与 App 同一下限；
  不追求一个 macOS 10.15 就能跑的纯本地小工具。
- **App 与 CLI 的完全解耦。** App 多一个本地监听与一次接管流程；关掉它的开关放在设置页里。
- **交互式 shell。** 常驻 host 已经解决了重复索引与重复发现的成本，不另做 REPL。
- **独立二进制的发布。** 独立形态只承诺可构建可运行，随 GitHub Release 附 zip 另议。

## 分阶段设想

四篇提案，依赖关系如图；②不依赖①，③依赖①与②，④依赖②（其中的开关依赖③）。

1. **引擎管理下沉**（[draft-engine-management-module](../Evolutions/draft-engine-management-module.md)）——
   `RuntimeEngineManager` 搬进无 UI 模块，加配置缝、资源定位缝、`RuntimeProcessAttacher`。
   行为零变化。
2. **命令行工具基础**（[draft-command-line-interface-foundation](../Evolutions/draft-command-line-interface-foundation.md)）——
   新包、命令与结果模型、线路协议、常驻 host 的拉起 / 单例 / 空闲退出、本地来源上的全部查询
   命令。不启动 App 就能查本机运行时，即用户最初的诉求。
3. **多来源与 App 充当 host**（[draft-command-line-interface-multi-source](../Evolutions/draft-command-line-interface-multi-source.md)）——
   独立 host 换上①的模块，`sources` / `attach` / `detach` 与全部来源寻址；App 启动即充当 host
   并接管独立 host。
4. **嵌入 App 包与设置页**（[draft-command-line-interface-app-embedding](../Evolutions/draft-command-line-interface-app-embedding.md)）——
   Xcode tool target 嵌到 `Contents/Helpers/`，设置页做 `/usr/local/bin` 符号链接与「允许命令行
   访问」开关。

之后可以接：**MCP 无头化**（bridge 搬进 host，工具直接复用命令词汇）、**独立二进制发布**。

## 不在此愿景内

- **helper daemon 的安装 / 卸载 / 重装**、**Simulator 里的 RuntimeViewer 安装器**。
- **让 CLI host 对局域网广播自己**或把引擎共享给对端。它只做 Bonjour 客户端。
- **改 `RuntimeEngine` 的请求集、任何既有线路协议、`RuntimeSource`。**
- **主题化的 ANSI 彩色输出**。纯文本与 `--json` 两种即可。
- **iOS 侧**。命令行只谈 macOS。

## 待确认

无。六条方向均已由用户选定；各提案里的实现假设在各自的「提议方案」中列出，由提案审阅时
逐一确认。

## 相关提案

| 提案 | 状态 | 它推进了愿景的哪一部分 |
|------|------|------------------------|
| [draft-engine-management-module](../Evolutions/draft-engine-management-module.md) | Draft | 方向一：引擎管理下沉为无 UI 模块 |
| [draft-command-line-interface-foundation](../Evolutions/draft-command-line-interface-foundation.md) | Draft | 方向二、四、六（独立包）：协议、常驻 host、本地来源上的全部查询命令 |
| [draft-command-line-interface-multi-source](../Evolutions/draft-command-line-interface-multi-source.md) | Draft | 方向三、五：全部来源、attach、App 充当 host |
| [draft-command-line-interface-app-embedding](../Evolutions/draft-command-line-interface-app-embedding.md) | Draft | 方向六（嵌入 App 包）与设置页 |

---

> **愿景是活文档**，随认识加深可以修订，修订时更新「最后更新」。

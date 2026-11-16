# 代码库体检 2026-11-16

- **分支与提交**: `next` @ `0a0003b8`（工作树另有两个 entitlements 文件的未提交改动，与本轮无关）
- **范围**: 首次体检，全仓分六块各由一个审查 agent 深审：Core 引擎；通信层与各服务外壳；AppCore；Packages 其余模块；macOS App 与 SourceEditor bridge；命令行工具、MCP 与 iOS App。全仓机械扫描在主线程做
- **降级**: 本轮早于 `audit-codebase` 流程，没有逐条派独立的复核 agent。六个高危问题由主线程逐条回到代码核对，并在修复前写出变红的测试确认；其余发现只经查找者本人核对，标「读代码确认」或「疑似」。没有跑 `jscpd` 一类重复检测工具
- **对照已裁决清单**: 查找时对照了 `Documentations/KnownIssues/`，已裁决且理由仍成立的跳过；发现 4 条以前记录过的问题仍未修好或修后又退回（见各条）

编号 `CA.<N>` 供提交说明和后续体检引用。

## 总评

整体守规矩：机械可查的规则里，`[unowned self]`、旧式 Rx 订阅、`strongSelf`、`print`、`layOut` / `setUp` 拼写全仓都是 0。问题集中在三处：

- **跨 actor 或跨进程的时序**：接口打印串配置、连接重建后丢处理器、镜像移除时整台主机被清掉；
- **把「位置」当「身份」**：过滤后的行号去删未过滤的数组；
- **任务强引用 ViewModel**：导出任务让 ViewModel 永远不释放，取消从不生效。

六个高危问题已在 `fix/high-severity-review-findings` 分支修复，每个都有修复前变红、修复后变绿的回归测试。最该接着处理的是：连接类之间约 220 行的复制（DirectTCP 与 Bonjour），以及 CLI 与 MCP 两套已经分叉的镜像与类型解析。

## 严重 bug

六条都已修复：先红的测试在 `d4c17c8c`、`7bf3d6d6`，修复在 `328536d4`。

### CA.1 不同选项的接口请求并发时，打印中途被改配置，错的结果还会进缓存

- **位置**: `RuntimeViewerCore/Sources/RuntimeViewerCore/Sections/Swift/RuntimeSwiftSection.swift` 的 `interface(for:)` 与 `updateConfiguration(...)`；`RuntimeEngine.swift` 里 5 个「先配置、再打印」的调用点
- **判定**: CONFIRMED（`SwiftInterfaceConcurrentOptionsTests` 修复前红）
- **失败场景**:
  - Swift section 是 actor，但打印要调用 nonisolated 的 async 函数，期间会让出 actor。
  - 另一个选项不同的请求（MCP、命令行，或另一个窗口）此时可以重新配置共享的 printer、清空缓存。
  - 结果：第一个请求打出两种配置混合的接口，并写进缓存，之后的请求都拿到它。
- **能复现吗**: 能。三个夹具类型、两套选项交替并发 25 轮，修复前有多次请求拿到的文本与单独打印的不一致
- **新的还是旧的**: 先配置再打印的写法始于 `fd2d30f9`（2026-07-23），main 上也有；把注释结构写进缓存始于 `c3ad6ca7`（2026-10-31）。早已存在
- **值不值得修**: 修。MCP 与命令行和窗口共用引擎是常态，错误的接口会一直留在缓存里
- **以前修过吗**: 语料打印在 0029 的决策日志（2026-09-29）里因为同一原因改用了第二个 printer；显示路径当时没有一起改，`c3ad6ca7` 只保护了两个标记位
- **修法**: section 加一道 `AsyncSemaphore` 串行门，「配置、打印、写缓存」合成一步，协议只暴露带选项的 `interface(for:options:)` 与 `importedInterface(for:options:)`
- **同类实例**: `importedInterface(for:)` 同一个 printer，一并修复；ObjC section 每次调用都新建 builder，没有共享状态

### CA.2 过滤时删除书签，删掉的是另一个

- **位置**: `SidebarRootBookmarkViewModel.swift` 与 `SidebarRuntimeObjectBookmarkViewModel.swift` 的 `removeBookmark`；两个书签视图控制器的 `rootIndex(forRow:)`
- **判定**: CONFIRMED（两个书签测试里的新用例修复前红）
- **失败场景**: 书签 A、B、C，过滤到只剩 C，对 C 点 Remove Bookmark（或按 Delete）→ 视图层传的是 C 在可见行里的序号 0 → ViewModel 删掉完整列表里的第 0 个，也就是 A
- **能复现吗**: 能。修复前删掉的是 Foundation 与 `NSObject`，测试期望留下的正是它们
- **新的还是旧的**: `5acf5b2f`（2026-01-12），main 上也有。早已存在
- **值不值得修**: 修。用户数据（书签）被静默删错
- **以前修过吗**: 没有。作者注意到了过滤时移动会出错（过滤时禁用移动），没顾及删除
- **修法**: 删除输入改为这一行的 cell ViewModel，按身份删除；`rootIndex(forRow:)` 随之删去

### CA.3 导出时点 Cancel 并不会停下

- **位置**: `ExportingProgressViewModel.swift`、`BatchExportingProgressViewModel.swift`
- **判定**: CONFIRMED（`OwnerReportingTaskTests` 两条修复前红）
- **失败场景**:
  - 两个导出任务都是 `Task { [weak self] in guard let self … }`，整个导出期间强引用着 ViewModel。
  - 所以 ViewModel 里负责取消任务的 `deinit` 永远不会执行，Cancel 只关掉了 sheet。
  - 导出继续写文件，结束时还要通过 `unowned` 的 router 触发路由。
- **能复现吗**: 停不下来已确认；结束时会不会因为 `unowned` 崩溃没有实测
- **新的还是旧的**: `63c74eb3`（2026-02-18），main 上也有
- **值不值得修**: 修。用户以为取消了，磁盘却还在被写，可能还会崩溃
- **以前修过吗**: 没有
- **修法**: 新增 `OwnerReportingTask`（AppCore），工作只在汇报时弱引用持有者，随持有者释放而取消，取消后不再汇报，也不把取消当失败；两个 ViewModel 改用它，批量导出被取消后不再开新的镜像

### CA.4 对端撤掉一个共享引擎，本机清掉那台机器的全部镜像

- **位置**: `RuntimeEngineManager.swift` 的 `handleEngineListChanged` 与 `cleanupMirroredEnginesOnDisconnect`
- **判定**: CONFIRMED（`MirroredEngineWithdrawalTests` 修复前红）
- **失败场景**:
  - 协调移除一个镜像后，先调了 `stop()`，没有取消它的状态订阅。
  - `stop()` 发出的断开事件回到 `handleStateChange`，这时注册表里已经没有这个镜像。
  - 于是落进「直连对端断开」分支，按主机 ID 前缀把同一台机器的所有镜像都移除并停掉，开在上面的窗口全部失去引擎。
- **能复现吗**: 能。修复前留下的那个镜像被移除并断开
- **新的还是旧的**: 按前缀清理始于 `b350f8c1`（2026-05-01，KnownIssues EM.2 的修复），main 上也有
- **值不值得修**: 修。对端 Attach / Detach 一个进程就能触发
- **以前修过吗**: 没有。`terminateRuntimeEngine` 早就先取消订阅再停止（注释写明了原因），镜像的三处移除点没有照做
- **修法**: 三处统一走 `stopRemovedMirrors(_:)`，先取消订阅再停止

### CA.5 Bonjour 与直连 TCP 服务端接新连接时丢掉消息处理器

- **位置**: `RuntimeNetworkServerConnection.swift`、`RuntimeDirectTCPServerConnection.swift`
- **判定**: CONFIRMED（`TransportHandlerReplayTests` 两条修复前红，报 `No handler registered for echo`）
- **失败场景**:
  - 处理器只设在当时那个底层连接上；每接受一个客户端都会换一个新的底层连接，处理器表是空的。
  - 引擎要等收到 `.connected` 之后才重新注册，客户端在这之前发来的请求得到「没有处理器」。
  - 调用方把这个回答当成对方是旧版本，于是悄悄关掉相关功能。
- **能复现吗**: 能
- **新的还是旧的**: `2cd10e27`（2026-03-03）等，main 上也有
- **值不值得修**: 修。重连是常态
- **以前修过吗**: 本地 socket 在 `fe442fa2`（2026-03-31）补过同样的重放，但只修在本地 socket 的两个类上，另两种传输没有跟进
- **修法**:
  - 新增 `RuntimeMessageHandlerReplay`，按消息名保存处理器，同名替换，这样服务端每次重连后重新注册也不会越积越多；
  - 新增 `RuntimeHandlerReplayingConnection`，在协议扩展里提供 5 个会记录、会重放的 `setMessageHandler`；
  - 四个服务端与客户端类都改用它，新的底层连接在开始收数据前先重放；
  - Bonjour 被接受的连接改为由服务端在挂好处理器后再 `start()`。

### CA.6 纯文本编辑器在文本末尾之后右键会抛 `NSRangeException`

- **位置**: `ContentTextViewController.swift` 的 `textView(_:menu:for:at:)`
- **判定**: CONFIRMED（`ContentLinkLookupTests` 修复前子进程 SIGABRT）
- **失败场景**:
  - 在最后一行下方、空白或正在加载的面板里右键，AppKit 传来的字符位置等于文本长度。
  - 对 `NSTextStorage` 在这个位置取属性会抛异常，App 崩溃。
  - 实测：不可变的 `NSAttributedString` 在这里返回 `nil`，可变字符串与 `NSTextStorage` 都会抛。
- **能复现吗**: 能（用 `NSTextStorage` 复现；没有在真实窗口里右键实测）
- **新的还是旧的**: `81aa58c7`（2024-11-21），main 上也有
- **值不值得修**: 修。用户能走到的崩溃
- **以前修过吗**: SourceEditor 那份同样的代码在 `0ca88855`（2026-08-19）就带了边界检查；纯文本这份一直没有
- **修法**: AppCore 的 `NSAttributedString.linkedRuntimeObject(at:)` / `declaredMember(at:)` 先判边界，两个面板共用

### 修复的验证

在 `JHs-Mac-Studio-Ultra`（macOS 27.2、Xcode 27.2）上，对修复提交 `328536d4` 做了以下验证：

- **新写的回归测试**：全部通过。
- **App 编译**：Debug workspace、`Debug-arm64e`、关签名，编译通过；MCP 包测试与命令行工具包编译也通过。
- **全量测试中的失败**：Core 与 Packages 全量并行时出现一批超时（当时负载均值约 73），负载降下后单独重跑全部通过。
- **唯一稳定复现的失败**：`InjectedDeviceEngineTests` 的两条在整个 `RuntimeViewerEngineManagementTests` 一起跑时必失败；在基线 `0a0003b8` 上用同样条件也一样失败，单独跑这个套件则通过。所以是基线已有的测试间干扰，不是本次引入的，记为 CA.30。

## 其余逻辑问题（未修，按严重程度）

| 编号 | 问题 | 位置 | 判定 | 备注 |
|------|------|------|------|------|
| CA.7 | 文本编辑器每显示一个对象就多装一个按键监听，窗口关闭前不释放 | `ContentTextViewController.swift:162` | 读代码确认 | |
| CA.8 | 批量导出直接调 `loadImage`，绕开 Report 的 Manual Loading，也不阻止 App Nap（切到后台约 30 秒后会被降速） | `BatchExportingProgressViewModel.swift` `exportOne` | 读代码确认 | 违反根 `AGENTS.md` 对手动加载的规定 |
| CA.9 | 打印接口出错被 `try?` 吞掉，用户只看到「找不到」 | `RuntimeEngine.swift` 的 `_interface` 与 `resolveSwiftReferenceInterface` | 读代码确认 | |
| CA.10 | 引擎停止时还没建完的 section 会在之后注册回去 | `RuntimeSwiftSectionFactory.swift` `registerBuiltSection`、`RuntimeObjCSectionFactory.swift` | 读代码确认 | |
| CA.11 | 对象列表的加载流取消后，后台仍读完整个镜像 | `SidebarRuntimeObjectListViewModel.swift:257`、`RuntimeEngine.objectsWithProgress` | 读代码确认 | 即 KnownIssues M6.1 / M6.6，记录过但未修 |
| CA.12 | 主题编辑器关闭前 150 毫秒内的最后一次修改会丢失 | `ThemeSettingsView.swift:328` | 读代码确认 | KnownIssues TS.1 修过，代码又改回去了 |
| CA.13 | Helper 状态每刷新一次，两个客户端各重连一次 | `RuntimeHelperClient.swift:47`、`RuntimeInjectClient.swift:55` | 读代码确认 | |
| CA.14 | MCP 只按镜像路径记录「已加载」，不分引擎 | `MCPBridgeServer.swift:62` | 读代码确认 | |
| CA.15 | MCP 的 `memberAddresses` 把成员地址查询的错误报成「加载失败」 | `MCPBridgeServer.swift:398` | 读代码确认 | |
| CA.16 | 注入 socket 的记录文件不分 Debug 与 Release | `RuntimeEngineManager.swift:227` | 读代码确认 | MCP 端口文件的同类问题已在本批修好 |
| CA.17 | 本地 socket 连接的描述符在三个队列间读写无同步，关闭后可能写进被复用的描述符 | `RuntimeLocalSocketConnection.swift:252` | 疑似 | |
| CA.18 | 本地 socket 服务端 `accept` 失败一次就永久停止监听 | `RuntimeLocalSocketServerConnection.swift` 接受循环 | 疑似 | |
| CA.19 | 对端在预检期间断开，仍会建出没人清理的镜像 | `RuntimeEngineManager.swift:518` | 读代码确认 | 即 KnownIssues UR.5，未修 |
| CA.20 | 导出配置页出错后，转圈一直不消失 | `ExportingConfigurationViewModel.swift:50` | 读代码确认 | |
| CA.21 | 代理启动失败时，可能把同名的新代理从表里移除 | `RuntimeEngineManager.swift:1775` | 疑似 | |
| CA.22 | 本地 socket 客户端在一个很窄的时间窗里会丢掉重连 | `RuntimeLocalSocketClientConnection.swift` `startReconnecting` | 疑似 | |
| CA.23 | NWConnection 收数据出错时丢掉了错误原因 | `RuntimeDirectTCPConnection.swift`、`RuntimeNetworkConnection.swift` 的接收回调 | 读代码确认 | |
| CA.24 | Bonjour 客户端在引擎挂好处理器前就开始收数据 | `RuntimeNetworkConnection.init(endpoint:)` | 疑似 | 服务端一侧已随 CA.5 修好 |
| CA.25 | XPC service 客户端的 `.connected` 可能盖掉 `.disconnected`，几秒后自愈 | `RuntimeXPCServiceClientConnection.swift:255` | 疑似 | |
| CA.26 | 命令行 host 接管时可能输给客户端拉起的独立 host，App 不再重试 | `CommandLineHostServer.swift:379`、`CommandLineHostController.swift:57` | 疑似 | |
| CA.27 | 连接落在 host 闲置退出的时间窗里，不可重试的命令直接失败 | `CommandLineHostServer.swift:199`、`CommandRunner.swift:71` | 读代码确认 | 与已裁决的 PR112.6 不是同一个时间窗 |
| CA.28 | 跨引用导航用的是没合并的生成选项 | `FindViewModel.swift:419`、`InspectorReferencesViewModel.swift:328` | 疑似 | |
| CA.29 | 文件模式的目录只能查类，查不了协议 | `RuntimeFileImageCatalog.swift:252` | 疑似 | |
| CA.30 | `InjectedDeviceEngineTests` 的两条在整个引擎管理测试包一起跑时必失败，单独跑通过 | `InjectedDeviceEngineTests.swift:314`、`:386` | 基线上同样复现 | 测试之间互相干扰，原因未查；可能是 `RuntimeUnusedPort.find()` 给出的端口在绑定前被同包里别的测试占走 |

## 规则

### 存量（首次体检，按条列出）

| 规则 | 位置 | 说明 |
|------|------|------|
| 埋点只用 `@Signpostable` + `#signpostInterval` | `ContentTextViewModel.swift:21`、`SpecializationTypePickerViewModel.swift:29` | 手写 `OSSignposter`；前者注释说是照抄后者的先例 |
| 日志只用 `#log` | `ServicePluginEntry.swift:20`；`RuntimeEngineManager.swift:1439` 起 5 处 `Self.logger` | plugin 能链接日志宏所在的库，算违规。Catalyst helper 是不链任何包的外壳，不算 |
| `#log` 不以手写 `[Tag]` 开头 | `RuntimeEngineConnectionServer.swift`、`RuntimeEngineProxyServer.swift` 共 15 行 | 前缀是运行时的实例标签 |
| 日志只用 `#log` | 命令行 `CommandLineHostPaths.swift:96` 的 `HostLog.write` | 独立 host 时写进 `host.log` 没问题；App 当 host 时这些诊断只进 stderr，丢失 |
| 每个 ViewController 有 ViewModel，业务逻辑不进 ViewController | `MainWindowController.swift:322-509`（约 190 行）；`ExportingViewController.swift` | |
| 对象命令走 `RuntimeObjectAction` | 两个内容面板的 Open in New Tab / Next Editor Pane | 手写标题与 relay |
| 一个文件一个顶层类型 | `SharedCache/RuntimeEngineSpanningCommand.swift` | 两个协议在一个文件里 |
| 根 `AGENTS.md` 不超过 64 KiB | `AGENTS.md`（67.7 KB） | Codex 只读前 64 KiB，超出部分被悄悄丢掉；本批修 MCP 一节时只多了约 100 字节 |
| 标识符不缩写 | 连接类里的 `val`、`addr`、`ptr`（单文件最多 18 处）；13 处单字母泛型参数 | `val` 已随 `RuntimeOnceFlag` 消失 |
| 文档与代码一致 | 根 `AGENTS.md` 的 MCP 一节描述的是已删掉的 TCP 桥架构 | 本批已改写 |

## 重复代码

**本批已合并**：

- 处理器重放 10 份 → `RuntimeMessageHandlerReplay`（随 CA.5）
- 「只恢复一次」保护 17 处 → `RuntimeOnceFlag`
- 引擎就绪检测 5 份 → `RuntimeEngineReadinessEdgeObserver`；`DocumentState` 处理自身引擎的那份原来缺 `isClosed` 判断，借此补上
- 应用支持目录名、MCP 端口文件路径、MCP 客户端配置片段 → 集中到 `Settings`；端口文件从此按 Debug 分目录
- 引擎里 5 处手写的 Swift 配置调用 → 随 CA.1 消失

**未合并**：

| 重复 | 位置 | 该合并到哪里 |
|------|------|-------------|
| DirectTCP 与 Bonjour 两个连接类各约 220 行，几乎相同；`NWParameters` 设置 4 份、监听器接受闭包每个服务端 2 份 | `RuntimeDirectTCPConnection.swift`、`RuntimeNetworkConnection.swift` 及两个服务端 | 一个基于 `NWConnection` 的底层连接加一个监听器助手；属大型重构，要先写提案 |
| CLI 与 MCP 各一套镜像与类型解析，已分叉：子对象、排序、裸名加载三处不一致 | `ImageResolver.swift`、`CommandExecutor.swift`、`MCPBridgeServer.swift` | KnownIssues PR112.17 已建议移进 Core；在那之前至少把 PR112.12 与 PR112.3 的修法补到 MCP |
| 两个内容面板的右键菜单与命令各约 90 行 | `ContentTextViewController.swift`、`ContentSourceEditorViewController.swift` | 一个基于 `RuntimeObjectAction` 的菜单构建器 |
| 单个导出与批量导出两套向导：协调器约 45 行、配置 ViewModel 约 48 行 | `Exporting/`、`BatchExporting/` | 一个通用的向导协调器 |
| 「按需索引镜像」5 份，彼此已不一致（`loadImage` 与 `loadImageForUser` 混用） | `RuntimeEngine+ImageIndexing.swift`、`ContentImageViewModel.swift`、`DocumentState+ManualLoading.swift`、`SidebarRuntimeObjectListViewModel.swift` | 一个返回对象、可选进度的引擎助手 |
| 共享缓存所有者订阅 4 份；设置重订阅循环 3 份 | `DocumentState.swift` 与三个协调器 | 共享助手，或改用 `Observable.tracking` |
| ObjC 跨镜像接口回退 2 份；进度路由设置 2 份（一份有取消后丢弃，一份没有） | `RuntimeEngine.swift` | 各一个私有助手 |
| 导航页的焦点、标签切换栏与滚动布局设置 4 份 | 四个侧栏页面控制器 | 规则手册规定的形状，优先级低 |
| `Then.swift` 5 份（4 份相同） | AppCore、AppUI、RuntimeViewerUI、App、iOS App | 见「建议不修」 |

## 死代码

| 位置 | 判定依据 |
|------|---------|
| `RuntimeEngine.swift` 两个带 `[unowned object]` 的 `setMessageHandlerBinding(forName:of:to:)` 重载 | 全仓无调用方（按方法名搜过） |
| `RuntimeStdioClientConnection` / `RuntimeStdioServerConnection` | 只有自身定义与测试引用 |
| `removeSection(for:)`（Swift 与 ObjC 两个 factory） | 生产代码无调用方 |
| `LoadFrameworksViewController` 及其空 ViewModel | 无引用；Load Frameworks 已改用 `NSOpenPanel` |
| `InspectorRuntimeNodeViewModel`；`FilterEngine.filter(context:items:)` 与 `FilterableItem` | 只有测试引用 |
| `RuntimeMessageChannel.receivingBufferSize` | 无引用 |
| 大段注释掉的代码 | iOS App `ContentTextViewController.swift:47-82`（36 行）、`InspectorViewModel.swift:13-33`、`MainViewModel.swift:284-295`、`MainToolbarController.swift:11-17`、`ContentTextViewController.swift:127-136` 等 |
| iOS App `MainCoordinator.swift` 的 `compactSidebarCoordinator` 与没人订阅的 `completeTransition` | 无引用 |

搜动态引用时排查过 selector、类名字符串与 storyboard（工程没有 nib）。

## 建议不修（用户确认后登记进已裁决清单）

用户已全部确认，登记为 [`KnownIssues/2026-11-16-codebase-audit-findings.md`](../../KnownIssues/2026-11-16-codebase-audit-findings.md) 的 CA.31–CA.35。

| 发现 | 理由 | 重新判断的条件 |
|------|------|---------------|
| 「进程是否存活」7 份判断，其中 3 份漏判 `EPERM` | 误报。注入服务那份其实判了；CLI 两份是在等自己的 host 进程退出，进程号被系统分给别的用户的进程（`EPERM`）正说明 host 已退，不算对。7 份各自正确且有注释，合并要给 3 个清单里的 4 个 target 加依赖，不值得 | 又出现第 8 份，或某份的语义出错 |
| `Then.swift` 在各模块各有一份 | 每份都是模块内部的 `protocol Then`，不对外导出 `then`；合并成公开的就会进各模块的公开接口 | 有了适合放它的 `package` 级共享模块 |
| `BatchExportingState` 的 `@RxObserved var` 没有 `private(set)` | 它是几个步骤 ViewModel 与协调器共写的状态对象，不是 ViewModel，那条规则不适用 | — |
| Catalyst helper 的 `AppDelegate` 手写 `Logger` | 外壳不链任何包，用不了日志宏 | 外壳改为链接包 |
| App target 里有 18 个 ViewModel | 没有规则禁止，只是测不到；不算违规 | 规则改为要求 ViewModel 都在 AppCore |

## 下一轮

- **从未深审的模块**：`RuntimeViewerUI`、`RuntimeViewerDeviceInjection`、`RuntimeViewerSimulatorInstaller`、`RuntimeViewerUtilities`、`RuntimeViewerSourceEditorBridge`。
- **深审过但没读到的部分**：
  - Core 的 `Search/Corpus/RuntimeInterfaceCorpusStore.swift`、`RuntimeInterfaceTextMatcher`、`RuntimeMemberDeclarationLocator`、`RuntimeTypeRelationshipsResolver`、`SharedCache/*`、`File/RuntimeFile.swift`、`LocalService/`；
  - 通信层的 `XPCMachService` 子类与 `CrossReferenceQuery`；
  - AppCore 的 `EditorArea`、`FindSession`、`FindCorpusCoordinator` 的构建与恢复核心、Theme、Storage；
  - 引擎管理的注入设备与握手部分（约 926–1395 行）；
  - App 的大部分侧栏与 Inspector 页面、`EditorPaneViewController`、Attach Process；
  - CLI 的 `EngineManagerSourceResolver`、`SourceCatalog` 与渲染器。

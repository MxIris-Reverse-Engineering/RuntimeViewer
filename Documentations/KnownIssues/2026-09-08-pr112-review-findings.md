# PR #112 审查裁决 — 2026-09-08

审查对象：PR #112（`feature/command-line-interface` → `next`，`runtime-viewer-cli` 基础提案），
head `6c7bc74f`，45 个文件 / +5700。

两轮产出合并：`/code-review xhigh` 报了 15 条，另一个会话（`runtimeviewer-f3`）对每条做了对抗性
复核——构建 CLI、自写协议客户端与假 host、真机跑实验。复核结论：**0 条推翻、11 条维持、4 条修正**
（`PR112.4` 低估、`PR112.10` 算错、`PR112.6` 否定过头、`PR112.9` 高估），另**补出一条审查未报的
缺陷**（`PR112.2`），它比 `PR112.1` 更基础。

**基线是 `next`，不是 `main`** —— `RuntimeViewerCommandLine/` 整个包是本 PR 新增的，`main` 上不
存在，所以除 `PR112.12` / `PR112.17` 外，四问的第二问一律是「本次新引入」。

ID 为 `PR112.<N>`。

## 已修（同批次）

| ID | 严重度 | 摘要 | 修复 | 复现测试 |
|---|---|---|---|---|
| PR112.1 | **Major** | `export` 在非结构化 `Task {}` 里跑，`try await exportTask.value` 也不传取消：命令取消后 host 把整个镜像写完。实测 `export Foundation` 取消后仍写满 **1648 个文件**，且 `requestDidFinish` 要等它结束，`host stop` 的排空一起卡住 | 事件循环包进 `withTaskCancellationHandler`，`onCancel` 取消 `exportTask`；取消的失败码从 `exportFailed` 改为 `cancelled` | `cancelledExportStopsWriting`（修前：`.exportFailed` +1648 文件） |
| PR112.2 | **Major** | **审查未报，复核补出**：`connectionDidClose` 不取消该连接的在途请求。Ctrl-C、客户端崩溃、`--timeout` 的 cancel 帧没来得及发出时，host 照样把命令跑完，只在投递结果时才发现没人接 | `requests` 改存 `InFlightRequest`（带 connection 归属），连接关闭即取消属于它的请求 | `closedConnectionCancelsItsRequest`（修前 3 s 超时未取消，修后 0.05 s） |
| PR112.3 | **Major** | `ImageResolver` 用 `fileExists(atPath:)` 兜底，解析的是 **host 的 cwd**——而 host 的 cwd 是当初拉起它的那个客户端的。同一条 `--image mylib.dylib` 在不同目录下读到不同文件，违反指南契约 1 | 客户端把「在本地存在的裸文件名」也绝对化；host 侧删掉字面路径兜底 | `bareFileNameInWorkingDirectoryBecomesAbsolute`、`shortNameStaysAShortName` |
| PR112.4 | Minor（安全） | 比审查说的更严重：不是「不校验 pid > 0」，而是**host 报哪个 pid 客户端就 SIGTERM 哪个**。实测假 host 让客户端杀掉了一个无关的 `sleep` 进程。pid 为 `0` / `-1` 时波及整个进程组 / 该用户全部进程 | 只在 `pid > 0` 且与 host 自己的 `host.json` 记录相符时才发信号，否则记 error 日志 | `outdatedHostCannotSignalAnArbitraryProcess`（修前受害进程真被杀） |
| PR112.5 | Minor | 客户端一个无法解码的帧就退出接收循环、`failEverything`，而服务端同一处是「记日志继续读」。坏帧之后的正常答复整个丢失 | 客户端与服务端对齐：记日志并 `continue` | `undecodableFrameKeepsTheConnection` |
| PR112.6 | Minor | 并发 `connect()` 覆盖 `welcomeContinuation`，前一个调用者永远挂起，还泄漏一个 `SocketConnection` 与接收任务。**复核修正**：审查另称「握手期间断线会挂死」，实测 100 次未命中（`failEverything` 会 resume 该 continuation），窗口存在但概率极低 | `connectTask` 缓存单次尝试，第二个调用者等它 | `concurrentConnectsBothReturn`（修前 5 s 未返回） |
| PR112.7 | Minor | `--timeout` 只包住 `send`，`connect()` 在外面——冷启动的锁等待 15 s + 启动轮询 10 s 全不受约束。`--timeout 1` 实测耗时 10.07 s | `connect()` 移入 `withTimeout` 的闭包 | `timeoutCoversConnecting`（修前 10.07 s，修后 1.01 s） |
| PR112.8 | Minor | `progressPrinter.finish()` 只在成功路径调用，失败时进度行留在终端上，错误信息直接粘在它后面 | 改为 `defer` | `failureClearsTheProgressLine` |
| PR112.9 | Minor | 每个进度帧派发进各自的 `Task {}`，无顺序保证，还可能在 `finish()` 清行之后重绘。**复核修正**：`Task {}` 在 actor 方法内继承隔离，实测 67 次重绘全部单调递增，属理论竞态 | 改为在 actor 上 `await onProgress(progress)` | **无独立复现测试**——复核 100 次未能构造乱序，见下文「无法复现但已修」 |
| PR112.10 | Minor | `TextTable` 用字素数算列宽、用 `padding(toLength:)`（UTF-16）填充。**复核修正：我原判「需 ≥3 个代理对」是错的**——截断条件是 `utf16 − 字素 ≥ 3`，一个 🇺🇸 就够，会切断代理对留下 U+FFFD；excess 2 时两空格分隔符被吃掉，列已不可解析。CJK 只是终端显示错列，不截断 | 手工按同一单位填充 | `wideCharacterCellIsNotTruncated` |
| PR112.11 | Minor | `removeSocketFile()` 无条件 `unlink`，而紧邻的 `removeRecordIfOwned()` 有 pid 守卫并在注释里引用提案 0006。**第四问：同类问题项目修过**——0006（2026-08-09）正是 MCP 端口文件被绑定失败的实例覆盖 | 新增 `hasBoundSocket` 标志（不能复用 `listeningFileDescriptor`，`stopAccepting()` 已把它置 −1）作为守卫 | `unstartedHostLeavesTheSocketAlone`（修前活 host 的 socket 被删） |
| PR112.12 | Minor | `match()` 对未排序数组取 `first(where:)`：`imageList` 是 dyld 顺序、catalog 是树遍历顺序，`--image Kit` 解析到哪个镜像取决于 host 冷热。**第二问例外**：`main` 的 `MCPBridgeServer.resolveImageNameFromImageList` 自 `0ebc99e0`（2026-03-11）起就是同一模式，本 PR 复制了它 | `match()` 内部先排序 | `substringMatchIsOrderIndependent`（修前三种顺序给出 3 个不同结果） |
| PR112.13 | Minor | `--options app` 用 `try?` 读 `settings.json`，把「文件不存在」和「读不出来」压成同一个结果 | 新增 `readSettings() -> SettingsReadOutcome`，`.unreadable` 写进 `host.log` | `undecodableSettingsFileIsReported`。**注意**：见 PR112.18，这条覆盖不了审查真正担心的场景 |
| PR112.14 | Minor | 横向同类：`--argument Param=Type` 的候选选择同样对无序数组取 `first`，而 `Candidate.imagePath` 的存在恰恰说明同名候选是真实情况 | 抽成 `CommandExecutor.candidate(named:among:)`，按 `Candidate` 自己的 `ComparableBuildable` 顺序排序——与 app 侧类型选择器 `candidates.sorted()` 一致，两边挑中同一个 | `candidateSelectionIsOrderIndependent` |
| PR112.15 | Minor | 横向同类：`LocalSourceResolver` 共享的 `connectTask` 也用 `Task.value` 等待，同样不传取消 | 抽出 `awaitCancellably(_:)`，客户端与 resolver 共用 | 无独立测试，与 PR112.7 是同一处理（`timeoutCoversConnecting` 覆盖客户端那半） |

## 无法复现但已修（PR112.9）

进度帧乱序在代码上成立（非结构化 `Task` 之间无顺序保证），但复核在 100 次实验里未能构造出来：
`Task {}` 在 actor 方法体内继承 actor 隔离，实际按入队顺序执行，要乱序需要 executor 的优先级抢占。
按审查规则「构造不出触发场景的要明确标注」——**它不是误报，但也没有能变红的测试**。修复本身
（在 actor 上直接 `await`）比原写法更简单，且顺带消除了「结果到达后仍有帧重绘」的窗口，所以照修，
并把这条限制记在这里，避免下次审查重报或误以为有测试保护。

## 不修（留档，下次不必重走四问）

### PR112.16 — `Package.swift` 里 45 行本地依赖开关是死代码

**报告的说法**：`envEnable` / `usingLocalDependencies` / `package(local:remote:)` 定义了却从未调用，
`USING_LOCAL_DEPENDENCIES=1` 对这个包无效，会误导下一个读者。

**四问**：属实（调用数确实为 0），基线上不存在（新包），值得修但**不在这里修**——复核给出反证：
`RuntimeViewerCore` / `RuntimeViewerPackages` / `RuntimeViewerMCP` 三个既有包在本分支上的调用数
**同样是 0**，这是仓库级模板而非 CLI 独有的疏漏。单独删 CLI 那份会让四个 manifest 不一致，真正
该做的是四份一起清理，属独立 PR。历史上无同类修复记录。

**下次的判据**：若某个包开始真正使用 `package(local:remote:)`，这条即失效，应重新裁决。

### PR112.17 — `ImageResolver` 与 `MCPBridgeServer` 的解析逻辑重复

**报告的说法**：短名解析与类型查找是 `MCPBridgeServer.resolveImagePaths` / `findObject` 的第二份
实现，且已经漂移（CLI 多了大小写不敏感回退与 catalog 阶段，MCP 没有），同一输入两边可能解析到
不同对象。

**四问**：属实且已漂移（复核确认 `MCPBridgeServer.swift:633` 只做精确匹配）。第二问：MCP 那份是
`main` 上的原始出处，不是本 PR 引入。值得修，但正确修法是把解析下沉到 `RuntimeViewerCore` 并同时
改 MCP 包，**动的是本 PR 之外的两个模块的公开面**，应走独立提案。本批只把确定性问题（PR112.12）
在 CLI 侧修掉。

**下次的判据**：下沉提案落地后本条关闭；在那之前两边的行为差异按已知记录处理，不再重复报。

### PR112.18 — `--options app` 读不出 settings 的 schema 漂移（PR112.13 的边界）

**报告的说法**（PR112.13 的后半）：`settings.json` 的 schema 一变，`try?` 就静默回退默认值，用户
看到的接口与 app 不同却没有任何提示。

**裁决：前提不成立，且不可能在这一层修。** 修 PR112.13 时实测发现：
`RuntimeObjectInterface.GenerationOptions` 是 MetaCodable 的 `@Codable`，每个属性都带 `@Default(…)`，
所以**类型不符的键根本不会抛错**——`{"transformer": "一个字符串"}` 解码成功并回退默认值，压根到
不了 `try?`。也就是说：
- 加诊断（PR112.13）只能覆盖「文件不是 JSON」这一种，
- 审查真正担心的「schema 漂移静默回退」发生在 `@Default` 那一层，CLI 这边无法观察，要治得改 Core
  的解码语义或让 reader 逐字段校验存在性——都超出本 PR。

`settingsTypeDriftIsSwallowedBeforeThisModuleSeesIt` 把这个行为锁在测试里，`@Default` 的语义一旦
改变，那条测试会提醒下一个人这条裁决失效。

## 复核推翻的两条断言（记录以免重复调查）

- **「#113 的 app-as-host 会踩到 PR112.11」**：不成立。`CommandLineHostController.claimAndServe()`
  在 `start()` 失败时不把 server 存进 `self.server`，`stop()` 的 `if let server` 因此不触发；它调用的
  `removeArtifactsSynchronously` 本来就带 pid 守卫。PR112.11 在两个分支上都不可达，修的是「靠调用
  约定」变成「靠代码」。
- **「握手期间断线会挂死」**：窗口存在（`send(hello)` 挂起期间接收循环先跑完 `connectionDidEnd`，
  此时 `welcomeContinuation` 还是 nil），但 100 次实验 0 次命中，因为 write 先报 EPIPE。PR112.6 的
  修复顺带收窄了它。

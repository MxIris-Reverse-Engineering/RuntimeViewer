# 越狱 iOS 注入（PR #119）的审查裁决 — 2026-10-06

审查对象：PR #119「Inject into device processes from the jailbroken iOS variant (five proposals)」
的 head `d2feb526`（43 个提交，118 个文件，+12228/-630）。相关提案五份，均在
[`../Evolutions/`](../Evolutions/)：`draft-jailbroken-ios-injection`、
`draft-device-payload-reverse-connection`、`draft-device-process-assertions`、
`draft-device-process-icons`，以及把注入搬出 Core 的那次重构。

`/code-review max` 报了 15 条。每条按四问逐一核复（能否复现 / 与基线比 / 值不值得修 / 以前修过
吗），另把 PR 上 Copilot 四条一直没人处理的评论一并走了同样的流程，并在核复过程中新发现 1 条。

**结论**：12 条属实并修（含新发现的 1 条与 Copilot 的 2 条）、2 条进待办、1 条不修、2 条误报、
Copilot 的 1 条判误报、1 条升级为独立提案。

**第二问的基线**：「这次引入」对照 `origin/next`（`7d599676`，也是本 PR 的 merge-base），「main 上
也有」对照 `origin/main`（`4476ab22`，即已发布的 v3.0.0-beta.6）。

ID 为 `PR119.<N>`，与审查报告的顺序一致；Copilot 的四条为 `PR119.C<N>`；新发现的那条为
`PR119.N1`。

## 已修（同批次）

| ID | 严重度 | 摘要 | 修复 | 复现测试 |
|---|---|---|---|---|
| PR119.1 | **Blocker** | 往已被 RST 的对端 `send` 会触发 `SIGPIPE`，默认动作结束进程 —— 一端是 App，另一端是被注入的目标（可能是 iOS 系统守护进程）。`sendRaw` 以 flags 0 调 `send`，而 fd 从未设 `SO_NOSIGPIPE`，仓库里也没有任何地方忽略这个信号（CLI 只忽略 TERM/INT/HUP）。XNU `sendit` 的判据：`EPIPE` 且既无 `SOF_NOSIGPIPE` 也无 `MSG_NOSIGNAL` 即 `psignal(p, SIGPIPE)`。三条触发路径：加载中途 detach 或退出引来 RST；目标进程被杀；`stop()` 自己的 `shutdown(SHUT_RDWR)` 唤醒阻塞的 `send`。**`next` 与 `main` 都有，已随正式版发出**；本 PR 把这条路径接到跨 Wi-Fi 的真机和 iOS 守护进程里，并新增了会主动断链的 keepalive，所以把触发面放大了 | `configureSocketOptions` 里加 `SO_NOSIGPIPE`，拨出与接入两端都经过它。**另有一个只改这一处的 PR 给 `main`**（分支 `fix/local-socket-sigpipe`，worktree `.worktrees/RuntimeViewer-LocalSocketNoSIGPIPE`，commit `bd8981b5`，尚未推送） | `sendToResetPeerDoesNotRaiseSignal`（修前两端读回 0）。main 那个 PR 的测试更强：装信号观察器，实测修前 `SIGPIPE` 被投递 1 次 |
| PR119.2 | **Major** | 网络断一下，目标就再也接不上。被动断线（`handleStateChange` 收到 `.disconnected`）走 `terminateRuntimeEngine`，对 `.injectedTCP` 既释放保活 assertion 又 `engine.stop()` 关掉监听；而载荷只认 rendezvous 里那一个地址端口、每 500 ms 永远重拨，宿主没有任何重建监听的路径（`reconnectInjectedEngines` 只管 XPC 与 localSocket）。重新注入也救不回来：同一暂存路径 `dlopen` 只拿到已加载的 image、不跑构造器。**与本 PR 自己的设计陈述矛盾** —— `RuntimeDeviceSuspensionController` 的注释写着 assertion「跨任何一次连接存活，只在用户 detach 或目标退出时结束」。触发条件是 keepalive 判死（约 25 秒）或 RST。「断线即拆」是基线既有语义（起源 `a1ad25d9`），在回环上无害；本 PR 新引入的是把它用到会掉线的真实网络上，并把 assertion 挂在它上面 | 拆除加 `TerminationReason`。被动断线且错误是传输类时**完全不拆**：监听保留（socket server 本来就回到 `accept()`）、assertion 保留、引擎留在列表里，载荷重拨上来即恢复。界线用传输已有的区分：socket 错误是链路，`peerClosed` 是进程 —— 被杀的进程由内核关 socket，所以 `kill -9` 也走 `peerClosed`，不需要额外定时器 | `aDroppedLinkDoesNotFinishAnInjectedEngine`（4 例）、`aClosedPeerFinishesAnInjectedEngine` |
| PR119.3 | Major | 载荷走广播而非直拨时，保活 assertion 在 attach 当下就被还掉。`awaitInjectedDeviceEngine` 两处（`:878` 与最终检查 `:898`，review 只点了前者）在广播一方胜出时 `terminateRuntimeEngine(for: listeningSource)`，而那正是刚连上的那个进程的 assertion；胜出的 `.bonjour` 引擎不带记录，之后 detach 也释放不了任何东西。后台 App 目标随即可被挂起。可达性：载荷只在 `stagedBesideImage` 返回 nil 时改走广播 —— 并发注入共用暂存目录的窗口（即 `PR119.C4`）是现实来源之一。**本 PR 新引入** | 新增 `.supersededByAdvertisement` 原因（不释放），并把记录改挂到胜出引擎的 source 上，两处都改 | `theHoldOutlivesABlipButNotTheInjection` |
| PR119.N1 | Major | **核复时新发现**：设备连接重连过一次后，保活 assertion 永远释放不掉。记录用 weak 引用指向「当时那个」`RuntimeEngine` 对象，而设备的 Bonjour 连接每次重连都新建对象（`:418`）、旧对象随即释放 —— 之后 detach 时引用已是 nil，`stopKeepingDeviceTargetAwake` 直接返回，目标在后台一直跑到越狱版自身退出。注释只预料到「用户先 detach 越狱版」这一种 nil。修好 `PR119.2` 后更容易踩到（引擎跨断线存活，期间设备引擎可能已换过对象）。**本 PR 新引入** | 记录改存设备 `hostID`，释放时在 `bonjourRuntimeEngines` 里找当前引擎 | 无单元测试（`bonjourRuntimeEngines` 的写入口 `appendBonjourRuntimeEngine` 是 private）。见下「测试缺口」 |
| PR119.4 | Major | 旧版 Mac 会断开和新版 Mac 的整条镜像连接。注入的设备引擎进 `attachedRuntimeEngines` → `updateProxyServers` 给它开 proxy → `buildEngineDescriptors` 把 `source: .injectedTCP` 发出去。`RuntimeSource` 的 `Codable` 是合成的，`engineList` 又是对**整个数组**一次 `JSONDecoder`，所以旧对端一个元素认不出就整次解码失败；它的心跳把失败当死链，连续 2 次（间隔 30 秒）即 `runtimeEngine.stop()` —— 这台 Mac 镜像过去的**所有**引擎一起消失，直到 Bonjour 重新发现，然后循环。接收端的脆弱（整体解码 + 解码错误当死链）`next` 与 `main` 都有；本 PR 是**镜像上线以来第一次新增 source case**（上次改 case 是 `1a4e99c4`，早于镜像的 `b7bdb7d4`），所以是第一个触发它的改动。旧版已发出，只能在发送端修。Copilot 的 `r4192141644` 也独立报了这一条 | `RuntimeSource.isMirrorableToPeers`：新 case 默认**不**镜像，`buildEngineDescriptors` 按它过滤。镜像注入的设备进程本来也不是验证过的路径 —— 对端经该设备自己的引擎就能看到它 | `mirrorableSourcesStayReadableByOlderPeers`（6 例，修前只有 `.injectedTCP` 那例红）、`oneUnknownCaseFailsTheWholeArray`（characterization：证明一个元素坏掉整个数组失败）。用新写的五 case 冻结解码器，既有的冻结 descriptor 复用当前 `RuntimeSource`，证不了「新增 case」 |
| PR119.6 | Major | 选中模拟器引擎时 Attach 按钮变灰，提示还让用户去装越狱版 —— 而越狱版在模拟器上根本用不了。`injectionTargetsRunOnThisMachine` 对所有 `.bonjour` 返回 false，**而模拟器正是走 `.bonjour`**（模拟器里的载荷和跑在模拟器里的 RuntimeViewer 都用 `advertisingSource()`）；于是去问对端，对端的 `os(iOS)` 分支答 `requiresJailbrokenVariant`。**相对 `next` 是回退**：那里只要 SIP 关着 Attach 就打开本机 picker。也与本 PR 自己的设计表格矛盾（`draft-jailbroken-ios-injection.md:302`、`:329`：这一行应可用且一次 RPC 都不发）。属性与测试里两处「模拟器走 `localSocket`」的注释都写错了 —— 模拟器从基线起就是 `.bonjour` | `.bonjour` 分支读 `hostInfo.metadata.isSimulator`（对端经 TXT 的 `rv-sim` 报告），两处错注释一并改 | `bonjourSimulatorIsThisMachine`（修前红） |
| PR119.C3 | Major | 注入超时的诊断文案声称「目标已确认在运行，所以挂起不是原因」，但注入前的检查只拦 `.suspended`，`.unknown` 直接放行 —— 而缺 `com.apple.runningboard.process-state` 的构建对每个目标都读到 `.unknown`。于是在最常见的「读不到运行状态」情形下，这句话没有依据，把用户赶去查载荷和目标，而原因可能就是挂起。**本 PR 新引入**（`81a874de`，那次改写本身是改进，只是没覆盖 `.unknown`） | 文案改为「持有 assertion 是已做的事；起始时未被报告为挂起，但在读不到运行状态的构建上这是未知而非已排除」，并把「目标可能仍被挂起」列为三种可能之一。`.unknown` 不改为拦下 —— 那会让没有该 entitlement 的构建完全无法注入，而注入本身不需要这个答案 | `timedOutReasonDoesNotOverstateWhatWasChecked`（修前命中「confirmed」与「is not the explanation」） |
| PR119.C4 | Major | 并发注入共用暂存目录会互相破坏。所有注入都暂存到固定的 `/private/var/tmp/RuntimeViewerPayload`，而 `stage` 先删后写 payload、依赖和 rendezvous，一次注入最长等 20 秒裁决。第二次注入落在窗口里就把第一个载荷还没读的 rendezvous 换掉：它于是拨到第二次的端口被当成另一个进程认领，或撞上删与写之间的空档、读不到文件而退回广播（在不能 bind 的目标上等于永不报到，即 `PR119.3` 的触发来源）。单个 picker 用 `isAttaching` 串行化，所以要两个发起方（第二个文档窗口、MCP、CLI）才撞上，而它们互不感知。**本 PR 新引入** | `RuntimePayloadStaging.isolated(forProcessWithIdentifier:)`，按目标 pid 分子目录。按 pid 而非按认领令牌：同一 pid 重注入复用自己的目录，不会每次留一份 | `concurrentInjectionsDoNotShareADirectory`（把 `isolated` 临时改回返回共享目录后实测红：两个 payload URL 相同、第一个的 rendezvous 被覆盖）、`restagingOneTargetReusesItsDirectory` |
| PR119.7 | Minor | 监听建立失败时残留一条保活记录。`launchInjectedDeviceEngine` 在 `connect()` 之前就记账，而调用方 `AttachToProcessViewModel.attachToRemoteProcess` 在 `do/catch` **之外**调它 —— 所以 `connect()` 抛错（咨询端口被抢、接口 IPv4 中途消失、fd 耗尽）时 `terminateInjectedDeviceEngine` 永不执行，记录（key 是一次性 UUID，不会被覆盖）永远回收不掉。注释「每条 attach 失败路径都经过 `terminateRuntimeEngine`」对这一条不成立。影响极小：还没取 assertion，设备侧不受影响 | 记账挪到 `connect()` 成功之后、注入之前；注释一并改准 | 无（记录是 private）。见下「测试缺口」 |
| PR119.10 | Minor | `.app` 本身是符号链接时能绕过图标路径校验。三道校验全是对**字符串**的判断，而内核解析路径时跟随每一个目录分量，所以 `Link.app → 任意目录` 能让 `Data(contentsOf:)` 读到 bundle 之外的 `Info.plist`，再读它声明的 PNG。叶子图标文件那一层防住了（`attributesOfItem` 不跟随链接），`.app` 目录这一层漏了 —— 防护只做了一半。实际危害接近零：链接得事先布在设备上，而同一条无鉴权连接本来就提供任意路径的 `loadImage`（基线既有）。但模块注释自称「confined to application bundles」「not an arbitrary file read primitive」，提案决策日志也写着「拒绝符号链接」，都比实现强。**本 PR 新引入**（`fbb85267`） | 对末段 lstat、要求是 `.typeDirectory`；注释与提案措辞一并改准 | `symbolicLinkApplicationBundleIsRefused`（修前返回了图标） |
| PR119.11 | Minor | `proc_listallpids` 的头文件注释说返回**字节数**，实际返回的是 pid 个数（libproc 自己除过 `sizeof(int)`），与 Swift 调用点的注释直接矛盾。**同一段注释里还有一处 review 没点名的错**：头文件与 `EnumerationError` 都说容器化调用「返回 -1、`errno == EPERM`」，但 `proc_listpids` 在 `__proc_info` 失败时 `return 0`，所以永远不会返回 -1 —— `processListRefused` 按负返回值判定是**不可达**的，权限被拒会被报成 `processListEmpty`（注释写的是「capacity of zero」）。依据：`apple-oss-distributions/xnu` 的 `libsyscall/wrappers/libproc/libproc.c`。运行时无 bug（Swift 侧按个数用，且 `injectionAvailability` 遇任何错误都判 unsupported），但这正是本 PR 自己踩过一次的坑（`eb367746` 修了「再除一次只剩四分之一进程」，只改了 Swift 侧没回头改头文件）。**本 PR 新引入**（`60bb3987`） | 头文件两处说法都改正并注明出处；判定改为调用前清 `errno`、返回 ≤ 0 时按 `errno` 区分拒绝与真空 | 无法在 Mac 上造出 `proc_listallpids` 失败，拒绝那条分支没有测试接缝。成功路径由 `eb367746` 的 launchd 回归测试守住。见下「测试缺口」 |
| PR119.13 | Minor | `reachingThisProcess` 的嵌套 `guard` 里有死代码：`RuntimeLocalAddressReachability` 只有两个 case，内层 `else` 不可达，却带一句永远不会出现的文案「no address was reported」。将来加第三个 case 时编译器不会报错，会静默走到这句编造的理由。**本 PR 新引入**（`4815f1c6`） | 改成穷举 `switch`，新增 case 即编译失败。原注释的动机（「陈述出来而不是用强解包绕过」）用 `switch` 同样满足 | 无需新测试：死分支没有可观察行为，收益是编译期检查；既有 `InjectionCommandWireFormatTests` 的拒绝路径用例继续守住行为 |
| PR119.15 | Minor | 缩写标识符。全 diff 新增行横扫，本 PR 真正新引入的只有两处：`RuntimeDeviceProcessEnumerator.swift:151` 的 `var info = kinfo_proc()`，和 `RuntimeSource.swift:261` 新 case 分支里的 `let id`（照抄同文件基线写法）。同类问题以前修过两次（`8a1a5ae8` 展开局部变量缩写、`bb1b1b08` 全仓展开 `lhs`/`rhs`，对应 `OBJID.11`），这次不是回归而是新代码再犯 —— 仓库没有 lint 拦这条规则 | 改名 `processInformation` / `claimToken` | 无需测试 |

第四问（以前修过吗）：除表中写明来历的几条外，其余均为本次新代码，没有既往修复；`gh pr list` /
`gh issue list` 全文搜索无相关记录。

### 没有横向同类的几条

确认为真后在全仓搜过同一模式，结果：
- `PR119.1`：自己调 `send`/`write` 写 socket 的只有 `sendRaw` 一处。CLI 的 `UnixDomainSocket` 在创建与
  accept 时都已设 `SO_NOSIGPIPE`（注释写明「写入必须以 EPIPE 失败，而不是杀掉进程」—— 作者知道这个
  坑，只是没推广到这条传输）。其余传输走 `NWConnection` / `FileHandle`，不调 `send(2)`。
- `PR119.2`：`terminateRuntimeEngine` 里另有一处同类副作用 —— `.localSocket` 的
  `removeInjectedSocketEndpointRecord` 在被动断线时也会删掉重连所需的记录。基线既有，且回环上断线
  基本等于目标已死，影响低，未改。
- `PR119.13`：全 PR 只有这一处两 case 枚举上的嵌套 `guard`。

## 待办（判定值得记、这批不修）

| ID | 摘要 | 不现在修的理由 |
|---|---|---|
| PR119.8 | 注入的设备引擎在载荷拨入前就上列表并发「已连接」通知，窗口是注入 RPC 加最多 30 秒。选中它不会卡住，而是立刻抛 `notConnected` | 基线同形状：`launchAttachedRuntimeEngine` 也是 `connect()` 后立即 append，且 `ea139588`（2026-07-14）**有意保留**「乐观的 `connect` 语义」（原文 Rejected: change shared connection state semantics）。本 PR 只是把窗口从回环下的 <1 秒拉到约 30 秒。attach sheet 是窗口模态的，要另一个文档窗口 / MCP / CLI 才能在窗口内选中它。修法（manager 内加一张 pending 表、确认后才上列表）不碰连接语义，可与下次改这块时一并做 |
| PR119.12 | `DeviceGlyph` 的亮屏颜色在构建时被冻结（systemCyan / systemBlue 与白色混出固定 RGB），浅/深色切换后仍是旧色，直到引擎列表下次变化才重建 | 纯观感，色差轻微（cyan 混白后红通道差约 50，blue 约 8，图标 20×20），未截图实测。review 另称「每次调用重建是浪费」**不成立**：每次发射只为几行机器各建一张图。修法是两种屏幕色改 `NSColor(name:dynamicProvider:)`、配置改 static。提案正文里「会在外观切换时重新解析颜色」已改准（只有 `labelColor` 如此） |

## 不修

### PR119.14 — `AttachFailure.injectionRefused` 持有包括 `.injected` 在内的整个结果

`errorDescription` 因此有一个不可达的 `.injected` 分支，返回「The injection succeeded.」。属实，但
**有意为之**：注释原文 "Stated rather than force-unwrapped away"，为的是不用强解包。而外层
`switch result` 是穷举的，给结果枚举加新 case 会在这里编译报错，不存在新 case 被静默吞掉的风险；
唯一代价是一句永远不会出现的文案。当初的动机今天仍然成立。真要改就把类型换成
`injectionRefused(reason: String)`，或给结果类型加 `failureDescription` —— 属于形状偏好，不是缺陷。
全仓只有这一处同类写法。

## 误报

### PR119.5 — 「永不放弃」的重连初始化被取消时会提前抛错

机制本身成立：`init(host:port:identifier:firstAttemptWindow:)` 的 `catch` 里是
`try await Task.sleep`，被取消时 `CancellationError` 会逃出 init，违背文档承诺的「不抛错，转后台继续
重试」。但**构造不出取消来源**：生产代码里唯一的调用链是
`RuntimeCommunicator.swift:186` ← `RuntimeEngine.connect()`（直接 await，没有 task group 或超时竞速）
← `RuntimeViewerServer.swift:58` 的 `Task {}` —— 那是在 C constructor 里起的非结构化 Task，句柄被
丢弃，没有父任务，没人能取消它。其余调用只在测试里。

**重开条件**：有调用方把 `engine.connect()` 包进可取消的上下文（task group、超时竞速）时重开。

真要修时注意**不能简单改成 `try?`**：被取消后 `Task.sleep` 会立即返回，循环会在首个窗口内空转吃满
CPU。正确写法是捕获 `CancellationError` 后直接转 `startReconnecting()`（它起的是新的非结构化 Task，
不继承取消状态）。

同类排查：`catch` 里 `try await Task.sleep` 的写法全仓只有两处（`:687` 与 `:766`）；
`reconnectionLoop`（`:888`）是 `catch { return }`，没有这个问题。基线的
`init(identifier:timeout:)` 早有同样写法，但那个 init 本来就允许抛错，被取消时抛出不违背它的约定。

### PR119.9 — `RuntimeInjection.install` 对 `nonisolated(unsafe) static var service` 的无锁写入

`install(service:)` 唯一带非 nil service 的调用点是 iOS `didFinishLaunching` 的第一行
（`AppDelegate.swift:16` → `InjectionServiceRegistrar.swift:36`），在主线程上，且早于
`RuntimeEngine.local` 的创建（晚一个 `dispatch async`）和 Bonjour server 引擎的创建（晚一个
`Task`）—— 两者都与这次写入构成 happens-before。另外 8 个调用点传 nil，不写。测试里
`installWithoutServiceKeepsTheRecordedOne` 会写，但同进程内没有任何测试会派发读它的注入命令。

且**基线早有同形状的写法**：`RuntimeEngine.engineListProvider` / `engineListChangedHandler` 是普通
`static var`，而且是在 `startBonjourServer` / `startBonjourBrowser` **之后**才写的，理论窗口比这条更
宽。本 PR 的提案决策日志明确写了「沿用 `engineListProvider` 那条既有接缝」，理由（机器级属性、入口
处写一次）仍然成立。

数据竞争也造不出能稳定变红的测试，按「修复必带复现测试」这条规则无法成批处理。

**重开条件**：有入口在引擎已连接之后才调 `install(service:)` 时重开。真要加固，`RuntimeInjection`
需要自己的 `NSLock` —— Core 的 `commandExtensionsLock` 是 private，而 Core 的 macOS 10.15 下限排除了
`Mutex`。

同类排查：本 PR 另两个 `nonisolated(unsafe)` 全局（`RuntimeEngineCommandRegistrar.swift:114`/`:116`）
都只在锁内读写，没问题。

### PR119.C1 — 认领令牌从不校验

令牌确实从不在握手里回传或校验（`init(host:port:identifier:)` 的注释明说它「只呈上、不参与计算」）。
但 Copilot 推出的后果——「带错令牌的对端会被当成本次注入的目标」——不成立：真机路径下宿主是**监听
方**，每次注入经 `RuntimeUnusedPort.find()` 要一个独占的新端口并单独开一个 listener，要连进来的对端
必须先知道那个临时端口。令牌按设计只做区分、不做认证，提案与术语表都显式这么写（「特意写明它只做
区分不做认证……和载荷同在世界可读目录，当密钥是会被误读的错」）。

真正该担心的是「谁能连上这个端口」，那是 `PR119.C2` 的鉴权问题，不是令牌问题。给令牌加密码学校验
与「它在世界可读目录、和可被任意加载的载荷并排」这一事实矛盾，买不到任何东西。

## 升级为独立提案

### PR119.C2 — 注入能力经无鉴权的 Bonjour 通道暴露

属实：设备端 Bonjour server 不做 TLS、不做鉴权，谁先连上接受谁（`tls: nil` + `includePeerToPeer`），
而越狱版在启动时装上真实的 `RuntimeDeviceInjectionService`，所以局域网上能连到该设备的对端可以枚举
进程并发起注入，设备上无需任何批准。

**但相对基线的增量有限**：无鉴权的 Bonjour server 和任意路径的 `loadImage` 在 `next` 与 `main` 上都
已存在，而能任意 `loadImage` 的对端本来就已经能在设备进程里跑任意代码 —— 新增的
`injectIntoProcess` 并没有把「只能读」提升成「能执行」，那条线基线上已经越过了。

**不进本批**：给 Bonjour 通道加鉴权或配对是设计级改动，会波及基线既有的整条传输、`loadImage`、模拟
器路径和跨 Mac 镜像，属于需要独立提案权衡的工作，不是一两行能补的。本 PR 的提案讨论过沙盒可达性与
令牌「不做认证」，但**没有**讨论过这个更大的问题。

**现行威胁模型**（登记在此，作为下次审查的对照）：越狱 / 开发者工具，在可信局域网内使用。

**重开条件**：要在非可信网络启用，或要对外发布普通版的设备注入时，必须先有鉴权提案。

## 测试缺口（诚实登记）

以下两处修复没有复现测试，理由逐条写明 —— 不是遗漏，是接缝不存在：

- `PR119.N1`（记录改存 `hostID`）与 `PR119.7`（记账挪到 `connect()` 之后）：
  `awakeTargetsByInjectedSource` 与 `bonjourRuntimeEngines` 的写入口都是 private，断言「记录没有残留」
  或「重连后仍能释放」都需要新开 internal 查询接口。两者都是严格改进（weak 引用在重连后必然为 nil；
  记录晚记只减少泄漏路径），所以没有为此新增接缝。
- `PR119.11` 的 `EPERM` 判定：Mac 上造不出容器化调用，`proc_listallpids` 无法被诱导失败。

`PR119.2` 的端到端那一环**已补上**（`InjectedDeviceEngineReconnectionTests`，用户在收尾时点名要的）：
起一个真监听，用裸 socket 充当载荷拨入，以 `SO_LINGER 0` 关闭制造 RST，再重拨。把 `handleStateChange`
里那个 `if case .injectedTCP` 改成 `if false` 实测变红 —— `errno 61`（`ECONNREFUSED`），监听没活下来；
而配对的「干净关闭要拆掉引擎」那条在同一个被改坏的版本上**仍然通过**，所以这对测试区分得出「修好」
与「干脆不拆」。

过程中测出一件原先不知道的事：**引擎不会停在 `.disconnected`**。socket server 在报告断开的同一轮就
重新 `accept()`，所以紧跟着就是 `.connecting`，中间那个状态按 20 ms 采样根本抓不到（采了 100 次，只
看到 `connected | connecting`）。断言因此落在可观察的结果上 —— 引擎仍在列表里、重拨被接受 —— 而不是
那个瞬时状态。

两个决策谓词是随测试一起新写的，所以**没有先观察到红**（谓词不存在时是编译失败，不是失败的测试）。
`PR119.C4` 则是把 `isolated` 临时改回返回共享目录、实测变红之后才恢复的，那一条的红是真的；
`PR119.1`、`PR119.4`、`PR119.6`、`PR119.10`、`PR119.C3` 的红都是在改实现之前直接跑出来的。

### `PR119.1` 两个分支的合并注意

同一个修复在两处落地，位置不同，因为 `main` 上还没有共享的 `configureSocketOptions`（那是本分支
keepalive 工作引入的）：本分支在该函数里设一次，两端都经过；`main` 的 PR 用一个文件级 helper 在拨出
与 accept 两处分别调用。**`main` 合进 `next` 时这两处会撞上** —— 重复设置本身无害（幂等），但应当
在合并时收敛成本分支的那一处。`main` 那个 PR 的行为测试（装信号观察器、实测修前 `SIGPIPE` 被投递
一次）依赖它那边的 `underlyingConnection` / `socketFD` 可见性改动与两个辅助类型，所以没有往本分支
回种 —— 合并时它会自己过来。

## 范围外（本次未处理）

Copilot 的第四条 `r4192141690` 已作为 `PR119.C3` 修掉；`r4192141572` 判误报（`PR119.C1`）；
`r4192141724` 已修（`PR119.C4`）；`r4192141610` 升级为独立提案（`PR119.C2`）。

`draft-device-process-assertions.md` 原先记录的范围外缺口「App 里没有 Detach 入口」仍然成立，且
`PR119.2` 的修复使它更值得补 —— 保留一个跨断线存活的引擎，意味着用户需要一个主动结束它的入口。

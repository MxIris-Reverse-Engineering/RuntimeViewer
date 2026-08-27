# PR #106 二轮审查裁决 — 2026-08-27

审查对象：PR #106（`feature/inject-ios-simulator-process` → `next`，Evolution 0013 模拟器注入），
head `db75f65f`。

**这是第二轮。** 第一轮的裁决在
[`2026-08-24-pr106-review-findings.md`](2026-08-24-pr106-review-findings.md)（`PR106.<N>`），本轮
开始前已通读，其中已裁决且理由仍成立的条目（`PR106.1` 书签键、`PR106.13` 误报、`PR106.14`
UDID 隐私、`PR106.15` / `PR106.16`）直接跳过，不再重走四问。

产出方式：`/code-review xhigh` 报了 10 条，扣掉一条（注入目标平台探测把「读不出来」当硬拒绝）
由用户当场排除，余下 9 条交给**两个互不知情的会话**分别复核 —— 一个 subagent，一个同项目的
独立会话（`runtimeviewer-05`）。两份复核在「是否成立」上高度一致，在两处定性上分歧，各自还
补出了对方没看到的东西。ID 为 `PR106X.<N>`。

**基线是 `next`（merge-base `429476a0`），不是 `main`。** 第一轮已经踩过这个坑，本轮两份复核都
独立确认了一次。

## 本轮的方法学结论（值得单独记一笔）

**两个独立复核的价值不在于「互相背书」，而在于互相证伪。** 本轮实际发生的：

- 一份复核给出的 `PR106X.1` 修法（改用 `source.identifier`）被另一份**当场推翻** —— 该
  identifier 对 Bonjour client 是 `{deviceID}-{pid}`，pid 每次启动都变，照此修等于把
  `PR106.10` 刚修掉的「每次启动换一套 autosave key」原样搬到另一处。**这个错误的修法一度已经
  转达给用户**，是被第二份复核拦下的。
- `PR106X.4` 的后果链被**实测证伪**，两份复核各自独立跑了实验，其中一份还写了 `NWListener`
  探针（即代码真正使用的那一层 API），而不是只跑 `dns-sd`。
- `PR106X.2` 与 `PR106X.5` 的严重度两份给了不同答案，分歧点写在各自条目里。

结论：对**修法**的复核和对**发现**的复核同等重要。一条发现成立，不代表随之给出的修法成立。

## 已修（同批次）

| ID | 严重度 | 摘要 | 修复 | 复现测试 |
|---|---|---|---|---|
| PR106X.3 | Minor | `localServiceName` 用 `localHostName` 组合广播名，而该属性自己的文档就写着「对外可见的服务名请用 `resolvedHostName()`」。iOS 真机上 `gethostname` 为空/`localhost` 时回退到 `UIDevice.current.name`，无 `user-assigned-device-name` entitlement 即机型名 —— 旧宿主把它同时用作窗口标题**和** sidebar autosave 键 | 新增 `resolvedServiceName()`，把会退化的两个调用点（iOS app 自身广播、注入 payload 的 Bonjour 分支）切过去；`localServiceName` 保留给 macOS 宿主（`SCDynamicStoreCopyComputerName` 不退化）与测试 | `resolvedServiceNameUsesResolvedHostName` |
| PR106X.5 | Minor | 模拟器 payload 编译失败时脚本只打 `warning:`，`SIMULATOR_PAYLOAD_PATH` 仍无条件传给主 app 构建。DerivedData 路径固定复用、编译失败不清旧产物，于是嵌入阶段 `-d` 判真、`ditto` 陈旧 framework 进包并打印「Embedded iOS Simulator payload」，与两行前的 warning 直接矛盾 | 失败分支 `rm -rf "$SIMULATOR_PAYLOAD_PATH"`（`RunScript.sh` 需先把赋值上提到 `if` 之前）。**光把变量置空不够** —— 嵌入阶段在变量为空时会回退到 `BUILD_DIR` 下的同一路径，必须真的删掉目录 | — （脚本层，无单测接缝） |
| PR106X.7 | Trivial | `Documentations/TaskReports/` 未登记进文档索引，而索引第 3 行自己写着「新增或重命名任何文档都必须同步更新这份索引」 | 索引补目录行 + 三份文件逐条登记。顺带修正同文件里「四份审查发现记录」的陈旧计数（实为 12 份），改为不含计数的描述 | — |
| PR106X.8 | Trivial | `clearAllForDisconnectedPeer`（`PR106.7` 的修复）插在 `clearAllWithHostID` 的文档块与函数体之间且无空行，两段 `///` 在词法上合并、全部挂到新函数；`clearAllWithHostID` 文档归零，而它仍是 `public` 且被新函数直接调用两次 | 把原文档块搬回 `clearAllWithHostID` 上方 | — |
| PR106X.9 | Trivial | ``awaitInjectedBonjourEngine(name:processIdentifier:timeout:)`` 引用悬空 —— 同 PR 内 `610e9d9c`（`PR106.3` 的修复）加了 `deviceID:` 却没同步这处 | 补上 `deviceID:` 标签 | — |

**`PR106X.3` 的两处收窄**（避免下次被当成更严重的问题重报）：

- **模拟器上完全不适用。** `resolvedHostName()` 的非 macOS 分支带 `!targetEnvironment(simulator)`
  守卫，模拟器直接 `return localHostName` —— 两者字面等价。而模拟器注入正是本 PR 的动机，
  所以这条对 PR 自身功能零影响，只影响 iOS 真机对端。
- **新宿主看不见退化值。** 引擎标题走 TXT 的 `rv-proc-name`，section 标题走 `rv-host-name`
  （`makeService` 里已经 `await resolvedHostName()` 写入）。退化只出现在 mDNS instance name，
  以及**早于 TXT 键的旧宿主**的标题与 autosave 键里。

**`PR106X.3` 是一次回归，不是新缺陷。** `db8388dc`（2026-04-26，PR #45）的 commit message 原文：
*"The previous fix avoided the watchdog by falling back to `gethostname(2)`, but lost the
user-friendly name in the process."* —— 那次改动做的**正是**把 iOS AppDelegate 的 `localHostName`
换成 `await resolvedHostName()`。当初的动机（避免 `0x8BADF00D` 看门狗崩溃）今天仍然成立，但已由
`resolvedHostName()` 自身的 detached task 解决，所以这次回退换不到任何东西。代码里那句
「resolving it here as well would just repeat the lookup」与 `resolvedHostName()` 自己的文档
（"the second call is essentially free"）直接矛盾，已一并改掉。

**`PR106X.3` 测试的诚实边界**：新测试跑在 macOS 上，而 macOS 的两个主机名来源都是
`SCDynamicStoreCopyComputerName`，运行时分辨不出。它锁住的是**组合方式**：函数体若漂回
`localHostName`，在 macOS 上仍会通过，但这套测试一旦在真机上跑就会失败。测试注释里写明了这一点，
不要把它当成完整防线。

## 误报（留档，下次不必重走四问）

### PR106X.4 — Bonjour 服务名可能超 DNS-SD 63 字节上限

**报告的说法**：`serviceName(hostName:processName:)` 无任何长度裁剪，RFC 6763 §7.2 限 63 字节，
超限后 mDNSResponder 拒绝或篡改注册、`NWListener` 从不广播，最终误报成
`bonjourEngineNeverAdvertised`（「payload 没启动完」），把排查引向错误方向。

**四问**：

1. **能复现吗** —— **前提为真，后果为假。** 「无裁剪」属实，且触发门槛比报告说的更低：报告按
   ASCII 算（63 字符电脑名 + 16 字节后缀），按**字节**算则中文电脑名每字 3 字节，约 15 个汉字即
   到顶。但后果链两份复核各自实测证伪：

   | 实验 | 输入 | 结果 |
   |---|---|---|
   | `dns-sd -R` | 63B / 64B / 70B / 80B ASCII | **全部注册成功**，超限者静默截断到 ≤63 字节 |
   | `dns-sd -R` | 66 字符中文（166 字节） | **注册成功**，截到 21 个完整汉字（63 字节），**在 UTF-8 字符边界上干净截断** |
   | `NWListener` 探针（代码真正使用的 API 层） | 裸名 / 9B / 63B / 64B / 80B 五组对照 | **全部 `state = ready`**，超限者截断后经 `serviceRegistrationUpdateHandler` 回报 |

   mDNSResponder 静默截断并正常注册，服务照常广播。原文「拒绝」半句为假，「篡改（截断）」半句为真。
   更关键的是 **TXT record 不受名字截断影响**，所以新宿主的 `uniqueKey` 匹配与
   `awaitInjectedBonjourEngine` 完全不受影响 —— 声称的 `bonjourEngineNeverAdvertised` 误诊不会发生。

   *实验污点披露*：其中一份复核用未签名解释器复跑时出现整轮 `failed(EINVAL)`（连 ASCII 短名与裸
   listener 对照组也失败），判定为本机 Local Network 授权/环境漂移而非名字问题；采信的是同进程五组
   对照完整成立的那一轮，并有系统签名的 `dns-sd` 独立佐证。
2. **`next` 上是否也有** —— 组合函数是本 PR 新增，但溢出风险不是新的：基线 iOS 广播用户设备名、
   macOS 广播 `SCDynamicStoreCopyComputerName`，同样无裁剪、同样可超 63 字节。截断现象基线就存在。
3. **值不值得修** —— **不值。** 系统层已经做了正确的事（UTF-8 边界截断），残余影响仅限旧宿主看到
   一个被截短的显示名。加裁剪代码不会比 mDNSResponder 做得更好，只会多一处要维护、且更容易在多字节
   边界上写错的逻辑。
4. **以前修过吗** —— 无前史，全仓库无相关 Issue / PR，基线上也从未做过长度处理。

**已落地的动作**：在 `serviceName` 的文档里写明「deliberately unclamped」以及截断行为，免得下一轮
审查把同一件事再报一遍。**横向排查**：`NWListener.Service(name:)` 全仓库只有 `makeService` 一个
构造点，无同类实例。

## 不修（留档）

### PR106X.2 — 端点键含 pid，对端进程重启后走不到 `pendingReconnectEndpoints`

**报告的说法**：`endpointKey` 从设备服务名改成 `{deviceID}-{pid}` 之后，对端进程重启即产生全新键，
`connectToBonjourEndpoint` 立刻连接，而旧引擎（`NWConnection` 尚未失败，正是 `bonjourHeartbeatTasks`
针对的 AWDL 场景）仍留在 `bonjourRuntimeEngines` 里，用户看到一台设备两行、其中一行指向死进程。

**四问**：

1. **能复现吗** —— **机制为真，定性为假。** 键的变化、立即连接、旧引擎残留都核实无误。时序两份复核
   都重算为 **~90 秒**（30s 心跳 + 15s 超时，`maxConsecutiveFailures = 2`），原文的 75s 少算了一次
   超时。但「破坏重连」这个定性不成立：
   - `pendingReconnectEndpoints` 自述的目标场景是**后台挂起后重新广播**（`32c6e336` 的原始动机），
     那是**同 pid、同键**，这条路径在 head 上依然工作，并未被破坏；
   - 基线在 kill-restart 下的行为是**用户必须等旧引擎心跳死亡（同样 ~90s）才能重连**；head 是
     立即连上可用的新进程 + 旧行残留 ~90s。**可用性反而更好**；
   - 不会发误导性的「已断开」通知 —— `observeRuntimeEngineState` 里 `stillReachable` 按 hostID
     守卫，新引擎同 hostID 在场即不发。

   净代价只是 UI 里多显示一行死引擎，最多 ~90 秒。
2. **`next` 上是否也有** —— 行为变化由 `abc1a96c` 引入，是本 PR 的新行为。
3. **值不值得修** —— **不修。** 决定性理由是**修法本身有害**：若在连接新 `{deviceID}-{pid'}` 时主动
   踢掉同 `deviceID` 的旧引擎，会误杀「同一设备上多个注入进程各自广播」这一 Evolution 0013 的**核心
   合法场景**。要精确区分「同设备的另一个进程」与「同一进程重启后的新化身」，复杂度远超 90 秒死行的
   代价。
4. **以前修过吗** —— `pendingReconnectEndpoints` 由 `32c6e336` 引入、`b350f8c1` 扩展，针对 listener
   flap 与挂起恢复；那个场景仍被覆盖，没有既往修复被本 PR 撤销。

**两份复核的分歧**：一份最初建议修（Minor→Major），另一份判不修。分歧在前者没有考虑「修法会误杀
0013 核心场景」这一点。采信不修。

**衍生出的独立发现见 `PR106X.10`** —— 那一条与本条是否修无关，应当单独处理。

## 部分成立 / 待验证

### PR106X.6 — 两个 payload bundle 共用同一个 `CFBundleIdentifier`

**报告的说法**：`RuntimeViewerServer` 与 `RuntimeViewerMobileServer` 都设成
`$(RUNTIME_VIEWER_SERVER_BUNDLE_IDENTIFIER)`，新的嵌入阶段把 iOS 构建以
`RuntimeViewerServer-iphonesimulator.framework` 放在 macOS 版旁边，一个签名 App 内出现两个同
identifier 的嵌套 bundle，属**已知的公证/校验驳回类别**，且 `Bundle(identifier:)` 查找有歧义。

**四问**：

1. **能复现吗** —— **事实成立，两处论据不成立。**
   - identifier 相同：证实。两个 target 的**全部** build configuration 都指向同一个 xcconfig 变量
     （`CodeSigning.xcconfig:25` = `com.MxIris.RuntimeViewerServer`，无 `[sdk=...]` 条件分支）；
     一份复核还读了本机已构建产物的 `Info.plist` 核对。
   - **「已知的公证驳回类别」是推测。** 重复 `CFBundleIdentifier` 的硬性驳回规则属于 **App Store
     Connect validation**（ITMS-90685 / 90806 一类）。本项目走 `notarytool` + Sparkle + GitHub
     Release，**不经过 App Store**；Developer ID 公证检查的是签名、hardened runtime、时间戳与恶意
     内容，两份复核都**没能找到**它检查嵌套 bundle identifier 重复的依据，也都没有条件实测。
   - **`Bundle(identifier:)` 在本仓库出现 0 次**（两份复核各自 grep 确认）。实际查找走
     `Bundle.main.url(forResource:withExtension:)`（按文件名）与 `Bundle(url:)`（按 URL），
     都不经过 identifier 注册表。歧义论点在本项目**不可触发**。
   - **行号引用有误导**：报告引的 `RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj:557` 是嵌入
     阶段的定义行，identifier 相同的证据在**另一个**工程文件（`RuntimeViewerServer.xcodeproj`）里。
2. **`next` 上是否也有** —— **需要拆开看**：identifier 相同**基线已有**（`RuntimeViewerServer.xcodeproj`
   根本没被本 PR 修改，`RuntimeViewerMobileServer` 自 `4fd6db7b` 起就共用同一变量）；**本 PR 新引入的
   是「把两者装进同一个签名 App」这件事**。也就是说，它把一个一直无害的配置放到了会产生后果的位置上。
   报告把两者混为一谈了。
3. **值不值得修** —— **卫生修可做，但不以「会被驳回」为理由**。给模拟器 target 一个带后缀的
   identifier（或给现有变量加 `[sdk=iphonesimulator*]` 分支）是一行 xcconfig 改动，没有任何下游
   代码依赖当前值。理由是「两个不同平台的产物共用一个身份本来就是错的，且修它几乎不要钱」。
   **本轮未修** —— 它改的是另一个工程文件，与本批次其余改动不同域，留给发布前的验收批次。
4. **以前修过吗** —— `1d402ceb` 把 identifier 收进 xcconfig 变量，但从未涉及这两个 server target 的
   拆分。当前写法是「只有一个 target 时正确、加第二个时没人重新审视」的产物，不是有意为之。

**真正的验收动作（必须做，且只能实测）**：跑一次完整的 `ArchiveScript.sh` 公证流程，确认带模拟器
payload 的包能过。**从仓库里看不出这条路径有没有被走通过。** 同一次验收顺带核查另一件事：

> 模拟器 payload 是被 `ditto` 进来的，保留 iOS Simulator 构建时的签名，而该 target 的 Distribution
> 配置是 `CODE_SIGN_IDENTITY = ""`（ad-hoc）。一个 Developer ID 签名的 App 的 `Contents/Resources`
> 下放一个 ad-hoc 签名的 Mach-O bundle，**可能比重复 identifier 更容易在公证或 Gatekeeper 卡住**。
> 同样是推测，同样只能靠那一次公证定性。

（这一条只有一份复核提出，另一份没查到；未经证实，按推测记录。）

### PR106X.1 — Bonjour 客户端引擎名撞 sidebar 的持久化键（**推迟到独立提案**）

**成立**。`RuntimeEngineManager` 把 client 引擎命名为 `endpoint.processName ?? endpoint.name`，
`RuntimeSource.description` 原样返回它，而 `SidebarRootViewController` 与
`SidebarRuntimeObjectViewController` 把这个字符串直接拼进 `outlineView.identifier` /
`expansionAutosaveName` / `autosaveName`。两台设备注入同名进程（两台模拟器各注入一个
SpringBoard —— 正是 0013 的核心场景）即写同一个键，展开状态与列宽互串。

**PR 自己知道 name 不能当键**：`RuntimeSource.identifier` 的注释写着 *"Keyed by the identifier,
never the name: a Bonjour client's name is the peer's *process* display name, which two processes on
one device can share"*，`localServiceName` 的文档也把 autosave 键称作 *"the part that does lasting
damage"*。防护落在了对外广播名（`PR106.10`）上，宿主侧这三处 `description`-as-key 没被排查。

**两处表述要修正**（避免按夸大的版本去设计修复）：

- 「升级前的 iOS 对端保存的状态**永久丢失**」不准确。旧键在 `UserDefaults` 里原封不动，只是再也不会
  被读到 —— 是**一次性失联 + 垃圾累积**，且累积量有上界（历史上见过的名字数量），不像 `PR106.10`
  修掉的 pid 方案那样每次启动涨一条。丢失发生在**对端升级之后**（升级后才开始广播 `rv-proc-name`），
  尚未升级的旧对端 fallback 到 `endpoint.name`，键不变、不丢。
- 后果是两台设备**共享 sidebar 展开状态与列宽**。烦人，但不丢数据。

**为什么不在本批次修 —— 这是本轮最重要的一条**：

> 看似显然的修法（把四处 autosave 键从 `source.description` 换成 `source.identifier`）**是错的**。
> Bonjour client 的 `identifier` 是 `bonjour.{deviceID}-{pid}`，**pid 每次启动都变**。照此修等于把
> `PR106.10` 刚刚修掉的「对端每次启动换一套 autosave 键、在 `UserDefaults` 里永久累积」原样搬到
> sidebar 上 —— 比现在的撞键更糟。

正确的键需要「设备 + **稳定**进程身份」，而这正是 `PR106.1`（Bonjour 书签被 pid-bearing identifier
做键，反转了 `917002cc` 刻意建立的稳定身份）裁决要引入 `RuntimeBookmarkScope` 去解决的同一个问题。
两者必须**同批设计**，因此本条随 `PR106.1` 一起推迟到该提案，不在本 PR 打补丁。

**提案已起草**：[`Evolutions/draft-runtime-bookmark-scope.md`](../Evolutions/draft-runtime-bookmark-scope.md)。
它把上面那个错误修法记进了「替代方案考量」，并明确等 PR #106 合入 `next` 后才开工。

**横向同类实例（确认为真，一并归入该提案的范围）**：

- `RuntimeEngineManager.deduplicateForwardedMirrors` 用 `source.description` 在同一 host section 内
  匹配「本地路由 vs 转发镜像」做去重 —— 同为 display-name-as-identity。远端一个被注入的 `Safari`
  与本机注入的 `Safari` 会互相误去重。**这条在 `main` 上就能复现**，不是本 PR 引入的。
- 纯显示用途（`MainWindowController` 标题、`MainViewModel` 的菜单项标题等）不算，无需改。

**前史存在，且方向相反**：`917002cc`（2026-03-04）新增 `DeviceIdentifier` 并给 `RuntimeSource` 写了
忽略 `name` 的自定义 `Equatable` / `Hashable`，目的正是让持久化身份**与显示名解耦**。本 PR 把显示名
重新绑回持久化键（虽然是另一处键），与那次决策的意图相悖。

> **待核实的引文**：两份复核对 `917002cc` 的 commit message 说法冲突 —— 一份称
> `2026-08-24` 那份裁决文件里引的句子不是原文，另一份把它当原文引用。两边对该 commit 的**内容
> 判断一致**（刻意让身份与名字解耦），仅引文出处存疑。写进提案前需 `git show 917002cc` 核对一次。

## 未验证（本轮新发现，非原始 10 条之一）

### PR106X.10 — `NWBrowser` 的 `.changed` 事件被整个丢弃

**发现经过**：复核 `PR106X.2` 时顺带查出的，不在原始报告里。

`RuntimeNetworkBrowser.start` 的 `browseResultsChangedHandler` 只处理 `.added` 与 `.removed`，
其余走 `default: break`。而 `1df0c1c3` 把服务名改成 launch-stable 的「设备名 (进程名)」之后，
对端进程重启时 **mDNS instance name 不变、只有 TXT 变**，`NWBrowser` 对这种情况报的是
`.changed(old:new:flags:)`（`flags` 含 `.metadataChanged`）。

**如果 mDNSResponder 把「goodbye + 重新注册」合并成一次 TXT 更新，宿主将完全看不到新 pid，
永远不会重连。**

**状态：机制可信，行为未实测。** 静态判不出走哪条路 —— 取决于 goodbye 包与新注册的到达顺序。

**下一步**：真机/模拟器上杀掉对端 app 再启动，观察 `browseResultsChangedHandler` 收到的是
`.removed` + `.added` 还是 `.changed`。无论 `PR106X.2` 修不修，**补上 `.changed` 分支
（`flags` 含 `.metadataChanged` 且 `uniqueKey` 变了时等价于 removed + added）都是该做的**。

**横向排查**：`NWBrowser` 全仓库只有这一个消费点，无同类实例。

## 未纳入本轮

`/code-review` 原始 10 条中的一条 —— `payloadPlatform(forTargetProcess:)` 把「读不出目标 Mach-O」
当成硬拒绝，使得改动前能注入的 macOS 目标现在被拒 —— 由用户在分派复核前排除，本轮两份复核均未查证。
若要重开，走新的 ID。

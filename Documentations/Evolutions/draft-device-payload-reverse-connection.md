# Draft - 真机注入载荷改为反向连接

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-10-02
- **最后更新**: 2026-10-02
- **所属愿景**: 无
- **关联提案**: [draft-jailbroken-ios-injection.md](draft-jailbroken-ios-injection.md)（本提案修正它对传输层的假设）
- **实现分支 / PR**: 待定
- **配套文档**: 待定 —— 落地时登记实现说明的链接

## 摘要

真机上注入的载荷（payload）目前自己开监听、自己发 Bonjour 广播，等宿主连进来。**这个前提在真机上对多数目标不成立**：载荷跑在目标进程的沙盒里，而内核拒绝多数 iOS daemon 的 `network-bind`（实测 7 个目标里 4 个被拒）。

本提案把真机上的连接方向反过来：**载荷不再监听，改为向外连接宿主**，地址与身份都由注入方在注入请求里交给它。模拟器保持现状不动。

顺带解决两个已确认的缺陷：载荷在别人进程里推导出的设备标识逐目标而异（导致认领失败），以及设备上的 App 一旦被系统回收就会带走所有注入连接。

## 动机

[draft-jailbroken-ios-injection.md](draft-jailbroken-ios-injection.md) 落地后在 vphone guest（iOS 26.6.2）上做端到端验证，**对允许绑定的目标整条链路是通的** —— 注入 `chronod`、`sharingd`、`identityservices` 都成功，能从设备的 dyld shared cache 读出完整的 Objective-C 与 Swift 类型树。

但对另一类目标，注入后什么都没有发生。原因在内核日志里：

```
Sandbox: searchpartyd(159) deny(1) network-bind local:*:55330
Sandbox: mediaplaybackd(346) deny(1) network-bind local:*:55331
Sandbox: dasd(83)          deny(1) network-bind local:*:59999
```

载荷用 `dlopen` 进入目标进程后，**继承的是目标的沙盒 profile，不是注入方的**。`network-bind` 恰是 iOS daemon 最常被禁的一项。失败链条完整可见：

```
nw_listener_socket_inbox_create_socket bind(15, …) failed [1: Operation not permitted]
  → Bonjour listener failed: POSIXErrorCode(1)
    → RuntimeViewerServer failed to create runtime engine
```

**这不是少数情况。** 逐个实测的 7 个目标：

| 允许 `bind` | 拒绝 `bind` |
|---|---|
| `chronod`、`sharingd`、`identityservices` | `searchpartyd`、`mediaplaybackd`、`backboardd`、`dasd` |

调用方无法预先知道一个目标属于哪一类 —— 它取决于那个 daemon 的 sandbox profile，而进程列表里看不出来。所以当前实现的表现是「挑一个目标，有一半多的概率什么都不发生」。

**模拟器验不出这个问题**：模拟器 guest 的沙盒宽松得多，`bind` 不被拒。

### 第二个动机：身份

即使目标允许绑定，认领仍可能失败。实测 `chronod` 注入后引擎确实连上并可用，但 attach 面板报超时，而引擎选择器里出现了**两个都叫 `iphone` 的分组** —— `chronod` 独占一组，`sharingd` 与 App 同在另一组。

分组键是 `rv-device-id`。也就是说载荷在 `chronod` 里算出的设备标识与 App 的不同，于是认领用的 `{deviceID}-{pid}` 永远匹配不上。

`RuntimeNetworkBonjour+LocalIdentity.swift:30-37` 的注释预言过这条路，并称它「目前不可达而非被防住，靠两道独立的闸」：模拟器上 `localDeviceID` 先返回 `SIMULATOR_UDID`，以及 MobileGestalt 会先答。**真机上第一道闸根本不存在**，只剩 MobileGestalt，而它按**目标进程的** entitlement 作答：`sharingd` 本职处理设备身份，答得上来；`chronod` 答不上来，于是退到按进程解析的 keychain UUID。

根子是同一个：**载荷在别人的进程里推导自己的身份**。

### 第三个动机：App 的生命周期

把设备上的 App 放进数据通路的方案（见「替代方案考量」A）另有一个硬伤：它是普通 iOS App，会被系统挂起甚至回收 —— 而且恰恰在用户盯着 Mac、它在后台的时候。那样所有注入的引擎会跟着它一起断。

## 前期调研

每条都已查证，推测显式标注。

### 现状代码怎么走的

- 载荷入口 `RuntimeViewerServer/RuntimeViewerServer/RuntimeViewerServer.swift`：macOS 分支先探测沙盒，被阻断时回退到本地 socket；**非 macOS 分支只有一条路** —— 建 `.bonjour(role: .server)` 并 `connect()`。
- `RuntimeNetworkConnection.swift:390-425`：bonjour 服务端的 `connect()` 走 `startListeningWithRetry` → `waitForConnection`，**只有连接建立才返回**。
- `RuntimeNetworkConnection.swift:505-518`：接受一个连接后 `listener.cancel()`，广播随之注销。这解释了观察到的「广播出现一秒就消失」，是设计行为而非故障。
- 宿主认领 `RuntimeEngineManager.swift:794`（`awaitInjectedBonjourEngine`，默认超时 30 秒）→ `:855-862` 要求引擎标识符**逐字等于** `{deviceID}-{pid}`；标识符来自 `RuntimeNetworkEndpoint.swift:31-34` 的 `uniqueKey`，而那是从载荷广播的 TXT 记录里读出来的。
- 引擎要在 `connect()` 完整握手之后才进入 `bonjourRuntimeEngines`（`RuntimeEngineManager.swift:416-426`），也就是才可能被认领。

### 实测结论

**向外连接在 `bind` 被禁的进程里仍然放行。** 为此写了一次性探针（`SandboxReachabilityProbe`，不进功能分支），故意打一个没人监听的端口，让失败方式本身成为答案：`ECONNREFUSED` 表示沙盒放行、对端拒绝，`EPERM` 表示沙盒拦下。在 `dasd` 里（同一次运行中 `raw-bind` 报 `DENIED`，对照组成立）：

```
PROBE raw-bind:             DENIED, errno 1  (Operation not permitted)
PROBE raw-connect loopback: ALLOWED(refused), errno 61 (Connection refused)
PROBE raw-connect host:     ALLOWED(refused), errno 61 (Connection refused)
```

Network.framework 同样放行 —— 日志里 `[C1 … lo0]` 与 `[C2 … en0]` 两条流都走到 `flow:failed_connect, error Connection refused`。（探针本身漏了一个状态：`NWConnection` 把「被拒」报成 `.waiting` 而非 `.failed`，所以这两行没打出来。**是测量的缺陷，不是平台的**。）

**现成的传输层已经实现了需要的角色反转。** `RuntimeLocalSocketConnection.swift` 的文档原文：

> 沙盒应用对 `bind()` 有限制，而 `connect()` 一般是允许的。注入的代码跑在被沙盒限制的目标进程里，所以它建不了 socket 服务端。因此把角色反过来：主 App 是业务上的客户端但**网络上的服务端**，注入的代码是业务上的服务端但**网络上的客户端**。

它是**裸 BSD socket**（`:134`、`:976` 的 `socket(AF_INET, SOCK_STREAM, 0)`），不走 Network.framework，因此完全绕开 NECP —— 而日志里所有 `NECP … Operation not permitted` 全部出在监听那条路上。

**但它把地址写死成回环**（`:142`、`:987` 的 `inet_addr("127.0.0.1")`），所以不能直接用来连宿主。

**`.directTCP` 的角色没有反转。** `RuntimeSource.swift:114` 的 `case directTCP(name:host:port:role:)` 注释写明「host 为 nil 表示服务端」，`RuntimeDirectTCPConnection.swift:503-506` 里 server 角色建 `NWListener`。业务服务端在它这里就是网络服务端，仍然要 `bind`。

### 被证伪的假设

- **「`chronod` 的连接被设备上的 App 抢走了」** —— 不成立。`RuntimeEngineManager` 整个文件是 `#if os(macOS)`，iOS 侧**没有引擎管理器，也不浏览 peer**，不存在第二个竞争者。
- **「Bonjour 广播传不到 Mac」** —— 不成立。连接确实建立了，载荷打出了 `Did Launch`，而那行只有在对端连上后才会执行。
- **「tunnel 网络模式下 Mac 看不到设备的广播」** —— 不成立，那是我用 `timeout` 杀掉 `dns-sd` 导致输出未刷新造成的假象。tunnel 真正挡住的是**反向的 TCP 连接**（vphone 文档：「Outbound only. Nothing on the Mac or the LAN can connect to a port in the guest through this network.」）。

## 提议方案

真机上，载荷不再监听，改为**向注入请求里带来的宿主地址发起连接**；身份同样由注入请求给定，载荷不再自行推导。

1. **注入请求携带一份 rendezvous**：宿主的可达地址与端口、设备标识、以及这次注入的认领令牌。
2. **注入方把它随载荷一起落到暂存目录**，载荷启动时读取。暂存目录本来就存在且可读（当前实现已经把 77 MB 的载荷与它的 `Frameworks/` 放在那里）。
3. **载荷用反转角色的裸 socket 连向该地址**，业务上仍是服务端。
4. **宿主按自己发出的令牌认领**，不再依赖载荷广播的 TXT，也不再依赖载荷推导的设备标识。
5. **连接断开后载荷退避重连同一地址**，所以 Mac 上的 RV 退出重开后连接会自己回来，不需要重新注入。

### 非目标

- **不动模拟器。** 模拟器的 Bonjour 路径现在可用且已验证：guest 沙盒宽松、`bind` 不被禁，身份有 `SIMULATOR_UDID` 打底，两个问题都不存在。改它等于动一条好路，换不来任何已知收益。
- **不动 macOS 与 Mac Catalyst。** 它们已有自己的探测与回退。
- **不解决「挂起的 App 注不进去」。** 那卡在 MachInjector 等远程线程的 210 毫秒预算上（`MIMachInjector.m:515-546`），与连接方向无关。本提案只把它的错误文案改成能看懂的。
- **不把 `RuntimeEngineManager` 移植到 iOS。** 本方案不需要设备侧有引擎管理器。
- **不改宿主侧的 attach 界面。** 用户看到的流程不变。

## 详细设计

### 一、rendezvous 的类型

```swift
/// 注入方交给载荷的一切 —— 它去哪儿报到，以及它该报什么身份。
///
/// 存在的理由是消除「载荷在别人的进程里推导自己是谁」这一整类问题：
/// 设备标识在目标进程里取决于那个进程的 entitlement，实测逐目标而异。
public struct RuntimePayloadRendezvous: Codable, Sendable, Hashable {
    /// 宿主的可达地址，由宿主在发起注入时填入。
    public let hostAddress: String

    /// 宿主为这次注入临时监听的端口。
    public let hostPort: UInt16

    /// 认领令牌。宿主只认自己发出去的这一个值，
    /// 所以载荷既不需要知道设备标识，宿主也不需要重新推导它。
    public let claimToken: String

    public init(hostAddress: String, hostPort: UInt16, claimToken: String)
}
```

### 二、注入请求

```swift
public struct InjectIntoProcessRequest: RuntimeEngineRequest {
    public let processIdentifier: pid_t

    /// 为 nil 时保持原有行为（载荷自行广播），这是模拟器走的路，
    /// 也是与尚未升级的对端之间的兼容点。
    public let rendezvous: RuntimePayloadRendezvous?
}

extension RuntimeEngine {
    public func inject(
        intoProcessWithIdentifier processIdentifier: pid_t,
        rendezvous: RuntimePayloadRendezvous?,
    ) async throws -> RuntimeProcessInjectionResult
}
```

### 三、设备侧：把 rendezvous 落到暂存目录

```swift
extension RuntimePayloadStaging {
    public static let rendezvousFileName = "rendezvous.json"

    /// 写在载荷旁边，权限与载荷一致。
    /// 每次注入覆盖：它描述的是这一次注入，不是这台设备。
    public func stage(rendezvous: RuntimePayloadRendezvous?) throws -> URL
}
```

### 四、载荷侧：读它，然后向外连

```swift
extension RuntimePayloadRendezvous {
    /// 从载荷自身所在目录读取。读不到返回 nil —— 那表示注入方是旧版本，
    /// 按原有的广播路径走。
    public static func besidePayload() -> RuntimePayloadRendezvous?
}
```

载荷入口相应改为：

```swift
#if os(macOS) || targetEnvironment(macCatalyst)
// 不变
#elseif targetEnvironment(simulator)
// 不变：模拟器继续自行广播
#else
if let rendezvous = RuntimePayloadRendezvous.besidePayload() {
    runtimeEngine = RuntimeEngine(
        source: .injectedTCP(
            name: processName,
            host: rendezvous.hostAddress,
            port: rendezvous.hostPort,
            identifier: .init(rawValue: rendezvous.claimToken),
            role: .server,          // 业务上的服务端，网络上的客户端
        )
    )
} else {
    // 旧注入方：保持原有广播行为
    runtimeEngine = RuntimeEngine(source: .bonjour(...))
}
try await runtimeEngine?.connect()
#endif
```

### 五、传输层

新增一个 source case，而不是改 `.localSocket` 的形状 —— 后者会波及每一处 switch，而新增一个 case 会让编译器指出所有需要决定的地方（例如 `RuntimeEngine.injectionTargetsRunOnThisMachine` 的 switch 刻意没有 `default`）：

```swift
/// 注入载荷在真机上的传输：业务上的服务端，网络上的客户端。
///
/// 与 `.localSocket` 的唯一区别是地址可指定；与 `.directTCP` 的区别是角色反转
/// —— `.directTCP` 的服务端会 `bind`，而这正是目标沙盒禁止的那个动作。
case injectedTCP(name: String, host: String, port: UInt16, identifier: Identifier, role: Role)
```

实现复用 `RuntimeLocalSocketConnection` 的反转逻辑，把写死的 `inet_addr("127.0.0.1")` 参数化为 host。保持裸 BSD socket，**不改用 Network.framework** —— 实测两者在目标进程里都能向外连，但裸 socket 不经过 NECP，而本提案遇到的每一次拒绝都出自那一层。

### 六、宿主侧

宿主为每次注入临时监听一个端口，并把地址与令牌放进请求；连接到达后按令牌认领，取代 `awaitInjectedBonjourEngine` 在真机路径上的角色（模拟器路径仍用它）。

### 七、重连

载荷持有 rendezvous，连接断开后退避重试同一地址。退避上限与是否永久重试见「落地步骤」第 5 步 —— 它需要一次真机观察才能定，不在此先写死。

## 替代方案考量

**A：载荷连设备上的 App，App 代它广播并转发。** 已否。App 是普通 iOS App，会被挂起或回收，而那恰好发生在用户盯着 Mac 时 —— 所有注入的引擎会跟着它一起断。它还要求 App 在数据通路上做转发，是三个候选里新增成本最高的。

**B（本提案）：载荷直连宿主。** 选中。App 只在注入那一刻参与，之后退出数据通路。

**C：把 `RuntimeEngineManager` 的引擎共享与镜像移植到 iOS。** 已否。最通用，但要在 iOS 上立起整套管理器，而本方案一行都不需要它。

**D：保持广播，只修身份问题。** 不够。它能让 3/7 的目标工作，另外 4/7 仍然连监听都建不起来。它作为第一步仍有价值（见关联提案的落地步骤），但不能作为终点。

**E：调大 MachInjector 的 210 毫秒预算。** 无关。那条超时针对的是挂起的目标，与沙盒禁止绑定是两回事。

**F：让载荷改用 Network.framework 的 `NWConnection` 向外连。** 可行但不选。实测它在被禁 `bind` 的进程里也能向外连，但它要先注册 NECP 流，而本提案遇到的全部拒绝都发生在那一层；裸 socket 少一层可能说不的东西。

## 影响

### 用户可见变化

**无新界面。** attach 流程与今天一致：选设备 → 选进程 → Attach。

变化在成功率：今天在多数 daemon 上点 Attach 后什么都不会发生（载荷静默地起不了监听），之后会正常连上。

错误文案有两处要修，都是今天就错的：

- 超时提示现在写的是「A **simulator** payload…」并建议 `xcrun simctl spawn <udid> log show` —— 那是模拟器路径的文案被原样复用到设备上，建议与操作对真机都不适用。
- 挂起的 App 注入失败时只报 `injection timed out`，不说明原因。

### 可发现性

不新增开关，也没有默认值要选。对用户而言这是「原本应该工作的东西开始工作了」。

### 数据与配置兼容

不触碰任何持久化数据。rendezvous 文件写在 `/private/var/tmp` 下的暂存目录里，每次注入覆盖，不属于用户数据。

**与旧版本的兼容**：`rendezvous` 是可选字段，为 nil 时载荷走原有广播路径。所以旧宿主 + 新载荷、新宿主 + 旧载荷都不会崩，只是退回今天的行为。

### 平台与最低版本

最低版本不变。**仅影响 iOS 真机**；模拟器、macOS、Mac Catalyst 的路径一律不动。

### 发布

不新增 entitlement、不新增隐私清单条目。注入载荷继续只需要越狱版 App 已有的三条（`no-sandbox` / `no-container` / `task_for_pid-allow`）。

**一处运维事实要写进使用指南**：载荷需要能从设备连到 Mac。vphone 的 `tunnel` 网络模式是「仅出向」的，宿主无法被 guest 连到，因此该模式下此功能不可用 —— 需要 `nat` 或 `bridged`。真机经 Wi-Fi 不受此限制，但 macOS 防火墙若阻止传入连接同样会挡住。

## 落地步骤

1. **`RuntimePayloadRendezvous` 与请求字段**：新增类型、给 `InjectIntoProcessRequest` 加可选字段、`RuntimeEngine.inject` 加参数。带编解码测试，覆盖「字段缺失 = 旧对端」这一路。
2. **暂存写入**：`RuntimePayloadStaging.stage(rendezvous:)` 与载荷侧的 `besidePayload()`。带测试：写入后可读回、权限正确、重复注入覆盖而非追加、文件缺失返回 nil。
3. **`.injectedTCP` 与传输层**：新增 source case，把 `RuntimeLocalSocketConnection` 的回环地址参数化。编译器会指出每一处需要决定的 switch。带测试：两端在本机上收发一轮。
4. **宿主侧监听与认领**：每次注入临时监听、按令牌认领、替换真机路径上的等待逻辑。模拟器路径保持走 `awaitInjectedBonjourEngine`。
5. **真机验证**：在之前失败的四个目标（`searchpartyd`、`mediaplaybackd`、`backboardd`、`dasd`）上注入并浏览接口；观察断开重连的实际表现，据此定下第 7 节的退避策略。
6. **错误文案**：修掉模拟器文案复用，以及挂起目标的无信息提示。
7. **收尾判断**（结果写进决策日志，不允许沉默跳过）：
   - 配套文档：几乎确定要写**实现说明** —— 「载荷继承目标沙盒」「身份不能在别人进程里推导」「为什么是裸 socket 而非 Network.framework」这三条都是从代码看不出来的决策。使用指南需要补网络可达性那一条。
   - 新术语：`rendezvous`（注入方交给载荷的报到信息）大概率要进术语表，落地时判定。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-02 | Created as Draft | 真机验证暴露出「载荷自己监听」的前提对多数目标不成立，经两轮澄清提问定稿。 |
| 2026-10-02 | 选 B（载荷直连宿主）而非 A（经设备 App 转发） | 用户指出的理由决定性且优于我原本给的「更简单」：A 把会被系统回收的 iOS App 放进数据通路，它一旦被挂起或回收，所有注入的引擎一起断。 |
| 2026-10-02 | 模拟器不动 | 它的 Bonjour 路径可用且已验证，两个问题（沙盒禁绑定、身份不可靠）在模拟器上都不存在。改它等于动一条好路换不来收益。因此「iOS 一律反向」这个早先的表述收窄为「**真机**一律反向」。 |
| 2026-10-02 | 身份由注入方给定，而非载荷推导 | 实测根因：`localDeviceID` 在目标进程里取决于那个进程的 entitlement，`sharingd` 答得上来而 `chronod` 答不上来，于是后者落入独立分组、认领失败。 |
| 2026-10-02 | 传输用裸 BSD socket，不用 Network.framework | 两者实测都能在被禁 `bind` 的进程里向外连，但本提案遇到的每一次拒绝都出自 NECP 层，而裸 socket 不经过它。 |
| 2026-10-02 | 新增 source case，而不是改 `.localSocket` 的形状 | 新增 case 让编译器指出每一处需要决定的 switch；改既有 case 的形状会波及所有调用点却不强制任何判断。 |
| 2026-10-02 | 断线后持续重连原地址 | 宿主重启后连接自己回来，不必重新注入整批目标。代价是载荷会在目标进程里保有一个重试循环，退避上限留到第 5 步按实测定。 |
| 2026-10-02 | 挂起的目标不在范围内 | 它卡在 MachInjector 的 210 毫秒远程线程等待，与连接方向无关，单独处理。 |

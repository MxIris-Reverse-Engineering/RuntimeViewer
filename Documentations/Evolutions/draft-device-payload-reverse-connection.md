# Draft - 真机注入载荷改为反向连接

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-02
- **最后更新**: 2026-10-02
- **所属愿景**: 无
- **关联提案**: [draft-jailbroken-ios-injection.md](draft-jailbroken-ios-injection.md)（本提案修正它对传输层的假设）
- **实现分支 / PR**: `feature/jailbroken-ios-injection`（未推送）
- **配套文档**: [`DevicePayloadReverseConnection.md`](../DevicePayloadReverseConnection.md)（实现说明）、[`Guides/JailbrokenDeviceInjection.md`](../Guides/JailbrokenDeviceInjection.md)（使用指南）

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

探针代码本身留在 `discarded/sandbox-reachability-probe`（`82b93e59`），不会被合并 —— 留档的理由是上面那三行结论的出处，主线只保留结论。

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

    /// 一次注入一个。实现时补的：picker 允许同时发起两次注入，共用令牌会让宿主把先到的
    /// 那个交给错误的请求。
    public static func makeClaimToken() -> String

    /// 三项齐备才算能用。载荷在放弃广播之前查它 —— 半填的 rendezvous 比没有更糟：
    /// 载荷既不广播也连不上，彻底没有症状。
    public var isUsable: Bool
}
```

落地时另外补了两个工厂，都是实现中才看出必要的：

```swift
extension RuntimePayloadRendezvous {
    /// 从「到这台设备的那条连接」上取地址，而不是枚举本机网卡去猜。
    /// 一台 Mac 同时有 Wi-Fi、以太网、VPN 和虚拟机网桥时，猜有好几个看起来都对的错答案。
    public static func reachingThisProcess(from engine: RuntimeEngine) async throws -> RuntimePayloadRendezvous
}

extension RuntimeConnection {
    /// 对端要怎么连到本进程 —— 只有活着的网络连接答得上来，其余传输一律 nil。
    var localAddressSeenByPeer: String? { get }
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

1. ✅ **`RuntimePayloadRendezvous` 与请求字段**（`90b726c1`）。另加：公开方法上的 `rendezvous`
   **刻意不给默认值** —— 漏传的调用方会落到「多数真机目标上静默什么都不发生」那条路，所以让编译器问。
2. ✅ **暂存写入**（`1b1198f1`）。读取接口最终是 `stagedBesideImage(#dsohandle)` 而非提案原先写的
   `besidePayload()`：`#dsohandle` 在使用处展开，写在 Core 里会指到 Core 自己，而暂存布局把它放在
   `Frameworks/` 下又深一层。另：rendezvous 为 nil 时**删除**残留文件，这是唯一没有自身症状的那种错 ——
   旧文件会让一个本该广播的载荷去连一个已经不在监听的宿主。
3. ✅ **`.injectedTCP` 与传输层**（`5b765780`）。编译器点出两处需要决定的地方，两处都记进了决策日志。
   地址解析从 `inet_addr` 换成 `inet_pton`：前者把失败报成 `0xFFFFFFFF`，于是写错的地址会变成一次
   对广播地址的连接而不是一个错误。重连不需要新代码 —— 现成的客户端循环本来就一直重试构造时那个地址。
4. ✅ **宿主侧监听与认领**（`623b3b8f`）。等待改成**两种到达方式赛跑**而非二选一，详见决策日志。
5. ✅ **真机验证**：`searchpartyd`、`mediaplaybackd`、`dasd`、`chronod`、`sharingd` 五个全部通过，
   其中前三个正是之前被内核拒 `network-bind`、这条路之前完全不可能的。`backboardd` ❌ 不支持，
   根因未查明且本提案内修不了，见上「真机验证中测到的」。重连实测可用：越狱版 App 切回前台后，
   断掉的引擎自己回来。退避策略据此定为「永不放弃」，理由见上。原始观察：`searchpartyd` ✅ 首个通过 —— 它正是之前被内核拒 `network-bind` 的四个之一，
   现在能注入、能浏览接口，且落在设备分组里。Mac 这边 `lsof` 看得到那条连接：
   `169.254.8.252:55166 -> 169.254.107.198:49428 (ESTABLISHED)`，目标进程驻留内存 42.3 → 61.4 MB。
   剩 `mediaplaybackd`、`backboardd`、`dasd` 待测；断开重连的实际表现与退避策略也还没定。
6. ✅ **错误文案**（`623b3b8f` 与 `81a874de`）。两条都修了，各带一条钉住文案内容的测试。
7. ✅ **收尾判断**：
   - 配套文档：**两份都写了**。实现说明
     [`DevicePayloadReverseConnection.md`](../DevicePayloadReverseConnection.md) —— 原计划的三条之外，
     真机验证又添了四条同样从代码看不出来的：地址只能取自活连接且每次重启都变、载荷只有一次运行机会、
     两种到达方式是赛跑、「注入成功」不等于载荷跑起来了。另附排查顺序与已知不支持的目标。
     使用指南 [`Guides/JailbrokenDeviceInjection.md`](../Guides/JailbrokenDeviceInjection.md) ——
     不只补了网络可达性，还收了「越狱版必须在设备屏幕上」和每条错误文案怎么读。
   - 新术语：**`rendezvous` 进了术语表**，连同 `认领令牌`（特意写明它只做区分不做认证）与 `反向连接`。

## 真机验证中测到的

### 链路本地地址每次重启都变，所以不能记住

vphone guest 那条链路上没有 DHCP（guest 的 `configd` 一直 `DHCP en1: INIT waiting`），
两端都自分配 `169.254.0.0/16`。实测三次 VM 重启的地址对：

| | Mac | guest |
|---|---|---|
| 第一次 | `169.254.153.160` | —— |
| 第二次 | `169.254.113.76` | `169.254.241.169` |
| 第三次 | `169.254.8.252` | `169.254.107.198` |

**每次都变**。这直接否掉了「把地址存下来下次复用」和「写死 vmnet 网关 `192.168.64.1`」两种做法 ——
后者更有迷惑性，因为那个地址确实一直存在于 `bridge101` 上，只是 Bonjour 根本没走那条接口。
现在每次从活连接上现读，所以这件事不需要处理。

### 「注入成功」不等于载荷跑起来了

有一个 VM 会话里，同一个 `searchpartyd` 连续两次注入都报成功而载荷从未加载。当时测到的特征是齐全的：

- 目标的驻留内存 42.3 MB **一毫不动**（载荷加载后是 61.4 MB）
- guest 全量日志里载荷的字符串**一个都没有**（`Attach successfully`、`Reporting to the host` 全为 0）
- 没有崩溃报告，没有 sandbox 拒绝，没有 AMFI 拒绝，目标进程也没重启
- 宿主侧全对：监听地址端口正确、设备上 `rendezvous.json` 的内容与之逐字节一致、暂存的载荷与 App 包里的字节数相同、双向 ping 0.6 ms

重启 VM 后同一个目标立刻正常。**根因未查明，不编造。** 但暴露出的可诊断性缺口是确定的：
`MIMachInjector` 的同步路径在远程 pthread 建好时就报成功，`dlopen` 的裁决要在一个轮询预算内回报，
**超出预算的失败会被当成成功**（它自己的头文件写明了这一点）。对一个 81 MB 的载荷，
宿主因此分不清「还没连上来」和「根本没加载」，这正是上面那段排查花掉二十多分钟的原因。
`MIMachInjectorAsync` 有带超时的完成回调，能给出真正的裁决 —— 换过去是候选，未做。

### 越狱版 App 离开前台一秒内就被挂起

guest 日志实测（`com.JH.RuntimeViewer.Jailbroken`，pid 412）：

```
14:10:40 runningboardd  Set jetsam priority to 90
14:10:41 runningboardd  Calculated state: running-suspended (role: None)
14:10:41 runningboardd  Set jetsam priority to 0
14:10:41 SpringBoard    running-suspended-NotVisible
```

**一秒。** 之后 jetsam 优先级 0，是最先被回收的那一档 —— 实测中它确实被回收过多次。

两个直接后果：

- **注入期间 App 必须是设备屏幕上的那个 App。** 注入在 App 进程里执行，被挂起就没人处理 RPC。
  注意判据是**设备屏幕**，不是 macOS 的窗口焦点 —— guest 不知道 macOS 的焦点在哪，所以在 Mac 上
  点 Attach 本身不会让它挂起，只有在 guest 里切走才会。
- **设备引擎（`RuntimeViewer JB` 那条）必然随之断开**，因为那条连接是 App 持有的。这是 iOS 的常态，
  不是缺陷；已注入的 daemon 载荷活在 daemon 里，不受影响（**待验证**，见落地步骤第 5 步）。

这也让异步注入器 20 秒的裁决窗口比预想的更脆：切走即挂起，裁决就永远不会到。
同步路径 210 毫秒往往能在挂起前跑完。目前接受这个代价 —— 换来的是不再把失败报成成功 ——
但若实际用起来经常撞到，这个数字要重新考虑。

### 注入 App 结构上受限，不只是「挂起」这一条

iOS 上只有一个 App 能在前台。要注入 App X，越狱版必须在跑（注入由它执行），而 X 这时必然在后台。
实测注入「设置」失败即此。能稳定注入的是 **daemon**，以及恰好持有后台执行权的 App。
这不是本提案能解决的，它在开篇就被列为非目标。

### `backboardd` 不支持，以及为什么现在修不了

同一会话里五个目标成功、唯独它失败，所以不是环境问题。它的特征：

- 异步注入器给出**真裁决且是成功** —— `result_code == 0 && handle != 0`，由目标进程自己写回
- 目标驻留内存**几乎不动**（对比 `sharingd` +22.7 MB、`chronod` +16.6 MB）
- 载荷**零日志**（而对照组证明成功注入时 `Attach successfully` 等四行都看得见）
- 没有崩溃、没有 sandbox 拒绝、没有 AMFI 拒绝

唯一能同时解释「handle 非空 + 内存不涨 + 构造器没跑」的是：**`dlopen` 了一个已经加载过的镜像**。
但这意味着某一次首注是成功加载的，而那一次又没连回来 —— 这一点三次尝试都没抓到日志，**未查明**。

即便查明，本提案里也修不了：失败点在 `dlopen` / MachInjector 那一层，而 macOS 上同类问题
（strict-seatbelt daemon 拒 `file-map-executable`）的解法是 `mach_vm_remap`，
**它在 iOS 上今天不可用** —— MachInjector 内嵌的 loader 是用不带 `-target` / `-isysroot`
的脚本编的，产物是 macOS dylib。移植它是 MachInjector 自己仓库的提案。

### 载荷只有一次运行机会，所以不能放弃

载荷由 `main.m` 的 `__attribute__((constructor))` 启动，dyld 只跑一次。而 **`dlopen` 一个已经在
进程里的镜像会返回现成 handle、不加内存、不跑任何初始化器**。两件事合起来意味着：

**一个首连失败过的载荷，会让那个目标永久不可用** —— 之后每一次注入都返回成功的 handle，
而什么都不会发生。实测特征正是如此：目标驻留内存纹丝不动、零日志、注入却次次报成功，
直到目标进程自己重启。

所以 §七 留给本步决定的「要不要永久重试」没有取舍空间：**必须一直重试**。首次连接窗口
（默认 10 秒）保留，但它过后不再抛出，而是转入后台重试循环；地址格式错误仍然立即抛出，
因为那个重试多久都不会变成合法地址，抛出去才能让载荷退回广播路径。

## 本提案范围之外的后续

真机验证把三件事推到了台面上，都**不在本提案范围内**，各自需要单独决定：

1. **保活** —— 越狱版离开前台一秒内就被挂起（实测，见上）。想在后台继续服务就得用后台模式、
   RunningBoard 自持断言，或干脆把注入器改成 LaunchDaemon。属于父提案
   [draft-jailbroken-ios-injection.md](draft-jailbroken-ios-injection.md) 的设备侧架构，完整档。
2. **注入 App** —— iOS 只给一个 App 前台，注入器在跑就意味着目标 App 不在跑。这不是「碰巧被挂起」，
   是结构性的，且只有解决了第 1 条才谈得上。
3. **`backboardd`** —— 失败在 `dlopen` / MachInjector 那一层。macOS 上同类问题的解法
   （`mach_vm_remap`）在 iOS 上不可用，移植它是 MachInjector 自己仓库的提案。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-02 | Created as Draft | 真机验证暴露出「载荷自己监听」的前提对多数目标不成立，经两轮澄清提问定稿。 |
| 2026-10-02 | 选 B（载荷直连宿主）而非 A（经设备 App 转发） | 用户指出的理由决定性且优于我原本给的「更简单」：A 把会被系统回收的 iOS App 放进数据通路，它一旦被挂起或回收，所有注入的引擎一起断。 |
| 2026-10-02 | 模拟器不动 | 它的 Bonjour 路径可用且已验证，两个问题（沙盒禁绑定、身份不可靠）在模拟器上都不存在。改它等于动一条好路换不来收益。因此「iOS 一律反向」这个早先的表述收窄为「**真机**一律反向」。 |
| 2026-10-02 | 身份由注入方给定，而非载荷推导 | 实测根因：`localDeviceID` 在目标进程里取决于那个进程的 entitlement，`sharingd` 答得上来而 `chronod` 答不上来，于是后者落入独立分组、认领失败。 |
| 2026-10-02 | 传输用裸 BSD socket，不用 Network.framework | 两者实测都能在被禁 `bind` 的进程里向外连，但本提案遇到的每一次拒绝都出自 NECP 层，而裸 socket 不经过它。 |
| 2026-10-02 | 新增 source case，而不是改 `.localSocket` 的形状 | 新增 case 让编译器指出每一处需要决定的 switch；改既有 case 的形状会波及所有调用点却不强制任何判断。 |
| 2026-10-02 | 首次连接也永不放弃，不只是断线后 | 真机观察定下了 §七 留的那个问题。载荷由构造器启动、dyld 只跑一次，而 `dlopen` 已加载的镜像是空操作 —— 所以放弃一次就等于把那个目标废到进程重启，且之后每次注入都还报成功。没有取舍空间。 |
| 2026-10-02 | 断线后持续重连原地址 | 宿主重启后连接自己回来，不必重新注入整批目标。代价是载荷会在目标进程里保有一个重试循环，退避上限留到第 5 步按实测定。 |
| 2026-10-02 | 挂起的目标不在范围内 | 它卡在 MachInjector 的 210 毫秒远程线程等待，与连接方向无关，单独处理。 |
| 2026-10-02 | 收尾判断：两份配套文档都写，术语表加三条 | 原计划只打算写三条「从代码看不出来」的事实，真机验证又添了四条，值得独立成篇而不是塞进提案。`认领令牌` 单独收进术语表并写明它**只做区分不做认证** —— 它和载荷同在一个世界可读的目录里，把它当密钥是会被将来的人误读的那种错。 |
| 2026-10-02 | Draft → Accepted | 用户批准（「开工」），开始按落地步骤实现。 |
| 2026-10-02 | 宿主地址取自「到该设备的那条连接」，不枚举本机网卡 | `NWConnection.currentPath.localEndpoint` 就是那台设备实际到达本机的地址。枚举网卡要在 Wi-Fi / 以太网 / VPN / 虚拟机网桥之间挑一个，每个都「看起来可能对」。取不到地址时整条 attach 直接拒绝并说明，而不是拿一个猜测去注入 —— 后者的结果是载荷连向虚空、用户盯着一个永远不出现的目标。 |
| 2026-10-02 | 端口向内核要（`RuntimeUnusedPort`），不沿用 `localSocket` 的哈希 | 宿主必须在载荷存在**之前**就在监听，所以它只能自己挑一个再告诉对方，没法跟对方约定一个哈希。代价是「要到」与「真正 bind」之间有一个窗口，接受它：输了竞争会在自己的 `bind` 上响亮地失败。 |
| 2026-10-02 | 等待改为「两种到达方式赛跑」，而不是先判断对端是模拟器还是真机 | 走哪条路由载荷在编译期决定，宿主读不出来。赛跑同时就是混版兼容的全部答案：忽略 rendezvous 的旧对端不是一个需要单独分支的失败情形，它只是赢了另一半。替代做法是从广播的 model identifier 去猜是不是模拟器 —— 那是猜。 |
| 2026-10-02 | 宿主 bind 它公布出去的那个地址，而不是所有网卡 | 设备根本到不了的地址会在宿主这边立刻失败、且错误里带着地址，而不是留下一个连向虚空的载荷。用 RFC 5737 保证不可路由的 `192.0.2.1` 做了测试。 |
| 2026-10-02 | ~~`injectedTCP` 的书签身份就是认领令牌~~ → **改为「设备 + 进程名」，与广播回来的那条完全同形** | 真机跑通后发现的更大问题顺带解决了这条：引擎按 `hostInfo.hostID` 分组，而我建引擎时用的是默认 hostInfo（本机的），于是 `searchpartyd` 被列在 Mac 组里、挨着 Mac 自己的进程。身份要从**发起注入的那条设备引擎**上取 —— 它早就带着正确的 hostInfo 与 deviceID。顺手把书签作用域也换成 `.bonjour(deviceID:processName:)`：认领令牌描述的是**一次注入**而不是那个进程，拿它存书签每次重注都会丢。`RuntimeBookmarkScope.Identity.injectedTCP` 保留，它是 `recovered(from:)` 对没带显式作用域的描述符的兜底。 |
| 2026-10-02 | 命令行的 `SourceKind` 新增 `injectedDevice` | 复用 `attachedSocket` 虽然传输相同，但那个 kind 的含义是「本机上的一个进程」，拿它描述一台手机上的进程是在关于目标位置这件事上给出明确的错答案。它的 selector 用引擎标识符而非 `pid:` —— pid 是设备的，`pid:` 会解析成本机持有那个 pid 的随便哪个进程。 |
| 2026-10-02 | 连接报的是 IPv6 时，保留它给出的**接口**，只换地址族 | 真机实测：到设备的 Bonjour 连接落在 `fe80::4c5:a2b1:1313:2629%en26`，而载荷的 socket 是 `AF_INET`。那个地址两头都用不了 —— 族不对，而且链路本地地址的 scope 是**本机**的接口序号，在设备自己的编号里没有意义。有价值的是接口名：它是从活连接上观察到的，不是从本机网卡列表里挑的。于是只把族换掉，取该接口的 IPv4 地址。`en26` 上只有一个自分配的 `169.254.153.160`，照样返回 —— 没有 DHCP 的链路上两端都会自分配，彼此够得着。 |
| 2026-10-02 | 挂起目标的超时改文案，不调预算 | MachInjector 自己的头文件对该错误码就写着「挂起的目标产生同样的症状」。预算不是问题所在：挂起的进程没有被调度的线程，等多久都不会有回报。 |
| 2026-10-06 | **PR #119 review：裸 socket 这条路的第二笔账 —— `SIGPIPE`** | 第四节记过「选裸 socket 而不用 Network.framework，有一笔没算到的账，就是 keepalive」。`SIGPIPE` 是同一笔账的另一半：`sendRaw` 以 flags 0 调 `send`，而 fd 从未设 `SO_NOSIGPIPE`，仓库里也没有任何地方忽略这个信号。对端 RST 之后下一次 `send` 拿到 `EPIPE`，内核先发 `SIGPIPE`，默认动作是结束进程 —— 一端是 App，另一端是被注入的目标（可能是系统守护进程）。触发场景平常：加载中途 detach 或退出、目标被杀、keepalive 判死。基线（`next` / `main`）同样有，已随正式版发出，所以另开了一个只改这一处的 PR 给 main；本分支在 `configureSocketOptions` 里一处设上，拨出与接入两端都覆盖 |
| 2026-10-06 | 被动断线不再拆掉注入引擎，监听保留等载荷重拨 | 载荷只认 rendezvous 里那一个地址和端口，且永远重拨：重新注入同一暂存路径只会拿到已加载的 image、不跑构造器，所以拆掉监听等于永久关掉它唯一会拨的端口 —— 目标在重启前再也接不上，而宿主把后续每次尝试报成超时并归咎于挂起或防火墙。界线用传输已有的区分：socket 错误是链路（25 秒 keepalive 预算、RST），载荷还在；`peerClosed` 是进程，而被杀的进程由内核关掉 socket，所以 `kill -9` 也走这条 —— 不需要额外定时器去发现真的死掉的目标。「断线即拆」原本来自回环，那里每次断开确实都等于目标已消失 |
| 2026-10-06 | 暂存目录按目标 pid 分开（Copilot `r4192141724`） | 原本所有注入共用 `/private/var/tmp/RuntimeViewerPayload`，而 `stage` 会先删后写 payload、依赖和 rendezvous，一次注入最长等 20 秒裁决。第二次注入落在这个窗口里就会把第一个载荷还没读的 rendezvous 换掉：它于是拨到第二次的端口被当成另一个进程认领，或正好撞上删与写之间的空档、读不到文件而退回广播 —— 在不能 bind 的目标上等于永远不报到。单个 picker 用 `isAttaching` 串行化，所以要两个发起方（第二个文档窗口、MCP、CLI）才会撞上，但它们互不感知。按 pid 而不是按认领令牌分目录：同一 pid 重注入复用自己的目录，不会每次留一份 |
| 2026-10-06 | 新增的 `.injectedTCP` 不进引擎镜像描述符 —— 否则旧版 Mac 会丢掉整条镜像连接（Copilot `r4192141644` 也报了同一条） | `RuntimeSource` 的 `Codable` 是合成的，而 `engineList` 是对**整个** `[RuntimeRemoteEngineDescriptor]` 一次解码，所以旧对端遇到它没有的 case 就整次失败；它的心跳再把失败当死链，连续 2 次（间隔 30 秒）即停掉引擎 —— 这台 Mac 镜像过去的**所有**引擎一起消失，直到 Bonjour 重新发现，然后循环。**这是镜像上线以来第一次新增 source case**，所以是第一个触发这个既存脆弱点的改动；旧版已发出，只能在发送端修。修法是 `RuntimeSource.isMirrorableToPeers`（新 case 默认不镜像）＋ `buildEngineDescriptors` 按它过滤。代价为零：`draft-jailbroken-ios-injection` 的 UI 表格本来就把「远程同步来的镜像引擎」列为 disabled，而经该设备自己的引擎就能看到这个进程。测试用新写的五 case 冻结解码器 —— 既有的冻结 descriptor 复用当前 `RuntimeSource`，证不了「新增 case」这件事 |

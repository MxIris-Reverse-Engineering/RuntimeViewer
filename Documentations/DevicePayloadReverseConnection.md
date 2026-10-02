# 真机注入载荷为什么反着连

读 `RuntimeViewerServer.main()`、`RuntimeSource.injectedTCP`、`RuntimePayloadRendezvous`
或 `RuntimeLocalSocketConnection` 之前先看这篇。它们的形状是被三件从代码里看不出来的事实逼出来的，
每一条都在真机上量过，而每一条的「显然做法」都是错的。

对应提案：[真机注入载荷改为反向连接](Evolutions/draft-device-payload-reverse-connection.md)。

---

## 一、载荷继承的是**目标进程**的沙盒，不是注入方的

越狱版 App 自己带着 `no-sandbox`，所以它能枚举、能注入。但 `dlopen` 进去之后，载荷跑在目标进程里，
受的是**那个进程**的沙盒 profile 约束。而 `network-bind` 恰是 iOS daemon 最常被禁的一项：

```
Sandbox: searchpartyd(159)   deny(1) network-bind local:*:55330
Sandbox: mediaplaybackd(346) deny(1) network-bind local:*:55331
Sandbox: dasd(83)            deny(1) network-bind local:*:59999
```

逐个实测的七个目标里，四个被拒。**调用方无法预先知道一个目标属于哪一类** —— 它取决于那个 daemon 的
sandbox profile，进程列表里看不出来。

于是载荷不能监听。**但向外 `connect()` 在被禁 `bind` 的进程里仍然放行**（一次性探针实测，故意打一个
没人监听的端口，让 `ECONNREFUSED` 与 `EPERM` 的区别本身成为答案）。所以方向反过来：载荷主动拨回宿主。

**模拟器验不出这条。** 模拟器 guest 的沙盒宽松得多，`bind` 不被拒 —— 所以模拟器那条广播路径一直好用，
至今未动。

## 二、身份不能在别人的进程里推导

载荷原先自己算设备标识，经 `MobileGestalt`。而 `MobileGestalt` 按**目标进程的** entitlement 作答：
`sharingd` 本职处理设备身份，答得上来；`chronod` 答不上来，退到按进程解析的 keychain UUID。

症状是引擎选择器里出现**两个都叫 `iphone` 的分组**，而认领用的 `{deviceID}-{pid}` 永远匹配不上。

`RuntimeNetworkBonjour+LocalIdentity.swift` 的注释预言过这条路，并称它「目前不可达而非被防住，靠两道
独立的闸」：模拟器上 `SIMULATOR_UDID` 先答，以及 MobileGestalt 会先答。**真机上第一道闸根本不存在。**

所以身份改为**由注入方给定**：宿主签发一个一次性令牌放进 rendezvous，载荷原样呈上。宿主只认自己发出去的值，
两边都不需要推导任何东西。

## 三、宿主地址只有「到那台设备的那条连接」知道

反向连接需要一个地址，而**枚举本机网卡去挑是在猜**。一台 Mac 同时有 Wi-Fi、以太网、VPN 和虚拟机网桥时，
每个都「看起来可能对」。

正确的来源是到设备的那条活连接：`NWConnection.currentPath.localEndpoint` 就是那台设备实际到达本机的地址。

但它实测是 **IPv6 链路本地**（`fe80::4c5:a2b1:1313:2629%en26`），而载荷的 socket 是 `AF_INET`。
那个地址两头都用不了 —— 族不对，而且链路本地地址的 scope 是**本机**的接口序号，在设备自己的编号里
不是同一个数，原样递过去即便改用 IPv6 传输也是错的。

**留接口、换地址族**：接口名是观察到的，拿它查本机在该接口上的 IPv4 地址（`RuntimeInterfaceAddresses`）。
实测那是一个自分配的 `169.254.x.x`（链路上没有 DHCP，两端都自分配），照样可用 —— 实测 RTT 0.6 ms。

> **别写死 vmnet 网关 `192.168.64.1`。** 它确实一直存在于 `bridge101` 上，很有迷惑性，
> 但 Bonjour 根本没走那条接口。而且链路本地地址**每次 VM 重启都变**（实测三次重启三组不同的地址对），
> 所以也不能记住上次的值。每次从活连接现读，这两个坑同时消失。

---

## 四、传输为什么是裸 BSD socket 而不是 Network.framework

两者实测在被禁 `bind` 的进程里**都能**向外连。选裸 socket 的理由是少一层能说不的东西：
本功能遇到的每一次拒绝都出自 NECP 层（`NECP_CLIENT_ACTION_ADD_FLOW … Operation not permitted`），
而 Network.framework 要先注册 NECP 流，裸 socket 不经过它。

`RuntimeLocalSocketConnection` 本来就实现了需要的角色反转（它的文档原文：「主 App 是业务上的客户端但
**网络上的服务端**，注入的代码是业务上的服务端但**网络上的客户端**」），只是把地址写死成回环。
`.injectedTCP` 就是把那个地址参数化，别无其他。

**不是 `.directTCP`。** 它的角色**没有**反转 —— `RuntimeSource.swift` 注释写明「host 为 nil 表示服务端」，
而 `RuntimeDirectTCPConnection` 里 server 角色建 `NWListener`。业务服务端在它这里就是网络服务端，
仍然要 `bind`，而那正是目标沙盒禁止的动作。

## 五、载荷只有一次运行机会

载荷由 `main.m` 的 `__attribute__((constructor))` 启动，dyld 只跑一次。而 **`dlopen` 一个已经在进程里的
镜像会返回现成 handle、不加内存、不跑任何初始化器**。

所以**载荷不能放弃首次连接**：放弃一次就把那个目标废到进程重启为止，而之后每一次注入都还会返回成功的
handle。实测特征正是如此 —— 目标驻留内存纹丝不动、零日志、注入却次次报成功。

首次连接窗口（10 秒）保留，它过后转入后台重试循环而不是抛出。唯一仍然立即抛出的是地址格式错误 ——
重试多久都不会让它变成合法地址，抛出去才能让载荷退回广播路径。

## 六、宿主侧：两种到达方式是**赛跑**，不是二选一

载荷走哪条路由它自己在**编译期**决定（`#if targetEnvironment(simulator)`），宿主读不出来。所以宿主
总是开监听、总是下发 rendezvous，然后同时等两件事：令牌连接到达，或 Bonjour 广播出现。先到的赢，
另一半拆掉。

这同时就是**混版兼容的全部答案**：忽略 rendezvous 的旧对端不是一个需要单独分支的失败情形，它只是赢了
另一半。替代做法是从广播的 model identifier 去猜对端是不是模拟器 —— 那是猜。

宿主 bind 的是它**公布出去的那一个地址**，不是所有网卡。这样「设备根本到不了的地址」会在宿主这边立刻
失败、错误里还带着地址，而不是留下一个连向虚空的载荷和一个永远不出现的目标。

## 七、注入成功 ≠ 载荷跑起来了

`MIMachInjector` 的**同步**路径在远程 pthread 建好时就报成功，`dlopen` 的裁决要在一个轮询预算内回报，
**超出预算的失败会被当成成功**（它自己的头文件写明了这一点）。对一个 81 MB 的载荷，这让「被慢慢拒绝」和
「加载成功」在宿主眼里一模一样。

所以设备侧用的是 `MIMachInjectorAsync`：它在目标里分配 mach port 等 `MACH_SEND_DEAD`，裁决是真的，
失败时带回**目标进程自己的 `dlerror()` 文本** —— 那是区分「库校验拒绝」和「沙盒拒绝」的唯一依据。
代价是一个报告不出裁决的目标（典型是被挂起的 App）要等满 20 秒才说话。

---

## 排查一次「注了但没连上」的顺序

按这个顺序证伪，别先改代码。全部可从 Mac 侧完成（vphone guest 经 `<VM bundle>/vphone.sock` 的
`{"t":"rpc", …}` 协议）。

1. **宿主在听吗** —— `lsof -nP -i TCP | grep <地址>`。应该看到 `LISTEN`；连上后还有一条 `ESTABLISHED`。
2. **设备拿到的 rendezvous 对不对** —— 读 `/private/var/tmp/RuntimeViewerPayload/rendezvous.json`，
   和上一步的地址端口逐字节比。
3. **两端通不通** —— `ping -b <接口> 169.254.255.255` 一次就能把链路上双方的 IPv4 问出来。
4. **载荷到底跑没跑** —— **看目标进程的驻留内存**。这是最可靠的一个指标：
   加载并运行后实测 `sharingd` +22.7 MB、`chronod` +16.6 MB、`searchpartyd` +19 MB；没跑是 ±2 MB。
5. **载荷自己怎么说** —— guest 日志里搜 `Attach successfully` / `Reporting to the host`。
   成功时四行俱全（已验证可见），所以缺席是真信号。
   **注意**：日志要在注入**那一刻**抓（live-only），且刚开机时日志量大到会撞上 `max_lines`
   上限并留下时间缝 —— 等系统安静下来再测，或用短窗口连续抓。

## 已知不支持

- **`backboardd`** —— 注入返回目标自己写回的真裁决且是成功，而载荷不运行、内存不动、零日志。
  根因未查明。macOS 上同类问题（strict-seatbelt daemon 拒 `file-map-executable`）的解法是
  `mach_vm_remap`，**它在 iOS 上不可用** —— MachInjector 内嵌的 loader 是 macOS dylib。
- **注入其它 App** —— iOS 只给一个 App 前台，越狱版在跑就意味着目标 App 不在跑，挂起的进程没有被调度的
  线程。这是结构性的，不是偶发。
- **uid 0 的目标** —— `mobile + no-sandbox` 拿不到 root 进程的 task port（逐级实测）。

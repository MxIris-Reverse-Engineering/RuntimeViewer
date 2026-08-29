# 2026-08-29 幽灵设备："JH's Mac Studio Ultra (RuntimeViewer)" 自成一台设备出现在引擎菜单里

**调查日期：** 2026-08-29
**修复落地：** 本日，分支 `fix/bonjour-ghost-device`
**Severity：** Moderate —— 引擎菜单出现一台不存在的"设备"，点进去看到的是本机 runtime 绕了一圈回来的数据；不崩溃、不丢数据，但极具迷惑性，且会随引擎镜像扩散到所有相连的 peer
**触发场景：** 两台 Mac 各跑一个 RuntimeViewer 且互相发现；本机菜单里出现一个以「本机广播服务名」命名的独立设备分组，条目与分组同名

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 引擎菜单多出一个 section，标题和唯一条目都是 "JH's Mac Studio Ultra (RuntimeViewer)"——正是本机广播的 Bonjour 服务实例名。本机并没有第二个 RuntimeViewer 在跑 |
| **影响范围** | 所有通过 Bonjour 互相发现的 RuntimeViewer 组合；幽灵一旦在任何一端出现，会被引擎镜像转发到每个相连 peer |
| **根因** | mDNS 把 TXT record 和服务记录分开应答，浏览结果可能在 TXT 到达前浮出。这种结果的所有身份字段都是 `nil`，每一道身份检查都塌回服务名兜底：自我过滤（`instanceID == localInstanceID`）判不中、分组 `hostID` 变成服务名、`originChain` 记下的也是服务名——没有任何一端的循环检测认得它 |
| **Status** | **Fixed** —— 双端修复：浏览器压住无身份的浏览结果直到 TXT 到达；镜像 reconcile 把「本机广播服务名」也当作本机身份参与循环检测 |

---

## 现象

截图（Mac Studio，新版本）：本机分组 "JH's Mac Studio Ultra" 下是正常的 My Mac / My Mac (Mac Catalyst)，MacBook Pro 分组也正常；中间多出一个 **section 标题和条目完全同名** 的分组 "JH's Mac Studio Ultra (RuntimeViewer)"。

「标题 = 条目 = 本机服务名」这个形态就是指纹：`RuntimeEngineManager.connectToBonjourEndpoint` 里 `hostID`、`hostName`、`engineName` 三个字段的兜底全都是 `endpoint.name`，只有 TXT 整体缺失才会三者同时塌到同一个字符串。

MacBook Pro（老版本）的菜单同时印证了另一半：它的 "JH's Mac Studio Ultra" 分组之外，底部也挂着一个同样自成一组的 "JH's Mac Studio Ultra (RuntimeViewer)"。

## 根因

三道闸门全部依赖 TXT record 里的身份键，而没有任何一处对「TXT 还没到」的浏览结果设防：

1. **自我过滤**（`RuntimeEngineManager` 的 `onAdded`）：`endpoint.instanceID == RuntimeNetworkBonjour.localInstanceID`。`instanceID` 为 `nil` 时判不中，本机会连上自己的广播。
2. **设备分组**：`hostID = deviceID ?? instanceID ?? name`、`hostName = hostName ?? name` —— 全部塌回服务名，幽灵自成一组，组名就是本机服务名。
3. **循环检测**：bonjour client engine 的 `originChain: [endpoint.instanceID ?? endpoint.name]` 记下的是服务名。这样的描述符经引擎镜像转发回来时，`RuntimeEngineMirrorRegistry.reconcile` 只认 `localInstanceID`，认不出"链上有我"。

两条成像路径共享这一个根因：

- **路径 A（本机自连）**：本机浏览到自己 TXT 未到的广播 → 连上自己 → 若引擎列表请求恰好失败/为空，被标记为 direct 引擎直接显示。
- **路径 B（peer 回流）**：对端在无 TXT 窗口给本机建了引擎（originChain 里是本机服务名）→ 描述符转发回本机 → 循环检测放行 → 幽灵以镜像身份出现。

**本次实测命中路径 B**：关掉跑老版本 RV 的 MacBook 后幽灵立即消失。老版本永远不会升级出发送侧的修复，所以接收侧的防御（下述修复 2）是必须的。

### 为什么现在才出现

这个 TXT 窗口漏洞在 main 上早已存在，但两个近期变更让它显形：

- `1df0c1c3`（服务名改为 `{主机名} ({进程名})`，跨启动稳定）之前，服务名是 `{deviceID}-{pid}`，同样的失效显示成一段 UUID 乱码，且每次启动都变；现在它顶着本机电脑名出现，看起来像一台真设备。
- `05541196` 新增了 `.changed` 浏览结果 → `onAdded` 的处理路径，TXT 抖动期间的快照（listener 每接受一个连接就注销重注册，抖动窗口频繁）多了一条进入连接流程的路。

无 TXT 的广播只在 v2.0.0-RC.4 这一个发布版本里存在过；`rv-instance-id` 自 v2.0.0-RC.5 起一直存在。所以「无身份的浏览结果」只可能是瞬态竞态，不是一类需要兼容的 peer——这是修复 1 可以无条件压住它们的前提。

## 修复

双端各一刀，都带着能红的测试落地：

1. **发送侧（`RuntimeNetworkBrowser`）**：把「上报什么」抽成纯函数 `events(forAdded:)` / `events(forRemoved:)` / `events(forChangeFrom:to:)`；`instanceID == nil` 的结果不上报，等携带 TXT 的 `.changed` 到达（`metadataChange` 判为 `.replacesEndpoint`）再放行。移除事件不受影响（manager 对移除本就有意不动作）。
2. **接收侧（`RuntimeEngineMirrorRegistry.reconcile`）**：新增 `advertisedServiceName` 参数；`originChain` 含本机 `localInstanceID` **或本机广播服务名** 的描述符都按循环丢弃。manager 调用点传入 `RuntimeNetworkBonjour.localServiceName`（macOS 上与 resolved 变体等价，且引擎镜像只在 macOS 上运行）。

## 验证

- `BonjourBrowseEventTests`（新增，RuntimeViewerCommunicationTests）：无身份结果不上报（幽灵复现）、TXT 到达后放行、TXT 抖动只报移除不报到达、relaunch 双半报告、移除无条件透传。mutation-check：去掉闸门后前两条立刻红（exit 1），恢复后绿。
- `RuntimeEngineMirrorRegistryTests` 新增「originChain 含广播服务名按循环过滤」。mutation-check：去掉服务名过滤后红，恢复后绿。
- 全量相关套件：RuntimeViewerCommunicationTests 6 套 59 测试全绿；RuntimeEngineMirrorRegistryTests 15 测试全绿（均以原始退出码判定）。

## 横向排查

- `uniqueKey`、`bookmarkScope` 等其余 `?? name` 兜底服务的是**部分**缺键的老版本 peer（老 key `rv-instance-id`/`rv-host-name` 在、新 key `rv-device-id`/`rv-proc-pid` 不在），属设计内兼容，保留。
- 修复 1 落地后，`connectToBonjourEndpoint` 里 `instanceID ?? name` 的兜底对新代码已不可达（能到达的 endpoint 必有 `instanceID`），仅为防御保留。

## 相关但未随本次修复

同一轮排查还定位了「Catalyst 条目有时变成 RuntimeViewerCatalystHelper」：helper 的 XPC server 无差别把自己登记进 daemon 的 injected-endpoint registry，主 app 非正常退出（如 Xcode 重跑杀进程）后 helper 残留，下次启动被 `reconnectInjectedXPCEngines` 当作被注入 App 重连，且直连会顶掉正常 Catalyst 引擎的 peer 连接。单独修复，另行记录。

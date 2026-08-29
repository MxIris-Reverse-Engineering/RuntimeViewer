# 2026-08-29 Catalyst 条目变成 "RuntimeViewerCatalystHelper"，正牌 "My Mac (Mac Catalyst)" 同时消失

**调查日期：** 2026-08-29
**修复落地：** 本日，分支 `fix/catalyst-helper-registry`
**Severity：** Moderate —— Catalyst runtime 仍然可用（换了个名字和图标），但菜单里凭空出现一个以 helper 进程命名的"附加进程"，正牌条目消失，且 helper 的 peer 连接被顶换过一次
**触发场景：** 正常启动即可触发（干净退出重启依然复现）；无需任何残留进程

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 本机分组里 "My Mac (Mac Catalyst)" 不见了，取而代之的是一条名为 "RuntimeViewerCatalystHelper" 的条目，图标是 Catalyst 应用的空白占位图 |
| **影响范围** | 每次 app 启动都可能触发；helper 与 app 同 bundle 发布，所有装机都在同一份代码上 |
| **根因** | helper 的 XPC server 无差别把自己登记进 daemon 的 injected-endpoint registry；主 app 同一次启动内的 `reconnectInjectedXPCEngines()` 跑在 helper 登记之后，把 helper 当成被注入的 App 重连，直连还顶掉了正牌 Catalyst 引擎的 peer 连接 |
| **Status** | **Fixed** —— XPC server 按 identifier 判定是否登记：`.macCatalyst` 不进 registry |

---

## 现象

引擎菜单本机分组：只有 "My Mac"（选中）和 "RuntimeViewerCatalystHelper"，后者带 Catalyst 空白应用图标；"My Mac (Mac Catalyst)" 整条消失。

图标与分组是指纹：条目走的是**附加进程**路径（`reconnectInjectedXPCEngines` 建的 `.remote(name: appName, identifier: pid)` 引擎，图标来自 `NSRunningApplication`，hostInfo 走默认值所以和 My Mac 同组），而不是 `.macCatalystClient`（那条路径的图标是 Mac 设备图）。

## 根因

一条链四环，全部发生在**同一次启动**里，不需要任何残留进程：

1. **helper 每次连接都登记自己**。`RuntimeXPCServerConnection.init` 在 `peer.activate()` 之后无条件调用 `announceListenerEndpoint()`，以 `appName = "RuntimeViewerCatalystHelper"` 写进 daemon 的 injected-endpoint registry。这个登记的本意是给**代码注入的目标 App** 用的——主 app 重启后可以按登记的 endpoint 直连回去——但 helper 的 XPC server 与被注入 App 的 XPC server 是同一个类，登记逻辑不区分。
2. **registry 只随进程存亡清理**。daemon 端 `InjectedEndpointRegistryService` 用 process monitor 在登记进程退出时清条目，其余照单全收、照单全出（`fetchAllInjectedEndpoints` 无任何过滤）。
3. **主 app 的重连扫描跑在 helper 登记之后**。`launchSystemRuntimeEngines` 的顺序是：连 Catalyst 引擎 → 启动 helper → `reconnectInjectedXPCEngines()`。走到第三步时，helper（第二步刚拉起的这只，不是什么孤儿）已经把自己登记进去了；扫描把它当成被注入的 App，建出 "RuntimeViewerCatalystHelper" 引擎。
4. **直连顶掉正牌连接**。重连走的是对 helper listener endpoint 的直连；helper listener 上的 `ClientReconnected` 处理器会"就地换掉 peer 连接"（单 peer 槽位），把第一步建好的 `.macCatalystClient` 引擎的连接顶死 → 引擎断线 → `terminateRuntimeEngine` 把 "My Mac (Mac Catalyst)" 从菜单移除。

### 被证伪的第一版假设

最初的诊断是「app 非正常退出、helper 残留成孤儿，下次启动被重连」。用户用活动监视器证实 **app 退出时 helper 一并退出**，且**干净退出重启依然复现**——孤儿假设不成立。回头看代码，上面这条同启动内的时序链根本不需要孤儿：helper 是当场登记、当场被扫到的。

## 修复

**helper 一开始就不该出现在「已注入 App」名册里**——名册的语义是「主 app 无法自行重启的注入目标」，而 helper 每次都由主 app 亲自拉起。落点在登记侧：

- `RuntimeXPCServerConnection` 新增判定 `shouldAnnounceListenerEndpoint(identifier:)`：`.macCatalyst` 不登记，其余（被注入 App，identifier 是目标 pid）照旧。
- `RuntimeSource.Identifier.macCatalyst` 常量从 `RuntimeViewerCatalystExtensions` 移入 `RuntimeViewerCommunication`（连接层需要拿它做判定，依赖方向决定它不能留在上层）；raw value 不变，并有测试钉死。

**为什么不需要接收侧兜底**（与幽灵设备修复的双端策略不同）：helper 与主 app 永远打在同一个 bundle 里、同版本发布，不存在「老版本 peer 永远修不上」的问题。修好登记侧后，甚至旧版主 app 配新版 helper 也自动痊愈——registry 里根本不会再有 helper 条目。跨 variant（Debug / arm64e / Release）也不会串：每个 variant 有自己的 mach service（daemon），registry 相互隔离。

## 验证

- `InjectedEndpointAnnouncementTests`（新增，RuntimeViewerCommunicationTests）：`.macCatalyst` 不登记（复现测试）、注入型 identifier 照旧登记、`.macCatalyst` raw value 钉死防止搬家改变两端会合身份。mutation-check：把判定改回无条件登记，复现测试立刻红（exit 1），恢复后绿。
- `RuntimeViewerCatalystExtensions`、`RuntimeViewerApplication` 编译通过（常量搬家的所有 `.macCatalyst` 使用点均已确认 import `RuntimeViewerCommunication`；`RuntimeViewerHelperClient` 里的 `.macCatalyst` 是其自有 platform 枚举的 case，无关）。

## 横向排查

- 其余会走 `RuntimeXPCServerConnection` 的只有被注入 App 的 payload——它们正是 registry 的服务对象，登记行为保留。
- `reconnectInjectedSocketEngines`（沙盒注入的 socket 记录）与 helper 无涉，不受影响。
- 「直连会顶掉现役 peer」这个性质本身仍在（`ClientReconnected` 换槽是注入重连所依赖的行为）；修复后 registry 里不再会出现「已有现役连接的进程」，该性质不再有误伤路径。

## 关联

同一轮排查的另一个问题（Bonjour 幽灵设备）见
[2026-08-29-bonjour-ghost-device-self-discovery.md](2026-08-29-bonjour-ghost-device-self-discovery.md)。

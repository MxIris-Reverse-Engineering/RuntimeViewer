# 2026-09-09 切到 Mac Catalyst 引擎永远 loading：helper 与 App 连的不是同一个 helper daemon

**调查日期：** 2026-09-09
**修复落地：** 本日，分支 `next`
**Severity：** High —— Debug-arm64e 下 Catalyst 引擎必现不可用；任何变体在 daemon 被重装的那次启动都会中招；两处都表现为菜单里有条目、点进去转圈到死，没有任何错误提示
**触发场景：** (1) Debug-arm64e 的 App 嵌了 Release 构建的 helper（9 月 1 日 `ArchiveScript.sh` 留在 staged 路径的那份）；(2) 启动时版本检查重装了 helper daemon；(3) daemon 缺失时启动，之后从 Settings 装好

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 切换到 "My Mac (Mac Catalyst)"，sidebar 一直 loading；重启 App 有时恢复 |
| **影响范围** | Debug-arm64e 变体：自 6 月 helper daemon 按变体分名以来必现。Release / Debug：升级后首次启动（daemon 版本不匹配触发重装）偶发 |
| **根因** | helper 向它自己解析出的 daemon 查 App 的 endpoint，而那不是 App 登记 endpoint 的那个 daemon（变体不同，或 daemon 在登记之后被换掉）；查不到就静默失败，App 侧引擎又是乐观报 `.connected`、没有握手确认 |
| **Status** | **Fixed** —— helper 翻变体标志并在失败时退出；App 等 helper 应答后才把引擎放进菜单，超时报事件与通知；daemon 装好后自动重拉；`RunScript.sh` 暂存自己编的 helper，Embed 前校验变体一致 |

---

## 现象

菜单里 "My Mac (Mac Catalyst)" 正常出现，切过去后 sidebar 的转圈永远不停；没有通知、没有 alert、日志里（默认落盘级别）只有 helper 进程一行 error。

loading 的来源：`SidebarRootViewModel` 把「第一批非空 `imageNodes` 完成索引」作为关闭 `commonLoading` 的信号，而 client 引擎的 `imageNodes` 只会由 helper 那端推过来。helper 永远不推，转圈就永远不停。

## 根因

三个独立的缺陷叠在一起，任何一个都足以让握手完不成，而第三个让前两个不可见。

### 1. helper 与 App 的 helper daemon 名字不同

App 与 helper 的 XPC 握手经由 helper daemon 中转：App 先把自己的 endpoint 登记进 daemon（`RegisterEndpointRequest`），再请求 daemon 拉起 helper；helper 起来后向 daemon 取 App 的 endpoint（`FetchEndpointRequest`）并直连回去。**两边必须找同一个 daemon**，而 daemon 名字（`RuntimeViewerMachServiceName`）是按构建变体编进每个二进制的：Release 是常量 `com.mxiris.runtimeviewer.service`；Debug 下由全局 `runtimeViewerIsARM64EVariant` 在 `dev.mxiris…` 与 `dev.arm64e.mxiris…` 之间选。

今天 11:24 那次启动的日志（只保留 error / default 级别）：

```
11:24:37.467  launchd        spawned RuntimeViewer-Debug-arm64e[95690]
11:24:38.548  App[95690]     activating connection … name=dev.arm64e.mxiris.runtimeviewer.service
11:24:38.934  runningboardd  Launch request for RuntimeViewerCatalystHelper
11:24:39.112  Helper[95695]  activating connection … name=com.mxiris.runtimeviewer.service
11:24:39.206  Helper[95695]  Connection state -> disconnected with error: … (MainService.MainService.Error error 1.)
```

`MainService.Error` 的 case 1 是 `notFound`：helper 去 Release daemon（pid 342）查 endpoint，App 登记在 arm64e daemon（pid 95060）里。两边名字不同又有两层原因：

- **嵌进 App 的 helper 是 Release 构建。** `Embed Catalyst Helpers` 拷的是 `RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper.app` 这个 staged 路径，它由 `ArchiveScript.sh` 在 9 月 1 日以 Release 导出；`RunScript.sh` 每次都编一份 Debug-arm64e 的 helper，但从不 stage 它。运行中的 App 里嵌的 plugin 与 staged 路径下的 md5 相同（`067748dd…`），`strings` 只含 `com.mxiris.runtimeviewer.service`；`Build/Products/Debug-arm64e-maccatalyst/` 下刚编出来的那份含两个 `dev.` 名字，从没被用上。
- **就算 helper 是 Debug-arm64e 构建也不对。** 6 月把 daemon 名字按变体区分的提交（`597cddaa`）只让 App、daemon、注入 server 三个入口在 `#if RUNTIMEVIEWER_ARM64E` 下翻标志，Catalyst helper 这个第四个可执行入口漏了：它会算出 `dev.mxiris…`，而本机根本没装这个 daemon。

### 2. daemon 重装清空登记表

daemon 里的 endpoint 登记表（`MainService.endpointByInfo`）只在内存里。启动顺序是：引擎 manager 向旧 daemon 登记并请求拉起 helper → `HelperServiceVersionChecker` 发现版本不匹配、重装 daemon（旧进程被换掉，登记表清空）→ helper 起来后向新 daemon 查 endpoint → `notFound`。这一条与变体无关，Release 也会中，且只在升级后的第一次启动出现，下一次启动 daemon 已是当前版本 —— 这正是「有时候卡、重启就好」。

此外装完 daemon 后没有任何东西会重拉 Catalyst：系统引擎只在 `RuntimeEngineManager.init` 里启动一次，Settings 的 install / reinstall 只动 `HelperServiceManager`，版本检查装完只弹一个「请重启」。daemon 缺失时启动（`connectionInvalid`，引擎根本没建）→ 之后装好 → 菜单里也不会出现 Catalyst。

### 3. 两端都不报错

- helper 侧 `AppKitPluginImpl.launch()` 把 `connect()` 的错误吞在 `Task {}` 里，进程留着但永远不会连回来。而 daemon 用 `createsNewApplicationInstance = false` 打开 helper，下一次请求拿回的还是这个不会再握手的实例。
- App 侧 `RuntimeEngine.connect()` 对 client 角色在自己的 listener 登记完就报 `.connected`，不等 helper；注入流程有 `confirmAttachedRuntimeEngineConnected` 兜底，Catalyst 没有。`catalystHelperUnavailable` 事件只在「拉起请求失败」时发，握手失败不发，且通知服务对它也不提示。

### 被证伪的第一版假设

一开始怀疑是「旧 helper 残留 + `createsNewApplicationInstance = false` 拿回旧实例」的时序竞争。日志否定了它：helper 是这次启动新拉起的（pid 紧挨着 App），失败原因是 `notFound` 而非拿错实例。残留实例的问题确实存在（见根因 3），但不是这次的触发路径。

## 修复

1. **helper 身份**（`AppKitPluginImpl`）：`init` 里照其余三个入口的写法 `#if RUNTIMEVIEWER_ARM64E` 翻 `runtimeViewerIsARM64EVariant`。项目级 Debug-arm64e 配置已经把该编译条件给到 plugin target，缺的只是这行代码。
2. **helper 失败即退出**（同文件）：`connect()` 抛错，或引擎状态进入 `.disconnected`，都 `exit`。helper 不登记进注入名册（`shouldAnnounceListenerEndpoint` 对 `.macCatalyst` 返回 false），所以不会有任何东西重连它，断线即无用；退出还让下一次 `OpenApplicationRequest` 拿到新实例。
3. **App 侧握手确认**（`RuntimeEngineManager.launchMacCatalystRuntimeEngine`）：拉起 helper 后用已有的 `pollUntilPeerAnswers` 等最多 15 s，应答后才 `append` 进 `systemRuntimeEngines`；超时 `stop()` 引擎并抛 `MacCatalystHelperError.handshakeTimedOut`，走既有的 `catalystHelperUnavailable` 事件。`RuntimeConnectionNotificationService` 对该事件发通知（受 `notifications.isEnabled` 控制）。
4. **拉起前先清旧实例**（`RuntimeHelperClient.launchMacCatalystHelper`）：按 bundle URL 找出同一份 helper 的运行实例，`terminate()` 并等它退出（1.5 s 后 `forceTerminate()`，上限 3 s），再发 `OpenApplicationRequest`。按 URL 不按 bundle identifier：三个变体的 helper 同名，不能互相误杀。
5. **daemon 可用即重拉**：`HelperServiceManager` 新增 `daemonAvailabilityPublisher`，在 install 成功、reinstall 成功（含启动时版本检查那条路径）、以及 refresh 发现状态变成 `.enabled` 时发出；`RuntimeEngineManager` 订阅后调用新增的 `relaunchMacCatalystRuntimeEngine()`：取消并等待在途的拉起、拆掉现役引擎、结束 helper、重新走第 3 步。`pollUntilPeerAnswers` 改为响应任务取消，重拉不必等完上一次的超时。
6. **构建侧**：`RunScript.sh` 编完 helper 后 `rm -rf` + `ditto` 到 staged 路径（与模拟器载荷对称，缺产物即 fail）；helper 的 `Info.plist` 新增 `RuntimeViewerServiceName = $(RUNTIME_VIEWER_SERVICE_NAME)`（helper target 三个配置各自定义该 setting）；App target 在 `Embed Catalyst Helpers` 之前新增 **Verify Catalyst Helper Variant** 脚本阶段，staged helper 的该键与 App 的 `RUNTIME_VIEWER_SERVICE_NAME` 不一致即构建失败并说明两边的值；`RUNTIME_VIEWER_ALLOW_MISMATCHED_CATALYST_HELPER=YES` 降级为 warning。

**为什么不改 daemon 端**（`swift-helper-service` 的 `ApplicationsService` 用 `createsNewApplicationInstance = false`）：那是外部库，且 App 侧清旧实例后语义已经等价；登记表落盘也不解决变体错配。留待该库自己演进。

## 验证

- `RuntimeEngineManagerMacCatalystLaunchTests`（新增，RuntimeViewerEngineManagementTests），通过 `MacCatalystLaunching` seam 用替身引擎驱动，不碰 daemon：
  - 复现测试：helper 永不应答 → `systemRuntimeEngines` 里没有 Catalyst 引擎，收到一条 `catalystHelperUnavailable(handshakeTimedOut)`。修复前的写法（先 append 再等）在这条上必红。
  - 应答 → 恰好一个引擎，且在应答之后才出现。
  - 重拉替换现役引擎、helper 再拉一次、旧引擎被 `stop()`。
  - 在途拉起（30 s 超时）被重拉取消，整个过程 < 5 s，不产生失败事件。
  - `launchesSystemEngines == false` 的配置忽略重拉。
- 构建：`RuntimeViewerCatalystHelper`（Debug-arm64e）与主 App 在 agent 隔离的 DerivedData 下构建通过；staged helper 的 `Info.plist` 读出 `dev.arm64e.mxiris.runtimeviewer.service`，校验阶段放行。
- 红绿命令（改前 0 行 = 红）：
  ```bash
  /usr/libexec/PlistBuddy -c 'Print :RuntimeViewerServiceName' \
    RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper.app/Contents/Info.plist
  ```
- 真机验证（需用户执行）：`./RunScript.sh` 后切到 Catalyst 引擎应正常加载；`log stream --predicate 'process == "RuntimeViewerCatalystHelper"'` 里不应再出现 `MainService.Error`。

## 横向排查

- 同样「乐观 `.connected` + 无握手确认」的还有注入流程，它已有 `confirmAttachedRuntimeEngineConnected`（2026-07-14 那篇）；Bonjour client 走 heartbeat。系统引擎里只有 Catalyst 缺这一层，本次补上。
- 同样「daemon 重装清空内存状态」影响的还有注入 endpoint 名册（`InjectedEndpointRegistryService`），但被注入的 server 会在 host 重启后由名册反向重连，重装 daemon 时 server 进程仍在、名册却空了，host 下次启动找不到它们。这是已知的另一处，不在本次范围。
- 翻 `runtimeViewerIsARM64EVariant` 的入口现在是四个：App、daemon、注入 server、Catalyst helper。`RuntimeViewerCommandLine` 的独立 host 用 `swift build` 编，`#if DEBUG` 下算 `dev.mxiris…`，与 Debug-arm64e App 也不同 —— 它有自己的 App 包定位与 helper 拉起路径，遇到同样的错配会走本次加的超时与事件，不再无限等待，但要与 arm64e 变体协同仍需单独处理。

## 关联

- [2026-08-29 Catalyst 条目变成 RuntimeViewerCatalystHelper](2026-08-29-catalyst-helper-injected-registry-hijack.md)：上一次 Catalyst 握手相关的排查，解释了 helper 为何不进注入名册。
- [2026-07-14 注入连接被拒后 engine 残留、无 UI 提示](2026-07-14-attached-engine-handshake-confirmation.md)：本次复用的握手确认机制。
- 提案 [0015](../Evolutions/0015-build-embedded-products-in-app-phase.md)：staged 路径的来历与自动构建为何撤回。

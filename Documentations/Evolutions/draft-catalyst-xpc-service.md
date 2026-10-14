# Draft - Mac Catalyst 运行时：App 改用内嵌 XPC service，CLI 保留 helper App

- **状态**: In Progress
- **创建日期**: 2026-10-14
- **最后更新**: 2026-10-14

## 摘要

App 里的「My Mac (Mac Catalyst)」今天经特权 helper daemon 拉起 `RuntimeViewerCatalystHelper.app`，再等它连回来（最多 15 秒的握手轮询）。改为 App 内嵌一个 Mac Catalyst 版 XPC service：launchd 按 App 实例查找、按需拉起、崩溃后连接自动重连，Debug / Debug-arm64e / Release 三个变体也不会再连错 daemon。`runtime-viewer-cli` 的独立 host 找不到 App 包里的 XPC service（只有包含它的那个 App 能找到），所以继续走 daemon + helper App。两个外壳只负责「成为 Catalyst 进程、加载 plugin」，写一次就不再动；核心逻辑全在 `RuntimeViewerCatalystHelperPlugin`。可行性已由 [`Experiments/CatalystXPCServiceProbe`](../../Experiments/CatalystXPCServiceProbe/README.md) 验证。

## 方案

1. **Plugin 承载两种模式。** `AppKitPlugin` 协议加 `runService()`。`launch()`（helper App 模式，CLI 用）逻辑不变，藏窗口、禁 Dock 图标的 hack 从 `init()` 挪进 `launch()`，service 进程不碰 `NSApplication`。`runService()`（XPC service 模式，App 用）：`RuntimeInjection.install()` → `dlopen` 一次 UIKit（service 刚启动时没有 UIKitCore，不补的话镜像列表比 helper App 少）→ 进程内 `.local` 引擎交给 `RuntimeLocalRuntimeServiceHost`，挂在 `RuntimeXPCServiceListenerConnection.embeddedService()` 上 → `activate()`，即 `xpc_main`，不返回。服务端整套复用本地引擎 service 的现成实现。
2. **两个外壳。** helper App 不改逻辑。新增 Catalyst `xpc-service` target `RuntimeViewerCatalystService`：`SDKROOT = macosx` + `SDK_VARIANT = iosmac`、`SKIP_INSTALL = YES`，其余设置照抄 helper；由 App 的「Embed XPC Services」嵌入 `Contents/XPCServices/`。`main.swift` 只做「加载 plugin → `runService()`」。两者共用 `AppKitBridge.swift` 与 `AppKitPlugin.swift`。
3. **Plugin 只放一份。** 从 helper 的 `PlugIns` 挪到 App 的 `Contents/PlugIns/`，`AppKitBridge` 改为从外层 App 的 `PlugIns` 加载（两个外壳都在 App 的 `Contents/` 下两层）。Plugin 加一条 rpath `@loader_path/../../../../Frameworks`，从 App 的 `Frameworks` 解析 `libswiftCompatibilitySpan.dylib`：macOS 15 系统里没有这个库，而 App 带的那份同时含 macOS 与 Mac Catalyst 两个平台。这样 Release 包不会多出一份约 44 MB 的 plugin。
4. **传输接缝。** `RuntimeCommunicator` 的 `.remote` + `.client` 分支接受 `.xpcService(target)` 凭证，建 `RuntimeXPCServiceClientConnection`。Catalyst 引擎身份仍是 `.macCatalystClient`，图标、书签 scope、CLI 的 `--source catalyst`、通知文案都不变。`RuntimeXPCServiceConnectionError` 的文案从 "local runtime" 改成中性说法，因为现在两个 service 共用它。
5. **谁走哪条路由进程自己的 bundle 决定**，与 `LocalRuntimeService` 同一手法：App 的 `Info.plist` 键 `RuntimeViewerCatalystServiceBundleIdentifier`（xcconfig 按三个配置各给一个 ID），`RuntimeViewerCatalystExtensions` 新增 `MacCatalystRuntimeService`（键名与凭证）。App 有这个键，走 XPC service；CLI 独立 host 没有，走 daemon + helper App。没有设置项。
6. **管理器。** `RuntimeEngineManager.MacCatalystLaunching` 的 helper 部分改为可选（`helperApplication: HelperApplication?`），`live` 按上一条选择。走 XPC service 时：不拉 helper、不做握手轮询（连接自带的 `hello` 就是拉起）；不观察断线，与 `.local` 相同——service 退出后连接自动重连、文档退回镜像列表，引擎不会从菜单里消失；daemon 重装不再触发 Catalyst 引擎重启（不订阅 daemon 可用性）。连上时补发一次 `engineConnected`：今天的观察在订阅时会发出这一次，「Connected」通知因此照旧。

没有询问就采用的假设：

- 不做「XPC service 起不来就退回 helper App」：那会让 App 继续依赖 daemon，也会掩盖签名或构建问题。
- service 的 entitlements 与 helper 一致（空，库校验开启）。Catalyst 来源能否加载第三方 framework 与今天相同，`disable-library-validation` 另议。
- Catalyst service 重启后不发通知（`.local` 有「Local Runtime Restarted」），留作后续。
- 实现在 `feature/catalyst-xpc-service`（`.worktrees/RuntimeViewer-CatalystXPCService`），完成后合回 `next`。

验证（2026-10-14 已做）：

- **Core**：`RuntimeLocalRuntimeServiceHostTests` 新增「`.remote` client 引擎带 service 凭证连上 host」，撤掉通信层改动时 0.5 秒内以 `connectionInvalid` 失败，恢复后通过；该套件 5 个、XPC service 连接的 3 个套件 12 个测试全过。
- **管理器**：`RuntimeViewerEngineManagementTests` 50 个全过，新增 3 个：走 service 时引擎立即出现、不做探测；走 service 时断线后引擎仍在；走 helper App 时断线即移除（对照）。
- **CLI**：`--source catalyst` 找不到时的提示改成两种 host 都成立的说法；`SourceCatalogTests`、`SourceCommandTests` 等 3 个套件 22 个测试全过。
- **App**：`RuntimeViewer macOS` 的 Debug-arm64e 冷编与改完最后几处后的增量编译都通过。产物检查：service 平台 `MACCATALYST`（minos 18.0），`CFBundleIdentifier` 与 App `Info.plist` 的 `RuntimeViewerCatalystServiceBundleIdentifier` 同为 `dev.JH.RuntimeViewerCatalystService.arm64e`，`XPC!` / `ServiceType = Application`；plugin 只在 App 的 `PlugIns`（helper 里已没有），rpath 依次是 `/usr/lib/swift` 与 `@loader_path/../../../../Frameworks`，后者指向的 `libswiftCompatibilitySpan.dylib` 存在、含 macOS 与 Mac Catalyst 两个平台；service、plugin、helper 同一 team 签名、开着 hardened runtime，`codesign --verify --deep --strict` 通过。

还没做、需要用户的：在真实 App 里打开「My Mac (Mac Catalyst)」并确认镜像列表正常、进程里出现 `RuntimeViewerCatalystService`；`kill` 掉 service 看引擎留在菜单、文档退回镜像列表、再次请求时自动重连；Release 归档与 Developer ID 签名下 plugin 能否载入（库校验）；macOS 15 实机。

文档同批更新 `AGENTS.md`、`CommunicationAndEngineArchitecture.md`、术语表、CLI 指南与 agent 插件 skill（`catalyst` 来源在 App 运行时不再需要 daemon，插件升到 1.0.2），实验 README 标注已落地，`RunScript.sh` / `ArchiveScript.sh` 的注释改为三个非 macOS 产物。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-14 | Created as Draft | 用户原话：「把catalyst xpc service那个分支合并过来，App侧用XPCService，CLI侧用HelperApp，这两个target写一次就行了，不用怎么改，核心逻辑在Plugin里面」 |
| 2026-10-14 | 实验分支 `feature/catalyst-xpc-service-probe` 合进 `next`（`d4b4ed72`） | 用户要求 |
| 2026-10-14 | CLI 独立 host 保留 helper App | 用户决定。XPC service 只能被包含它的 App 找到，实验 README 记为硬冲突；两条路共用一个 plugin，外壳的维护成本接近零 |
| 2026-10-14 | Plugin 只留一份，放 App 的 `PlugIns` | 两个外壳各嵌一份会让 Release 包多约 44 MB；放在 App 里还顺带让 plugin 能从 App 的 `Frameworks` 找到 Span 垫片 |
| 2026-10-14 | Accepted → In Progress | 用户：「开工」。实现在 `feature/catalyst-xpc-service` |
| 2026-10-14 | 服务端原样复用 `RuntimeLocalRuntimeServiceHost`，不加 `label` 参数 | 它只影响日志行前缀，而日志本来就按进程区分；少动一处 Core |
| 2026-10-14 | 藏窗口、禁 Dock 图标的 hack 从 plugin 的 `init()` 挪进 `launch()`，顺手把 `m1` / `m2` 等缩写改成完整名字 | service 进程不碰 `NSApplication`；`init()` 两种模式都会跑 |
| 2026-10-14 | 走 service 的 Catalyst 引擎连上时补发一次 `engineConnected` | 不观察之后，今天订阅时那一次 `.connected` 就没了；补发让「Connected」通知与现在一致，提案承诺通知文案不变 |
| 2026-10-14 | 记下：Catalyst 运行时从此受 App Nap 降速影响，不另做处理 | XPC service 是 adaptive 任务，App 进 App Nap 后它只跑效率核（`ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`）；helper App 是独立应用，没有这个问题。现有的 `BackgroundWorkProcessActivity` 按文档状态持有 activity，不分引擎，Catalyst 文档的索引与语料构建同样被覆盖 |
| 2026-10-14 | 改 CLI 里 `--source catalyst` 找不到时的提示 | 原文固定说「需要 helper daemon」，App 充当 host 时已经不对；只改文案、不加分支，两种 host 都成立（App 在跑就重开 App，独立 host 照旧装 daemon） |
| 2026-10-14 | Core 测试先红后绿 | 通信层改动撤掉时，新测试在 0.5 秒内以 `connectionInvalid` 失败（旧代码把 `.xpcService` 凭证忽略，走了 daemon）；恢复后通过 |

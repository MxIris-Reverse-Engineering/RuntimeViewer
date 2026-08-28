# PR #106 审查裁决 — 2026-08-24

审查对象：PR #106（`feature/inject-ios-simulator-process` → `next`，Evolution 0013 模拟器注入），
head `69d8131b`，27 个文件 / +2481 −97。

两轮产出合并：`/code-review xhigh` 报了 15 条，另一个会话对每条做了对抗性复核（复现、证伪、
补漏）。其中一条（`installServerFrameworkIfNeeded` 不调用 `isInstalledServerFramework`）经用户
确认为**有意设计**，不计入。余下 14 条逐条走完四问，ID 为 `PR106.<N>`。

**基线是 `next`，不是 `main`** —— 本 PR 的对比基线是它的合并目标。

## 已修（同批次）

| ID | 严重度 | 摘要 | 修复 | 复现测试 |
|---|---|---|---|---|
| PR106.2 | Minor | `platformOfFatFile` 用 `Int(rawOffset.bigEndian)` 转换 64 位 slice offset，高位置 1 时是 trapping 转换，整个 app SIGTRAP。第二处在 `loadUnalignedIfWithinBounds` 的 `byteOffset + size`，对 `(Int.max-4, Int.max]` 的 offset 自身溢出 | `Int(exactly:)` + `continue`；边界检查改写成减法 | `hostileFat64OffsetDoesNotTrap`、`fat64OffsetAtIntMaxDoesNotTrap`，新增 `MachOFixture.fat64` |
| PR106.3 | Minor | `injectedBonjourEngine(forProcessIdentifier:)` 只比对端点键最后一个 dash 分量，丢弃设备半边。局域网上任何对端只要广播的进程 pid 相同即满足等待，注入失败时静默报成功 | 新增 `ProcessEnvironmentProbe`（`KERN_PROCARGS2`）读目标 `SIMULATOR_UDID`，改为整键相等；读不到设备身份时抛 `simulatorDeviceUnidentifiable` 而非放行 | `InjectedBonjourEngineMatchingTests`（5 条，含异设备同 pid、pid 后缀、旧对端服务名）、`ProcessEnvironmentProbeTests`（5 条） |
| PR106.4 | Minor | `AttachToProcessViewModel` 取 dylib URL 失败时 `return`，无报错、无日志、sheet 不关；同一 `do` 块其余失败全部走 throw | 改抛已存在的 `serverFrameworkNotFound` | — |
| PR106.5 | Minor | `LC_BUILD_VERSION` 平台常量 11 被映射成 `.visionOSSimulator`。`<mach-o/loader.h>` 里 11 是 `PLATFORM_VISIONOS`（真机）、12 才是模拟器；测试第 42 行把错误断言锁死 | 改成 12，测试断言一并改，并补 11 → `.unsupported(11)` | `loadCommandValuesMap` |
| PR106.6 | Minor | `realSimulatorBinaryIsDetected` 在 fixture 缺失时 `return`，报告为**通过**而非跳过；且搜索路径只覆盖 `Volumes/` 布局，漏掉 legacy `Profiles/Runtimes` | 改用 `.enabled(if:)` trait 真跳过 + `#require`；搜索补上 legacy 布局 | — |
| PR106.7 | **Major** | 断开清理只按 `hostInfo.hostID` 匹配 `engineID` 前缀。身份改造后直连路由是**设备级**，而对端自己的 engine 仍带**实例级**（`RuntimeEngine.init` 默认 `hostID = localInstanceID`，本 PR 未改），两者不再相等 —— A→B→C 三台 Mac 且 A 支持 engine sharing 时，A 掉线后它的转发镜像清不掉；`stillReachable` 守卫同时被打穿，屏幕上镜像还在却照发「已断开」通知 | registry 新增 `clearAllForDisconnectedPeer(hostID:originInstanceID:)`，补上按 `originChain.first` 的第三条命名空间；manager 传入两个身份 | `clearForDisconnectedPeerCoversDeviceAndInstanceNamespaces`、`clearForDisconnectedPeerStillCoversDeviceNamespace`；摘掉第三条清理后确认变红 |
| PR106.8 | Minor | `awaitInjectedBonjourEngine` 轮询里 `try? await Task.sleep` 吞掉取消，取消后退化为主线程忙等至 30s 超时。当前不可达（唯一调用方的 Task 句柄无人持有），但函数是 `public` | 改 `try await` 让取消传播 | — |
| PR106.9 | Minor | `isRunningInsideInjectedProcess` 的注释称「今天唯一的痕迹是 `localInstanceID`」，不属实：`localDeviceID` 可达 `DeviceIdentifier` 的 keychain 回退 | 改注释，写明第二条痕迹被哪两道闸挡着（模拟器上 `SIMULATOR_UDID` 优先、keychain 前还有 MobileGestalt） | — |
| PR106.10 | **Major** | `localServiceName` 改成 `{deviceID}-{pid}`。旧宿主把 `endpoint.name` 直接当显示名**和持久化键**用 —— 它会显示原始 UUID，且 `NSOutlineView` 的 `autosaveName` / `identifier` 按对端每次启动换一套，在 `UserDefaults` 里永久累积。iOS 端有外部用户，混版是常态 | 服务名改为 `「设备名 (进程名)」`，去掉 pid；进程级唯一性完全交给 TXT 键（新宿主本来就只认 TXT） | `serviceNameComposition`、`localServiceNameCarriesNoProcessIdentifier`、`localServiceNameIsStable`、`twoProcessesStayDistinctWithoutNameUniqueness` |
| PR106.11 | Minor | `guard count > 0, count < 64` 把「切片过多」和「读不出来」压成同一个 `nil`，被调用方翻成 `targetPlatformUnreadable` 拒绝 attach —— 一个由守卫而非文件造成的拒绝 | 改为 `min(count, maximumInspectedSliceCount)` 钳制迭代，上限命名 | `sliceCountPastCapIsClampedRatherThanRefused` |
| PR106.12 | **Major** | `RuntimeViewerServer.processName` 与 `RuntimeNetworkBonjour.localProcessName` 是两份重复的三级回退，且不一致：私有那份没有 `!isEmpty` 检查。注入进程里 `Bundle.main` 指的是**宿主 app** 的 bundle，所以目标 app 只要声明了空串 `CFBundleDisplayName`，XPC / localSocket 路径就把源命名为空串 | 删私有副本，改用共享实现；回退链抽成可测的 `processName(displayName:bundleName:fallback:)` | `ProcessNameFallbackTests`（5 条） |

**与 SIMID.4 的关系（PR106.7）**：不冲突，也不重开它。SIMID.4 担心的是**设备级**前缀会「清过了头」
——一台设备上某个进程掉线，把该设备下全部镜像一锅端。本次补的第三条清理按 **instanceID** 前缀匹配，
而 instanceID 是每安装一个，不具备设备级语义，正是 `next` 上的既有行为。SIMID.4 的三条复核判据
（iOS payload 开始返回非空 descriptor / 出现同设备多 Bonjour server 且其一支持 engine sharing /
`RuntimeEngine.init` 默认 `hostID` 改成设备级）**均未触发**，该裁决继续有效。

复现目标（PR106.12）：本机 `/Applications` 下 `DrString.app`、`Eudic.app`、`RapidAPI.app` 三个已安装
app 的 `CFBundleDisplayName` 均存在且为空串。

## 误报（留档，下次不必重走四问）

### PR106.13 — fat 条目读失败时 `return nil` 应改 `continue`

**报告的说法**：`platformOfFatFile` 在某个 `fat_arch` 条目越界时 `return nil`，放弃了后面本可读的
条目，与函数注释「every slice is inspected」矛盾。两轮审查都判它「成立但触发面窄」。

**四问**：

1. **能复现吗** —— **不能，是误报。** fat 条目是**连续定长**的：`entryOffset = fat_header.size +
   index * entrySize`，随 index 单调递增；`loadUnalignedIfWithinBounds` 的失败条件
   `byteOffset + size > count` 因而也单调。**一旦某个条目越界，其后所有条目必然越界**，不存在
   「`continue` 能够到、`return nil` 跳过了」的输入。写探针枚举了 buffer 长度 8 / 28 / 48 / 68
   四种情况，「越界之后还有可读条目」恒为 false。两种写法**没有任何可观测差异**。
2. **`next` 上是否也有** —— 不适用（整个文件是本 PR 新增）。
3. **值不值得修** —— 不值。行为等价，改动只会让人以为修掉了什么。
4. **以前修过吗** —— 新代码，无前史。

**附带一点是真的，但不是 bug**：`platformOfThinFile` 对未知平台返回 `.unsupported(value)`，调用方
`if let` 把它当「识别成功」而短路，与注释「first **recognized** platform wins」不符。但 fat 文件的
各 slice 是同一次构建的不同架构，平台不会互相矛盾（`.xcframework` 存在的理由正是 fat 无法表达
跨平台）。所以这是**注释措辞与实现不符**，不是行为缺陷；真要改应该改注释。本轮未改。

## 不修（留档）

### PR106.14 — UDID 在 mDNS 与统一日志中明文出现

**问题**：`localDeviceID`（iOS 上是 MobileGestalt UDID）作为 TXT `rv-device-id` 广播，且约 40 处
`.public` 日志会打印由它组成的字符串。绝大多数是**文本没改、值变了** —— `RuntimeEngineManager.swift:222`
把 `let name` 从电脑名换成 `localServiceName`，下游所有既有日志随之改变内容。本 PR 在 iOS
AppDelegate 新加的那个 `.private` 是无效的：同一个值紧接着流进五个 `.public` 位置。

**四问**：

1. **能复现吗** —— 能。局域网上任何设备都能在 browse 结果里看到 TXT 的 `rv-device-id`；
   `log show` 能读到未脱敏的字符串。
2. **`next` 上是否也有** —— 部分。`next` 上不广播 deviceID（服务名是设备名），所以广播那半是本 PR
   引入的；日志那半在 `1f3a387d`（2026-03-05）里曾被从 `.public` 改成 `.private`，但那次 commit 的
   主题是搬 target，message 只字未提，**不能断定是一次有意识的隐私决策**。
3. **值不值得修** —— 值得，但不在本轮。它需要的是一条**贯穿的隐私约定**而不是补丁：约 40 处
   要梳理，且广播那半的替代方案（固定盐 hash）会造成跨版本认不出同一台设备，必须和兼容方案
   捆绑设计。用户裁决：两半都先记账，单独立提案。
4. **以前修过吗** —— 见第 2 条。

**注意（实现时的坑）**：加盐 hash **必须用固定盐**（编译期常量，全体进程一致）。
per-installation 的盐每个进程不同，会把一台模拟器重新拆成「每个注入进程一个 Section」——
正是 SIMID.1–3 那组改造要消除的症状。

**复核判据**：`localServiceName` 已经不再包含 deviceID（见 PR106.10），所以现在只剩 TXT 与日志
两个出口，范围比记账时更小。

## 延后到单独 PR

### PR106.1 — Bonjour 书签的键含 pid，对端每次启动即全部失效

**问题**：书签存在 `[RuntimeSource: …]` 两张表里，而 `RuntimeSource` 对 `.bonjour` 的
`==` / `hash` 只看 `Identifier`。本 PR 把客户端 `Identifier` 从对端服务名改成
`{deviceID}-{pid}`，pid 每次对端启动都变 → 上次存的书签再也读不到，且字典按对端每次启动
累积一条死记录，永不回收（全仓库没有任何裁剪逻辑）。

读写点共 **4 处**：`SidebarRootBookmarkViewModel`、`SidebarRuntimeObjectBookmarkViewModel`、
`SidebarRootDirectoryViewModel`、`SidebarRuntimeObjectListViewModel:442`。最后一处除了拿
`runtimeSource` 当键，还把它存进 `RuntimeObjectBookmark.source` **字段本身** ——
`RuntimeImageBookmark` / `RuntimeObjectBookmark` 两个结构体都有这个字段（`RuntimeBookmark.swift:7/14`），
所以只改键不改值会留下自带过期 source 的书签。

**四问**：

1. **能复现吗** —— 能，且是必然发生。
2. **`next` 上是否也有** —— 没有。基线上 identifier 是对端广播的设备名，改名才会丢，不会每次启动都丢。
3. **值不值得修** —— 值得，Major。
4. **以前修过吗** —— 修过，方向相反。`917002cc`（2026-03-04）的 commit body 原文：
   *"use **stable** DeviceIdentifier for Bonjour endpoint identity, custom Equatable/Hashable for
   RuntimeSource (**name-independent matching**)"* —— 当时特意把身份做成稳定且与显示名无关，
   正是为了让持久化的键活过重启。本 PR 把 pid 塞回键里，撤销了那次修复的目的。

**用户裁决：单独开 PR 修，方案取「换掉存储键类型」** —— 新建一个 `RuntimeBookmarkScope` 作字典键，
落盘格式变更 + 迁移。理由是它能顺带解决下面这个既存缺陷，而那不属于本 PR 的范围。

**同批要解决的既存缺陷（先于本 PR 存在）**：`@FileStorage`（来自 `RxSwiftPlus` 的 `RxDefaultsPlus`）
用裸 `JSONEncoder` 把 `[RuntimeSource: X]` 落成键值交替的 JSON 数组，**键里编码了 `name`**，
而 `Hashable` / `Equatable` **忽略 `name`**。落盘里两个只有 name 不同的键，解码时 `==` 且 hash 相同，
`Dictionary` 的无键容器解码是裸 `self[key] = value`、不做重复检测 → **后者静默覆盖前者**。
即：对端改个显示名就可能在加载时静默销毁书签，无任何诊断。另外解码失败被完全吞掉
（`catch { return defaultValue }`），文件损坏时全部书签静默清空。
磁盘实证：`~/Library/Application Support/AppStorage/imageBookmarksByRuntimeSource.json` 顶层是
长度 4 的 JSON 数组，键对象含 `"name":"My Mac (Mac Catalyst)"`。

## 顺带发现（不属于本 PR，建议单独跟进）

### PR106.15 — `RuntimeViewerCore` 有 4 条稳定失败的既存测试

- `RuntimeBackgroundIndexingManagerTests.cancelBatchStopsPendingItemsAndEmitsCancelledEvent`
  （批次在 cancel 落地前就 finished）
- `RuntimeMessageChannelTests` / `sendRequest with non-nil timeout throws requestTimeout`
  （elapsed 2.33s，断言 < 1.0）
- `ConnectionTransportRegressionTests` / `LocalSocket: fire-and-forget pushes are handled in send order`
  （`.notConnected`）
- `RuntimeLocalSocketConnectionTests` / `Fire-and-forget message with no response`

**不是本 PR 引入**：把本轮改动全部还原到 `69d8131b` 后重跑，同样这 4 条一模一样地失败
（`404 tests / 4 issues`）。稳定复现，不是负载相关的不稳定测试。

### PR106.16 — 发布流程缺一道 payload gate

pbxproj 新增的 "Embed iOS Simulator Payload" 构建阶段在 payload 缺失时只
`echo "warning: …"` 然后 `exit 0`；`ArchiveScript.sh:344` 在 payload 构建失败时同样只 log warning
后继续。**一次 `ArchiveScript.sh --upload-to-github` 可以在模拟器 payload 完全缺席的情况下发布成功**，
发布方在发布前不会被拦（运行时用户会正常收到 `serverFrameworkNotFound`，那条路径本身是对的）。
建议在 `--upload-to-github` 路径上把这个 warning 升级为 fail。

**已修（2026-08-28）**，加了两道闸而不是一道：

1. `ArchiveScript.sh` 引入 `PUBLISHING`（`--upload-to-github` / `--update-appcast` / `--commit-push`
   任一即为真）。payload 构建失败时，本地构建仍只 warn（少的只是模拟器注入这一项能力），
   **发布运行直接 fail**。
2. 更硬的一道：导出之后**直接检查 `.app` 里有没有** `Contents/Resources/
   RuntimeViewerServer-iphonesimulator.framework`，没有就拒绝发布。这一道检查的是产物本身而不是
   中间步骤，所以连「嵌入阶段压根没跑」也一起挡住了 —— 那个阶段缺 payload 时同样是 `warning:`
   加 `exit 0`，从退出码上看和成功一模一样。

与 `PR106X.5`（陈旧 payload 被当新品嵌入）是同一域的两面：那条管「别发旧的」，这条管「别发缺的」。

## 构建与测试说明

本分支**必须**用 `USING_LOCAL_DEPENDENCIES=1` 构建。按声明的远程 pin 解析会失败：
`RuntimeViewerCore` 调用 `demangleAsNodeTransient`（`swift-demangling` ≥ 0.5.0 才有），而
`RuntimeViewerCore/Package.swift` 把 `MachOSwiftSection` 钉在 `exact: "0.15.2"`，后者又把
swift-demangling 限制在 `< 0.5.0`。这先于本 PR 存在（`next` 上同样如此）。

```bash
cd RuntimeViewerPackages && USING_LOCAL_DEPENDENCIES=1 swift test --scratch-path /tmp/claude/SwiftPM/RVP-local
cd RuntimeViewerCore     && USING_LOCAL_DEPENDENCIES=1 swift test --scratch-path /tmp/claude/SwiftPM/RVC-local
```

**成败只认退出码** —— 日志里那行 `Test Suite 'RuntimeViewerPackagesPackageTests.xctest' passed`
是 XCTest 那半在报绿，swift-testing 崩溃时它照样打印。

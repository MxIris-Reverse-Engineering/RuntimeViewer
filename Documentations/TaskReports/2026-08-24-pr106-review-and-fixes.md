# 2026-08-24 - PR #106 代码审查与修复落地

- **日期**: 2026-08-24 ~ 2026-08-25
- **任务**: PR #106 代码审查与修复落地
- **作者**: Mx-Iris
- **仓库**: git@github.com:MxIris-Reverse-Engineering/RuntimeViewer.git

## 1. 问题 / 任务

对 PR #106（`feature/inject-ios-simulator-process` → `next`，Evolution 0014 模拟器注入，
27 文件 / +2481 −97）跑 `/code-review xhigh`，产出 15 条发现。要求：按 AGENTS.md 的
「发现必答四问」逐条裁决，把结论交由另一个会话对抗性复核，然后按用户批准的范围修复，
每条带「修复前红、修复后绿」的复现测试，裁决留档，最后分批提交推送。

用户在过程中做的裁决：

- `installServerFrameworkIfNeeded` 不查 `isInstalledServerFramework` —— **有意设计**，剔除，不计入。
- 书签键含 pid —— 认可为 Major，但**单开 PR 修**，方案取「换掉存储键类型」。
- UDID 的广播与日志 —— **两半都先记账**，本轮不动。
- 服务名形状 —— 取「设备名 (进程名)」，去掉 pid。
- 范围 —— 必修 + 顺手修，各带复现测试。

## 2. 探索与调研

### 调研内容

- PR 全量 diff 与基线 `next` 的逐文件对比（基线是合并目标 `next`，**不是** `main`）
- `RuntimeSource` 的 `==` / `hash` / `identifier` 语义，以及 `AppDefaults` 两张书签表的读写点
- `RuntimeEngineManager` 的 Bonjour 连接、镜像 reconcile、断开清理三条路径
- `RuntimeEngineMirrorRegistry` 的 ownership 与 engineID 前缀两套匹配键
- `InjectionTargetPlatform` 的 Mach-O 解析全文，对照 `MacOSX26.5.sdk/usr/include/mach-o/loader.h`
- 作者自查文档 `KnownIssues/2026-08-22-simulator-injection-identity-findings.md`（SIMID.1–5）
- `git log -S` / commit body 追溯 `917002cc`（稳定身份）、`b350f8c1`（leaf 掉线清理）、`1f3a387d`（日志脱敏）

### 关键发现

- **十四条发现里，十一条是同一个上游决定的连带后果**：身份从「每安装一个」改成「每设备一个」之后，
  一批值的含义变了，而别处仍按旧含义读它们。这是本轮的主线，不是十四个独立 bug。
- `Int(_: UInt64)` 是 trapping 转换：fat-64 slice offset 高位置 1 时**整个 app SIGTRAP**，
  实测 exit 133。第二处更深：`loadUnalignedIfWithinBounds` 的 `byteOffset + size` 自身溢出，
  区间是 `(Int.max-4, Int.max]`，宽 4 —— 宽度来自第一次读的 `UInt32`，不是最宽的那次。
- `clearAllWithHostID` 的前缀失配：`buildEngineDescriptors` 填的是对端的 `hostInfo.hostID`，
  对端**自己的** engine 走 `RuntimeEngine.init` 默认值（实例级），而直连路由已是设备级。
  A→B→C 且 A 支持 engine sharing 时，A 掉线后镜像清不掉，`stillReachable` 守卫同时被打穿。
- 服务名 `{deviceID}-{pid}` 的代价不在显示：旧宿主经 `RuntimeSource.description` 把它写进
  `NSOutlineView` 的 `autosaveName` / `identifier`，**对端每启动一次就多一套 autosave 键，永不回收**。
- `Bundle.main` 在被注入的 payload 里指的是**宿主 app** 的 bundle —— 所以
  `CFBundleDisplayName` 为空串是现实问题，本机 `/Applications` 里就有三个（DrString、Eudic、RapidAPI）。

### 被证伪的判断（三方都判错过）

- **fat 条目 `return nil` 应改 `continue`** —— 原报告、我的转述、复核会话都判「成立但触发面窄」。
  实为**误报**：条目连续定长，`entryOffset = 8 + index * entrySize` 单调递增，越界条件随之单调，
  **一旦某条越界其后必然全越界**，不存在「`continue` 够得到而 `return nil` 跳过了」的输入。
  写探针枚举 buffer 长度 8/28/48/68 证否。
- **「同机第二个模拟器同 pid」** —— 我举的复现场景错误。macOS 上模拟器进程就是宿主普通进程，
  共用同一 pid 命名空间，同机不可能有两个相同 pid。复核会话证伪，剩余场景只有局域网另一台设备。
- **`Bundle(url:)` 对 iOS 扁平布局返回 nil** —— 我的推断，实测证否：扁平 framework 解析正常、
  无 Info.plist 也非 nil、**不存在负缓存**。该条结论保留但理由换成「零反馈的空操作」。
- **「本分支编译不过、需要 pull 依赖仓库」** —— 我的错误结论。真相是必须带
  `USING_LOCAL_DEPENDENCIES=1`；按远程 pin 解析确实失败（`RuntimeViewerCore` 调
  `demangleAsNodeTransient` 需 swift-demangling ≥ 0.5.0，而 `MachOSwiftSection` 被钉在
  `exact: "0.15.2"`，后者又限制 < 0.5.0），但这**先于本 PR 存在**，且本地依赖模式下整图正常。

### 候选方案（服务名，C5）

| 方案 | 优点 | 缺点 |
|------|------|------|
| `「设备名 (进程名)」`，去掉 pid（**用户选定**） | 旧宿主可读且**跨启动稳定**，autosave 键不再累积；顺带把 UDID 移出广播名 | 同设备两个**同名**进程会撞 mDNS 名，系统加后缀 |
| `「设备名 (进程名 pid)」` | mDNS 唯一性有硬保证 | autosave 键仍按启动累积，只修好一半 |
| 维持 `{deviceID}-{pid}`，只记账 | 零改动 | iOS 端有外部用户，升级后会在旧宿主上看到原始 UUID |

### 候选方案（书签键，A1）

| 方案 | 优点 | 缺点 |
|------|------|------|
| 用设备级 `hostID` 当键，不迁移 | 改动最小，不需解析字符串（`engine.hostInfo.hostID` 已是设备级） | 存量书签一次性孤儿化 |
| 同上加惰性迁移 | 保住存量 | 迁移需「设备名 → deviceID」映射，只有对端在线时才知道，复杂度与出错面明显更大 |
| 换掉存储键类型（**用户选定，单开 PR**） | 语义最干净，顺带解决既存的 `@FileStorage` 缺陷 | 落盘格式变更 + 迁移，量级超出本轮 |

## 3. 最终方案

十四条发现的处置：**十一条修**、**一条误报不改**、**两条延后**（UDID 隐私记账；书签键单开 PR）。

修复按可独立编译的顺序拆成四个代码 commit 加一个文档 commit：Mach-O 探针加固 →
镜像清理（registry 先落，manager 后调）→ 设备级 attach 确认 → 服务名与进程名 → 裁决留档。
`RuntimeEngineManager.swift` 同时含 A3/C1/C3 三处改动，无法按发现拆分（不用交互式
`git add -p`），故随 A3 那个 commit 落地，在 body 里说明。

## 4. 实际执行与改动

### 改动清单

| Commit | 修的是 | 文件 |
|---|---|---|
| `3916932e` fix(inject) | fat-64 offset trap、边界检查溢出、visionOS 常量 11↔12、切片上限由「拒绝」改「钳制」、测试静默通过与漏搜 legacy runtime 路径 | `InjectionTargetPlatform.swift`、`InjectionTargetPlatformTests.swift` |
| `005169c9` fix(engine) | 新增 `clearAllForDisconnectedPeer(hostID:originInstanceID:)`，补上实例级命名空间 | `RuntimeEngineMirrorRegistry.swift`、`RuntimeEngineMirrorRegistryTests.swift` |
| `610e9d9c` fix(inject) | 新增 `ProcessEnvironmentProbe`（`KERN_PROCARGS2`）读目标 `SIMULATOR_UDID`，attach 确认改整键相等；另含 `try?` 吞取消、静默 `return` 两处 | `ProcessEnvironmentProbe.swift`(新)、`RuntimeEngineManager.swift`、`AttachToProcessViewModel.swift`、两个新测试文件 |
| `1df0c1c3` fix(bonjour) | 服务名改 `「设备名 (进程名)」`；删掉 `RuntimeViewerServer` 里少了 `isEmpty` 检查的重复回退链；更正 `isRunningInsideInjectedProcess` 的不实注释 | `RuntimeNetwork.swift`、`RuntimeViewerServer.swift`、`RuntimeViewerUsingUIKit/AppDelegate.swift`、`BonjourProcessIdentityTests.swift`、`ProcessNameFallbackTests.swift`(新) |
| `e2856885` docs | 十四条四问裁决 + 三条顺带发现；索引与 0014 决策日志 | `KnownIssues/2026-08-24-pr106-review-findings.md`(新)、`KnownIssues/README.md`、`Evolutions/0014-*.md` |

共 17 文件、25 个新测试。PR 自带的 `localServiceName` 测试断言 `-pid` 后缀，被 C5 打红后
改写为新契约（不是删掉）。

### 关键命令

```bash
# 本分支必须带这个环境变量，否则按远程 pin 解析必然编译失败
cd RuntimeViewerPackages && USING_LOCAL_DEPENDENCIES=1 \
  swift test --scratch-path /tmp/claude/SwiftPM/RVP-local
cd RuntimeViewerCore && USING_LOCAL_DEPENDENCIES=1 \
  swift test --scratch-path /tmp/claude/SwiftPM/RVC-local
# 成败一律以退出码判定；日志里的 "Test Suite ... passed" 是 XCTest 那半在报绿，
# swift-testing 崩溃时它照样打印

# Xcode target 的两个文件只能靠建主 app 验证；scheme 名是 "RuntimeViewer macOS"
USING_LOCAL_DEPENDENCIES=1 xcodebuild -workspace RuntimeViewer-Debug.xcworkspace \
  -scheme 'RuntimeViewer macOS' -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/claude/DerivedData/RuntimeViewer build

# 本地依赖解析会改写三个 Package.resolved，属构建产物，提交前必须还原
git checkout -- RuntimeViewerCore/Package.resolved RuntimeViewerPackages/Package.resolved \
  RuntimeViewer-Debug.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

### 验证

- **红/绿逐条**：A2 红态是**真崩溃**（`Fatal error: Not enough bits to represent the passed value`，
  signal 5，exit 1）；B2 / C7 断言失败；C5 打红 PR 自带测试；C1 因缺既有接缝，改用
  「摘掉第三条清理再跑」证明测试会咬（`removed → []`、陈旧条目存活），验毕还原。
- `RuntimeViewerPackages`：**148 tests / 24 suites 全绿，exit 0**。
- `RuntimeViewerCore`：412 tests，**4 条失败**——把全部改动还原到 `69d8131b` 重跑，
  同样这 4 条以同样消息失败（404 tests / 4 issues），**确为既存问题**，已登记 `PR106.15`。
- `RuntimeViewer macOS`：**BUILD SUCCEEDED**，`AttachToProcessViewModel.swift` 与
  `RuntimeViewerServer.swift` 均在该段内编译，该段 0 错误。
- `RuntimeViewerServer` 单独 scheme 编不过（MetaCodable 宏插件链接失败），发生在任何本次
  代码编译**之前**；同一 target 作为主 app 一部分编译正常，判为环境问题。

### 与原方案的差异

- **差异点**: C6 由「修」改为「误报不修」。
  **原因**: 探针证明 `return nil` 与 `continue` 无可观测差异（条目连续定长，越界单调）。
  **影响**: 少一处改动；结论与理由写入 `PR106.13`，下次审查不必重走四问。
- **差异点**: A2 / A3 严重度由 Major 降为 Minor（仍在本轮修）。
  **原因**: 复核会话指出 A2 唯一生产调用方是 `platform(ofProcess:)`，触发需 TOCTOU 替换正在运行
  进程的可执行文件，不构成安全边界；A3 的「同机双模拟器」场景被 pid 命名空间证伪，且该函数只管
  报错不管选中，真实损害是「该报的错没报」而非「连到错的设备」。
  **影响**: 仅标签，修复照做。
- **差异点**: C1 由「记账不修」改为「修」。
  **原因**: 复核会话给出一条不动默认 `hostID` 的修法——直连 engine 的 `originChain[0]` 已存着对端
  instanceID，追加一次按它的清理即可，因而不重开 SIMID.4。
  **影响**: 多一个 commit；SIMID.4 的三条复核判据均未触发，该裁决继续有效（已在文档中注明）。
- **差异点**: C2 范围由「两处新增 `.public` 日志」扩大到约 40 处。
  **原因**: 复核会话的全仓库审计指出绝大多数是**文本没改、值变了**（`RuntimeEngineManager.swift:222`
  把 `let name` 换成 `localServiceName`，下游既有日志内容随之改变），只读 `+` 行的 review 必然漏掉；
  且本 PR 新加的那个 `.private` 无效——同一值紧接着流进五个 `.public` 位置。
  **影响**: 从「顺手修」改判为「需要一条贯穿约定，单独立提案」，用户裁决记账。
  实现时的坑已写入文档：加盐 hash **必须用固定盐**，per-installation 盐会重新把一台模拟器
  拆成「每个注入进程一个 Section」。
- **差异点**: A1 的写入点由 3 处更正为 4 处，且值里也存了 source。
  **原因**: 复核会话补漏 `SidebarRuntimeObjectListViewModel:442`；`RuntimeImageBookmark` /
  `RuntimeObjectBookmark` 两个结构体都带 `source` 字段，只改键不改值会留下自带过期 source 的书签。
  **影响**: 促成用户改选「换掉存储键类型」并单开 PR。

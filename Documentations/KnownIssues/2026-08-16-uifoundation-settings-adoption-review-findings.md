# 2026-08-16 UIFoundation Settings Adoption Review Findings

**Review date:** 2026-08-16
**Branch reviewed:** `feature/uifoundation-settings-adoption` @ PR [#99](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/pull/99) (base `next`)
**Method:** `/code-review` (10 finder angles + sweep), then per-finding adjudication against the four questions in AGENTS.md
**Scope:** 31 files changed since the merge base, 552 insertions / 518 deletions
**Companion proposal:** [`Evolutions/0007-uifoundation-settings-adoption.md`](../Evolutions/0007-uifoundation-settings-adoption.md)

本轮共 14 条 findings。11 条已在本批次修复，1 条判定为**误报**，2 条**延后**（由 `main` 上已有的提交解决）。
`US.1` 与 `US.2` 是合并阻塞项，两者都需要 UIFoundation 出新版本——为此发布了
[UIFoundation 0.17.0](https://github.com/Mx-Iris/UIFoundation/releases/tag/0.17.0)。

## 概览

| Class | Count | Notes |
|---|---:|---|
| Blocker（已修） | 2 | 分支无法按自己声明的依赖图编译；设置窗口不再记住位置 |
| Major（已修） | 6 | 加载/落盘时机、actor 隔离陷阱、平台守卫、持久化测试缺口 |
| Minor（已修） | 3 | preview 隔离、tracking 隔离断言、重复依赖声明 |
| False positive | 1 | 非 macOS 持久化 |
| Deferred | 2 | `OutputTransformer` 依赖声明、文档随之更新 |

## 使用说明

- 每条 finding 有稳定 ID `US.<N>`，便于在 commit / 后续 review 中引用。
- 已修条目在 Fix 列给出提交；**不要删除条目**，保留历史。
- 判为误报或延后的条目，下一轮 review 若前提未变可直接跳过，不再重走四问；
  若有新证据推翻当初理由，更新本表并重新裁决。

---

## Blockers（已修）

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **US.1** | 版本下限写 `0.16.0`，但该 tag 不含 `SettingsConfiguration` | `RuntimeViewerPackages/Package.swift`；三份 `Package.resolved` | `SettingsWindowController` 调用 `super.init(configuration: SettingsConfiguration(sidebarIconSize: 15))`，而 UIFoundation `0.16.0` = 提交 `4bde74c`，`SettingsConfiguration.swift` 是下一个提交 `eb07e10` 才加的；0.16.0 的 initializer 也没有 `configuration:` 参数。任何没有启用本地 sibling checkout 的构建都会报 "cannot find 'SettingsConfiguration' in scope"。**基线无此问题**（`next` / `main` 都不碰该 API，main 下限还是 0.15.1），纯本次引入。 | **Fixed by [`4103883`](../../commit/4103883)** —— 发布 UIFoundation 0.17.0（含 `SettingsConfiguration`），下限提到 `0.17.0`，`RuntimeViewerPackages` 由 SwiftPM 重新解析，两份 workspace lockfile 定点改 pin（Debug 那份原本还停在 0.15.1，早于 `Settings` trait）。 |
| **US.2** | 设置窗口每次启动都回到屏幕中央 | UIFoundation `SettingsWindowController.windowDidLoad` | 迁移前 RuntimeViewer 的顺序是 `center()` → `setFrameAutosaveName()`，UIFoundation 基类是反过来的，而子类没有覆写。**注册 autosave 名字这一步本身就会应用已保存的 frame**，所以之后再 `center()` 就把它丢掉了。实测：PR 顺序得到 `(1113, 897)`（居中），旧顺序得到 `(111, 222)`（用户位置）。窗口**尺寸**不受影响，`center()` 只移动不改大小。**基线无此问题**——旧顺序是刻意写对的，`git log -S setFrameAutosaveName` 也没有相关修复史。 | **Fixed in UIFoundation [`0b323b0`](https://github.com/Mx-Iris/UIFoundation/commit/0b323b0) (0.17.0)** —— 只有 `setFrameUsingName(_:)` 会报告「是否真的恢复了」（`setFrameAutosaveName` 的 Bool 只表示名字有没有被接受，首次启动同样返回 true），改为它返回 false 时才居中。附带好处：外接屏拔掉后那条越界记录会被 AppKit 判否，从而降级为居中而不是把窗口开到看不见的地方。带三个场景的回归测试。 |

---

## Major issues（已修）

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **US.3** | 磁盘加载只是解析依赖的副作用 | `RuntimeViewerSettings/Settings.swift` | `Settings.load()` 全项目唯一调用点是 `SettingsAccess` 私有 init 里的 `Task {}`，也就是说「设置有没有被读进来」取决于哪个服务先碰 `\.settings`（今天是 `AppearanceController.start()`）。SwiftUI 页面经 `AppSettings` 直接读 `Settings.store`，完全绕过 `SettingsAccess`——一旦启动顺序变化，页面会显示默认值，而首次改动就把这份默认值覆盖回用户文件。**基线无此问题**：旧的 `Settings.shared` 自身 init 就会加载，任何路径都触发。 | **Fixed by [`df554c8`](../../commit/df554c8)** —— `load()` 提升为文档化的实例方法，新增 `SettingsLifecycleController` 在 `applicationDidFinishLaunching` 里第一件事就调用它。 |
| **US.4** | `MainActor.assumeIsolated` 在 actor 上首次解析会 abort | `RuntimeViewerMCPBridge/MCPBridgeServer.swift` | `\.settings` 的 liveValue 建在 `MainActor.assumeIsolated` 后面。`generationOptions()` 已经用 `MainActor.run` 包住了**读取**，但 `let settingsAccess = settings` 在 hop 之前、跑在 `MCPBridgeServer` 自己的执行器上——解析动作本身仍在错误的 actor 上。直接驱动 bridge 的单元测试、或任何启动顺序变化都会触发。**基线无此问题**：旧的 `liveValue: Settings.shared` 没有隔离断言。 | **Fixed by [`7b45be7`](../../commit/7b45be7)** —— 依赖声明移进 `MainActor.run` 内部，顺带删掉这个 actor 不再需要的存储属性。`MainActor.run` 仍在同一 task 内，task-local 的 `withDependencies` 覆盖照常生效。 |
| **US.5** | `AppSettings.swift` 缺平台守卫，且依赖未声明 | `RuntimeViewerSettingsUI/AppSettings.swift`；`RuntimeViewerPackages/Package.swift` | 该文件无条件 `import UIFoundationSettings`，而同目录其它文件全部以 `#if os(macOS)` 开头；两个 UIFoundation Settings product 都挂着 `.when(platforms: [.macOS])`，所以为包声明的其它平台（iOS 18 / tvOS 18 / visionOS 2）编译该 module 会报 "no such module"。同时 target 只声明了 `UIFoundationSettingsUI`，这个 import 是靠 UIFoundation 内部的 target 边传递解析的。**基线无此问题**：旧文件只 import Foundation/SwiftUI/Dependencies。 | **Fixed by [`d248015`](../../commit/d248015)** —— 加 `#if os(macOS)`，并在 manifest 中显式声明 `UIFoundationSettings`。 |
| **US.7** | `accessPersistedValues()` 是手工清单，无测试兜底 | `RuntimeViewerSettings/Settings.swift` | 七个挂在声明上的 `didSet { scheduleAutoSave() }` 被替换成一个可以忘记维护的方法。漏掉一个属性的失败方式极隐蔽：该属性仍会在**别的**属性触发写入时被一并编码，日常测试看不出来；只有「本次会话只改了这一个设置」才会丢。 | **Fixed by [`e2e269a`](../../commit/e2e269a)** —— 两个测试：其一逐个单独修改七个属性并断言写入落盘（删掉 `_ = update` 后确认变红）；其二把覆盖清单与真实编码 payload 的顶层键集合对比，加第八个属性时立即失败并指出需要登记的两处。每个用例还先断言自己的改动不等于默认值——`notifications` 用例第一次跑就是这样被抓出来的。 |
| **US.10** | 退出时不落盘，1 秒防抖窗口内的修改丢失 | `App/AppDelegate.swift` | `SettingsStore` 默认 1 秒防抖且每次改动都重置计时器，改完设置立刻 ⌘Q 就丢。**基线也有这个洞**，不是本次引入；但 UIFoundation 提供的 `save()` 文档原话就是 "Use when the app is about to terminate"，修复成本降到接近零，故一并处理。 | **Fixed by [`df554c8`](../../commit/df554c8)** —— `applicationShouldTerminate` 返回 `.terminateLater`，`flush()` 写完后再 reply。注意 `applicationWillTerminate` 无法 await，不要把 flush 挪回去。此处可以安全延迟退出，是因为 `Document` 永远不会变脏（`updateChangeCount(_:)` 空实现 + 三个 save action 都是 no-op），AppKit 没有未保存文档要复查。 |
| **US.14** | `SettingsAccess` 两个初始化器行为分叉 | `RuntimeViewerSettings/Settings.swift` | `private init()` 会启动加载，internal `init(store:)` 不会；而 `load()` 与主题迁移都硬编码写静态的 `Settings.store`，不管实例持有的是哪个 store。于是 `SettingsAccess(store: other)` 读一个对象，加载和迁移却改另一个，两份模型静默分叉。当时只有测试用到 `init(store:)`，危害是假设性的。 | **Fixed by [`df554c8`](../../commit/df554c8)** —— 只保留 `init(store:)`，`load()` 与迁移都走实例自己的 store。 |

---

## Minor issues（已修）

| ID | Title | Where | Why | Fix |
|---|---|---|---|---|
| **US.8** | `previewValue` 被删，预览会读写真实设置文件 | `RuntimeViewerSettings/Settings.swift` | 旧写法是 `@DependencyEntry(liveValue: Settings.shared, previewValue: Settings())`；迁移后只剩 `liveValue`，而 swift-dependencies 的 `previewValue` 默认回落到 `liveValue`。仓库里目前一个 `#Preview` 都没有，所以是**理论风险**；但修复几乎免费，且能顺带解决 US.14。 | **Fixed by [`df554c8`](../../commit/df554c8)** —— 新增 `InMemorySettingsStorage`，preview value 解析到一份内存 store，测试也复用它。 |
| **US.9** | `Observable.tracking` 的首次读取碰 `@MainActor` 状态 | `Theme/ResolvedThemeStream.swift`、`Content/ContentTextViewModel.swift` | `tracking` 的第一次 `access()` 同步跑在订阅者所在线程上，而闭包现在读的是 `@MainActor` 的 `SettingsAccess`。迁移前读的是非隔离的 `@Observable Settings`，同样形状是良性的。两个文件都有 `@preconcurrency import RuntimeViewerSettings`，把诊断压掉了。今天所有订阅者都在主线程，故优先级低。 | **Fixed by [`ab7345b`](../../commit/ab7345b)** —— 闭包内加 `MainActor.assumeIsolated`，把要求从「编译器不再检查」改成运行时断言，未来从后台订阅会响亮失败而不是静默竞争。 |
| **US.13** | `ContentTextViewModel` 重复声明 `@Dependency(\.settings)` | `Content/ContentTextViewModel.swift:38` | `ViewModel` 基类已有同名依赖，且 `super.init` 在此之前已执行，局部声明只是遮蔽了继承来的属性。开销可忽略，真正代价是让下一个读代码的人搞不清指的是哪个。 | **Fixed by [`ab7345b`](../../commit/ab7345b)** —— 删除局部声明，直接用继承的 `settings`。 |

---

## False positive

| ID | Title | Where | 裁决理由 |
|---|---|---|---|
| **US.6** | 「非 macOS 平台丢失了持久化与主题迁移」 | `RuntimeViewerSettings/Settings.swift` | 现象属实——`store` / `load()` / 迁移都进了 `#if os(macOS)`，而旧的 `SettingsFileSystemStorage` 没有平台门。但**没有可观察的影响**：全仓库检索确认，`RuntimeViewerSettings` 模块之外**没有任何代码写入设置**，唯一的写入方是 macOS-only 的 SwiftUI 设置页；`RuntimeViewerUsingUIKit` 对 settings 的引用数为 **0**；`RuntimeConnectionNotificationService` 整个文件是 `#if os(macOS)`。非 macOS 上唯一的读取方是 `ViewModel` 基类和 `RuntimeBackgroundIndexingCoordinator`，两者读到的只会是默认值——迁移前那套跨平台持久化，在 iOS 上读写的也永远是一个只含默认值的文件。补一套第二持久化栈等于写死代码。**结论：不修**，改为在 AGENTS.md 写明这条平台边界，并注明「哪天要给其它平台加设置 UI，必须先给它真正的存储，否则改动会静默消失」。 |

---

## Deferred

| ID | Title | Where | 裁决理由 |
|---|---|---|---|
| **US.12** | `@_exported import OutputTransformer` 保留，但声明该 product 的依赖边被删了 | `RuntimeViewerCore/Package.swift`、`Transformer/Transformer.swift` | 现象属实，但**基线也是如此、且 main 上有更完整的解法**。`main` 的 `0cb669c`（升级 MachOSwiftSection 0.15.2 并拆包，`Transformer.swift` 同时 re-export `OutputTransformer` 与 `SwiftOutputTransformer`）是完整版；本分支的 `8982027` 只删了 product 行没动源码。而且 `main` 自己的 `RuntimeViewerCore` 也没有声明这两个 product，同样依赖隐式传递解析。**结论：不在本 PR 处理**，等 `main` 并入 `next` 自然解决。若要收紧成显式声明，另开 PR。 |
| **US.11** | AGENTS.md 与提案自相矛盾，且提案状态标为 `Implemented` | `AGENTS.md`、`Evolutions/0007` | 已随 US.1 一并修正（版本改 0.17.0、删掉「等发布后再验证」的措辞、已知限制重写）。保留条目是因为**根因未除**：本分支目前远端 pin 与本地 sibling checkout 两端都编不过（见提案「已知限制」），所以 `Implemented` 的状态要到 `main` 并入 `next` 之后才真正成立。 |

# Draft - iOS 上的设置真正存盘

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-20
- **最后更新**: 2026-11-20
- **所属愿景**: [iOS 版功能对齐](../Visions/IOSFeatureParity.md)（第二步）
- **关联提案**: [0099-engine-management-on-ios](0099-engine-management-on-ios.md)（第一步）、[0011-uifoundation-settings-adoption](0011-uifoundation-settings-adoption.md)（设置改用 UIFoundation 的存储）；上游 UIFoundation 的 [0042-settings-store-on-all-platforms](https://github.com/Mx-Iris/UIFoundation/blob/main/Documentations/Evolutions/0042-settings-store-on-all-platforms.md)（放开设置存储的平台限定、加同步读取，已随 0.48.0 发布）
- **实现分支 / PR**: `feature/settings-storage-on-ios`
- **配套文档**: 待定 —— 预计无单独文档，规则写进根 `AGENTS.md` 的 *Settings Integration*
- **网页版**: 同目录同名的 `.html`

## 摘要

iOS、越狱版 iOS 与 visionOS 上的 RuntimeViewer 把设置存进文件，与 Mac 版用同一个 `SettingsStore`、同一种格式：
`RuntimeViewerSettings` 在所有平台上依赖 UIFoundation 的 `UIFoundationSettings`（上游先放开平台限定），`SettingsAccess`
只剩一种实现，迁移逻辑各平台都跑；iOS app 启动时同步读完设置，App 进入后台或即将终止时立刻写盘。Mac 上行为不变。
iOS 上还没有能改设置的界面，所以这一步做完用户看不到变化；派生数据（Find 语料的磁盘缓存）在 iOS 上暂不开启。

## 动机

完整动机见愿景《[iOS 版功能对齐](../Visions/IOSFeatureParity.md)》。这一步特有的：

- **iOS 上的设置只在内存里**：`SettingsAccess` 在 macOS 之外持有一份 `Settings()`，`load()` 与 `flushSynchronously()`
  是空操作（`RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift:116-122`、`:134-174`）。根 `AGENTS.md`
  的 *Settings Integration* 已经写明：哪个平台要加设置界面，得先给它真正的存储，否则改动会悄悄丢掉。
- **后面几步都要它**：愿景第三步把设置生命周期收进 AppCore，第五步给 iOS 做设置页；今天 iOS 上任何写入（包括迁移逻辑
  想做的）在下次启动都会消失。
- **macOS 与 iOS 两套 `SettingsAccess`**：两个分支各管一份状态（`store` 与 `value`），iOS 分支还跳过了两项迁移
  （`:177-241` 整段只在 macOS 上编）。合成一种实现，iOS 上的行为才和 Mac 上测过的是同一份代码。

## 前期调研

- **上游**：`UIFoundationSettings` 的三个源文件只 import `Foundation` 与 `Observation`，却包在 `#if Settings && os(macOS)`
  里（UIFoundation `Sources/UIFoundationSettings/*.swift:1`）。上游提案 0042 把条件改成
  `#if Settings`、补齐 `@available`，并给 `SettingsStore` 加同步 `load()`，已随 0.48.0 发布（2026-11-20）。
- **依赖声明**：`RuntimeViewerSettings` 只在 AppKit 平台依赖 `UIFoundationSettings`（`RuntimeViewerPackages/Package.swift:407`），
  测试 target 同样（`:589`）；`RuntimeViewerSettingsUI` 的两条依赖（`:423-424`）与本篇无关。UIFoundation 现在的下限是
  `from: "0.47.0"`（`:179`）。
- **只在 macOS 上的部分**：`Settings.swift` 的 import（`:5-7`）、`applicationDirectoryName` / `applicationDirectoryURL` /
  `store`（`:48-72`）、`PersistentSettings` 遵循（`:75-95`）、`SettingsAccess` 的两个分支（`:108-122`）、两项迁移
  （`:177-241`）、`current` 与 `preview` 的分支（`:243-277`）；`InMemorySettingsStorage.swift` 整个文件（`:1`）。
  这些都只用 Foundation 与 `UIFoundationSettings`。
- **留在 macOS 上的**：`Settings+Types.swift:179` 起 MCP 端口文件的位置（MCP 只在 Mac 上）、`ApplicationRelauncher.swift`、
  `SourceEditorFrameworks.swift`——都不动。
- **macOS 的生命周期**：`RuntimeViewerUsingAppKit/.../App/SettingsLifecycleController.swift` 在 `applicationDidFinishLaunching`
  里开 `Task { await settings.load() }`，在 `applicationShouldTerminate` 里 `flushSynchronously()` 后回 `.terminateNow`；
  `AppDelegate.swift:90`、`:106` 调用它。
- **iOS 的生命周期**：`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/AppDelegate.swift` 在
  `application(_:didFinishLaunchingWithOptions:)` 里依次注册注入与交叉引用命令、防挂起、建 `.local`、启动引擎管理器；
  没有任何设置相关的调用。`SceneDelegate` 只实现了 `scene(_:willConnectTo:options:)`。iOS 没有
  `applicationShouldTerminate`；App 可能在后台被直接杀掉，不会收到任何回调。
- **工程**：`RuntimeViewerUsingUIKit` 文件夹是 `RuntimeViewerUsingUIKit`、`-JB`、`RuntimeViewerUsingVision` 三个 target
  共用的同步文件夹（`RuntimeViewerUsingUIKit.xcodeproj/project.xcproj:35-68`），在 `App/` 里新增文件三个 target 都会编，
  不用改工程文件。
- **测试**：`SettingsPersistenceTests.swift` 与 `SettingsResidentLimitMigrationTests.swift` 只因整份文件包在 `#if os(macOS)`
  里而限于 macOS，内容只用 `InMemorySettingsStorage`、`SettingsStore` 与 `SettingsAccess(store:)`。测试只在 Mac 上跑，
  放开后覆盖的就是各平台共用的那份代码。
- **派生数据**：系统身份 `RuntimeDerivedDataSystemIdentity` 与读取标记 `RuntimeDerivedDataReadingMarker` 都有
  `#if os(macOS)` 分支（`RuntimeViewerCore/Sources/RuntimeViewerCore/DerivedDataStorage/`）；派生数据只给 Find 语料用，
  而 iOS 上还没有 Find。

## 提议方案

1. **上游先落地**：UIFoundation 按它的提案放开设置存储并发 0.48.0；RuntimeViewer 把下限抬到 `from: "0.48.0"`，
   `RuntimeViewerSettings` 与 `RuntimeViewerSettingsTests` 在所有平台上依赖 `UIFoundationSettings`。
2. **一种 `SettingsAccess`**：去掉 `Settings.swift` 与 `InMemorySettingsStorage.swift` 里的 `#if os(macOS)`。`Settings.store`、
   `applicationDirectoryName`、`applicationDirectoryURL`、`PersistentSettings` 遵循在各平台都有；`SettingsAccess` 只保留
   `store` 一种状态，`load()` 与两项迁移、`flushSynchronously()`、`current`、`preview` 各平台同一份。
3. **同步读取**：`SettingsAccess` 新增 `loadSynchronously()`，与 `flushSynchronously()` 成对：用上游的同步 `load()` 读完，
   再跑同样的两项迁移。`load()`（异步）保留给 macOS，它的行为不变。
4. **iOS 的生命周期**：iOS app 新增 `SettingsLifecycleController`（与 macOS 那个同名、同样隐藏在 `@Dependency` 后面），
   `AppDelegate` 在 `didFinishLaunching` 的第一件事里调它的 `loadOnLaunch()` 同步读完；它订阅
   `UIApplication.didEnterBackgroundNotification` 与 `willTerminateNotification`，收到就 `flushSynchronously()`。
5. **文件位置**：与 Mac 同一套命名——App 容器里 `Library/Application Support/RuntimeViewer[-Debug]/settings.json`。
6. **文档**：根 `AGENTS.md` 的 *Settings Integration* 把「macOS 之外只在内存里」那条改成两个平台各自何时读、何时写；
   *Dependency floors* 补一句 UIFoundation 0.48.0 的理由；愿景相关提案表、两份索引登记本篇。

### 非目标

- **iOS 的设置界面**：用户定了这一步只做存储；设置页在愿景第五步。
- **iOS 上的派生数据**：iOS 上还没有 Find，派生数据没人读；系统身份与读取标记在 iOS 上怎么取（本机引擎在 App 进程里，
  App 自己读写），留给把 Find 搬到 iOS 的那一步一起定。
- **macOS 的任何行为变化**：macOS 仍是异步读取、`applicationShouldTerminate` 里写盘；文件位置与格式不变。
- **把两个平台的生命周期控制器并进 AppCore**：愿景第三步做。
- **MCP 端口文件、`ApplicationRelauncher`、`SourceEditorFrameworks`**：都只属于 Mac，保持 `#if os(macOS)`。
- **iCloud 同步设置、在两台设备之间共享设置**。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerPackages/Package.swift` | 修改 | UIFoundation 下限 `from: "0.48.0"`；`RuntimeViewerSettings`、`RuntimeViewerSettingsTests` 对 `UIFoundationSettings` 的依赖去掉平台条件 | 上游放开后各平台都能链接 | 1 |
| 三个 workspace 的 `Package.resolved` | 修改 | UIFoundation 升到 0.48.0（`UpdatePackagesScript.sh`） | 锁文件跟着下限走 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift` · `Settings` | 修改 | 去掉 import、`applicationDirectoryName`、`applicationDirectoryURL`、`store`、`PersistentSettings` 遵循外的 `#if os(macOS)` | 各平台同一个存储 | 1 |
| 同上 · `SettingsAccess` | 修改 | 只留 `store`；`load()`、两项迁移、`flushSynchronously()`、`current`、`preview` 去掉分支；新增 `loadSynchronously()` | 一种实现；iOS 启动时要同步读完 | 1 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/InMemorySettingsStorage.swift` | 修改 | 去掉 `#if os(macOS)` | `preview` 与测试在各平台都用它 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerSettingsTests/SettingsPersistenceTests.swift` | 修改 | 去掉 `#if os(macOS)`；新增同步读取的用例 | 测的是各平台共用的代码 | 1 |
| `RuntimeViewerPackages/Tests/RuntimeViewerSettingsTests/SettingsResidentLimitMigrationTests.swift` | 修改 | 去掉 `#if os(macOS)`；同一组参数也走一遍 `loadSynchronously()` | 迁移现在各平台都跑，两个入口都要迁 | 1 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/SettingsLifecycleController.swift` | 新增 | `@MainActor` 单例，`@DependencyEntry` 暴露；`loadOnLaunch()` 同步读取；订阅进入后台与即将终止两个通知写盘 | iOS 的读写时机 | 2 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/AppDelegate.swift` | 修改 | `didFinishLaunching` 第一件事调 `settingsLifecycleController.loadOnLaunch()` | 在任何东西读设置之前读完 | 2 |
| `AGENTS.md`（根）· *Settings Integration*、*Dependency floors* | 修改 | 改写「macOS 之外只在内存里」那条；补 UIFoundation 0.48.0 的理由 | 规则跟着代码变 | 3 |
| `Documentations/Visions/IOSFeatureParity.md` | 修改 | 相关提案表加本篇；「最后更新」 | 愿景登记 | 3 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本篇 | 索引 | 3 |

## 架构图

```text
RuntimeViewerSettings
  depends on UIFoundationSettings
-   when platforms: [macOS]
+   on every platform (UIFoundation >= 0.48.0)

  Settings
    static store: SettingsStore<Settings>          - macOS only   + every platform
    : PersistentSettings                           - macOS only   + every platform

  SettingsAccess
-   #if os(macOS)  store: SettingsStore<Settings>
-   #else          value: Settings                 (in memory; load/flush no-ops)
+   store: SettingsStore<Settings>                 (one implementation)
    load() async                                   (macOS launch; migrations now on every platform)
+   loadSynchronously()                            (iOS launch; same migrations)
    flushSynchronously()                           (macOS terminate, iOS background / terminate)
```

```text
iOS app, launch to background
  AppDelegate.didFinishLaunchingWithOptions
+   settingsLifecycleController.loadOnLaunch()
+     settings.loadSynchronously()
+       Settings.store.load()                       // synchronous, from Application Support
+       migrateLegacyThemeProfileIfNeeded / migrateResidentLimitDefaultsIfNeeded
    InjectionServiceRegistrar.registerIfAvailable() ... runtimeEngineManager   (unchanged order after it)
  SceneDelegate.scene(_:willConnectTo:)              // reads the stored settings
  edit -> SettingsStore auto-save after 1 s          (unchanged)
+ UIApplication.didEnterBackgroundNotification -> settings.flushSynchronously()
+ UIApplication.willTerminateNotification      -> settings.flushSynchronously()
```

## 详细设计

`SettingsAccess` 合并后的形状（只列变化的成员）：

```swift
@MainActor
@Loggable
@dynamicMemberLookup
public final class SettingsAccess {
    fileprivate static let shared = SettingsAccess(store: Settings.store)

    private let store: SettingsStore<Settings>

    init(store: SettingsStore<Settings>) {
        self.store = store
    }

    /// Reads the stored settings into the model and runs the one-shot data
    /// migrations behind it. The macOS app calls this at launch.
    public func load() async {
        logLoadOutcome(await store.load())
        runMigrations()
    }

    /// The same read and migrations as ``load()``, finished before the call
    /// returns. The iOS app calls this first thing at launch: its first scene
    /// connects right after `application(_:didFinishLaunchingWithOptions:)`
    /// returns, and reads settings as it does.
    public func loadSynchronously() {
        logLoadOutcome(store.load())
        runMigrations()
    }

    private func logLoadOutcome(_ outcome: SettingsStore<Settings>.LoadOutcome) { … }   // the three #log lines of today

    private func runMigrations() {
        migrateLegacyThemeProfileIfNeeded()
        migrateResidentLimitDefaultsIfNeeded()
    }

    public var current: Settings {
        get { store.value }
        set { store.value = newValue }
    }

    package static var preview: SettingsAccess {
        SettingsAccess(store: SettingsStore(defaultValue: Settings(), storage: InMemorySettingsStorage()))
    }
}
```

iOS 的生命周期控制器：

```swift
import UIKit
import RuntimeViewerSettings
import DependenciesMacros

/// Reads the settings when the app launches and writes them as it leaves
/// the foreground. iOS has no `applicationShouldTerminate(_:)`, and a
/// suspended app can be killed without another callback, so the
/// background notification is the last dependable moment to write.
@MainActor
final class SettingsLifecycleController {
    fileprivate static let shared = SettingsLifecycleController()

    @Dependency(\.settings) private var settings

    private var notificationObservers: [any NSObjectProtocol] = []

    private init() {}

    func loadOnLaunch() {
        settings.loadSynchronously()
        let notificationCenter = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            notificationObservers.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        SettingsLifecycleController.shared.settings.flushSynchronously()
                    }
                }
            )
        }
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SettingsLifecycleController.shared })
    var settingsLifecycleController: SettingsLifecycleController
}
```

- **为什么用 App 级通知、不用 `sceneDidEnterBackground`**：愿景第三步要开多个 scene，单个 scene 进后台时别的 scene 可能
  还在前台；`didEnterBackgroundNotification` 在整个 App 进后台时发一次。
- **为什么不包 `beginBackgroundTask`**：写的是几 KB 的 JSON、同步完成，进后台的通知回调本身有几秒时间。
- **迁移在 iOS 上也跑**：`migrateLegacyThemeProfileIfNeeded` 读的 `UserDefaults` 键 iOS 上从没写过，只会记下「已迁移」；
  `migrateResidentLimitDefaultsIfNeeded` 在第一次启动时把修订号写进设置，随自动保存落盘——这也是在设备上验证存盘的信号。

## 替代方案考量

- **RuntimeViewer 自己在 iOS 上写一套持久化、不改上游**：愿景第七条取舍已经否掉——同一份设置走两套持久化，
  `accessPersistedValues()` 那条规则要守两遍。
- **iOS 上也像 macOS 那样开 `Task` 异步读**：第一个 scene 可能在读完之前就读了默认值；读完之前的改动会把默认值写回去。
- **在 `SceneDelegate.sceneDidEnterBackground` 里写盘**：多 scene 时语义不对，见详细设计。
- **把 macOS 也改成同步读取**：macOS 的读取时机没出过问题，本篇不改 Mac 的行为；第三步合并两个控制器时再统一。

## 影响

### 用户可见变化

无。iOS 上还没有能改设置的界面；设置照旧取默认值，只是现在会落盘。Mac 版一切照旧。

### 可发现性

无新功能。

### 数据与配置兼容

- iOS 上第一次启动时没有存储，取默认值，与今天一样；迁移把修订号写进设置后，App 容器里出现
  `Library/Application Support/RuntimeViewer[-Debug]/settings.json`。
- Mac 上的文件、格式、位置都不变。
- 越狱版若装成不带沙盒的系统 App，Application Support 是 `/var/mobile/Library/Application Support`，Debug 与 Release
  因目录名不同仍互不干扰（**待在 vphone 上核实**它实际装在哪种容器里）。

### 平台与最低版本

最低版本不变：RuntimeViewerPackages 是 iOS 18、visionOS 2，高于 Observation 要求的 iOS 17、visionOS 1。iOS、越狱版 iOS
与 visionOS 三个 target 行为相同。`os(macOS)` 在 Mac Catalyst 上为假，所以 Catalyst 编译时也走放开后的代码；但依赖
`RuntimeViewerSettings` 的只有 AppCore 与设置界面这一层，Catalyst 的 helper 与 service 是不链接包的外壳，没有进程在
Catalyst 上读写设置。

### 发布

不需要新的权限或 entitlement；不影响公证与 Sparkle。UIFoundation 要先发 0.48.0，RuntimeViewer 的发布 workspace 要跟着
解析到它。

## 落地步骤

0. **上游先落地**（已完成）—— UIFoundation 的 0042 合进 `main` 并打 0.48.0
1. **一种 `SettingsAccess`**（已完成）—— 改动地图里 `Package.swift`、锁文件、`Settings.swift`、`InMemorySettingsStorage.swift`、两份测试
   - 行为：`settingsPackageBuildsForIOSAndVisionOS`（Ultra 上以 iOS 模拟器、iOS 真机、visionOS 模拟器编 `RuntimeViewerSettings`）
   - 行为：`existingSettingsTestsPassOnMac`（放开平台后原有用例照过）
   - 行为：`synchronousLoadAdoptsStoredSettings`
   - 行为：`synchronousLoadRunsTheResidentLimitMigration`
   - 行为：`synchronousLoadKeepsDefaultsWhenNothingIsStored`
   - 行为：`macAppBuildUnchanged`（Tuist workspace，Debug）
2. **iOS 的生命周期** —— `SettingsLifecycleController.swift`（iOS）、`AppDelegate.swift`（iOS）
   - 行为：`iOSAppBuildsForAllThreeTargets`
   - 行为：`settingsFileAppearsAfterFirstLaunchOnDevice`（在 vphone 上看 App 容器里出现 `settings.json`；由用户看，或经用户同意由 agent 经 `vphone.sock` 读）
3. **文档** —— 根 `AGENTS.md`、愿景、两份索引

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：读写时机写进根 `AGENTS.md` 的 *Settings Integration*。
- **有没有引入新术语** —— 预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-20 | Created as Draft | 愿景《iOS 版功能对齐》第二步：iOS 上的设置只在内存里，后面几步都要它真正存盘 |
| 2026-11-20 | 用户选定：只做存储 | 设置页搬到 iOS 的工作量大好几倍（上游设置窗口大半绑着 AppKit），照愿景留到第五步 |
| 2026-11-20 | 自定：派生数据不在本篇开 | iOS 上还没有 Find，派生数据没人读；系统身份与读取标记怎么取留给搬 Find 的那一步 |
| 2026-11-20 | 自定：iOS 启动时同步读取，靠上游新增的同步 `load()` | 第一个 scene 在启动回调返回后就连接，异步读取赶不上 |
| 2026-11-20 | 自定：App 级的进后台与终止通知写盘 | iOS 没有 `applicationShouldTerminate`；多 scene 时单个 scene 进后台不代表 App 进后台 |
| 2026-11-20 | 用户批准，开始实现 | 与上游 UIFoundation 的提案一起批准；上游已落地为 0042 并发布 0.48.0，本篇接着做 |

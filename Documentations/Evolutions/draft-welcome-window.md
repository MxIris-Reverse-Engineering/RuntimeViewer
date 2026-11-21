# Draft - 欢迎窗口（接入 UIFoundation 的 WelcomePanel）

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-21
- **所属愿景**: 无
- **关联提案**: [0069 文件模式](0069-file-mode.md)（最近列表里的文件都是它打开的）、[0077 文件模式打开文件夹](0077-file-folders.md)；UIFoundation 的 [0011 WelcomePanel](https://github.com/Mx-Iris/UIFoundation/blob/main/Documentations/Evolutions/0011-welcome-panel.md) 与 [0012 Xcode 26 样式实测复刻](https://github.com/Mx-Iris/UIFoundation/blob/main/Documentations/Evolutions/0012-xcode26-faithful-style.md)
- **实现分支 / PR**: RuntimeViewer `feature/welcome-window`（从 `next` 切）；UIFoundation `feature/welcome-panel-placeholder-text`（从 `main` 切，合回 `main` 后发 0.50.0）
- **配套文档**: 待定 —— 落地时判断
- **网页版**: 同目录同名的 `.html`

## 摘要

macOS App 接入 UIFoundation 现成的 Xcode 风格欢迎窗口（`WelcomePanelController`，`.xcode26` 样式）。
启动时、以及没有文档窗口时点 Dock 图标，弹出欢迎窗口，不再自动新开一个 My Mac 窗口：左侧是 App 图标、
名字、版本和两个动作（New Window on My Mac、Open File…），右侧是最近打开的文件（与 File › Open Recent
同一份），双击即打开。任何文档窗口一出现，欢迎窗口就自己关掉。Window 菜单加 Welcome to RuntimeViewer
（⇧⌘1），设置 › 通用 › Windows 加「Show Welcome Window at Launch」开关（默认开），关掉即回到现在的行为。
上游 UIFoundation 先给 `WelcomePanelController.Configuration` 加 `projectListPlaceholderText`，让空列表能显示
「No Recent Files」，发 0.50.0 后 RuntimeViewer 打开 `WelcomePanel` trait、把下限抬到 0.50.0。

## 动机

- **启动就建一个用户未必要的窗口。** `AppDelegate` 没有实现 `applicationShouldOpenUntitledFile(_:)`，AppKit
  在没有恢复窗口、也没有打开文件时按默认新开一个未命名文档，`Document.init()` 把它放在 `.local`（My Mac）上
  （`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift:33`）。这个文档一打开就经
  `DocumentSession.open()` 加入 My Mac 引擎的后台工作。想读磁盘上某个文件（0069 / 0077 的文件模式）的用户，
  得先拿到这个窗口，再 ⌘O，原窗口往往随手关掉。
- **最近打开的文件藏在菜单里。** 文件模式读过的文件会进 Open Recent（`FileController.swift:76`
  `noteNewRecentDocumentURL`），但只能从 File › Open Recent 找；欢迎窗口把它们直接摆在第一屏。
- **跟随 Xcode。** RuntimeViewer 的界面一直照 Xcode 做（导航区、工具栏活动、来源选择器、编辑器分栏），
  Xcode 启动时给的正是这个欢迎窗口。
- **组件已经现成。** UIFoundation 的 WelcomePanel 是对 Xcode 26 欢迎窗口逐值实测复刻的（UIFoundation 0012），
  RuntimeViewer 已经依赖 UIFoundation，只是没开这个 trait。

## 前期调研

**UIFoundation 一侧**（检出：`/Volumes/Repositories/Private/Personal/Library/Multi/UIFoundation`，`main` 与
tag `0.49.0` 是同一个提交 `96343f3`，没有未发版的提交）

- 组件在 `Sources/UIFoundationAppKit/WelcomePanel/`，整块包在 `#if WelcomePanel && os(macOS)` 里，
  trait `WelcomePanel` 默认关（`Package.swift:134`）。0.20.0 起就有，RuntimeViewer 现在的下限 0.49.0 已经带它。
- 公开面：`WelcomePanelController: NSWindowController`，`init(configuration:)`，`dataSource` / `delegate`（weak），
  `reloadData()`，`showWindow(_:)`；`window` 与 `contentViewController` 标了 `@available(*, unavailable)`，
  窗口的位置、大小与外框由组件自己管（`Documentations/WelcomePanel.md` §4.1）。
- `Configuration`：`style`，`welcomeLabelText` / `versionLabelText`（及各自的字体、颜色），`appIconImage`、
  `appIconImageShadow`，三个动作槽 `primaryAction` / `secondaryAction` / `tertiaryAction`（`nil` 的不显示），
  `checkShowOnLaunch`。`Action` 带 `image`、`title`、`action: ((Self) -> Void)?` 等。
- `DataSource.welcomePanelUsesRecentDocumentURLs(_:)` 返回 `true` 时直接用
  `NSDocumentController.shared.recentDocumentURLs`，另外两个方法不再被调用（§4.3）。列表是拉取式的：
  赋 `dataSource`、每次 `showWindow(_:)`、窗口重新可见（occlusion）时都重读（§3）。
- `Delegate` 有三个回调；`didCheckShowPanelWhenLaunch` 只有 `.xcode14` 样式有勾选框才会来（§4.4）；
  双击空白处报 `-1`（§4.7）。行的右键菜单自带 Show in Finder。
- 标题默认取 `CFBundleName`、版本默认是 `"Version \(CFBundleShortVersionString)"`
  （`WelcomePanel+Bundle.swift`、`WelcomePanel+WelcomeViewController.swift:155`）。
- **缺口**：列表为空时的文字写死成 `"No Recent Projects"`
  （`WelcomePanel+ProjectsViewController.swift:54`），配置里改不了。RuntimeViewer 的列表是文件，不是工程。
- `.xcode26` 样式：无边框、20 pt 圆角、740 × 460、`.fullScreenUI` 材质、没有「启动时显示」勾选框，
  全部是公开 API，类型标 `@available(macOS 11.0, *)`，RuntimeViewer 的 macOS 15 下限可用。
- 测试：`Tests/UIFoundationTests/WelcomePanelTests.swift`（18 个，`#if WelcomePanel` 包着），要带
  `--traits WelcomePanel` 才编进来。

**RuntimeViewer 一侧**

- 启动顺序：窗口恢复由 `NSApplication.run()` 里的 open-application Apple Event
  （`-[NSApplication _handleAEOpenEvent:]`）驱动，落在 `applicationDidFinishLaunching` 之前
  （`Documentations/ResolvedIssues/2026-09-18-arm64e-variant-selected-after-window-restoration.md`，有调用栈）。
  **推测**：「要不要新开未命名文档」也在同一个事件里问 `applicationShouldOpenUntitledFile(_:)`，因此同样早于
  `applicationDidFinishLaunching`——未实测；下面的方案不依赖这个顺序。
- 设置在 `applicationDidFinishLaunching` 里异步读：`SettingsLifecycleController.loadOnLaunch()` 起一个
  `Task { await settings.load() }`（`App/SettingsLifecycleController.swift`）。所以 AppKit 问要不要开未命名文档时，
  设置多半还没读完；那一刻读到的开关值是默认值，不可信。
- 没窗口时点 Dock：`WindowLifecycleController.handleReopen(for:)` 只看文档窗口，都没有时最后一支调
  `NSDocumentController.shared.openUntitledDocumentAndDisplay(true)`（`App/WindowLifecycleController.swift:64`）。
- 最近文档：`Document` 从不存盘（`data(ofType:)`、`save` 等都被覆写成空），所以
  `recentDocumentURLs` 里只有文件模式读过的文件（`FileController` 在文件读完后登记）。用
  `NSDocumentController.shared.openDocument(withContentsOf:display:completionHandler:)` 打开它，走的是
  `DocumentController` 的覆写，交给 `FileController`，与 Open Recent 一样；文件不存在时 `FileController` 自己报错。
- 「Quit After Closing Last Window」（`Settings.General.terminatesAfterLastWindowClosed`）默认关。开着时，
  欢迎窗口若是最后一个窗口，关掉它 App 就退出——所以关欢迎窗口必须等文档窗口已经上屏。
- Attach to Process 与 Load Frameworks 都是主窗口的路由（`Main/MainCoordinator.swift:112`、`:179`），
  没有窗口就无从发起，因此不放进欢迎窗口的动作。
- 菜单：UIFoundation 有 `MainMenu.window(customizing:)`
  （`Sources/UIFoundationAppKit/Menu/MainMenu+Window.swift:40`），可以在 Zoom 之后插项；RuntimeViewer 现有
  菜单里没有 ⇧⌘1。
- App 名字：`CFBundleDisplayName` 是 `RuntimeViewer`（`Configurations/RuntimeViewerUsingAppKit/Shared.xcconfig:37`），
  而 Debug 构建的 `PRODUCT_NAME` 是 `RuntimeViewer-Debug` / `RuntimeViewer-Debug-arm64e`
  （同目录 `Debug.xcconfig:10`、`Debug-arm64e.xcconfig:10`）。组件默认取 `CFBundleName`，Debug 版标题会是后者。
- 依赖：`RuntimeViewerPackages/Package.swift:96` 的 `uiFoundationTraits` 没有 `WelcomePanel`，下限
  `from: "0.49.0"`。锁文件：`RuntimeViewer-Debug` 与 `RuntimeViewer-Distribution` 钉 0.49.0，
  `RuntimeViewer.xcworkspace` 还钉 0.47.0。Tuist 从清单推算 trait，`./TuistScript.sh check` 会报出漏补的
  trait 宏（`Documentations/Guides/TuistDevelopment.md` 第 187 行起）。
- 设置：`Settings.General` 的字段用 `@Default` 解码，旧文件缺键时取默认值；`SettingsPersistenceTests` 已有一条
  解码旧 payload 的测试（第 165 行附近），新字段在那里补一句断言即可。`general` 本身是顶层属性，
  `accessPersistedValues()` 不用改。

## 提议方案

1. **上游（UIFoundation 0.50.0）**：`WelcomePanelController.Configuration` 加
   `public var projectListPlaceholderText: String?`，`nil` 时仍是 `"No Recent Projects"`；
   `ProjectsViewController` 读它。补测试、更新 `Documentations/WelcomePanel.md`，打 tag `0.50.0`。
2. **依赖**：`uiFoundationTraits` 加 `"WelcomePanel"`，下限抬到 `from: "0.50.0"`，四个被跟踪的锁文件只抬 UIFoundation。
3. **设置**：`Settings.General.showsWelcomeWindowAtLaunch`，`@Default(true)`；设置 › 通用 › Windows 一节加开关，
   改写这一节的说明文字（Dock 点击的行为也随它）。
4. **决策**：RuntimeViewerAppCore 新增纯值类型 `WelcomeWindowPolicy`，把「这时该弹欢迎窗口、开 My Mac 窗口、
   还是等设置读完」写成可测的函数。
5. **App**：新增生命周期控制器 `WelcomeController`（`App/` 目录）——
   - 持有 `WelcomePanelController`（`.xcode26`，懒创建），自己当它的 data source（用最近文档）与 delegate
     （双击打开文件）；两个动作：New Window on My Mac（`newDocument`）、Open File…（`openDocument`）；
     标题用 `CFBundleDisplayName`，空列表文字 `No Recent Files`。
   - `shouldOpenUntitledDocument()` 回答 `applicationShouldOpenUntitledFile(_:)`：设置已读完就按开关当场决定；
     没读完就记下「启动时有一个未命名文档的请求」并先回 `false`，等 `start()` 里读完设置后再决定弹欢迎窗口
     还是开 My Mac 窗口（这时已经有文档窗口就什么都不做）。
   - `showInsteadOfUntitledDocument()` 给 Dock 点击用：开关开着就弹欢迎窗口，否则照旧开 My Mac 窗口。
   - 观察 `NSWindow.didBecomeMainNotification`：成为主窗口的是文档窗口（`windowController?.document != nil`）时，
     关掉欢迎窗口。
   - `showWindow()` 给 Window 菜单用。
6. **接线**：`AppDelegate` 加 `applicationShouldOpenUntitledFile(_:)`、`welcomeController.start()` 与
   `@objc showWelcomeWindow(_:)` 三处一行转发；`WindowLifecycleController.handleReopen(for:)` 最后一支改调
   `welcomeController.showInsteadOfUntitledDocument()`；`SettingsLifecycleController` 补 `isLoaded` 与
   `waitUntilLoaded()`；`MainMenuController` 在 Window 菜单 Bring All to Front 之前插 Welcome to RuntimeViewer（⇧⌘1）。

### 非目标

- 不做欢迎窗口里的「启动时显示」勾选框：`.xcode26` 样式没有，开关放在设置里。
- 不放 Attach to Process、Load Frameworks 等第三个动作：它们挂在主窗口上，要另想入口。
- 最近列表只有文件，不列 My Mac、设备或附加过的进程。
- 不改设置的读取时机（macOS 仍异步读）；恢复出来的窗口在设置读完前读到默认值，那是另一件事。
- 不做 iOS、visionOS：WelcomePanel 只有 macOS 版。
- 不加 Xcode 27 风格：UIFoundation 只有 `.xcode14` / `.xcode15` / `.xcode26` 三种样式。
- 欢迎窗口的位置不记忆：组件不开放窗口，每次居中。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| UIFoundation `Sources/UIFoundationAppKit/WelcomePanel/WelcomePanel+Configuration.swift` · `Configuration` | 修改 | 加 `projectListPlaceholderText: String?` 及 `init` 参数（默认 `nil`） | 空列表文字可配 | 1 |
| UIFoundation `Sources/UIFoundationAppKit/WelcomePanel/WelcomePanel+ProjectsViewController.swift` · `ProjectsViewController` | 修改 | `placeholderLabel` 的文字取 `configuration.projectListPlaceholderText ?? "No Recent Projects"` | 同上 | 1 |
| UIFoundation `Tests/UIFoundationTests/WelcomePanelTests.swift` | 修改 | 两条测试：默认文字不变、配置的文字生效 | 回归 | 1 |
| UIFoundation `Documentations/WelcomePanel.md` | 修改 | §1 的配置说明加这一项 | 文档同批 | 1 |
| `RuntimeViewerPackages/Package.swift` | 修改 | `uiFoundationTraits` 加 `"WelcomePanel"`；远端下限 `from: "0.50.0"` | 编进组件、拿到新属性 | 2 |
| `RuntimeViewer-Debug` / `-Distribution` 两个 workspace 与 `RuntimeViewerPackages`、`RuntimeViewerCommandLine` 的 `Package.resolved`（四个） | 修改 | 只把 UIFoundation 抬到 0.50.0 | 锁文件跟上下限 | 2 |
| 根 `AGENTS.md` · *Dependency floors* | 修改 | UIFoundation 下限改为 0.50.0，写明 `WelcomePanel` trait 与 `projectListPlaceholderText` | 下限的理由要留档 | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift` · `Settings.General` | 修改 | 加 `@Default(true) public var showsWelcomeWindowAtLaunch: Bool` | 开关 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/GeneralSettingsView.swift` | 修改 | Windows 一节加 Toggle「Show Welcome Window at Launch」，改写说明文字 | 开关的界面 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerSettingsTests/SettingsPersistenceTests.swift` | 修改 | 旧 payload 解码后 `showsWelcomeWindowAtLaunch == true` | 兼容旧设置文件 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/App/WelcomeWindowPolicy.swift` · `WelcomeWindowPolicy` | 新增 | 两个纯函数与 `Decision` 枚举 | 决策可测 | 4 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/WelcomeWindowPolicyTests.swift` | 新增 | 覆盖每种输入组合 | 回归 | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/SettingsLifecycleController.swift` | 修改 | 存下 load 的 `Task`；加 `isLoaded`、`waitUntilLoaded()` | 启动决策要等设置读完 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/WelcomeController.swift` · `WelcomeController` | 新增 | 持有面板、data source / delegate、启动与 Dock 决策、关窗观察、`@DependencyEntry` | 生命周期职责独立成控制器 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift` | 修改 | `@Dependency(\.welcomeController)`；`applicationShouldOpenUntitledFile(_:)`；`didFinishLaunching` 里 `welcomeController.start()`；`@objc showWelcomeWindow(_:)` | 一行转发 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/WindowLifecycleController.swift` | 修改 | 最后一支改调 `welcomeController.showInsteadOfUntitledDocument()`，doc comment 跟着改 | Dock 点击也弹欢迎窗口 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/MainMenuController.swift` | 修改 | `MainMenu.window(customizing:)`，Bring All to Front 之前插 Welcome to RuntimeViewer（⇧⌘1）与分隔线 | 随时能叫出来 | 5 |
| `RuntimeViewerUsingAppKit/AGENTS.md` · *AppDelegate and the Lifecycle Controllers* | 修改 | 控制器清单加 `WelcomeController`，写明「关欢迎窗口要等文档窗口成为主窗口」 | 规则留档 | 6 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案；落地时改编号与状态 | 索引 | 6 |

## 架构图

改了什么：

```text
UIFoundation 0.49.0 -> 0.50.0
  UIFoundationAppKit/WelcomePanel/
    WelcomePanelController.Configuration
+     projectListPlaceholderText: String?
    WelcomePanelController.ProjectsViewController
~     placeholderLabel <- projectListPlaceholderText ?? "No Recent Projects"

RuntimeViewerPackages
~ Package.swift                       uiFoundationTraits += "WelcomePanel", from: "0.50.0"
  RuntimeViewerSettings/
~   Settings.General                  + showsWelcomeWindowAtLaunch (default true)
  RuntimeViewerSettingsUI/
~   GeneralSettingsView               + Toggle "Show Welcome Window at Launch"
  RuntimeViewerAppCore/App/
+   WelcomeWindowPolicy               pure decisions, tested

RuntimeViewerUsingAppKit/App/
+ WelcomeController ──owns──> WelcomePanelController (UIFoundation, .xcode26)
│   ├─ DataSource: NSDocumentController.recentDocumentURLs
│   ├─ Delegate:   double-click -> NSDocumentController.openDocument(withContentsOf:)
│   └─ observes NSWindow.didBecomeMainNotification -> close()
~ AppDelegate                         applicationShouldOpenUntitledFile, start(), showWelcomeWindow(_:)
~ WindowLifecycleController           handleReopen: last branch -> WelcomeController
~ SettingsLifecycleController         + isLoaded, + waitUntilLoaded()
~ MainMenuController                  Window ▸ Welcome to RuntimeViewer ⇧⌘1
```

启动时的流程：

```text
NSApplication.run()
└─ open-application Apple Event
   ├─ a window restored / a file opened ──> AppKit asks nothing
   └─ AppDelegate.applicationShouldOpenUntitledFile(_:)
      └─ WelcomeController.shouldOpenUntitledDocument()
         └─ WelcomeWindowPolicy.decisionForUntitledDocumentRequest(areSettingsLoaded:showsWelcomeWindow:)
            ├─ .showWelcomeWindow     ──> showWindow(); return false
            ├─ .openUntitledDocument  ──> return true   (AppKit opens a My Mac window)
            └─ .waitForSettings       ──> hasPendingLaunchRequest = true; return false

AppDelegate.applicationDidFinishLaunching(_:)
├─ settingsLifecycleController.loadOnLaunch()
└─ welcomeController.start()
   └─ Task { await settingsLifecycleController.waitUntilLoaded()
             guard hasPendingLaunchRequest
             WelcomeWindowPolicy.decisionAfterSettingsLoaded(showsWelcomeWindow:hasDocumentWindow:)
             ├─ .showWelcomeWindow    ──> showWindow()
             ├─ .openUntitledDocument ──> openUntitledDocumentAndDisplay(true)
             └─ nil                   ──> nothing (a document window is already up) }

later: a document window becomes main ──> WelcomeController closes the panel
later: Dock click, no document window ──> WindowLifecycleController ──> showInsteadOfUntitledDocument()
```

## 详细设计

### UIFoundation

```swift
extension WelcomePanelController {
    public struct Configuration {
        // …existing fields…
        /// The text the project list shows when it has no projects. `nil` shows "No Recent Projects".
        public var projectListPlaceholderText: String?

        public init(
            style: Style = .xcode14,
            // …existing parameters, unchanged…
            tertiaryAction: Action? = nil,
            projectListPlaceholderText: String? = nil,
            checkShowOnLaunch: Bool = true
        )
    }
}
```

命名沿用同一结构里的 `welcomeLabelText` / `versionLabelText`：`nil` 取样式或组件的默认值。参数插在
`checkShowOnLaunch` 之前、带默认值，现有调用点源码兼容。只加文字，不加字体与颜色：Xcode 26 的空列表文字
没有按样式区分的字体，需要时另加。

### 设置

```swift
// Settings.General
/// Whether launching the app, and clicking its Dock icon with no window open, shows the Welcome
/// window instead of opening a new window on My Mac.
@Default(true)
public var showsWelcomeWindowAtLaunch: Bool
```

设置页 Windows 一节：

```swift
Toggle("Show Welcome Window at Launch", isOn: $settings.showsWelcomeWindowAtLaunch)
Toggle("Quit After Closing Last Window", isOn: $settings.terminatesAfterLastWindowClosed)
// footer:
// "The Welcome window lists the files you opened recently. It also shows when you click the Dock
//  icon with no window open; when it is off, a new window on My Mac opens instead. With Quit After
//  Closing Last Window on, closing the last window quits the app; otherwise the app keeps running
//  with no window open."
```

### `WelcomeWindowPolicy`（RuntimeViewerAppCore，`App/`）

```swift
public enum WelcomeWindowPolicy {
    public enum Decision: Equatable, Sendable {
        case showWelcomeWindow
        case openUntitledDocument
        case waitForSettings
    }

    /// AppKit asks whether to open an untitled document: at launch, when nothing was restored or opened.
    public static func decisionForUntitledDocumentRequest(
        areSettingsLoaded: Bool,
        showsWelcomeWindow: Bool
    ) -> Decision {
        guard areSettingsLoaded else { return .waitForSettings }
        return showsWelcomeWindow ? .showWelcomeWindow : .openUntitledDocument
    }

    /// A launch request was held back until the settings were read. `nil`: a document window came up
    /// in the meantime, so neither window is wanted.
    public static func decisionAfterSettingsLoaded(
        showsWelcomeWindow: Bool,
        hasDocumentWindow: Bool
    ) -> Decision? {
        guard !hasDocumentWindow else { return nil }
        return showsWelcomeWindow ? .showWelcomeWindow : .openUntitledDocument
    }

    /// The Dock icon was clicked with no document window to bring back.
    public static func decisionForReopen(showsWelcomeWindow: Bool) -> Decision {
        showsWelcomeWindow ? .showWelcomeWindow : .openUntitledDocument
    }
}
```

不用 ViewModel：面板是 UIFoundation 的窗口控制器、内容在构造时就定了，它没有随时间变化的状态；
会变的只有上面这几处决策，放在 AppCore 由测试驱动。`AppTargetBoundaryTests` 只拦 ViewModel，
`WelcomeController` 不受影响。

### `SettingsLifecycleController`

```swift
private(set) var isLoaded = false
private var loadTask: Task<Void, Never>?

func loadOnLaunch() {
    loadTask = Task {
        await settings.load()
        isLoaded = true
        runtimeEngineManagerSettingsFollower.startFollowing()
    }
}

/// Returns once the stored settings are read. Called after `loadOnLaunch()`.
func waitUntilLoaded() async {
    await loadTask?.value
}
```

### `WelcomeController`（App target，`App/`）

```swift
@MainActor
final class WelcomeController: NSObject {
    fileprivate static let shared = WelcomeController()

    @Dependency(\.settings) private var settings
    @Dependency(\.settingsLifecycleController) private var settingsLifecycleController

    private var hasPendingLaunchRequest = false
    private var documentWindowObservation: (any NSObjectProtocol)?

    private lazy var welcomePanel: WelcomePanelController = {
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "RuntimeViewer"
        var configuration = WelcomePanelController.Configuration(style: .xcode26)
        configuration.welcomeLabelText = applicationName
        configuration.projectListPlaceholderText = "No Recent Files"
        configuration.primaryAction = .init(
            image: SFSymbols(systemName: .plusSquare).nsImage,
            title: "New Window on My Mac",
            action: { _ in MainActor.assumeIsolated { NSDocumentController.shared.newDocument(nil) } }
        )
        configuration.secondaryAction = .init(
            image: SFSymbols(systemName: .folder).nsImage,
            title: "Open File…",
            action: { _ in MainActor.assumeIsolated { NSDocumentController.shared.openDocument(nil) } }
        )
        let panel = WelcomePanelController(configuration: configuration)
        panel.dataSource = self
        panel.delegate = self
        return panel
    }()

    /// Backs `applicationShouldOpenUntitledFile(_:)`.
    func shouldOpenUntitledDocument() -> Bool
    /// Called from `applicationDidFinishLaunching(_:)`, after `loadOnLaunch()`.
    func start()
    /// The Window menu's Welcome to RuntimeViewer.
    func showWindow()
    /// `WindowLifecycleController`'s last resort when the Dock icon is clicked.
    func showInsteadOfUntitledDocument()
}

extension WelcomeController: WelcomePanelController.DataSource { /* usesRecentDocumentURLs = true */ }
extension WelcomeController: WelcomePanelController.Delegate {
    // didDoubleClickProjectAtIndex: guard the index against recentDocumentURLs (−1 on empty space),
    // then NSDocumentController.shared.openDocument(withContentsOf:display: true) { … }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { WelcomeController.shared })
    var welcomeController: WelcomeController
}
```

- `start()` 先注册 `NSWindow.didBecomeMainNotification` 的观察（主线程队列）：`object` 是 `NSWindow`，
  `windowController?.document != nil` 时调 `welcomePanel.close()`——只有面板已经创建过才关，不为关窗去创建它。
  然后起一个 `Task`：`await settingsLifecycleController.waitUntilLoaded()`，`hasPendingLaunchRequest` 为真时按
  `decisionAfterSettingsLoaded` 执行并清掉标志。
- 判断「有没有文档窗口」用与 `WindowLifecycleController` 相同的表达式
  （`NSDocumentController.shared.documents.flatMap(\.windowControllers).compactMap(\.window)`），两处抽成一个
  `NSDocumentController` 的小扩展，免得各写一份。
- 关窗等文档窗口成为主窗口，而不是在 `addDocument` 或 `makeWindowControllers` 里关：那时文档窗口还没上屏，
  开着「Quit After Closing Last Window」时，关掉唯一的窗口 App 就会退出。
- 打开文件出错时 `openDocument(withContentsOf:)` 的 completion 里不再报一次：`FileController` 已经报过。
- 两个动作的图标是 Xcode 欢迎窗口用的 SF Symbol：`plus.square`（Xcode 的 Create New Project…）与 `folder`
  （决策日志 2026-11-21「动作图标」一行）。

### `AppDelegate`

```swift
@Dependency(\.welcomeController) private var welcomeController

func applicationDidFinishLaunching(_ aNotification: Notification) {
    // …
    settingsLifecycleController.loadOnLaunch()
    welcomeController.start()
    // …
}

func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
    welcomeController.shouldOpenUntitledDocument()
}

@objc func showWelcomeWindow(_ sender: Any?) {
    welcomeController.showWindow()
}
```

三处都是一行转发，符合 `RuntimeViewerUsingAppKit/AGENTS.md` 对 `AppDelegate` 的约束。

### 菜单

```swift
MainMenu.window { builder in
    builder.insertItems(before: .Window.bringAllToFront) {
        NSMenuItem(
            "Welcome to RuntimeViewer",
            action: #selector(AppDelegate.showWelcomeWindow(_:)),
            keyEquivalent: "1",
            modifiers: [.command, .shift],
        )
        NSMenuItem.separator()
    }
}
```

插在 Bring All to Front 之前、自带一条分隔线，菜单读作 Minimize、Zoom、—、Welcome to RuntimeViewer、—、
Bring All to Front，与 Xcode 里 Welcome to Xcode 所在的那一组位置相同。

## 替代方案考量

- **启动照旧开 My Mac 窗口，欢迎窗口只从 Window 菜单打开**：用户选了取代；照旧的话欢迎窗口几乎没人会见到。
- **把 macOS 的设置改成同步读、挪到 `applicationWillFinishLaunching`**：能让启动时的判断直接读开关，省掉
  「先记下、读完再决定」。但这改的是整个 App 读设置的时机，牵动恢复窗口与所有读设置的地方，是另一件事；
  这里只等这一处。
- **在 RuntimeViewer 里自己写欢迎窗口**：UIFoundation 已经有逐值实测的 Xcode 26 复刻，重写只会做出一份更差的。
- **照现状显示「No Recent Projects」**：用户选了先改上游。
- **用 `.xcode14` 样式换来窗口里的勾选框**：那是 Xcode 14 的外观，与 App 其余照 Xcode 26 / 27 做的界面不一致；
  开关放设置里。
- **在 `DocumentController.addDocument(_:)` 或 `Document.makeWindowControllers()` 里关欢迎窗口**：那时文档窗口
  还没上屏，开着「Quit After Closing Last Window」会让 App 直接退出。
- **给欢迎窗口配 ViewModel 与 coordinator**：面板的内容在构造时定死、没有随时间变化的状态，ViewModel 无事可做；
  会变的决策放进 AppCore 的 `WelcomeWindowPolicy` 测试。

## 影响

### 用户可见变化

- 启动时（没有恢复窗口、也没打开文件时）弹欢迎窗口，不再自动开 My Mac 窗口。要原来的窗口：点
  New Window on My Mac、按 ⌘N，或在设置 › 通用里关掉「Show Welcome Window at Launch」回到原样。
- 没有文档窗口时点 Dock 图标，同样弹欢迎窗口（开关关掉则照旧开 My Mac 窗口）。
- Window 菜单新增 Welcome to RuntimeViewer（⇧⌘1）。
- 设置 › 通用 › Windows 新增一个开关，这一节的说明文字改写。
- 从 Finder 或 Dock 拖文件打开、恢复窗口时，不出现欢迎窗口。

### 可发现性

默认开：它取代的是启动后的第一个窗口，用户一启动就能看到。理由：它把文件模式与最近文件摆上第一屏，
而回到原样只要 ⌘N 或一个开关。

### 数据与配置兼容

新设置键 `general.showsWelcomeWindowAtLaunch`，旧设置文件没有这个键，解码时取默认值 `true`，不需要迁移。
设置文件的位置不变。最近文档仍是系统的 Open Recent，一份数据两处显示。

### 平台与最低版本

只涉及 macOS App，最低版本不变（macOS 15）。`.xcode26` 样式只用公开 API，macOS 15、26、27 上外观一致；
iOS、visionOS 不受影响（设置模型里多一个字段，iOS 的设置页不显示它）。

### 发布

不需要新权限、entitlement 或隐私清单条目，不影响公证与 Sparkle。发版说明写一句「启动时显示欢迎窗口，
可在设置 › 通用里关掉」。UIFoundation 要先发 0.50.0，RuntimeViewer 的 Distribution 锁文件随之更新。

## 落地步骤

1. ✅ **UIFoundation：空列表文字可配，发 0.50.0** —— 改动地图 UIFoundation 四行
   - 行为：`placeholderTextDefaultsToNoRecentProjects`
   - 行为：`placeholderTextComesFromConfiguration`
   - 测试带 `--traits WelcomePanel` 跑；会开窗口的测试放到另一台机器上跑（本机是 Ultra 就用 MacBook）。
     打 tag `0.50.0` 并推送。
2. ✅ **RuntimeViewer 打开 trait、抬下限** —— `Package.swift`、四个锁文件（两个 workspace 与 Packages、CommandLine 两个包；`RuntimeViewer.xcworkspace` 的锁文件不进仓库）、根 `AGENTS.md`
   - 行为：包与 App 都能编，`WelcomePanelController` 可见；`./TuistScript.sh check` 通过。
3. ✅ **设置开关** —— `Settings+Types.swift`、`GeneralSettingsView.swift`、`SettingsPersistenceTests.swift`
   - 行为：`welcomeWindowSwitchRoundTrips`（默认开、关掉后存取不丢）
   - 行为：`legacyPayloadDecoding` 补一句（旧文件没有这个键时为开）
4. ✅ **决策** —— `WelcomeWindowPolicy` 与测试
   - 行为：`untitledRequestBeforeSettingsLoadWaits`
   - 行为：`untitledRequestShowsWelcomeWindowWhenEnabled`
   - 行为：`untitledRequestOpensUntitledDocumentWhenDisabled`
   - 行为：`heldLaunchRequestDoesNothingOnceADocumentWindowIsUp`
   - 行为：`heldLaunchRequestFollowsTheLoadedSetting`
   - 行为：`reopenFollowsTheSetting`
5. ✅（代码与构建；目视验收待用户）**App 接线** —— `SettingsLifecycleController`、`WelcomeController`、`AppDelegate`、`WindowLifecycleController`、
   `MainMenuController`
   - 行为（App 构建通过；以下由用户在 App 里目视验收）：
     - 启动弹欢迎窗口；关掉开关后重启，开的是 My Mac 窗口。
     - 双击最近文件打开它，欢迎窗口随之关闭；列表为空时显示 No Recent Files。
     - New Window on My Mac、Open File… 两个动作；打开任何文档窗口后欢迎窗口关闭。
     - 关掉所有窗口后点 Dock 弹欢迎窗口；⇧⌘1 随时打开。
     - 开着「Quit After Closing Last Window」时，从欢迎窗口打开文件不会让 App 退出。
6. ✅（取号与 Implemented 留给收尾）**文档** —— `RuntimeViewerUsingAppKit/AGENTS.md`、两份索引；落地时取号、状态改 Implemented

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、
  代码本身看不出来的决策」就写实现说明。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 有就同批次登记进术语表。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-21 | Created as Draft | 用户要接入 UIFoundation 的欢迎窗口。 |
| 2026-11-21 | 启动与 Dock 点击都改弹欢迎窗口，设置里可关 | 用户选择照 Xcode，用欢迎窗口取代启动时自动打开的 My Mac 窗口；开关默认开。 |
| 2026-11-21 | 空列表文字先改上游 | 用户选择先给 UIFoundation 加可配置的占位文字并发版，不在 RuntimeViewer 里将就「No Recent Projects」。 |
| 2026-11-21 | 只放两个动作；用 `.xcode26` 样式；不配 ViewModel | 未询问用户的默认决定：Attach 与 Load Frameworks 挂在主窗口上；样式与 App 其余界面一致；会变的决策放进 AppCore 的 `WelcomeWindowPolicy` 测试。UIFoundation 一侧只加一个可选属性，不另写提案，记在它的 `WelcomePanel.md` 与发版说明里。 |
| 2026-11-21 | Accepted | 用户批准，开始实现。 |
| 2026-11-21 | 动作图标用 `plus.square` 与 `folder` | 偏离提案：原定第一个动作用来源选择器给 My Mac 的设备字形。那要在建面板时经 `RuntimeEngineIconProvider` 碰引擎管理器，字形还带自己的配色；改用 Xcode 欢迎窗口自己的符号（Create New Project… 的 `plus.square`），与 Xcode 一致。 |
| 2026-11-21 | Welcome to RuntimeViewer 放在 Bring All to Front 之前 | 偏离提案：原定插在 Zoom 之后。放在 Bring All to Front 之前、前后各一条分隔线，与 Xcode 里 Welcome to Xcode 所在的那一组位置相同。 |
| 2026-11-21 | `Tuist.swift` 缺 `SwiftSectionTestingMacros` 不在本分支修 | `./TuistScript.sh check` 报这一项，trait 的比对通过。缺项来自 next 上已有的 MachOSwiftSection pin（C++ 对象那次合并抬到的提交带了这个新 target），与本提案无关，留给 next 上处理。 |
| 2026-11-21 | 设置测试改为一条往返测试加一句旧文件断言 | 原列的两个用例名合并成 `welcomeWindowSwitchRoundTrips` 与 `legacyPayloadDecoding` 里的一句，覆盖的行为不变。 |
| 2026-11-21 | 实现完成，待用户看过后收尾 | 包级测试与 Tuist 的 App 构建通过；目视验收交给用户。文档判断：不另写使用指南或实现说明，决策与约束已写进 `RuntimeViewerUsingAppKit/AGENTS.md`（`WelcomeController` 一条）与本提案；没有新术语。 |

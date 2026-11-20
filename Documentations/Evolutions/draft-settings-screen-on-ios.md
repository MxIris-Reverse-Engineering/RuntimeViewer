# Draft - iOS 上的设置页

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-20
- **最后更新**: 2026-11-21
- **所属愿景**: [iOS 版功能对齐](../Visions/IOSFeatureParity.md)（第五步「iOS 前端逐项补齐」里的设置页，提前做）
- **关联提案**: [0100-settings-storage-on-ios](0100-settings-storage-on-ios.md)（iOS 上的设置已经存盘）；上游 UIFoundation 的 [0043-settings-ui-on-ios](https://github.com/Mx-Iris/UIFoundation/blob/main/Documentations/Evolutions/0043-settings-ui-on-ios.md)（写页面的组件放开到 iOS，加 iOS 宿主，已随 0.49.0 发布）
- **实现分支 / PR**: `feature/settings-screen-on-ios`
- **配套文档**: 待定 —— 预计无单独文档，规则写进 `RuntimeViewerUsingUIKit/AGENTS.md`
- **网页版**: 同目录同名的 `.html`

## 摘要

iOS、越狱版 iOS 与 visionOS 的 RuntimeViewer 有了设置页：侧栏右上角一个齿轮按钮，点开弹出设置，列着**外观**（跟随系统 /
浅色 / 深色）、**主题**（字号、配色方案与自定义颜色）、**转换选项**（生成接口时的类型与偏移写法）三页。页面复用 Mac 版的
SwiftUI 代码，只把 Mac 专属的几处换成两边都能用的写法（转换选项页的模板编辑器另写一份 UIKit 版）；宿主是上游 UIFoundation
新增的 iOS 设置界面。顺带两处让设置在 iOS 上真正生效：内容区改为跟随设置里的主题（现在固定用默认主题），外观设置作用到
App 的所有窗口。Mac 版不变。

## 动机

完整动机见愿景《[iOS 版功能对齐](../Visions/IOSFeatureParity.md)》。这一步特有的：

- **iOS 上没有任何改设置的地方**：0100 让设置能存盘了，但 iOS App 里没有入口，用户也就看不到任何变化；用户要先看到界面
  再验收这条线上的工作，所以把愿景第五步里的设置页提前。
- **只放 iOS 上现在起作用的页**：iOS 上会读设置的只有内容区的主题、生成接口的转换选项（`ViewModel.currentMergedGenerationOptions`，
  `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Base/ViewModel.swift:55`）；外观是用户点名要的，需要在 iOS 上新接。
  索引、搜索、文件、MCP、更新、helper 等页在 iOS 上没有对应功能，放进来只会让人困惑。
- **主题在 iOS 上其实还没生效**：`ContentTextRenderer` 在 macOS 之外默认用 `ResolvedTheme.fallback`
  （`RuntimeViewerPackages/Sources/RuntimeViewerAppUI/Content/ContentTextRenderer.swift:41-56`），因为 `ResolvedThemeStream`
  只在 AppKit 上编（`Theme/ResolvedThemeStream.swift:1`）——当初 iOS 没有存下来的设置，跟随也没意义。0100 之后理由不在了。

## 前期调研

- **现有的三页**（`RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/`，整份文件包在 `#if os(macOS)` 里）：
  - `GeneralSettingsView.swift`（153 行）：外观一节用 `AppearancePicker`（三张缩略图，资源在本 target 的 `Assets.xcassets`），
    其余三节（工具栏样式、关最后一个窗口时退出、侧栏展开深度）只属于 Mac。
  - `ThemeSettingsView.swift`（436 行）：字号 `Stepper`、预设列表、颜色编辑（`ColorPicker`）都是 SwiftUI；唯一的 AppKit 用法是
    `ColorValue.from(_:)` 用 `NSColor(color).usingColorSpace(.sRGB)` 取分量（`:405-428`）。
  - `TransformerSettingsView.swift`（1045 行）：各模块的编辑器是 SwiftUI；AppKit 部分是模板编辑器——`TokenTextAttachmentCell`
    把 `${名字}` 画成强调色胶囊、`TokenTemplateTextView`（`NSTextView` 子类）输入时把占位符换成胶囊、读回时还原
    （`:277-529`），以及 `CopyableTokenChip` 用 `NSPasteboard` 复制（`:531-568`）。`FlowLayout`（`:1005`）是 SwiftUI `Layout`。
- **上游**：这些页写在 `@AppSettings`、`SettingsForm` 上，二者与 `SettingsPage` 只在 macOS 上有；上游提案
  0043 把它们放开到 iOS、Catalyst、visionOS，并新增 `SettingsViewController`（UIKit 宿主），已随 0.49.0 发布（2026-11-20）。
- **依赖声明**：`RuntimeViewerSettingsUI` 只在 AppKit 平台依赖 `UIFoundationSettingsUI`（`RuntimeViewerPackages/Package.swift:424`）；
  `RuntimeViewerAppUI` 只在 AppKit 平台依赖 `RuntimeViewerSettingsUI`（`:486`）。iOS App 链接的是门面 `RuntimeViewerApplication`
  （`RuntimeViewerUsingUIKit.xcodeproj/project.xcproj:104-106`），它再导出 AppUI。
- **iOS App 的结构**：`MainCoordinator`（`RuntimeViewerUsingUIKit/.../Main/MainCoordinator.swift`）管一个双栏
  `UISplitViewController`，`MainRoute` 在 App target 里；侧栏是 `SidebarCoordinator` 的导航控制器，根页
  `SidebarRootViewController`；`SidebarCoordinator` 通过 `SidebarCoordinatorDelegate` 把完成的路由报给 `MainCoordinator`。
  iOS 的内容区 `ContentTextViewController` 用 `ContentTextRenderer` 的 `renderedText`，不设背景色（Mac 的内容区按主题设背景，
  `RuntimeViewerUsingAppKit/.../Content/ContentTextViewController.swift:181-183`）。
- **Mac 的外观**：`AppearanceController`（`RuntimeViewerUsingAppKit/.../App/AppearanceController.swift`）用
  `SwiftNavigation.observe` 跟随 `settings.general.appearance`，设 `NSApp.appearance`。iOS 上对应的是每个窗口的
  `overrideUserInterfaceStyle`。
- **`ResolvedTheme` 本身跨平台**：`ThemeProfile.swift`、`ThemePreset+ThemeProfile.swift` 只把 import 分平台，`ResolvedTheme(settings:)`
  在 iOS 上就有，颜色是 `NSUIColor`，按 trait 自动取浅色或深色。

## 提议方案

1. **上游先落地**：UIFoundation 的 0043 已随 0.49.0 发布；RuntimeViewer 下限抬到 `from: "0.49.0"`，
   `RuntimeViewerSettingsUI` 在所有平台依赖 `UIFoundationSettingsUI`，`RuntimeViewerAppUI` 在所有平台依赖 `RuntimeViewerSettingsUI`。
2. **三页能在 iOS 上编**（`RuntimeViewerSettingsUI`）：
   - `AppSettings.swift` 去掉平台条件。
   - 外观：`AppearancePicker` 与它的选项视图挪进新文件 `AppearanceSettingsSection.swift`（各平台），Mac 的 `GeneralSettingsView`
     用它、其余三节不变且仍只在 macOS；iOS 用新的 `AppearanceSettingsView`（`SettingsForm` 里只放这一节）。
   - 主题：`ThemeSettingsView` 放开；`ColorValue.from(_:)` 在 macOS 上原样走 `NSColor`，在 UIKit 上走 `UIColor(color)` 转到 sRGB。
   - 转换选项：`TransformerSettingsView` 放开；模板编辑器分平台——AppKit 的原样留着，UIKit 上新写 `UITextView` 版（同样把
     `${名字}` 显示成胶囊、读回时还原、随内容长高）；复制按钮按平台用 `NSPasteboard` 或 `UIPasteboard`。
   - 新增 `SettingsViewController.swift`（iOS、visionOS）：继承上游 `SettingsViewController`，三页：外观、主题、转换选项。
3. **内容区跟随主题**：`ResolvedThemeStream` 去掉 AppKit 条件，`ContentTextRenderer` 在所有平台默认用它；iOS 的
   `ContentTextViewController` 按主题设文字视图的背景色。
4. **外观作用到窗口**：iOS App 新增 `AppearanceController`（与 Mac 的同名、同样在 `@Dependency` 后面），跟随
   `settings.general.appearance` 给每个窗口设 `overrideUserInterfaceStyle`；`SceneDelegate` 建窗口时先套一次当前设置。
5. **入口**：`SidebarCoordinator` 给侧栏根页的导航栏加齿轮按钮，按下经 `SidebarCoordinatorDelegate` 告诉 `MainCoordinator`；
   `MainRoute` 加 `.settings`，以 sheet 弹出 `SettingsViewController`。
6. **文档**：`RuntimeViewerUsingUIKit/AGENTS.md` 加「设置页与外观」一节；根 `AGENTS.md` 的 *Settings Integration* 那句
   「设置界面在别的平台由 App 自己做」改成 iOS 用上游的宿主，*Dependency floors* 补 0.49.0；愿景表与两份索引登记本篇。

### 非目标

- **其余设置页**（通用里的 Mac 专属三节、编辑器、通知、索引、搜索、文件、MCP、更新、helper、开发者）：等对应功能到 iOS 时再加。
- **iPad 的双栏设置**：用上游的单栏导航栈，iPad 上以 sheet 弹出。
- **Mac 版任何变化**：页面在 macOS 上的内容与行为不变，`GeneralSettingsView` 只是把外观一节挪进共用文件。
- **把 iOS 的 `MainRoute`、`MainViewModel` 并进 AppCore**：愿景第三步做；本篇照现在 iOS App 的结构加一个路由。
- **iOS 设置的单元测试替身与 UI 测试**：iOS App 没有测试 target。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerPackages/Package.swift` | 修改 | UIFoundation `from: "0.49.0"`；`RuntimeViewerSettingsUI` → `UIFoundationSettingsUI`、`RuntimeViewerAppUI` → `RuntimeViewerSettingsUI` 去掉平台条件 | iOS 要链接设置页 | 1 |
| 四份 `Package.resolved`（Debug、Distribution workspace，Packages、CommandLine 包） | 修改 | 只改 UIFoundation 一条 pin 到 0.49.0 | 跟着下限 | 1 |
| `RuntimeViewerSettingsUI/AppSettings.swift` | 修改 | 去掉 `#if os(macOS)` | 页面在 iOS 上也用 | 2 |
| `RuntimeViewerSettingsUI/Components/AppearanceSettingsSection.swift` | 新增 | `AppearanceSettingsSection`（外观一节）、`AppearancePicker`、选项视图，从 `GeneralSettingsView` 挪来 | 两边共用 | 2 |
| `RuntimeViewerSettingsUI/Components/GeneralSettingsView.swift` | 修改 | 外观一节改用 `AppearanceSettingsSection`；文件仍只在 macOS | Mac 不变 | 2 |
| `RuntimeViewerSettingsUI/Components/AppearanceSettingsView.swift` | 新增 | iOS 的外观页：`SettingsForm { AppearanceSettingsSection() }` | iOS 只要这一节 | 2 |
| `RuntimeViewerSettingsUI/Components/ThemeSettingsView.swift` | 修改 | 去掉平台条件；`ColorValue.from(_:)` 分平台 | iOS 上编 | 2 |
| `RuntimeViewerSettingsUI/Components/TransformerSettingsView.swift` | 修改 | 去掉平台条件；AppKit 的模板编辑器与复制分支留在 `#if os(macOS)` | iOS 上编 | 2 |
| `RuntimeViewerSettingsUI/Components/TokenTemplateTextField+UIKit.swift` | 新增 | UIKit 版模板编辑器：`UITextView` 子类、胶囊附件、`UIViewRepresentable` 包装 | iOS 上的同等功能 | 2 |
| `RuntimeViewerSettingsUI/SettingsViewController.swift` | 新增 | iOS 的设置宿主子类，三页；`public` | 入口打开的就是它；iOS App 在包外 | 2 |
| `RuntimeViewerSettingsUI/SettingsWindowController.swift` | 修改 | 整个文件包进 `#if os(macOS)` | 以前 iOS 不编这个模块，它从没需要过条件 | 2 |
| `RuntimeViewerSettingsUI/Components/TokenTemplatePlaceholder.swift` | 新增 | 找 `${名字}`、名字与占位符互转、算光标位置 | UIKit 编辑器用；规则与 AppKit 编辑器一致，在 macOS 上可测 | 2 |
| `Tests/RuntimeViewerAppUITests/TokenTemplatePlaceholderTests.swift`（及 `Package.swift` 里 AppUI 测试对 `RuntimeViewerSettingsUI` 的依赖） | 新增 | 占位符规则的测试 | 两个平台的编辑器要读出同样的模板 | 2 |
| `Tests/RuntimeViewerAppCoreTests/CrossPlatformSourceGuardTests.swift` | 修改 | 扫描范围加 `RuntimeViewerSettingsUI`；自检名单的 `UIFoundationSettingsUI` 换成 `RuntimeViewerHelperClient` | 前者现在 iOS 也编；后者不再是 macOS 专属 | 2 |
| `RuntimeViewerAppUI/Theme/ResolvedThemeStream.swift` | 修改 | 去掉 AppKit 条件 | iOS 内容区跟随主题 | 3 |
| `RuntimeViewerAppUI/Content/ContentTextRenderer.swift` | 修改 | 默认主题在各平台都取 `resolvedThemeStream` | 同上 | 3 |
| `RuntimeViewerUsingUIKit/.../Content/ContentTextViewController.swift` | 修改 | 按 `renderer.theme` 设背景色；改掉「固定用默认主题」的注释 | 深色主题下背景要跟着变 | 3 |
| `RuntimeViewerUsingUIKit/.../App/AppearanceController.swift` | 新增 | 跟随外观设置，设所有窗口的 `overrideUserInterfaceStyle` | 外观页生效 | 4 |
| `RuntimeViewerUsingUIKit/.../App/AppDelegate.swift` | 修改 | 读完设置后启动 `AppearanceController` | 同上 | 4 |
| `RuntimeViewerUsingUIKit/.../App/SceneDelegate.swift` | 修改 | 新窗口先套当前外观 | 后开的窗口也对 | 4 |
| `RuntimeViewerUsingUIKit/.../Sidebar/SidebarCoordinator.swift` | 修改 | 根页导航栏加齿轮按钮；`SidebarCoordinatorDelegate` 加「要打开设置」 | 入口 | 5 |
| `RuntimeViewerUsingUIKit/.../Main/MainCoordinator.swift` · `MainRoute` | 修改 | 加 `.settings`，以 sheet 弹出设置 | 入口 | 5 |
| `RuntimeViewerUsingUIKit/AGENTS.md`、根 `AGENTS.md`、愿景、两份索引 | 修改 | 见方案第 6 条 | 文档 | 6 |

## 架构图

```text
RuntimeViewerAppUI ──(every platform now)──▶ RuntimeViewerSettingsUI ──(every platform now)──▶ UIFoundationSettingsUI (0.49.0)
                                                │
   macOS (unchanged)                            │   iOS / visionOS (new)
   SettingsWindowController (12 pages)          │   SettingsViewController : UIFoundationSettingsUI.SettingsViewController
     General ── AppearanceSettingsSection ◀─────┼──── Appearance ── AppearanceSettingsSection
     Theme ─────────── ThemeSettingsView ◀──────┼──── Theme
     Transformer ── TransformerSettingsView ◀───┼──── Transformer
                         TokenTemplateTextField │        TokenTemplateTextField
                         (NSTextView)           │        + (UITextView)
```

```text
iOS app
  SidebarRootViewController.navigationItem  + gear button
    └─ SidebarCoordinator ─delegate▶ MainCoordinator.trigger(.settings)
                                       └─ present(SettingsViewController(), .pageSheet)
  AppDelegate: loadOnLaunch() → + appearanceController.start()
    AppearanceController: observe settings.general.appearance → window.overrideUserInterfaceStyle (every scene)
  ContentTextViewController
    ContentTextRenderer(themes: - .just(.fallback)  + resolvedThemeStream)   → text colours, font, + background
```

## 详细设计

```swift
// RuntimeViewerSettingsUI/SettingsViewController.swift
#if os(iOS) || os(visionOS)
import UIFoundationSettingsUI

package final class SettingsViewController: UIFoundationSettingsUI.SettingsViewController {
    package init() {
        super.init(title: "Settings") {
            SettingsPage("Appearance", id: "appearance", plainSymbol: "circle.lefthalf.filled") {
                AppearanceSettingsView()
            }
            SettingsPage("Theme", id: "theme", plainSymbol: "paintpalette") {
                ThemeSettingsView()
            }
            SettingsPage("Transformer", id: "transformer", plainSymbol: "arrow.triangle.2.circlepath") {
                TransformerSettingsView()
            }
        }
    }
}
#endif
```

```swift
// RuntimeViewerUsingUIKit/.../App/AppearanceController.swift
@MainActor
final class AppearanceController {
    fileprivate static let shared = AppearanceController()
    @Dependency(\.settings) private var settings
    private var observeToken: ObserveToken?

    func start()                         // observe settings.general.appearance → apply to every window
    func apply(to window: UIWindow)      // window.overrideUserInterfaceStyle = .unspecified / .light / .dark
}
```

- **主题页的取色**：iOS 上 `UIColor(color)` 先 `cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, …)`，转不了就返回
  `nil`（与 macOS 一样，不覆盖原值）。macOS 分支一个字不改。
- **UIKit 模板编辑器**：`NSTextAttachment` 的 `image` 用 `UIGraphicsImageRenderer` 画胶囊（与 AppKit 版同样的字体、内边距、
  强调色 15% 底色），附件子类记住名字；`textViewDidChange` 时把新出现的 `${名字}` 换成附件、保持光标；读回时把附件换回
  `${名字}`；高度取 `contentSize.height` 回报给 SwiftUI。
- **主题流在 iOS 上**：`ResolvedThemeStream` 里只读 `SettingsAccess`（主线程）与 `ResolvedTheme(settings:)`，没有 AppKit 调用；
  订阅都在主线程，与 macOS 相同。

## 替代方案考量

- **RuntimeViewer 自己写 iOS 版的三页、上游不动**：用户选了复用，两套界面代码改一项要改两处。
- **iOS 上把模板编辑器换成普通文本框**：胶囊是这页的主要价值，降级会让 iOS 版难用；UIKit 版不到两百行。
- **入口放到系统「设置」App（Settings.bundle）**：只能放简单的开关，放不下主题编辑与模板编辑器。
- **外观只作用到当前窗口**：设置是全局的，多窗口时会不一致。

## 影响

### 用户可见变化

- iOS、越狱版 iOS 与 visionOS：侧栏右上角多一个齿轮按钮，点开是设置（外观、主题、转换选项三页）。
- 内容区的字号、配色从此跟随设置里的主题，默认主题仍是 Xcode 预设、13 号字，所以没改过设置的人看到的与现在相同
  （背景色会按主题变——深色模式下背景跟着主题的深色背景）。
- 外观设成浅色或深色后，App 不再跟随系统。
- Mac 版：无变化。

### 可发现性

齿轮按钮是 iOS App 的惯例位置；三页的默认值都与现状一致，不改设置就没有变化。

### 数据与配置兼容

读写的是 0100 起已存盘的同一份 `settings.json`，不新增键。

### 平台与最低版本

最低版本不变（RuntimeViewerPackages：iOS 18、visionOS 2，高于上游要求的 17 / 1）。iOS 与越狱版行为相同；visionOS 同一套代码，
外观在 visionOS 上的表现以系统为准。

### 发布

不需要新的权限或 entitlement；不影响公证与 Sparkle。UIFoundation 要先发 0.49.0。

## 落地步骤

0. **上游先落地**（已完成）—— UIFoundation 的 0043 合进 `main` 并打 0.49.0
1. **依赖**（已完成）—— `Package.swift`、四份锁文件
   - 行为：`settingsUIPackageResolvesUIFoundation049`
2. **三页能在 iOS 上编**（已完成）—— `RuntimeViewerSettingsUI` 的各行
   - 行为：`macSettingsPagesUnchanged`（`RuntimeViewerSettingsTests` 与 macOS App 构建照过）
   - 行为：`settingsUIBuildsForIOSAndVisionOS`（三个 iOS 系 App 编过，它们都编这个模块）
   - 行为：`tokenTemplateRoundTripsPlaceholders`（占位符换胶囊再读回不变——把转换逻辑抽成两边共用、可在 macOS 上测的函数）
   - 行为：`colorValueFromColorRoundTripsSRGB`（macOS 上测共用的部分）
3. **内容区跟随主题**（已完成）—— `ResolvedThemeStream`、`ContentTextRenderer`、iOS `ContentTextViewController`
   - 行为：`rendererDefaultsToTheSettingsThemeOnEveryPlatform`
4. **外观**（已完成）—— `AppearanceController`（iOS）、`AppDelegate`、`SceneDelegate`
   - 行为：`iOSAppBuildsForAllThreeTargets`
5. **入口**（已完成，设备上待用户看）—— `SidebarCoordinator`、`MainCoordinator`
   - 行为：`gearButtonOpensSettings`（由用户在设备上看）
   - 行为：`editingThemeChangesTheContentPane`、`appearanceOverridesTheSystemStyle`、`settingsSurviveRelaunch`（由用户在设备上看）
6. **文档**（已完成）—— 见改动地图最后一行

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：规则写进 `RuntimeViewerUsingUIKit/AGENTS.md`。
- **有没有引入新术语** —— 预计没有。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-20 | Created as Draft | 用户要先看到 iOS 的界面再验收，把愿景第五步里的设置页提前 |
| 2026-11-20 | 用户选定：外观、主题、转换选项三页 | 主题与转换选项是 iOS 上现在会读的设置；外观是用户点名加的，要在 iOS 上新接 |
| 2026-11-20 | 用户选定：复用现有页面，上游一起放开 | 照愿景「设置页复用 SwiftUI 页面、宿主换成 UIKit」，不在下游另写一套 |
| 2026-11-20 | 自定：入口是侧栏右上角的齿轮按钮，sheet 弹出 | iOS App 的惯例位置 |
| 2026-11-20 | 自定：内容区跟随设置里的主题、按主题设背景 | 主题页要生效；原来 iOS 固定用默认主题，只因当时没有存下来的设置 |
| 2026-11-20 | 自定：模板编辑器写 UIKit 版，不降级为普通文本框 | 胶囊是这页的主要价值 |
| 2026-11-20 | 用户批准，开始实现 | 与上游 UIFoundation 的提案一起批准；上游已落地为 0043 并发布 0.49.0，本篇接着做 |
| 2026-11-21 | 实现中的调整 | 一、`SettingsWindowController.swift` 原来没有平台条件——以前 iOS 根本不编 `RuntimeViewerSettingsUI`；现在 AppUI 在各平台都依赖它，这个文件包进 `#if os(macOS)`。二、RV 的 iOS `SettingsViewController` 是 `public`：iOS App 在包外，`package` 看不到（macOS 的设置窗口经 AppUI 的 `appRouter` 打开，所以那边是 `package`）。三、占位符规则抽成 `TokenTemplatePlaceholder` 给 UIKit 编辑器用，AppKit 编辑器原样留着自己那份（Mac 行为一字不动），两边按同样的规则取名字；测试放在 `RuntimeViewerAppUITests`（为此给它加了对 `RuntimeViewerSettingsUI` 的依赖），变异检查（让 `caretLocation` 原样返回）使 2 处断言变红。四、`CrossPlatformSourceGuardTests` 的扫描范围加上 `RuntimeViewerSettingsUI`，自检名单换掉不再是 macOS 专属的 `UIFoundationSettingsUI`。五、外观一节在 iOS 上把「Appearance」放到节标题、三张缩略图占满一行：iPhone 一行放不下标签加三张图。六、`rendererDefaultsToTheSettingsThemeOnEveryPlatform` 与 `colorValueFromColorRoundTripsSRGB` 没写成测试：前者现在是不分平台的同一行代码；后者的 UIKit 分支只在 iOS 上编，macOS 的测试跑不到——两者由三个 iOS 系 App 的构建与用户在设备上看来验证。 |
| 2026-11-21 | 实现完成，待用户看过后收尾 | 验证都在 Ultra 上：`RuntimeViewerSettingsTests` 71 个、`TokenTemplatePlaceholderTests` 5 个、`CrossPlatformSourceGuardTests` 与 `AppCoreBoundaryTests` 全过；`RuntimeViewer iOS`（iOS 模拟器）、`RuntimeViewer iOS Jailbroken`（iOS 真机）、`RuntimeViewer visionOS`（visionOS 模拟器）用 Debug workspace 编过；macOS App 用 Tuist workspace（Debug）编过。打了越狱版安装包给用户在 vphone 上看。没做的：设备上的四条行为（齿轮打开设置、改主题内容区跟着变、外观盖过系统、重启后设置还在）由用户看；会开窗口的 AppUI 测试没在这台 Mac 上跑。文档判断：规则写进 `RuntimeViewerUsingUIKit/AGENTS.md` 的「Settings screen and appearance」，根 `AGENTS.md` 改了 *Settings Integration*、*Dependency floors* 与规则表一行；不另写使用指南或实现说明，没有新术语。 |

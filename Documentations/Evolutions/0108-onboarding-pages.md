# 0108 - 首次启动欢迎页与更新后的 What's New（接入 swift-onboardingkit）

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-11-24
- **最后更新**: 2026-11-25
- **所属愿景**: 无
- **关联提案**: [0105 欢迎窗口](0105-welcome-window.md)（同在启动时出现的另一个窗口，它在前时本提案的页面显示在它前面）
- **实现分支 / PR**: `feature/onboarding-pages`（已合进 `next`）
- **配套文档**: 无 —— 规则在 `RuntimeViewerUsingAppKit/AGENTS.md`，框架行为在 swift-onboardingkit 的实现说明（见决策日志 2026-11-24「落地」）
- **网页版**: 同目录同名的 `.html`

## 摘要

macOS App 接入 swift-onboardingkit（Apple 私有框架 OnBoardingKit 的 Swift 封装，App Store、Freeform、Shortcuts 的欢迎页与 "What's New" 页就是它画的），做两种一次性页面：新用户第一次启动时的**欢迎页**（RuntimeViewer 能做什么），以及升级到新的功能版本（`主版本.次版本`）后第一次启动时的 **What's New 页**（这一版的新功能）。页面在文档窗口上是 sheet；0105 的欢迎窗口在前时（它是无边框窗口、不会成为主窗口），页面放在一个独立窗口里显示在它前面。点 Continue 关闭并记下「已看过这一版」；Help 菜单新增 What's New in RuntimeViewer，随时可再看。「这次启动该弹哪一页」由 RuntimeViewerAppCore 判断（可单测），页面内容是 AppCore 里的值，由 RuntimeViewerAppUI 画成 OnBoardingKit 的模板，App 里一个新的启动控制器负责弹出。swift-onboardingkit 改为公开仓库、改成弱链接私有框架后发布 `0.1.0`，修 0 × 0 页面时再发 `0.1.1`（容器自己定好尺寸），再发 `0.2.0`（页面值 `OBTemplatePage`，由库组装成控制器）、`0.2.1`（功能行图标的尺寸）；RV 按 `from: "0.2.1"` 依赖它，只给 macOS 链接，页面取 App Store 的样式（居中版式、功能行符号用强调色，What's New 不带图片，欢迎页顶部是 128pt 的 App 图标）。

## 动机

- **升级之后用户看不到新功能。** 3.0.0 的十一个 beta 加了 Find 导航器、交叉引用、文件模式、C++ 对象、编辑器分栏、内嵌 CLI 等一大批功能（`Changelogs/v3.0.0-beta.5.md` 到 `v3.0.0-beta.10.md` 的 New 一节），可它们只写在 Sparkle 更新框的 release notes 里：用户在更新框里点了 Install，重启后 App 里没有任何提示。很多入口藏在菜单或设置里（Find Call Hierarchy 是 ⌃⇧⌘H，C++ 导出是导出面板里的开关），不知道就找不到。
- **新用户第一次打开只看到一个空的欢迎窗口。** 0105 的欢迎窗口左边是两个动作、右边是最近文件（第一次是空的「No Recent Files」），没有任何一句话说 RuntimeViewer 是做什么的、能连哪些来源。
- **系统自己就有现成的画法。** Apple 的 App 用 OnBoardingKit 画这两种页面，swift-onboardingkit（`/Volumes/Repositories/Private/Personal/Library/macOS/swift-onboardingkit`，提案 0001）把它包成了可用的 Swift 接口。自己用 AppKit 画一套同样外观的页面，既费工又永远差一点。

## 前期调研

- **swift-onboardingkit 的现状**（本机检出与 GitHub，2026-11-24）：
  - 只有一个提交 `87fca78`，已推到 `Mx-Iris/swift-onboardingkit` 的 `main`，**仓库是私有的，没有任何 tag**。README 的安装写法是 `branch: "main"`。
  - 两个 product：`COnBoardingKit`（一份 Objective-C 头文件，声明 29 个类）与 `OnBoardingKit`（Swift 层，`@_exported import COnBoardingKit`）。只支持 macOS 14+，tools version 6.2。
  - 链接方式：`COnBoardingKit` 的 `linkerSettings` 是 `.unsafeFlags(["-F/System/Library/PrivateFrameworks"])` 加 `.linkedFramework("OnBoardingKit")`，即**强链接**。框架一旦在某个系统上不存在，链接它的 App 启动时就被 dyld 拒绝（`Library not loaded`），而不是只少一个功能。
  - 用得上的接口（`Sources/OnBoardingKit/`）：
    - `OBTemplateView(title:bodyText:systemImage:layoutStyle:features:)`，`features` 是 `OBTemplatePartBulletList.ItemBuilder` 的 result builder；
    - `OBTemplatePartBulletList.Item(_ title:description:systemImage:tintColor:status:subitems:)`；
    - `OBTemplateContainerViewController(templateView:primaryButton:secondaryButton:cancelButton:)`，按钮是 `OBTemplateContainerViewController.Button(_ title:action:)`，`action` 收到容器自己；主按钮自动响应 Return；
    - README 的用法是 `window.contentViewController?.presentAsSheet(controller)`。
  - 已知行为（README「Things to know」）：这是 SPI，系统更新可能删成员（27.2 就删了三个）；包的测试在运行时核对头文件声明的每个成员。
- **仓库可见性**（`gh repo view`）：RuntimeViewer 是公开仓库；swift-onboardingkit、swift-skylight、AppKitPlus 是私有的。RV 依赖的 AppKitPlus 走的是公开的二进制发布仓库 `AppKitSupportProgram/AppKitPlus-Release`。release workflow（`.github/workflows/release.yml`）只为 SourceEditor 另配了 `SOURCE_EDITOR_RELEASES_TOKEN`，其余依赖用 job 自己的 token 解析，读不到别的私有仓库。所以 swift-onboardingkit 保持私有，CI 发版与外部贡献者都解析不了依赖图。用户已决定改为公开并发布 `0.1.0`。
- **带 unsafe flags 的远端依赖在 Xcode 里是否被接受：尚未验证。** 包的 README 说 tools 6.2 起 SwiftPM 不再拒绝；本机所有仓库的 `Package.resolved` 里还没有任何一个工程依赖同样写法的 swift-skylight，没有先例。Tuist 把它放进二进制缓存后链接参数是否还传到 App 的链接也没验证。两项都放在落地第 2 步实测。
- **RV 的启动流程**（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`）：`applicationDidFinishLaunching` 依次调各个生命周期控制器的一行 `start()`；设置是异步读的，要等 `SettingsLifecycleController.waitUntilLoaded()`。`WelcomeController` 是同形的先例：决策在 AppCore 的 `WelcomeWindowPolicy`（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/App/WelcomeWindowPolicy.swift`，`#if os(macOS)` 包着的无状态 enum），测试在 `RuntimeViewerAppCoreTests/WelcomeWindowPolicyTests.swift`。`RuntimeViewerUsingAppKit/AGENTS.md` 规定新的启动职责一律是 `App/` 下一个新的 `@MainActor` 控制器，AppDelegate 只放一行调用。
- **「新用户」怎么认**：
  - `SettingsAccess.load()`（`RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift:120`）拿到的 `SettingsStore.LoadOutcome` 有 `.loaded`、`.noStoredData`、`.failed(_:)` 三种，但现在只打日志、不留结果。`settings.json` 在 `~/Library/Application Support/RuntimeViewer[-Debug]/`，用过任何一版、改过任何一项设置的用户都有它。
  - UIFoundation 的设置层 skill（`uifoundation-settings-layer`「The first-run gate」）的建议是：首次启动的判断从**已经持久化的状态**推出，不另存一个可能和它矛盾的布尔值。
  - 从没改过设置的老用户没有 `settings.json`，会被当成新用户、看到欢迎页而不是 What's New。见「我自己定的」与「替代方案」。
- **「看过哪一版」存在哪**：`AppDefaults`（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Storage/AppDefaults.swift`）是 App 的非偏好状态（最近查询、Filter Scope 记忆、书签……），`@UserDefault` 存在标准 defaults 里，测试用隔离的 namespace。Debug 与 Release 的 bundle identifier 不同（`Configurations/RuntimeViewerUsingAppKit/{Debug,Release}.xcconfig`），defaults 天然分开。
- **版本号**：`Configurations/Version.xcconfig` 的 `MARKETING_VERSION = 3.0.0` 是唯一来源，3.0.0 的所有 beta 都报 `3.0.0`，只差构建号。所以按 `主版本.次版本` 认「功能版本」：beta 与补丁版不会重复弹页，同一功能版本只弹一次。
- **Help 菜单**：`MainMenuController.makeMainMenu()` 现在是 `MainMenu.help()`（UIFoundation `Sources/UIFoundationAppKit/Menu/MainMenu+Help.swift`），另有 `help(title:_:)` 接受 `@MenuBuilder`，`MainMenu.Help.applicationHelp()` 是标准的「RuntimeViewer Help」一项。Window 菜单里已有「Welcome to RuntimeViewer」（⇧⌘1，打开 0105 的欢迎窗口）。
- **符号**：AppCore 用 `SystemSymbol`（`Presentation/SystemSymbol.swift`，raw value 就是符号名）描述系统符号，AppUI 的 `SystemSymbolTests` 逐个加载每个 case。已有 `magnifyingglass`、`arrowTriangleBranch`、`sparkles`；页面要用的其余符号要新加 case。
- **启动时的另一个弹窗**：`HelperServiceVersionChecker.checkOnLaunch()` 在升级后可能 `runModal()` 一个「重装 helper、要重启」的 alert（beta.9 起）。两者同时出现时，sheet 会等 modal 会话结束才显示；若用户在 alert 里选了重启，页面没被关过、下次启动照样出现。不做特别处理。
- **页面内容的来源**：`Changelogs/<tag>.md` 的条目是一整句话，OnBoardingKit 的列表行要的是短标题、一句描述和一个符号，直接解析 changelog 拿不到这三样。所以内容在 AppCore 里手写一份，取材于 changelog。

## 提议方案

1. **swift-onboardingkit 发布 `0.1.0`**：链接改成弱链接（`-weak_framework OnBoardingKit`），README 的安装写法改成 `from: "0.1.0"`，在它的提案 0001 决策日志里记一笔；仓库改为公开；打 tag `0.1.0`（Mx-Iris 库的 tag 不带 `v`，同 UIFoundation）并建 GitHub Release。
2. **RV 依赖它**：`RuntimeViewerPackages/Package.swift` 照既有写法声明 `swift-onboardingkit`（本地候选指向 `Personal/Library/macOS/swift-onboardingkit`，远端 `from: "0.1.0"`，修 0 × 0 页面时抬到 `0.1.1`，改用页面值时抬到 `0.2.0`，修功能行图标时抬到 `0.2.1`），`RuntimeViewerAppUI` 依赖 `OnBoardingKit` product，条件 `.when(platforms: appkitPlatforms)`。更新受版本控制的锁文件：`RuntimeViewerPackages`、`RuntimeViewerCommandLine` 两个包的，以及 Debug、Distribution 两个 workspace 的。
3. **「功能版本」与判断放在 AppCore**（全部 `#if os(macOS)`）：
   - `FeatureRelease`：`主版本.次版本`，可比较、可编码，从 marketing version 解析。
   - `OnboardingPage`：一页的内容，值类型——标题、正文、顶部图片（`Image?`：App 图标或某个 `SystemSymbol`，可以没有）、功能行（标题、描述、`SystemSymbol`），以及它是欢迎页还是哪一版的 What's New。
   - `OnboardingCatalog.runtimeViewer`：欢迎页一份，What's New 按功能版本各一份；第一份是 3.0。
   - `OnboardingPolicy.pageForLaunch(currentRelease:lastPresentedRelease:hasStoredSettings:catalog:)`：
     - 记录为空：没有存过设置 → 欢迎页；存过设置（老用户）→ 当前版本的 What's New，目录里没有就不弹。
     - 记录早于当前版本，且目录里有当前版本的页 → What's New。
     - 其余（同版本、降级、目录里没有这一版）→ 不弹。
   - `AppDefaults.lastPresentedOnboardingRelease: FeatureRelease?`：点 Continue 时写成当前功能版本。欢迎页也写当前版本，所以新用户不会紧接着再看一次同一版的 What's New。
4. **`SettingsAccess` 记下这次读设置时有没有找到存储的设置**：`didFindStoredSettingsOnLoad`，`.loaded` 与 `.failed` 为 `true`（文件在，只是读坏了，也算老用户），`.noStoredData` 为 `false`。
5. **AppUI 把页面画成 OnBoardingKit 的模板**：`OnboardingPage.templatePage(parentWindowSize:)` 把页面值映射成 swift-onboardingkit 0.2.0 的 `OBTemplatePage`，取 App Store 的样式——居中版式（`.centered`：每边 68pt、图片居中）、功能行的符号用强调色（`.controlAccentColor`）、App 图标按 128pt 显示，尺寸取 `OBTemplateContainerViewController.sheetSize(forParentWindowSize:)`（宽 482，高取父窗口的 88%、限制在 546–600，没有父窗口时 546）。`makeTemplateContainerViewController(parentWindowSize:onContinue:)` 交给库的 `OBTemplateContainerViewController(page:primaryButton:)` 组装，返回带一个 Continue 按钮的容器；视图与控制器的属性（自动约束、模板类型、`preferredContentSize`）都由库按页面值设，原因见详细设计「AppUI」一节。系统上没有 OnBoardingKit（弱链接后类为 nil）时返回 `nil`，调用方就不弹，只记日志。Continue 先把页面从屏幕上拿掉（被 present 的就 `dismiss`，作为 sheet 窗口内容的就 `endSheet`，独立窗口里的就关窗），再调 `onContinue`。
6. **App 里新增 `OnboardingController`**（`App/`）：
   - `start()`：等设置读完，用 policy 算出这次要弹的页。主窗口已是文档窗口，就挂成它的 sheet；欢迎窗口在屏幕上，就放进一个独立窗口、显示在欢迎窗口前面；两者都没有，就等第一个成为主窗口的文档窗口或成为 key 的欢迎窗口。Continue 时写 `AppDefaults` 的记录。
   - `showWhatsNew()`：Help › What's New in RuntimeViewer 的动作，弹不超过当前版本的最新一页 What's New，不改记录；主窗口是文档窗口就挂成它的 sheet，否则用独立窗口。页面已在屏幕上时不重复弹。
   - `WelcomeController` 加 `owns(_ window:)` 与 `isShowingWindow`，让控制器认得欢迎窗口：`WelcomePanelController` 把 `window` 标成不可用，所以按窗口的 `windowController` 认。
7. **AppDelegate 加三行**：`@Dependency(\.onboardingController)`、`onboardingController.start()`，以及转发菜单动作的 `@objc func showWhatsNew(_:)`。`MainMenuController` 的 Help 菜单改成 `MainMenu.help { … }`，在「RuntimeViewer Help」之后加「What's New in RuntimeViewer」。
8. **目录必须写到当前版本**：AppCore 的测试读 `Configurations/Version.xcconfig`，目录里没有它的功能版本就失败。下一个功能版本（3.1）改版本号时必须同批写好 What's New。

### 非目标

- 不做 iOS、visionOS 与越狱 iOS 版：OnBoardingKit 的 macOS 版只有 macOS；iOS 版（`OBWelcomeController`）不在 swift-onboardingkit 范围内。
- 不做多页引导、权限请求或设置向导：两种页面都只有一页、一个 Continue 按钮。
- 不显示 OnBoardingKit 的隐私页（`OBPrivacyPresenter`）：它只认 Apple 自己的隐私 bundle，RV 的隐私说明在 `docs/privacy.html`。
- 不从 `Changelogs/` 自动生成内容，不联网取内容。
- 不给补丁版或 beta 单独弹页；不在 Settings 里加开关（页面一个版本只出现一次，点 Continue 就没了）。
- 不改 0105 的欢迎窗口本身。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| swift-onboardingkit `Package.swift` · `COnBoardingKit` | 修改 | `linkerSettings` 改为 `.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-Xlinker", "-weak_framework", "-Xlinker", "OnBoardingKit"])`，去掉 `.linkedFramework` | 框架不在的系统上 App 仍能启动 | 1 |
| swift-onboardingkit `README.md` | 修改 | 安装写法改 `from: "0.1.0"`；「Things to know」加一条弱链接与可用性检查 | 公开发布后的用法 | 1 |
| swift-onboardingkit `Documentations/Evolutions/0001-…md`（与 `.html`） | 修改 | 决策日志加一行：改弱链接、公开、发布 0.1.0 | 那边的决策留档 | 1 |
| GitHub `Mx-Iris/swift-onboardingkit` | 修改 | 可见性改公开；tag `0.1.0` 与 Release | RV 是公开仓库 | 1 |
| `RuntimeViewerPackages/Package.swift` | 修改 | 声明 `swift-onboardingkit`（本地候选 + `from: "0.2.1"`）；`RuntimeViewerAppUI` 依赖 `OnBoardingKit`，只给 macOS | 接入依赖 | 2 |
| `RuntimeViewerPackages/Package.resolved`、`RuntimeViewerCommandLine/Package.resolved`、`RuntimeViewer-Debug.xcworkspace/…/Package.resolved`、`RuntimeViewer-Distribution.xcworkspace/…/Package.resolved` | 修改 | 加 swift-onboardingkit 的 pin，其余 pin 不动 | 锁文件随依赖变 | 2 |
| `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift` · `SettingsAccess` | 修改 | 新增 `didFindStoredSettingsOnLoad`，在 `logLoadOutcome(_:)` 里记 | 认新用户，不另存布尔值 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerSettingsTests/SettingsStoredSettingsDetectionTests.swift` | 新增 | 无数据、有数据、坏数据三种 | 第 3 步的测试 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/App/FeatureRelease.swift` · `FeatureRelease` | 新增 | 主次版本、解析、比较、编码 | 按功能版本弹页 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/App/OnboardingPage.swift` · `OnboardingPage` | 新增 | 一页的内容值 | AppCore 只描述、AppUI 画 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/App/OnboardingCatalog.swift` · `OnboardingCatalog` | 新增 | 欢迎页与 3.0 的 What's New；按版本取页 | 内容 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/App/OnboardingPolicy.swift` · `OnboardingPolicy` | 新增 | `pageForLaunch(…)` | 判断可单测 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Storage/AppDefaults.swift` · `AppDefaults` | 修改 | 新增 `@UserDefault lastPresentedOnboardingRelease: FeatureRelease?`（键 `lastPresentedOnboardingRelease`） | 记住看过哪一版 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Presentation/SystemSymbol.swift` · `SystemSymbol` | 修改 | 加页面用到、还没有的符号（见详细设计） | 页面的符号 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/FeatureReleaseTests.swift` | 新增 | 解析与比较 | 第 3 步的测试 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/OnboardingPolicyTests.swift` | 新增 | 每种启动情形 | 第 3 步的测试 | 3 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/OnboardingCatalogTests.swift` | 新增 | 目录覆盖当前版本、每页行数、取页规则 | 第 3、8 条 | 3 |
| `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/App/OnboardingPage+TemplateContainer.swift` | 新增 | `makeTemplateContainerViewController(parentWindowSize:onContinue:)`、`isPresentable` | 画成 OnBoardingKit 模板，按挂在哪里定页面尺寸 | 4 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppUITests/OnboardingTemplateContainerTests.swift` | 新增 | 标题、按钮、Continue 的回调 | 第 4 步的测试 | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/OnboardingController.swift` · `OnboardingController` | 新增 | `start()`、`showWhatsNew()`、等主窗口、写记录 | 新的启动职责 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/WelcomeController.swift` · `WelcomeController` | 修改 | 新增 `owns(_ window: NSWindow) -> Bool` 与 `isShowingWindow` | 让页面知道欢迎窗口在不在前面 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift` | 修改 | `@Dependency(\.onboardingController)`、`start()` 一行、`showWhatsNew(_:)` 一行 | 接入启动 | 5 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/MainMenuController.swift` | 修改 | Help 菜单加「What’s New in RuntimeViewer」 | 随时再看 | 5 |
| `RuntimeViewerUsingAppKit/AGENTS.md` | 修改 | 生命周期控制器清单加 `OnboardingController`：弱链接要先查 `isPresentable`、新功能版本必须同批带 What's New | 规则落到受管目录 | 6 |
| `Tuist/Package.swift` | 修改 | `productTypes` 把 `OnBoardingKit` 定为静态库、`COnBoardingKit` 钉回静态 framework；`localTestTargetSettings` 给 `RuntimeViewerAppUITests` 补链接参数 | Tuist 构建（实现中发现，见决策日志） | 2 |
| `Tuist/ProjectDescriptionHelpers/OnBoardingKitLinking.swift` · `OnBoardingKitLinking` | 新增 | swift-onboardingkit 的链接参数与要重复它们的包测试名单 | 同上 | 2 |
| `RuntimeViewerUsingAppKit/Project.swift` · `targetSettings(…)` | 修改 | 新参数 `linksOnBoardingKit`，App target 传 `true` | 同上 | 2 |
| `Documentations/Guides/TuistDevelopment.md` | 修改 | 「已知的坑」加两条，「已知差异」提一句 | 同上 | 2 |
| `Documentations/Glossary.md` | 修改 | 登记「功能版本（feature release）」 | 新术语 | 6 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案 | 文档索引 | 6 |

## 架构图

改了什么：

```text
swift-onboardingkit 0.2.0                    (+ new public dependency, macOS only)
  COnBoardingKit   ~ links OnBoardingKit.framework weakly (-weak_framework)  [0.1.0]
  OnBoardingKit    ~ container sizes itself, sheetSize(forParentWindowSize:)  [0.1.1]
                   + OBTemplatePage, init(page:primaryButton:)                [0.2.0]

RuntimeViewerPackages
  RuntimeViewerSettings
    SettingsAccess
      + didFindStoredSettingsOnLoad: Bool
  RuntimeViewerAppCore                        (no UI library, unchanged rule)
    Storage/AppDefaults
      + lastPresentedOnboardingRelease: FeatureRelease?
    Presentation/SystemSymbol                 ~ + symbol cases for the pages
    App/
      + FeatureRelease
      + OnboardingPage
      + OnboardingCatalog        (.runtimeViewer: welcome + 3.0)
      + OnboardingPolicy         (pageForLaunch)
  RuntimeViewerAppUI
    + App/OnboardingPage+TemplateContainer.swift ──► OnBoardingKit (macOS only)

RuntimeViewerUsingAppKit (app target)
  App/
    + OnboardingController
    ~ WelcomeController          (+ owns(_:), + isShowingWindow)
    ~ AppDelegate                (+ start(), + showWhatsNew(_:))
    ~ MainMenuController         (+ Help › What's New in RuntimeViewer)
```

启动时的流程：

```text
applicationDidFinishLaunching
  ├─ settingsLifecycleController.loadOnLaunch()
  │    └─ SettingsAccess.load() ─► didFindStoredSettingsOnLoad
  ├─ welcomeController.start()
  └─ onboardingController.start()
       └─ await settingsLifecycleController.waitUntilLoaded()
       └─ OnboardingPolicy.pageForLaunch(
              currentRelease:       FeatureRelease(marketingVersion: CFBundleShortVersionString),
              lastPresentedRelease: appDefaults.lastPresentedOnboardingRelease,
              hasStoredSettings:    settings.didFindStoredSettingsOnLoad,
              catalog:              .runtimeViewer)
            ├─ nil ─► done
            └─ page
                 ├─ main window is a document window      ─► sheet on it
                 ├─ welcomeController.isShowingWindow      ─► a window of its own, in front
                 └─ neither ─► wait: a document window becomes main ─► sheet on it
                                    or the Welcome window becomes key ─► a window of its own
                      page.makeTemplateContainerViewController(parentWindowSize: sheet parent's size or nil)
                        ├─ nil (no OnBoardingKit) ─► log, done
                        └─ Continue ─► dismiss / endSheet / close
                                    ─► appDefaults.lastPresentedOnboardingRelease = currentRelease

Help › What's New in RuntimeViewer
  └─ AppDelegate.showWhatsNew(_:) ─► onboardingController.showWhatsNew()
       └─ catalog.latestWhatsNewPage(upTo: currentRelease)
            └─ sheet on a document main window, or a window of its own   (record unchanged)
```

## 详细设计

### swift-onboardingkit 的弱链接

```swift
.target(
    name: "COnBoardingKit",
    linkerSettings: [
        // OnBoardingKit is a private framework; the SDK ships its text stub under PrivateFrameworks, which is
        // not on the default framework search path. It is linked weakly, so that an app linking this package
        // still launches on a system without the framework; check that a class exists before using it.
        .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-Xlinker", "-weak_framework", "-Xlinker", "OnBoardingKit"]),
    ]
),
```

`-Xlinker` 前缀让参数原样交给 `ld`，swiftc 与 clang 驱动都认；第 2 步用 `otool -l` 确认 App 里是 `LC_LOAD_WEAK_DYLIB`。弱链接后，系统上没有框架时 Objective-C 类引用为 `nil`，所以 RV 在构造前先查 `NSClassFromString("OBTemplateContainerViewController")`。

### AppCore

```swift
#if os(macOS)

/// A feature release of the app: the major and minor parts of its marketing version. The betas and the
/// patch releases of one feature release share its onboarding pages.
public struct FeatureRelease: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int)

    /// `3.0.0`, `3.0` and `3.0.1` are all 3.0. `nil` when the string does not start with two numbers.
    public init?(marketingVersion: String)

    /// `3.0`.
    public var description: String

    public static func < (lhs: FeatureRelease, rhs: FeatureRelease) -> Bool
}

/// One onboarding page: what OnBoardingKit's template shows, as values. RuntimeViewerAppUI draws it.
public struct OnboardingPage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Shown once, to someone who has never used the app.
        case welcome
        /// Shown once after updating to this feature release.
        case whatsNew(FeatureRelease)
    }

    /// One row of the page's list.
    public struct Feature: Equatable, Sendable {
        public var title: String
        public var description: String
        public var symbol: SystemSymbol

        public init(_ title: String, description: String, symbol: SystemSymbol)
    }

    public var kind: Kind
    public var title: String
    public var bodyText: String?
    /// The image above the title, or `nil` for none, as the App Store's What's New pages have.
    public enum Image: Equatable, Sendable { case appIcon; case symbol(SystemSymbol) }
    public var image: Image?
    public var features: [Feature]

    public init(kind: Kind, title: String, bodyText: String? = nil, image: Image? = nil, features: [Feature])
}

/// Every onboarding page the app has.
public struct OnboardingCatalog: Sendable {
    public var welcomePage: OnboardingPage
    /// What's New, by feature release. A release without an entry shows none.
    public var whatsNewPages: [FeatureRelease: OnboardingPage]

    public init(welcomePage: OnboardingPage, whatsNewPages: [FeatureRelease: OnboardingPage])

    /// RuntimeViewer's pages.
    public static let runtimeViewer: OnboardingCatalog

    /// The page Help › What's New shows: the release's own, or else the latest one before it.
    public func latestWhatsNewPage(upTo release: FeatureRelease) -> OnboardingPage?
}

/// Which onboarding page a launch shows. The app's `OnboardingController` shows it; this type only
/// decides, so that a test can.
public enum OnboardingPolicy {
    /// - Parameters:
    ///   - currentRelease: The feature release of the running app.
    ///   - lastPresentedRelease: The release of the last page the user continued from, or `nil`.
    ///   - hasStoredSettings: Whether the launch found stored settings, which only someone who has used
    ///     the app before has.
    /// - Returns: `nil` to show nothing.
    public static func pageForLaunch(
        currentRelease: FeatureRelease,
        lastPresentedRelease: FeatureRelease?,
        hasStoredSettings: Bool,
        catalog: OnboardingCatalog
    ) -> OnboardingPage?
}

#endif
```

`OnboardingPolicy.pageForLaunch` 的规则：

| `lastPresentedRelease` | `hasStoredSettings` | 目录里有当前版本 | 结果 |
|---|---|---|---|
| `nil` | `false` | 任意 | 欢迎页 |
| `nil` | `true` | 有 | 当前版本的 What's New |
| `nil` | `true` | 没有 | `nil` |
| 早于当前 | 任意 | 有 | 当前版本的 What's New |
| 早于当前 | 任意 | 没有 | `nil` |
| 等于或晚于当前 | 任意 | 任意 | `nil` |

`AppDefaults`：

```swift
@UserDefault
public var lastPresentedOnboardingRelease: FeatureRelease?
// init: _lastPresentedOnboardingRelease = UserDefault(key: userDefaultsNamespace.key("lastPresentedOnboardingRelease"), defaultValue: nil, suite: userDefaults)
```

`SettingsAccess`：

```swift
/// Whether the last `load()` or `loadSynchronously()` found stored settings, even unreadable ones. Only
/// someone who has used the app before has them, so this is how a first launch is told apart. It
/// describes the load, not the store: a save afterwards does not change it.
public private(set) var didFindStoredSettingsOnLoad = false
```

`.loaded` → `true`；`.failed` → `true`；`.noStoredData` → `false`。

### 页面内容（界面文字用英文）

欢迎页（`image: .appIcon`，128pt 的 App 图标）：

- 标题 **Welcome to RuntimeViewer**；正文 *Read the Objective-C, Swift and C++ interfaces of the images on your Mac, in other processes and on your devices.*
- Every Interface — *Browse the Objective-C, Swift and C++ objects of any image, printed with Xcode's syntax highlighting.* — `square.stack.3d.up`
- Jump Through Types — *Click a type in an interface to open it, and go back the way you came.* — `arrow.right.circle`
- Beyond This Process — *Attach to a running app, a Mac Catalyst app, the Simulator or a device, or open files from disk.* — `app.connected.to.app.below.fill`
- Find and Cross References — *Search every indexed interface and follow callers, callees and type references.* — `magnifyingglass`
- Made for Agents — *An MCP server and runtime-viewer-cli give coding agents the same interfaces.* — `terminal`

What's New in RuntimeViewer 3.0（不放顶部图片，取材于 `Changelogs/v3.0.0-beta.5.md`–`v3.0.0-beta.10.md`）：

- Find Navigator — *Search the interfaces of every indexed image, find types with their hierarchy, and find members.* — `magnifyingglass`
- Cross References — *See who calls a method, what it calls and which functions use a type.* — `arrow.triangle.branch`
- Files from Disk — *Open Mach-O files, bundles, folders and dyld shared caches, each in its own window.* — `folder`
- C++ Interfaces — *Classes and namespaces recovered from RTTI, vtables and symbols, printed and exported as headers.* — `curlybraces`
- Editor Panes — *Split the content area; each pane has its own tabs, history and jump bar.* — `rectangle.split.2x1`
- Command-Line Tool — *runtime-viewer-cli ships inside the app and works without it running.* — `terminal`

`SystemSymbol` 新加的 case（起初还有欢迎页顶部的 `handWave`，改用 App 图标后删掉）：`squareStack3dUp = "square.stack.3d.up"`、`arrowRightCircle = "arrow.right.circle"`、`appConnectedToAppBelowFill = "app.connected.to.app.below.fill"`、`terminal`、`folder`、`curlybraces`、`rectangleSplit2x1 = "rectangle.split.2x1"`（已有的不重复加）。`SystemSymbolTests` 会在 macOS 上逐个加载。

### AppUI

```swift
#if os(macOS)
import AppKit
import OnBoardingKit
import RuntimeViewerAppCore

extension OnboardingPage {
    /// Whether this system has OnBoardingKit, which the package links weakly.
    public static var isPresentable: Bool { NSClassFromString("OBTemplateContainerViewController") != nil }

    /// The page as swift-onboardingkit's page value, in the App Store's style: centered, the rows'
    /// symbols in the accent color, the app's icon at 128 points, the framework's sheet size.
    @MainActor
    func templatePage(parentWindowSize: NSSize?) -> OBTemplatePage

    /// The page assembled by `OBTemplateContainerViewController(page:primaryButton:)`, with one
    /// Continue button. Continue dismisses the container — or closes its window when it was not
    /// presented — and then calls `onContinue`. `nil` when the system has no OnBoardingKit.
    @MainActor
    public func makeTemplateContainerViewController(parentWindowSize: NSSize?, onContinue: @escaping @MainActor () -> Void) -> NSViewController?
}
#endif
```

每个 `Feature` 变成 `OBTemplatePartBulletList.Item(_:description:systemImage:)`，按钮文字 `Continue`。App 图标取 `NSImage(named: NSImage.applicationIconName)` 的副本再设成 128pt：具名的应用图标是全 App 共用的那一份，直接改尺寸会影响别处。

**页面要有尺寸，模板视图要关掉自动约束。** 两处都是框架的行为，在 macOS 27.2 的 cache 上用 IDA 反编译、再在测试里逐步打印尺寸查明；最初在 RV 里修，随后移进 swift-onboardingkit（0.1.1 的尺寸、0.2.0 的页面值与版式），结论也记在它的实现说明「Swift 层依赖的框架行为」：

- 模板视图用零尺寸创建，`translatesAutoresizingMaskIntoConstraints` 是默认的 `true`；容器（`setTemplateView:` 里的 `_completelyFillWithView:`）又用约束把它与四边贴死。于是 AppKit 按它的零尺寸生成 `width == 0`、`height == 0` 两条必需约束，把容器连同用它建的窗口或 sheet 一起压成 0 × 0，什么尺寸约束都顶不过。只给尺寸不关开关时，窗口够大，模板仍是 0 × 0，页面里只剩按钮栏。
- 容器自己不定尺寸：`-[OBTemplateContainerViewController loadView]` 用 `NSZeroRect` 建视图，只约束了按钮栏的高度（63），宽度没有任何约束；模板要到第一次 `viewWillDraw` 才搭子视图，所以在那之前也撑不起尺寸。只关开关不给尺寸时，窗口宽约 300、高为 0。
- 框架自己的隐私页窗口（`OBPrivacyWindow`）覆写 `setFrame:display:`，把尺寸强制成 `+[OBStyle sheetSizeForParentWindowSize:]` 的结果：宽 482；高取父窗口高度的 88%，限制在 546 到 600 之间；没有父窗口（尺寸为零）时 546。macOS 15.5 与 27.2 上这组数相同（两版 cache 各建了 IDA 库核对）。`OBStyle` 不在 SDK 的 `.tbd` 里，App 调不到，所以 swift-onboardingkit 的 `sheetSize(forParentWindowSize:)` 照抄这个公式，交给容器的 `preferredContentSize`（AppKit 换成两条优先级 501 的约束）。`NSWindow(contentViewController:)` 与 `presentAsSheet` 都按它开出窗口；sheet 用文档窗口的尺寸算，独立窗口没有父窗口，取 546。
- 模板的左右边距按类型定（`-[OBTemplateView outerContentMargins]`）：构造器给的标准类型每边 175pt（开 `needsExtraWideContent` 时 85），是给整窗口页面用的，放进 482 宽的页面，标题只剩 136pt 宽；隐私类型（`privacy`）与居中类型（`centered`）每边 68pt。居中类型的列表行宽 344（`-[OBTemplatePartBulletList setBulletListSpacing:]`），正好是 482 − 2 × 68 留下的宽度；隐私类型的列表仍按间距档位取 382，比可用宽度还宽，而且它的上边距按窗口高度的 12% 算，是隐私页的版式。所以页面用居中类型，模板与列表都设（列表的类型只影响行宽与内缩，模板不会替它设）。类型在模板第一次绘制时才读，建完模板再设即可。

### App

```swift
@MainActor
final class OnboardingController {
    fileprivate static let shared = OnboardingController()

    @Dependency(\.appDefaults) private var appDefaults
    @Dependency(\.settings) private var settings
    @Dependency(\.settingsLifecycleController) private var settingsLifecycleController
    @Dependency(\.welcomeController) private var welcomeController

    /// Called from `applicationDidFinishLaunching(_:)`, after `WelcomeController.start()`.
    func start()

    /// Help › What's New in RuntimeViewer.
    func showWhatsNew()
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { OnboardingController.shared })
    var onboardingController: OnboardingController
}
```

- 当前版本取 `Bundle.main` 的 `CFBundleShortVersionString`，解析不出就什么也不弹。
- 启动时：主窗口是文档窗口（`windowController?.document != nil`）就挂成它的 sheet；`welcomeController.isShowingWindow` 时放进独立窗口；都不是就同时观察 `didBecomeMainNotification` 与 `didBecomeKeyNotification`——欢迎窗口（Xcode 26 样式）是 `.borderless` 的 `NSWindow` 子类，只覆写了 `canBecomeKey`，永远不会成为 main——第一个成为 main 的文档窗口或成为 key 的欢迎窗口拿到页面，随即移除观察。
- 独立窗口：`NSWindow(contentViewController:)`，`[.titled, .fullSizeContentView]`、标题栏透明、居中显示；没有关闭按钮，与 sheet 一样只有 Continue（回车）一个出口——别的方式关掉的页面不会记下版本，下次启动还会再弹。文档窗口已挂着别的 sheet、或没有 `contentViewController` 时也用它。
- `showWhatsNew()` 不写记录；页面还在屏幕上时再点菜单，不重复弹第二个（`presentedContainer` 是弱引用，按它所在窗口是否可见判断）。

## 替代方案考量

- **自己用 AppKit 画页面**：不依赖私有框架，但要逐像素对齐 Apple 的模板，系统每次改样式还得跟。OnBoardingKit 就是系统 App 在用的那一套，选它正是为了外观一致；代价是 SPI 风险，用弱链接与可用性检查兜住。
- **swift-onboardingkit 保持私有、CI 加 token**：发版能过，但公开仓库的贡献者与任何没有 token 的构建都解析不了依赖图。用户选了改公开。
- **把封装放进 UIFoundation 的 `UIFoundationAppleInternal`**（项目以前对私有 API 封装的惯例）：用户已经把它做成了独立的包，与 swift-skylight 同一形态；本提案只接入，不搬家。
- **用一个布尔值 `hasCompletedOnboarding` 判断新用户**：从没改过设置的老用户也没有这个值，同样会被当成新用户，还多了一份可能和设置文件矛盾的状态（UIFoundation 设置层 skill 的告诫）。用「这次读设置时有没有找到存储的设置」，不新增状态。
- **用 Sparkle 写进 defaults 的 `SUHasLaunchedBefore` 认老用户**：覆盖面更大（没改过设置的老用户也有），但那是 Sparkle 的内部键，而且由 `UpdaterService.start()` 写入，读的时机要排在它前面，容易被调整启动顺序时悄悄打破。不用。
- **按完整版本号（含补丁）或构建号弹 What's New**：3.0.0 的 beta 都报 `3.0.0`，按构建号会每个 beta 弹一次；补丁版没有新功能可讲。按功能版本。
- **从 `Changelogs/*.md` 解析内容**：条目是整句话，没有标题与符号，解析出来的列表没法读。手写一份。
- **一律在独立窗口里弹，不挂 sheet**：Apple 的 App（App Store、Freeform）都挂在主窗口上。只在欢迎窗口在前、或没有合适的文档窗口时用独立窗口。
- **挂成欢迎窗口的 sheet**（最初的方案）：欢迎窗口是无边框窗口、不会成为主窗口，sheet 会从它没有标题栏的上沿垂下来；`WelcomePanelController` 还把 `window` 与 `contentViewController` 标成不可用。改为在它前面放一个独立窗口。

## 影响

### 用户可见变化

- 新用户第一次启动：欢迎窗口前面出现一个独立窗口（打开的是文档窗口时，则在它上面滑出 sheet），显示欢迎页，五行功能介绍，一个 Continue。
- 老用户升级到 3.0 后第一次启动：滑出 What's New in RuntimeViewer 3.0，六行新功能，一个 Continue。
- Help 菜单在「RuntimeViewer Help」之后多一项「What's New in RuntimeViewer」，没有快捷键。
- 其余操作不变；页面关掉之后不会再自动出现，直到下一个功能版本。

### 可发现性

页面本身就是新功能的入口说明；Help 菜单的一项让用户随时再看。默认开启，没有开关：每个功能版本只出现一次，点一下就关。

### 数据与配置兼容

- 新增一个 defaults 键 `lastPresentedOnboardingRelease`（`FeatureRelease` 编码后的值），旧版本不读它；降级后再升级，按记录判断，不会重复弹。
- `settings.json` 格式不变，只读取「文件在不在」。
- 删掉 defaults 键（`defaults delete <bundle id> lastPresentedOnboardingRelease`）即可让页面再出现一次，便于开发时查看。

### 平台与最低版本

只在 macOS（15+，App 的部署目标）上有；swift-onboardingkit 本身要求 macOS 14+。iOS、visionOS、Mac Catalyst 不链接它，行为不变。系统上没有 OnBoardingKit 时不弹、只记日志，App 照常启动（弱链接）。

### 发布

- 不需要新的 entitlement、权限或隐私清单条目；链接 `/System/Library/PrivateFrameworks` 下的系统框架不影响 hardened runtime 的库校验，也不影响公证。RV 不上 App Store，私有 API 不涉及审核。
- Sparkle 流程不变；release notes 照旧写在 `Changelogs/`，What's New 是另外手写的短版。
- 发布下一个功能版本前，`OnboardingCatalogTests` 会因为目录缺这一版而失败，提醒同批写 What's New。

## 落地步骤

1. ✅ **发布 swift-onboardingkit 0.1.0** —— 改动地图 swift-onboardingkit 四行
   - 行为：`swift test` 在那个包里照旧通过。
   - 行为：链接它的可执行文件里 OnBoardingKit 是 `LC_LOAD_WEAK_DYLIB`。
   - 行为：`gh repo view` 显示公开，`0.1.0` 的 tag 与 Release 存在。
2. ✅ **接入依赖并实测构建** —— `Package.swift`、四份锁文件，以及实现中补上的 Tuist 四行
   - 行为：在 Ultra 上 `RuntimeViewer-Debug.xcworkspace` 的 `RuntimeViewer macOS` 构建通过（Xcode 接受带 unsafe flags 的远端包）。
   - 行为：构建出的 App 里 OnBoardingKit 是弱链接（Debug 构建在 `RuntimeViewer-Debug-arm64e.debug.dylib` 里）。
   - 行为：`./TuistScript.sh check` 与 `warm` 通过，Tuist workspace 构建的 App 同样弱链接 OnBoardingKit。
   - 行为：iOS App（`RuntimeViewer iOS`）的构建不受影响。
   - 两项实测有一项不成立就停下，把现象和备选做法（例如在 App 的 xcconfig 里加链接参数、把它列进 Tuist 的源码依赖）报给用户，不自行换路。（实际：原生一项成立；Tuist 一项起初不成立，原因与项目里已有的两种 Tuist 绕行完全同类，照先例在 Tuist 一侧补上，没有换路，见决策日志。）
3. ✅ **AppCore 的判断与内容** —— `SettingsAccess`、`FeatureRelease`、`OnboardingPage`、`OnboardingCatalog`、`OnboardingPolicy`、`AppDefaults`、`SystemSymbol` 与三份测试
   - 行为：`featureReleaseParsesMajorAndMinorOfMarketingVersion`（`3.0.0`、`3.0`、`3.0.1` → 3.0）
   - 行为：`featureReleaseRejectsVersionWithoutTwoNumbers`
   - 行为：`featureReleaseOrdersByMajorThenMinor`
   - 行为：`firstLaunchWithoutStoredSettingsShowsWelcomePage`
   - 行为：`firstLaunchWithStoredSettingsShowsCurrentWhatsNew`
   - 行为：`launchAfterUpdatingShowsWhatsNewOfNewRelease`
   - 行为：`launchOfSameReleaseShowsNothing`
   - 行为：`launchAfterDowngradingShowsNothing`
   - 行为：`releaseWithoutWhatsNewShowsNothing`
   - 行为：`catalogHasWhatsNewForMarketingVersionInVersionXcconfig`
   - 行为：`latestWhatsNewPageFallsBackToEarlierRelease`
   - 行为：`everyPageListsBetweenOneAndSixFeatures`
   - 行为：`storedSettingsDetectedWhenStoreHasData`、`…NotDetectedWhenStoreIsEmpty`、`…DetectedWhenStoredDataIsUnreadable`
   - 行为：`AppCoreBoundaryTests` 与 `SystemSymbolTests` 照旧通过。
4. ✅ **AppUI 画页面** —— `OnboardingPage+TemplateContainer.swift` 与测试
   - 行为：`systemHasOnBoardingKit`、`bulletListHasARowForEachFeature`
   - 行为：`templateContainerShowsPageTitle`
   - 行为：`templateContainerHasOnlyContinueButton`
   - 行为：`continueButtonCallsOnContinueOnce`
5. ✅ **App 接入启动与菜单** —— `OnboardingController`、`WelcomeController.owns(_:)` 与 `isShowingWindow`、`AppDelegate`、`MainMenuController`（界面已由用户目视验收）
   - 行为：App 构建通过；`AppTargetBoundaryTests` 照旧通过（控制器不是 ViewModel）。
   - 行为：Help 菜单里有「What’s New in RuntimeViewer」。
   - 行为（由用户目视验收）：删掉 defaults 键与 `settings.json` 后启动看到欢迎页；保留 `settings.json` 再删 defaults 键看到 3.0 的 What's New；点 Continue 后重启不再出现。
6. ✅ **文档** —— `RuntimeViewerUsingAppKit/AGENTS.md`、术语表、两份索引、本提案
   - 行为：根 `AGENTS.md` 不再变大（它已超过 64 KiB，见提案索引的暂缓项）。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：「下一个功能版本要同批写 What's New」由测试强制，规则写进 `RuntimeViewerUsingAppKit/AGENTS.md`；弱链接与可用性检查写在 swift-onboardingkit 的 README。落地时再确认。
- **有没有引入新术语** —— 「功能版本」（`FeatureRelease`）是新说法，落地时登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-24 | Created as Draft | 用户要求接入新建的 swift-onboardingkit。澄清一轮定了两件事：做首次启动欢迎页与更新后的 What's New 两种页面；swift-onboardingkit 改为公开仓库并发布 0.1.0，RV 按版本号依赖。 |
| 2026-11-24 | Accepted | 用户批准，开始实现。功能分支 `feature/onboarding-pages` 从本地 `next` 切出；本地 `next` 上有别的会话尚未推送的提交，所以提案只在本地提交、不推送。 |
| 2026-11-24 | 功能分支叠在本地 next 上 | 本地 `next` 有两个还没推到任何远端的提交：别的会话在本地合进来、等用户看过的 `feature/debug-app-icon`（合并提交），以及 Tuist 的一处修复（`fix(tuist): resolve again when a manifest or the local libraries change`）。功能分支从本地 `next` 切出，推送后这两个提交也出现在 `origin/feature/onboarding-pages` 上；`next` 本身没有推送。 |
| 2026-11-24 | 第 1 步完成 | swift-onboardingkit 改为弱链接（`-Xlinker -weak_framework -Xlinker OnBoardingKit`，去掉 `.linkedFramework`），README 与它的 0001 决策日志同步；本机 `swift test` 两组共 20 个测试通过，两个测试包里 OnBoardingKit 都是 `LC_LOAD_WEAK_DYLIB`。仓库改为公开，打 tag `0.1.0` 并建 GitHub Release。 |
| 2026-11-24 | 锁文件从全新目录解析 | 在 Ultra 上用全新的 scratch 与 DerivedData 对两个包（`swift package resolve`）与 Debug、Distribution 两个 workspace（`xcodebuild -resolvePackageDependencies`）解析，已有的 pin 全部保留，四份锁文件只多出 swift-onboardingkit 一条（`RuntimeViewerPackages` 的锁文件另换了 `originHash`）。`RuntimeViewerAppUITests` 也依赖 `OnBoardingKit`（只给 macOS），测试里要直接读模板的属性。 |
| 2026-11-24 | 欢迎窗口在前时用独立窗口 | 偏离方案：方案原本让页面也挂成欢迎窗口的 sheet。读 UIFoundation 的 `WelcomePanelController` 发现，Xcode 26 样式的欢迎窗口是 `.borderless` 的 `NSWindow` 子类，只覆写了 `canBecomeKey`，永远不会成为 main，sheet 会从它没有标题栏的上沿垂下来；它还把 `window` 与 `contentViewController` 标成不可用。所以页面在文档窗口上仍是 sheet，欢迎窗口在前时放进一个独立窗口、显示在它前面；启动时等第一个成为 main 的文档窗口或成为 key 的欢迎窗口。`WelcomeController` 按窗口的 `windowController` 认出欢迎窗口（`owns(_:)`），另加 `isShowingWindow`。Continue 相应地也会结束 sheet 窗口（`endSheet`）。 |
| 2026-11-24 | Tuist 一侧补两处 | 第 2 步的 Tuist 实测起初不成立，两个原因都在 Tuist 把包 target 变成 Xcode target 这件事上，原生构建与发版不受影响。① `tuist cache warm` 报 `OnBoardingKit` 与 `COnBoardingKit` 循环依赖：Swift target 编成的静态 `OnBoardingKit.framework` 与私有框架同名、排在搜索路径前面，ObjC target 的 `-weak_framework OnBoardingKit` 链到了它。与 UIFoundation 一模一样，照它在 `Tuist/Package.swift` 的 `productTypes` 里把 Swift target 定为静态库、ObjC target 钉回静态 framework。② App 链接时 `OBTemplateView` 等四个类未定义：Tuist 不把包 target 的链接参数传给链接它的二进制。照 `-ObjC`、`SymbolLanguageRegistration` 的先例，新建 `OnBoardingKitLinking`，App 与 `RuntimeViewerAppUITests` 重复这组参数。两处都属于项目已有的 Tuist 绕行，没有改方案，所以没有停下来问；记进 `TuistDevelopment.md`「已知的坑」。修好后 install、check、warm、构建全部通过，Tuist 编出的 App 同样是 `LC_LOAD_WEAK_DYLIB`。 |
| 2026-11-24 | 独立窗口不带关闭按钮 | 自审时发现：独立窗口原本带关闭按钮，从那里关掉不会记下版本，下次启动又会弹。与 sheet 一样只留 Continue（回车）一个出口。 |
| 2026-11-24 | 根 AGENTS.md 不加依赖下限 | 根 `AGENTS.md` 已约 73 KB，超过它自己定的 64 KiB 上限，不再往里加；swift-onboardingkit 下限的理由写在 `RuntimeViewerPackages/Package.swift` 的注释里，使用规则（先查 `isPresentable`、新功能版本同批写 What's New）写进 `RuntimeViewerUsingAppKit/AGENTS.md` 的生命周期控制器清单。「功能版本」登记进术语表。 |
| 2026-11-24 | 实现完成，待用户看过后收尾 | 验证（都在 macOS 27.2、Xcode 27.2 上）：MacBook 上包级 `swift build --build-tests` 通过；`RuntimeViewerSettingsTests` 75 个全过；`RuntimeViewerAppCoreTests` 1098 个中 4 个失败，三个是既有记录里整包跑必红的（Call Hierarchy 超时、语料构建保持活动、Always Index 换 Engine），第四个 `SidebarImageListLoadWaitTests` 单独重跑通过；`RuntimeViewerAppUITests` 264 个只有既有必红的 `TitleActivityIndicatorTests` 一条失败。新增的五个套件全过。MacBook 显示器睡着时 AppUI 测试会卡死，点亮后重跑。Ultra 上原生 Debug workspace 构建 App、Tuist 的 install / check / warm / 构建、iOS App 构建全部通过，两种 App 里 OnBoardingKit 都是 `LC_LOAD_WEAK_DYLIB`。界面没有目视验收，留给用户。配套文章：不写——「新功能版本同批写 What's New」由测试强制、规则在 `RuntimeViewerUsingAppKit/AGENTS.md`，弱链接的用法在 swift-onboardingkit 的 README，Tuist 的两处绕行在 `TuistDevelopment.md`，没有别的调用方契约或下一任维护者会踩的决策。新术语：「功能版本」已登记进术语表。正式收尾时一并清理 Ultra 与 MacBook 上同名的 worktree `.worktrees/RuntimeViewer-OnboardingPages` 和 agent 构建目录（`/Volumes/DerivedData/Agents.noindex/claude/` 下名字带 `OnboardingPages` 的）。 |
| 2026-11-24 | 修好 0 × 0 的页面 | 用户看效果时发现页面窗口是 0 × 0。查明两个原因（详细设计「AppUI」一节）：模板视图零尺寸创建、自动约束没关，被按零尺寸钉死；容器自己也不定尺寸。修法是关掉模板视图的 `translatesAutoresizingMaskIntoConstraints`，再照框架给自家隐私页窗口定尺寸的公式（`+[OBStyle sheetSizeForParentWindowSize:]`，15.5 与 27.2 相同）设容器的 `preferredContentSize`；sheet 按文档窗口的高度算，`makeTemplateContainerViewController` 因此多了 `parentWindowSize:` 参数。第一版只给了尺寸、没关开关，测试显示窗口够大但模板仍是 0 × 0，随即改正。AppUI 测试新增尺寸公式的四种情况，以及「用容器建的窗口、弹出的 sheet 是页面尺寸且模板铺满」两条；去掉关开关那一行时这两条变红，已实测。swift-onboardingkit 的 README 示例（`presentAsSheet(controller)`）同样会弹出 0 × 0 的 sheet，库里还没改，是否改库并发 0.1.1 待用户定。 |
| 2026-11-24 | 修法移进 swift-onboardingkit 0.1.1 | 用户决定改库：库的 README 示例同样会弹出 0 × 0 的 sheet，修法放在框架知识所在的地方，别的 App 也不必再撞一次。swift-onboardingkit 的容器便利构造器关掉模板视图的开关、默认要求框架自家 sheet 的尺寸，新增 `sheetSize(forParentWindowSize:)`，发布 `0.1.1`（库的 27 个测试在 Ultra 上全过，去掉关开关那一行时三条变红）。RV 下限抬到 `from: "0.1.1"`，四份锁文件只改这一条 pin，删掉自己那份公式与开关；公式测试随之移到库里，RV 留窗口与 sheet 两条集成测试。 |
| 2026-11-24 | 页面用居中模板类型 | 用户看过修好尺寸的页面：正文挤在中间约 130pt 宽的一列。原因是构造器给模板的标准类型每边留 175pt 边距，是给整窗口页面用的。反编译模板的边距与列表行宽规则后，改用居中类型（每边 68pt、列表行宽 344，正好配 482 宽的页面），模板与列表都设；新增「标题与列表占页面宽度的六成以上」的测试，去掉这两行时标题宽 136、测试变红。swift-onboardingkit 的 README 示例用的也是标准类型，同样会挤成一列，是否改库待用户定。 |
| 2026-11-24 | 改用库的页面值，取 App Store 样式 | 用户看过居中版式后嫌难看（图标居中、文字靠左，空隙大），先要一个 demo 自己比较样式，再要求把 demo 里「数据组装成控制器」的部分搬进 swift-onboardingkit，封装成结构化数据、不暴露视图与控制器的属性（库的提案 0002，发布 `0.2.0`）。随后选定 App Store 的样式：反汇编 App Store 得知它的 What's New 模板不带图片、模板与列表都是居中类型、列表符号用 App 的强调色，欢迎页放 128pt 的 App 图标。RV 的页面值把顶部符号改成可选的 `image`（App 图标或符号），What's New 不放图片、欢迎页放 App 图标；AppUI 映射成 `OBTemplatePage` 交给库组装，不再自己设模板类型与尺寸。下限抬到 `0.2.0`，四份锁文件只改这条 pin；`SystemSymbol.handWave` 不再使用，删掉。验证（Ultra）：全新目录下包级构建、引导页相关测试（设置检测 3 个、AppUI 引导页 11 个、AppCore 引导页与功能版本 15 个）全过；CommandLine 包与 Debug、Distribution 两个 workspace 在全新目录下解析，锁文件不被改写；原生 Debug-arm64e 构建 App 通过，解析到 0.2.0。界面仍待用户目视。 |
| 2026-11-24 | 落地为 0108，Implemented | 用户看过 App Store 样式的页面后同意收尾。编号取本地与远端 `next`、`main` 上最大的 0107 加一。验证沿用上一行在 Ultra 上对功能分支最终代码的结果；本地 `next` 的合并结果没有另跑测试，用户目视时构建的就是它。没有拆出的后续项。配套文章：仍不写——理由同「实现完成」一行，后来几次修改的框架行为（尺寸公式、版式边距、组装顺序）写在 swift-onboardingkit 的实现说明与提案 0002 里，RV 一侧只剩把页面值映射成 `OBTemplatePage`。新术语：「功能版本」已登记，后来的修改没有引入新术语。本地 `next` 上还有别的会话没推送的提交，所以 `next` 暂不推送，远端的功能分支保留到 `next` 推上去为止。 |
| 2026-11-25 | 修 What's New 功能行的图标，下限抬到 0.2.1 | 用户在 What's New 上看到每行的符号压在标题上。原因在 swift-onboardingkit 0.2.0：页面默认的行距 `.default` 被写回列表，盖掉了框架给新列表的 `large`，每行图标成了 0 × 0 的框（IDA 反编译 27.2 的 OnBoardingKit 查明，库的测试修复前先红）。库发 `0.2.1` 修复，RV 的下限与四份锁文件跟着抬，代码不变。原因记在库的实现说明。 |

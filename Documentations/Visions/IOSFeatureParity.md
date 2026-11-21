# 愿景：iOS 版功能对齐

- **状态**: Active
- **最后更新**: 2026-11-21
- **相关提案**: [0099-engine-management-on-ios](../Evolutions/0099-engine-management-on-ios.md)（第一步，已落地）、[0100-settings-storage-on-ios](../Evolutions/0100-settings-storage-on-ios.md)（第二步，已落地）、[0101-settings-screen-on-ios](../Evolutions/0101-settings-screen-on-ios.md)（第五步里的设置页，提前做，已落地）、[0102-window-model-on-ios](../Evolutions/0102-window-model-on-ios.md)（第三步，已落地）

愿景**不做具体决定**，它划定一个方向的边界与取舍原则，让后续每个提案不必重新论证一遍。

## 这是什么领域

**iOS 上的 RuntimeViewer 不再只是给 Mac 连的一端，而是自己就能当完整的查看器用。** 越狱版
（在 vphone 这类没有沙盒限制的设备上）做到与 Mac 版几乎相同的功能；普通 iOS 版和 visionOS 版
编同一份代码，做不到的功能按能力隐藏。

**算在里面**：

- 引擎管理在 iOS 上可用：切换来源、发现局域网里的设备、在设备上附加进程、读磁盘上的文件。
- iOS 上的设置存储与设置页。
- App target 里与平台无关的逻辑下沉到 `RuntimeViewerAppCore`（两端共用的文档会话、打开文件、设置生命周期、导出日志、派生数据的度量与删除、启动顺序）。
- `RuntimeViewerAppCore` 里只在 macOS 上编、却没有硬阻塞的 ViewModel 放开平台限定；`RuntimeViewerAppUI` 补上 UIKit 一侧缺的绘制与适配。
- iOS 前端按 Mac 版的结构重建：每个窗口一份 `DocumentState`，再逐项补齐功能。

**不算在里面**：Mac 版自身的功能变化；`RuntimeEngine` 的请求集、线路协议与 `RuntimeSource`；iOS 上的
命令行工具与 MCP；App Store 上架；visionOS 的空间界面。

一句话：**两个前端共用同一套 ViewModel、同一个引擎管理器和同一套分层规则，差别只留在真正的平台能力上。**

## 为什么值得系统性投入

一篇提案装不下：引擎管理跨平台是一篇，设置存储（还要改上游 UIFoundation）是一篇，App 层逻辑下沉
与 iOS 窗口模型是一篇，ViewModel 放开平台限定与 AppUI 补齐是一篇，之后 iOS 前端还要按功能一项项补。
不先定方向，每一篇都要把同一组问题重吵一遍：普通 iOS 版做不做、窗口用 UIScene 还是 UIDocument、
先照 iPhone 还是 iPad、坏文件能不能让 App 崩、UIKit 视图放哪个模块。

另一个理由是差距在持续拉大：Mac 版每加一项功能，新的 ViewModel 照惯例写在 `#if os(macOS)` 里，iOS
版就又落后一项。

## 现状与代价

**iOS 版今天主要是给 Mac 连的一端。** `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/AppDelegate.swift:42-46`
起一个 Bonjour 服务端引擎供 Mac 连；越狱版再注册注入服务（`InjectionServiceRegistrar.swift:16-35`）并防止
被挂起（`SuspensionPreventionRegistrar.swift:14-34`）。这些能力（列出设备进程、注入、保活，提案 0043–0046）
**只有从 Mac 上才用得到**。设备上自己看到的只是早期 Mac 版水平的浏览器：

- 21 个 Swift 文件，`SceneDelegate.swift:14` 只有一份 `DocumentState()`，`Info.plist` 关着多窗口。
- 有：镜像树、对象列表与过滤、`UITextView` 显示接口、分栏。
- 没有：Inspector（`InspectorCoordinator` 只处理 `.placeholder`）、点击跳转（`ContentTextViewController.swift:84` 注释掉了）、标签页与历史、多栏编辑区、Find、Report、书签、Filter Scope、导出、特化、生成选项、切换来源、附加进程、文件模式、设置页。
- target 自己声明了 `MainViewModel` 与 `MainRoute`（`Main/MainViewModel.swift:7`、`Main/MainCoordinator.swift:9`），违反「ViewModel 都在 AppCore」；`AppTargetBoundaryTests` 只扫 macOS target。
- `RuntimeViewerUsingVision` 编的是同一个源码目录，没有自己的代码。

**引擎管理整个只在 macOS 上编。** `RuntimeViewerEngineManagement` 的五个文件（`RuntimeEngineManager`、
`…Configuration`、`…Event`、`RuntimeProcessAttacher`、`RuntimeSharedCacheEligibility`）第一行都是
`#if os(macOS)`。但真正的 macOS 依赖只有三簇：内嵌 XPC service（local、file、Catalyst）、特权 helper daemon
（`RuntimeViewerHelperClient`，`Package.swift:565-568` 只在 AppKit 平台链接）、Mac Catalyst。`RuntimeEngineManager`
2272 行里约 350 行是 macOS 传输，其余（Bonjour 发现、镜像、共享、心跳、注入设备的引擎 `.injectedTCP`、
socket 记录、文件引擎的簿记）与平台无关；`import ServiceManagement`（`RuntimeEngineManager.swift:6`）甚至没有用到。
`.local` 在 iOS 上本来就在进程里跑（`RuntimeLocalService.swift:40-45` 在 macOS 之外返回 `nil`）。

**文件模式的读取代码本身不依赖 macOS。** `RuntimeEngine(reading:)`、`RuntimeFileImageCatalog`、
`RuntimeDirectoryImageScanner` 都没有平台限定；只有 `RuntimeFileService` 与 `RuntimeFileServiceHost`（XPC 那一层）
是 `#if os(macOS)`。`fileEngineCredential` 返回 `nil`（`RuntimeEngineManager.swift:98`）已经是一道现成的缝。

**iOS 上的设置不存盘。** `Settings.swift:116-122` 在 macOS 之外只持有一份内存里的 `Settings()`，`load()` 与
`flushSynchronously()` 是空操作（`:134-174`）。UIFoundation 的 `SettingsStore` 只用 Foundation 与 Observation，
却整个声明在 `#if Settings && os(macOS)` 里；`SettingsConfiguration`、设置窗口与 `RuntimeViewerSettingsUI` 的 13 个
文件是 AppKit 的。

**AppCore 的 168 个文件里有 41 个只在 macOS 上编**，按阻塞原因分：

| 原因 | 文件数 |
|------|--------|
| 没有硬阻塞，只因为只有 Mac 窗口用（导出、批量导出、特化、生成选项、`AppRoute`、`MainRoute`、来源选择器的内容……） | 24 |
| 要 `RuntimeEngineManager`（含 `MainViewModel`、`AttachToProcessViewModel`、文件引擎的停放与依赖缓存） | 6 |
| MCP，产品上只在 macOS | 4 |
| 用了 RxAppKit / DifferenceKit 的类型（`RxMenuItemRepresentable`、`OutlineMove`、`Differentiable`） | 4 |
| 注入可用性（只差 manifest 条件）与 SIP 检查（要 `/usr/bin/csrutil`） | 2 |
| 用户通知（`UNUserNotificationCenter` 在 iOS 上也有） | 1 |

**AppUI 画值的那一层大多已有 UIKit 分支**（图标、颜色、行文字、内容页的渲染与主题、剪贴板）。缺的是：
内容页的链接属性只在 AppKit 上加（`ContentInterface+Theme.swift:31`），主题不跟随设置与外观
（`ResolvedThemeStream` 只在 AppKit），引擎图标在 iOS 上是空图（`IconDescriptor+Image.swift:45`），`appRouter`
与 `finderClient` 在 iOS 上没有真实实现；路径栏、Find 与来源选择器的适配完全没有 UIKit 对应。`RuntimeViewerUI`
的 40 个视图文件全是 AppKit 的。

**派生数据在 iOS 上不会生效**：`RuntimeDerivedDataSystemIdentity.current()` 在 macOS 与 Catalyst 之外返回 `nil`
（`:96`），存放位置要 macOS 的包结构与 `RuntimeViewerLocalServiceBundleIdentifier`（`RuntimeDerivedDataLocation.swift:58-59`）。
它的 `Platform` 枚举里已经有 `iOS`。

## 根本的设计取舍

### 一、范围：只做越狱版，还是三个版本一起

**只做越狱版**：普通 iOS 与 visionOS 不管，改动少；但三者编的是同一个源码目录，放着不管就会编不过，
以后再捡回来更贵。

**三个版本同一份代码，按能力隐藏**：越狱版全功能，做不到的（列出进程、注入）在运行时判断后隐藏。要多想一层
「这个能力在哪些设备上有」，但不会长出分支。

### 二、窗口模型：UIScene 加 `DocumentState`，还是 UIDocument

RuntimeViewer 的窗口不对应任何要保存的文件：Mac 上用 `NSDocument` 只为了窗口管理与「打开文件」，保存、
打印、还原全关了（`Document.swift:64-84`）。

**UIDocument**：与 Mac 对称；但新窗口（本机运行时、附加的进程）没有文件，要造占位 URL，读写也都要关掉。

**系统文档浏览器做启动页**：只适合打开文件，本机运行时与附加进程得另设入口。

**每个 UIScene 一份 `DocumentState`**：不借文档类型，窗口就是一个 scene；打开磁盘上的文件时经文档选择器或
「用其他 App 打开」开一个新 scene。失去的是 Files App 的最近文档与文档浏览器那一套系统集成。

### 三、设备形态：iPhone、iPad，还是一套

vphone 是一台虚拟 iPhone；Mac 版是侧栏、多栏编辑区、标签页与 Inspector 并排。**一套分栏界面**在 iPad 上并排、
在 iPhone 上折叠成逐级推进的导航，代价是有些布局（多栏编辑区）只能在 iPad 上开。iPhone 优先或 iPad 优先都会让
另一边沦为「能用就行」。

### 四、读磁盘上的文件：在 App 进程里，还是另起进程

Mac 上每个文件在单独的 XPC service 进程里读，坏文件只会让那个进程崩溃（提案 0069）。iOS App 内嵌不了 XPC service。

**在 App 进程里读**：Core 的读取代码现成可用；坏文件可能让 App 崩溃，打开的文件描述符都算在 App 头上
（文件夹的镜像本来就按需打开，提案 0077）。

**越狱版另起子进程**：照 Mac 隔离，但多一套进程管理，普通 iOS 版仍得在进程里读或者不支持。

### 五、引擎管理：一个管理器，还是 iOS 另写一个

**另写**：互不干扰，但 Bonjour 可靠性补丁、镜像、共享、重连这些占八成多的代码要维护两份。

**一个管理器，按平台换传输**：系统引擎怎么起（XPC service 还是进程内）、附加怎么做（helper daemon 还是设备上的
MachInjector）、文件引擎给不给凭据，收进几道平台接缝；其余代码放开平台限定。代价是要把 macOS 的传输从一个大类里
拆到接缝后面，回归风险靠测试兜。

### 六、分层：iOS 前端守不守 Mac 的规则

**守**：ViewModel、路由与状态一律在 `RuntimeViewerAppCore`；通用的 UIKit 视图进 `RuntimeViewerUI`（与 `AppKit/`
并列），UIKit 控件的适配进 `RuntimeViewerAppUI`；iOS target 只放 ViewController、Coordinator 与 scene 生命周期。
要多搬一些东西，但两个前端共用的部分只有一份。

**不守**：iOS target 自己写 ViewModel，快，但正是今天 `MainViewModel` 重名的来路。

### 七、设置：改上游，还是 RuntimeViewer 自己存

**改 UIFoundation 上游**：把 `SettingsStore` 与 `PersistentSettings` 的平台限定放开（它们本就只用 Foundation），
设置页复用现有的 SwiftUI 页面、换一个 UIKit 宿主。要跨仓库发一版 UIFoundation。

**RuntimeViewer 自己存**：不碰上游，但同一份设置在两个平台上走两套持久化，`accessPersistedValues()` 那条
「每个属性都要列」的约束得在第二套里再保证一次。

## 我们选的方向

一至四由用户于 2026-11-18 选定；五至七是调研后提出的做法，随方向一起列给用户、没有被推翻。各提案直接引用，
不再论证。

**一、三个版本同一份代码，越狱版全功能，其余按能力隐藏。** 能力在运行时判断（注入可用性已经是这样问的），
不新增编译开关；`RUNTIME_VIEWER_JAILBROKEN` 只留在今天用到它的注册处。

**二、每个 UIScene 一份 `DocumentState`，不用 UIDocument。** 打开文件经文档选择器与「用其他 App 打开」进一个
新 scene；Mac 的 `Document` 里与平台无关的那部分（MCP 编号、先启动后台工作再建界面、关闭时只关自己带来的成员）
收成两端共用的文档会话。

**三、一套分栏界面，iPhone 上折叠。** 多栏编辑区只在 iPad 上开；标签页、历史、Inspector 两种设备都有。

**四、文件在 App 进程里读。** `fileEngineCredential` 在 iOS 上不给凭据，`RuntimeEngine(reading:)` 直接在进程里读。

**五、一个 `RuntimeEngineManager`，平台差异收进接缝。** iOS 上：系统引擎只有进程内的 `.local`；附加在越狱设备上
由设备自己完成（列进程、注入、等载荷连回来，复用 `.injectedTCP` 那条路）；没有 Catalyst 与 helper daemon。
设备上的 App 同时继续当 Mac 能连的 Bonjour 服务端。

**六、守同一套分层。** `AppTargetBoundaryTests` 扩到 iOS target；iOS 的 `MainViewModel` 与 `MainRoute` 并进 AppCore 的同名类型。

**七、改 UIFoundation 上游放开设置存储的平台限定**，iOS 在 scene 进入后台时写盘（iOS 没有 `applicationShouldTerminate`）；
设置页复用 SwiftUI 页面，宿主换成 UIKit。

### 这个方向放弃了什么

- **iOS 上读文件的隔离**：坏文件能让 App 崩溃。
- **UIDocument 的系统集成**：Files App 里的最近文档、文档浏览器启动页。
- **iPhone 上的多栏编辑区。**
- **普通 iOS 版与 visionOS 版的注入和进程列表**：设备不允许，隐藏而不是报错。
- **iOS 上的 Sparkle 更新、特权 helper、Mac Catalyst、命令行 host 与 MCP。**
- **iOS 前端的独立演化**：它的 ViewModel 全在 AppCore，Mac 改一处 ViewModel 两端一起变。

## 分阶段设想

五步，①②③可以并行，④依赖①，⑤依赖全部。顺序与拆法不是承诺，实际提案可以调整。

```text
① engine management on iOS ──┐
② settings storage on iOS ───┼──► ④ AppCore off the macOS gate, AppUI's UIKit side ──► ⑤ iOS front end, feature by feature
③ app logic into AppCore,  ──┘
   scene window model
```

1. **引擎管理跨平台**——放开 `RuntimeViewerEngineManagement` 里与平台无关的部分；系统引擎、附加、文件凭据、共享缓存
   的进程探测收进平台接缝；越狱设备上自己附加本机进程；iOS 上文件在进程里读。Mac 行为零变化。
2. **iOS 的设置存储**——UIFoundation 上游放开 `SettingsStore` 与 `PersistentSettings`，RuntimeViewer 的 `Settings` 在 iOS
   上真正读写，scene 进入后台时写盘；派生数据的系统身份与存放位置是否一并放开，在这篇里定。
3. **App 层逻辑下沉与 iOS 窗口模型**——把 macOS App target 里与平台无关的逻辑收进 AppCore（文档会话、打开文件、
   设置生命周期、导出日志、派生数据的度量与删除、启动顺序），iOS 改成每个 scene 一份 `DocumentState` 并打开多窗口，
   iOS 的 `MainViewModel` 与 `MainRoute` 并进 AppCore，边界测试扩到 iOS target。由 0102 做完，其中两处有变：
   `MainViewModel` 与 `MainRoute` 的合并挪到第四步；派生数据与启动顺序不另立共用类型（理由在 0102 的决策日志）。
4. **AppCore 放开平台限定、补齐 AppUI 的 UIKit 一侧**——24 个没有硬阻塞的文件先放开，RxAppKit / DifferenceKit 的类型
   换成平台无关的值，等①落地再放开那 6 个；AppUI 补上链接属性、主题跟随、引擎图标、`appRouter` 与 `finderClient` 的
   iOS 实现；iOS 的 `MainViewModel` 与 `MainRoute` 并进 AppCore（从第三步挪来），iOS 照 Mac 走 `SelectionRoute`。
5. **iOS 前端逐项补齐**——Inspector、点击跳转、标签页与历史、Find、Report、书签、Filter Scope、导出（走分享面板）、
   特化、生成选项、切换来源与附加进程、文件模式、设置页（外观、主题、转换选项三页已由 0101 提前做完，其余页随各自的
   功能补上），iPad 上再加多栏编辑区。可能拆成几篇。

## 不在此愿景内

- **Mac 版的功能变化。** 这里只搬家与开缝，Mac 的行为不变。
- **`RuntimeEngine` 的请求集、任何线路协议、`RuntimeSource`。**
- **iOS 上的命令行工具与 MCP。**
- **App Store 上架**：越狱版的权限本来就上不了架；普通版怎么分发另议。
- **visionOS 的空间界面**：visionOS 版只跟着编过、按能力隐藏。
- **tvOS 与 watchOS 前端**。

## 待确认

各提案里再定，不影响方向：

- iOS 上有没有对应 `BackgroundWorkProcessActivity`（防 App Nap）的东西要做：越狱版已经防挂起，普通版在后台被挂起时
  后台索引怎么办。
- 派生数据在 iOS 上开不开：本机引擎在 App 进程里，开了就是 App 自己读写。
- 工具栏的活动进度、来源选择器在 iPhone 上放哪。

## 相关提案

| 提案 | 状态 | 它推进了愿景的哪一部分 |
|------|------|------------------------|
| [0043-jailbroken-ios-injection](../Evolutions/0043-jailbroken-ios-injection.md) | Implemented | 前置：越狱版列出设备进程并注入（供 Mac 使用） |
| [0047-open-command-registry-and-injection-module](../Evolutions/0047-open-command-registry-and-injection-module.md) | Implemented | 前置：注入搬出 Core，iOS 也能链接 |
| [0091-app-core-ui-split](../Evolutions/0091-app-core-ui-split.md) | Implemented | 前置：AppCore 与 AppUI 分开 |
| [0094-app-core-without-ui-models](../Evolutions/0094-app-core-without-ui-models.md) | Implemented | 前置：AppCore 不用 AppKit/UIKit 类型，图标、颜色与文字改成值 |
| [0096-view-models-to-app-core](../Evolutions/0096-view-models-to-app-core.md) | Implemented | 前置：macOS App 的 ViewModel 全部进 AppCore（仍只在 macOS 上编） |
| [0099-engine-management-on-ios](../Evolutions/0099-engine-management-on-ios.md) | Implemented | 第一步：引擎管理在 iOS 与 visionOS 上可用，iOS app 改由管理器启动引擎 |
| [0100-settings-storage-on-ios](../Evolutions/0100-settings-storage-on-ios.md) | Implemented | 第二步：iOS 上的设置真正存盘（上游 UIFoundation 放开设置存储的平台限定）；设置页与派生数据不在这一步 |
| [0101-settings-screen-on-ios](../Evolutions/0101-settings-screen-on-ios.md) | Implemented | 第五步里的设置页，提前做：外观、主题、转换选项三页，复用 Mac 版页面；外观一节照 iOS「显示与亮度」画 |
| [0102-window-model-on-ios](../Evolutions/0102-window-model-on-ios.md) | Implemented | 第三步：每个窗口一份共用的文档会话、iPad 多窗口，iOS 能打开磁盘上的文件；`MainViewModel` / `MainRoute` 的合并挪到第四步 |

---

> **愿景是活文档**，随认识加深可以修订，修订时更新「最后更新」。

# Draft - iOS 的窗口模型与打开文件

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-21
- **所属愿景**: [iOS 版功能对齐](../Visions/IOSFeatureParity.md)（第三步「App 层逻辑下沉与 iOS 窗口模型」；`MainViewModel` / `MainRoute` 的合并按用户决定挪到第四步）
- **关联提案**: [0099-engine-management-on-ios](0099-engine-management-on-ios.md)（引擎管理在 iOS 上可用、文件在进程里读）、[0100-settings-storage-on-ios](0100-settings-storage-on-ios.md)、[0101-settings-screen-on-ios](0101-settings-screen-on-ios.md)、[0055-engine-scoped-background-work](0055-engine-scoped-background-work.md)、[0058-runtime-engine-session](0058-runtime-engine-session.md)、[0069-file-mode](0069-file-mode.md)、[0077-file-folders](0077-file-folders.md)
- **实现分支 / PR**: `feature/window-model-on-ios`，从 `next` 切出，worktree 在 `.worktrees/RuntimeViewer-WindowModelOnIOS`
- **配套文档**: 待定 —— 预计无单独文档，规则写进 `RuntimeViewerUsingUIKit/AGENTS.md`
- **网页版**: 同目录同名的 `.html`

## 摘要

iOS、越狱版 iOS 与 visionOS 的 RuntimeViewer 改成「每个窗口一份文档会话」：Mac 的 `Document` 里与平台无关的那部分
（编号、先启动引擎的后台工作再建界面、关闭时只关自己带来的成员）收成 AppCore 里两端共用的 `DocumentSession`，iOS 每个
scene 持有一个，iPad 与 visionOS 能开多个窗口。在此之上，iOS 能打开磁盘上的文件：侧栏根页齿轮旁多一个打开按钮，经文档
选择器选文件（越狱版另有「Open Path…」按绝对路径打开），也接收「文件」App 里的「用其他 App 打开」；文件在 App 进程里读，
能开多窗口的设备上开一个新窗口，iPhone 上叠在当前窗口上面、关掉就回到本机。打开文件、导出日志的格式化、引擎管理器跟随
设置这几段平台无关的逻辑进 AppCore，为此 AppCore 在所有平台上链接 `RuntimeViewerEngineManagement`。边界测试扩到 iOS
target。`MainViewModel` / `MainRoute` 的合并留到第四步。Mac 的行为不变。

## 动机

完整动机见愿景《[iOS 版功能对齐](../Visions/IOSFeatureParity.md)》。这一步特有的：

- **iOS 的窗口从不启动、也不结束引擎的后台工作。** `SceneDelegate` 直接 `DocumentState()`
  （`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/App/SceneDelegate.swift:15`），既不调 `startBackgroundWork()`
  也不调 `documentWillClose()`；`DocumentState` 的会话（`RuntimeEngineSession`，提案 0058）因此一直是「没有后台工作」的
  那种，Find 语料、交叉引用的预建、后台索引在 iOS 上都不会跑，多开一个窗口也没有人收尾。Mac 的 `Document` 把这两步写死在
  `makeWindowControllers` 与 `close()` 里（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift:40-54`），
  第二个前端只能照抄一遍。
- **iOS 上打不开磁盘上的文件。** 0099 让引擎管理器在 iOS 上能在进程里读文件（`RuntimeEngineManager.startReading(_:)`
  走 `.inThisProcess`，`RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/RuntimeEngineManager.swift:2141-2219`），
  但没有任何入口；打开文件的流程（看文件是什么、选依赖缓存、开窗、读失败时说明原因）全在 Mac 的 `FileController` 里，
  夹着 `NSDocumentController` 与 `NSAlert`（`App/FileController.swift:53-110`）。用户要在 vphone 上看到效果，这是这一步
  最能看见的部分。
- **iOS 只有一个窗口。** iOS 与越狱版的 `Info.plist` 关着 `UIApplicationSupportsMultipleScenes`
  （`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Info.plist:11-12`、`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit-Jailbroken-Info.plist:11-12`），
  iPad 上不能并排看两个来源；visionOS 开着，但每个窗口都是同一个 `.local` 的新 `DocumentState`。
- **分层在 iOS target 上没人看着。** `AppTargetBoundaryTests` 只扫 macOS target
  （`RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/AppTargetBoundaryTests.swift:18`），iOS target 自己声明了
  `MainViewModel`（`RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Main/MainViewModel.swift:7`），愿景第六条说要扩过去。

## 前期调研

- **Mac 的 `Document`**（85 行，`App/Document.swift`）：静态计数器给 MCP 编号（:6-12）；`init(runtimeEngine:)` 建
  `DocumentState`（:20-23）；`makeWindowControllers` 先 `documentState.startBackgroundWork()` 再加窗口控制器（:40-48）；
  `close()` 先 `documentWillClose()`（:50-54）；其余是关掉保存、打印的 `NSDocument` 覆写。编号只有
  `AppMCPBridgeDocumentProvider` 读（`App/AppMCPBridgeDocumentProvider.swift:21,32`）。
- **`DocumentState` 在 iOS 上本来就编**（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Document/DocumentState.swift`，
  599 行，没有整体平台条件）；`startBackgroundWork()`（:343-346）经 `runtimeEngineBackgroundWorkRegistry` 加入引擎的后台
  工作，`documentWillClose()`（:435-440）离开并关掉 Find 会话，只能各调一次。用到的 `RuntimeEngineBackgroundWork`、
  `RuntimeEngineSession`、`BackgroundWorkProcessActivity` 都没有平台条件。
- **Mac 打开文件**（`App/FileController.swift`）：平台无关的是 `RuntimeFile(contentsOf:)` 在主线程外读文件头（:72-75）、
  已列出的文件优先、否则配默认依赖缓存（:76-81，`Settings.File.defaultDependencyCache(for:)`）、
  `runtimeEngineManager.startReading(_:)`（:55）、`waitUntilFileIsRead(by:)`（:89）、`runtimeFileEngineParking.start()`（:37）；
  只属于 AppKit 的是 `NSDocumentController` 的 `addDocument` / `noteNewRecentDocumentURL`、开窗、读失败的 `NSAlert`。
  `DocumentController`（52 行）把 File › Open… 的 URL 交给它。
- **在进程里读文件**：`startReading(_:)` 在 `.inThisProcess` 下返回前就读完文件，读不了就抛错、什么都不列（:2134-2219 的文档
  注释）；这样的引擎「从不挂起」——`suspendFileEngine(_:)` 只在 file service 下有效（:2255-2256）。能把文件引擎从列表里
  拿掉的只有 `terminateRuntimeEngine(for:because:)`（:921 起，:940-946 处理文件引擎）。管理器的 `FileReading` 是
  internal（:109、:2095-2106），外面看不出文件在哪读。
- **放走文件引擎**：`RuntimeFileEngineParking`（`RuntimeViewerAppCore/Engine/RuntimeFileEngineParking.swift`，整个
  `#if os(macOS)`）在最后一个文档离开 30 秒后挂起文件引擎，靠的是 `runtimeEngineBackgroundWorkRegistry.occupancyChanges`
  （:42-44）。对在进程里读的引擎它什么也做不了，所以 iOS 上关掉的文件一直占着解析结果与文件描述符，直到 App 退出。
- **依赖缓存的默认配对**：`Settings.File.platformNamesPairedWithThisMac` 写死 `["macOS", "macCatalyst"]`
  （`RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+File.swift:111`），在 iOS 上一个 iOS 的二进制配不到本机的
  缓存，只能单独读。`.systemDyldSharedCache` 在 Core 里读 `FullDyldCache.cachedHost`，打不开时报
  `dependencyCacheUnavailable`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Images/RuntimeFileImageCatalog.swift:136-146`）。
  **推测、待实测**：越狱版（无沙盒）能打开设备上的 dyld 缓存；普通 iOS 的沙盒能不能读，没验证过。
- **AppCore 的依赖**：`RuntimeViewerEngineManagement` 只在 AppKit 平台链接（`RuntimeViewerPackages/Package.swift:460`，
  `appkitPlatforms` 是 `[.macOS]`，:90）；0099 之后它已经能在 iOS 上编，iOS App 直接链接了它。AppCore 191 个文件里 48 个
  整个包在 `#if os(macOS)` 里，`MainViewModel`（627 行）与 `MainRoute` 在其中。
- **两份 `MainRoute` 没有一个 case 相同**：Mac 17 个（`main(RuntimeEngine)`、各种 sheet 与 popover……，
  `RuntimeViewerAppCore/Main/MainRoute.swift`），iOS 4 个（`initial`、`select`、`inspect`、`settings`，
  `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Main/MainCoordinator.swift:10-16`）；iOS 的 `MainViewModel` 是空壳
  （9 行）。合并要先放开第四步那批文件，所以留到第四步（见决策日志）。
- **导出日志**（`App/DebugMenuController.swift:45-56`）：`OSLogStore(scope: .currentProcessIdentifier)` 取本次启动以来、
  subsystem 含 `RuntimeViewer` 的条目，格式化成 `[HH:mm:ss.SSS] [subsystem/category] message`；iOS 15 起可用。菜单、
  `NSSavePanel`、`NSWorkspace` 是 AppKit 的。
- **派生数据的度量与删除**：平台无关的部分早已在 Core 的 `RuntimeDerivedDataMaintenance`（`allocatedByteCount(at:)`、
  `deleteAll(at:)`）里，Mac 的 `RuntimeDerivedDataController`（104 行）只剩设置页客户端的接线、`NSAlert` 确认与 Finder；
  0100 定了 iOS 上不开派生数据。
- **设置生命周期**：Mac 异步 `load()`、终止前写盘（`App/SettingsLifecycleController.swift:34-73`），iOS 同步
  `loadSynchronously()`、进后台时写盘（0100）；两端能共用的只有「读完设置后让引擎管理器跟随 Settings › Developer 的共享缓存
  开关」（Mac :44-52）。iOS 上这个开关的生效值恒为 `true`（`Settings.Developer.effectiveSharesSharedCacheImages`，
  `Settings+Developer.swift:44-47`，Developer 页在 iOS 上没有），与管理器的默认值相同。
- **启动顺序**：两端都要「先读设置、命令扩展早于任何引擎」，但注册调用不同（Mac 在 `AppDelegate.main()` 里
  `RuntimeInjection.install()`，iOS 经 `InjectionServiceRegistrar` 带上设备的注入服务），能共用的只有两行，已写在两份
  `AGENTS.md` 里（`RuntimeViewerUsingUIKit/AGENTS.md`「Launch order」）。
- **iOS 的 scene**：三份 `Info.plist` 只有一个 "Default Configuration" 指向 `SceneDelegate`；没有
  `CFBundleDocumentTypes`、`LSSupportsOpeningDocumentsInPlace`；`SceneDelegate` 不看 `connectionOptions`。iPhone 上即使
  打开 `UIApplicationSupportsMultipleScenes`，`UIApplication.supportsMultipleScenes` 也是 `false`，只有一个窗口。
- **边界测试**：`AppTargetBoundaryTests` 有三条检查——目录存在且多于 50 个文件（:33-38）、没有以 `ViewModel` 结尾的类型
  （:41-56）、继承子句里没有 `ViewModel<…>` / `CellViewModel` / `ViewModelProtocol`（:59-77）；iOS target 只有 23 个文件，
  扩过去今天会报 `Main/MainViewModel.swift:7` 两次。
- **iOS 侧栏根页**：齿轮按钮由 `SidebarCoordinator` 放在根页的 `rightBarButtonItem`（`Sidebar/SidebarCoordinator.swift:34,52-56`），
  经 `SidebarCoordinatorDelegate.sidebarCoordinatorDidRequestSettings(_:)` 交给 `MainCoordinator`。

## 提议方案

1. **AppCore 在所有平台上链接引擎管理**：`Package.swift` 里对 `RuntimeViewerEngineManagement` 的依赖一律去掉平台条件
   （AppCore、AppUI、SettingsUI 与引擎管理的测试 target 四处；它从 0099 起各平台都编）；`HelperClient`、`CatalystExtensions`、
   `Injection` 照旧只在 macOS。`MainViewModel`、`MainRoute` 及其依赖的那批文件仍是 `#if os(macOS)`，第四步再放开。
2. **共用的文档会话 `DocumentSession`**（AppCore `Document/`）：持有 `DocumentState`，有一个进程内从 1 起的编号；`open()`
   在界面绑定之前启动引擎的后台工作，`close()` 离开后台工作、关掉这个文档带来的成员——开过没开过都收尾，关过之后
   `open()` 不再生效；两者都只生效一次。Mac 的 `Document` 持有一个，MCP 编号写成 `"document\(session.number)"`，行为不变。
3. **iOS 的窗口模型**：
   - iOS 与越狱版打开 `UIApplicationSupportsMultipleScenes`（visionOS 本来就开着）。
   - AppCore 新增 `DocumentSessionRegistry`：按窗口的标识（`UISceneSession.persistentIdentifier`）给每个窗口一个会话，
     窗口第一次连接时建、进程活着时一直保留（scene 被系统断开再连回来用的还是它），窗口被用户关掉
     （`application(_:didDiscardSceneSessions:)`）时 `close()`。为文件开的新窗口先在注册表里预留引擎，拿一个请求号，
     scene 连接时凭请求号取走；取不到（App 重启后系统恢复的窗口）就用本机。
   - `SceneDelegate` 从注册表取会话，先 `open()` 再建界面，与 Mac 的顺序相同；iPad 的「新窗口」与恢复的窗口都从本机开始。
4. **打开文件的共用部分 `RuntimeFileOpener`**（AppCore `Engine/`，与 parking、依赖缓存放在一起）：`startReading(fileAt:)` 在主线程外读文件头，已列出的文件
   优先，否则配默认依赖缓存，交给 `runtimeEngineManager.startReading(_:)`，返回引擎；URL 带安全作用域时开始访问并一直保持，
   直到引擎被放走（文件夹里的镜像是用到时才打开的，提案 0077）。`letGoOfFile(readBy:)` 放走一个引擎：在 file service 里读的
   挂起（与今天相同），在进程里读的从管理器拿掉并结束访问。Mac 的 `FileController` 改用它，`NSDocumentController`、开窗、
   Open Recent、读失败的提示仍在 App 里。
5. **`RuntimeFileEngineParking` 放开平台限定**：最后一个文档离开 30 秒后调 `runtimeFileOpener.letGoOfFile(readBy:)`；
   Mac 上效果与今天相同，iOS 上关掉的文件 30 秒后释放内存与文件描述符，再打开就重新读。为此
   `RuntimeEngineManager` 公开一个只读的 `readsFilesInThisProcess`。
6. **依赖缓存按本机配对**：`Settings.File.platformNamesPairedWithThisMac` 改名为 `platformNamesPairedWithThisDevice`、
   `canPairWithThisMacsCache(_:)` 改名为 `canPairWithThisDevicesCache(_:)`，按平台取值——macOS 上仍是 macOS 与 Mac
   Catalyst，iOS 上是 iOS，visionOS 上是 visionOS。在进程里读的文件按默认配了本机缓存、而本机缓存打不开
   （`RuntimeFileError.dependencyCacheUnavailable`）时，`RuntimeFileOpener` 改为单独读这个文件，而不是整个打不开。
7. **iOS 的打开入口**（iOS target `App/FileController.swift`，Mac 同名控制器的对应物）：
   - 侧栏根页齿轮旁多一个打开按钮。普通 iOS 与 visionOS 上按下就是文档选择器（文件、文件夹都能选）；越狱版上是一个菜单：
     「Choose File…」与「Open Path…」（输入或粘贴绝对路径）。「越狱版」在运行时判断：App 没有容器（主目录不在
     `…/Containers/Data/Application/` 下）。
   - 「用其他 App 打开」：iOS 与越狱版的 `Info.plist` 声明能打开 `public.data` 与 `public.directory`（Mach-O 与 dyld 缓存
     没有专门的类型，bundle 与文件夹是目录），`LSSupportsOpeningDocumentsInPlace` 打开、就地读；`SceneDelegate` 在连接时与
     `scene(_:openURLContexts:)` 里把 URL 交给 `FileController`。
   - 读成功后：能开多窗口的设备上，在注册表里预留引擎，经 `UIApplication.activateSceneSession(for:)` 开一个新窗口；iPhone 上，
     给文件建一个会话与一套 `MainCoordinator`，全屏叠在当前窗口上面。文件窗口的侧栏根页左上角有关闭按钮：叠着的就收起并
     `close()` 会话，独立窗口就请系统销毁这个 scene。
   - 读不了：文件在进程里读，`startReading(fileAt:)` 返回前就知道，所以不开任何窗口，在当前窗口弹一个说明原因的提示。
8. **平台无关的小块逻辑进 AppCore**：`ApplicationLogs.formattedEntries(since:)`（导出日志的取条目与格式化，Mac 的 Debug ›
   Export Logs 改用它，iOS 不加入口）；`RuntimeEngineManagerSettingsFollower`（引擎管理器跟随共享缓存开关；Mac 的设置
   生命周期控制器在读完设置后启动它，iOS 的 `AppDelegate` 在引擎管理器起来之后启动它）。
9. **边界测试扩到 iOS target**：`AppTargetBoundaryTests` 对两个 App target 各跑一遍（各自的最少文件数），iOS 的
   `MainViewModel` 列为唯一例外，第四步合并后删掉这条例外。
10. **文档**：`RuntimeViewerUsingUIKit/AGENTS.md` 加「窗口与文档会话」「打开文件」两节；`RuntimeViewerUsingAppKit/AGENTS.md`
    里 `FileController`、`Document` 的描述改成用 AppCore 的类型；根 `AGENTS.md` 的 AppCore 一行与 *Key Architectural
    Patterns* 里文档的说法补上 `DocumentSession`；愿景表与两份索引登记本篇。

### 非目标

- **合并 `MainViewModel` / `MainRoute`**：第四步与 AppCore 放开平台限定一起做，届时 iOS 的选中与 Inspector 照 Mac 走
  `SelectionRoute`（用户已定）。这一步 iOS 的路由不动，打开文件也不加路由 case。
- **iOS 上的切换来源、最近打开、依赖缓存的选择与 Settings › Files 页**：愿景第五步。iPhone 上回到本机靠文件窗口的关闭按钮。
- **iOS 上导出日志的入口、派生数据**：用户定了导出日志只下沉逻辑；派生数据照 0100 不开。
- **派生数据的度量与删除下沉**：平台无关的部分已经在 Core 的 `RuntimeDerivedDataMaintenance`，Mac 控制器剩下的都是界面与
  客户端接线，iOS 又不用，不另立类型。
- **启动顺序写成共用代码**：两端能共用的只有「先读设置、命令扩展早于引擎」两行，调用还不同，继续写在两份 `AGENTS.md` 里。
- **把 iOS target 里的通用 UIKit 小工具搬进 `RuntimeViewerUI`**（`Base/`、`Utils/`、分栏转场扩展）：第四步补 AppUI 的 UIKit
  一侧时一起整理。
- **在单独的进程里读文件**：愿景已定 iOS 上在 App 进程里读。
- **Load Frameworks、附加进程**：iOS 上没有。

## 改动地图

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerPackages/Package.swift` | 修改 | 对 `RuntimeViewerEngineManagement` 的四处依赖（AppCore、AppUI、SettingsUI、引擎管理的测试）都去掉 `condition` | 打开文件、跟随设置的共用逻辑要用管理器；守卫测试把清单里任何一处带平台条件的模块都当作 macOS 专属 | 1 |
| `RuntimeViewerAppCore/Document/DocumentSession.swift` · `DocumentSession` | 新增 | 编号、`documentState`、`open()`、`close()`，各只生效一次 | 两端共用的文档会话 | 1 |
| `RuntimeViewerUsingAppKit/.../App/Document.swift` · `Document` | 修改 | 持有 `DocumentSession`；`makeWindowControllers` 调 `open()`，`close()` 调会话的 `close()`；`mcpIdentifier` 由编号拼出；`documentState` 转发会话的 | Mac 改用共用会话，行为不变 | 1 |
| `RuntimeViewerUsingAppKit/.../App/AppMCPBridgeDocumentProvider.swift` | 修改（可能不动） | 只要 `Document.mcpIdentifier`、`documentState` 的形状不变就不动 | 同上 | 1 |
| `Tests/RuntimeViewerAppCoreTests/DocumentSessionTests.swift` | 新增 | 只开一次、只关一次、没开就关、编号递增 | 会话的契约 | 1 |
| `RuntimeViewerAppCore/Document/DocumentSessionRegistry.swift` · `DocumentSessionRegistry` | 新增 | 按窗口标识给会话、预留引擎与请求号、窗口关掉时关会话 | iOS 每个窗口一份会话；可在 macOS 上测 | 2 |
| `Tests/RuntimeViewerAppCoreTests/DocumentSessionRegistryTests.swift` | 新增 | 见步骤 2 的行为清单 | 注册表的契约 | 2 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Info.plist`、`RuntimeViewerUsingUIKit-Jailbroken-Info.plist` | 修改 | `UIApplicationSupportsMultipleScenes` 改 `true`；`NSUserActivityTypes` 加文件窗口的活动类型 | 多窗口；新窗口凭活动带请求号 | 2 |
| `RuntimeViewerUsingVision/Info.plist` | 修改 | `NSUserActivityTypes` 同上 | visionOS 也开文件窗口 | 2 |
| `RuntimeViewerUsingUIKit/.../App/SceneDelegate.swift` | 修改 | 从注册表取会话（看 `connectionOptions.userActivities` 里的请求号），先 `open()` 再建界面；去掉直接 `DocumentState()` | iOS 的窗口模型 | 2 |
| `RuntimeViewerUsingUIKit/.../App/AppDelegate.swift` | 修改 | `didDiscardSceneSessions` 交给注册表关会话 | 窗口关掉时收尾 | 2 |
| `RuntimeViewerEngineManagement/RuntimeEngineManager.swift` | 修改 | 公开只读的 `readsFilesInThisProcess` | 放走文件引擎时分两种做法 | 3 |
| `RuntimeViewerAppCore/Engine/RuntimeFileOpener.swift` · `RuntimeFileOpener` | 新增 | `startReading(fileAt:)`、`letGoOfFile(readBy:)`、安全作用域访问的保持与结束；`@DependencyEntry` 的 `runtimeFileOpener` | 打开文件的共用部分 | 3 |
| `RuntimeViewerAppCore/Engine/RuntimeFileEngineParking.swift` | 修改 | 去掉 `#if os(macOS)`；放走引擎改调 `runtimeFileOpener.letGoOfFile(readBy:)` | iOS 上关掉的文件也释放 | 3 |
| `RuntimeViewerSettings/Settings+File.swift` | 修改 | `platformNamesPairedWithThisMac` 改名 `platformNamesPairedWithThisDevice` 并按平台取值；`canPairWithThisMacsCache(_:)` 改名 `canPairWithThisDevicesCache(_:)`（调用者 `RuntimeFileDependencyCaches` 跟着改） | iOS 的二进制配上设备自己的缓存 | 3 |
| `RuntimeViewerUsingAppKit/.../App/FileController.swift` | 修改 | 读文件头、选缓存、`startReading` 改调 `runtimeFileOpener.startReading(fileAt:)`；其余不变 | Mac 改用共用部分 | 3 |
| `Tests/RuntimeViewerAppCoreTests/RuntimeFileOpenerTests.swift`、`RuntimeFileEngineParkingTests`（已有的补用例） | 新增 / 修改 | 见步骤 3 的行为清单 | 打开与放走的契约 | 3 |
| `Tests/RuntimeViewerSettingsTests/…`（`Settings.File` 的已有测试） | 修改 | 跟着改名；macOS 上配对不变 | 防回归 | 3 |
| `RuntimeViewerUsingUIKit/.../App/FileController.swift` · `FileController` | 新增 | 文档选择器、「Open Path…」、读成功后开新窗口或叠在上面、读失败的提示、接收 URL | iOS 的打开入口 | 4 |
| `RuntimeViewerUsingUIKit/.../Sidebar/SidebarCoordinator.swift` | 修改 | 根页齿轮旁加打开按钮（越狱版是菜单）；文件窗口的根页加关闭按钮；`SidebarCoordinatorDelegate` 加「要打开文件」「要关掉窗口」 | 入口与出口 | 4 |
| `RuntimeViewerUsingUIKit/.../Main/MainCoordinator.swift` | 修改 | 把两个新请求转给 `FileController` / 文件窗口的持有者；知道自己是不是文件窗口 | 同上 | 4 |
| `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Info.plist`、`…-Jailbroken-Info.plist` | 修改 | `CFBundleDocumentTypes`（`public.data`、`public.directory`，`LSHandlerRank` = `Alternate`）、`LSSupportsOpeningDocumentsInPlace` = `true` | 「用其他 App 打开」 | 4 |
| `RuntimeViewerUsingUIKit/.../App/SceneDelegate.swift` | 修改 | 连接时的 `urlContexts` 与 `scene(_:openURLContexts:)` 交给 `FileController` | 同上 | 4 |
| `RuntimeViewerAppCore/App/ApplicationLogs.swift` · `ApplicationLogs` | 新增 | `formattedEntries(since:)` | 导出日志的共用部分 | 5 |
| `RuntimeViewerUsingAppKit/.../App/DebugMenuController.swift` | 修改 | 改用 `ApplicationLogs`；菜单、保存面板、Finder 不变 | Mac 改用共用部分 | 5 |
| `RuntimeViewerAppCore/Engine/RuntimeEngineManagerSettingsFollower.swift` · `RuntimeEngineManagerSettingsFollower` | 新增 | `startFollowing()`：共享缓存开关的生效值写进管理器，之后每次变化都写 | 两端共用 | 5 |
| `RuntimeViewerUsingAppKit/.../App/SettingsLifecycleController.swift` | 修改 | `followSharedCacheSharing()` 换成启动 follower | 同上 | 5 |
| `RuntimeViewerUsingUIKit/.../App/AppDelegate.swift` | 修改 | 引擎管理器起来之后启动 follower（iOS 的设置生命周期控制器不动） | iOS 跟 Mac 一样跟随；在读设置时碰管理器会让引擎早于命令扩展起来 | 5 |
| `Tests/RuntimeViewerAppCoreTests/ApplicationLogsTests.swift`、`RuntimeEngineManagerSettingsFollowerTests.swift` | 新增 | 见步骤 5 的行为清单 | 契约 | 5 |
| `Tests/RuntimeViewerAppCoreTests/AppTargetBoundaryTests.swift` | 修改 | 两个 App target 参数化（路径、最少文件数）；iOS 的 `MainViewModel` 列为例外并注明第四步删 | 分层扩到 iOS | 6 |
| `RuntimeViewerUsingUIKit/AGENTS.md`、`RuntimeViewerUsingAppKit/AGENTS.md`、根 `AGENTS.md`、愿景、两份索引 | 修改 | 见方案第 10 条 | 文档 | 7 |

## 架构图

改了什么（模块与类型）：

```text
RuntimeViewerAppCore  (iOS / visionOS / macOS)
  ~ depends on RuntimeViewerEngineManagement: macOS only -> every platform
  + Document/DocumentSession              number, documentState, open() -> startBackgroundWork(), close() -> documentWillClose()
  + Document/DocumentSessionRegistry      window ID -> DocumentSession; reserved engine by request ID; discard -> close()
  + Engine/RuntimeFileOpener                URL -> RuntimeFile -> runtimeEngineManager.startReading(_:); security-scoped access
  ~ Engine/RuntimeFileEngineParking       #if os(macOS) removed; lets go through RuntimeFileOpener
  + App/ApplicationLogs           OSLogStore -> "[time] [subsystem/category] message"
  + Engine/RuntimeEngineManagerSettingsFollower   developer.effectiveSharesSharedCacheImages -> manager
    Main/MainViewModel, Main/MainRoute, App/AppRoute ...   still #if os(macOS) (step 4)

RuntimeViewerEngineManagement
  + RuntimeEngineManager.readsFilesInThisProcess
RuntimeViewerSettings
  ~ Settings.File.platformNamesPairedWithThisMac -> platformNamesPairedWithThisDevice (per platform)

macOS app (behaviour unchanged)
  ~ Document                 holds a DocumentSession; mcpIdentifier = "document\(number)"
  ~ FileController           -> RuntimeFileOpener; keeps NSDocumentController, Open Recent, NSAlert
  ~ DebugMenuController      -> ApplicationLogs; keeps the menu, NSSavePanel, Finder
  ~ SettingsLifecycleController -> RuntimeEngineManagerSettingsFollower

iOS / jailbroken / visionOS app
  ~ Info.plist               multiple scenes, NSUserActivityTypes, CFBundleDocumentTypes, open in place
  ~ AppDelegate              didDiscardSceneSessions -> registry
  ~ SceneDelegate            session from registry, open() before the UI; URLs -> FileController
  + App/FileController       document picker, Open Path... (no container), new window or stacked window
  ~ Sidebar/SidebarCoordinator  open button beside the gear; close button in a file window
  ~ Main/MainCoordinator     forwards open / close
  ~ App/SettingsLifecycleController -> RuntimeEngineManagerSettingsFollower

Tests
  ~ AppTargetBoundaryTests   macOS and iOS targets; iOS MainViewModel excepted until step 4
  + DocumentSessionTests, DocumentSessionRegistryTests, RuntimeFileOpenerTests,
    ApplicationLogsTests, RuntimeEngineManagerSettingsFollowerTests
```

iOS 上打开一个文件（调用链）：

```text
sidebar root: open button / Open Path... / Open In from Files (scene URL contexts)
  -> SidebarCoordinatorDelegate.sidebarCoordinatorDidRequestOpenFile -> MainCoordinator
  -> FileController (iOS app)
       UIDocumentPickerViewController | path prompt
  -> RuntimeFileOpener.startReading(fileAt:)            AppCore
       RuntimeFile(contentsOf:) off the main actor
       listed file | Settings.File.defaultDependencyCache(for:)
       url.startAccessingSecurityScopedResource()       kept until the engine is let go
       RuntimeEngineManager.startReading(_:)            .inThisProcess: read before it returns
  -> failed: alert in the current window, no window opens
  -> UIApplication.supportsMultipleScenes?
       yes: registry.reserve(engine) -> request ID
            -> UIApplication.activateSceneSession(for: request with NSUserActivity(request ID))
            -> SceneDelegate.scene(_:willConnectTo:) -> registry.session(forWindow:requestID:)
            -> DocumentSession.open() -> MainCoordinator
       no:  DocumentSession(runtimeEngine:).open() -> MainCoordinator, presented full screen
            close button -> session.close() -> dismiss
  -> last document leaves the engine -> RuntimeFileEngineParking (30 s)
       -> RuntimeFileOpener.letGoOfFile(readBy:)
            in this process: terminateRuntimeEngine(for:) + stopAccessingSecurityScopedResource()
            in the file service (macOS): suspendFileEngine(_:)
```

## 详细设计

```swift
// RuntimeViewerAppCore/Document/DocumentSession.swift
/// One window's document: its `DocumentState`, and the two steps every
/// front end takes with it — joining the engine's background work before the
/// window's UI binds, and leaving it, with what the document brought into
/// being, when the window goes.
@MainActor
public final class DocumentSession {
    /// The order this session was made in within this process, from 1.
    public let number: Int

    public let documentState: DocumentState

    public init(runtimeEngine: RuntimeEngine)

    /// Joins the engine's background work. Call before the document's UI
    /// binds; only the first call does anything.
    public func open()

    /// Leaves the engine's background work and closes what this document
    /// brought into being, opened or not. Only the first call does anything,
    /// and `open()` does nothing after it.
    public func close()
}
```

Mac 的调用点：

```swift
final class Document: NSDocument {
    let session: DocumentSession
    var documentState: DocumentState { session.documentState }
    var mcpIdentifier: String { "document\(session.number)" }

    override func makeWindowControllers() {
        session.open()
        addWindowController(mainCoordinator.windowController)
    }

    override func close() {
        session.close()
        super.close()
    }
}
```

```swift
// RuntimeViewerAppCore/Document/DocumentSessionRegistry.swift
/// The document session of each window a scene-based front end shows,
/// by the window's identifier (a `UISceneSession.persistentIdentifier`),
/// kept while the process lives — a window the system disconnects and
/// connects again gets the same session back — and closed when the user
/// closes the window.
@MainActor
public final class DocumentSessionRegistry {
    /// Holds `runtimeEngine` for a window about to be requested, and names
    /// the request.
    public func reserveWindow(on runtimeEngine: RuntimeEngine) -> UUID

    /// The session of the window `windowIdentifier`: the one it already has,
    /// or a new one on the engine reserved under `requestIdentifier`, or on
    /// `.local` when nothing is reserved under it — a window the system
    /// restored after a relaunch. Not yet opened.
    public func session(forWindow windowIdentifier: String, requestIdentifier: UUID?) -> DocumentSession

    /// Closes and forgets the sessions of windows the user closed.
    public func discardSessions(forWindows windowIdentifiers: some Sequence<String>)
}
```

```swift
// RuntimeViewerAppCore/Engine/RuntimeFileOpener.swift
/// Opens files from disk into engines, on every platform: what the Mac's
/// File › Open… and the iOS open button share.
@MainActor
public final class RuntimeFileOpener {
    /// Starts reading the file at `url` and returns the engine reading it: the
    /// one listed for it, as the user paired it, or a new one paired with the
    /// default dependency cache. What is at `url` is inspected off the main
    /// actor. A security-scoped `url` stays accessible until the engine is
    /// let go. Throws, opening nothing, when `url` is nothing file mode reads
    /// — and, where files are read in this process, when the file cannot be
    /// read.
    public func startReading(fileAt url: URL) async throws -> RuntimeEngine

    /// Lets `engine`'s file go once no document is on it: suspends an engine
    /// whose file a file service reads, and takes an engine that read its
    /// file in this process off the manager's list, ending its access to the
    /// file.
    public func letGoOfFile(readBy engine: RuntimeEngine) async
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeFileOpener.shared })
    public var runtimeFileOpener: RuntimeFileOpener
}
```

```swift
// RuntimeViewerEngineManagement/RuntimeEngineManager.swift
extension RuntimeEngineManager {
    /// Whether files are read in this process (iOS, visionOS) rather than in
    /// instances of a file service (macOS).
    public var readsFilesInThisProcess: Bool { get }
}

// RuntimeViewerSettings/Settings+File.swift
extension Settings.File {
    /// Platforms whose files read this device's own dyld shared cache:
    /// macOS and Mac Catalyst on a Mac, iOS on an iPhone or iPad, visionOS
    /// on a Vision Pro.
    public static let platformNamesPairedWithThisDevice: Set<String>
}
```

```swift
// RuntimeViewerAppCore/App/ApplicationLogs.swift
public enum ApplicationLogs {
    /// The entries this process logged under a RuntimeViewer subsystem since
    /// `date`, one line each: `[HH:mm:ss.SSS] [subsystem/category] message`.
    public static func formattedEntries(since date: Date) async throws -> String
}

// RuntimeViewerAppCore/Engine/RuntimeEngineManagerSettingsFollower.swift
/// Writes the settings the engine manager takes into it — Settings ›
/// Developer's shared cache switch — from the stored values on, and every
/// change after. Start it once the stored settings are read: loading replaces
/// the object an earlier start would have followed.
@MainActor
public final class RuntimeEngineManagerSettingsFollower {
    public func startFollowing()
}
```

- **iOS 的文件窗口**：`FileController` 读成功后，`UIApplication.shared.supportsMultipleScenes` 为真就
  `registry.reserveWindow(on:)`，把请求号放进类型为 `dev.JH.RuntimeViewer.fileWindow` 的 `NSUserActivity` 的 `userInfo`，
  调 `activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication, userActivity:))`（iOS 17 起）；为假就
  建 `DocumentSession` 与一套新的 `MainCoordinator(documentState:isFileWindow: true)`，`open()` 之后以
  `.fullScreen` 从当前窗口的根控制器呈现，`FileController` 持有它直到关闭。
- **关闭按钮**：`SidebarCoordinator` 在文件窗口的根页放 `xmark`（`leftBarButtonItem`），按下经 delegate 到
  `MainCoordinator`，再到持有者：叠着的收起并 `close()`；独立窗口调 `requestSceneSessionDestruction`，会话在
  `didDiscardSceneSessions` 里关。
- **「越狱版」的判断**：`NSHomeDirectory()` 不在 `/Containers/Data/Application/` 之下即视为没有容器、不受沙盒限制，
  菜单里才出现「Open Path…」；路径是 `UIAlertController` 的文本框，接受 `~`。不新增编译开关，与愿景第一条一致。
- **安全作用域**：`RuntimeFileOpener` 按引擎的来源记下已开始访问的 URL；`letGoOfFile(readBy:)` 拿掉引擎之后
  `stopAccessingSecurityScopedResource()`。读失败（`startReading` 抛错）时当场结束访问。Mac 的 URL 不带安全作用域，
  `startAccessingSecurityScopedResource()` 返回 `false`，什么也不记。
- **默认依赖缓存**：`platformNamesPairedWithThisDevice` 用 `#if os(macOS)` / `os(visionOS)` / `os(iOS)` 给值；设置不判断本机
  缓存能不能打开，由 `RuntimeFileOpener` 在进程内读文件、本机缓存打不开（`RuntimeFileError.dependencyCacheUnavailable`）时
  把文件改成单独读、再读一次。
- **后台工作在 iOS 上开始跑**：`open()` 之后，交叉引用的预建（默认开）、Always Index（默认关）、Find 语料按设置运行，
  与 Mac 相同；iOS 上没有 Report 页看它们，暂由日志观察。

## 替代方案考量

- **iOS 用 `UIDocument`**：愿景已否（没有文件的窗口要造占位 URL）。
- **这一步就合并 `MainViewModel` / `MainRoute`**：要先放开第四步那批文件，用户定了留到第四步。
- **打开文件的共用逻辑放进 `RuntimeEngineManager` 本身**，AppCore 依赖不动：用户选了让 AppCore 链接引擎管理；而且读文件头、
  选依赖缓存要读设置，引擎管理器不依赖设置。
- **iPhone 上把当前窗口换成文件**（照 Mac 的切换引擎）：切换来源要等第五步，换过去就回不到本机；用户选了叠在上面。
- **越狱版只用文档选择器**：vphone 上看不到系统路径与别的 App 的二进制，用户选了加「Open Path…」。
- **在进程里读的文件引擎改成可挂起**（拿掉解析结果、留在列表里、再打开时重读并换一个引擎对象）：列表里留着的引擎要等第五步
  的来源列表才看得见，而且要动管理器里引擎身份的假设；这一步直接拿掉，第五步需要时再议。
- **scene 断开就关会话**：系统会为省内存断开后台的 scene，再连回来时文件窗口就变成了本机；改为进程活着时保留、用户关掉才关。
- **重启后恢复文件窗口**：要把文件的书签存进 scene 的状态，且 Mac 也关掉了窗口恢复；用户认可一律从本机开始。

## 影响

### 用户可见变化

- iOS、越狱版 iOS 与 visionOS：侧栏根页齿轮旁多一个打开按钮；越狱版上按下是菜单（Choose File…、Open Path…）。
- 选中的文件、文件夹或 dyld 缓存在一个文件窗口里打开：iPad 与 visionOS 上是新窗口，iPhone 上叠在当前窗口上面；文件窗口
  左上角的关闭按钮关掉它，iPhone 上随即回到本机。读不了的文件不开窗口，弹一个说明原因的提示。
- 「文件」App 里对文件选「用其他 App 打开」能选 RuntimeViewer（iOS 与越狱版）。
- iPad 上能开多个 RuntimeViewer 窗口，新窗口看本机。
- 引擎的后台工作在 iOS 上开始按设置运行（交叉引用预建默认开）。
- Mac：无变化。

### 可发现性

打开按钮在齿轮旁，iOS App 放「打开」的惯例位置；「用其他 App 打开」由系统列出。默认都开，没有开关。

### 数据与配置兼容

不新增设置键，不改存盘格式。`Settings.File.platformNamesPairedWithThisMac` 是代码里的静态常量，改名不影响存盘。

### 平台与最低版本

最低版本不变（RuntimeViewerPackages：iOS 18、visionOS 2；`activateSceneSession(for:)` 要 iOS 17 / visionOS 1）。
iPhone 一个窗口、文件窗口叠在上面；iPad 与 visionOS 多窗口。「Open Path…」只在没有容器的越狱版上出现。

### 发布

不需要新的 entitlement；iOS 与越狱版的 `Info.plist` 多了文档类型与就地打开的声明。不影响公证与 Sparkle。

## 落地步骤

1. **AppCore 链接引擎管理，共用的文档会话**（已完成）—— 改动地图里步骤 1 的行
   - 行为：`documentSessionOpensOnlyOnce`
   - 行为：`documentSessionClosesOnlyOnceAndOnlyAfterOpening`
   - 行为：`documentSessionNumbersCountUpFromOne`
   - 行为：`macDocumentBehavesAsBefore`（macOS App 构建、MCP 的文档编号不变）
   - 行为：`appCoreBuildsWithEngineManagementOnIOSAndVisionOS`（三个 iOS 系 App 编过）
2. **iOS 的窗口模型**（已完成，设备上待用户看）—— 步骤 2 的行
   - 行为：`registryGivesAWindowOneSessionAndKeepsIt`
   - 行为：`registryHandsAReservedEngineToTheWindowThatAsksForIt`
   - 行为：`registryFallsBackToLocalForAnUnknownRequest`
   - 行为：`registryClosesTheSessionsOfDiscardedWindows`
   - 行为：`iOSWindowJoinsTheEngineBackgroundWork`（设备上看日志）
   - 行为：`iPadOpensASecondWindowOnThisDevice`（模拟器或设备上看，由用户看）
3. **打开文件的共用部分与放走**（已完成）—— 步骤 3 的行
   - 行为：`openerReadsTheListedFileAsTheUserPairedIt`
   - 行为：`openerPairsANewFileWithTheDefaultCache`
   - 行为：`openerThrowsAndListsNothingForAnUnreadableFile`
   - 行为：`parkingLetsGoOfAnInProcessFileEngineAfterTheGracePeriod`
   - 行为：`parkingStillSuspendsAFileServiceEngine`
   - 行为：`macFilesStillPairWithThisMacsCache`
   - 行为：`macFileModeBehavesAsBefore`（macOS App 构建、文件模式的已有测试照过）
4. **iOS 的打开入口**（已完成，设备上待用户看）—— 步骤 4 的行
   - 行为：`openButtonChoosesAFileAndOpensItInAFileWindow`（由用户在设备上看）
   - 行为：`openPathOpensAnAbsolutePathOnTheJailbrokenApp`（由用户在 vphone 上看）
   - 行为：`fileWindowStacksOverTheWindowOnIPhoneAndClosesBackToThisDevice`（由用户在 vphone 上看）
   - 行为：`unreadableFileShowsWhyAndOpensNoWindow`（由用户在设备上看）
   - 行为：`openInFromFilesOpensTheFile`（由用户在设备上看）
5. **导出日志与跟随设置进 AppCore**（已完成）—— 步骤 5 的行
   - 行为：`applicationLogsListsThisProcessesEntriesSinceADate`
   - 行为：`followerWritesTheSharedCacheSwitchIntoTheManager`
   - 行为：`macExportLogsBehavesAsBefore`
6. **边界测试扩到 iOS target**（已完成）—— 步骤 6 的行
   - 行为：`iOSAppTargetHoldsNoViewModelButTheOneWaitingForStep4`
   - 行为：`macAppTargetStillHoldsNoViewModel`
7. **文档**（已完成）—— 步骤 7 的行

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计不需要：规则写进 `RuntimeViewerUsingUIKit/AGENTS.md`。
- **有没有引入新术语** —— 「文档会话」（`DocumentSession`）可能要登记进 `Documentations/Glossary.md`，收尾时判断。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-21 | Created as Draft | 愿景第三步，按完整档问了两轮再写 |
| 2026-11-21 | 用户选定：`MainViewModel` / `MainRoute` 留到第四步合并 | 合并要先放开 AppCore 里依赖引擎管理、注入的那批文件，正是第四步的内容；这一步只做窗口模型、文档会话与平台无关逻辑下沉，每步改动小 |
| 2026-11-21 | 用户选定：合并后 iOS 照 Mac 走 `SelectionRoute` | 选中经 `DocumentState` 的 `SelectionRoute`，Inspector 自己跟随，设置经 `appRouter`；两端一套模型。第四步执行 |
| 2026-11-21 | 用户选定：打开文件做到能在 vphone 上打开 | 文档选择器与「用其他 App 打开」，在设备上就能看到效果 |
| 2026-11-21 | 用户选定：导出日志只把逻辑移进 AppCore | iOS 暂不加入口；在 vphone 上看日志可经 vphoned 的日志接口 |
| 2026-11-21 | 用户选定：AppCore 只放开对引擎管理的这一条依赖 | 打开文件的共用逻辑要用管理器；`MainViewModel` 那批文件照旧留到第四步 |
| 2026-11-21 | 用户选定：iPhone 上文件窗口叠在当前窗口上，关掉回本机 | 不必等第五步的切换来源就能回去 |
| 2026-11-21 | 用户选定：越狱版加「Open Path…」 | 文档选择器看不到系统路径与别的 App 的二进制 |
| 2026-11-21 | 用户认可其余假设 | 共用的文档会话（MCP 编号只有 Mac 用）；iOS 与越狱版打开多窗口、iPad 新窗口看本机、重启后一律从本机开始；打开按钮在齿轮旁；文件在读取期间一直保持访问权限；「用其他 App 打开」收 Mach-O、bundle、文件夹与 dyld 缓存；AppCore 不弹窗，要提示时经 AppCore 声明、AppUI 实现的客户端；边界测试先留 iOS `MainViewModel` 一条例外 |
| 2026-11-21 | 自定：派生数据与启动顺序不另立共用类型 | 派生数据平台无关的部分早已在 Core 的 `RuntimeDerivedDataMaintenance`，Mac 控制器剩下的都是界面，iOS 又不开；启动顺序能共用的只有两行且调用不同，留在两份 `AGENTS.md`。偏离愿景第三步的清单，写在非目标里 |
| 2026-11-21 | 自定：iOS 上关掉的文件 30 秒后从管理器拿掉 | 在进程里读的引擎挂不起来，不拿掉就一直占着解析结果与文件描述符；`RuntimeFileEngineParking` 放开平台限定，经 `RuntimeFileOpener.letGoOfFile(readBy:)` 分两种做法 |
| 2026-11-21 | 自定：会话在进程活着时保留，用户关掉窗口才关 | 系统会断开后台的 scene，断开就关会让文件窗口连回来时变成本机 |
| 2026-11-21 | 自定：依赖缓存按本机配对，打不开就单独读 | 原来只认 macOS 与 Mac Catalyst，iOS 的二进制配不到设备自己的缓存；沙盒里能不能打开本机缓存没验证，打不开就退回单独读而不是整个打不开 |
| 2026-11-21 | 自定：这一步 AppCore 里新代码都不弹窗，暂不需要新的跨层客户端 | 打开文件、导出日志的共用部分都只返回结果或抛错，提示留在各端的控制器；用户认可的「经客户端提示」留给真需要 AppCore 发起提示的地方 |
| 2026-11-21 | 用户批准，开始实现 | 看过简报后批准；从 `next` 切 `feature/window-model-on-ios` |
| 2026-11-21 | 实现中的调整（步骤 1–3） | 一、`RuntimeViewerEngineManagement` 在清单里的四处平台条件一起去掉：`CrossPlatformSourceGuardTests` 把清单里任何一行带 `appkitPlatforms` 条件的模块都算作 macOS 专属，只去掉 AppCore 那一处，它仍会拦住 AppCore 里用到引擎管理的跨平台文件；模块本身从 0099 起各平台都编。二、`DocumentSession.close()` 不要求先 `open()`：`DocumentState.documentWillClose()` 本来就不要求，Mac 的文档没显示过就关时也要收尾，照旧。三、`RuntimeFileOpener` 放在 AppCore 的 `Engine/`（没有 `File/` 目录），`ApplicationLogs` 放 `App/`，跟随设置的类型放 `Engine/`。四、本机缓存打不开时退回单独读，做在 `RuntimeFileOpener` 里（捕获 `dependencyCacheUnavailable` 后去掉配对再读一次），设置只按平台给默认配对：判断缓存能否打开要用到 Core 里的 `FullDyldCache`，设置模块不该依赖它。五、`canPairWithThisMacsCache(_:)` 跟着改名为 `canPairWithThisDevicesCache(_:)`。六、行为 `openerEndsSecurityScopedAccessWhenReadingFails` 换成 `openerThrowsAndListsNothingForAnUnreadableFile`：测试里的文件 URL 不带安全作用域，看不到访问计数；安全作用域在设备上验。 |
| 2026-11-21 | 实现中的调整（步骤 4–6） | 一、iOS 上的 `RuntimeEngineManagerSettingsFollower` 由 `AppDelegate` 在引擎管理器起来之后启动，不在设置生命周期控制器里：那个控制器在启动顺序的第一步，那时读管理器就会把引擎拉起来，早于注入与交叉引用两个命令扩展的注册（`RuntimeViewerUsingUIKit/AGENTS.md`「Launch order」）。二、一个窗口是不是文件窗口，看它的引擎是不是引擎管理器列出的文件引擎，而不是看连接时有没有请求号：系统断开再连回来的文件窗口没有请求号，照样要有关闭按钮。三、叠在 iPhone 窗口上的文件窗口由 `FileController` 同时持有它的 `MainCoordinator` 与会话：协调器没有别人持有，不留就会被释放。四、「越狱版」判断写成 `FileController.opensAbsolutePaths`，打开按钮在越狱版上是 Choose File… 与 Open Path… 的菜单，别处直接是文档选择器。五、`ApplicationLogs.formattedEntries(since:)` 是非隔离的 `async` 函数，读日志库这一慢操作自然不在调用方的 actor 上。六、边界测试按 App target 参数化，例外清单里的 view model 一旦搬走，测试就报「把例外删掉」。 |
| 2026-11-21 | 实现完成，待用户看过后收尾 | 验证都在 Ultra 上：AppCore 的 32 个测试（新加的文档会话、窗口注册表、打开文件、parking 的进程内一例、导出日志、跟随设置，加上跨平台守卫、AppCore 边界与两个 App target 的边界检查）与设置的 7 个测试全过；macOS App 用 Tuist workspace（Debug）编过；`RuntimeViewer iOS Jailbroken` 用 Debug workspace 编过并打成越狱包，`RuntimeViewer visionOS`（visionOS 模拟器）编过，`activateSceneSession(for:)` 在 visionOS 上可用。没做的：普通 iOS（模拟器）没单独编（与越狱版同一份源码）；设备上的行为（打开按钮、Open Path…、iPhone 上叠放与关闭、读不了的提示、「用其他 App 打开」、安全作用域的访问）由用户在 vphone 上看；iPad 多窗口手头没有设备，没验。文档判断：规则写进 `RuntimeViewerUsingUIKit/AGENTS.md`（启动顺序第 5、6 步，新增「Windows and their documents」「Opening files」两节），`RuntimeViewerUsingAppKit/AGENTS.md` 改了三个控制器的说明，根 `AGENTS.md` 改了文档的说法与规则表一行；不另写使用指南或实现说明；「文档会话」就是类型名 `DocumentSession`，不另立术语。 |
| 2026-11-21 | 用户在设备上看时发现的两件事 | 一、iPad 上内容区的导航栏后面与底部手势条旁露出纯黑：0101 只给文字视图上了主题底色，文字视图又只占安全区，安全区外露出的是分栏控制器的 `systemBackground`。用户同意在这条分支上一起修：`ContentTextViewController` 的视图底色也跟主题走。不是这一步引入的，iPhone 上同样有，只是不显眼。二、iOS 18.7.2 虚拟机上越狱版起不来：系统拒绝执行（`EBADEXEC`，内核日志 `AMFI: … Developer mode is disabled, task_for_pid-allow is disallowed`）。越狱版带 `task_for_pid-allow`，开发者模式关着时 AMFI 不让它执行；两台 iOS 27 虚拟机开着开发者模式，所以没遇到。与代码无关，App 一行都没跑到。那台虚拟机在设置里打开开发者模式不生效，要带补丁重新装，所以这一步不在 iOS 18 上验；前提写进了 `Documentations/Guides/JailbrokenDeviceInjection.md`「前提」。修完重新打包，装进两台 iOS 27 虚拟机。 |
| 2026-11-21 | 用户在设备上看时发现内容页导航栏没有标题，同意在这条分支上修 | 2026-07-23 那次把 iOS 的标题改成跟 `DocumentState.selectedRuntimeObject` 走，而 iOS 的侧栏经自己的路由打开对象、不走 `SelectionRoute`，那个值一直是空的。改回每页自己的对象：`ContentTextViewModel.Output.selectedRuntimeObjectName` 改名 `runtimeObjectName`，取视图模型自己的 `runtimeObject`；只有 iOS 用它。不等第四步让 iOS 走 `SelectionRoute` 再修：导航栈里每页要有自己的标题，返回按钮显示下面那页的，跟随全局选中会让下面的页也变成当前这页的名字。原来锁定旧行为的测试换成 `runtimeObjectNameIsThePanesOwn`，修之前两处断言都红。 |

# Draft - Load Frameworks 改在独立实例里加载，并诊断加载失败

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-19
- **最后更新**: 2026-11-19
- **所属愿景**: 无
- **关联提案**: [0037-local-runtime-xpc-service](0037-local-runtime-xpc-service.md)（My Mac 的引擎搬进 XPC service；service 崩溃丢掉已加载的镜像、不自动重放）、[0069-file-mode](0069-file-mode.md)（每个文件一个 service 实例，本提案照它接线）、[0079-shared-service-plugin](0079-shared-service-plugin.md)（service 是加载共享插件的外壳）、[0081-shared-cache-images-across-engines](0081-shared-cache-images-across-engines.md)（系统镜像的数据向 My Mac 借）、[draft-engine-management-on-ios](draft-engine-management-on-ios.md)（引擎管理的平台接缝，已在 `next` 上；本提案的管理器改动照它的写法加接缝）
- **实现分支 / PR**: `feature/isolated-framework-loading`（worktree `.worktrees/RuntimeViewer-IsolatedFrameworkLoading`），从 `next` 切出
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

Load Frameworks 不再把框架装进 My Mac 的 service。在 My Mac 的窗口里选了框架，App 新起一个 XPC service 实例（新的内嵌 service `RuntimeViewerFrameworkService`，每次一个，带 `disable-library-validation`），开一个挂在这个实例上的新窗口，把这次选的框架都加载进去；之后在这个窗口里再加载，也进同一个实例；没有窗口留在这个实例上时（关窗，或窗口换到别的来源），实例退出，框架随之卸载。加载失败时窗口照常打开，内容区显示诊断：在加载失败的那个进程里模拟 dyld 的查找——依赖链、rpath 栈及其展开、每条候选路径的结果——并附上 dyld 原文；缺的依赖就在宿主 App 的 Frameworks 目录里时，提议先按绝对路径加载它们再重试，找不到时让用户指定宿主 App 或搜索路径；重试成功，窗口原地变成普通窗口。窗口挂在 Mac Catalyst、注入进程、远端 Mac 等引擎上时，框架仍加载进那个进程，失败时同一诊断以 sheet 显示，不带重试与修复。诊断随失败的那次加载一起回来（加载请求多一个可选字段，旧版对端照旧只回 dyld 原文，App 据原文给出简化诊断），不给旧版 payload 发它不认识的命令。窗口的侧栏只列这次加载的框架和它们不在系统 shared cache 里的依赖；窗口不进 Open Recent，重启后不恢复。

## 动机

今天的 Load Frameworks 把选中的框架 `dlopen` 进窗口引擎所在的进程，My Mac 的窗口就是 local service（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Main/MainViewModel.swift:189-209` → `RuntimeEngine.loadImageInServingProcess(at:)`）。这有三个问题：

1. **卸不掉，还会牵连 My Mac。** `dlopen` 进去的框架一直留到 service 退出：My Mac 的镜像列表、Find、后台索引从此都带着它。它的构造函数在 My Mac 的进程里运行，崩了，My Mac 已加载、已索引的全部镜像一起丢掉（0037：service 崩溃丢的是已加载的镜像）。用户只是想看一眼某个第三方框架，代价落在 My Mac 上。
2. **失败时只有一段原文。** 失败经 `MainViewModel.errorRelay` 弹成 `NSAlert`（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift:281-286`），内容是 `dlerror()` 的原文。558b6abf 之前跨 XPC 连原文都丢了，只剩「An unknown error occured」。原文列出 dyld 试过的路径，却不说这些路径从哪来。第三方 App 里的框架常带 `@executable_path/../Frameworks` 这样的 rpath，指望由宿主 App 的可执行文件来展开；在 service 里，`@executable_path` 展开成 service 自己，依赖必然找不到，而用户从原文里看不出这一点，也不知道该怎么办。
3. **没有补救手段。** 依赖明明就在旁边（宿主 App 的 `Contents/Frameworks`），也没有办法让它先就位再重试。

一个具体的例子（诊断页原型用的就是它）：`/Applications/Example.app/Contents/Frameworks/Foo.framework` 链接 `@rpath/Bar.framework/Versions/A/Bar`，Foo 的 rpath 是 `@executable_path/../Frameworks` 与 `@loader_path/Frameworks`。在 service 里加载 Foo，dyld 依次试 service 的 `Contents/Frameworks`、插件的 `Contents/Frameworks`、Foo 自己的 `Frameworks`……全都不存在；而 Bar 就在 `Example.app/Contents/Frameworks` 里，与 Foo 并排。

## 前期调研

### 现状代码怎么走的

- **入口只有工具栏按钮**：`loadFrameworksItem`（`Main/MainToolbarController.swift:237-239`，标签 "Load Frameworks"，图标 `.latch2Case`），主菜单里没有。点击经 `MainWindowController.swift:104` 进 `MainViewModel.Input.loadFrameworksClick`，原样转成 `Output.requestFrameworkSelection`，`MainWindowController.presentOpenPanel()`（`:328-337`）开 open panel：只收 `.framework`、可多选，选中的 URL 经 `frameworksSelectedRelay` 回到 `Input.frameworksSelected`。
- **逐个加载**（`MainViewModel.swift:189-209`）：在 App 进程里用 `Bundle(url:)?.executableURL` 取可执行文件路径，`documentState.recordingManualLoad(ofImageAt:_:)` 包着 `runtimeEngine.loadImageInServingProcess(at:)`；失败 `errorRelay.accept(error)`。用 `loadImageInServingProcess` 而不是 `loadImage` 是 0081 定的：框架进窗口引擎所在的进程，不交给系统镜像的 owner。
- **按钮何时可用**：只有 `MainViewModel.swift:373-376` 一条——`.file` 引擎不可用，其余都可用。
- **引擎一侧**：`loadImageInServingProcess(at:)`（`RuntimeViewerCore/Sources/RuntimeViewerCore/SharedCache/RuntimeEngine+SharedCache.swift:248`）经 `dispatchToServingProcess` 发 `LoadImageCommand`（`Engine/RuntimeEngine+Commands.swift:31-41`，线上名 `loadImage`，回复 `RuntimeEngineEmpty`）。最终那个进程的 `_loadImage`（`Engine/RuntimeEngine.swift:1297`）先 `imageCatalog.prepareImage(at:)`——进程目录的实现就是 `DyldUtilities.loadImage(at:)`（`Images/DyldUtilities.swift:217-233`，`dlopen(path, RTLD_LAZY)`，失败抛 `DyldOpenError(message: dlerror())`）——再建 ObjC 与 Swift section，然后 `reloadLocalData(isReloadImageNodes: false)`。
- **错误怎么过线**：XPC 上只剩 `localizedDescription`，socket 上只剩 `String(describing:)`。558b6abf 让 `DyldOpenError` 遵循 `LocalizedError` 与 `CustomStringConvertible`，原文才过得来（`DyldLoadFailureMessageTests` 覆盖进程内、XPC、socket 三种）。**结构化的数据挂在错误上过不了线**，所以诊断只能放在回复里。
- **加载之后侧栏怎么更新**：`reloadLocalData(isReloadImageNodes: false)` 只刷新 `imageList`，不重建镜像节点；节点只在启动时建（`RuntimeEngine.swift:744`）。所以 My Mac 加载一个不在 shared cache 里的框架后，侧栏的 Others 里大概率看不到它，要等引擎重连（读代码所得，**未实测**；本提案不修 My Mac 这一处，见非目标）。新实例的镜像目录会在每次加载后自己重建节点。
- **没有任何持久化**：`Document` 不读不写（`App/Document.swift:56-62`），`applicationSupportsSecureRestorableState` 返回 false，Open Recent 只由 `FileController.swift:90` 显式登记，Manual Loading 的历史只在内存里。

### 照搬文件模式的多实例 service

- 文件模式（0069）已经有「每个文件一个 service 实例」的整套接线：外壳 `RuntimeViewerUsingAppKit/RuntimeViewerFileService/`（`main.swift` 只调 `ServicePluginLoader.loadPlugin().runFileService()`；`Info.plist` 只有 `ServiceType = Application` 与 `_MultipleInstances = true`）、`Configurations/RuntimeViewerFileService/` 四份 xcconfig、`Configurations/CodeSigning.xcconfig:47-54` 三个 bundle identifier 变量、App 的 `Info.plist:59-60` 的 `RuntimeViewerFileServiceBundleIdentifier`、`project.xcproj` 的 target 与 Embed XPC Services、Tuist `Project.swift:199-203, 274, 376-387`。
- 凭证与握手：`RuntimeFileService.credential(for:)` 返回 `.xpcService(.dedicatedInstance(bundleIdentifier:launchPayload:))`（`RuntimeViewerCore/Sources/RuntimeViewerCore/File/RuntimeFileService.swift:16-48`）；服务端 `RuntimeFileServiceHost` 用 `setLaunchHandler` 在第一个非空 `hello` 时建引擎，`setClientDepartureHandler { exit(EXIT_SUCCESS) }` 在客户端离开时退出（`ServicePluginEntry.swift:132-172`）。
- **重连语义**：`.dedicatedInstance` 的连接在中断后以**新连接、新实例、同一份 payload** 重连（`RuntimeXPCServiceClientConnection.swift:119-122, 311-345`）。所以框架实例的 payload 不能列框架：列了，崩溃后的新实例会再加载一遍同一个会崩的框架。payload 只标识实例，崩溃后得到一个空实例，与 0037「崩溃丢掉已加载镜像、不自动重放」一致。
- **local service 已经带 `disable-library-validation`**（`RuntimeViewerLocalService.entitlements:12-13`，`Configurations/RuntimeViewerLocalService/Shared.xcconfig:19` 的 `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES`），今天在 My Mac 里能加载第三方框架靠的就是它；file service 有意不带（只读不运行）。新 service 照 local service 带上。
- 文件引擎关窗后停 30 秒再挂起、仍留在来源列表里（`RuntimeViewerAppCore/Engine/RuntimeFileEngineParking.swift`）。框架实例要的是没有窗口就立即结束、从列表里拿掉，照它的写法另起一个。
- 新来源要改的穷举 `switch`：`RuntimeSource.swift` 的 `description`、`remoteRole`、`==`、`hash`、`isMirrorableToPeers`、`identifier`；`RuntimeCommunicator.swift:68`；`RuntimeEngine.swift:304-311, 349`；`RuntimeBookmarkScope.swift:104, 172, 228, 378`；`RuntimeEngine+Injection.swift:72-86`；`SidebarRootViewModel.swift:246-253`；`RuntimeEngine+ImageIndexing.swift:43-50`；`RuntimeEngineIconProvider.swift:159-170`；CLI 的 `SourceCatalog.swift:90`。
- **系统镜像的借用**：0081 只给 system 与 attached 两类引擎分配 owner（`RuntimeEngineManager.swift:1953-1980` 的 `updateSharedCacheOwners()` 与 `isBorrowingEngine(_:)`），文件引擎有意不借。框架实例是本机原生进程、映射的就是本机的 shared cache，借得了；它会是第一个「由 App 自己起的 service 实例」借用方。

### dyld 的事实（dyld-1323，`/Volumes/AppleOSS/distribution-macOS/dyld`）

- 控制台与 `dlerror()` 里的 `Library not loaded / Referenced from / Reason: tried:` 是同一段文字：`JustInTimeLoader.cpp` 拼出诊断，`DyldAPIs.cpp` 加上 `dlopen(<path>, 0x…):` 前缀。
- `DYLD_PRINT_SEARCHING` 一类开关只在进程启动时读、要 AMFI 放行，launchd 管的进程会写进 syslog，**没有 API 取得到**。
- `dlopen_preflight` 只检查顶层镜像的架构切片，不检查依赖，**不能**拿来预检 rpath。
- `dlopen` 时的 rpath 栈是：主程序（service 外壳）→ 调用 `dlopen` 的镜像（service 插件，RuntimeViewerCore 静态链接在里面）→ 依赖链上的每个加载者；`@executable_path` 展开到 service 自己。
- 解析 `@rpath/…` 时，dyld 先匹配已加载镜像的 install name（`JustInTimeLoader::matchesPath` 的 `altInstallName`），所以「先按绝对路径加载依赖，再加载要它的框架」**读源码可行，未实测**。落地步骤 1 先用测试实测，不成立就停下回来重议（退路见替代方案）。

### 现成的 Mach-O 能力

- **`DylibPathResolver`**（`RuntimeViewerCore/Sources/RuntimeViewerCore/Images/DylibPathResolver.swift`）已经按 dyld 的规则展开 `@rpath/`（逐个 rpath，rpath 本身的 `@executable_path/`、`@loader_path/` 也展开）、`@executable_path/`、`@loader_path/`，把 shared cache 里没有文件的镜像算作存在；尝试过的候选路径只写进日志。诊断要的正是这份「试了什么、结果如何」，把它从日志改成返回值即可。
- **`RuntimeImageCatalog.dependencyEntries(ofImageAt:ancestorRpaths:mainExecutablePath:)`**（`Images/RuntimeImageCatalog.swift`）按 dyld 的顺序累积祖先的 rpath，跳过弱链接与延迟初始化的依赖——诊断的依赖遍历照它走。
- MachOKit 的 `MachOFile` 给出 `rpaths` 与 `dependencies`（`DependedDylib` 带 `.type` 与 `.useFlags`）；诊断从磁盘读失败的镜像（它没加载成，进程目录拿不到）。
- **MachOKitExtensions 2.0.0 的 MachODependencies 不展开 `@` 路径**（`DependencySearchPath.swift:9-11`），只按裸名匹配，模拟不了 dyld 的查找，诊断不用它。

### 与旧版对端的兼容

- 引擎之间不交换协议版本（`Documentations/CommunicationAndEngineArchitecture.md` §4.4）。**经 Mach service 连着的旧版注入 payload 收到不认识的命令会断开连接**（`Documentations/KnownIssues/2026-10-07-pr121-review-findings.md` PR121.73；`RuntimeViewerCore/Sources/AGENTS.md` 写明「Never make a payload answer a new command before it can work」）。
- §4.4 规定改已有命令的形状只能「发送方保守、接收方容错」：请求加可选字段，旧对端解码时跳过；回复的新形状只发给声明读得懂的请求方。第三例（Generated Interface 的 `interfaceLanguage`）就是为了不加新命令才这样做。本提案的加载诊断照这条走：`LoadImageCommand` 加可选字段，回复从 `RuntimeEngineEmpty` 换成全可选的 `RuntimeImageLoadResponse`，两者在线上都是空对象。

### 原型

- 诊断页做过一个用完即弃的静态 HTML 原型，回答「诊断页放什么、怎么排」：标题与一句话结论、架构与系统版本、修复提议的横幅（三个按钮）、依赖链、按 rpath 列出的查找表（含「为什么」的一句解释）、dyld 自己的尝试列表、可折叠的 dyld 原文、拷贝诊断与 Show in Finder；另有重试成功后的状态。**用户看过，认可。**原型放在 `/tmp`，不进仓库；网页版里的界面草图照它重画，保留结论。

## 提议方案

### 加载去哪，按窗口的引擎分

| 窗口所在的引擎 | 框架加载到哪里 | 失败时怎么显示 |
|---|---|---|
| My Mac（`.local`） | **新起一个框架实例，开一个新窗口挂在它上面**；原窗口不动 | 新窗口的内容区显示诊断，带重试与修复 |
| 框架实例（`.frameworkInstance`） | 同一个实例，同一个窗口 | 窗口还什么都没打开时在内容区；已经打开了内容时用 sheet。都带重试与修复 |
| Mac Catalyst、注入进程（XPC 或 socket）、远端与 Bonjour、直连 TCP | 那个进程，与今天一样 | sheet 显示诊断，不带重试与修复 |
| 文件（`.file`） | 不可用，与今天一样 | — |

My Mac 上不再保留「直接加载进 My Mac」的入口。工具栏按钮在 My Mac 的窗口里的 tooltip 改为「在新的独立实例里加载框架」。侧栏镜像行的 Load、CLI 与 MCP 的加载不受影响（它们加载的是引擎自己列出的镜像，或另有入口，见非目标）。

### 框架实例

- **一个新的内嵌 XPC service**：`RuntimeViewerFrameworkService.xpc`，放在 `Contents/XPCServices/`，`Info.plist` 声明 `_MultipleInstances`，带 hardened runtime 与 `com.apple.security.cs.disable-library-validation`。它是 0079 式的外壳：`main.swift` 只调 `ServicePluginLoader.loadPlugin().runFrameworkService()`，活在 `ServicePluginEntry.runFrameworkService()` 里。
- **一次 Load Frameworks 一个实例**：App 以 `.xpcService(.dedicatedInstance(…))` 连接，launch payload 只有实例的标识、名字和第一个框架的 URL，**不列要加载的框架**。实例收到 `hello` 时建引擎，然后 App 用普通的加载命令逐个加载。这样崩溃后的重连得到一个空实例，不会重放会崩的那次加载。
- **实例里的引擎**：镜像来自本进程（框架真的被 `dlopen`、构造函数真的运行），目录换成 `RuntimeFrameworkInstanceImageCatalog`——只列这个实例里经引擎加载的镜像（成功或失败的都列）和随之被 dyld 带进来、又不在 shared cache 里的依赖，RuntimeViewer 自己的镜像（实例启动时已经加载的那些）不列；每次加载之后重建侧栏节点。
- **系统镜像向 My Mac 借**：实例的引擎是 0081 的借用方，owner 是 My Mac。内容区跳到 `NSObject` 这类系统类型时，数据来自 My Mac，不在实例里重新解析。
- **不开派生数据**：`runFrameworkService()` 不调 `RuntimeDerivedData.enable…`。实例的系统镜像是借来的，自己的框架不是 shared cache 镜像，派生数据本来也不存它们。
- **照 install 规则装两个命令扩展**：`RuntimeInjection.install()` 与 `RuntimeCrossReferences.install()`。框架被真的映射进了进程，交叉引用照常可用。
- **生命周期**：
  - 窗口打开时文档加入这个引擎的后台工作（`.occupied`）。没有文档留在引擎上时（`.vacated`：关窗，或窗口换到别的来源），`RuntimeFrameworkInstanceRetirement` 立即让管理器结束这个引擎：从列表里拿掉、停掉连接，实例的客户端离开处理器 `exit(EXIT_SUCCESS)`，框架随进程卸载。没有宽限期——这个实例里的状态（加载过的框架、它们的构造函数做过的事）关掉就该没了。
  - 实例崩溃（加载时，或之后）：连接自己以新实例重连，新实例是空的。窗口进入「实例已停止」页，说明停在哪次加载上，给一个「Load Again」按钮把这次请求的框架重新加载一遍；**不自动重试**。
- **来源列表**：实例活着时，所有窗口的来源选择器在「Isolated Frameworks」一节里列出它（与文件引擎的「Files」一节并列），别的窗口可以换上来；它不分享给别的 Mac（`isMirrorableToPeers` 为假），CLI 的来源目录不列它。
- **不进 Open Recent，重启后不恢复**：重新加载会再跑一遍构造函数，不该悄悄发生。

### 框架实例的窗口

- **标题**：来源名是「Foo.framework (Isolated)」，一次选了多个时是「Foo.framework + 2 (Isolated)」。工具栏标题在没选中对象时显示第一个框架的名字，副标题按状态显示「Loading…」「Couldn't Load」「Isolated」。图标是框架自己的图标（与文件引擎一样取 `NSWorkspace` 的文件图标）。
- **侧栏**：两个根节点。「Frameworks」——经引擎加载的镜像，按加载顺序，加载失败的也在（显示为未加载的行，选中后是侧栏现有的 Load 按钮与错误文字）；修复时先加载的依赖也算在这里。「Dependencies」——dyld 随之带进来、不在 shared cache 里的镜像。没有 shared cache 的根节点。
- **内容区**：
  - 加载中，空的编辑栏显示「Loading Foo.framework…」页（一次多个时附「1 of 3」）。
  - 失败，空的编辑栏显示诊断页（下一节）。
  - 全部成功，页面消失，焦点栏打开第一个框架的镜像页（镜像页会索引它），与原型「重试之后」的状态一致。
  - 窗口已经打开了内容（之前加载过、用户点开过对象）时，之后的失败改用 sheet，内容同一个诊断页，带关闭按钮。

### 诊断

诊断在**加载失败的那个进程里**算出来，随失败的那次加载一起回到 App。它回答四件事：

1. **缺了什么、谁要它**：从 dyld 原文解析出失败的种类——找不到镜像（`Library not loaded: <install name>` / `Referenced from: <image>`）、找不到符号（`Symbol not found: <symbol>` / `Expected in: <image>`）、镜像不兼容（架构或平台，`mach-o file, but is an incompatible architecture …`）、其他（只显示原文）。
2. **依赖链**：从要加载的框架沿 `LC_LOAD_DYLIB` 走到出问题的那条边（跳过弱链接与延迟初始化的依赖，与 dyld 一致），显示成 `Foo → Bar ✗`。依赖链上的镜像从磁盘读；已经加载在进程里的、shared cache 里的算作存在。
3. **dyld 去哪里找了**：缺的是 `@rpath/…` 时，按 dyld 的 rpath 栈逐行列出——这条 rpath 属于谁（主程序、调用 `dlopen` 的镜像、依赖链上的加载者）、rpath 原文、展开后的候选路径、结果（不存在 / 找到 / 不在 shared cache）——再加一句「为什么」：例如 Foo 的第一条 rpath `@executable_path/../Frameworks` 是写给宿主 App 的，在这里 `@executable_path` 是这个实例自己。另列 dyld 自己报的尝试列表（从原文解析，带它的理由）。
4. **能怎么修**（只在框架实例里提供，见下一节）。

诊断页还有：架构与系统版本、「Diagnosed in the instance that tried the load」这样的出处说明、可折叠的 dyld 原文、「Copy Diagnosis」（纯文本，含以上全部）与「Show Foo in Finder」。

### 修复

- **自动提议**：诊断算出缺的依赖时，在几个地方找它：要加载的框架所在的 App（框架路径里最近的那个 `.app`，即 `Example.app/Contents/Frameworks/Foo.framework` 的 `Example.app`）、用户指定过的宿主 App、用户加过的搜索路径。找的方式是把那个 App 的可执行文件当成主程序、把搜索路径当成额外的 rpath，重新模拟一遍。依赖链上原本找不到的镜像全都找得到时，诊断带上一份修复方案：要先加载的镜像（依赖在前），以及它来自哪个宿主 App。横幅显示「Bar.framework is next to Foo in /Applications/Example.app/Contents/Frameworks. Foo expects Example.app to load it…」，主按钮「Load Example.app's Frameworks and Retry」。
- **执行修复**：按方案顺序，用普通的加载命令按绝对路径逐个加载这些依赖，再重试原来的框架。dyld 解析 `@rpath/Bar.framework/…` 时会先匹配已加载镜像的 install name，所以 Foo 这时找得到 Bar。
- **找不到时**：「Choose Host App…」选一个 App、「Add Search Path…」选一个目录。App 把它们交给实例重新诊断（实例才是做模拟的那个进程）；新的诊断有修复方案就立即执行，没有就换上新的诊断（说明在那里也没找到）。
- **记到窗口关掉为止**：用过的宿主 App 和搜索路径留在这个窗口的加载器里，之后在这个窗口里再失败，先带着它们诊断；关窗即忘，不写进设置。
- **只在框架实例里提供**：别的引擎的进程不是我们起的，往里补加载依赖不是用户要的事；这些窗口的 sheet 只有诊断、拷贝与 Show in Finder。

### 旧版对端

诊断由加载请求里的一个可选字段请求。旧版的进程（升级前注入的 payload、旧版 iPhone、经旧版 Mac 中转）解码时跳过它，失败照旧只回 dyld 原文。App 收到没有诊断的失败时，从原文自己解析出能解析的部分（失败种类、缺的 install name、谁要它、dyld 的尝试列表），诊断页标明「这个进程运行的是旧版 RuntimeViewer，只能显示 dyld 自己的信息」。**不给任何可能是旧版的对端发新命令。**重新诊断的那条新命令只发给框架实例——它总是与 App 同一次构建内嵌的 service。

### 设计中自定的假设

以下几条用户没有逐条定，是写提案时按已定的方向补齐的，可以推翻：

- 窗口挂在 Mac Catalyst、注入进程、远端 Mac 等引擎上时，仍加载进那个进程，失败用 sheet，不带重试（这一条在澄清提问时列给过用户，没有反对）。
- 加载时崩溃不自动重试，窗口给「Load Again」（同上）。
- 新建专用 service，不复用 My Mac 的；系统镜像照 0081 向 My Mac 借（同上）。
- CLI 与 MCP 不加命令（同上）。
- 重试用过的宿主 App 和搜索路径只在窗口活着时记住，不保存（同上）。
- 窗口开着时，其他窗口的来源选择器也列出这个实例（同上）。
- 框架实例的窗口已经打开了内容之后的失败用 sheet，而不是挤进某个编辑栏；诊断不做成标签历史里的一步。
- 侧栏分「Frameworks」「Dependencies」两个根节点；修复时先加载的依赖算在「Frameworks」里（原型重试之后的侧栏也是把 Bar 和 Foo 列在一起）。加载失败的框架显示为未加载的行，不加原型里的「failed」角标。
- 框架实例窗口里的书签按第一个框架的路径归档：下次再在独立实例里加载同一个框架，书签和侧栏的展开状态回来。
- open panel 照旧只收 `.framework`，不收 dylib 与裸 Mach-O。
- 诊断随加载失败的回复带回（可选字段），不另发命令；重新诊断的命令只发给框架实例。
- 框架实例的引擎在 iOS 上不可用（`RuntimeEngineManager` 的 iOS 移植里给 `.unavailable`）。

### 非目标

- CLI 与 MCP 不加命令；`runtime-viewer-cli load` 与 MCP 的 `loadImage` 照旧加载进它们的引擎（包括 My Mac）。
- 侧栏的 Load 按钮、镜像页、路径栏这几处加载失败仍只显示文字；接上诊断页是后续项（它们走的是 `loadImage`，不是 `loadImageInServingProcess`）。
- 不加载 dylib 或裸 Mach-O；不为 x86_64 框架起 Rosetta 实例（不兼容的架构只诊断、不修）。
- 不修 My Mac 的进程目录「加载后不重建侧栏节点」那一处（调研里未实测的那条）。
- 不在实例之间、启动之间记住宿主 App 与搜索路径。
- 不恢复窗口，不进 Open Recent。
- 崩溃后不自动重试。

## 改动地图

缩写：`Core/` = `RuntimeViewerCore/Sources/RuntimeViewerCore/`，`Comm/` = `RuntimeViewerCore/Sources/RuntimeViewerCommunication/`，`CoreTests/` = `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/`，`CommTests/` = `RuntimeViewerCore/Tests/RuntimeViewerCommunicationTests/`，`EM/` = `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/`，`EMT/` = `RuntimeViewerPackages/Tests/RuntimeViewerEngineManagementTests/`，`AppCore/` = `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/`，`AppCoreTests/` = `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/`，`AppUI/` = `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/`，`App/` = `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`，`Plugin/` = `RuntimeViewerUsingAppKit/RuntimeViewerServicePlugin/`。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `Core/Images/DylibPathResolver.swift` · `DylibPathResolver` | 修改 | 新增 `resolution(of:imagePath:rpathStack:mainExecutablePath:) -> Resolution`，逐条记下 rpath 的归属、原文、展开、候选与结果；原 `resolve(…)` 改为取它的 `resolvedPath`，日志不变 | 诊断要的正是这份尝试记录 | 1 |
| `Core/ImageLoadDiagnosis/RuntimeImageLoadDiagnosis.swift` · `RuntimeImageLoadDiagnosis` | 新增 | 线上模型：失败、依赖链、rpath 查找、dyld 的尝试、说明、修复方案、出处；`init(dyldMessage:imagePath:)` 给旧版对端的简化诊断 | 诊断要过线，App 与 Core 共用 | 1 |
| `Core/ImageLoadDiagnosis/DyldLoadFailureMessage.swift` · `DyldLoadFailureMessage` | 新增 | 解析 `dlerror()` 原文：种类、install name、Referenced from、符号、Expected in、`tried:` 列表及理由 | 两种诊断都从原文起步 | 1 |
| `Core/ImageLoadDiagnosis/RuntimeImageLoadDiagnostician.swift` · `RuntimeImageLoadDiagnostician` | 新增 | 在本进程模拟 dyld 的查找：rpath 栈、依赖遍历、修复方案；`Environment` 是测试接缝 | 诊断本身 | 1 |
| `CoreTests/ImageLoadDiagnosis/ImageLoadFixtures.swift` | 新增 | 测试时用 `xcrun clang` 在临时目录建 `Example.app` 及其 `Foo` / `Bar` 框架（名字带随机后缀）、缺符号与 x86_64 的变体 | 诊断要真 Mach-O；随机名防止已加载镜像按 install name 串到别的用例 | 1 |
| `CoreTests/ImageLoadDiagnosis/PreloadSatisfiesRpathDependencyTests.swift` | 新增 | 实测：Foo 先失败；按绝对路径加载 Bar 后 Foo 成功 | 修复方案的前提（读源码可行、未实测）；不成立就停下 | 1 |
| `CoreTests/ImageLoadDiagnosis/DyldLoadFailureMessageTests.swift` | 新增 | 三种原文（缺镜像、缺符号、架构不兼容）与未知原文的解析 | 解析器的行为 | 1 |
| `CoreTests/ImageLoadDiagnosis/RuntimeImageLoadDiagnosticianTests.swift` | 新增 | 依赖链、rpath 行、`@executable_path` 的说明、宿主 App 推断、修复方案的顺序、搜索路径、找不到时没有方案 | 诊断的行为 | 1 |
| `Core/ImageLoadDiagnosis/RuntimeImageLoadError.swift` · `RuntimeImageLoadError` | 新增 | `LocalizedError`（描述 = dyld 原文），带可选的诊断；`Codable` | 调用方拿到的失败 | 2 |
| `Core/ImageLoadDiagnosis/RuntimeImageLoadResponse.swift` · `RuntimeImageLoadResponse` | 新增 | `LoadImageCommand` 的新回复：`failure: RuntimeImageLoadError?`，为空时编码成空对象 | 诊断放在回复里过线 | 2 |
| `Core/Engine/RuntimeEngine+Commands.swift` · `LoadImageCommand` | 修改 | 加 `reportsFailureDiagnosis: Bool?`；`Response` 换成 `RuntimeImageLoadResponse`；`perform(on:)` 在字段为真时接住 `DyldOpenError`、诊断、作为回复返回 | §4.4 发送方保守 | 2 |
| `Core/Engine/RuntimeEngine+Commands.swift` · `DiagnoseImageLoadCommand` | 新增 | 线上名 `diagnoseImageLoad`；`subjectImagePath` 为 `nil`（问的是这个进程的依赖与 rpath） | 选了宿主 App 或搜索路径后重新诊断 | 2 |
| `Core/Engine/Commands/RuntimeEngineCommandName.swift` | 修改 | 加 `diagnoseImageLoad` | 命令名 | 2 |
| `Core/Engine/RuntimeEngine.swift` · `registerBuiltInHandlers(into:)` | 修改 | 注册 `DiagnoseImageLoadCommand` | 内置命令 | 2 |
| `Core/SharedCache/RuntimeEngine+SharedCache.swift` · `loadImageInServingProcess(at:)` | 修改 | 发带 `reportsFailureDiagnosis: true` 的请求；回复带失败时抛 `RuntimeImageLoadError` | Load Frameworks 的加载拿到诊断 | 2 |
| `Core/ImageLoadDiagnosis/RuntimeEngine+ImageLoadDiagnosis.swift` | 新增 | `diagnoseImageLoad(at:dyldMessage:hostApplicationPath:searchPaths:)`；`diagnosesImageLoadsOnRequest`（只有进程内与框架实例为真，其余不问就抛 `unknownCommand`） | 新命令不发给可能是旧版的对端 | 2 |
| `CoreTests/ImageLoadDiagnosis/LoadImageFailureDiagnosisWireTests.swift` | 新增 | 新请求方 × 新服务端带回诊断；新请求方 × 冻结的旧服务端只有原文；冻结的旧请求方 × 新服务端回复与旧版逐字节相同；经新版中转原样转发；XPC service、TCP 与 Mach service 的 `XPCEncoder` 三条路 | §4.4 的冻结读端测试 | 2 |
| `CoreTests/SharedCache/SharedCacheRoutingDeclarationTests.swift` | 修改 | 登记 `DiagnoseImageLoadCommand` 为「Neither」 | 新命令声明路由 | 2 |
| `CoreTests/DyldLoadFailureMessageTests.swift` | 修改 | 加「`loadImageInServingProcess` 的失败带诊断」，三种传输 | 诊断随失败过线 | 2 |
| `Comm/RuntimeSource.swift` · `RuntimeSource` | 修改 | 新 case `frameworkInstance(name:frameworkURL:identifier:)`；`description`、`remoteRole`（nil）、`==` 与 `hash`（按 identifier）、`isMirrorableToPeers`（假）、`identifier` | 框架实例是一种新来源 | 3 |
| `Comm/RuntimeCommunicator.swift` | 修改 | `.frameworkInstance` 与 `.file` 同走 `.xpcService(target)` | 传输与文件实例相同 | 3 |
| `Core/FrameworkInstance/RuntimeFrameworkInstance.swift` · `RuntimeFrameworkInstance` | 新增 | 实例的标识、名字、第一个框架的 URL；`source` | launch payload 与来源的唯一出处 | 3 |
| `Core/FrameworkInstance/RuntimeFrameworkService.swift` · `RuntimeFrameworkService` | 新增 | `Info.plist` 键 `RuntimeViewerFrameworkServiceBundleIdentifier`、`credential(for:)`、payload 编解码 | XPC 代码只在这几处（根 `AGENTS.md`） | 3 |
| `Core/FrameworkInstance/RuntimeFrameworkServiceHost.swift` · `RuntimeFrameworkServiceHost` | 新增 | 第一个 `hello` 时解出实例、记下基线镜像、建引擎、`RuntimeLocalServiceHost(engine:connection:).start()` | 照 `RuntimeFileServiceHost` | 3 |
| `Core/FrameworkInstance/RuntimeFrameworkInstanceImageCatalog.swift` · `RuntimeFrameworkInstanceImageCatalog` | 新增 | 包着进程目录：`prepareImage` 先记下路径再 `dlopen`；`imagePaths()` 与两个根节点只含经引擎加载的与新带进来的非 shared cache 镜像；`rootNodesFollowLoads` 为真 | 侧栏只列这次加载的 | 3 |
| `Core/Images/RuntimeImageCatalog.swift` · `RuntimeImageCatalog` | 修改 | 加 `rootNodesFollowLoads: Bool`，扩展里默认 `false` | 目录说了算，引擎不认识具体目录 | 3 |
| `Core/Engine/RuntimeEngine.swift` · `_loadImage(at:progressContinuation:)` | 修改 | 加载之后（失败也算）`reloadLocalData(isReloadImageNodes: imageCatalog.rootNodesFollowLoads)`；`credentialMovesWorkOutOfProcess` 与 `forwardsToServiceProcess` 认新 case | 侧栏跟上加载；App 一侧的引擎从一开始就转发 | 3 |
| `Core/FrameworkInstance/RuntimeEngine+FrameworkInstance.swift` | 新增 | `init(servingFrameworkInstance:engineID:hostInfo:)`，服务端用 | 照 `RuntimeEngine(reading:)` | 3 |
| `Core/FrameworkInstance/RuntimeHostInfo+FrameworkInstance.swift` | 新增 | `RuntimeHostInfo.frameworkInstances`（「Isolated Frameworks」） | 来源列表单独一节 | 3 |
| `Core/Bookmarks/RuntimeBookmarkScope.swift` | 修改 | `Identity.frameworkInstance(path:)` 与它的 `Kind`、原始值编解码、`recovered(from:)` | 书签按第一个框架的路径归档 | 3 |
| `RuntimeViewerCore/Sources/RuntimeViewerInjection/RuntimeEngine+Injection.swift` | 修改 | `injectionTargetsRunOnThisMachine` 对新 case 为真 | 本机进程 | 3 |
| `CoreTests/FrameworkInstance/RuntimeFrameworkServiceHostTests.swift` | 新增 | 匿名 listener 起 host：空侧栏；加载夹具后侧栏两节；失败的框架在「Frameworks」里；基线镜像不列；客户端离开触发处理器 | host 与目录的行为 | 3 |
| `CoreTests/RuntimeBookmarkScopeTests.swift`、`CommTests/` 里的 `RuntimeSource` 测试 | 修改 | 新 case 的相等、哈希、原始值往返；`isMirrorableToPeers` 为假 | 新来源的身份 | 3 |
| `RuntimeViewerUsingAppKit/RuntimeViewerFrameworkService/main.swift`、`Info.plist`、`RuntimeViewerFrameworkService.entitlements` | 新增 | 外壳；`ServiceType = Application`、`_MultipleInstances = true`；`disable-library-validation` | 新 service | 4 |
| `Configurations/RuntimeViewerFrameworkService/Shared.xcconfig`、`Debug.xcconfig`、`Debug-arm64e.xcconfig`、`Release.xcconfig` | 新增 | 照 file service，另加 `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES` | 设置只在 xcconfig | 4 |
| `Configurations/CodeSigning.xcconfig` | 修改 | 三个 `RUNTIME_VIEWER_FRAMEWORK_SERVICE_*_BUNDLE_IDENTIFIER` | bundle identifier | 4 |
| `Configurations/RuntimeViewerUsingAppKit/Debug.xcconfig`、`Debug-arm64e.xcconfig`、`Release.xcconfig` | 修改 | `RUNTIME_VIEWER_FRAMEWORK_SERVICE_BUNDLE_IDENTIFIER` | App 的 `Info.plist` 用 | 4 |
| `App/Info.plist` | 修改 | `RuntimeViewerFrameworkServiceBundleIdentifier` | App 凭它找内嵌 service | 4 |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.xcproj` | 修改 | 新 target、插件文件夹的成员例外、App 依赖、Embed XPC Services（在 Xcode 里改） | 原生工程 | 4 |
| `RuntimeViewerUsingAppKit/Project.swift` | 修改 | 同上的 Tuist 描述 | 同批提交，`TuistScript.sh check` 通过 | 4 |
| `Plugin/ServicePlugin.swift` · `ServicePlugin` | 修改 | 加 `runFrameworkService()` | 外壳调插件 | 4 |
| `Plugin/ServicePluginEntry.swift` · `ServicePluginEntry` | 修改 | `runFrameworkService()`：两个 `install()`、`embeddedService()`、`RuntimeFrameworkServiceHost`、客户端离开即退出、`activate()`；不开派生数据 | 服务的入口 | 4 |
| `Plugin/ServicePluginLoader.swift`、`Plugin/ServicePlugin.swift`、`Plugin/ServicePluginEntry.swift` 的注释 | 修改 | 「four shells」改为五个 | 文档同步 | 4 |
| `EM/RuntimeEngineManager.swift` · `RuntimeEngineManager` | 修改 | `frameworkInstanceEngines`（并进 `runtimeEngines` 与两处去重）、`startFrameworkInstance(_:)`、`waitUntilFrameworkInstanceIsReady(_:)`、`terminateFrameworkInstance(_:)`；`terminateRuntimeEngine(for:because:)` 认它；`updateSharedCacheOwners()` 与 `isBorrowingEngine(_:)` 把它算作借用方 | 管理器持有实例 | 5 |
| `EM/RuntimeEngineManager.swift` · `FrameworkInstanceLaunching` | 新增 | 闭包接缝：`.live` 用 `RuntimeFrameworkService.credential(for:)`，iOS 上 `.unavailable` | 与 iOS 移植的平台接缝同一写法 | 5 |
| `EM/RuntimeEngineManager+PlatformServices.swift` | 修改 | `FrameworkInstanceLaunching.live` 的两个平台分支 | 平台代码集中一处 | 5 |
| `EMT/FrameworkInstanceEngineManagementTests.swift` | 新增 | 起实例后列在「Isolated Frameworks」；结束后拿掉；是借用方、owner 是 My Mac；不分享、不进 CLI 目录 | 管理器的行为 | 5 |
| `RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Execution/SourceCatalog.swift` | 修改 | `.frameworkInstance` 返回 `nil` | CLI 不列 | 5 |
| `AppCore/FrameworkLoading/FrameworkLoader.swift` · `FrameworkLoader` | 新增 | 一个文档的加载器：逐个加载、记进 Manual Loading、失败时的诊断与简化诊断、修复、重试、宿主 App 与搜索路径、实例停止 | 加载流程的唯一归属 | 6 |
| `AppCore/FrameworkLoading/FrameworkLoadState.swift` | 新增 | `FrameworkLoadState`、`FrameworkLoadFailure`、`FrameworkLoadInterruption` | 加载器的状态值 | 6 |
| `AppCore/FrameworkLoading/FrameworkInstanceName.swift` | 新增 | 由选中的框架算出来源名 | 一处定名 | 6 |
| `AppCore/FrameworkLoading/ImageLoadDiagnosisPresentation.swift` | 新增 | 诊断页的值：标题、结论、标签、横幅与按钮标题、依赖链、两张表、原文、拷贝用的纯文本 | 视图只画值 | 6 |
| `AppCore/FrameworkLoading/FrameworkLoadViewModel.swift` · `FrameworkLoadViewModel` | 新增 | `ViewModel<MainRoute>`；`Presentation.editorArea` / `.sheet`；页面状态、各按钮的 `Input` | 加载页与诊断页 | 6 |
| `AppCore/Engine/RuntimeFrameworkInstanceRetirement.swift` | 新增 | 订阅占用变化，`.vacated` 的框架实例立即结束 | 关窗即退出 | 6 |
| `AppCore/Document/DocumentState.swift` · `DocumentState` | 修改 | `frameworkLoader`（懒建） | 文档持有加载器 | 6 |
| `AppCore/Main/MainRoute.swift` · `MainRoute` | 修改 | `openIsolatedFrameworks([URL])`、`frameworkLoadFailure` | 开新窗口、弹 sheet | 6 |
| `AppCore/Main/MainViewModel.swift` · `MainViewModel` | 修改 | `frameworksSelected` 按引擎分三路；失败且窗口已有内容时发 `.frameworkLoadFailure`；工具栏标题与副标题在框架实例上按加载状态；按钮 tooltip | 入口分流 | 6 |
| `AppCore/BackgroundWork/Indexing/RuntimeEngine+ImageIndexing.swift` | 修改 | `loadImageForUser` 对新 case 走带进度的加载 | 与 App 同版本 | 6 |
| `AppCore/Sidebar/Root/SidebarRootViewModel.swift` · `isOnThisMac(_:)` | 修改 | 新 case 为真 | 本机磁盘上的镜像 | 6 |
| `AppUI/Engine/RuntimeEngineIconProvider.swift` | 修改 | 新 case 用第一个框架的文件图标 | 来源图标 | 6 |
| `AppCoreTests/FrameworkLoaderTests.swift` | 新增 | 见步骤 6 的行为清单 | 加载器的行为 | 6 |
| `AppCoreTests/FrameworkLoadViewModelTests.swift`、`ImageLoadDiagnosisPresentationTests.swift` | 新增 | 页面状态与按钮；结论句、横幅、表格行 | 页面的行为 | 6 |
| `AppCoreTests/RuntimeFrameworkInstanceRetirementTests.swift` | 新增 | 离开即结束；文件引擎与其他引擎不受影响 | 生命周期 | 6 |
| `AppCoreTests/MainViewModel…Tests`（Load Frameworks 分流） | 新增 | My Mac 发 `.openIsolatedFrameworks`；框架实例与其他引擎交给加载器；文件引擎不可用 | 入口分流 | 6 |
| `App/App/FrameworkInstanceController.swift` · `FrameworkInstanceController` | 新增 | `openWindow(loadingFrameworksAt:)`：起实例、`Document(runtimeEngine:)`、显示窗口、交给加载器；`start()` 启动 retirement | 照 `FileController` | 7 |
| `App/App/AppDelegate.swift` | 修改 | `applicationDidFinishLaunching` 里一行 `frameworkInstanceController.start()` | AppDelegate 只派发 | 7 |
| `App/Main/MainCoordinator.swift` | 修改 | `.openIsolatedFrameworks` 交给 `FrameworkInstanceController`；`.frameworkLoadFailure` 以 sheet 显示 `FrameworkLoadViewController` | 路由 | 7 |
| `App/EditorArea/EditorAreaCoordinator.swift` | 修改 | 把主路由交给每个 `ContentCoordinator` | 编辑栏里的页面要 `Router<MainRoute>` | 7 |
| `App/Content/ContentCoordinator.swift` | 修改 | 第四个场景 `frameworkLoad`：空栏（`.placeholder` 与没有条目的 `.back`）在加载器要显示页面时进入它；页面状态变了重新判一次 | 诊断显示在内容区 | 7 |
| `App/Content/FrameworkLoadViewController.swift` · `FrameworkLoadViewController` | 新增 | 加载页、诊断页、实例停止页；选宿主 App 与搜索路径的 open panel；嵌套的私有视图 `DiagnosisView` | 页面本身 | 7 |
| `AGENTS.md`（根） | 修改 | Application Targets 加 `RuntimeViewerFrameworkService`；外壳数与「one copy … for the four processes」改为五；install 表加一行；XPC 代码的位置加 `FrameworkInstance/`；Derived data 一节注明它不开 | 文档同步 | 8 |
| `Configurations/AGENTS.md` | 修改 | 插件段落的外壳数 | 文档同步 | 8 |
| `Documentations/CommunicationAndEngineArchitecture.md` | 修改 | §4.4 加第四例（`LoadImageCommand` 的可选字段与回复形状）；§3.6 的 service 清单 | 兼容规则的实例 | 8 |
| `Documentations/Glossary.md` | 修改 | 落地时判断：「独立实例 / framework instance」「加载诊断」 | 新术语 | 8 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案 | 索引 | 0 |
| `RuntimeViewerCore/Tests/AGENTS.md` | 不动 | 框架实例不开派生数据，测试不碰真实位置 | — | — |
| `RuntimeViewerMCP/`、CLI 的命令 | 不动 | 非目标 | — | — |

## 架构图

改了什么：

```text
RuntimeViewer.app/Contents
├─ XPCServices/
│  ├─ RuntimeViewerLocalService.xpc            My Mac            ~ no longer takes Load Frameworks
│  ├─ RuntimeViewerFileService.xpc             one per file
│  ├─ RuntimeViewerCatalystService.xpc         My Mac (Catalyst)
│  └─ + RuntimeViewerFrameworkService.xpc      one per Load Frameworks window
│                                               _MultipleInstances, disable-library-validation
└─ PlugIns/RuntimeViewerServicePlugin.bundle
   └─ ServicePluginEntry   + runFrameworkService()

RuntimeViewerCommunication
└─ RuntimeSource   + case frameworkInstance(name:frameworkURL:identifier:)

RuntimeViewerCore
├─ + FrameworkInstance/
│    + RuntimeFrameworkInstance, RuntimeFrameworkService (credential, payload)
│    + RuntimeFrameworkServiceHost, RuntimeFrameworkInstanceImageCatalog
│    + RuntimeEngine(servingFrameworkInstance:), RuntimeHostInfo.frameworkInstances
├─ + ImageLoadDiagnosis/
│    + RuntimeImageLoadDiagnosis, RuntimeImageLoadError, RuntimeImageLoadResponse
│    + DyldLoadFailureMessage, RuntimeImageLoadDiagnostician
│    + RuntimeEngine.diagnoseImageLoad(at:…)
├─ Images/DylibPathResolver          ~ returns its attempts
├─ Images/RuntimeImageCatalog        + rootNodesFollowLoads
└─ Engine/
     LoadImageCommand                ~ + reportsFailureDiagnosis: Bool?   Response: RuntimeEngineEmpty -> RuntimeImageLoadResponse
     + DiagnoseImageLoadCommand      (answered by the serving process; sent only to framework instances)

RuntimeViewerEngineManagement
└─ RuntimeEngineManager   + frameworkInstanceEngines, startFrameworkInstance, terminateFrameworkInstance
                          ~ shared cache owners: framework instances borrow from My Mac

RuntimeViewerAppCore
├─ + FrameworkLoading/   FrameworkLoader, FrameworkLoadState, FrameworkLoadViewModel,
│                        ImageLoadDiagnosisPresentation, FrameworkInstanceName
├─ + Engine/RuntimeFrameworkInstanceRetirement
├─ Main/MainViewModel    ~ frameworksSelected: My Mac -> new window; others -> loader
└─ Main/MainRoute        + openIsolatedFrameworks([URL]), frameworkLoadFailure

RuntimeViewerUsingAppKit (app target)
├─ + App/FrameworkInstanceController
├─ + Content/FrameworkLoadViewController
├─ Content/ContentCoordinator   + scene .frameworkLoad (empty panes)
└─ Main/MainCoordinator         + routes above
```

在 My Mac 的窗口里加载，一次失败再修好：

```text
Toolbar "Load Frameworks" (window on My Mac)
└─ MainViewModel.frameworksSelected([Foo.framework])
   └─ MainRoute.openIsolatedFrameworks([URL])
      └─ MainCoordinator → FrameworkInstanceController.openWindow(loadingFrameworksAt:)
         ├─ RuntimeEngineManager.startFrameworkInstance(instance)
         │    RuntimeEngine(source: .frameworkInstance) ── xpc dedicatedInstance(payload: instance) ──▶ new process
         │                                                    RuntimeFrameworkServiceHost: baseline images, engine
         ├─ Document(runtimeEngine:) → window (empty pane shows "Loading Foo.framework…")
         └─ documentState.frameworkLoader.load(frameworksAt:)
            └─ recordingManualLoad → engine.loadImageInServingProcess(Foo)   [reportsFailureDiagnosis: true]
                 instance: catalog records Foo → dlopen fails (DyldOpenError)
                           RuntimeImageLoadDiagnostician.diagnose(Foo, dyldMessage)
                             chain Foo → @rpath/Bar ✗, rpath rows, host Example.app, remedy [Bar]
                 ◀─ RuntimeImageLoadResponse(failure: RuntimeImageLoadError(diagnosis))
               state = .failed → empty pane shows FrameworkLoadViewController (diagnosis)
                 [Load Example.app's Frameworks and Retry]
                   loadImageInServingProcess(/Applications/Example.app/…/Bar)   ← preload by absolute path
                   loadImageInServingProcess(Foo)                                ← dyld matches Bar's install name
                 [Choose Host App… / Add Search Path…]
                   engine.diagnoseImageLoad(Foo, dyldMessage, hostApplicationPath / searchPaths)
                   → remedy? apply it : show the new diagnosis
               state = .idle → sidebar: Frameworks [Bar, Foo]; focused pane opens Foo's image page
```

实例的生命周期与其他引擎上的失败：

```text
window closes / switches source
└─ DocumentState.documentWillClose → occupancy .vacated(engine)
   └─ RuntimeFrameworkInstanceRetirement
      └─ RuntimeEngineManager.terminateFrameworkInstance(engine)  → unlisted, engine.stop()
         └─ client connection closes → instance: setClientDepartureHandler → exit(EXIT_SUCCESS)

instance crashes
└─ connection: .disconnected → reattach to a NEW, EMPTY instance (same payload, no frameworks listed)
   └─ FrameworkLoader: state = .instanceStopped(request, during: Foo?) → page with [Load Again]

window on an injected process / Catalyst / remote Mac
└─ frameworkLoader.load → loadImageInServingProcess  [reportsFailureDiagnosis: true]
   ├─ peer of this build  → diagnosis in the reply
   └─ older peer          → field skipped, text only → RuntimeImageLoadDiagnosis(dyldMessage:imagePath:)
   └─ MainRoute.frameworkLoadFailure → sheet (diagnosis, copy, Show in Finder; no retry, no remedy)
```

## 详细设计

### 落点与「改动要聚合」

- XPC 相关的代码只在根 `AGENTS.md` 列出的几处：`Core/FrameworkInstance/RuntimeFrameworkService.swift`（键、凭证、payload）与 `RuntimeFrameworkServiceHost.swift`，以及 `ServicePluginEntry.runFrameworkService()`。传输本身零改动——`.dedicatedInstance` 是文件模式已有的。
- `RuntimeEngine` 只改两处判断（新 case 一开始就转发；凭证把工作移出进程）与 `_loadImage` 末尾一行（是否重建节点，由目录说了算）。引擎不认识「框架实例」这个概念，只认识目录的 `rootNodesFollowLoads`。
- 新 `RuntimeSource` case 碰到的穷举 `switch` 每处一行，集中在步骤 3。
- App 一侧的加载流程只在 `FrameworkLoader` 一处；`MainViewModel` 只做分流。

### Core：诊断

```swift
// Core/ImageLoadDiagnosis/RuntimeImageLoadDiagnosis.swift
/// Why dyld refused to load an image, worked out in the process that tried.
public struct RuntimeImageLoadDiagnosis: Codable, Sendable, Hashable {
    /// What dyld said went wrong. A struct with an open `Kind`, not an enum: a later
    /// version may name a kind an earlier app has never heard of, and must still decode.
    public struct Failure: Codable, Sendable, Hashable {
        public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String
            public init(rawValue: String)
            public static let imageNotFound = Kind(rawValue: "imageNotFound")
            public static let symbolNotFound = Kind(rawValue: "symbolNotFound")
            public static let incompatibleImage = Kind(rawValue: "incompatibleImage")
            public static let unrecognized = Kind(rawValue: "unrecognized")
        }
        public var kind: Kind
        public var missingInstallName: String?
        public var symbolName: String?
        public var referencingImagePath: String?
        public var expectedInImagePath: String?
        public var reason: String?
    }

    /// One edge of the dependency chain from the requested image to the failure.
    public struct ChainLink: Codable, Sendable, Hashable {
        public var imagePath: String
        public var installName: String
        public var isResolved: Bool
    }

    /// One place dyld looked for a missing `@rpath/` image.
    public struct RpathSearch: Codable, Sendable, Hashable {
        public struct Role: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String
            public init(rawValue: String)
            public static let mainExecutable = Role(rawValue: "mainExecutable")
            public static let dlopenCaller = Role(rawValue: "dlopenCaller")
            public static let loader = Role(rawValue: "loader")
            public static let searchPath = Role(rawValue: "searchPath")
        }
        public var ownerImagePath: String
        public var role: Role
        public var rpath: String
        public var candidatePath: String
        public var outcome: String
    }

    public struct TriedPath: Codable, Sendable, Hashable {
        public var path: String
        public var reason: String
    }

    /// A sentence the page shows under the table: why the search went where it went.
    public struct Note: Codable, Sendable, Hashable {
        public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String
            public init(rawValue: String)
            /// An rpath written for a host app's executable, expanded against this process's.
            public static let rpathExpectsHostExecutable = Kind(rawValue: "rpathExpectsHostExecutable")
            /// The missing image is next to the requested one, in its app's Frameworks directory.
            public static let dependencyInHostApplication = Kind(rawValue: "dependencyInHostApplication")
            /// A symbol is missing from an image that exists: a different version of it.
            public static let symbolMissingFromImage = Kind(rawValue: "symbolMissingFromImage")
            /// The image has no slice this process can run.
            public static let architectureMismatch = Kind(rawValue: "architectureMismatch")
        }
        public var kind: Kind
        public var imagePath: String?
        public var rpath: String?
        public var hostApplicationPath: String?
        public var architectures: [String]?
    }

    /// Images to load by absolute path, dependencies first, before the requested one is tried again.
    public struct Remedy: Codable, Sendable, Hashable {
        public var hostApplicationPath: String?
        public var searchPaths: [String]
        public var imagePathsToLoadFirst: [String]
    }

    public var imagePath: String
    public var dyldMessage: String
    public var failure: Failure
    public var dependencyChain: [ChainLink]
    public var rpathSearches: [RpathSearch]
    public var triedPaths: [TriedPath]
    public var notes: [Note]
    public var remedy: Remedy?
    /// The serving process's architecture and system, which the search depends on.
    public var processArchitecture: String?
    public var operatingSystemVersion: String?
    /// True when only dyld's message was available: the process that tried is from an
    /// earlier version and could not work anything out itself.
    public var isFromMessageOnly: Bool

    /// What can be read from dyld's message alone, for a failure reported by an older peer.
    public init(dyldMessage: String, imagePath: String)
}
```

```swift
// Core/ImageLoadDiagnosis/RuntimeImageLoadDiagnostician.swift
/// Retraces dyld's search for an image that failed to load, in this process.
struct RuntimeImageLoadDiagnostician {
    struct Environment: Sendable {
        /// The executable `@executable_path` expands against: the service's shell.
        var mainExecutablePath: String
        /// The image that called `dlopen`, whose rpaths come second: the image holding RuntimeViewerCore.
        var dlopenCallerImagePath: String
        var isSharedCacheImage: @Sendable (String) -> Bool
        /// Install names of the images already loaded, which dyld matches before it searches.
        var loadedImagePathsByInstallName: @Sendable () -> [String: String]
        var fileExists: @Sendable (String) -> Bool
        var processArchitecture: String
        var operatingSystemVersion: String

        static func currentProcess() -> Environment
    }

    init(environment: Environment)

    func diagnose(
        imageAt imagePath: String,
        dyldMessage: String,
        hostApplicationPath: String?,
        searchPaths: [String]
    ) -> RuntimeImageLoadDiagnosis
}
```

算法：

1. `DyldLoadFailureMessage(parsing:)` 解出失败与 `tried:` 列表。
2. rpath 栈的底是主程序的 `LC_RPATH`，然后是调用 `dlopen` 的镜像的。从磁盘读要加载的镜像（`MachOFile`，胖文件取本进程 CPU 的切片；取不到切片即「镜像不兼容」，列出它有的架构），深度优先沿非弱链接、非延迟初始化的依赖走，每进一层把加载者自己的 rpath 压栈；一条边先按 install name 匹配已加载的镜像，再用 `DylibPathResolver.resolution(…)` 逐条展开。第一条解析不了的边（原文里有 `Referenced from` 时优先找那一条）就是依赖链的终点。`visited` 集合防环。
3. 那条边的 install name 以 `@rpath/` 开头时，`Resolution` 的每一次尝试成为 `RpathSearch` 的一行；`@executable_path` 开头的 rpath 出现在非主程序的镜像上时，加一条 `rpathExpectsHostExecutable` 说明。
4. 修复方案：宿主 App 候选依次是 `hostApplicationPath` 与要加载的镜像路径上最近的 `.app`；以宿主 App 的 `Bundle.executablePath` 作主程序、`searchPaths` 作额外 rpath，把整棵依赖树重走一遍。原本解析不了、换了环境能解析的镜像按「依赖在前」排好就是 `imagePathsToLoadFirst`；还有解析不了的就不给方案。缺的镜像在宿主 App 的 `Contents/Frameworks` 里时，加 `dependencyInHostApplication` 说明。
5. 缺符号时只给依赖链与 `symbolMissingFromImage` 说明（`Expected in` 那个镜像存在，版本不对），不给方案。

```swift
// Core/ImageLoadDiagnosis/RuntimeImageLoadError.swift
/// A load dyld refused, with what the process that tried worked out about why.
public struct RuntimeImageLoadError: Error, LocalizedError, CustomStringConvertible, Codable, Sendable, Hashable {
    public var dyldMessage: String
    /// Nil only when the serving process could not diagnose the failure.
    public var diagnosis: RuntimeImageLoadDiagnosis?
    public var errorDescription: String? { dyldMessage }
    public var description: String { dyldMessage }
}

// Core/ImageLoadDiagnosis/RuntimeImageLoadResponse.swift
/// What a load answers. Encodes as an empty object when it succeeded — byte for byte
/// what `RuntimeEngineEmpty` encoded — so a requester that never asked for a diagnosis
/// reads it as before.
public struct RuntimeImageLoadResponse: Codable, Sendable {
    public var failure: RuntimeImageLoadError?
}
```

```swift
// Core/Engine/RuntimeEngine+Commands.swift
struct LoadImageCommand: RuntimeEngineCommand {
    typealias Response = RuntimeImageLoadResponse
    let path: String
    /// Set by a requester that reads a failure from the reply. A peer of an earlier version
    /// skips the key and keeps failing with dyld's message, which is all such a requester
    /// then gets. Never set, the reply is the empty object it always was.
    var reportsFailureDiagnosis: Bool?

    var subjectImagePath: String? { path }
    static var isForegroundLoad: Bool { true }
    static var indexesSubjectImage: Bool { true }

    func perform(on engine: RuntimeEngine) async throws -> Response
    // in process: try await engine._loadImage(at: path); on DyldOpenError, when
    // reportsFailureDiagnosis == true, return .init(failure: diagnosed error); otherwise rethrow
}

/// Retraces a failed load with a host app or extra search paths. Answered by the process
/// that tried the load — its dependencies and rpaths are its own, so no owner answers it
/// (`subjectImagePath` is nil). Sent only to engines whose serving process is known to be
/// of this build: one in this process, or a framework instance.
struct DiagnoseImageLoadCommand: RuntimeEngineCommand {
    typealias Response = RuntimeImageLoadDiagnosis
    let imagePath: String
    let dyldMessage: String
    let hostApplicationPath: String?
    let searchPaths: [String]
}
```

```swift
// Core/ImageLoadDiagnosis/RuntimeEngine+ImageLoadDiagnosis.swift
extension RuntimeEngine {
    /// Whether `diagnoseImageLoad(at:…)` may be asked: the serving process is this one,
    /// or a framework instance, embedded in the same build.
    public nonisolated var diagnosesImageLoadsOnRequest: Bool

    /// Throws `RuntimeNetworkRequestError.unknownCommand(named:)` without asking when
    /// `diagnosesImageLoadsOnRequest` is false.
    public func diagnoseImageLoad(
        at imagePath: String,
        dyldMessage: String,
        hostApplicationPath: String? = nil,
        searchPaths: [String] = []
    ) async throws -> RuntimeImageLoadDiagnosis
}

// SharedCache/RuntimeEngine+SharedCache.swift — signature unchanged
/// Throws `RuntimeImageLoadError` when dyld refused the image; its `diagnosis` is nil
/// when the serving process is of an earlier version.
public func loadImageInServingProcess(at path: String) async throws
```

`loadImageInServingProcess` 收到旧版对端抛来的普通错误时原样抛出，由 App 一侧决定要不要做简化诊断；Core 不猜一段文字是不是 dyld 的。

### Core：框架实例

```swift
// Comm/RuntimeSource.swift
/// Frameworks the user loaded into an instance of the framework service of their own —
/// Load Frameworks. The identity is `identifier` alone; `name` is what menus show and
/// `frameworkURL`, the first framework chosen, is what bookmarks are filed under.
case frameworkInstance(name: String, frameworkURL: URL, identifier: Identifier)
```

```swift
// Core/FrameworkInstance/RuntimeFrameworkInstance.swift
public struct RuntimeFrameworkInstance: Codable, Sendable, Hashable {
    public var identifier: String
    public var name: String
    public var frameworkURL: URL
    public init(identifier: String = UUID().uuidString, name: String, frameworkURL: URL)
    public var source: RuntimeSource { get }
}

// Core/FrameworkInstance/RuntimeFrameworkService.swift
public enum RuntimeFrameworkService {
    public static let bundleIdentifierInfoDictionaryKey = "RuntimeViewerFrameworkServiceBundleIdentifier"
    /// The framework service this process embeds, by the key in its own Info.plist;
    /// nil in every process but the app.
    public static var embeddedServiceBundleIdentifier: String? { get }
    /// A connection to a new instance of the service for `instance`; nil when this
    /// process embeds no framework service.
    public static func credential(for instance: RuntimeFrameworkInstance) throws -> RuntimeConnectionCredential?
    static func launchPayload(for instance: RuntimeFrameworkInstance) throws -> Data
    static func instance(fromLaunchPayload payload: Data) throws -> RuntimeFrameworkInstance
}

// Core/FrameworkInstance/RuntimeFrameworkServiceHost.swift
/// What an instance of the framework service runs: on the first `hello` it reads which
/// instance it is, notes the images already loaded — RuntimeViewer's own, which its
/// sidebar leaves out — and serves an engine over this process's images.
public final class RuntimeFrameworkServiceHost {
    public init(connection: RuntimeXPCServiceListenerConnection)
}

// Core/FrameworkInstance/RuntimeEngine+FrameworkInstance.swift
extension RuntimeEngine {
    public init(
        servingFrameworkInstance instance: RuntimeFrameworkInstance,
        baselineImagePaths: Set<String>,
        engineID: String = UUID().uuidString,
        hostInfo: RuntimeHostInfo = RuntimeHostInfo(
            hostID: RuntimeNetworkBonjour.localInstanceID,
            hostName: RuntimeNetworkBonjour.localHostName,
        )
    )
}

// Core/FrameworkInstance/RuntimeFrameworkInstanceImageCatalog.swift
/// This process's images, as a framework instance lists them: the ones loaded through
/// the engine, failed or not, in order, and the images dyld brought in with them from
/// outside the shared cache. Nothing that was loaded when the instance started.
final class RuntimeFrameworkInstanceImageCatalog: RuntimeImageCatalog {
    init(baselineImagePaths: Set<String>)
    var rootNodesFollowLoads: Bool { true }
    // prepareImage(at:) records the path under "Frameworks", then dlopens it through
    // RuntimeProcessImageCatalog; every other requirement forwards to that catalog,
    // except imagePaths() and rootNodes(), which filter as above.
}

// Core/FrameworkInstance/RuntimeHostInfo+FrameworkInstance.swift
extension RuntimeHostInfo {
    public static let frameworkInstances = RuntimeHostInfo(hostID: "frameworkInstances", hostName: "Isolated Frameworks")
}
```

记录「经引擎加载的路径」用 `Mutex<[String]>`（目录要求 `Sendable`）。

### 引擎管理

```swift
// EM/RuntimeEngineManager.swift
@Published public private(set) var frameworkInstanceEngines: [RuntimeEngine]

/// Starts a new instance of the framework service for `instance` and lists its engine
/// under Isolated Frameworks. The engine forwards from the moment it exists; until the
/// instance answers, a request fails rather than being answered from this process.
public func startFrameworkInstance(_ instance: RuntimeFrameworkInstance) throws -> RuntimeEngine

/// Waits for the instance's first connection. Throws when it could not be started.
public func waitUntilFrameworkInstanceIsReady(_ engine: RuntimeEngine) async throws

/// Unlists the engine and stops it; the instance exits once its client has gone.
public func terminateFrameworkInstance(_ engine: RuntimeEngine) async

struct FrameworkInstanceLaunching: Sendable {
    var credential: @Sendable (RuntimeFrameworkInstance) throws -> RuntimeConnectionCredential?
    static let unavailable: Self
}
```

`updateSharedCacheOwners()` 的借用方列表加上 `frameworkInstanceEngines`；`isBorrowingEngine(_:)` 对新 case 为真。实例的 owner 与 My Mac 的引擎相同（My Mac 是 owner）。

### App 一侧

```swift
// AppCore/FrameworkLoading/FrameworkLoadState.swift
public enum FrameworkLoadState: Equatable, Sendable {
    case idle
    case loading(frameworkURL: URL, position: Int, count: Int)
    case failed(FrameworkLoadFailure)
    case instanceStopped(FrameworkLoadInterruption)
}

public struct FrameworkLoadFailure: Equatable, Sendable {
    public var frameworkURL: URL
    public var diagnosis: RuntimeImageLoadDiagnosis
    public var remainingFrameworkURLs: [URL]
    /// Retry, the remedy, Choose Host App and Add Search Path: only in a framework instance.
    public var offersRemedies: Bool
}

public struct FrameworkLoadInterruption: Equatable, Sendable {
    /// Every framework the window asked for, to load again in the new instance.
    public var frameworkURLs: [URL]
    /// The load the instance stopped during, when it stopped during one.
    public var interruptedFrameworkURL: URL?
}

// AppCore/FrameworkLoading/FrameworkLoader.swift
/// Loads the frameworks a window asks for into its engine, one after another, and keeps
/// what the window shows about it. One per document; a document on a framework instance
/// keeps the host app and search paths the user gave it until it closes.
@MainActor
public final class FrameworkLoader {
    @Published public private(set) var state: FrameworkLoadState = .idle
    /// Whether the window's empty editor panes show the loading or failure page.
    public var showsPageInEmptyPanes: Bool { get }

    init(documentState: DocumentState)

    public func load(frameworksAt frameworkURLs: [URL]) async
    public func retry() async
    public func applyRemedy() async
    public func retry(hostedBy applicationURL: URL) async
    public func retry(searching directoryURL: URL) async
    public func loadAgain() async
}
```

- 每次加载走 `documentState.recordingManualLoad(ofImageAt:)`（Report 的 Manual Loading 照旧记录；它也让 App 不进 App Nap）。
- 失败：错误是 `RuntimeImageLoadError` 且带诊断，用它；不带诊断或是别的错误，用 `RuntimeImageLoadDiagnosis(dyldMessage: error.localizedDescription, imagePath:)`。窗口在框架实例上、且已有宿主 App 或搜索路径时，先带着它们 `diagnoseImageLoad` 一次。
- 一次选的几个框架：一个失败就停在它上面，剩下的留在 `remainingFrameworkURLs`；重试或修复成功后接着加载剩下的。
- 实例停止：订阅引擎的 `statePublisher`，`.disconnected` 时进入 `.instanceStopped`；`loadAgain()` 等实例重连好，再从头加载 `frameworkURLs`。
- 全部成功且窗口还什么都没打开：经 `SelectionRoute.openImage(firstExecutablePath, in: 焦点栏)` 打开第一个框架的镜像页。

`FrameworkLoadViewModel`（`ViewModel<MainRoute>`）：

- `Input`：`retryClicked`、`remedyClicked`、`hostApplicationChosen: Signal<URL>`、`searchPathChosen: Signal<URL>`、`loadAgainClicked`、`copyDiagnosisClicked`、`showInFinderClicked`、`closeClicked`。
- `Output`：`page: Driver<FrameworkLoadPage>`（`.loading(title:progress:)`、`.failure(ImageLoadDiagnosisPresentation, actions:)`、`.instanceStopped(…)`、`.none`），`requestHostApplication` / `requestSearchPath`（`Signal<Void>`，视图开 open panel）。
- 拷贝走 `pasteboardClient`，Show in Finder 走 `finderClient`；sheet 的关闭发 `.dismiss`。

`MainViewModel.frameworksSelected`：

```swift
switch documentState.runtimeEngine.source {
case .local:
    router.trigger(.openIsolatedFrameworks(urls))
case .file:
    break // the button is disabled
default:
    Task { await documentState.frameworkLoader.load(frameworksAt: urls) }
}
```

失败时（`frameworkLoader.$state` 进入 `.failed`），`showsPageInEmptyPanes` 为假就发 `.frameworkLoadFailure`。

`ContentCoordinator` 在进入占位场景时（`.placeholder`，或 `.back` 到没有条目），`documentState.frameworkLoader.showsPageInEmptyPanes` 为真就进入 `frameworkLoad` 场景；它订阅这个值，栏空着时值一变就重新判一次。`FrameworkLoadViewController` 的 view model 由 `ContentCoordinator` 建，路由用 `EditorAreaCoordinator` 交下来的主路由（编辑栏模式下不会用到 `.dismiss`）。

### 测试夹具

- 夹具在测试时用 `xcrun clang -dynamiclib` 建到临时目录（Apple Silicon 上链接器自动 ad hoc 签名），不把二进制提交进仓库。名字都带随机后缀：dyld 按 install name 匹配已加载的镜像，测试进程里前一个用例加载过的 `Bar` 会让后一个用例的「缺 Bar」不成立。
- 布局：`Example.app/Contents/MacOS/Example`（rpath `@executable_path/../Frameworks`）、`Example.app/Contents/Frameworks/Foo_<id>.framework`（链接 `@rpath/Bar_<id>.framework/Versions/A/Bar_<id>`，rpath `@executable_path/../Frameworks` 与 `@loader_path/Frameworks`）、`Bar_<id>.framework`；缺符号的变体（Foo 链接的 Bar 少一个符号）；只有 x86_64 切片的变体。

## 替代方案考量

- **保留「加载进 My Mac」，只加诊断。** 用户否：卸不掉、构造函数的副作用与崩溃都落在 My Mac 上，正是要解决的问题。
- **所有 Load Frameworks 共用一个长期的框架 service 实例。** 否：卸载要整个实例一起退出，一个窗口的框架会留给另一个窗口；一个框架崩溃牵连所有窗口。
- **用文件模式（`.file` 与 file service）打开框架。** 否：file service 只读不运行，有意不带 library validation 例外；Load Frameworks 要的是真的加载、真的运行（ObjC 运行时注册的类、Swift 元数据实例化后的布局）。文件模式照旧是「不运行就看」的那条路。
- **launch payload 列出要加载的框架，由实例启动时加载。** 否：`.dedicatedInstance` 崩溃后用同一份 payload 起新实例，会再加载一遍刚才崩掉的框架，陷入崩溃循环。
- **给实例设 `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH`。** 否：hardened runtime 下要 `allow-dyld-environment-variables`；XPC service 的环境变量写死在 `Info.plist`，不能按实例给。它是「预加载依赖」实测不成立时的退路之一，代价届时重新评估。
- **新命令 `diagnoseImageLoad` 发给所有引擎。** 否：引擎之间不交换版本，经 Mach service 的旧版注入 payload 收到不认识的命令会断开连接（PR121.73）。改为随失败的那次加载在回复里带回诊断（可选字段），新命令只发给框架实例。
- **在 App 进程里做诊断。** 否：rpath 栈与 `@executable_path` 取决于失败的那个进程，远端 Mac 的文件也不在本机。用户定在失败的进程里做。
- **用 MachODependencies 遍历依赖。** 否：它不展开 `@rpath`、`@loader_path`、`@executable_path`，只按裸名匹配。
- **用 `dlopen_preflight` 预检。** 否：只查顶层镜像的架构切片，不查依赖。
- **读 `DYLD_PRINT_SEARCHING` 的输出。** 否：启动时读、要 AMFI 放行，launchd 管的进程写进 syslog，没有 API 取得。
- **加载时崩溃自动重试。** 用户定不重试，与 0037 一致：重试多半再崩一次。
- **诊断页做成标签历史的一步（`NavigationEntry.Content` 新 case）。** 否：每个穷举 `Content` 的 `switch`（`NavigationEntry` 的辅助属性、`ContentCoordinator` 的 `.back`、路径栏的 `EditorJumpBarItem.Content`）都要改，Back / Forward 会走进一个失败页，关掉标签诊断就没了。用空栏的页面加 sheet。
- **框架实例关窗后像文件引擎一样停 30 秒再挂起。** 否：挂起的文件引擎恢复时会重新读文件，代价只是时间；框架实例恢复要重新运行构造函数，不该悄悄发生。没有窗口就结束。

## 影响

### 用户可见变化

- My Mac 的窗口里点 Load Frameworks，框架不再进 My Mac，而是开一个新窗口「Foo.framework (Isolated)」。原来的习惯（在 My Mac 里加载后与系统框架一起看）的替代：在新窗口里看框架；内容区跳到系统类型照常可用（数据来自 My Mac）；也可以把新窗口的来源换回 My Mac 看系统镜像——那样这个实例会结束。
- 加载失败不再是一个只有原文的提示框：框架实例的窗口在内容区显示诊断，可修复、可重试；其他引擎的窗口弹出带诊断的 sheet。
- 来源选择器多一节「Isolated Frameworks」，列出活着的实例。
- 框架实例的窗口不进 Open Recent，重启后不恢复。

### 可发现性

- 入口不变（工具栏的 Load Frameworks），My Mac 窗口里的 tooltip 改为「在新的独立实例里加载框架」。
- 修复提议直接出现在诊断页的横幅上，不用找。
- 没有开关：独立实例是 Load Frameworks 在 My Mac 上唯一的行为。

### 数据与配置兼容

- 不改设置，不迁移数据。
- 书签多一种归档身份（`frameworkInstance`）。旧版 App 读到这种键时 `init?(rawValue:)` 返回 `nil` 而跳过，不影响其他书签。
- `RuntimeSource` 新 case 不会发给对端（`isMirrorableToPeers` 为假、CLI 目录不列）。步骤 3 核对所有编码 `RuntimeSource` 的地方，确认它不进持久化数据。
- 线上：`LoadImageCommand` 加可选字段，回复在线上仍是空对象（失败且请求方声明读得懂时才带 `failure`）。新旧组合见步骤 2 的测试。

### 平台与最低版本

- 只在 macOS 上（service 只内嵌在 Mac App 里）；最低版本不变（macOS 15）。
- `RuntimeSource` 在所有平台上都多一个 case；iOS 的引擎管理里框架实例不可用。
- 每个独立窗口多一个进程。它的常驻内存（RuntimeViewerCore 加上加载的框架，系统镜像的数据借自 My Mac）**未测**，步骤 8 实测后记进本提案。

### 发布

- 新 XPC service 带 hardened runtime 与 `com.apple.security.cs.disable-library-validation`，与 local service 相同，公证照常通过（local service 已经如此）。正式发版前在 Distribution workspace 里归档并公证一次实测。
- `ArchiveScript.sh` 不列 XPC service，不用改；`SKIP_INSTALL = YES` 照 file service 设上，否则归档不再是 App 归档。
- 不影响 Sparkle；不需要新的隐私清单条目。

## 落地步骤

1. **诊断本身（Core，无界面）** —— 改动地图里步骤 1 的行
   - 先跑 `PreloadSatisfiesRpathDependencyTests`：**不通过就停下回来重议修复方案**，不往下做。
   - 行为：
     - `aMissingRpathDependencyFailsTheLoad`
     - `loadingTheDependencyByAbsolutePathFirstLetsTheLoadSucceed`
     - `parsesLibraryNotLoadedWithTriedPaths`
     - `parsesSymbolNotFoundWithExpectedIn`
     - `parsesIncompatibleArchitecture`
     - `unknownMessageIsUnrecognizedAndKeepsTheText`
     - `chainEndsAtTheFirstUnresolvedDependency`
     - `rpathRowsFollowDyldOrderMainExecutableCallerThenLoaders`
     - `executablePathRpathOnAFrameworkGetsTheHostExecutableNote`
     - `hostApplicationIsInferredFromTheEnclosingApp`
     - `remedyListsDependenciesBeforeDependents`
     - `searchPathActsAsAnExtraRpath`
     - `noRemedyWhenSomethingStaysUnresolved`
     - `symbolNotFoundHasNoRemedy`
     - `alreadyLoadedImagesCountAsResolvedByInstallName`
     - `dylibPathResolverResolveStillReturnsTheSamePaths`

2. **诊断随失败的加载过线（Core）** —— 步骤 2 的行
   - 行为：
     - `servingProcessLoadFailureCarriesDiagnosisInProcess` / `…OverXPCService` / `…OverTCP`
     - `olderServerFailsWithTextOnlyWhenAskedForDiagnosis`（冻结的旧服务端）
     - `olderRequesterGetsTheSameEmptyReplyAsBefore`（冻结的旧请求方，逐字节比较）
     - `relayForwardsTheFieldAndTheReplyUnchanged`
     - `machServiceXPCEncoderSkipsTheOptionalField`
     - `successfulLoadReplyDecodesAsBefore`
     - `diagnoseImageLoadIsNotSentToOtherEngines`（不问就抛 `unknownCommand`）
     - `diagnoseImageLoadIsAnsweredByTheServingProcess`
     - `routingDeclarationListsDiagnoseImageLoadAsNeither`

3. **框架实例的 Core 与传输** —— 步骤 3 的行
   - 核对所有编码 `RuntimeSource` 的地方，确认新 case 不进持久化、不发给对端，结论写进决策日志。
   - 行为：
     - `frameworkInstanceSourcesAreEqualByIdentifierAlone`
     - `frameworkInstanceIsNotMirrorableToPeers`
     - `bookmarkScopeOfAFrameworkInstanceRoundTripsThroughItsRawValue`
     - `credentialIsNilWithoutTheInfoPlistKey`
     - `launchPayloadRoundTrips`
     - `hostListsNothingBeforeTheFirstLoad`
     - `hostListsLoadedFrameworksAndTheirNonCacheDependencies`
     - `failedFrameworkIsListedUnderFrameworks`
     - `imagesLoadedBeforeTheInstanceStartedAreNotListed`
     - `sharedCacheImagesAreNotListed`
     - `imageNodesAreRebuiltAfterEachLoad`
     - `processCatalogStillDoesNotRebuildNodes`
     - `engineForAFrameworkInstanceForwardsFromTheStart`

4. **内嵌 service** —— 步骤 4 的行
   - 构建 Debug-arm64e（`RunScript.sh --no-launch`）与 Release，核对 `Contents/XPCServices/RuntimeViewerFrameworkService.xpc` 在、签名带 `disable-library-validation`、外壳约 86 KB、不链接任何包；`./TuistScript.sh check` 通过。
   - 行为：
     - `appBundleEmbedsTheFrameworkService`（构建后检查）
     - `frameworkServiceShellLinksNoPackage`
     - `pluginAnswersRunFrameworkService`

5. **引擎管理** —— 步骤 5 的行
   - 行为：
     - `startedInstanceIsListedUnderIsolatedFrameworks`
     - `terminatedInstanceIsUnlisted`
     - `frameworkInstanceBorrowsSharedCacheImagesFromMyMac`
     - `frameworkInstanceIsNotShared`
     - `commandLineSourceCatalogLeavesFrameworkInstancesOut`
     - `startFailsWhenTheServiceIsNotEmbedded`

6. **App 的加载流程与页面的值（AppCore）** —— 步骤 6 的行
   - 行为：
     - `loadFrameworksOnMyMacOpensAnIsolatedWindow`
     - `loadFrameworksOnAFrameworkInstanceLoadsInPlace`
     - `loadFrameworksOnAnInjectedProcessLoadsInPlaceWithoutRemedies`
     - `loadFrameworksIsDisabledOnAFile`
     - `loaderLoadsFrameworksInOrderAndRecordsManualLoads`
     - `loaderStopsAtTheFirstFailureAndKeepsTheRest`
     - `retryAfterFixContinuesWithTheRemainingFrameworks`
     - `applyRemedyLoadsDependenciesFirstThenRetries`
     - `chosenHostApplicationIsUsedForLaterFailuresInTheWindow`
     - `olderPeerFailureBecomesAMessageOnlyDiagnosis`
     - `instanceStopDuringALoadShowsInstanceStoppedWithoutRetrying`
     - `loadAgainReloadsEveryRequestedFramework`
     - `successInAnEmptyWindowOpensTheFirstFrameworksImagePage`
     - `failureInAWindowWithContentRoutesToTheSheet`
     - `retirementTerminatesAFrameworkInstanceWhenVacated`
     - `retirementLeavesFileAndOtherEnginesAlone`
     - `presentationSummaryNamesTheMissingImageAndWhoLinksIt`
     - `presentationBannerNamesTheHostApplication`
     - `presentationCopyTextHoldsEverySection`
     - `sheetPresentationHasNoRetryOrRemedy`
     - `instanceNameCountsTheOtherFrameworks`

7. **App 的窗口、路由与页面（App target）** —— 步骤 7 的行
   - 行为：
     - `openWindowCreatesADocumentOnANewInstance`
     - `emptyPaneShowsTheFrameworkLoadSceneWhileTheLoaderAsks`
     - `paneLeavesTheSceneWhenTheLoadSucceeds`
     - `frameworkLoadFailureRoutePresentsASheet`
     - `closingTheWindowEndsTheInstance`（App 内手工核对，见步骤 8）

8. **文档、实测与收尾** —— 步骤 8 的行
   - 手工核对：用一个真实的、带 `@executable_path` rpath 的第三方 App 框架走一遍失败 → 修复 → 成功；关窗后 `pgrep RuntimeViewerFrameworkService` 没有残留；在注入进程的窗口里制造一次失败，看 sheet；测一个实例的常驻内存，记进本提案的「平台与最低版本」。
   - 文档按改动地图步骤 8 的行更新。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 「为什么实例的 payload 不列框架」「为什么诊断随回复而不是新命令」「修复为什么靠先加载依赖」都是下次维护会踩、代码本身看不出来的决策，倾向写一篇实现说明 `Documentations/FrameworkInstances.md`，落地时定。
- **有没有引入新术语** —— 「独立实例（framework instance）」「加载诊断」，落地时登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-19 | Created as Draft | Load Frameworks 把第三方框架装进 My Mac 的 service，卸不掉、会牵连 My Mac，失败时只有 dyld 原文，用户看不出依赖为什么找不到、也无从补救；改成每次在独立实例里加载，并在失败的进程里诊断。完整档，三轮澄清提问与诊断页原型之后创建。 |
| 2026-11-19 | 前置修复已落地 | dyld 原文跨 XPC 丢失（`DyldOpenError` 没有遵循 `LocalizedError`）先单独修好并推上 `next`（558b6abf），回归测试 `DyldLoadFailureMessageTests`。 |
| 2026-11-19 | 澄清提问定下的方向 | 用户定：每次 Load Frameworks 都在独立的 XPC service 实例里加载、新窗口挂在它上面、关窗即实例退出；一次选的框架共用一个实例，之后在该窗口加载也进同一实例；My Mac 上不保留直接加载的入口；失败时窗口照常打开、诊断显示在内容区、重试成功原地变成正常窗口；不进 Open Recent、重启不恢复（重新加载会再跑构造函数）；诊断在失败的进程里模拟 dyld 的查找并附原文；修复手段放进本提案（缺的依赖在宿主 App 的 Frameworks 目录里就提议先按绝对路径加载再重试，否则让用户指定宿主 App 或搜索路径）；诊断所有引擎都提供、修复只在独立实例里提供；侧栏只列这次加载的框架和它们不在 shared cache 里的依赖。 |
| 2026-11-19 | 诊断页原型通过 | 静态 HTML 原型回答了诊断页的内容与排布（结论、横幅与三个按钮、依赖链、rpath 查找表与解释、dyld 的尝试列表、可折叠原文、拷贝与 Show in Finder、重试成功后的状态），用户看过认可。原型在 `/tmp`、不进仓库，网页版的界面草图照它重画。 |
| 2026-11-19 | 写提案时定下的实现方向 | 诊断随失败的加载在回复里带回（`LoadImageCommand` 加可选字段），不加发给所有引擎的新命令——经 Mach service 的旧版 payload 会因未知命令断开（PR121.73）；重新诊断的命令只发给框架实例。实例的 launch payload 不列框架，崩溃后的重连得到空实例，避免崩溃循环。没有窗口就立即结束实例，不像文件引擎那样留宽限期。其余自定的假设列在「设计中自定的假设」。 |
| 2026-11-19 | Accepted | 用户批准，开始实现。 |

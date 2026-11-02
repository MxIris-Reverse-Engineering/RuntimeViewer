# Draft - 离线模式：打开磁盘上的 Mach-O 文件、bundle 与 dyld shared cache

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-02
- **最后更新**: 2026-11-03
- **所属愿景**: 无
- **关联提案**: [0037](0037-local-runtime-xpc-service.md)（本地运行时 XPC service：离线 service 沿用它的 service host、凭证与重连做法）、[0051](0051-catalyst-xpc-service.md)（第二个内嵌 service 的先例）、[0003](0003-generic-type-specialization.md)（泛型特化的 UI 流程；离线走 MachOSwiftSection 0069 的静态特化）、[0033](0033-runtime-bookmark-scope.md)（新来源要有自己的书签身份）、[0054](0054-always-index-per-engine.md) / [0055](0055-engine-scoped-background-work.md) / [0058](0058-runtime-engine-session.md)（每个引擎一份后台工作；「最后一个文档离开」是停放离线进程的钩子）、[0056](0056-cross-references.md)（交叉引用只能在进程内做，离线不支持）、[0061](0061-derived-data.md)（派生数据：离线 cache 的语料要按该 cache 的身份存，并躲开本机的清理规则）
- **实现分支 / PR**: `feature/offline-mode`（worktree `.worktrees/RuntimeViewer-OfflineMode`），从 `next` 切出
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

RuntimeViewer 现在只能看「某个进程里已经加载的镜像」：每个引擎读的都是 dyld 映射进进程的 `MachOImage`。本提案加一种新的引擎来源——**磁盘上的文件**：单个 Mach-O（含胖二进制）、`.app` / `.framework` 等 bundle、dyld shared cache（含 `.01`… 子缓存）。用户经 File › Open…、Open Recent 或拖到 Dock 图标打开，App 为它开一个新窗口；它在工具栏引擎菜单里单列一组「Offline Files」，任何窗口都能切过去、切走。每个打开的文件由**自己的一个进程**解析（内嵌 XPC service 的多实例），崩溃只影响它自己；所有窗口都离开后进程退出、释放内存，菜单条目保留，再选中时重新拉起。单个 Mach-O 或 bundle 的系统依赖由一个 dyld cache 提供：macOS 文件自动用本机的 cache，iOS 等其它平台的文件从 Settings 里登记的 cache 中按平台挑版本最接近的一个，也能在引擎菜单里改。离线可用的有 ObjC / Swift 接口、侧栏、关系、泛型特化、Find 与导出；交叉引用、注入、载入框架不可用。技术上，Core 里写死 `MachOImage` 的那一簇类型（两个 section、两个 indexer 包装、两个工厂、两个关系解析器）改成对 Mach-O 读取方式泛型，进程内的镜像与磁盘上的文件各给一份「镜像目录」实现，引擎经一个非泛型协议持有它们。

## 动机

**磁盘上的二进制看不了。** 用户手里常有不在本机运行、也不该在本机运行的二进制：从 IPSW 解出来的 iOS / visionOS dyld cache（本机 `/Volumes/DyldSharedCaches/<平台>/<版本>/` 下按版本存了一批）、别的 macOS 版本的 cache、第三方 App 的发布版、不能或不想注入的进程的主程序。今天要看它们只有两条路：注入一个正在运行的进程，或者改用命令行的 `swift-section` / `objc-section`——后者没有侧栏、关系、跳转、Find 和泛型特化。

**限制来自 RuntimeViewer 自己，不是上游。** 引擎拿镜像的唯一入口是 `DyldUtilities.machOImage(forPath:)`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift:179-185`）：它只在 dyld 已加载的镜像里按路径找，找不到就按文件名猜一个已加载的同名镜像。两个 section 都在 `init` 里调它（`Core/RuntimeObjCSection.swift:77-92`、`Core/RuntimeSwiftSection.swift:232-252`），找不到就抛 `invalidMachOImage`；`loadImage(at:)` 的本地实现先 `dlopen`（`RuntimeEngine.swift:1102-1105`、`DyldUtilities.swift:221-237`）。而 MachOObjCSection 与 MachOSwiftSection 的索引、渲染、打印、特化全部对 `MachOFile` 通用（见前期调研 §2）——上游 MachOSwiftSection 甚至专门为「RuntimeViewer 将来的离线模式」做了离线泛型特化（它的提案 0069，状态 Implemented），至今没有消费方。

## 前期调研

### 1. 现状：引擎只认进程里已加载的镜像

- **镜像清单来自 dyld**：`imageList` 是 `_dyld_get_image_name` 的结果去掉注入载荷（`DyldUtilities.swift:52-100`），侧栏的两个根节点「Dyld Shared Cache」「Others」由 `DyldCacheLoaded.current.imageInfos` 和这份清单拼出（`DyldUtilities.swift:243-305`）；`RuntimeEngine.observeRuntime()` / `reloadLocalData` 直接读它们（`RuntimeEngine.swift:658-710`）。`RuntimeImageNode.rootNode(for:name:)` 只是按 `/` 切路径建树（`Common/RuntimeImageNode.swift:46`），对任何路径列表都适用。
- **写死 `MachOImage` 的类型集中在一簇**：`RuntimeObjCSection` / `RuntimeSwiftSection`（各持一个 `machO: MachOImage`，打印器是 `SwiftDeclarationPrinter<MachOImage>`）、`RuntimeObjCInterfaceIndexer` / `RuntimeSwiftInterfaceIndexer`（包着 `ObjCInterfaceIndexer<MachOImage>`、`SwiftDeclarationIndexer<MachOImage>`、`IndexerConformanceProvider<MachOImage>`）、两个工厂（各有一个以 `MachOImage.current()` 占位的聚合 indexer，`RuntimeObjCSection.swift:488-491`、`RuntimeSwiftSection.swift:1899`）。引擎与两个关系解析器只经工厂和包装类型拿数据：`RuntimeEngine.swift` 有 44 处、`RuntimeTypeRelationshipsResolver.swift` 45 处、`RuntimeRelationshipsResolver.swift` 16 处、`+Search` / `+GenericSpecialization` / `+BackgroundIndexing` 共 16 处引用工厂或 section；工厂和包装类型以外，只有 `RuntimeEngine.swift:804,813`（读 `entry.machO.imagePath`）和 `RuntimeTypeRelationshipsResolver.swift:299,515,552,665`（推断出 `ObjCInterfaceIndexer<MachOImage>.ObjCClassGroup`）碰到上游的泛型类型。
- **镜像路径的键**：`MachOFile.imagePath` 返回的是 install name，不是磁盘路径（MachOKit `MachOFile.swift:175`）。离线时镜像的键必须由镜像目录给出，不能从 `machO.imagePath` 推。
- **派生数据只认本机**：系统身份取自本进程映射的 cache 与 `kern.osversion`（`DerivedDataStorage/RuntimeDerivedDataSystemIdentity.swift:29-50`，`Platform` 只有 `macOS` / `macCatalyst`）；本机 service 启动时的清理会删掉「build 与本机不同」的每个系统目录（`DerivedDataStorage/RuntimeDerivedDataMaintenance.swift` 的 `cleanUp`）。

### 2. 上游已经具备的能力（钉在 `next` 的同一修订）

- **索引与渲染**：`ObjCInterfaceIndexer<MachO: ObjCMetadataSource>` / `ObjCInterfaceBuilder<MachO>`，`MachOFile` 与 `MachOImage` 都遵循 `ObjCMetadataSource`（MachOObjCSection `Sources/ObjCMetadataSource/MachOFile+ObjCMetadataSource.swift:7`）；`SwiftDeclarationIndexer<MachO: MachOSwiftSectionRepresentableWithCache>`、`SwiftDeclarationPrinter<MachO: MachOFieldLayoutRenderable>`、`GenericSpecializer<MachO>`、`IndexerConformanceProvider<MachO>`，两种读取方式都遵循（MachOSwiftSection `Sources/ABI/MachOSwiftSection/Protocols/MachOSwiftSectionRepresentableWithCache.swift:10-11`）。MachOObjCSection 自己的 `objc-section` 命令行就是 `ObjCInterfaceBuilder<MachOFile>`。
- **字段布局**：`MachOImage` 从进程里实例化好的 metadata 读（`RuntimeFieldLayoutBackend.swift:11-12`），`MachOFile` 用静态布局引擎算（`StaticFieldLayoutBackend.swift:10-12`）。静态布局要知道依赖镜像在哪：`SwiftDeclarationPrintConfiguration.staticLayoutDependencyResolution`（`SwiftDeclarationPrintConfiguration.swift:222`），取值 `.singleImage` 或 `.dependencyClosure(searchPaths:)`，默认只搜本机 cache（`StaticFieldLayoutProvider.swift:12-28`）。
- **依赖闭包**：Swift indexer 对 `MachOFile` 按 `SwiftDeclarationIndexConfiguration.dependencySearchPaths`（默认 `[.systemDyldSharedCache]`，`SwiftDeclarationIndexConfiguration.swift:21`）建传递依赖闭包，用来认出别的镜像里的 property wrapper 与 ObjC 祖先类（`SwiftDeclarationIndexer.swift:400-436`）。`DependencySearchPath` 有 `.machOFile(path:)`、`.dyldSharedCache(path:)`、`.systemDyldSharedCache`、`.systemRoot(path:)`；`FileDependencyLocator` 不展开 `@rpath`，bundle 里的框架要作为 `.machOFile` 显式给出（`Sources/MachO/MachODependencies/FileDependencyLocator.swift:145-163`）。
- **离线泛型特化**（MachOSwiftSection 提案 0069）：`GenericSpecializer where MachO == MachOFile` 提供 `specialize(_:with:) -> StaticSpecializationResult` 与 `staticPreflight(selection:for:) -> SpecializationValidation`（`GenericSpecializer+StaticSpecialization.swift:24-63`，`@_spi(Support)`），`TypeDefinition.specialize(with: StaticSpecializationResult, derivingNestedSpecializationsWith:in: MachOFile)`（`TypeDefinition+Specialization.swift:485-530`）。`SpecializationValidation` 的错误与警告枚举不变，RuntimeViewer 的翻译函数和线上类型都不用改；离线证据不全时「无法证明的遵循」降为警告。
- **读文件的先例**：MachOSwiftSection 的 `MachOSource.load()`（`Sources/Commands/SwiftSectionKit/Inputs/MachOSource.swift:50-90`）——薄文件直接用，胖文件按架构挑切片，cache 一律经 `FullDyldCache(url:)`（同时映射子缓存，否则子缓存里的段读越界），再按名字或路径取 `MachOFile`。

### 3. 只能在进程内做的事

| 位置 | 做什么 | 离线怎么办 |
|------|--------|-----------|
| `RuntimeObjCSectionFactory.section(for: RuntimeObjCName)` + `MachOImage.image(forClassName:)`（`RuntimeObjCSection.swift:522-543,611-627`） | 点到别的镜像里的 ObjC 类 / 协议时，用 `NSClassFromString` 找定义它的镜像（`RuntimeEngine.swift:768-776`） | 先在已解析镜像里找（聚合 indexer 已有 `classGroupAcrossImages`），找不到再查「名字 → 镜像」表，见详细设计 §3 |
| `RuntimeSwiftSection.classHierarchy(for:)` 用 `ClassHierarchyDumper(machO:)`（`RuntimeSwiftSection.swift:656`） | 调 metadata accessor 走 Swift 类的父类链 | 用 indexer 的父类 mangled 名静态走链 |
| `RuntimeSwiftSection.runtimeName(of:in:)`（`RuntimeSwiftSection.swift:1035-1045`） | 已实现的类数据指针指向 `class_rw_t`，要绕回 `class_ro_t` | 文件里只有 `class_ro_t`，直接读 |
| 泛型特化（`RuntimeSwiftSection.swift:1059-1140` 一带） | `specialize(_:with:metadataRequest:)`、`runtimePreflight`，结果带 metadata | 走 §2 的静态特化，结果不带 metadata |
| `DyldUtilities.loadImage(at:)` | `dlopen` 后清掉字段布局的进程内缓存 | 不 `dlopen`，只建 section |
| 后台索引的依赖解析（`RuntimeEngine+BackgroundIndexing.swift:62-187`、`Utils/DylibPathResolver.swift`） | 经 `machOImage(forPath:)` 读 rpath 与依赖，未加载的先 `dlopen` | 由镜像目录读 `MachOFile` 的加载命令；`@rpath` 等照旧在 bundle 目录里展开，绝对 install name 去配对的 cache 里找 |
| 交叉引用（`RuntimeViewerCrossReferences`，MachOSwiftSection 的 `CrossReferenceAnalyzer.init?()`） | 只认本进程的 `MachOImage` 与已映射的 cache（`CrossReferenceAnalyzer.swift:85-120`） | **不支持**（非目标） |

### 4. 进程与传输

- **「My Mac」已在进程外**：App 的 `RuntimeEngine.local` 带着 `.xpcService(.bundleIdentifier(…))` 凭证连内嵌的 `RuntimeViewerLocalRuntimeService`（`RuntimeEngine.swift:57-63,347-358`）；service 侧是 `RuntimeLocalRuntimeServiceHost`：先建好进程内引擎、登记命令表，再激活监听（`LocalRuntimeService/RuntimeLocalRuntimeServiceHost.swift`）。监听方只有一个 peer 槽位，后来的连接顶替先来的。
- **普通 XPC service 默认每个 App 只有一个进程**。要「每个文件一个进程」，Apple 自己的做法是 WebKit：service 的 `Info.plist` 在 `XPCService` 里设 `_MultipleInstances = true`（另有 `ServiceType = Application`、`JoinExistingSession = true`、`_ProcessType = App`，`/Volumes/AppleOSS/WebKit/Source/WebKit/WebProcess/EntryPoint/Cocoa/XPCService/WebContentService/Info-OSX.plist:43-52`），App 每次启动一个进程前 `uuid_generate`、`xpc_connection_set_oneshot_instance(connection, uuid)`，再用 `xpc_connection_set_bootstrap` 把启动参数交给新进程（`/Volumes/AppleOSS/distribution-macOS/WebKit/Source/WebKit/UIProcess/Launcher/cocoa/ProcessLauncherCocoa.mm:271-282`），service 侧用 `xpc_copy_bootstrap()` 读。本机 `libxpc` 导出 `_xpc_connection_set_instance`、`_xpc_connection_set_oneshot_instance`、`_xpc_connection_set_bootstrap`、`_xpc_copy_bootstrap`（`dyld_info -exports` 实测）。这些都是私有接口。
- **SwiftyXPC 没有接口可用**：项目用的是用户自己的 fork（`MxIris-macOS-Library-Forks/SwiftyXPC` 0.5.105，本地 `/Volumes/Repositories/Private/Fork/Library/SwiftyXPC`）。它创建连接用 `xpc_connection_create(bundleID, nil)`，接收现成 `xpc_connection_t` 的构造器是 `internal`（`Sources/SwiftyXPC/XPCConnection.swift:99-125`），在创建与 `activate()` 之间没有钩子。这个 fork 已经用 `@_silgen_name` 手声明过一个 libxpc 私有函数（`xpc_connection_get_audit_token`），照样补上实例与 bootstrap 是小改动。
- **复用本地运行时 service 的二进制不行**：它启动即建 `.local` 引擎；更要紧的是派生数据的「生产者」身份由镜像的 `LC_UUID` 算出（`RuntimeDerivedDataProducerIdentity.swift:15-74`），同一个二进制给本机 cache 打出的 `MachOImage` 语料与 `MachOFile` 语料会落进同一目录、互相删掉对方（`RuntimeDerivedDataStore.swift` 的 `removeOtherVariants` 每种数据每个镜像只留一个变体）。单独的 service target 自带不同的生产者身份。

### 5. App 侧现状

- **引擎菜单**按 `hostInfo.hostID` 分组（`RuntimeEngineManager.swift:1828-1860`），默认的 `hostID` 是本机，离线引擎要有自己的 `hostID` 才会单列一组；去重逻辑写死了三组本地引擎（`:1880-1912`）。菜单项选中后按 `engineID` 找引擎、`router.trigger(.main(engine))`（`MainViewModel.swift:368-375`）。
- **文档**：`Document` 不读写文件（`read(from:ofType:)` 抛 `unimpErr`），`DocumentState()` 默认 `.local`，`MainCoordinator.init` 写死 `initialRoute: .main(.local)`（`Main/MainCoordinator.swift:36`）。没有 `NSDocumentController` 子类。File › Open…（⌘O → `openDocument:`）来自 UIFoundation 的 `MainMenu.file`，Open Recent 由 `NSDocumentController` 自己插入；`Info.plist` 只声明了一个 `com.JH.RuntimeViewer.Document` 类型，所以今天 ⌘O 只能选 `.runtimedocument`，选了也打不开。
- **「最后一个文档离开」**：`RuntimeEngineBackgroundWorkRegistry.leave` 在成员清空时关闭该引擎的后台工作（`RuntimeViewerApplication/Engine/RuntimeEngineBackgroundWork.swift:105-143`），目前没有对外的通知。
- **功能开关**：Attach to Process 经 `injectionTargetsRunOnThisMachine`（`RuntimeEngine+Injection.swift:72-80`，穷举 switch）；Load Frameworks… 没有任何开关（`MainViewModel.swift:244-258`）；交叉引用与 Find 语料在对端回答「未知命令」时把自己标为「此引擎不支持」，Report 显示对应行（`CrossReferencePreparationCoordinator.swift:404-408`、`FindCorpusCoordinator.swift:781-788`、`ReportTreeBuilder.swift:166`）。
- **新 `RuntimeSource` case 的波及面**：`RuntimeSource` 自身六处、`RuntimeCommunicator.swift:75`、`RuntimeEngine+ImagePathCanonicalization.swift:88`、`RuntimeEngine+Injection.swift:73`、`RuntimeBookmarkScope.swift:356`（连同它的 `Identity` / `Kind` 与 `Settings+IndexingEngineReference.swift:49`）、CLI 的 `SourceCatalog.swift:74`、App 的 `Utils/RuntimeSource+.swift:13`，约十二处穷举 `switch`。`isRemote` 没有正式代码调用方。新 case 必须先**不可镜像**（`RuntimeSource.swift:262-269`），否则旧版本对端解码整张引擎列表失败。

### 6. 待验证（推测，落地第 0 步先证实）

1. **一次性实例 + bootstrap 在我们的 service 上可用**：`_MultipleInstances` 的内嵌 service 每次 `set_oneshot_instance` 都起一个新进程，`xpc_copy_bootstrap()` 在 service 的 `main` 里拿得到 App 给的数据；Developer ID 签名、hardened runtime、非沙盒下照常工作。
2. **进程在 App 取消连接后退出**：service 侧在唯一的 peer 断开时自行 `exit(0)` 即可；还要确认 launchd 不会因为一次性实例退出而记为崩溃、反复拉起。
3. **崩溃后的重连**：一次性实例退出后 launchd 不会重拉它，所以 client 连接的重连要换成「新 UUID + 同一份 bootstrap」重建连接（推测，需实测 `XPC_ERROR_CONNECTION_INTERRUPTED` 与 `INVALID` 在这里各在什么时候出现）。
4. **「名字 → 镜像」表的代价**：只读每个镜像的 ObjC class / protocol 列表的名字建表，一份 iOS cache 要多久、多大（§3 的方案取决于它）。

## 提议方案

1. **新来源**：`RuntimeSource.file(name:url:)`——身份只有文件的规范化 URL（`name` 只用于显示，和其它 case 一样不参与相等）。配对哪个 cache、胖文件取哪个切片都是**配置**，不进身份：换配对 cache 不会让书签、侧栏状态、Always Index 列表另起一份。
2. **描述打开的东西**：Core 新增值类型 `RuntimeOfflineFile`——URL、内容种类（Mach-O 带切片 / bundle / dyld cache）、依赖 cache（本机的、某个 cache 文件、或没有）。它是 App → service 的启动参数、service 里引擎的构造参数、管理器里停放条目的配置。
3. **每个文件一个进程**：新的内嵌 XPC service `RuntimeViewerOfflineService.xpc`，`_MultipleInstances`。App 侧引擎带一个 `.xpcService(.dedicatedInstance(bundleIdentifier:launchPayload:))` 凭证连接，连接层给每次启动生成实例 UUID、把 `RuntimeOfflineFile` 编码后作为 bootstrap；service 读出它、建进程内的文件引擎、复用 `RuntimeLocalRuntimeServiceHost` 提供服务，peer 断开即退出。XPC 的细节只在连接层与 service 入口两处（与 0037 定下的「XPC 逻辑不进 Engine、改动要聚合」一致）。
4. **Core 泛型化**：section、indexer 包装、工厂、关系解析器对 Mach-O 读取方式泛型；两种读取方式的差异（特化、Swift 父类链、ObjC 类名、`dlopen`）集中在一个内部协议的两份实现里（读取方式策略 `RuntimeImageReading`）；引擎经几个非泛型协议持有它们，本地臂的逻辑基本不挪窝。镜像从哪来由「镜像目录」决定：`RuntimeProcessImageCatalog`（就是今天的 dyld 逻辑）与 `RuntimeFileImageCatalog`（文件 / bundle / cache + 配对 cache）。
5. **打开**：App 新增 `NSDocumentController` 子类拦截打开，`Info.plist` 声明 Mach-O 可执行文件、动态库与 bundle 为 Viewer 类型。选中的文件先判种类（读文件头 / bundle 结构），定配对 cache，交给管理器取得（或新建、或唤醒）对应引擎，再开一个直接落在该引擎上的新窗口，并记入 Open Recent。
6. **引擎菜单**：离线引擎用专属的 `hostInfo`（`hostID` 固定，`hostName` 为「Offline Files」），单列一组；组末两项「Open File…」与「Dependency Cache ▸」（后者作用于当前窗口所在的离线引擎）。图标取文件自身的 Finder 图标（`.app` 就是 App 图标）。
7. **停放与唤醒**：后台工作注册表在「第一个文档加入」「最后一个文档离开」时发事件；App 侧的 `OfflineFileController` 收到「离开」后等 30 秒，仍无文档就让管理器停放该引擎（引擎 `stop()`，连接取消，service 退出），条目仍在菜单里；用户再选它、或经 Open / Open Recent 再开它，管理器先唤醒（同一个引擎对象再 `connect`，新实例、同一份 `RuntimeOfflineFile`）再切换。
8. **配对 cache**：macOS 与 Mac Catalyst 文件配本机 cache（`.systemDyldSharedCache`）；其它平台从 Settings › Offline 登记的 cache 里挑平台相同、版本最接近文件 SDK 版本的一个，没有就只看文件本身；「Dependency Cache ▸」可改，改了重启该引擎的进程。打开 dyld cache 本身不需要配对。bundle 内的每个 Mach-O 自动作为 `.machOFile` 依赖路径。
9. **侧栏**：打开的文件一组（bundle 时按包内目录展开）、配对的 cache 一组；打开 cache 本身时只有 cache 一组。离线引擎的 `imageList` 是目录里的全部镜像，全部视为「已加载」，点开即解析。
10. **不可用的功能**：Attach to Process 对离线引擎回答不支持；Load Frameworks… 对离线引擎禁用；离线 service 不链接 `RuntimeViewerCrossReferences` 与 `RuntimeViewerInjection`，交叉引用走现成的「此引擎不支持」路径。CLI 的 `sources` 不列离线引擎；MCP 按窗口工作，窗口切到离线引擎就能用。
11. **派生数据**：离线进程按它读的那份 cache（打开的 cache，或配对的 cache）的身份存 Find 语料；单独的 Mach-O 与 bundle 里的文件不存。离线 cache 的目录与本机身份的目录分开，本机 service 的清理不碰它们；Settings › Indexing 的「删除派生数据」照旧全删。

### 未询问自定的假设

写方案时自行定下的几条，审阅时可改：

- 停放前等 30 秒，免得来回切窗口时反复拉起进程、重新解析。
- 拖到 Dock 图标只接 Mach-O 可执行文件、动态库与 bundle；dyld cache 没有扩展名、只能声明成 `public.data`，那会让 App 出现在所有未知文件的「打开方式」里，所以 cache 只经 File › Open… 与 Open Recent 打开。
- 打开的文件不跨 App 重启恢复（窗口本来就不恢复）；停放的条目留到 App 退出，第一版没有「从菜单移除」。
- File › Open… 的面板不进入包内容：选 `.app` 就是打开整个 bundle；想单看包里某个二进制，可用 ⌘⇧G 输入路径或直接拖文件。
- 胖文件自动取本机优先的切片（arm64e、arm64、x86_64 依次）；iOS 等文件只看 arm64e / arm64。
- App 进程只读文件头与 `LC_BUILD_VERSION` 判种类和平台（沿用已经为畸形胖文件头加固过的 `InjectionTargetPlatform.platform(ofMachOFileAt:)` 的读法），登记 cache 时只读 cache 头；其余解析都在离线进程里。

### 非目标

- **交叉引用**：上游分析器只能读本进程（前期调研 §3）；要支持得先有 MachOSwiftSection 一侧的提案，把分析器改成能读文件。
- **CLI**：`runtime-viewer-cli` 不列、不读离线文件，agent 插件的 skill 不动。以后要做时，CLI 指定文件与列出 App 已打开的离线文件分两件事考虑。
- **iOS 版 App**（`RuntimeViewerUsingUIKit`）与越狱版：不做。
- **镜像给其它 Mac**：离线引擎不可镜像（新 case 的线协议规则，也没有意义）。
- **监视文件变化**：磁盘上的文件被重新编译不自动刷新；要刷新就让引擎停放后再打开。
- **手选胖文件切片、在面板里浏览包内容**：第一版不做（见上面的假设）。
- **AOT cache（Rosetta）**、kernel cache、`.ipa` 解包：不做。

## 详细设计

签名是方案级的形状，实现时名字可微调，调整记进决策日志。

### 1. 来源与描述

```swift
// RuntimeViewerCommunication/RuntimeSource.swift
public enum RuntimeSource: Sendable, CustomStringConvertible, Codable {
    // … existing cases …

    /// A Mach-O file, a bundle or a dyld shared cache on disk, read without running it.
    ///
    /// The identity is `url` alone, standardized when the file is opened; `name` is what
    /// menus show. Where its dependencies come from and which slice of a fat file is read
    /// are configuration, not identity — see `RuntimeOfflineFile`.
    case file(name: String, url: URL)
}
```

- `remoteRole` 为 `nil`（不是远端传输）；`isMirrorableToPeers` 为 `false`；`identifier` 为 `"file.<url.path>"`；相等与哈希只看 `url`。
- `RuntimeBookmarkScope` 新增 `Identity` / `Kind` 的 `file`，余下部分是规范化路径；Always Index 的 `EngineReference.key` 随之可用。
- `canonicalImagePath`（`RuntimeEngine+ImagePathCanonicalization.swift:88`）对 `.file` 不加 `DYLD_ROOT_PATH` 前缀。

```swift
// RuntimeViewerCore/Offline/RuntimeOfflineFile.swift
public struct RuntimeOfflineFile: Sendable, Hashable, Codable {
    public enum Content: Sendable, Hashable, Codable {
        /// A thin Mach-O file, or one slice of a fat one.
        case machO(slice: Slice?)
        /// A bundle: its main executable and every Mach-O file inside it.
        case bundle
        /// The main file of a dyld shared cache; its subcaches lie next to it.
        case dyldSharedCache
    }

    /// One slice of a fat file, by CPU type and subtype.
    public struct Slice: Sendable, Hashable, Codable {
        public let cpuType: Int32
        public let cpuSubtype: Int32
    }

    /// Where the images a Mach-O file or a bundle links come from, when they are not inside it.
    public enum DependencyCache: Sendable, Hashable, Codable {
        /// This Mac's dyld shared cache.
        case systemDyldSharedCache
        /// A dyld shared cache read from disk, by the URL of its main file.
        case dyldSharedCache(URL)
    }

    public let url: URL
    public let content: Content
    /// `nil` reads the file alone. Ignored for `.dyldSharedCache`, which is its own.
    public var dependencyCache: DependencyCache?

    /// Inspects what is at `url` — a Mach-O magic, a fat header, a bundle, a dyld cache
    /// magic — reading no more than its header. Throws `RuntimeOfflineFileError`.
    public init(contentsOf url: URL) throws

    public var displayName: String
    public var source: RuntimeSource { .file(name: displayName, url: url) }
}
```

`displayName`：bundle 用 bundle 名（`Foo.app`），Mach-O 用文件名，cache 用「平台 版本 (架构)」，如「iOS 27.0 dyld cache (arm64e)」。

### 2. Core：按读取方式泛型化

```swift
// RuntimeViewerCore/Core/RuntimeImageReading.swift (internal)
/// A way an engine reads an image. Everything that differs between reading what dyld
/// loaded and reading a file is a requirement here, so the generic code never asks which
/// one it holds.
protocol RuntimeImageReading: Sendable {
    associatedtype MachO: MachOFieldLayoutRenderable, ObjCMetadataSource, Sendable

    static func classHierarchy(of classDescriptor: ClassDescriptor, mangledTypeName: String,
                               in machO: MachO, across aggregate: RuntimeSwiftInterfaceIndexer<Self>) throws -> [String]
    static func objcRuntimeName(of objcClass: ObjCClass64, in machO: MachO) -> String?
    static func objcProtocolRecords(in machO: MachO) -> [(name: String, flags: UInt32)]
    static func makePrivateDiscriminatorSourceFileIndex(indexer: SwiftDeclarationIndexer<MachO>) -> PrivateDiscriminatorSourceFileIndex
    static func preflight(_ selection: SpecializationSelection, for request: SpecializationRequest,
                          using specializer: GenericSpecializer<MachO>) -> SpecializationValidation
    static func specialize(_ typeDefinition: TypeDefinition, request: SpecializationRequest,
                           selection: SpecializationSelection, typeArgumentNodes: [Node]?,
                           typeArgumentNodesByParameter: [String: Node],
                           using specializer: GenericSpecializer<MachO>, in machO: MachO) async throws -> TypeDefinition
}

enum RuntimeLoadedImageReading: RuntimeImageReading { typealias MachO = MachOImage /* today's runtime code */ }
enum RuntimeFileImageReading: RuntimeImageReading { typealias MachO = MachOFile /* static paths, MachOSwiftSection 0069 */ }
```

- **为什么是策略类型**：要求让 `MachOImage` / `MachOFile` 自己遵循做不到——`MachOFile` 是非 final 的 class，满足不了在别的泛型里写 `Self` 的要求（`GenericSpecializer<Self>` 之类）。两个枚举各带一个关联类型 `MachO`，差异全在它们的静态方法里。
- **变成泛型的类型**：`RuntimeObjCSection<Reading>`、`RuntimeSwiftSection<Reading>`、`RuntimeObjCInterfaceIndexer<Reading>`、`RuntimeSwiftInterfaceIndexer<Reading>`、两个工厂、`RuntimeRelationshipsResolver<Reading>`、`RuntimeTypeRelationshipsResolver<Reading>`，每个类型体内 `typealias MachO = Reading.MachO`，原有代码几乎不用改。section 不再自己找镜像，`init(imagePath:machO:factory:progressContinuation:)` 收工厂从目录取来的镜像。
- **每个工厂一份索引配置**：`RuntimeSwiftSection.indexConfiguration(dependencySearchPaths:)` 按目录给出的依赖搜索路径设 `SwiftDeclarationIndexConfiguration.dependencySearchPaths`；打印器的 `staticLayoutDependencyResolution` 也取 `.dependencyClosure(searchPaths:)`。进程内的镜像两者都用不上，路径与上游默认相同。
- **聚合 indexer 的占位镜像**：进程内照旧 `MachOImage.current()`；文件引擎用目录里第一个镜像。`SwiftDeclarationIndexer` 的 `deinit` 只在某个镜像的最后一个活着的 indexer 走时才清共享缓存，和活着的 section 共用同一个镜像不会误清。
- **跨镜像表记 section 的键**：Swift 工厂「mangled 名 → 定义它的镜像」两张表记下注册它的 section 的键，不再拿镜像自己的 `imagePath`（文件的是 install name）；引擎经 `imagePath(definingTypeWithCandidateID:)` / `imagePath(definingProtocolWithCandidateID:)` 取。
- **引擎看到的是非泛型协议**：`RuntimeObjCSectioning` / `RuntimeSwiftSectioning` 列出引擎与语料构建在 section 上调用的方法；`RuntimeObjCSectionProviding` / `RuntimeSwiftSectionProviding` 用关联类型声明自己的 section，经 `any` 调用时自动擦除成 section 协议；另有 `RuntimeRelationshipsResolving`、`RuntimeTypeRelationshipsResolving`。`RuntimeEngine` 的四个属性保留原名，类型换成这几个协议；`RuntimeImageIndex` 按同一种读取方式把目录、两个工厂、两个解析器成套建出来，交给引擎的指定构造器。

### 3. Core：镜像目录

```swift
// RuntimeViewerCore/Catalog/RuntimeImageCatalog.swift (internal)
protocol RuntimeImageCatalog<Reading>: Sendable {
    associatedtype Reading: RuntimeImageReading
    typealias MachO = Reading.MachO

    func imagePaths() -> [String]
    func rootNodes() -> [RuntimeImageNode]
    func canonicalImagePath(_ imagePath: String) -> String
    func machO(forImagePath imagePath: String) -> MachO?
    /// `dlopen` in a process, nothing for a file.
    func prepareImage(at imagePath: String) throws
    func image(definingObjCType name: RuntimeObjCName) async -> (imagePath: String, machO: MachO)?
    func mainExecutablePath() -> String
    func isSharedCacheImage(_ path: String) -> Bool
    var dependencySearchPaths: [DependencySearchPath] { get }
}
// canOpenImage(at:), rpaths(ofImageAt:) and dependencyEntries(ofImageAt:ancestorRpaths:mainExecutablePath:)
// are an extension: background indexing's old dependency rules, for either way of reading.
```

- **`RuntimeProcessImageCatalog`**：今天 `DyldUtilities` 的那些静态函数原样搬进来；按名字找 ObjC 类型仍是 `NSClassFromString`。
- **`RuntimeFileImageCatalog`**，按 `RuntimeOfflineFile.Content`，构造时打开全部镜像：
  - **Mach-O**：`File.loadFromFile(url:)`，胖文件取 `Slice` 指定的切片；镜像键是磁盘路径。
  - **bundle**：遍历包内普通文件（跳过符号链接，框架的 `Versions/Current` 否则会重复），按魔数收下所有 Mach-O，主程序取 `Bundle(url:).executableURL` 排第一。包内每个文件都进 `dependencySearchPaths`（`.machOFile`），`@rpath` / `@loader_path` / `@executable_path` 由现有的 `DylibPathResolver` 在磁盘上展开。
  - **dyld cache**：`FullDyldCache(url:)` 的 `machOFiles()` 遍历一次，镜像键是 install name；`dependencySearchPaths` 只有它自己。
  - **配对 cache**：本机的用 `FullDyldCache.host`（读磁盘上的 cache 文件，不是进程里映射的那份），别的用 `FullDyldCache(url:)`；它的镜像是第二个根节点，也能被解析；`dependencySearchPaths` 末尾加上 `.systemDyldSharedCache` 或 `.dyldSharedCache(path:)`。`DylibPathResolver` 判断「不在磁盘上的路径是不是 cache 镜像」改问目录。
  - **按名字找 ObjC 类**：在各镜像的导出 trie 里查 `_OBJC_CLASS_$_<类名>`，先查文件自己的镜像、再查 cache，结果按类名记住。ObjC 协议没有导出符号，离线只在已解析的镜像里找得到。
- **引擎的本地臂**：`observeRuntime()` / `reloadLocalData` 的镜像清单与根节点、`_isImageLoaded`、`_loadImage`、后台索引的 `_canOpenImage` / `_rpaths` / `_dependencies` / `loadImageForBackgroundIndexing`、`mainExecutablePath`、Find 与关系查询里的路径规范化全部改问目录；`DyldUtilities` 只剩进程目录在用。

```swift
// RuntimeViewerCore/Offline/RuntimeEngine+Offline.swift
extension RuntimeEngine {
    /// An engine that reads `file` in this process — what the offline service runs. Its
    /// source is `file.source`; `connect()` without a credential starts it. Throws
    /// `RuntimeOfflineFileError` when the file or its paired cache cannot be opened.
    public init(reading file: RuntimeOfflineFile, engineID: String = UUID().uuidString) throws
}
```

### 4. 通信层：每个文件一个 service 实例

```swift
// RuntimeViewerCommunication/Connections/RuntimeXPCServiceConnection.swift
public enum RuntimeXPCServiceTarget: Sendable {
    case bundleIdentifier(String)
    /// A process of its own for this connection: launchd starts a new instance of the embedded
    /// service and hands it `launchPayload`, which the service reads with
    /// `RuntimeXPCServiceListenerConnection.launchPayload`. The service declares
    /// `_MultipleInstances`. Reattaching after the instance went away starts another instance
    /// with the same payload.
    case dedicatedInstance(bundleIdentifier: String, launchPayload: Data)
    case anonymousListener(RuntimeXPCServiceEndpoint)
}

extension RuntimeXPCServiceListenerConnection {
    /// The payload the app handed this instance when it started it; `nil` for a service
    /// started any other way.
    public static var launchPayload: Data? { get }
}
```

- client 连接为 `.dedicatedInstance` 每次建连生成 UUID，在 `activate()` 之前调 `set_oneshot_instance` 与 `set_bootstrap`（经 SwiftyXPC 新增的接口）。中断后的重连不再在同一条 XPC 连接上补 `hello`，而是用同一份 payload 新起一个实例；具体以第 0 步实测为准。
- **SwiftyXPC（用户的 fork）**：`XPCConnection.ConnectionType` 加一种「带实例的 service 连接」，带 UUID 与 bootstrap；`XPCListener` 加读取 bootstrap 的静态属性。发 0.5.106，RuntimeViewer 把下限抬到它。私有函数照 fork 里 `xpc_connection_get_audit_token` 的写法用 `@_silgen_name` 声明。
- 引擎对此一无所知：它只看到连接的 `.connecting` / `.connected` / `.disconnected`。

### 5. 离线 service target

- **`RuntimeViewerOfflineService`**（`RuntimeViewerUsingAppKit/RuntimeViewerOfflineService/`）：`main.swift`、`Info.plist`（`XPCService`：`ServiceType = Application`、`_MultipleInstances = true`；其余键照 WebKit 第 0 步验证后取舍）、entitlements（`disable-library-validation`，不开沙盒——要读任意路径的文件）。`Configurations/RuntimeViewerOfflineService/` 下 Shared 与三个配置的 xcconfig（`SKIP_INSTALL = YES`、hardened runtime、`MACOSX_DEPLOYMENT_TARGET = 15.0`、各配置的 bundle ID），`CodeSigning.xcconfig` 三个变量，App 的 `Info.plist` 加 `RuntimeViewerOfflineServiceBundleIdentifier`，App target 依赖它并在「Embed XPC Services」阶段嵌入。Tuist 描述（`RuntimeViewerUsingAppKit/Project.swift`）同一个 commit 加上，`./TuistScript.sh check` 通过。
- **`main.swift`**：读 `RuntimeXPCServiceListenerConnection.launchPayload`，解出 `RuntimeOfflineFile`；读不出就退出。若读的是 cache（打开的或配对的），按它的身份打开派生数据（§9）。建 `RuntimeEngine(reading:)`，交给 `RuntimeLocalRuntimeServiceHost`（它本来就是「把一个进程内引擎挂到 service 监听上」，文档注释改成不限于 `.local`），`start()` 后 `activate()`；监听方的 peer 断开即 `exit(0)`。
- **进程义务**：不链接 `RuntimeViewerInjection` 与 `RuntimeViewerCrossReferences`，所以没有两个 `install()`——这是根 `AGENTS.md`「linked it ⇒ call it」表格里的第一个有意不链接的进程，表格加一行说明为什么。
- **`RuntimeOfflineService`**（`RuntimeViewerCore/Offline/`，仿 `LocalRuntimeService`）：`Info.plist` 键名、从进程 bundle 读出 bundle ID、为某个 `RuntimeOfflineFile` 造凭证（编码 payload）。

### 6. 引擎管理（`RuntimeViewerEngineManagement`）

```swift
extension RuntimeEngineManager {
    /// The engine reading `file`: the one already listed for its URL — woken if it was
    /// suspended, restarted if `file` asks for another dependency cache — or a new one.
    public func runtimeEngine(reading file: RuntimeOfflineFile) async throws -> RuntimeEngine
    /// Lets the engine's process exit. The engine stays listed; `resumeOfflineEngine(_:)`
    /// or `runtimeEngine(reading:)` brings it back.
    public func suspendOfflineEngine(_ engine: RuntimeEngine)
    public func resumeOfflineEngine(_ engine: RuntimeEngine) async throws
    public func offlineFile(of engine: RuntimeEngine) -> RuntimeOfflineFile?
}
```

- 第五组 `@Published offlineRuntimeEngines`，进 `runtimeEngines`、去重的本地组判断、`terminateRuntimeEngine` 的移除；不进 `startSharingEngines` 的组合——离线引擎不可镜像，也不该为它起代理服务器。每个离线引擎记着它的 `RuntimeOfflineFile`。
- 离线引擎的 `hostInfo` 是固定的 `RuntimeHostInfo(hostID: "offline-files", hostName: "Offline Files")`，所以 `rebuildSections()` 自然把它们单列一组。
- **停放与唤醒用同一个引擎对象**：`suspend` 调 `engine.stop()`；`resume` 再 `connect(credential:)`，新实例、同一份 payload。`RuntimeEngine` 目前没有「停止后再连接」的调用方，补测试证明它可行（状态、处理器、镜像清单推送都重新来过）。
- 无头的 CLI host 没有离线 service，`runtimeEngine(reading:)` 抛错；CLI 本来也不调用它。
- **CLI 不暴露**：`RuntimeEngineManagerCatalog.snapshot()`（`SourceCatalog.swift:159-170`）把 `.file` 的引擎从 `sections` 里滤掉；离线组不在 `allEngines` 里，`--source engine:<id>` 也找不到它。`SourceKind(source:)` 改为可失败的 `init?(source:)`，`.file` 返回 `nil`，调用处跳过。

### 7. 应用层

- **`DocumentController`**（`NSDocumentController` 子类，`AppDelegate.main()` 里在任何文档之前实例化，使它成为 shared；注释写明为什么必须在那里）：重写 `beginOpenPanel` 一类入口配置面板（允许任意文件与包，不浏览包内容），重写 `openDocument(withContentsOf:display:completionHandler:)`：URL 交给 `OfflineFileController`，成功后 `noteNewRecentDocumentURL`，把新建的 `Document` 交还完成回调；不是离线文件的 URL 走原路。Dock 拖放与 Open Recent 都走这里。
- **`OfflineFileController`**（App target 的 `@MainActor` 控制器，`@Dependency(\.offlineFileController)`）：`RuntimeOfflineFile(contentsOf:)` 判种类；按 §8 定配对 cache；向管理器要引擎；`Document(runtimeEngine:)` 开窗口；订阅后台工作注册表的占用事件做停放（30 秒）；提供「Dependency Cache ▸」菜单的内容与动作。打不开的文件弹错误（「不是 Mach-O 文件、bundle 或 dyld shared cache」，带具体原因）。
- **`Info.plist`**：`CFBundleDocumentTypes` 加一项 Viewer、`LSHandlerRank = Alternate`，`LSItemContentTypes` 为 `public.unix-executable`、`com.apple.mach-o-dylib`、`com.apple.mach-o-binary`、`com.apple.bundle`、`com.apple.application-bundle`、`com.apple.framework`（具体 UTI 以实测 Finder 给出的为准）。
- **从指定引擎起步的文档**：`DocumentState(runtimeEngine:)`、`MainCoordinator(documentState:)` 的初始路由取文档的引擎，不再写死 `.local`；`Document()` 的默认仍是 `.local`。
- **引擎菜单**（`MainWindowController.swift:213-260`、`MainViewModel.swift:368-375`）：选中已停放的离线引擎时先 `resumeOfflineEngine` 再 `.main(engine)`；离线组末尾的「Open File…」「Dependency Cache ▸」两项。图标：`Utils/RuntimeSource+.swift` 的 `icon` 对 `.file` 返回 `NSWorkspace.shared.icon(forFile:)`。
- **后台工作注册表**（`RuntimeEngineBackgroundWork.swift:105-143`）：加一个发布者，在某个引擎的第一个成员加入、最后一个成员离开时各发一次。只有离线引擎的控制器订阅它。
- **功能开关**：`RuntimeEngine+Injection` 对 `.file` 直接回答不支持（`injectionTargetsRunOnThisMachine` 为 `false`，`injectionAvailability()` 不问对端）；Load Frameworks… 在离线引擎上禁用；交叉引用与「Keep Cross References Ready」靠对端没有这几条命令，落到现成的「此引擎不支持」，Report 显示该行。

### 8. 设置

- **`Settings.offline`**（新分支，`Settings.Offline`）：`dependencyCaches: [Settings.Offline.DependencyCache]`，每项存 cache 主文件的路径与登记时读出的平台、系统版本、架构、UUID（显示与自动挑选都不必再开 cache）。`accessPersistedValues()` 与 `SettingsPersistenceTests` 的覆盖表同批更新。
- **Settings › Offline 页**：一张表（路径、平台、版本、架构）加「+」「−」；「+」弹面板选 cache 主文件，读头失败就提示并不登记。
- **自动挑选**：文件的平台（`LC_BUILD_VERSION` 的 platform；Mac Catalyst 与 macOS 用本机 cache）相同的登记项里，取版本不低于文件 SDK 版本的最小者；都低于就取最高的；没有同平台的就不配对。模拟器文件只配模拟器的 cache。
- 「Dependency Cache ▸」列出本机 cache（macOS / Catalyst 文件）、同平台的登记项、「None」和「Manage in Settings…」，当前项打勾。

### 9. 派生数据（只给 dyld cache）

- **身份来自 cache 文件**：`RuntimeDerivedDataSystemIdentity` 加一个由 `FullDyldCache` 头构造的入口——平台、OS 版本、UUID。cache 头只有 `platform` / `osVersion` / `altPlatform` / `altOsVersion`，没有 build 号（MachOKit `Header/DyldCacheHeader/DyldCacheHeader.swift:40-61`），目录名改用 `Offline-<平台>-<版本>-<UUID>`，由 UUID 区分不同的 cache。`Platform` 补 iOS、iOS Simulator、tvOS、watchOS、visionOS 等。
- **哪些镜像存**：离线进程的「是不是 shared cache 镜像」由目录回答——它读的那份 cache 的镜像存，单独的文件与包里的文件不存。
- **清理**：本机 service 的 `cleanUp` 跳过 `Offline-` 开头的系统目录；离线目录只由「删除派生数据」清掉，或在第一版之后再加按最近使用时间的清理（先记为后续项）。App 侧的「派生数据占用」统计照旧把它们算进去。
- **不撞车**：离线 service 是另一个二进制，生产者身份不同，即使配对的是本机 cache，`MachOFile` 打出的语料也落在与本机 service 不同的目录。
- 动手前按根 `AGENTS.md` 先读 `Documentations/DerivedData.md`。

### 10. 测试

- **Core**（`RuntimeViewerCore/Tests`，不碰真实派生数据）：
  - 第一步（只泛型化进程内这条路）以全量 Core 测试不变红为准。
  - 用测试 bundle 自己在磁盘上的二进制建文件引擎，与进程内引擎对照：对象清单一致，ObjC 与 Swift 接口在去掉布局注释后一致。
  - 用本机 cache 文件（`FullDyldCache.host`）建 cache 引擎：清单含 Foundation，解析 Foundation 后 ObjC 与 Swift 对象非空，`NSObject` 的接口能打出。
  - 离线泛型特化：测试 bundle 里一个泛型类型走 request → `staticPreflight` → specialize，结果出现在子节点。
  - 目录：bundle 遍历（`.xctest` 本身就是 bundle）、胖文件取片（系统里现成的 universal 二进制）、`RuntimeOfflineFile(contentsOf:)` 对非 Mach-O 文件抛错。
  - 引擎停止后再连接：匿名监听器上的 client 引擎 `stop()` 后 `connect(credential:)`，再次收到镜像清单。
- **通信层**：`.dedicatedInstance` 的实例与 bootstrap 只有真实的内嵌 service 才能测，单元测试只覆盖 payload 编解码与重连状态机；真实验证在第 0 步与人工验收。
- **Packages**：`SettingsPersistenceTests` 加 `offline`；管理器的离线组（单列一组、不进 CLI 快照、停放后仍列出、唤醒复用同一对象）；`DocumentState(runtimeEngine:)` 起步即在该引擎上。
- **人工验收**（用户在真实 App 里做）：打开一个第三方 `.app`、一个 iOS cache、一个胖二进制；切走窗口 30 秒后 Activity Monitor 里该进程消失、再选回来能用；`kill -9` 离线进程后窗口回根、其它窗口不受影响；打开一个截断的 Mach-O 只影响它自己。

## 替代方案考量

- **在 App 进程里解析离线文件**：最省事。否：0037 把「My Mac」搬出去，正是因为解析器碰到畸形二进制会让 App 崩溃、索引结果常驻 App 内存；用户打开的任意文件更不可控。
- **所有离线文件共用一个 XPC service 进程**：和「My Mac」同一套做法，实现少。否：一个文件把解析器弄崩，所有离线文件一起断开；内存要等所有离线文件都关了才回收。
- **复用 `RuntimeViewerLocalRuntimeService` 的二进制跑多实例**：省一个 target。否：「My Mac」的实例也要改成按 bootstrap 分支；更要紧的是同一个生产者身份让本机 cache 的两种语料互相删除（前期调研 §4）。
- **自己起子进程，走 socket 或 stdio**：不依赖私有接口，`RuntimeStdioConnection` 现成。否（本次）：进程生命周期、僵尸进程、崩溃后的重拉都要自己管，launchd 免费给的正是这些；第 0 步若证明多实例不可用，退回这条路，并在决策日志里记下。
- **把离线文件做成真正的文档（NSDocument 读文件、窗口绑定文件）**：标题、最近打开、同一文件只开一个窗口都是现成的。否：用户选了「当作引擎接入」——窗口要能在离线文件与「My Mac」、设备之间切换，绑死文件的窗口做不到。
- **只放进引擎菜单、不走 File › Open**：否：用户要 ⌘O、最近打开与拖到 Dock。
- **单个文件只看它自己 / 每次都让用户选 cache**：前者解析不出父类在系统框架里的类、跨框架的类型和字段布局；后者打开 macOS 文件也要多一步。用户选了自动配同平台 cache。
- **让 `RuntimeEngine` 本身对 Mach-O 泛型**：否：`RuntimeEngine` 是整个 App、管理器、CLI 的公共类型，泛型会一路传染；只在 section 这一簇泛型、引擎经协议持有，波及面小得多。
- **包一个同时代表 `MachOImage` 与 `MachOFile` 的类型去遵循上游协议**：否：上游协议的面很大，而且上游自己按 `machO.asMachOFile` / `as? MachOImage` 分支（例如 `SwiftDeclarationIndexer.swift:401`），包一层会让它们全部走错路。
- **配对 cache 算进来源身份**：否：换配对 cache 会让书签、侧栏状态与 Always Index 另起一份，而用户看的还是同一个文件。
- **用 MachOKit 的 dyld cache ObjC 优化表按类名找镜像**：MachOKit 能读优化表的头（`ObjCOptimization`），但没有现成的类名查表接口；自己按 libobjc 的哈希表格式读，依赖未公开的布局且随系统变化。否（本次），先用「只读名字建表」的办法。
- **CLI 第一版就列出离线文件**：用户定为第一版不暴露。

## 影响

### 用户可见变化

- **File › Open…（⌘O）** 从「只能选一个打不开的 `.runtimedocument`」变成打开 Mach-O 文件、bundle 与 dyld cache；**File › Open Recent** 列出打开过的离线文件。Finder 里把可执行文件、动态库或 `.app` / `.framework` 拖到 Dock 图标上也能打开；「打开方式」菜单会列出 RuntimeViewer（Alternate 级别，不抢默认）。
- **工具栏引擎菜单**多一组「Offline Files」：已打开（含已停放）的离线文件，加「Open File…」「Dependency Cache ▸」。
- **离线窗口**：侧栏是文件一组、配对的 cache 一组；Load Frameworks… 不可用；Attach to Process 提示此引擎不支持；Report 的交叉引用一行显示不支持，Find 的调用层级等交叉引用功能不可用。
- **离线时内容区的差别**：字段偏移与类型布局注释是静态推算的，个别跨模块、带 resilient 父类的类型可能比在线少；泛型特化的结果没有 metadata 数值，约束检查里无法证明的遵循显示为警告而不是错误。
- **Settings** 多一页 **Offline**，登记非 macOS 平台用的 dyld cache。
- 已有的操作习惯不受影响：「My Mac」、Catalyst、设备、注入照旧。

### 可发现性

- ⌘O 是 macOS 的通用打开方式；引擎菜单里的「Open File…」给只在工具栏里找来源的用户；Settings › Offline 页说明 iOS 等文件为什么需要登记 cache。
- 功能默认开启：它只在用户主动打开文件时出现，不打开就什么都不变。

### 数据与配置兼容

- 设置新增 `offline` 分支，旧设置文件没有它就是空列表，无需迁移。
- 书签、侧栏状态、Find 最近查询、Always Index 列表按离线文件的书签身份（规范化路径）各存一份；同一文件换了路径算另一个来源。
- 派生数据新增 `Offline-…` 目录，旧目录不受影响；本机 service 的清理规则改为跳过它们。
- 线协议：新 `RuntimeSource` case 不可镜像，不出现在发给其它 Mac 的引擎列表里，旧版本对端看不到它。

### 平台与最低版本

- 只改 macOS App；最低系统仍是 macOS 15。iOS 版、越狱版、CLI 的独立 host 不受影响。
- 能打开的文件不限平台：macOS、Mac Catalyst、iOS、iOS Simulator、tvOS、watchOS、visionOS 的 Mach-O 与 cache 都按同一套静态解析读。

### 发布

- 新内嵌 XPC service，签名与公证方式与另外两个 service 相同（hardened runtime、`disable-library-validation`、非沙盒）。
- 用到 libxpc 的私有函数（实例与 bootstrap）。App 走 Developer ID 分发，不受 App Store 审核限制；系统更新改动这些接口的风险由第 0 步的探测和发布前的手测兜住，坏了就退回「自起子进程」的方案。
- Sparkle 更新流程不变；`ArchiveScript.sh` 的产物多一个 `.xpc`，归档后检查列表要加上它。
- 没有新的隐私清单条目或权限弹窗：读的是用户自己选的文件，App 本来就不在沙盒里。

## 落地步骤

每一步单独可构建、可验证。

0. **验证多实例 XPC**（前期调研 §6 第 1–3 条）：在丢弃分支上用一个只回显 bootstrap 的临时 service（不进仓库）实测——两个连接得到两个进程、`xpc_copy_bootstrap` 拿到数据、取消连接后进程退出、`kill -9` 后连接报什么、换新 UUID 重连。结论写回本提案；不可用就改走「自起子进程」并记进决策日志。
1. **SwiftyXPC**：fork 里加带实例的连接类型与读取 bootstrap 的接口，发 0.5.106；RuntimeViewer 抬下限，三个 workspace 的锁文件经 `UpdatePackagesScript.sh` 更新。
2. **Core 泛型化，行为不变**：读取方式协议、泛型的 section / indexer / 工厂 / 解析器、给引擎用的非泛型协议与 `RuntimeImageIndex`、`RuntimeProcessImageCatalog`；引擎改经目录与这些协议。验收：`RuntimeViewerCore` 全量测试与基线一致（满载下 IPC 类测试成批超时是已知现象，对照基线判断）。
3. **文件目录与文件引擎（进程内）**：`RuntimeOfflineFile`、`RuntimeFileImageCatalog`（Mach-O / 胖文件 / bundle / cache / 配对 cache）、`RuntimeFileImageReading`（特化、父类链、ObjC 名字）、按导出符号找 ObjC 类、`RuntimeEngine(reading:)`、`RuntimeSource.file`。测试见 §10。
4. **来源与传输**：`RuntimeSource.file` 及十二处 `switch`、`RuntimeBookmarkScope`、`.dedicatedInstance` 目标与重连、`RuntimeOfflineService`；引擎停止后再连接的测试。
5. **离线 service target**：目录、`Info.plist`、entitlements、xcconfig、bundle ID、App 的 `Info.plist` 键、目标依赖与嵌入阶段、Tuist 描述（`./TuistScript.sh check` 通过）、根 `AGENTS.md` 的进程表。验收：`./RunScript.sh --no-launch` 后 `Contents/XPCServices/RuntimeViewerOfflineService.xpc` 存在，`codesign -dv` 显示 hardened runtime 与 entitlements，`Info.plist` 带 `_MultipleInstances`。
6. **引擎管理**：离线组、`runtimeEngine(reading:)`、停放 / 唤醒、CLI 快照过滤与 `SourceKind`。测试见 §10。
7. **应用层与设置**：`DocumentController`、`OfflineFileController`、`Info.plist` 文档类型、`DocumentState(runtimeEngine:)` 与初始路由、引擎菜单两项与图标、注册表的占用事件、功能开关、`Settings.offline` 与 Settings › Offline 页。
8. **派生数据**：cache 身份、`Platform` 补全、离线进程的镜像判断、清理规则跳过 `Offline-` 目录。动手前读 `Documentations/DerivedData.md`。
9. **人工验收**（用户）：§10 的人工验收清单。
10. **文档**：根 `AGENTS.md`（Application Targets 加离线 service；XPC 代码的位置列表加上它的入口；进程义务表；派生数据一节）、`CommunicationAndEngineArchitecture.md`（多实例连接）、`DerivedData.md`（离线身份与清理）、`Glossary.md`（离线文件、依赖 cache、停放）、`README.md` 的功能介绍、两份索引；本提案推进状态并补决策日志。

### 进度

| 步骤 | 状态 | 证据 |
|------|------|------|
| 0 验证多实例 XPC | 未做 | 实验程序已写好（仓库外），等用户过目后运行 |
| 1 SwiftyXPC | 未做 | 等第 0 步的结论定接口 |
| 2 Core 泛型化 | 完成 | Core 全量与基线对照：基线就有的满载失败（交叉引用预先准备、后台索引批次取消、事件订阅三个之中的两个）照旧，无新增失败；新增的跳转回归测试在旧查找逻辑上红、修复后绿 |
| 3 文件目录与文件引擎 | 完成 | `OfflineFileEngineTests` 9 例通过：薄 / 胖 / 非 Mach-O / bundle 的判定，离线与进程内引擎对同一镜像列出的对象一致、打印一致，离线泛型特化，依赖解析进配对 cache，cache 引擎按导出符号找到 `NSObject` 所在的 libobjc。Core 全量 663 项只有基线就有的两个满载失败；Packages 全量 701 项挂 1 个交叉引用的等待超时（174 秒），单独跑该套件 11 项全过；CLI 121 项全过；Debug 设置文件前后校验和不变。App 目标未编，第 5 步加 service target 时一起编 |
| 4–10 | 未做 | |

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计要一篇使用指南（`Guides/OfflineMode.md`）：能打开什么、配对 cache 怎么定、哪些功能不可用、停放是什么；以及一篇实现说明或架构文档的一节：多实例 XPC 的约束（一次性实例不重拉、bootstrap 在 `main` 里读、peer 断开即退出）。
- **有没有引入新术语** —— 「离线文件」「依赖 cache（配对 cache）」「停放」要进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-02 | Created as Draft | 引擎只能读进程里已加载的镜像（`MachOImage`），而上游 ObjC / Swift 两套库对 `MachOFile` 早已通用；用户要求实现离线模式，打开磁盘上的 Mach-O 文件与 dyld cache。 |
| 2026-11-02 | 按完整档处理 | 新的引擎来源、Core 的泛型化、新的进程，属于架构改动；按完整档拷问两轮后确认共识，再写本提案。 |
| 2026-11-02 | 每个文件一个进程 | 用户选定。否决「所有离线文件共用一个 XPC service」（一个文件崩溃带走全部）与「在 App 进程里解析」（违背 0037 的隔离原则）。 |
| 2026-11-02 | 离线文件当作一种引擎接入 | 用户选定：File › Open… 开新窗口，引擎菜单单列，任何窗口可切换，进最近打开。否决「当作文档绑定窗口」（窗口不能切引擎）与「只放进引擎菜单」。 |
| 2026-11-02 | 自动配同平台的 dyld cache | 用户选定：macOS 文件用本机 cache，其它平台用登记的 cache，没有就只看文件本身。否决「只看文件本身」（父类链、跨框架类型与字段布局解析不出）与「总让用户选」。 |
| 2026-11-02 | 第一版加上 `.app` / `.framework` 包 | 用户选定；CLI 直接指定文件与交叉引用不进第一版。 |
| 2026-11-02 | 无窗口时进程退出、菜单保留 | 用户选定：释放内存优先，再选中时重新拉起、重新解析。否决「一直活着直到手动关闭」与「彻底关闭、只能从最近打开再开」。 |
| 2026-11-02 | 非 macOS 文件的 cache 在设置里登记、按平台自动挑 | 用户选定，可在引擎菜单里改。否决「每次打开弹窗选」与「打开后再从菜单挂」。 |
| 2026-11-02 | 侧栏：文件一组、cache 一组 | 用户选定，与「My Mac」的「Dyld Shared Cache / Others」同形；跳到系统类型时侧栏有它的位置。 |
| 2026-11-02 | CLI 第一版不暴露离线文件 | 用户选定；agent 插件的 skill 不动。MCP 按窗口工作，不受影响。 |
| 2026-11-02 | 默认假设（用户未反对） | 同一文件只起一个进程；胖文件自动取本机优先的切片；cache 选主文件、子缓存自动带上；不跨重启恢复；交叉引用沿用「此引擎不支持」、载入框架与注入对离线引擎禁用；Find 语料落盘只给 dyld cache；文件改动不自动刷新；只做 macOS App；不镜像给其它 Mac。 |
| 2026-11-02 | 共识确认 | 用户确认以上决定即为共识，同意据此写提案。 |
| 2026-11-02 | 写方案时自定的几条 | 停放前等 30 秒；Dock 拖放不接 dyld cache（不声明 `public.data`）；停放条目留到 App 退出、第一版不能从菜单移除；面板不进入包内容；离线引擎菜单组名「Offline Files」；配对的选择规则（同平台、版本不低于 SDK 的最小者）；App 进程只读文件头与 cache 头。理由见「未询问自定的假设」。 |
| 2026-11-02 | 技术路线 | 新 service target 而不复用本地运行时 service（语料撞车）；多实例用一次性实例 + bootstrap（WebKit 的现行做法），须第 0 步实测；Core 只把 section 一簇泛型化、引擎经非泛型协议持有；配对 cache 是配置不是身份；离线 service 不链接注入与交叉引用两个模块。 |
| 2026-11-02 | Draft → Accepted | 用户批准，开始实现。 |
| 2026-11-03 | Accepted → In Progress | 功能分支 `feature/offline-mode` 开工。 |
| 2026-11-03 | 第 0 步挪到第 3 步之后 | 第 0 步的多实例实验是自己写的程序，按全局规则要先给用户看过才能运行；第 2、3 步（Core 泛型化与进程内的文件引擎）不依赖它，先做，做到第 0 步时一并请用户过目。 |
| 2026-11-03 | 引擎持有四个协议类型的属性，不另立 `RuntimeImageIndexing` | 详细设计 §2 原拟一个总协议。实现时让 `objcSectionFactory`、`swiftSectionFactory`、`relationshipsResolver`、`typeRelationshipsResolver` 保留原名、类型换成 `any RuntimeObjCSectionProviding` 等四个协议（工厂协议以关联类型声明自己的 section，经 `any` 调用时自动擦除成 section 协议），引擎里的调用点几乎不用改；五样东西由 `RuntimeImageIndex` 按同一种读取方式成套建出，另加 `imageCatalog`。 |
| 2026-11-03 | `RuntimeIndexableMachO` 多两项要求 | MachOObjCSection 读 ObjC 协议记录的名字、MachOSwiftSection 建私有鉴别器的源文件索引，都是按 `MachOImage` / `MachOFile` 分开的具体重载，泛型代码调不到；协议里加 `objcProtocolRecords(in:)` 与 `makePrivateDiscriminatorSourceFileIndex(indexer:)`。Core target 补上 `ObjCMetadataSource` 产品依赖（协议的约束在这个模块里）。 |
| 2026-11-03 | Swift 工厂的跨镜像表记下 section 自己的键 | 「mangled 名 → 定义它的镜像」两张表原来拿 `MachOImage.imagePath` 去找 section；离线时单个文件的 `imagePath` 是 install name，找不到。改成两张表各记注册它的 section 的键，引擎经 `imagePath(definingTypeWithCandidateID:)` / `imagePath(definingProtocolWithCandidateID:)` 取。这顺带修掉了提案索引「暂缓的后续项」里的「跨镜像点击跳到 `@rpath` 镜像落空」（同一个原因），收尾时从那张表里划掉。 |
| 2026-11-03 | `RuntimeSource.file` 提前到第 3 步 | 进程内的文件引擎（`RuntimeEngine(reading:)`）构造时就要有来源，第 3 步的测试离不开它；`RuntimeSource` 自身六处、`RuntimeCommunicator`、路径规范化、注入能力与 `RuntimeBookmarkScope`（新增 `Identity.file(path:)`）随之同批改完。App 与 CLI 两侧的 switch 仍在第 4、6 步。 |
| 2026-11-03 | CLI 的排除与两处 App / 设置的 switch 也在第 3 步做 | 新 case 一进 Core，CLI 的 `SourceKind(source:)`、设置里的 `carriesProcessIdentifier` 与 App 的来源图标三处穷举 switch 就编不过，每一步都要整个仓库可构建，所以提前做：`SourceKind.init?(source:)` 对 `.file` 返回 `nil`，`SourceInfo.init?(engine:)` 随之可失败，CLI 的快照把离线引擎从各分组里滤掉（即第 6 步「CLI 不暴露」的全部改动）；`.file` 不带进程号；来源菜单的图标先用文档符号，第 7 步做引擎菜单时再定。 |
| 2026-11-03 | 离线按名字找 ObjC 类走导出符号，协议只看已解析的镜像 | 详细设计 §3 原拟按需建「名字 → 镜像」表。实现时改查各镜像导出 trie 里的 `_OBJC_CLASS_$_<类名>`：别的镜像引用一个类正是经这个导出符号，查一次是几次 trie 节点读取，整份 cache 查一遍也远比解析全部 classlist 便宜，所以不必建表、也不用实测建表代价。ObjC 协议没有导出符号，离线时只能在已解析的镜像里找到——跳到一个尚未解析的镜像里的协议会找不到，记为已知降级。 |
| 2026-11-03 | 读取方式改为策略类型 `RuntimeImageReading` | 第 2 步按提案让 `MachOImage` / `MachOFile` 直接遵循 `RuntimeIndexableMachO`；第 3 步加 `MachOFile` 时编译不过：它是非 final 的 class，满足不了在别的泛型里写 `Self` 的要求（`GenericSpecializer<Self>`、`SwiftDeclarationIndexer<Self>`）。改成两个枚举 `RuntimeLoadedImageReading` / `RuntimeFileImageReading` 实现同一协议，各带关联类型 `MachO`；泛型类型改为对策略泛型、体内 `typealias MachO = Reading.MachO`，方法体不用动。详细设计 §2、§3 已改成实际的样子。 |
| 2026-11-03 | 离线的 Swift 父类链停在第一个 ObjC 父类 | `RuntimeEngine.hierarchy(for:)` 在进程内实例化 metadata 一路走到 `NSObject`；离线时只能读各镜像索引时记下的父类名，走到第一个 ObjC 父类（记它的运行时名字）或尚未索引的镜像里的 Swift 类为止。Inspector 的父类时间线走的是 `superclassChain`，不受影响。 |

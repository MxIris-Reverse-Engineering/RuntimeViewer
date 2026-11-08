# Draft - 系统镜像的数据跨 engine 只存一份：My Mac 与 Mac Catalyst 分管，本机附加进程借用

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-08
- **最后更新**: 2026-11-08
- **所属愿景**: 无
- **关联提案**: [0037](0037-local-runtime-xpc-service.md)（本地引擎搬进 XPC service）、[0051](0051-catalyst-xpc-service.md)（Catalyst 引擎改用内嵌 service）、[0054](0054-always-index-per-engine.md)（Always Index 按 Engine 区分）、[0055](0055-engine-scoped-background-work.md)（后台工作按 Engine 共享）、[0056](0056-cross-references.md)（交叉引用）、[0058](0058-runtime-engine-session.md)（RuntimeEngineSession）、[0061](0061-derived-data.md)（派生数据）、[0065](0065-engine-resident-memory.md)、[0066](0066-on-demand-corpora-and-cross-references.md)
- **实现分支 / PR**: `feature/shared-cache-images-across-engines`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

本机所有进程映射的是同一份 dyld shared cache（下称「系统镜像」，即 shared cache 里的镜像），它们的 Objective-C / Swift 元数据在哪个进程里读都一样，可现在每多一个 engine，就在它自己的进程里把这些镜像的索引、Find 语料和交叉引用表重建一遍；Attach 的进程更糟，这些数据建在目标进程里，也读不到存盘的派生数据。改为每个系统镜像只归一个 engine 管：只有 Mac Catalyst 进程才能加载的镜像（523 个）归 **My Mac (Mac Catalyst)** engine，其余的归 **My Mac** engine，两者互相借用；本机 Attach 的进程（经 XPC 或 socket 注入、与 App 用同一份 shared cache 的）不再自己处理系统镜像，而是直接借这两份。路由做在 `RuntimeEngine` 这一层，App 窗口、MCP 与 `runtime-viewer-cli` 一起受益：只涉及一个镜像的请求转给它的归属 engine，跨镜像的查询两边都问、合并结果。附加进程的文档代为在归属 engine 上发起索引，Report 里另起一组显示且可以操作；侧栏的「已加载」仍以目标进程为准，点 Load 只加载进归属 engine，不碰目标进程。资格不符、归属 engine 不可用或在 Developer 设置页关掉时，退回现状。

## 动机

**同一份数据存了好几遍。**

- 每个 engine 的 section（一个镜像的 ObjC / Swift 索引）、Find 语料、交叉引用表，都存在服务它的那个进程里，各建各的（`RuntimeEngine.swift:236-298`，`RuntimeImageIndex.process()`）。2026-11-08 在 Ultra 上实测，只开 My Mac 一个文档时本地 service 的堆约 305 MB：6 个 Always Index 镜像（AppKit、Foundation、libswiftCore、SwiftUI、SwiftUICore、libobjc）的索引约 175 MB，交叉引用 65 MB，Find 语料 53 MB（后两项各有 64 MB 上限）。
- Always Index 清单默认对所有 engine 生效（`AlwaysIndexEntry.appliesToAllEngines` 默认 `true`），每个附加进程的文档还会从目标的主程序出发按依赖深度建一批。于是 My Mac、Mac Catalyst、每个附加进程各建一遍同样的系统镜像数据。0054 当时只做了「每行自己选适用的 engine」作为缓解，没有去掉重复本身。
- 附加进程的这份数据建在**目标进程里**：别人的 App 平白多出几百 MB 内存、多跑几分钟 CPU；派生数据（存盘的语料，0061）只在两个内嵌 service 里开启，注入的 payload 读不到，所以每次附加都要重打一遍语料。
- App 进程里每个 engine 还各存一棵系统镜像树（约 1.47 万个 `RuntimeImageNode`）。2026-11-08 实测 App 堆里有 2.9 万个，正好 My Mac 与 Catalyst 各一棵；每附加一个进程再多一棵。

**两个系统 engine 各有打不开的镜像。** My Mac 跑在 macOS 进程里，dyld 拒绝把只为 Mac Catalyst 构建的镜像加载进来：UIKitCore 等 523 个镜像在 My Mac 的侧栏里列着，却点不开。

## 前期调研

- **系统镜像按平台的分布**（macOS 27.2，build 26B123，M3 Ultra，arm64e cache，UUID `b411828b-4450-38e3-973a-afe7b7b5bef5`）：从 `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.map` 取出 4115 个镜像路径，逐个 `dyld_info -platform`：
  - 只为 Mac Catalyst 构建的 523 个：519 个在 `/System/iOSSupport/` 下，另有 4 个在外面（`AccessorySetupKitCore`、`DrawingBoard`、`MaterialKit`、`_CommunicationsUICore_PosterBoardServices`）；
  - `/System/iOSSupport/` 下还有 1 个是 macOS 镜像（`AuthKitUIMacHelper`）；
  - 其余 2029 个只为 macOS 构建，1562 个双平台（zippered）。
  - 结论：按 `/System/iOSSupport/` 路径前缀划分有 5 个例外，按镜像自己的平台划分才与「哪个进程能加载」完全一致。
- **dyld 的加载规则**：`Header::loadableIntoProcess`（`/Volumes/AppleOSS/distribution-macOS/dyld/mach_o/Header.cpp:2174`）规定 Mac Catalyst 进程与 Mac 上的 iOS 进程可以加载 macOS 镜像，macOS 进程不能加载只为 Catalyst 构建的镜像。实测：macOS 进程 `dlopen` UIKitCore、MaterialKit 失败，`AuthKitUIMacHelper` 成功。
- **进程用哪份 shared cache**：dyld 按它自己的架构挑 cache 文件（`dyld/SharedCacheRuntime.cpp:83-97` 的 `ARCH_NAME`）。Apple Silicon 上 dyld 是 arm64e，所以 arm64 与 arm64e 的原生进程都映射 `dyld_shared_cache_arm64e`；Rosetta 下的 x86_64 进程用 x86_64 的 cache；Intel Mac 上按是否 Haswell 在 `x86_64` 与 `x86_64h` 之间选。macOS 的 payload 带 x86_64 切片（`Configurations/RuntimeViewerServer/Release.xcconfig:3` 的 `ARCHS_STANDARD`），所以 Rosetta 进程也能被附加。
- **同一份 cache 时数据相同**：ObjC 索引从镜像的 Mach-O 静态读取，运行时只用来按类名找所在镜像（`MachOImage+RuntimeObjCName.swift:28-32`）；成员地址显示的是未加 slide 的地址（`AgentPlugins/runtime-viewer/skills/runtime-viewer-cli/SKILL.md:136-138`），不同进程的 slide 不同也不影响。
- **无法向旧 payload 打听 cache 身份**：经 Mach service 注入的旧版 payload 收到不认识的命令，会当成客户端离开而断开（PR121.73，`Documentations/CommunicationAndEngineArchitecture.md:414`），所以不能给 payload 加一条「你用的是哪份 cache」的新命令。App 一侧也读不到别的进程的 shared region：实测 `proc_regionfilename` 对 Finder、Dock 的 cache 地址返回 `EINVAL`。能读到的是进程是否在 Rosetta 下运行：`sysctl` 的 `KERN_PROC_PID` 给出 `p_flag`，`P_TRANSLATED`（`0x20000`）对任何进程（含 root 进程）都读得到，实测通过。
- **请求只有一个分发点**：每个请求都是一个 `RuntimeEngineCommand`，经 `RuntimeEngine.dispatch(_:)` 决定本地执行还是转发（`RuntimeEngine.swift:989-1045`）。命令本身没有「关于哪个镜像」的字段（`Engine/Commands/RuntimeEngineCommand.swift:16-22`），镜像路径散在各命令的 `path`、`image`、`object.imagePath` 等字段里。
- **看似单镜像、实则跨镜像的查询**：`interface(for:)` 的 Swift 兜底按 mangled name 查遍所有已索引镜像（`RuntimeEngine.swift:857`）、ObjC 兜底经服务进程的运行时找类所在镜像并按需建 section（`RuntimeEngine.swift:827`）；`superclassChain` 与 `refinedProtocolTree` 跨镜像往上走，走不到的父类记成 unresolved 节点（`RuntimeTypeRelationshipsResolver.swift:437-469`）；`counterpart` 的 Swift 协议分支也查遍已索引镜像（`RuntimeEngine.swift:1390`）。
- **跨镜像查询的结果形状**：`relationships(for:)` 是所有已索引镜像的并集（`RuntimeRelationshipsResolver.swift:27-46`）；Find 的文本与成员搜索按镜像路径顺序扫描、全局 `resultLimit` 默认 1000、重复的 ObjC 协议副本按每次扫描折叠（`RuntimeInterfaceCorpusStore.swift:1134-1256`）；`typeRelationships` 的树跨镜像构建（`RuntimeTypeRelationshipsResolver.swift:93-174`），不能简单拼接；交叉引用的扫描范围是 engine 的 `indexedImagePathList()`（`CrossReferenceQuery.swift:29,133`），结果按进程内的镜像序号排序（`:811-815`），两个进程的结果只能拼接。
- **泛型特化**：候选实参来自服务进程里所有已索引镜像的聚合（`RuntimeSwiftSection.swift:1007-1012`，`RuntimeSwiftInterfaceIndexer.swift:638-690`），特化本身调用进程内的元数据访问函数（`RuntimeLoadedImageReading.swift:69-80`），结果登记在泛型类型所在的 section 上并广播 `.specializationAdded`。
- **后台工作的结构**：后台索引管理器跑在 App 进程里，挂在 App 持有的那个 engine 对象上（`RuntimeEngine.swift:290`），按依赖做广度优先遍历，每个镜像的判断与加载都是经 `dispatch` 发出的单镜像命令（`RuntimeBackgroundIndexingManager.swift:290-367,493`），对系统镜像没有任何特殊处理。三个协调器、`RuntimeEngineBackgroundWork`、`RuntimeEngineSession`、Report 与工具栏进度都假定一个文档只持有一个 engine 的后台工作（`RuntimeEngineSession.swift:18-60`；`ReportNodeIdentifier` 不含 engine，`ReportNode.swift:20-42`）。
- **侧栏打开镜像**：先 `isImageLoaded`，没加载就显示「not yet loaded」与 Load 按钮；Load 调 `loadImage(at:)`，之后靠 engine 的 `.fullReload` 刷新（`SidebarRuntimeObjectViewModel.swift:459-531,724-734`）。`isImageLoaded` 看的是服务进程的已加载列表（`RuntimeEngine.swift:1117-1119`）。
- **Always Index 的解析**：条目只按 engine 的 `imageList`（服务进程已加载的镜像）解析，解析不到的静默跳过（`RuntimeBackgroundIndexingCoordinator.swift:564-575`），本意是不把镜像加载进目标进程。
- **CLI 与 MCP 用的是同一批 engine 对象**：App 充当 CLI 宿主时经 `RuntimeEngineManager` 取 engine（`CommandLineHostController.swift`，`EngineManagerSourceResolver`），MCP 用窗口的 `documentContext.runtimeEngine`（`MCPBridgeServer.swift:161` 等）。agent 插件的说明里有多处描述附加进程与加载行为（`SKILL.md:19-22,49-55,82-89,213-216`），两份插件清单的 `version` 都是 `1.0.2`。
- **重启后从头来过**：文档只跟随自己 engine 的就绪状态，从「未就绪」回到「就绪」且有内容打开时回到起点（`DocumentState.swift:108-130`）。
- **Developer 设置**：`Settings.Developer` 有总开关 `isEnabled`，各选项通过 `effective…` 属性读取（`Settings+Developer.swift`）；`RuntimeViewerEngineManagement` 不依赖 `RuntimeViewerSettings`（`RuntimeViewerPackages/Package.swift:516-527`）。

## 提议方案

1. **归属按平台划分**：只为 Mac Catalyst 构建的系统镜像归 Mac Catalyst engine，其余（只为 macOS 构建的与双平台的）归 My Mac engine。划分在进程启动后从本进程映射的 shared cache 里算一次。
2. **谁借用**：
   - My Mac 与 Mac Catalyst 互相借用：My Mac 文档里的 Catalyst 专用镜像由 Catalyst engine 提供，Catalyst 文档里的其余系统镜像由 My Mac 提供。
   - 本机 Attach 的进程（`.remote` / `.localSocket` 来源，identifier 是 pid）借用这两份，前提是 App 判定它与 App 用同一份 shared cache：Apple Silicon、App 与目标都不在 Rosetta 下运行、目标的环境变量里没有 `DYLD_SHARED_REGION` 与 `DYLD_SHARED_CACHE_DIR`。
   - 不借用：离线文件、Bonjour 设备与模拟器、别的 Mac、Rosetta 下的目标、Intel Mac。
3. **路由做在 `RuntimeEngine` 这一层**：只涉及一个镜像的请求，按镜像转给它的归属 engine；跨镜像的查询同时问本 engine 与归属 engine，各取自己负责的那部分镜像再合并；单镜像查询里的跨镜像兜底（Swift 跳转、ObjC 类、父类链、协议树）改为先本 engine、后归属 engine 接力。App 窗口、MCP、`runtime-viewer-cli` 用的是同一批 engine 对象，一起生效。
4. **加载语义**：借用方的侧栏里，系统镜像的「已加载」= 目标进程已加载的，加上经本 engine 借来加载过的。目标已加载的镜像打开时，由归属 engine 自动加载并索引；没加载的仍标「not yet loaded」，点 Load 只加载进归属 engine，不碰目标进程。
5. **后台工作**：
   - 附加进程的文档以「借用者」身份加入归属 engine 的后台工作：工作因此存在、照常运行，但不触发归属 engine 自己的开场派发（它的主程序批次与它的 Always Index）。
   - 目标主程序依赖里的系统镜像、Always Index 里的系统镜像，交给归属 engine 的索引管理器建；Always Index 的系统镜像条目按全部系统镜像解析，不论有没有加载。
   - 借用方自己的语料与交叉引用只管非系统镜像；系统镜像的语料与交叉引用由归属 engine 的协调器负责，照常读写派生数据。
   - Report 按 engine 分组：本 engine 一组，借用的每个归属 engine 各一组，组内的取消、推出、清历史作用于那个 engine，与在它自己的窗口里操作一样。工具栏的活动进度把各组合在一起显示。
6. **App 里共用一棵系统镜像树**：所有用同一份 cache 的 engine 的 `imageNodes` 里，「Dyld Shared Cache」这一棵换成同一个对象。
7. **泛型特化**：系统镜像里的泛型类型交给归属 engine 特化。附加进程自己的泛型类型仍在目标进程里特化；为了让系统类型继续出现在候选里，第一次特化前让目标进程为它已加载、且本 engine 借用过的系统镜像建 section。这是共用之后唯一保留的重复，只在用户主动特化时发生。特化结果登记在做特化的那个 engine 上，所有借用这个镜像的窗口都看得到。
8. **退回现状**：不满足借用条件、归属 engine 不在（例如 Catalyst helper 不可用）、或在 Settings › Developer 关掉共用时，engine 照旧自己处理所有镜像。
9. **归属 engine 重启**：My Mac 或 Catalyst 的服务进程重启（崩溃或被系统回收）时，正在借用它、且有内容打开的文档也回到起点，与它自己的文档一样。
10. **CLI 插件**：`runtime-viewer-cli` 对附加进程的行为随之改变，agent 插件的说明同步更新，两份清单的 `version` 升到 `1.1.0`。

### 非目标

- 离线模式（`.file` 来源的 engine）不参与。
- 设备、模拟器、别的 Mac 上的 engine，Rosetta 下运行的目标进程，Intel Mac：维持现状。
- 不给 payload 加需要它先回答才能工作的命令，不改连接与握手格式，不升 helper 协议版本。唯一的线上改动是给类型关系查询加一个可选字段（见详细设计 §6），旧 payload 解码时忽略它。
- 目标进程打印自己的镜像时，MachOSwiftSection 内部按需读取系统镜像元数据的那部分开销不在本提案处理。
- 不改派生数据的格式、位置与清理规则，不改语料与交叉引用的常驻内存上限。
- 不按目标进程过滤 Find、调用层级与类型引用的结果：覆盖归属 engine 已索引的全部系统镜像。
- Report 分组的视觉细节按现有样式实现，验收时目视确认，不在本提案里定稿。

## 详细设计

### 1. 系统镜像的归属（Core，`Images/`）

```swift
/// Which kind of process can load an image of the dyld shared cache.
public enum RuntimeSharedCacheImagePlatform: Sendable, Hashable {
    /// Built for macOS, alone or zippered with Mac Catalyst: a macOS process loads it.
    case macOS
    /// Built for Mac Catalyst only: only a Mac Catalyst process loads it.
    case macCatalyst
}

/// The images of the dyld shared cache this process maps, each with the kind of
/// process that can load it. Read once from the cache's own headers.
public struct RuntimeSharedCachePartition: Sendable {
    public let cacheUUID: UUID
    public let imagePaths: Set<String>

    /// The partition of the cache this process maps; `nil` when it maps none.
    public static func current() -> RuntimeSharedCachePartition?

    /// `nil` for a path that names no image of the cache.
    public func platform(ofImageAt imagePath: String) -> RuntimeSharedCacheImagePlatform?

    /// The image tree every engine on this cache shows, built once.
    public var imageRootNode: RuntimeImageNode { get }
}
```

- 平台取自每个镜像的 `LC_BUILD_VERSION`：只列 `macCatalyst` 的算 `.macCatalyst`，其余算 `.macOS`。读的是本进程已映射的 cache 头部，不 `dlopen`，所以 App 进程也可以算（AGENTS.md 只禁止 App 进程加载与索引镜像）。
- 4115 个镜像的头部读一遍在毫秒级，结果由 engine 管理器持有，整个进程一份。

### 2. 借用关系（Core，`Engine/`）

```swift
/// The engines that keep the data of this Mac's shared cache images, and the
/// partition that says which one keeps which image.
public struct RuntimeSharedCacheOwners: Sendable {
    public let partition: RuntimeSharedCachePartition
    public let macOS: RuntimeEngine
    /// `nil` while the Mac Catalyst engine is not up: its images stay with
    /// whoever asks for them.
    public let macCatalyst: RuntimeEngine?

    public func owner(ofImageAt imagePath: String) -> RuntimeEngine?
}

extension RuntimeEngine {
    /// The owners this engine borrows shared cache images from; `nil` when it
    /// serves every image itself.
    public var sharedCacheOwners: RuntimeSharedCacheOwners? { get }

    public func setSharedCacheOwners(_ owners: RuntimeSharedCacheOwners?)
}
```

- `owner(ofImageAt:)` 对不是系统镜像的路径返回 `nil`；`RuntimeEngine` 内部再把「归属 engine 就是自己」也当成 `nil`，所以 My Mac 只把 Catalyst 专用镜像转出去，Catalyst 只把其余系统镜像转出去。
- 借用关系只由 engine 管理器设置（§7），`RuntimeEngine` 不知道归属 engine 在哪个进程、经什么传输。

### 3. 路由（Core，`Engine/Commands/`）

命令自己声明它关于哪个镜像，分发点只有 `dispatch(_:)` 一处：

```swift
extension RuntimeEngineCommand {
    /// The one image whose data answers this request, when exactly one does.
    /// `nil` — the default — keeps the request with the engine it was sent to.
    public var subjectImagePath: String? { nil }

    /// Whether the request is a load made for the user, which holds back the
    /// background indexing of the engine that serves it.
    public static var isForegroundLoad: Bool { false }

    /// Whether the subject image is indexed once the request returns, which
    /// the serving engine announces on its `imageDidIndexPublisher`.
    public static var indexesSubjectImage: Bool { false }
}
```

- `dispatch(_:)` 的第一步：`subjectImagePath` 有归属 engine 时，交给 `owner.dispatchBorrowedRequest(command)`。后者在归属 engine 上照常分发，并按命令的两个声明替它做一个窗口直接发请求时会做的事：前台加载时压住它的后台索引，建好索引后在它的 `imageDidIndexPublisher` 上通告。这样归属 engine 的语料与交叉引用协调器像对待自己窗口的请求一样接着处理。
- 声明 `subjectImagePath` 的命令：`IsImageIndexed`、`LoadImage`、`LoadImageWithProgress`、`LoadImageForBackgroundIndexing`、`CanOpenImage`、`Rpaths`、`Dependencies`、`ObjectsInImage`、`Interface`、`Hierarchy`、`Counterpart`、`MemberAddresses`、`PrivateDeclarationSourceFiles`、`SpecializationRequestForObject`、`RuntimePreflight`、`Specialize`、`BuildInterfaceCorpus`、`PrioritizeInterfaceCorpus`、`EvictInterfaceCorpus`（给了路径时）、`ExportModuleInfo`；交叉引用模块的 `Callees` 与 `PrepareCrossReferences` 在它自己的模块里声明（AGENTS.md 第 8 条）。
- `IsImageLoaded` 不按镜像转出去，见 §5。进程级的命令（主程序路径、`reloadData`、`dyldRootPath`、注入命令、engine 列表、常驻上限）不声明，留在本 engine。
- 测试钉住覆盖：枚举所有内置命令与两个扩展模块的命令，断言每个带镜像路径字段的命令要么声明了 `subjectImagePath`，要么在「有意不转」的名单里。以后新增命令漏了声明，测试会红。

### 4. 跨镜像查询的合并

跨镜像的命令遵循一个协议，由借用方 engine 同时问自己与各归属 engine，再把结果合并：

```swift
/// A request about every image an engine has indexed. An engine that borrows
/// shared cache images sends it to itself and to each owner, keeps from each
/// answer the images that engine is responsible for, and combines the parts.
public protocol RuntimeEngineSpanningCommand: RuntimeEngineCommand {
    /// The part of `response` about the images `isIncluded` accepts.
    static func response(_ response: Response, includingImagesWhere isIncluded: (String) -> Bool) -> Response

    /// One answer made of `parts`, as this request would have answered alone.
    func combinedResponse(of parts: [Response]) -> Response
}
```

各命令的合并规则：

| 命令 | 规则 |
|------|------|
| `relationships(for:)` | 子类与遵循者取并集，按 `RuntimeObject` 去重 |
| `indexedImagePathList()` | 取并集后重新排序 |
| `interfaceCorpusCoverage()` | 两个按路径的字典合并；常驻字节数与上限各 engine 分别报，不相加 |
| `restoreInterfaceCorpora` | 按归属把路径分组分别发出，结果字典合并 |
| `searchInterfaces` / `searchMembers` | 两边并行扫描；进度按镜像各自转发；合并时按镜像路径排序，套用全局 `resultLimit` 重算截断，摘要字段相加或取或；重复的 ObjC 协议副本按它显示的文本再折叠一次；取消时同时撤回各子请求 |
| `callers` / `typeReferences`（交叉引用模块） | 两边结果拼接，进度的已扫与总数相加，`resultLimit` 作用于拼接后的结果 |
| `typeRelationships` | 见 §6 |
| `evictInterfaceCorpus(for: nil)` | 本 engine 与各归属 engine 都执行 |

「各取自己负责的那部分」的含义：借用方只留非系统镜像的结果；每个归属 engine 只留归它管的系统镜像。这同时去掉了特化时在目标进程里按需建出的系统镜像带来的重复（§8）。

### 5. 加载语义

- 借用方 engine 记一个「借来加载过的」路径集合。系统镜像的 `isImageLoaded(path:)` = 目标进程的 `imageList` 含它，或集合里有它。
- `loadImage(at:)` 对系统镜像转给归属 engine；成功后记进集合，并在借用方本地发一次 `.fullReload(isReloadImageNodes: false)`，侧栏据此刷新（目标进程不会为此发 `.fullReload`）。
- `objects(in:)` 对系统镜像：归属 engine 还没加载它时，先让归属 engine 加载，再取对象。这就是「目标已加载的镜像打开时由归属 engine 自动加载并索引」。
- Load Frameworks… 选择框（`MainViewModel.swift:343`）表达的是「把这个框架加载进 engine 的进程」，对附加进程就是目标进程。它改用一个不转出去的变体 `loadImageInServingProcess(at:)`；加载之后数据仍由归属 engine 提供。

### 6. 跨镜像兜底的接力

- **Swift 跳转**（`interface(for:)` 按 mangled name 的兜底）：本 engine 找不到时依次问各归属 engine。
- **ObjC 类兜底**：先在各归属 engine 上找（它的服务进程按类名定位所在镜像，必要时把镜像加载进自己的 service 再建 section）；都找不到时退回现在的做法，由本 engine 的服务进程按需建 section。不新增问目标进程的命令：旧版经 Mach service 注入的 payload 收到不认识的命令会断开（PR121.73）。归属 engine 怎样在镜像未加载时按类名定位镜像（例如 shared cache 预先建好的 ObjC 类表），实现时查证；查不到可用的办法时，只对已加载的镜像生效，并把结论记进决策日志。
- **父类链与协议树**（`superclassChain`、`refinedProtocolTree`）：本 engine 走到 unresolved 节点、且它是系统类型时，把归属 engine 从这个类型往上的部分接上去。
- **`counterpart` 的 Swift 协议分支**：同 Swift 跳转。
- **`typeRelationships`**：候选取两边的并集，按「精确匹配在前」重排后套用 `candidateLimit`。祖先树按父类链的规则接力。后代树与遵循者树：系统类型的部分由归属 engine 给出；附加进程里继承或遵循它的类型，靠查询新增的可选字段 `externalRootNames` 交给目标进程，按名字找出它自己镜像里的后代再接上。旧 payload 忽略这个字段，此时少了目标进程自己的那部分，与「目标没有索引系统镜像」时的结果相同。

### 7. 资格判定与接线（`RuntimeViewerEngineManagement`）

```swift
extension RuntimeEngineManager {
    /// Whether engines borrow shared cache images from My Mac and Mac Catalyst.
    /// On by default; the app turns it off from Settings › Developer.
    public var sharesSharedCacheImages: Bool { get set }
}
```

- 管理器启动时算一次 `RuntimeSharedCachePartition.current()`；App 进程本身在 Rosetta 下运行、或不是 Apple Silicon 时，整套机制不启用。
- 资格判定是纯函数，读数入口可注入，便于测试：来源是 `.remote`（identifier 是 pid，不是 `.macCatalyst`）或 `.localSocket`；`sysctl(KERN_PROC_PID)` 读到的 `P_TRANSLATED` 为假；目标的环境变量（沿用附加流程已有的 `ProcessEnvironmentProbe`）没有 `DYLD_SHARED_REGION`、`DYLD_SHARED_CACHE_DIR`；读不到环境变量时按符合处理（这两个变量只有开发者手动设置才会出现）。
- 接线时机：系统 engine 起来时（`.local` 借 Catalyst、Catalyst 借 `.local`）；附加 engine 连上或重连时；Catalyst engine 重启、换成新对象或消失时，重算所有 engine 的借用关系；`sharesSharedCacheImages` 变化时同样重算。
- 借用关系变化的那一刻，正在借用的文档按「engine 重启」处理：有内容打开的回到起点。
- 无头 CLI 宿主（`.headlessHost` 配置）走同一套：它的 `.local` 在进程内，Catalyst 经 helper。

### 8. 后台工作（Core 的索引管理器与 `RuntimeViewerApplication`）

- **索引管理器把系统镜像交出去**：借用方 engine 的遍历遇到有归属 engine 的系统镜像时不加进自己的批次，而是记下它与剩余深度；遍历结束后在各归属 engine 的管理器上开一个多根批次。新接口：

  ```swift
  public struct RuntimeIndexingBatchRoot: Sendable, Hashable {
      public let imagePath: String
      public let depth: Int
  }

  extension RuntimeBackgroundIndexingManager {
      public func startBatch(roots: [RuntimeIndexingBatchRoot], maxConcurrency: Int, reason: RuntimeIndexingBatchReason) async -> RuntimeIndexingBatchID?
  }
  ```

  `RuntimeIndexingBatchReason` 新增 `.borrowed(by: String, reason: …)`，Report 据此把这批标成「为 Finder 索引」。系统镜像只依赖系统镜像，所以归属 engine 那边接着往下走就能覆盖它的依赖。
- **借用者身份**：`RuntimeEngineBackgroundWorkRegistry` 的成员分两种。文档直接在 engine 上时是成员，借用它时是借用者；两种都让工作存在，最后一个离开时关闭。只有第一个成员加入时才调用 `documentDidOpen()`，所以只有借用者时不派发归属 engine 自己的主程序批次与 Always Index。
- **会话**：`RuntimeEngineSession` 增加 `borrowedBackgroundWorks`，在会话创建时定下，之后不再改变；借用关系变化时换一个新会话（与切换 engine 同一条路）。
- **Always Index**：借用方的条目解析时，先查目标的 `imageList`，再查全部系统镜像；短名同时匹配到两个平台的同名镜像时（如 SwiftUI），取本 engine 所在进程的平台能加载的那个。解析到系统镜像的条目交给归属 engine 的管理器（多根批次，reason 为 `.borrowed`），其余照旧。My Mac 与 Catalyst 自己的文档同样遵循这条规则，所以 My Mac 文档里的 UIKitCore 条目会交给 Catalyst。
- **借用方自己的协调器**：语料协调器与交叉引用协调器忽略系统镜像（`imageDidIndexPublisher` 发来的与 `indexedImagePathList()` 列出的都过滤掉）。
- **泛型特化的按需索引**：借用方 engine 第一次为目标自己的类型发 `specializationRequest` 前，把「目标已加载、且本 engine 借用过」的系统镜像在目标进程里建好 section，作为一次本 engine 的后台批次显示在 Report 里。这一批明确绕过路由，直接发给目标进程（与 `loadImageInServingProcess(at:)` 同一条路），否则会被 §3 转回归属 engine。这些镜像不建语料、不备交叉引用。
- **Report**：顶层改为每个 engine 一组：本 engine 一组，每个借用的归属 engine 一组（组标题是 engine 名），组内仍是后台索引、Searchable Interfaces、Cross References 三类。`ReportNodeIdentifier` 加上 engine 标识，取消、推出、清历史作用于所在组的工作。会话没有借用时只有一组，界面与现在一样。
- **工具栏进度**：`ToolbarActivityPresenter` 合并本 engine 与借用工作的 `activityReporter`，沿用每个窗口自己的 `ActivityReportSelector` 选出要显示的那一条。App Nap 由各工作自己的 `processActivity` 负责，不需要改。
- **回到起点**：`DocumentState` 除了跟随自己 engine 的就绪状态，也跟随所借归属 engine 的；其中任何一个从「未就绪」回到「就绪」、且文档有内容打开时，回到起点。

### 9. App 里的系统镜像树

借用方 engine 收到服务进程推来的 `imageNodes` 时，把名为「Dyld Shared Cache」的那棵换成 `partition.imageRootNode`；My Mac 与 Catalyst 也一样。路径集合相同才换（防止对端推来的是另一份 cache），不同就保留对端的。侧栏的 cell view model 仍是每个文档各一份。

### 10. Developer 开关

- `Settings.Developer` 新增 `sharesSharedCacheImages: Bool`（`@Default(true)`）与 `effectiveSharesSharedCacheImages`：总开关关着时恒为 `true`，即默认行为不受影响。
- Settings › Developer 页加一行开关，说明关掉后每个 engine 各建一份，用于对比内存与排查数据差异。
- 设置层的生命周期控制器跟随这个值，写到 `RuntimeEngineManager.sharesSharedCacheImages`。
- `Settings.Developer` 是已有的顶层属性，`accessPersistedValues()` 已经读到它，新字段不需要改那里；`SettingsPersistenceTests` 照常覆盖。

### 11. 测试

- **Core**（遵守 `RuntimeViewerCore/Tests/AGENTS.md`，不碰真实派生数据）：
  - `RuntimeSharedCachePartitionTests`：在本机 cache 上断言 UIKitCore、MaterialKit 是 `.macCatalyst`，AppKit、`/System/Library/Frameworks/SwiftUI.framework`、`AuthKitUIMacHelper` 是 `.macOS`，`/System/iOSSupport` 下的 SwiftUI 是 `.macCatalyst`；不是 Apple Silicon 时跳过。
  - 路由：测试进程里两个进程内 engine，一个借用另一个；系统镜像的 `objects(in:)`、`interface`、`memberAddresses` 由归属方建 section，借用方不建；非系统镜像相反；归属 engine 是自己时不转。
  - 声明覆盖：§3 末尾的枚举测试。
  - 合并：搜索结果不重复、按路径有序、截断与摘要正确、取消能撤回两边；`relationships` 并集；父类链接上系统部分。
  - 索引管理器：遍历把系统镜像交给归属方的多根批次，剩余深度正确。
- **Packages**（遵守 `RuntimeViewerPackages/Tests/AGENTS.md`）：
  - 资格判定：在 Rosetta 下、带 `DYLD_SHARED_REGION`、Catalyst 身份的 `.remote`、`.injectedTCP`、`.file` 都不借用。
  - 接线：Catalyst engine 重启后各 engine 的借用关系换成新对象；开关关掉后全部清空。
  - 注册表：只有借用者时工作存在、不派发归属 engine 的开场批次；之后来了成员才派发；最后一个离开时关闭。
  - Always Index：没加载的系统镜像条目交给归属 engine；同名双平台镜像按 engine 平台选取。
  - Report：两个 engine 的同名节点不再冲突；组内操作作用于对应工作。
  - 加载语义：借用方 Load 之后 `isImageLoaded` 为真，目标进程的 `imageList` 不变。
- **手工验收**：附加到一个 App（如 TextEdit），开关打开与关闭各记录一次目标进程与两个 service 的内存（`leaks --forkCorpse` 抓内存图对比）和后台索引时长；My Mac 文档打开 UIKitCore；Report 分组与操作；CLI 对附加进程的 `load` 与 `interface`。

## 替代方案考量

- **只做在 App 的文档层**：由 `DocumentState` 和各 ViewModel 自己决定问哪个 engine。CLI 与 MCP 对附加进程的结果会和窗口不一致，改动也要散到四十多个调用点。用户选了 engine 层。
- **让 payload 自己去问归属 engine**：目标进程大多在沙盒里，连不到 App 内嵌的 XPC service；即使经 App 中转，也要新增反向请求的协议，并且旧 payload 全都用不上。否。
- **经派生数据在进程间共享**：沙盒里的目标进程读不到 App 的缓存目录；派生数据也只有语料，索引与交叉引用仍要重建。否。
- **给 payload 加一条报告 cache 身份的命令**：经 Mach service 注入的旧版 payload 收到不认识的命令会断开（PR121.73），附加一个旧进程就会断线。改为 App 一侧判定：dyld 按自身架构选 cache 文件，原生进程在 Apple Silicon 上都用 arm64e 那份，只需排除 Rosetta 与私有 shared region。
- **按 `/System/iOSSupport/` 路径前缀划分**：用户最初的说法。实测有 5 个例外（4 个 Catalyst 专用镜像在外面，1 个 macOS 镜像在里面），按平台划分才与 dyld 能否加载一致。用户同意按平台划分。
- **只去重后台工作，浏览仍在目标进程**：附加进程的文档点开 AppKit 时仍在目标进程里建 section，数据照旧存多份。不满足「直接用共用的数据」。否。
- **Find 只算目标进程加载了的系统镜像**：结果更贴近这个进程，但同一个查询在不同窗口结果不同，还要另定 My Mac 借来的 Catalyst 镜像算不算。用户选了全部已索引的。
- **Report 里共用的一组只读**：要取消或推出得去 My Mac 窗口。与 0055「同一 engine 的窗口共用一份 Report、操作对所有窗口生效」不一致。用户选了可以操作。
- **特化时不提供系统类型候选**：完全没有重复，但附加进程里特化自己的泛型类型时选不到 NSView 这类实参，比现在差。用户选了特化时按需索引。
- **不留开关 / 开关放在 Indexing 设置页**：前者不便对比内存和排查数据差异；后者把一个开发用的选择暴露给所有用户。用户选了放在 Developer 页。

## 影响

### 用户可见变化

- 附加进程的文档：系统镜像的内容来自 My Mac 或 Mac Catalyst，打开已被它们索引过的镜像不再等待；目标进程不再因 RuntimeViewer 多占内存和 CPU。
- 附加进程的侧栏：点系统镜像的 Load 不再把镜像加载进目标进程，而是加载进 My Mac 或 Catalyst 的 service。需要把框架真正加载进目标进程时，用 Load Frameworks…。
- My Mac 文档可以打开 UIKitCore 等 Catalyst 专用镜像。
- 附加进程的 Find、调用层级与类型引用覆盖 My Mac 与 Catalyst 已索引的全部系统镜像，可能出现目标进程没加载的框架里的结果。
- Report 在借用时按 engine 分组；工具栏进度也包括借用的工作。
- Always Index 里的系统镜像条目不再要求镜像已加载：只要有文档在适用的 engine 上，就交给归属 engine 索引。
- `runtime-viewer-cli` 对附加进程的 `load` 与查询行为随之改变，agent 插件说明同步更新。

### 可发现性

默认开启，用户不需要做任何事。Report 的分组标题说明了工作在哪个 engine 上进行。Settings › Developer 只在 Debug 构建里出现，开关供开发时对比使用。

### 数据与配置兼容

- `settings.json` 的 `developer` 分支多一个带默认值的字段，旧文件照常解码。不需要迁移。
- 派生数据、书签、Find 最近查询的键都不变。
- Always Index 条目的含义对系统镜像放宽了（见上），已有条目不需要改动；限定了 engine 的条目仍只在那些 engine 的文档打开时派发。

### 平台与最低版本

只影响 macOS 版，最低系统版本不变。只在 Apple Silicon 上启用；Intel Mac、Rosetta 下运行的 App 或目标进程维持现状。iOS、visionOS 版与越狱版不受影响。

### 发布

不需要新的权限、entitlement 或隐私清单条目，不影响公证与 Sparkle。agent 插件两份清单的 `version` 升到 `1.1.0`。发版说明要写明「附加进程里点 Load 不再加载进目标进程」。

## 落地步骤

1. **归属划分**：`RuntimeSharedCachePartition` 与 `RuntimeSharedCacheImagePlatform`，附带测试。
2. **借用关系与单镜像路由**：`RuntimeSharedCacheOwners`、`setSharedCacheOwners(_:)`、命令的三个声明与 `dispatch` 的转发、`dispatchBorrowedRequest`；加载语义（§5）；声明覆盖测试与路由测试。此时没有任何 engine 设置借用关系，行为不变。
3. **跨镜像合并与接力**：`RuntimeEngineSpanningCommand` 与各命令的合并规则，交叉引用模块的两条命令；§6 的接力与 `externalRootNames`；测试。
4. **索引管理器交出系统镜像**：多根批次、`.borrowed` reason；测试。
5. **资格判定与接线**：`RuntimeEngineManager` 的划分、资格判定、借用关系的设置与重算、`sharesSharedCacheImages`；测试。从这一步起附加进程开始借用。
6. **应用层后台工作**：注册表的借用者身份、会话的 `borrowedBackgroundWorks`、Always Index 解析、借用方协调器过滤系统镜像、特化前的按需索引、`DocumentState` 跟随归属 engine；测试。
7. **界面**：Report 按 engine 分组、工具栏进度合并、侧栏 Load 的语义、Load Frameworks… 改用 `loadImageInServingProcess(at:)`、Developer 页开关；测试。
8. **App 里共用系统镜像树**。
9. **文档**：`Documentations/CommunicationAndEngineArchitecture.md` 加一节写借用与路由；`Documentations/Guides/CommandLineInterface.md` 与 agent 插件说明写附加进程的新行为，插件升版本；根 `AGENTS.md` 的开发准则加一条「新命令要声明它关于哪个镜像，或说明为什么不转」；术语表登记「系统镜像」「归属 engine」「借用」。
10. **手工验收与测量**：按 §11 的手工验收项，结果写进本提案的决策日志。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章**：路由声明与合并规则是「从签名看不出来、下一位维护者会踩」的约定，预计要写一份实现说明；落地时再定。
- **有没有引入新术语**：系统镜像、归属 engine、借用，落地时登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-08 | Created as Draft | 用户提出系统 shared cache 的数据只存一份：My Mac 存 Catalyst 专用以外的，Mac Catalyst 只存 Catalyst 专用的，本机附加进程直接用这两份，离线模式不参与。起因是每多一个 engine 就重建一遍同样的数据，附加进程还建在目标进程里。按完整档走，经三轮澄清提问定下以下决策。 |
| 2026-11-08 | 归属按镜像平台划分，不按 `/System/iOSSupport/` 路径 | 实测路径前缀有 5 个例外，平台划分与 dyld 能否加载完全一致；用户同意 |
| 2026-11-08 | My Mac 与 Mac Catalyst 双向借用 | 用户选定。两个文档对系统镜像看到同一份数据，My Mac 文档也能打开 Catalyst 专用镜像 |
| 2026-11-08 | 附加进程的 Find、调用层级与类型引用覆盖全部已索引的系统镜像 | 用户选定。规则简单，各窗口结果一致 |
| 2026-11-08 | 附加进程的文档代为在归属 engine 上发起索引，Report 另起一组显示 | 用户选定 |
| 2026-11-08 | 侧栏的「已加载」以目标进程为准，Load 只加载进归属 engine | 用户选定。目标进程不受 RuntimeViewer 的副作用影响 |
| 2026-11-08 | 做在 engine 层，App、MCP、CLI 一起共用；CLI 插件说明同步更新并升版本 | 用户选定。三者对同一个附加进程结果一致，改动集中在 engine 与 engine 管理两处 |
| 2026-11-08 | Report 的共用组可以取消、推出、清历史，作用于归属 engine | 用户选定。沿用 0055 的规则 |
| 2026-11-08 | Always Index 的系统镜像条目按全部系统镜像解析，不论是否已加载 | 用户选定。加载只发生在 My Mac / Catalyst 的 service 里，不再有把镜像加载进目标进程的顾虑 |
| 2026-11-08 | Settings › Developer 加关掉共用的开关，默认开启 | 用户选定。便于对比内存与排查数据差异，正式版没有开关 |
| 2026-11-08 | 附加进程特化自己的泛型类型时，在目标进程里按需索引借用过的系统镜像作候选 | 用户选定。保留现有能力，这是唯一保留的重复 |
| 2026-11-08 | 退回现状的条件：资格不符、归属 engine 不在、开关关闭；归属 engine 重启时借用它的文档回到起点；特化结果所有借用窗口可见 | 收尾时用户确认的默认做法 |
| 2026-11-08 | 资格判定在 App 一侧做，不给 payload 发新命令 | 旧版经 Mach service 注入的 payload 收到不认识的命令会断开（PR121.73）。dyld 按自身架构选 cache，Apple Silicon 上原生进程都用 arm64e 那份，只需用 `sysctl` 排除 Rosetta、用环境变量排除私有 shared region |
| 2026-11-08 | Load Frameworks… 仍加载进目标进程 | 没有询问即采用的假设：选择框表达的是「加载进这个进程」，与侧栏 Load 的含义不同 |
| 2026-11-08 | 状态 → Accepted | 用户批准，开始实现；功能分支 `feature/shared-cache-images-across-engines` |

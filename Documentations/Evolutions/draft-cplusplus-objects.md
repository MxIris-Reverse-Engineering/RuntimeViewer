# Draft - C++ 对象：列出并打印从 RTTI、vtable 与符号恢复的 C++ 类与命名空间

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-21
- **所属愿景**: 无
- **关联提案**: MachOKitExtensions [0005 C++ 符号的结构化归类](https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions/blob/main/Documentations/Evolutions/0005-cplusplus-symbol-classification.md)（作用域树，3.0.0）与 [0006 从 RTTI 与 vtable 恢复 C++ 类](https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions/blob/main/Documentations/Evolutions/0006-cplusplus-class-hierarchy.md)（类、vtable 与沿基类补名，3.1.0）；后者的非目标一节写明「RuntimeViewer 等下游采用：各自另写提案」，本提案就是 RuntimeViewer 这一份
- **实现分支 / PR**: `feature/cplusplus-objects`，从 `next` 切出，worktree 在 `.worktrees/RuntimeViewer-CPlusPlusObjects`
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接
- **网页版**: 同目录同名的 `.html`

## 摘要

RuntimeViewer 新增第三种对象语言：C++。镜像的对象列表在 Objective-C、Swift 之外列出 C++ 的**类**与**命名空间**，嵌套的作为子项。类有两个来源，按限定名合并：MachOKitExtensions 3.1.0 的 `CPlusPlusClassIndexStore` 读 RTTI（Itanium C++ ABI 的运行时类型信息）与 vtable（虚函数表），符号被剥离的类也找得到；3.0.0 起的 `CPlusPlusSymbolIndexStore` 按作用域归类镜像的 C++ 符号，给出看得出是类型的作用域与命名空间。内容区把一个类打印成伪头文件：基类、按槽位排列的虚函数（自己没名字的沿基类补名，并标出是覆盖还是继承）、非虚成员函数与变量，槽位号与地址写在注释里；命名空间打印其中的自由函数与变量。点基类名跳到基类（基类在别的镜像也行），Inspector 显示主基类链与本镜像里的派生类，Filter Scope 多一组 C++，图标是绿色的 `C` 与 `N`。C++ 对象只发给声明要它的请求方：`objectsInImage` 命令加一个可选字段，旧版对端跳过它、照旧只回 ObjC 与 Swift，所以旧版对端不会收到解不开的新种类；本版里也只有侧栏、路径栏与镜像页去要，Find、导出、MCP、CLI 都看不到 C++ 对象，它们以后各自另写提案。

## 动机

- **RuntimeViewer 现在对 C++ 一无所知。** 对象种类只有 C、Objective-C、Swift 三支（`RuntimeViewerCore/Sources/RuntimeViewerCore/Objects/RuntimeObjectKind.swift`），其中 C 的结构体与联合体只来自 ObjC 类型编码（`Sections/ObjC/RuntimeObjCSection.swift:99-105`）。整个仓库没有任何地方 demangle C++ 名字：交叉引用只给 Swift 符号还原名字，`__ZN…` 原样显示（`RuntimeViewerCrossReferences/Analysis/CrossReferenceNaming.swift:17-28`），函数语言把 C 与 C++ 并成一类 `cOrCPlusPlus`（`Models/RuntimeFunctionLanguage.swift:5-25`）。
- **C++ 写的镜像在侧栏里几乎是空的。** MachOKitExtensions 的普查（`Documentations/Internal/CPlusPlusClasses.md`，2026-11-20，macOS 27.2）：
  - 系统的 Espresso 有 4,379 个带 RTTI 的类，其中 643 个没有任何 typeinfo 符号，3,506 张 vtable、56,204 个槽位；
  - iWork 14.5 的 TSTables 有 611 个类（167 个无符号）、12,518 个槽位，其中 1,520 个槽位的名字只能沿基类补回（基类多在另一个镜像 TSPersistence 的 `google::protobuf::Message` 里）。
  这些类在 RuntimeViewer 里现在看不到，逆向它们只能另开 IDA。
- **上游能力已经就绪，且按 RuntimeViewer 的需要做了跨镜像。** 0006 的补名在进程内的镜像上去进程里找基类、在 dyld shared cache 里的镜像上去同一个 cache 里找、独立文件按调用方给的依赖搜索路径找——正好对应 RuntimeViewer 的三种读法（进程内的 My Mac 与注入进程、文件模式读 cache、文件模式读独立文件）。

## 前期调研

### 现状代码怎么走的

**对象种类与它穿过的边界**

- `RuntimeObjectKind` 是自动合成 `Codable` 的枚举，三支 `.c(C)`、`.objc(ObjectiveC)`、`.swift(Swift)`；同一文件里的 `level`（排序）、`allCases`、`description`、`isC` / `isObjC` / `isSwift` 都按三支写（`Objects/RuntimeObjectKind.swift`）。
- `RuntimeObject` 过 XPC 与 TCP（`Objects/RuntimeObject.swift:128`），存在派生数据的语料快照里（`Search/Corpus/RuntimeInterfaceCorpusSnapshot.swift:246`），存在书签里（`Bookmarks/RuntimeObjectBookmark.swift:9`）。合成的解码遇到不认识的 case 会抛错，所以**旧版本收到一个带新种类的对象就解不开**。
- 两处持久化已经容错：
  - Filter Scope 的记忆存「被排除的种类」，逐条宽松解码，新种类在旧记忆里不在排除之列、照常显示（`RuntimeViewerAppCore/Sidebar/RuntimeObject/RuntimeObjectScope.swift:260-318`）；
  - 书签由 `@ResilientFileStorage` 存，单条解不开只丢那一条并记日志（`RuntimeViewerAppCore/Storage/ResilientFileStorage.swift`）。
- 语料快照按产出数据的代码分目录（`Documentations/DerivedData.md`），旧版本不会读新版本写的快照；何况本提案不把 C++ 放进语料。

**对象列表从哪来**

- 请求链：`RuntimeEngine.objects(in:)` / `objectsWithProgress(in:)`（`Engine/RuntimeEngine.swift:1364-1386`）→ `foregroundObjects` → `dispatch(ObjectsInImageCommand(image:))`（`Engine/RuntimeEngine+Commands.swift:151-164`）→ 本地臂 `_objects(in:)`（`:831-843`）或带进度的 `_localObjectsWithProgress`（`:1452-1475`），后者依次调 ObjC 与 Swift 两个 section 工厂的 `section(for:)` 与 `allObjects()`，返回 `objcObjects + swiftObjects`。
- 两个工厂只在 `Images/RuntimeImageIndex.swift:24-37` 一处建好，泛型于读取策略 `Catalog.Reading`；引擎按协议持有它们（`RuntimeObjCSectionProviding`、`RuntimeSwiftSectionProviding`）。
- 手工同时调两个工厂的地方还有：`removeAllSections`（`RuntimeEngine.swift:604-605`）、`_loadImage`（`:1313-1314`）、后台索引（`BackgroundIndexing/RuntimeEngine+BackgroundIndexing.swift:12-13, 66-67`，`_isImageIndexed` 要求两个 section 都已缓存）、语料打印（`Search/RuntimeEngine+Search.swift:280-321`）。
- App 里调 `objects(in:)` / `objectsWithProgress(in:)` 的：侧栏对象列表（`RuntimeViewerAppCore/Sidebar/RuntimeObject/SidebarRuntimeObjectListViewModel.swift:250, 267`，Open Quickly 用同一份列表）、路径栏（`RuntimeViewerAppUI/EditorArea/JumpBar/EditorJumpBarItemStore.swift:315`）、镜像页（`RuntimeViewerAppCore/Content/ContentImageViewModel.swift:108, 186-201`，按种类数对象）、命名词云（`NamingWordCloud/NamingWordCloudViewModel.swift:308`）、导出配置（`Exporting/ExportingConfigurationViewModel.swift:61`）、后台索引（`BackgroundWork/Indexing/RuntimeEngine+ImageIndexing.swift:16, 28`）、MCP（`RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPBridgeServer.swift` 七处）、CLI（`RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Execution/CommandExecutor.swift:552`）。

**读取器类型**

- 进程内（My Mac 的 local service、注入进程、框架实例、Catalyst）用 `RuntimeLoadedImageReading`，`MachO` 是 `MachOImage`（`Images/RuntimeLoadedImageReading.swift:18-19`，目录 `RuntimeProcessImageCatalog`）；文件模式（独立文件、bundle、文件夹、dyld shared cache）用 `RuntimeFileImageReading`，`MachO` 是 `MachOFile`（`Images/RuntimeFileImageReading.swift:14-15`，目录 `RuntimeFileImageCatalog`，cache 以 `FullDyldCache` 打开，`RuntimeFileImageCatalog.swift:125-150, 363`）。
- `MachOImage`、`MachOFile` 都遵循 MachOKitExtensions 的 `MachORepresentableWithCache`（`MachOKitExtensions/Sources/Core/MachOKitExtensions/MachORepresentableWithCache.swift:64, 131`），这是两个 C++ store 的方法要的类型。`RuntimeImageReading.MachO` 现在约束为 `MachOFieldLayoutRenderable & ObjCMetadataSource & Sendable`（`Images/RuntimeImageReading.swift:16`），是否已经蕴含 `MachORepresentableWithCache` 在第 1 步编译时核对，不蕴含就把它加进约束。
- 目录已经回答「按名字找定义它的镜像」与「依赖搜索路径」：`image(definingObjCType:)`（进程内 `RuntimeProcessImageCatalog.swift:44-47` 走 `MachOImage.image(forName:)`，文件模式 `RuntimeFileImageCatalog.swift:260-269` 查各镜像的导出表）、`dependencySearchPaths(forImageAt:)`（进程内恒为 `[.systemDyldSharedCache]`，`RuntimeProcessImageCatalog.swift:62-64`）。

**界面怎么分派、怎么上色、怎么跳转**

- `_interface(for:options:resolvesReferencesAcrossImages:)`（`Engine/RuntimeEngine.swift:846-891`）按种类分派：`.swift` 去 Swift section，`.c, .objc` 去 ObjC section；`.objc(.type)` 在本镜像找不到时经 `objcSectionFactory.section(for: RuntimeObjCName)` 去定义它的镜像找。
- `RuntimeObjectInterface.interfaceString` 是 `FrozenSemanticString`（`Interfaces/RuntimeObjectInterface.swift:17, 35-49`）。颜色完全由 `SemanticType` 决定（`standard`、`comment`、`keyword`、`type(TypeKind, Context)`、`member`、`function` 等，swift-semantic-string 的 `Sources/Semantic/SemanticType.swift`；映射在 `RuntimeViewerUsingAppKit/…/Content/SourceEditorThemeConversion.swift:73-90` 与 `RuntimeViewerAppUI/Theme/ThemePreset+ThemeProfile.swift:79-110`），没有按语言的着色。
- 跳转：ObjC 与 C 的界面按 `.type` 记号的文字建链接，目标种类由 `ContentInterface.linkTargetKind(of:in:)` 按对象种类决定（`RuntimeViewerAppCore/Content/ContentInterface.swift:141-220`），目标对象的 `imagePath` 是当前镜像，引擎在本镜像找不到时自己去别的镜像找。
- SourceEditor 面板把语言标识交给桥接（`ContentSourceEditorViewController.swift:437-445`，现在只有 `"swift"`、`"objc"`）；桥接只认这两个，别的标识返回 `nil`，即「不用框架自己的解析着色」，语义区间照样上色（`RuntimeViewerSourceEditorBridge/SourceEditorBridge.swift:642-649`）。
- `RuntimeInterfaceLanguage` 是字符串（`occ`、`swift`），刻意做成旧对端也解得开的开放集合（`Interfaces/RuntimeInterfaceLanguage.swift`）。
- 生成选项里离 C++ 最近的地址开关是 ObjC 的 `addMethodIMPAddressComments`（MachOObjCSection `ObjCDeclarationRendering/ObjCGenerationOptions.swift:30`），Swift 的是 `printMemberAddress`（`Interfaces/SwiftGenerationOptions.swift:45`）。

**侧栏、图标、Inspector**

- Filter Scope 的种类分组 `RuntimeObjectScope.KindGroup`（`c`、`objectiveC`、`swift`，`RuntimeObjectScope.swift:95-126`），弹窗每组一行（`RuntimeViewerUsingAppKit/…/Sidebar/RuntimeObject/SidebarRuntimeObjectScopeViewController.swift:30-33, 619-627`）。
- 图标：`RuntimeObjectIcon.glyphContent(for:)`（`RuntimeViewerAppCore/RuntimeObject/RuntimeObjectIcon.swift:57-85`）按种类给字母与颜色，C 的结构体与联合体是绿色 `S` / `U`，不认识的种类落到灰色 `?`。Find 结果里 C/C++ 函数的徽标也是绿色（`Find/Results/FindResultNode+Icon.swift:84-88`）。
- Inspector：页签由 `InspectorRuntimeObjectCoordinator.TabConfiguration.compute(for:)` 按种类定（`RuntimeViewerUsingAppKit/…/Inspector/InspectorRuntimeObjectCoordinator.swift:312-336`）；层级页对非协议一律当「类与它的父类链」画（`InspectorHierarchyViewModel.swift:144-158`），父类链来自 `superclassChain(for:)`，对端不支持时退回 `hierarchy(for:)` 的名字；关系页对类显示 `RuntimeRelationships.subclasses`（`InspectorRelationshipsViewModel.swift:156-180`）。`_hierarchy` 对 `.c` 返回空（`RuntimeEngine.swift:1481-1490`）。

**线上兼容的规矩**（`Documentations/CommunicationAndEngineArchitecture.md` §4.4）

- 改已有命令的形状：请求加可选字段，旧对端解码时跳过；只有请求方声明读得懂才发新形状；配冻结的旧请求、旧读端测试，JSON 与 SwiftyXPC 的 `XPCEncoder` 两条编码都覆盖，经新版中转也要跑。已有四例：列式接口字符串、进度信封的 `requestIdentifier`、接口语言、加载失败的诊断。
- 新增命令：旧对端经 socket 回 `No handler registered for …`；但**经 Mach service 的旧版注入 payload 会把不认识的命令当成客户端离开、断开连接**（PR121.73，`Documentations/KnownIssues/2026-10-07-pr121-review-findings.md`）。所以 Generated Interface 没有加新命令，加载诊断的新命令只发给同一次构建内嵌的进程。

### 上游的能力（MachOKitExtensions 3.1.0，tag `3.1.0` = `0e6be27`）

- `CPlusPlusSymbolIndexStore.shared`（3.0.0 起）：`childScopes(of:in:)`、`scope(named:in:)`、`members(of:in:)`、`symbols(for:in:)`、`symbol(named:in:)`、`unparsedSymbols(in:)`、`prepare` / `contains` / `remove`。`CPlusPlusScope` 有 `path`、`baseName`、`name`、`qualifiedName`、`kind`（`namespace` / `type` / `function` / `undetermined`）与 `evidence`；`CPlusPlusScope.global` 是全局命名空间。`CPlusPlusSymbol` 是 `symbol`（含偏移）加 `CPlusPlusSymbolName`。
- `CPlusPlusSymbolName`：`demangledName`、`kind`（function、constructor、destructor、variable、virtualTable、typeInfo、typeInfoName、各种 thunk、guardVariable……）、`scopePath`、`baseName`、`templateArguments`、`parameters`、`returnType`、`functionQualifiers`（const、volatile、`&`、`&&`）、`constructorOrDestructorVariant`、`suffix`。**返回类型只有函数模板特化的修饰名里有**（`returnType` 的文档注释），所以大多数函数打印不出返回类型；修饰名也不区分静态与非静态成员函数，不记录访问级别。
- `CPlusPlusClassIndexStore.shared`（3.1.0）：`classes(in:)`、`class(named:in:)`、`class(atTypeInfoOffset:in:)`、`derivedClasses(of:in:)`、`virtualTables(of:in:)`，以及给独立文件的 `virtualTables(of:in:dependencySearchPaths:)`。`CPlusPlusClass` 有 `qualifiedName`（与作用域树同一格式）、`scopePath`、`baseName`、`mangledTypeName`、`typeInfoOffset`、`bases`（`qualifiedName`、`mangledTypeName`、`isVirtual`、`isPublic`、`offset`、`location`：同镜像的 typeinfo 偏移或别的镜像的 install name）、`inheritanceShape`、`hasVirtualTable`、`hasTypeInfoSymbol`、`hasUniqueTypeInfo`。`CPlusPlusVirtualTable` 有 `addressPointOffset`、`offsetToTop`、`subobjectClassName`、`functions`；`CPlusPlusVirtualFunction` 有 `slotIndex`、`implementation`（本镜像偏移 / 导入的符号 / 别的镜像的地址 / 纯虚 / deleted）、`symbolName`、`baseFunction`（基类名、名字、`isInherited`），`name` 取自己的名字、没有就取基类的。
- 实测耗时（debug 构建，Ultra）：作用域树 JavaScriptCore 约 0.15 秒（release）、debug 约 1 秒；类索引 Espresso 进程内 0.29 秒、给每个类每个槽位取名 2.2 秒，从本机 cache 文件读 8.0 秒与 9.7 秒（cache 读法慢约 10 倍，上游列为后续项）；TSTables 建索引 2.2 秒、补名 1.1 秒（`CPlusPlusClasses.md`「普查」、`CPlusPlusSymbols.md`「内存与耗时」）。作用域树常驻：JavaScriptCore 进程内约 0.7 MB、cache 文件约 4.7 MB。
- 已知局限（`CPlusPlusClasses.md`「已知局限」）：有虚基类、无 `__ZTV` 符号、找到多组表时可能取到别的类的 construction vtable；基类的基类里的虚基类不展开；种类与名字都是推出来的，`baseFunction` 以后可能从 `nil` 变成有值。WebKit 编译时关了 RTTI，JavaScriptCore 没有类，只有作用域树。
- 依赖：`CPlusPlusSymbols` 依赖 C++ target `CPlusPlusDemangling`（从 libc++abi 引入的 LLVM `ItaniumDemangle`），对 Swift 只露 C 接口，下游不用开 C++ 互操作。包的平台下限 macOS 10.15、iOS 13、watchOS 6、tvOS 13、visionOS 1，与 RuntimeViewerCore 一致。
- 版本：RuntimeViewerCore 现在写 `from: "3.0.0"`，各锁文件钉 3.0.0（`516288d8`）；MachOSwiftSection 与 MachOObjCSection 的 `next` 对本包都是 `from:` 下限，3.1.0 纯新增，不影响它们。Tuist 的 `Tuist.swift` 已经列着 `CPlusPlusDemangling`、`CPlusPlusSymbols` 两个 target（`:63-64`）。

### 前人怎么做的

- IDA 的 ClassInformer 一类工具把 RTTI 恢复成「类 + 每张 vtable 逐格列出」的报告；Xcode 与 clang 生成的头文件是声明的形状。本提案的界面取后者（伪头文件），与 ObjC、Swift 的界面一致，用户在澄清提问里选定。

## 提议方案

1. **新对象种类 `RuntimeObjectKind.cPlusPlus(CPlusPlus)`**，两个子种类 `.class`（「C++ Class」，结构体与类在修饰名里分不开，一律叫类）与 `.namespace`（「C++ Namespace」），排在 Swift 之后。新界面语言 `RuntimeInterfaceLanguage.cPlusPlus`，原文 `"cpp"`。
2. **每个镜像一个 C++ section，由第三个工厂按需建。** `RuntimeCPlusPlusSection<Reading>`（actor）在建成时读作用域树与类索引、做好对象树；`RuntimeCPlusPlusSectionFactory<Reading>` 照 ObjC 工厂的形状按镜像缓存、合并同一镜像的并发构建（`RuntimeSectionBuild`）、`removeAllSections()` 时一并让两个上游 store 丢掉这个镜像。**C++ section 不属于「已索引」**：后台索引、语料、`_isImageIndexed` 都不碰它，第一次有人要 C++ 对象时才建，所以不给每个镜像的索引增加任何开销。
3. **对象树怎么建。**
   - 作用域树里 `kind == .type` 的作用域，以及类索引里的每个类（按 `qualifiedName` 合并到同名作用域上），都是 `.cPlusPlus(.class)`；
   - `kind == .namespace` 与 `.undetermined` 的作用域是 `.cPlusPlus(.namespace)`（「未定」只有自由函数一类的成员，形状与命名空间相同，界面里注明种类未定）；
   - `kind == .function` 的作用域（函数里的局部实体与 lambda）不成对象；
   - 只有 RTTI、作用域树里没有的类，按它的 `scopePath` 挂到对应的作用域下，缺的中间层补成命名空间（父层是类时补成类）；
   - 既没有成员、也没有子对象的命名空间不列；
   - 全局命名空间里直接有自由函数或变量时，列一个名为 `::`、显示为「Global Namespace」的命名空间对象；
   - `name` 是限定名（全局对象是 `::`），`displayName` 是最后一段（`vector<int, std::__1::allocator<int>>`），嵌套的作用域与类放进 `children`；同一镜像里同名的隐藏类（不同编译单元）只留 typeinfo 偏移最小的那个，与上游 `class(named:in:)` 一致。
4. **C++ 对象只发给要它的请求方。** `ObjectsInImageCommand` 加可选字段 `includesCPlusPlusObjects: Bool?`，为 `nil` 时不编码；服务端只在它为 `true` 时建 C++ section 并把 C++ 对象接在 ObjC、Swift 之后。公开 API 是 `objects(in:includesCPlusPlusObjects:)` 与 `objectsWithProgress(in:includesCPlusPlusObjects:)`，默认 `false`。
   - 旧请求方（旧版 App 连本版 payload）不带字段，收到的回复与以前逐字节相同；
   - 本版请求方连旧版对端，对端跳过字段、照旧只回 ObjC 与 Swift，App 只是看不到 C++ 对象，不加新命令，所以没有 PR121.73 的断线风险；
   - C++ 对象的界面、层级、关系请求只会发给列出过 C++ 对象的对端，也就是本版对端。
   - 本版里传 `true` 的只有侧栏对象列表（含 Open Quickly）、路径栏与镜像页；Find、导出、命名词云、MCP、CLI、后台索引照旧传默认值。
5. **进度。** `RuntimeObjectsLoadingProgress.Phase` 加 `indexingCPlusPlusSymbols` 与 `indexingCPlusPlusClasses` 两个阶段，只在请求带了字段时发出，旧请求方永远收不到这两个新 case。
6. **界面打印：伪头文件。** 内部类型 `CPlusPlusInterfacePrinter` 用 swift-semantic-string 的组件拼 `SemanticString`：
   - 类：头部注释（镜像名；typeinfo 与主 vtable 的地址；只有 RTTI 没有符号的类注明「只从运行时类型信息恢复」）；`class 限定名 : 基类列表 {`，基类带 `virtual` 与 `public`；RTTI 只区分 public 与否，非 public 的基类写成 `/* not public */ 基类`，不猜是 `private` 还是 `protected`；然后依次是每张 vtable 的虚函数（主表在前，副表注明属于哪个基类子对象与 offset-to-top）、非虚的成员函数（构造函数在前）、变量、嵌套类型的前置声明。
   - 虚函数一槽一行：`virtual 名字(参数) 限定;`，纯虚加 ` = 0`，deleted 加 ` = delete`；注释里是槽位号、实现地址，以及「overrides 基类」或「inherited from 基类」；自己没名字、基类也补不回的槽位写 `virtual /* unnamed */;`。虚析构的两个槽合成一行（`slots 0–1`）。
   - 构造与析构的各个变体（C1/C2、D0/D1/D2）合成一行，注释里列出各自的地址；已经作为虚函数打印过的实现不在「成员函数」里重复；thunk、vtable、VTT、typeinfo、typeinfo 名字、守护变量这些元数据符号不打印成成员。
   - 返回类型只在修饰名带着时打印；不写 `static`、不写访问级别（修饰名里没有，不猜）。
   - 命名空间：`namespace 限定名 {`，依次是自由函数、变量、子命名空间与类的前置声明；未定种类的作用域在头部注释里说明。
   - 地址注释跟随生成选项里的 `addMethodIMPAddressComments`（ObjC 头文件的同一个开关；C++ 与它同是头文件，不为 C++ 另加选项）；地址的口径与 ObjC 的 IMP 地址注释相同。槽位号与「overrides / inherited」不受开关影响。
   - 语义类型：`class`、`namespace`、`virtual`、`const`、`delete` 是 `keyword`；类名在声明处是 `type(.class, .declaration)`，基类与前置声明里的类是 `type(.class, .name)`，命名空间名是 `type(.other, …)`；函数名是 `function(.declaration)`、变量名是 `member(.declaration)`；参数串是 `standard`；注释是 `comment`。这些记号里的类名与命名空间名一律写完整限定名，供跳转按文字查找。
7. **跳转与跨镜像找类。** `ContentInterface.linkTargetKind` 对 C++ 对象把 `type(.class, _)` 映射到 `.cPlusPlus(.class)`、`type(.other, _)` 映射到 `.cPlusPlus(.namespace)`，目标对象的 `imagePath` 是当前镜像（与 ObjC 相同）。引擎的 `_interface` 加 C++ 臂：在对象的镜像里按限定名找；找不到时，问这个镜像的 section 它是不是某个类的基类、要到基类的修饰名，再经目录的新方法 `image(definingCPlusPlusTypeInfoForMangledTypeName:)` 找到定义它的镜像——进程内用 `dlsym` 找 `_ZTI<修饰名>` 再 `dladdr` 得到镜像，文件模式查各镜像的导出表找 `__ZTI<修饰名>`（与 `image(definingObjCType:)` 同一写法）。非唯一 RTTI（每个镜像各留一份隐藏副本）的类型没有导出的 typeinfo，找不到就不跳。参数串里的类型不建链接。
8. **补名用的依赖搜索路径。** 文件模式的独立文件调 `virtualTables(of:in:dependencySearchPaths:)`，路径取目录的 `dependencySearchPaths(forImageAt:)`，`@rpath` 指向的兄弟框架照文件模式已有的规则找；进程内与 cache 里的镜像调不带路径的重载。
9. **Inspector。** C++ 类有层级页与关系页：
   - 层级是主基类链（每层取第一个偏移为 0、非虚的基类，与上游补名用的主基类相同），基类在别的镜像就按第 7 条找到那个镜像再往上走；`hierarchy(for:)` 给名字，`superclassChain(for:)` 给能跳转的对象；
   - 关系页的标题是「Derived Classes」，内容是本镜像里直接派生自它的类（`derivedClasses(of:in:)`）；别的镜像里的派生类不找。
   - 多重继承的其余基类只在界面头部列出。
10. **App 一侧。** Filter Scope 加 C++ 一组（类、命名空间两个勾选项）；图标是绿色的 `C`（类）与 `N`（命名空间），与 C 的结构体、Find 里 C/C++ 函数的绿色同属 C 家族；SourceEditor 面板对 C++ 传 `"cpp"`，桥接不认识它，只按语义区间上色；内容的文件类型是 `UTType.cPlusPlusHeader`，分享与拖出时扩展名 `hpp`；镜像页的按种类计数带上 C++。
11. **依赖。** RuntimeViewerCore 的 MachOKitExtensions 下限改为 `from: "3.1.0"`，`RuntimeViewerCore` target 加 `CPlusPlusSymbols` product；用 `UpdatePackagesScript.sh` 更新三个 workspace 与各包的锁文件，只让 MachOKitExtensions 移到 3.1.0（其余依赖若一并移动，逐个核对后再提交）。

### 非目标

- **Find**：C++ 对象不进文本语料与成员搜索，`RuntimeMemberKind` 不加 C++ 成员；以后另写提案（要改语料快照的成员种类表与成员定位器的按语言规则）。
- **导出**：批量导出与单个导出都不含 C++ 对象。
- **MCP 与 CLI**：两者照旧只列 ObjC 与 Swift。
- **交叉引用**：C++ 对象没有成员地址（`memberAddresses` 返回空），所以 Callers / Callees / Type References 不提供给 C++；`RuntimeFunctionLanguage` 仍把 C 与 C++ 并成一类，交叉引用里的 C++ 名字仍不 demangle。
- **命名词云**不数 C++ 名字。
- **派生数据**不存 C++ 的任何东西，每次启动重建。
- **字段**：RTTI 与 vtable 不带字段，类不打印数据成员（变量只来自符号表里的静态数据）；protobuf 描述符还原是上游之后的提案。
- **参数里的类型跳转**、返回类型、`static` 与访问级别的推断。
- **函数作用域里的局部实体**（`kind == .function` 的作用域）。
- **别的镜像里的派生类**、跨 owner 合并 C++ 的层级（借用 shared cache 镜像的 engine 上，C++ 的层级只在镜像的主人那里求）。
- **SourceEditor 的 C++ 语言**：重建版 SourceEditor 有没有 C++ 的 SourceModel 语言，要读它的源码才能定（`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`），本提案不接。
- **注释标签**：C++ 界面不标注释结构（`marksCommentStructure` 对它不起作用），注释以普通注释显示。
- **新的 `RuntimeObject.Properties` 位**（例如「只从 RTTI 恢复」）：本提案不加，界面头部的注释已经说明；加位要同时加 Filter Scope 的行（`AGENTS.md` 开发规则第 9 条），以后需要时另议。
- **MachOKitExtensions 之外的 C++ 来源**（ObjC ivar 编码里的 C++ 结构体）。

## 改动地图

路径省略公共前缀：Core 指 `RuntimeViewerCore/Sources/RuntimeViewerCore/`，AppCore、AppUI 指 `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/`、`…/RuntimeViewerAppUI/`，App 指 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| `RuntimeViewerCore/Package.swift` | 修改 | MachOKitExtensions 下限 `from: "3.1.0"`，注释写明为了 `CPlusPlusClassIndexStore`；`RuntimeViewerCore` target 加 `.product(name: "CPlusPlusSymbols", package: "MachOKitExtensions")` | 方案第 11 条 | 1 |
| 各 `Package.resolved`（三个 workspace、`RuntimeViewerCore`、`RuntimeViewerPackages`、`RuntimeViewerCommandLine`） | 修改 | MachOKitExtensions 移到 3.1.0 | 同上 | 1 |
| Core `Objects/RuntimeObjectKind.swift` · `RuntimeObjectKind`、新的嵌套 `CPlusPlus` | 修改 | 加 `.cPlusPlus(CPlusPlus)`，`level` 21–22、`allCases`、`description`（`C++ Class`、`C++ Namespace`）、`isCPlusPlus` | 方案第 1 条 | 1 |
| Core `Interfaces/RuntimeInterfaceLanguage.swift` | 修改 | 加 `static let cPlusPlus = RuntimeInterfaceLanguage(rawValue: "cpp")` | 方案第 1 条 | 1 |
| Core 里穷举 `RuntimeObjectKind` 的各处：`Engine/RuntimeEngine.swift`（`_interface`、`_imageName(ofObjectName:)`、`_hierarchy`、`_memberAddresses`）、`Objects/RuntimeObject+GeneratedInterface.swift`、`Objects/RuntimeObject+CounterpartKind.swift`、`SharedCache/RuntimeEngine+SharedCacheRelays.swift`、`Search/RuntimeEngine+Search.swift`、`Search/Matching/*`、`Export/*`、`Relationships/*` | 修改 | 第 1 步只补让它编过、行为不变的臂（C++ 走「无」的分支：没有生成界面、没有对应面、不进语料、导出按头文件）；`_interface`、`_hierarchy` 的真实 C++ 臂在第 3、4 步 | 新 case 让穷举 switch 编不过 | 1 |
| `RuntimeViewerCore/Sources/RuntimeViewerCrossReferences/` 里穷举种类的三处（`Analysis/CrossReferenceQuery.swift`、`Analysis/FunctionReferenceBuilder.swift`、`Models/RuntimeFunctionReference.swift`） | 修改 | 补臂，C++ 不是可查引用的类型 | 同上 | 1 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusSectionCostProbeTests.swift` | 新增（临时） | 在 release 下测进程内与 cache 文件两种读法建 Espresso、libc++ 的作用域树与类索引的耗时；结论写进本提案后删掉 | 方案第 2 条按需建的前提 | 1 |
| Core `Sections/CPlusPlus/RuntimeCPlusPlusSection.swift` · `RuntimeCPlusPlusSection<Reading>`（actor） | 新增 | 建对象树（方案第 3 条）、按限定名查类或命名空间、给出基类的修饰名、打印界面、层级与派生类 | 方案第 2、3 条 | 2、3、4 |
| Core `Sections/CPlusPlus/RuntimeCPlusPlusSectionFactory.swift` · `RuntimeCPlusPlusSectionFactory<Reading>`（actor） | 新增 | 按镜像缓存、`RuntimeSectionBuild` 合并构建、`existingSection`、`section(for:progressContinuation:)`、`section(definingClassWithMangledTypeName:)`、`removeAllSections()`（同时调两个上游 store 的 `remove(for:)`） | 方案第 2、7 条 | 2、3 |
| Core `Sections/CPlusPlus/CPlusPlusObjectTreeBuilder.swift` · `CPlusPlusObjectTreeBuilder`（internal） | 新增 | 把作用域树与类索引合成 `[RuntimeObject]`；与 section 分开，单元测试直接喂作用域与类 | 方案第 3 条，规则多、要单测 | 2 |
| Core `Sections/CPlusPlus/CPlusPlusInterfacePrinter.swift` · `CPlusPlusInterfacePrinter`（internal） | 新增 | 方案第 6 条的打印规则 | 方案第 6 条 | 3 |
| Core `Sections/RuntimeCPlusPlusSectionProviding.swift`、`Sections/RuntimeCPlusPlusSectioning.swift` | 新增 | 引擎持有工厂与 section 用的协议，照 ObjC 的两份 | 引擎不依赖具体读取器 | 2 |
| Core `Images/RuntimeImageIndex.swift` | 修改 | 建第三个工厂并交给关系解析器 | 唯一的装配点 | 2 |
| Core `Images/RuntimeImageCatalog.swift`（协议）、`RuntimeProcessImageCatalog.swift`、`RuntimeFileImageCatalog.swift`，以及框架实例的目录 | 修改 | 加 `image(definingCPlusPlusTypeInfoForMangledTypeName:)`：进程内 `dlsym` + `dladdr`，文件模式查导出表并缓存结果 | 方案第 7 条 | 3 |
| Core `Images/RuntimeImageReading.swift` | 修改（视编译结果） | `MachO` 约束不蕴含 `MachORepresentableWithCache` 时加上 | 上游 store 的方法要它 | 1 |
| Core `Engine/RuntimeEngine.swift` | 修改 | 持有 `cPlusPlusSectionFactory`；`_objects` 与 `_localObjectsWithProgress` 带 `includesCPlusPlusObjects`；`removeAllSections` 加第三个；`_interface`、`_hierarchy` 的 C++ 臂；公开的 `objects(in:includesCPlusPlusObjects:)`、`objectsWithProgress(in:includesCPlusPlusObjects:)` | 方案第 4、7、9 条 | 2、3、4 |
| Core `Engine/RuntimeEngine+Commands.swift` · `ObjectsInImageCommand` | 修改 | 加 `let includesCPlusPlusObjects: Bool?`，两个 `perform` 都传下去 | 方案第 4 条 | 2 |
| Core `Objects/RuntimeObjectsLoadingProgress.swift` | 修改 | 加两个阶段与描述文字，注释写明只对声明了字段的请求发出 | 方案第 5 条 | 2 |
| Core `Relationships/RuntimeRelationshipNode.swift`、`RuntimeRelationshipsResolver.swift`、`RuntimeTypeRelationshipsResolver.swift` | 修改 | `TypeKind` 把 `.cPlusPlus(.class)` 认成 `class`；关系解析器给 C++ 类返回派生类；类型关系解析器的 `superclassChain` 给 C++ 走主基类链 | 方案第 9 条 | 4 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusObjectTreeBuilderTests.swift` | 新增 | 第 2 步的建树规则（编造的作用域与类） | 第 2 步行为 | 2 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusSectionTests.swift` | 新增 | 本进程的 `/usr/lib/libc++abi.dylib`（`std::exception`、`std::bad_alloc`、`std::bad_array_new_length`）上的对象、界面、层级，进程内与本机 cache 文件两种读法各跑一遍 | 第 2–4 步行为 | 2、3、4 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/ObjectsInImageCPlusPlusWireTests.swift` | 新增 | 冻结的旧请求、旧服务端；经新版中转；JSON 与 `XPCEncoder` 两种编码 | §4.4 的兼容规矩 | 2 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusInterfacePrinterTests.swift` | 新增 | 打印规则在编造的类、表、槽位上的单元测试 | 第 3 步行为 | 3 |
| `SharedCacheRoutingDeclarationTests` | 不变（核对） | 不加命令，只改字段，路由声明不变；第 2 步跑一遍确认 | Core 的路由规矩 | 2 |
| AppCore `Sidebar/RuntimeObject/SidebarRuntimeObjectListViewModel.swift` | 修改 | 两处取对象传 `includesCPlusPlusObjects: true` | 方案第 4 条 | 5 |
| AppUI `EditorArea/JumpBar/EditorJumpBarItemStore.swift` | 修改 | 取对象传 `true`；按种类分组带上 C++ | 同上 | 5 |
| AppCore `Content/ContentImageViewModel.swift` | 修改 | 三处取对象传 `true` | 镜像页的计数带 C++ | 5 |
| AppCore `Sidebar/RuntimeObject/RuntimeObjectScope.swift` · `KindGroup` | 修改 | 加 `.cPlusPlus`（标题「C++」） | 方案第 10 条 | 5 |
| App `Sidebar/RuntimeObject/SidebarRuntimeObjectScopeViewController.swift` | 修改 | 新组一行与两个种类的按钮标题 | 同上 | 5 |
| AppCore `RuntimeObject/RuntimeObjectIcon.swift` | 修改 | `.cPlusPlus(.class)` → `("C", .green)`，`.cPlusPlus(.namespace)` → `("N", .green)` | 同上 | 5 |
| AppCore `Content/ContentInterface.swift` · `linkTargetKind` | 修改 | C++ 臂（方案第 7 条） | 跳转 | 5 |
| App `Content/ContentSourceEditorViewController.swift` · `languageIdentifier` | 修改 | `.cPlusPlus` → `"cpp"` | 方案第 10 条 | 5 |
| AppCore `Main/MainViewModel.swift`、App `Main/MainWindowController.swift` | 修改 | `UTType.cPlusPlusHeader` 与扩展名 `hpp` | 同上 | 5 |
| App `Inspector/InspectorRuntimeObjectCoordinator.swift` · `TabConfiguration` | 修改 | C++ 类有层级页（父类链）与关系页 | 方案第 9 条 | 5 |
| AppCore `Inspector/InspectorRelationshipsViewModel.swift` | 修改 | C++ 类的标题「Derived Classes」、内容是 `subclasses` | 同上 | 5 |
| AppCore、AppUI、MCP、CLI 里其余穷举种类的地方（`Find/Results/FindResultNode+Icon.swift`、`Find/CrossReferences/FindCrossReferences.swift`、`NamingWordCloud/*`、`Exporting/ExportingConfigurationViewModel.swift`、`ContextMenus/*`、`EditorArea/NavigationEntry.swift`、`RuntimeViewerCommandLineInterface/Execution/TypeKindFilter+RuntimeObjectKind.swift` 等） | 修改 | 补臂，C++ 走「不提供」的分支 | 新 case 让穷举 switch 编不过 | 1、5 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/CPlusPlusPresentationTests.swift` | 新增 | Filter Scope 分组、图标、跳转目标种类、Inspector 页签与标题 | 第 5 步行为 | 5 |
| `AGENTS.md`（根） | 修改 | *Package Structure* 写上 C++ 来自 MachOKitExtensions 的 `CPlusPlusSymbols`；*Dependency floors* 写上 3.1.0 的理由 | 文档与代码同批 | 6 |
| `Documentations/CommunicationAndEngineArchitecture.md` §4.4 | 修改 | 第五例：`objectsInImage` 的 `includesCPlusPlusObjects`，以及为什么不加新命令 | 同上 | 6 |
| `README.md` | 修改 | 功能列表加 C++ 类与命名空间 | 对外说明 | 6 |
| `Documentations/Evolutions/README.md`、`Documentations/README.md` | 修改 | 登记本提案（写提案时已登记）；落地时按需登记实现说明 | 索引 | 6 |

## 架构图

改了什么：

```text
MachOKitExtensions 3.1.0 (package, floor 3.0.0 -> 3.1.0)
  CPlusPlusSymbols  (product)         CPlusPlusSymbolIndexStore (scopes), CPlusPlusClassIndexStore (RTTI, vtables)

RuntimeViewerCore
  Objects/RuntimeObjectKind           ~ + case cPlusPlus(.class | .namespace)
  Interfaces/RuntimeInterfaceLanguage ~ + .cPlusPlus ("cpp")
  Images/RuntimeImageIndex            ~ builds a third factory
  Images/*ImageCatalog                ~ + image(definingCPlusPlusTypeInfoForMangledTypeName:)
  Sections/ObjC/                        RuntimeObjCSectionFactory, RuntimeObjCSection      (unchanged)
  Sections/Swift/                       RuntimeSwiftSectionFactory, RuntimeSwiftSection    (unchanged)
+ Sections/CPlusPlus/
+   RuntimeCPlusPlusSectionFactory<Reading>   per-image cache, built on demand only
+   RuntimeCPlusPlusSection<Reading>          object tree, interface, hierarchy, derived classes
+   CPlusPlusObjectTreeBuilder                scopes + classes -> [RuntimeObject]
+   CPlusPlusInterfacePrinter                 SemanticString pseudo-header
  Engine/RuntimeEngine                ~ objects(in:includesCPlusPlusObjects:), _interface / _hierarchy C++ arms
  Engine/RuntimeEngine+Commands       ~ ObjectsInImageCommand + includesCPlusPlusObjects: Bool? (omitted when nil)
  Relationships/*                     ~ C++ class: primary base chain, derived classes in its image

RuntimeViewerAppCore / AppUI / App
  Sidebar object list, jump bar, image page   ~ ask with includesCPlusPlusObjects: true
  Find, export, word cloud, MCP, CLI, indexing  (unchanged: default false, never see C++)
  RuntimeObjectScope.KindGroup        ~ + .cPlusPlus
  RuntimeObjectIcon                   ~ + green "C" / "N"
  ContentInterface.linkTargetKind     ~ + C++ arm
  ContentSourceEditorViewController   ~ "cpp" (bridge: no SourceModel language, semantic colours only)
  Inspector tabs / relationships      ~ C++ class: hierarchy + "Derived Classes"
```

一次「打开镜像」的数据流：

```text
SidebarRuntimeObjectListViewModel
 └─ engine.objectsWithProgress(in: path, includesCPlusPlusObjects: true)
     └─ dispatch(ObjectsInImageCommand(image: path, includesCPlusPlusObjects: true))
         ├─ old peer: field skipped ------------------------------> [ObjC + Swift]
         └─ this build: _localObjectsWithProgress(in:includesCPlusPlusObjects:)
             ├─ objcSectionFactory.section(for:)   -> allObjects()
             ├─ swiftSectionFactory.section(for:)  -> allObjects()
             └─ cPlusPlusSectionFactory.section(for:)                 (only when true)
                 └─ RuntimeCPlusPlusSection.init
                     ├─ CPlusPlusSymbolIndexStore.shared   scope tree       (progress: indexingCPlusPlusSymbols)
                     ├─ CPlusPlusClassIndexStore.shared    classes(in:)     (progress: indexingCPlusPlusClasses)
                     └─ CPlusPlusObjectTreeBuilder        -> [RuntimeObject]
             -> [ObjC + Swift + C++]
```

一次「点基类名」的数据流：

```text
ContentInterface link: RuntimeObject(name: "google::protobuf::Message", kind: .cPlusPlus(.class), imagePath: TSTables)
 └─ engine.interface(for:options:)  -> _interface C++ arm
     ├─ cPlusPlusSection(TSTables).object(named:)                         found -> print
     └─ not found: section(TSTables).mangledTypeName(ofBaseNamed:)  -> "N6google8protobuf7MessageE"
         └─ catalog.image(definingCPlusPlusTypeInfoForMangledTypeName:)
             ├─ process: dlsym("_ZTIN6google8protobuf7MessageE") + dladdr -> image path
             └─ file:    export trie "__ZTIN6google8protobuf7MessageE"     -> image path
         └─ cPlusPlusSectionFactory.section(for: that image) -> print, object.imagePath = that image
```

## 详细设计

### 种类与语言

```swift
public enum RuntimeObjectKind: Codable, Hashable, Identifiable, Comparable, CaseIterable, CustomStringConvertible, Sendable {
    // …existing C, ObjectiveC, Swift…

    /// A C++ entity an image's symbols or run-time type information show.
    /// Itanium mangling does not tell a `struct` from a `class`, so every
    /// type is a class.
    public enum CPlusPlus: Codable, Hashable, Identifiable, CaseIterable, Sendable {
        case `class`
        case namespace
        public var id: Self { self }
    }

    case c(C)
    case objc(ObjectiveC)
    case swift(Swift)
    case cPlusPlus(CPlusPlus)

    public var isCPlusPlus: Bool { if case .cPlusPlus = self { true } else { false } }
}

extension RuntimeInterfaceLanguage {
    /// A C++ declaration, as an image's symbols and run-time type information
    /// recover it.
    public static let cPlusPlus = RuntimeInterfaceLanguage(rawValue: "cpp")
}
```

`level`：`.cPlusPlus(.class)` 21，`.cPlusPlus(.namespace)` 22。

### 命令与公开 API

```swift
struct ObjectsInImageCommand: RuntimeEngineProgressCommand {
    let image: String
    /// Whether the reply may carry C++ objects. `nil` is left out of the
    /// encoding, so the request of a build before C++ objects and of a caller
    /// that does not want them is byte for byte what it was; a peer of such a
    /// build skips the key and answers Objective-C and Swift only — which is
    /// why this is a field and not a command (PR121.73).
    let includesCPlusPlusObjects: Bool?
    // commandName, subjectImagePath, isForegroundLoad, indexesSubjectImage unchanged
}

extension RuntimeEngine {
    public func objects(in image: String, includesCPlusPlusObjects: Bool = false) async throws -> [RuntimeObject]
    public func objectsWithProgress(in image: String, includesCPlusPlusObjects: Bool = false) -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>
}
```

命令把 `false` 编成 `nil`（`includesCPlusPlusObjects ? true : nil`），只有 `true` 上线。借用 shared cache 镜像的 engine 把整条命令交给镜像的主人，字段随之过去。

### 工厂、section 与协议

```swift
protocol RuntimeCPlusPlusSectionProviding: Actor {
    associatedtype Section: RuntimeCPlusPlusSectioning
    func existingSection(for imagePath: String) -> Section?
    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)
    /// The section of the image whose typeinfo for `mangledTypeName` is
    /// exported — `nil` when the catalog finds none.
    func section(definingClassWithMangledTypeName mangledTypeName: String) async throws -> Section?
    func removeAllSections()
}

protocol RuntimeCPlusPlusSectioning: Actor {
    nonisolated var imagePath: String { get }
    func allObjects() -> [RuntimeObject]
    func object(named qualifiedName: String) -> RuntimeObject?
    /// The mangled type name of a base of one of this image's classes,
    /// by its qualified name: how a jump to a base in another image starts.
    func mangledTypeName(ofBaseNamed qualifiedName: String) -> String?
    func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface
    /// Nearest first: the primary base, its primary base, … — each level's
    /// qualified name and, when this engine can read it, its object.
    func primaryBaseChain(of object: RuntimeObject) async throws -> [(qualifiedName: String, object: RuntimeObject?)]
    func derivedClasses(of object: RuntimeObject) -> [RuntimeObject]
}
```

- `RuntimeCPlusPlusSection.init(imagePath:machO:catalog:progressContinuation:)` 依次调 `CPlusPlusSymbolIndexStore.shared.prepare(in:)` 与 `CPlusPlusClassIndexStore.shared.classes(in:)`，各报一个阶段（`currentCount` / `totalCount` 只报 0/1 与 1/1：上游 store 不报进度），再交给 `CPlusPlusObjectTreeBuilder`。
- section 只存对象树、限定名 → 记录（作用域与/或类）的字典、基类限定名 → 修饰名的字典；作用域的成员与 vtable 在打印时向上游 store 取（上游各自缓存，`virtualTables` 每次补名，一个类的几十个槽位是毫秒级）。
- `removeAllSections()` 对每个已建的镜像调 `CPlusPlusSymbolIndexStore.shared.remove(for:)` 与 `CPlusPlusClassIndexStore.shared.remove(for:)`。上游补名时顺带给基类所在镜像建的索引（libc++abi、TSPersistence 之类）由上游自己的缓存持有，RuntimeViewer 不知道是哪些，不清它们；写进实现说明的已知局限。

### 建树规则（`CPlusPlusObjectTreeBuilder`）

输入：作用域树（从 `.global` 递归 `childScopes`，每个作用域带 `members` 的数目）与 `[CPlusPlusClass]`。输出：顶层对象数组，子项按 `displayName` 排序。

1. 每个作用域按 `kind` 归类：`.type` → 类；`.namespace`、`.undetermined` → 命名空间；`.function` → 丢弃，连同它下面的一切。
2. 每个 RTTI 类按 `qualifiedName` 找作用域；找到就把那个作用域标成类（即使作用域树判成命名空间或未定——RTTI 是更强的证据）；找不到就按 `scopePath` 逐层建，缺的层按「父层是类就是类，否则是命名空间」补。
3. 自底向上去掉没有成员、没有子对象、也不是 RTTI 类的命名空间。没有成员的类型作用域保留（它出现在作用域树里本身就有类型证据）。
4. 全局作用域有直接成员时，加一个 `name: "::"`、`displayName: "Global Namespace"` 的命名空间对象。
5. 同名去重：作用域树里一个限定名只有一个作用域；多个 RTTI 类同名时只取 typeinfo 偏移最小的，与 `class(named:in:)` 一致。

### 打印规则（`CPlusPlusInterfacePrinter`）

以 `std::bad_array_new_length` 为例（libc++abi，进程内，地址开关打开时；地址为示意）：

```cpp
// libc++abi · typeinfo 0x1A2B30 · vtable 0x1C4F00
class std::bad_array_new_length : public std::bad_alloc {
    // Virtual functions (primary vtable)
    virtual ~bad_array_new_length();       // slots 0–1  0x0004A3C0, 0x0004A3E0
    virtual what() const;                  // slot 2  0x0004A510  overrides std::bad_alloc

    // Member functions
    bad_array_new_length();                // 0x0004A100, 0x0004A120
};
```

- 槽位注释的三种结尾：`overrides <基类>`（`baseFunction.isInherited == false`）、`inherited from <基类>`（`true`）、什么都不写（`baseFunction == nil`，类自己引入的虚函数，或基类读不到）。名字取 `CPlusPlusVirtualFunction.name`：自己的名字优先，没有才用基类那一格的。
- 实现在别的镜像（`.imported`、`.otherImage`）时地址注释写 `in <install name>` 或地址本身。
- 副表的小标题：`// Virtual functions (secondary vtable for <subobjectClassName ?? "unknown base">, offset-to-top <n>)`。
- 头部的「只从运行时类型信息恢复」注释在 `hasTypeInfoSymbol == false` 时写；`hasUniqueTypeInfo == false` 时注明 typeinfo 按名字比较。
- 作用域树里有、RTTI 里没有的类，没有 vtable 一节，头部不写 typeinfo。
- 命名空间对象没有成员时只有子项的前置声明；全局对象打印成 `// Global namespace` 加成员，不写 `namespace {}`。

### 跳转的目标种类

```swift
case .cPlusPlus:
    switch kind {
    case .class: return .cPlusPlus(.class)
    case .other: return .cPlusPlus(.namespace)
    default: return nil
    }
```

### Inspector

- `TabConfiguration`：`.cPlusPlus(.class)` → `hierarchy: .superclasses, needsRelationships: true`；`.cPlusPlus(.namespace)` → 两者都没有。
- 关系页：C++ 类的 `sectionTitle` 是「Derived Classes」，`payload` 是 `relationships.subclasses`。
- `superclassChain(for:)` 的 C++ 臂经 `RuntimeTypeRelationshipsResolver` 调 section 的 `primaryBaseChain(of:)`，每层生成 `RuntimeRelationshipNode(name:object:typeKind: .class)`；节点的 `TypeKind` 只有 `class` / `protocol` 两个 case，不加新 case，线上形状不变。

## 替代方案考量

- **给 C++ 对象加一条新命令**（`cPlusPlusObjectsInImage`），App 分两次取：职责更清楚，但经 Mach service 的旧版注入 payload 收到不认识的命令会断开连接（PR121.73），而侧栏每打开一个镜像就要发一次。否决，改为给已有命令加可选字段——§4.4 已有四例的做法。
- **把 C++ 对象无条件并进 `objectsInImage` 的回复**：最省事，但旧版 App 连本版 payload（例如设备上装的是较新的 RV、Mac 上是旧的）会因为解不开新种类整张列表失败；本版的 Find、导出、MCP、CLI 也会突然收到它们处理不了的对象。否决。
- **C++ section 随索引一起建**（并进 `_isImageIndexed`）：侧栏打开已索引的镜像时更快，但 Always Index 的几百个镜像每个都要多建一次作用域树与类索引（cache 文件读法上游实测慢约 10 倍），而 C++ 对象只在侧栏用得到。否决，按需建；第 1 步的实测若显示侧栏首开明显变慢，再另议。
- **按 vtable 逐格列出的报告式界面**（ClassInformer 的形状）：离二进制更近，但不像代码，高亮、跳转与以后接 Find 的成员定位都要另写一套。用户在澄清提问里选了伪头文件。
- **只列 RTTI 类**或**只列类型**：范围小，但命名空间里的自由函数（C++ 库的大量 API）看不到。用户选了类型与命名空间都列，代价是几乎每个镜像都多出 `std` 一类的命名空间，可用 Filter Scope 的 C++ 一组藏起来。
- **第一版一次接上 Find、导出、MCP、CLI**：落地慢、提案过大。用户选了只接浏览用的界面。
- **为 C++ 另加地址注释开关**：要改 `GenerationOptions` 的线上形状与设置页；C++ 与 ObjC 同是头文件，共用 `addMethodIMPAddressComments` 足够。否决。
- **猜返回类型、`static` 与访问级别**（例如按 `this` 限定推非静态）：修饰名里没有，猜错比不写更误导。否决，只打印修饰名里有的。
- **C++ 放进单独的命令扩展模块**（像 `RuntimeViewerCrossReferences`）：开发规则第 8 条针对的是「不是 Core 自己的命令」；本提案不加命令，C++ 是与 ObjC、Swift 并列的对象语言，section 放进 Core 的 `Sections/` 与另两种对称。否决。

## 影响

### 用户可见变化

- 侧栏的对象列表、Open Quickly、路径栏多出 C++ 的类与命名空间（嵌套显示），图标是绿色 `C` 与 `N`；镜像页的种类计数多出两行。
- 选中 C++ 对象，内容区显示伪头文件，点基类或前置声明里的类名跳过去；Inspector 有层级页与「Derived Classes」页。
- Filter Scope 多一组「C++」，可以整组或逐项藏起。
- 没有任何已有界面、交互或快捷键被移除；ObjC 与 Swift 的对象、界面完全不变。
- C++ 对象在 Find、导出、MCP、CLI 里都不出现（非目标），这是有意的阶段性差异，落地说明里写清。

### 可发现性

默认开启：打开任何带 C++ 符号或 RTTI 的镜像，C++ 对象就和 ObjC、Swift 对象一起列出，不需要设置。嫌多的用户用 Filter Scope 的 C++ 一组关掉，选择按 Engine 与镜像记住（提案 0085）。

### 数据与配置兼容

- **书签**：本版可以收藏 C++ 对象。降级到旧版时，旧版解不开这几条书签，按 `@ResilientFileStorage` 的逐条容错只丢这几条并记日志，其余书签保留；旧版下次写回时这几条就没了。只影响降级，不做迁移。
- **Filter Scope 记忆**：存的是排除的种类，旧记忆里没有 C++，C++ 默认显示；旧版读本版写的记忆，C++ 种类逐条解不开、只丢那一条。
- **派生数据**：不存 C++ 的东西，语料快照格式不变。
- **线上**：旧请求方与本版对端、本版请求方与旧对端两种组合都由第 2 步的冻结测试守住。

### 平台与最低版本

最低版本不变。RuntimeViewerCore 在所有平台上都链接 `CPlusPlusSymbols`（上游平台下限与 Core 相同），所以 iOS、visionOS 的 App 与越狱版也列出 C++ 对象（它们共用侧栏的 ViewModel）；注入 payload（含 iOS Simulator 的 x86_64 切片）多带一份 `ItaniumDemangle`，体积增加，第 1 步记下增量。

### 发布

不需要新的权限、entitlement 或隐私清单条目。不影响公证与 Sparkle。MachOKitExtensions 3.1.0 已发布，发版前照常编 `RuntimeViewer-Distribution.xcworkspace` 核对锁文件。

## 落地步骤

1. **依赖、种类与测量** —— 改动地图里的 `Package.swift`、锁文件、`RuntimeObjectKind`、`RuntimeInterfaceLanguage`、各处穷举的补臂、`RuntimeImageReading`（视编译结果）、临时的耗时探针
   - 行为：`cPlusPlusKindsSortAfterSwiftKinds`
   - 行为：`cPlusPlusKindRoundTripsThroughJSON`
   - 行为：`cPlusPlusKindDescriptionsNameTheLanguage`
   - 行为：探针结论（进程内与 cache 文件、Espresso 与 libc++、release）与注入 payload 的体积增量写进本提案的前期调研与决策日志，探针删除
2. **C++ section 与对象列表** —— section、工厂、建树、两份协议、`RuntimeImageIndex`、`RuntimeEngine` 的取对象部分、`ObjectsInImageCommand`、两个进度阶段、建树与 section 的测试、线上测试
   - 行为：`typeScopeBecomesClassObject`
   - 行为：`typeInfoOnlyClassIsPlacedUnderItsScopePath`
   - 行为：`missingParentOfTypeInfoOnlyClassBecomesNamespace`
   - 行为：`typeInfoTurnsUndeterminedScopeIntoClass`
   - 行为：`functionScopesAreDropped`
   - 行为：`emptyNamespacesAreDropped`
   - 行为：`globalMembersGetGlobalNamespaceObject`
   - 行为：`libcxxabiListsBadArrayNewLengthUnderStd`（进程内与 cache 文件各一遍）
   - 行为：`objectsWithoutFlagCarryNoCPlusPlusObjects`
   - 行为：`requestWithoutFlagEncodesAsBefore`
   - 行为：`frozenOldServerAnswersFlaggedRequestWithObjCAndSwiftOnly`
   - 行为：`relayForwardsTheFlag`（JSON 与 `XPCEncoder`）
   - 行为：`progressReportsCPlusPlusPhasesOnlyWhenAsked`
   - 行为：`stoppingEngineRemovesCPlusPlusIndexes`
   - 行为：`concurrentRequestsBuildOneCPlusPlusSection`
3. **界面与跨镜像跳转** —— 打印器、`_interface` 的 C++ 臂、目录的新方法、打印测试
   - 行为：`classPrintsBasesWithVirtualAndAccess`
   - 行为：`virtualDestructorSlotsCollapseIntoOneLine`
   - 行为：`constructorVariantsCollapseIntoOneLine`
   - 行为：`slotNamedThroughBaseSaysInheritedOrOverrides`
   - 行为：`unnamedSlotPrintsSlotNumberOnly`
   - 行为：`pureAndDeletedSlotsPrintTheirMarkers`
   - 行为：`secondaryTableNamesItsSubobject`
   - 行为：`virtualFunctionsAreNotRepeatedAsMemberFunctions`
   - 行为：`metadataSymbolsAreNotPrintedAsMembers`
   - 行为：`returnTypePrintedOnlyWhenMangled`
   - 行为：`addressCommentsFollowIMPAddressOption`
   - 行为：`typeInfoOnlyClassSaysSo`
   - 行为：`namespacePrintsFunctionsVariablesAndChildren`
   - 行为：`typeTokensCarryQualifiedNames`
   - 行为：`baseInAnotherImageResolvesThroughExportedTypeInfo`（进程内：libc++ 的类跳到 libc++abi 的 `std::exception`）
   - 行为：`nonUniqueTypeInfoBaseDoesNotResolve`
4. **层级与派生类** —— `_hierarchy`、关系解析器、类型关系解析器、`RuntimeRelationshipNode.TypeKind`
   - 行为：`hierarchyFollowsPrimaryBases`
   - 行为：`hierarchyCrossesIntoTheImageDefiningTheBase`
   - 行为：`superclassChainNodesResolveCPlusPlusObjects`
   - 行为：`relationshipsListDerivedClassesInTheImage`
   - 行为：`namespaceHasNoHierarchy`
5. **App 接入** —— 侧栏、路径栏、镜像页、Filter Scope、图标、内容区语言与文件类型、跳转目标、Inspector、其余补臂、AppCore 测试
   - 行为：`filterScopeHasCPlusPlusGroup`
   - 行为：`cPlusPlusIconsAreGreenCAndN`
   - 行为：`cPlusPlusLinkTargetsAreClassesAndNamespaces`
   - 行为：`cPlusPlusClassGetsHierarchyAndDerivedClassesTabs`
   - 行为：`sidebarAsksForCPlusPlusObjects`
   - 行为：`exportAndFindDoNotAskForCPlusPlusObjects`
   - 行为：`imagePageCountsCPlusPlusKinds`
   - 行为：`./TuistScript.sh check` 通过
6. **文档** —— `AGENTS.md`、`CommunicationAndEngineArchitecture.md` §4.4、`README.md`、索引；判断是否写实现说明（倾向写一份 `Documentations/CPlusPlusObjects.md`：建树规则、打印规则、为什么是字段不是命令、已知局限）与术语表

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、代码本身看不出来的决策」就写实现说明。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 有就同批次登记进术语表（项目级 `Documentations/Glossary.md`，跨项目通用的登记到全局术语表）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-21 | Created as Draft | 用户要求把 MachOKitExtensions 新增的 C++ 恢复（0005 作用域树、0006 RTTI 与 vtable）接进 RuntimeViewer。走轻量档，问了一轮。 |
| 2026-11-21 | 定下范围与形状 | 用户选定：类型与命名空间都列（接受 `std` 一类命名空间带来的噪音，由 Filter Scope 收起）；第一版只接浏览用的界面（侧栏、图标、Filter Scope、内容区、跳转、Inspector、路径栏），Find、导出、MCP、CLI 以后另起提案；内容区写成伪头文件，不写成按 vtable 逐格的报告。 |
| 2026-11-21 | 线上形状：字段而非命令 | 经 Mach service 的旧版注入 payload 会把不认识的命令当成客户端离开（PR121.73），而侧栏每开一个镜像都要取对象，所以 C++ 对象经 `objectsInImage` 的可选字段 `includesCPlusPlusObjects` 取，旧对端跳过字段。 |
| 2026-11-21 | 不打印修饰名里没有的东西 | 澄清提问的样例里画了返回类型与 `static`，但 Itanium 修饰名只给函数模板特化记返回类型、不区分静态成员、不记访问级别；界面只打印修饰名里有的，样例的这几处在实现里不会出现。 |
| 2026-11-21 | Accepted | 用户看过简报后批准，开始实现。 |

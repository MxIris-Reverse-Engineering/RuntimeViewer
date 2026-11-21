# 0107 - 导出 C++ 对象：单个与批量导出写出 C++ 头文件

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-11-21
- **最后更新**: 2026-11-22
- **所属愿景**: 无
- **关联提案**: [0103 C++ 对象](0103-cplusplus-objects.md)。本提案接 0103 留在提案索引「暂缓的后续项」里的导出一项；Find、MCP 与 CLI 仍各自另写
- **实现分支 / PR**: `feature/cplusplus-export`，从 `next` 切出
- **配套文档**: 待定 —— 落地时判断；倾向不写（理由见「落地步骤」第 3 步）
- **网页版**: 同目录同名的 `.html`

## 摘要

导出（单个镜像的 Export，⌘E；批量的 Export Multiple Images…，⇧⌘E）在 Objective-C、Swift 之外写出镜像的 C++ 类与命名空间。每个 C++ 对象写成一份伪头文件，内容就是内容区打印的那一份。目录格式放进 `CPlusPlusHeaders/`，单文件格式合成 `<镜像名>.hpp`，两种格式在配置页里像 ObjC、Swift 一样单选。

C++ 对象是一棵树：顶层多是命名空间，类挂在下面，而打印器打印命名空间时只给其中的类写一行前向声明。所以导出要把整棵树展开，每个类与命名空间各写一份。文件名用限定名，免得不同命名空间里的同名类互相覆盖。

Core 的导出配置加一个默认关闭的 `includesCPlusPlusObjects`，只有 App 的两条导出路径打开它，所以 CLI 的 `export` 子命令输出不变。

## 动机

0103 让侧栏、路径栏、镜像页和内容区能看到 C++ 对象，但导出一张带 C++ 的镜像（libc++、libc++abi、Espresso、WebKit 一类）仍然只得到 ObjC 与 Swift。导出常见的用途是拿整份头文件去 grep，或者对比两个系统版本的差异；现在 C++ 部分只能在内容区一个类一个类地看、一个个复制。用户在 0103 落地后要求补上导出这一项。

## 前期调研

**现状代码怎么走的**

- 单个导出：配置页 `ExportingConfigurationViewModel.loadObjects()`（`RuntimeViewerPackages/Sources/RuntimeViewerAppCore/Exporting/ExportingConfigurationViewModel.swift:57-67`）用不带参数的 `objects(in:)` 取对象，只用来数 ObjC 与 Swift、决定显示哪几组单选（`:95-98`）。进度页 `ExportingProgressViewModel.startExport()`（`Exporting/ExportingProgressViewModel.swift:51-90`）组出 `RuntimeInterfaceExportConfiguration`，调 `RuntimeEngine.exportInterfaces(with:reporter:)`。
- 批量导出：`BatchExportingProgressViewModel.exportOne(…)`（`BatchExporting/BatchExportingProgressViewModel.swift:164-260`）先索引镜像，再给每个镜像一个子目录，调同一个 Core 入口。配置页 `BatchExportingConfigurationViewModel` 与单个导出共用 `ExportingDefaultsKey` 里的两个格式键。
- CLI 的 `export`（`RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Execution/CommandExecutor.swift:438-451`）也走 `exportInterfaces`。MCP 没有导出：它的源码里没有调用 `exportInterfaces` 的地方。
- Core 的导出（`RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeEngine+Export.swift:15-145`）取顶层对象，逐个 `interface(for:options:)`，按 `RuntimeInterfaceExportItem.isSwift` 分成两组：非 Swift 的进 `ObjCHeaders/` 或 `<镜像名>.h`，Swift 的进 `SwiftInterfaces/` 或 `<镜像名>.swiftinterface`，最后写 README。`RuntimeInterfaceExportWriter`（`Export/RuntimeInterfaceExportWriter.swift`）的两个写法里又各自按 `isSwift` 分了一次组，`exportInterfaces` 里两组的写出代码几乎逐行重复。
- 0103 为了让穷举 switch 编过，已经给导出补了 C++ 的臂：`exportFileName` 给 `.cPlusPlus` 用 `.hpp`（`Export/RuntimeObject+Export.swift:36-38`），`RuntimeInterfaceExportItem.fileExtension` 也是 `hpp`。但 `isSwift` 对 C++ 是 false，C++ 条目要是进来，会落进 ObjC 那一组（`ObjCHeaders/`、`<镜像名>.h`）。今天没出问题，只是因为导出从不要 C++ 对象。
- C++ 对象是树：`CPlusPlusObjectTreeBuilder.Node.object(parentPath:imagePath:)`（`Sections/CPlusPlus/CPlusPlusObjectTreeBuilder.swift:158-172`）给出的 `name` 是限定名 `std::exception`，`displayName` 只是最后一段 `exception`，子项是其中声明的类与命名空间。全局命名空间的对象叫 `::`，显示名是 `Global Namespace`（同文件 `:20-25`）。
- 打印器打印类或命名空间时，其中声明的类型只写一行（`CPlusPlusInterfacePrinter.declaredSection`，`Sections/CPlusPlus/CPlusPlusInterfacePrinter.swift:360-381`）：类写 `class std::bad_alloc;`，命名空间写 `namespace std::__1 {}`，不展开。所以只导顶层对象，就会丢掉几乎所有类。
- `exportFileName` 用的是 `displayName`。对 C++，这意味着 `a::Impl` 与 `b::Impl` 会写成同一个文件，后写的覆盖先写的。

**上游或依赖是否已具备能力**

- 都具备。`objects(in:includesCPlusPlusObjects:)` 与 C++ 对象的 `interface(for:options:)` 是 0103 做的。旧版对端收到带字段的请求时，会当成没带字段，只回 ObjC 与 Swift；0103 的线上测试（`ObjectsInImageCPlusPlusWireTests`）钉住了这一点。所以对旧对端导出照常进行，只是没有 C++ 文件。

**验证过什么**

- 耗时（0103「实测」一节，release、Ultra）：Espresso 的 C++ section，进程内建约 0.25 秒，从 cache 文件读约 1.9 秒；给全部 4,379 个类的 56,204 个槽位取名，进程内 0.62 秒，cache 文件 2.43 秒。导出逐个类打印，量级与此相当，另加每个对象一次请求往返。ObjC 与 Swift 导出本来就是一个对象一次往返，所以不另做批量接口。
- 导出的文本与内容区一致：根 `AGENTS.md` 开发规则第 7 条把导出列为直接调引擎、不走界面缓存的批量消费方，但导出的文本应与内容区显示的一致。所以本提案不另写打印方式。

## 提议方案

1. **Core 的导出配置加两项**：`includesCPlusPlusObjects: Bool`（默认 `false`）与 `cPlusPlusFormat: Format`（默认 `.directory`）。默认不要 C++，所以 CLI 和现有调用点的行为不变。
2. **要 C++ 时把树展开**：`exportInterfaces` 取对象时把字段带上，再把每个对象换成它的 `exportedObjects`：ObjC、Swift、C 对象只有自己；C++ 对象是自己加上全部后代，深度优先、父在前，顺序与侧栏一致。新增公开的 `RuntimeObject.exportedObjects`，配置页数 C++ 对象时用同一个。
3. **写出分三组**：Objective-C（含 C）、Swift、C++。C++ 的单文件是 `<镜像名>.hpp`，目录是 `CPlusPlusHeaders/`。写出器改成按组的表来写（目录名、扩展名、格式），`exportInterfaces` 里两段重复的写出代码合成一段。
4. **C++ 的文件名用限定名**：沿用现有的清洗规则，非法字符（含冒号）一律换成下划线，所以 `std::exception` → `std__exception.hpp`。全局命名空间写成 `GlobalNamespace.hpp`。超长的名字照旧截断后加哈希。
5. **结果与 README**：`RuntimeInterfaceExportResult` 加 `cPlusPlusCount`，构造参数默认 0。README 只在要了 C++ 时多两行：`C++ format` 与 `C++ interfaces`。C++ 没有生成选项，所以选项部分不加 C++ 一节。
6. **App 的两条导出路径都要 C++**：
   - 单个导出：配置页取对象时带 `true`，摘要多一段「N C++」（数展开后的对象）。镜像里有 C++ 时显示「C++:」一组单选，选项是 Single File (.hpp) 与 Directory Structure。完成页在「ObjC: … | Swift: …」后面加「C++: N」，N 为 0 时不加。
   - 批量导出：配置页一直显示 C++ 一组，完成页的卡片从「ObjC · Swift」改成「ObjC · Swift · C++」三个数。
   - C++ 格式存在 `Exporting.cPlusPlusFormat`，单个与批量共用，默认 Directory，与 ObjC 一致。
7. **不加「不导出 C++」的开关**：ObjC 和 Swift 也没有，镜像里有就导出。

### 非目标

- CLI 的 `export`、MCP、Find 照旧看不到 C++ 对象；提案索引的暂缓项改为只列这三项。
- 不改 C++ 打印器：导出的就是内容区的文本，命名空间里的类照旧是前向声明，每个类有自己的一份。
- ObjC、Swift 的导出不变：仍只导顶层对象，文件名和目录都不变。
- 不按命名空间分子目录（见「替代方案」第 3 条，用户定了平铺）。

### 已确认

开工前请用户定的三件事都已确认：照此开工；目录格式里的 C++ 文件平铺在 `CPlusPlusHeaders/` 下；CLI 的 `export` 这次不加 C++，以后与 MCP、Find 一起另起提案。

## 改动地图

Core 指 `RuntimeViewerCore/Sources/RuntimeViewerCore/`，AppCore 指 `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/`，App 指 `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`。

| 文件 / 类型 | 动作 | 改什么 | 为什么 | 步骤 |
|---|---|---|---|---|
| Core `Export/RuntimeInterfaceExportConfiguration.swift` | 修改 | 加 `cPlusPlusFormat`（默认 `.directory`）与 `includesCPlusPlusObjects`（默认 `false`），构造参数带默认值 | 方案第 1 条 | 1 |
| Core `Export/RuntimeObject+Export.swift` | 修改 | 加 `exportedObjects`；`exportFileName` 对 C++ 用清洗过的限定名，全局命名空间用 `GlobalNamespace` | 方案第 2、4 条 | 1 |
| Core `Export/RuntimeInterfaceExportItem.swift` | 修改 | `isSwift` 换成 `Group`（`.objectiveC`、`.swift`、`.cPlusPlus`），每组带目录名与单文件扩展名；删掉没人用的 `fileExtension` | 方案第 3 条 | 1 |
| Core `Export/RuntimeInterfaceExportWriter.swift` | 修改 | 两个写法合成按组写一组：`write(_:as:format:to:imageName:)` | 方案第 3 条 | 1 |
| Core `Export/RuntimeEngine+Export.swift` | 修改 | 取对象带字段、按 `exportedObjects` 展开、按组计数与写出；两段重复的写出代码合成一个循环 | 方案第 2、3 条 | 1 |
| Core `Export/RuntimeInterfaceExportResult.swift` | 修改 | 加 `cPlusPlusCount`，构造参数默认 0 | 方案第 5 条 | 1 |
| Core `Export/RuntimeInterfaceExportMetadata.swift` | 修改 | `ExportInfo` 加可选的 `cPlusPlusFormat` 与 `cPlusPlusInterfaceCount`，`make` 多传 C++ 计数，README 只在要了 C++ 时多两行 | 方案第 5 条 | 1 |
| `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/CPlusPlusExportTests.swift` | 新增 | 第 1 步的行为：libc++abi 上的两种格式、默认不要、文件名、展开顺序、README、计数、与内容区一致 | 第 1 步行为 | 1 |
| AppCore `Exporting/ExportingState.swift` | 修改 | `ExportingDefaultsKey.cPlusPlusFormat`、`ExportingState.cPlusPlusFormat`；测试用的完成态带 C++ 计数 | 方案第 6 条 | 2 |
| AppCore `Exporting/ExportingConfigurationViewModel.swift` | 修改 | 取对象带 `true`；`Input` 加 `cPlusPlusFormatSelected`，`Output` 加 `cPlusPlusCount`、`hasCPlusPlus`、`cPlusPlusFormat`；记住所选格式 | 方案第 6 条 | 2 |
| App `Exporting/ExportingConfigurationViewController.swift` | 修改 | 「C++:」一组单选与说明，摘要加「N C++」；整页放进滚动视图 | 方案第 6 条 | 2 |
| AppCore `Exporting/ExportingProgressViewModel.swift` | 修改 | 配置带 `cPlusPlusFormat` 与 `includesCPlusPlusObjects: true` | 方案第 6 条 | 2 |
| AppCore `Exporting/ExportingCompletionViewModel.swift` | 修改 | 摘要的语言一行在 C++ 数大于 0 时加「C++: N」 | 方案第 6 条 | 2 |
| AppCore `BatchExporting/BatchExportingState.swift` | 修改 | `cPlusPlusFormat`；每个镜像的 `cPlusPlusCount` 与汇总的 `totalCPlusPlusCount` | 方案第 6 条 | 2 |
| AppCore `BatchExporting/BatchExportingConfigurationViewModel.swift`、App `BatchExporting/BatchExportingConfigurationViewController.swift` | 修改 | C++ 一组单选，与单个导出共用格式键；整页放进滚动视图 | 方案第 6 条 | 2 |
| AppCore `BatchExporting/BatchExportingProgressViewModel.swift` | 修改 | `exportOne` 的配置带 C++ 格式与 `true` | 方案第 6 条 | 2 |
| AppCore `BatchExporting/BatchExportingCompletionViewModel.swift`、App `BatchExporting/BatchExportingCompletionViewController.swift` | 修改 | `objcSwiftValue` 改名 `languageCountsValue`，三个数；卡片标签「ObjC · Swift · C++」 | 方案第 6 条 | 2 |
| `RuntimeViewerPackages/Tests/RuntimeViewerAppCoreTests/ExportingCompletionViewModelTests.swift` | 修改 | 单个与批量完成页的 C++ 计数 | 第 2 步行为 | 2 |
| `AGENTS.md`（Package Structure 里 C++ 那段）、`Documentations/Glossary.md`（「C++ 对象」）、`Documentations/Evolutions/README.md`（本行与暂缓项）、`Documentations/README.md` | 修改 | 导出从「看不到 C++ 的」里拿掉，改为「App 的导出要」；暂缓项改为 Find、MCP 与 CLI；登记 | 文档与代码同批 | 2 |

不改的：CLI（`CommandExecutor` 不传新参数，取默认值）、MCP、Find、C++ 打印器、ObjC 与 Swift 的导出写法。

## 架构图

改了什么：

```
App / AppCore                                   RuntimeViewerCore
─────────────────────────────────────────       ────────────────────────────────────────────────
ExportingConfigurationViewModel          ~      RuntimeEngine.exportInterfaces(with:reporter:)      ~
  objects(in:, includesCPlusPlusObjects: true)   objects(in:, includesCPlusPlusObjects:
  counts allObjects.flatMap(\.exportedObjects)            configuration.includesCPlusPlusObjects)
  + C++ format radios                             .flatMap(\.exportedObjects)                      +
ExportingProgressViewModel               ~        interface(for:options:) per object               (as before)
  + cPlusPlusFormat, includesCPlusPlusObjects     group by RuntimeInterfaceExportItem.Group        ~
ExportingCompletionViewModel             ~          ├─ .objectiveC  ObjCHeaders/      | <image>.h
  "ObjC: n | Swift: n | C++: n"                     ├─ .swift       SwiftInterfaces/  | <image>.swiftinterface
BatchExporting{Configuration,Progress,   ~          └─ .cPlusPlus   CPlusPlusHeaders/ | <image>.hpp  +
  Completion}ViewModel: same three                RuntimeInterfaceExportWriter.write(_:as:…)        ~
                                                  RuntimeInterfaceExportResult.cPlusPlusCount       +
runtime-viewer-cli export                (unchanged: includesCPlusPlusObjects defaults to false)
```

一张镜像的 C++ 树怎么展开、写成哪些文件（目录格式，libc++abi）：

```
objects(in: libc++abi, includesCPlusPlusObjects: true)
  ├─ Objective-C / Swift objects ..... themselves only, as before
  └─ std                (namespace)  -> CPlusPlusHeaders/std.hpp             free functions + "Declared here" list
       ├─ std::exception      (class) -> CPlusPlusHeaders/std__exception.hpp
       ├─ std::bad_alloc      (class) -> CPlusPlusHeaders/std__bad_alloc.hpp
       └─ ...                         depth first, parent before children
  ::  (global namespace)             -> CPlusPlusHeaders/GlobalNamespace.hpp
```

## 详细设计

**Core 的 API**（形状照现有的 `objcFormat` / `swiftFormat`、`objcCount` / `swiftCount` 与 0103 的 `includesCPlusPlusObjects`）：

```swift
public struct RuntimeInterfaceExportConfiguration: Sendable {
    public let cPlusPlusFormat: Format
    /// Whether the export asks for the image's C++ objects
    /// (`objects(in:includesCPlusPlusObjects:)`) and writes them. Off by
    /// default, so a caller that predates C++ objects exports what it did.
    public let includesCPlusPlusObjects: Bool

    public init(
        imagePath: String,
        imageName: String,
        directory: URL,
        objcFormat: Format,
        swiftFormat: Format,
        cPlusPlusFormat: Format = .directory,
        generationOptions: RuntimeObjectInterface.GenerationOptions,
        includeMetadata: Bool = true,
        includesCPlusPlusObjects: Bool = false
    )
}

extension RuntimeObject {
    /// The objects an export writes for this one: itself, and for a C++
    /// class or namespace every class and namespace declared in it, depth
    /// first. A C++ interface names what is declared in it without printing
    /// it, so each of them is written on its own.
    public var exportedObjects: [RuntimeObject] { get }
}

public struct RuntimeInterfaceExportResult: Sendable, Equatable {
    public let cPlusPlusCount: Int
    public init(succeeded:failed:totalDuration:objcCount:swiftCount:cPlusPlusCount: Int = 0)
}

struct RuntimeInterfaceExportItem: Sendable {
    enum Group: CaseIterable, Sendable {
        case objectiveC   // .objc and .c:  ObjCHeaders/,      <image>.h
        case swift        //                SwiftInterfaces/,  <image>.swiftinterface
        case cPlusPlus    //                CPlusPlusHeaders/, <image>.hpp
        var directoryName: String { get }
        var singleFileExtension: String { get }
    }
    var group: Group { get }
}
```

**`exportInterfaces` 的流程**：

```swift
let objects = try await objects(in: configuration.imagePath,
                                includesCPlusPlusObjects: configuration.includesCPlusPlusObjects)
    .flatMap(\.exportedObjects)
// per object, as before: interface(for:options:), empty → skipped, failure → counted
// count per group (objcCount, swiftCount, cPlusPlusCount)
for group in RuntimeInterfaceExportItem.Group.allCases {
    let items = results.filter { $0.group == group }
    guard !items.isEmpty else { continue }
    try RuntimeInterfaceExportWriter.write(items, as: group, format: configuration.format(for: group),
                                           to: configuration.directory, imageName: configuration.imageName)
}
```

`configuration.format(for:)` 是内部辅助方法：`.objectiveC` 取 `objcFormat`，`.swift` 取 `swiftFormat`，`.cPlusPlus` 取 `cPlusPlusFormat`。三组的写出顺序与今天相同（ObjC 在 Swift 前面），C++ 最后。

**C++ 的文件名**：

| 限定名 | 文件名 |
|---|---|
| `std::exception` | `std__exception.hpp` |
| `(anonymous namespace)::Foo` | `(anonymous namespace)__Foo.hpp` |
| `std::__1::vector<int, std::__1::allocator<int>>` | `std____1__vector_int, std____1__allocator_int__.hpp` |
| `::`（全局命名空间） | `GlobalNamespace.hpp` |

清洗规则沿用 `exportFileName` 现有的那一套（`/:<>"\|?*` 换成 `_`，超过 255 字节时截断并加哈希），只是 C++ 的输入从 `displayName` 换成了 `name`。清洗后仍可能撞名：全局命名空间里一个真叫 `a__b` 的类，会和 `a::b` 撞。C++ 把双下划线开头或含双下划线的名字留给实现，所以只在标准库内部才会出现，按现状处理，不另做去重。

**单文件格式**：`<镜像名>.hpp` 是各对象界面按展开顺序拼接，中间空一行，与 ObjC、Swift 的单文件格式相同。

**App 的文字**：

| 地方 | 文字 |
|---|---|
| 单个导出的组名与选项 | `C++:`，`Single File (.hpp)`、`Directory Structure` |
| 单个导出的说明 | `Combine all C++ interfaces into one .hpp file`；`Individual .hpp files in CPlusPlusHeaders/ subdirectory` |
| 批量导出的说明 | `Combine all C++ interfaces into one .hpp file per image`；`Individual .hpp files in each image's CPlusPlusHeaders/ subdirectory` |
| 单个导出的摘要 | `Image: libc++abi.dylib · 12 ObjC · 3 Swift · 41 C++`（数为 0 的一段不写，与现在相同） |
| 单个导出的完成页 | `ObjC: 12 \| Swift: 3 \| C++: 41`（C++ 为 0 时不写 C++ 那段） |
| 批量导出的卡片 | 标签 `ObjC · Swift · C++`，值 `12 · 3 · 41` |

配置页数的 C++ 是 `allObjects.flatMap(\.exportedObjects)` 里 C++ 种类的个数，也就是会写出的文件数，不是顶层对象数。进度页显示的对象名照旧用 `displayName`，所以 C++ 显示短名。

## 替代方案考量

1. **只导顶层 C++ 对象**：最省事，但顶层几乎全是命名空间，而命名空间的界面只给其中的类写前向声明，类等于没导出。否决。
2. **每个顶层命名空间写一个文件，把其中的类展开写进去**：文件少、读起来像真的头文件。但要给打印器加一种展开的打印方式，导出的文本就和内容区不一样了，开发规则第 7 条要两者一致。否决。
3. **目录格式按命名空间分子目录**（`CPlusPlusHeaders/std/exception.hpp`）：浏览起来更顺手，但有三处要另定规矩：
   - 命名空间自己的文件放哪：`std.hpp` 与 `std/` 并列，还是 `std/std.hpp`；
   - 类里嵌套的类怎么放：`Outer/Inner.hpp`，而 `Outer` 是类；
   - 模板参数里的 `::` 不能当成层级。

   用户定了平铺。
4. **导出一律带 C++，不加配置项**：调用方少一个参数，但会悄悄改掉 CLI `export` 的输出；那样 CLI 的插件 skill 要跟着改、插件版本要抬，又不在这次的范围里。否决。
5. **配置页加「Include C++」勾选框**：ObjC 和 Swift 都没有这样的开关，C++ 的代价也只是多几秒、多一些文件。不加。
6. **用一个 `cPlusPlusFormat: Format?` 同时表达「要不要」和格式**：少一个参数，但 `nil` 表示什么，要读文档才知道；与 `objects(in:includesCPlusPlusObjects:)` 同名的布尔一看就懂。否决。

## 影响

### 用户可见变化

- 导出带 C++ 的镜像时，多出 `CPlusPlusHeaders/` 或 `<镜像名>.hpp`；配置页和完成页多了 C++ 的格式与计数。
- 往导出过的目录里再导一次，会多出这些 C++ 文件，ObjC 与 Swift 的文件不变。

### 可发现性

- 单个导出时，镜像里有 C++ 才出现「C++:」一组，和 ObjC、Swift 的规矩一样；批量导出一直显示。
- release note 写一句。

### 数据与配置兼容

- 新的 UserDefaults 键 `Exporting.cPlusPlusFormat`，没有时取 Directory；旧的两个键不动。
- 线上协议不变：`objectsInImage` 的字段 0103 就有了。旧版对端不回 C++ 对象，导出照常，只是没有 C++ 文件。
- `RuntimeInterfaceExportConfiguration` 与 `RuntimeInterfaceExportResult` 新加的参数都有默认值，CLI 和现有测试不用改。

### 平台与最低版本

- 导出只在 macOS 上有（相关文件都在 `#if os(macOS)` 里），iOS 不涉及。最低版本不变。

### 发布

- release note：「导出与批量导出现在也会写出 C++ 类与命名空间（.hpp）。」

## 落地步骤

1. **[完成] Core 导出写出 C++** —— 改动地图里步骤为 1 的各行。行为：
   - `exportLeavesCPlusPlusOutUnlessAsked`：不带新参数的配置导出 libc++abi，没有 `CPlusPlusHeaders/`，`cPlusPlusCount == 0`（CLI 的现状）
   - `directoryExportWritesCPlusPlusHeaders`：libc++abi 的目录导出写出 `CPlusPlusHeaders/std__exception.hpp`、`std__bad_alloc.hpp` 与 `std.hpp`
   - `singleFileExportCombinesCPlusPlusIntoOneHeader`：单文件导出写出 `libc++abi.hpp`，里面有 `class std::bad_alloc`
   - `exportedCPlusPlusTextMatchesTheContentPane`：一个 C++ 类的文件内容等于 `interface(for:options:)` 的文本
   - `nestedObjectsFollowTheirScopeDepthFirst`：自造的树上，`exportedObjects` 父在前、深度优先
   - `objectiveCAndSwiftObjectsExportOnlyThemselves`：ObjC、Swift 对象的 `exportedObjects` 只有自己
   - `cPlusPlusFileNamesUseQualifiedNames`：`a::Impl` 与 `b::Impl` 是两个文件
   - `globalNamespaceExportsAsGlobalNamespaceFile`
   - `resultCountsCPlusPlusInterfaces`
   - `readmeListsCPlusPlusOnlyWhenIncluded`
2. **[完成] App 的两条导出路径与界面，加文档** —— 改动地图里步骤为 2 的各行。行为：
   - `completionSummaryListsCPlusPlusCount`
   - `completionSummaryOmitsCPlusPlusWhenThereIsNone`
   - `batchSummaryShowsThreeLanguageCounts`
   - `aggregatedResultAddsUpCPlusPlusCounts`
   - 整个 App 编过；`./TuistScript.sh check` 没有新的红（`SwiftSectionTestingMacros` 那条是既有红）
   - 配置页的计数与单选的显隐不写测试：要替身引擎才能测，计数用的是第 1 步测过的 `exportedObjects`；由用户在 App 里目视
3. **[完成] 文档判断**（随第 2 步提交）：使用指南与实现说明倾向都不写——导出没有使用指南，规则在提案与 `AGENTS.md` 里；没有新术语，「C++ 对象」那条改一句。

## 决策日志

| 日期 | 变更 | 说明 |
|---|---|---|
| 2026-11-21 | Created as Draft | 0103 落地后，用户要求导出也带上 C++，这是 0103 暂缓项里的一项。走轻量档：先查清现状写出方案，开工前请用户确认三件事（照此开工、目录平铺还是分层、CLI 带不带）。 |
| 2026-11-21 | Accepted | 用户看过简报后批准，并确认目录格式平铺、CLI 的 `export` 这次不加 C++。 |
| 2026-11-21 | In Progress | 从 `next` 切出 `feature/cplusplus-export`。 |
| 2026-11-21 | 第 1 步完成 | Core 照方案改完。新增的 10 条测试放在 C++ 对象测试套件的嵌套套件 `CPlusPlusSectionTests.Export` 里，和它共用串行执行：MachOKitExtensions 存 C++ 索引的 store 是整个进程共用的，那个套件里有一条测试会清空它。C++ 与导出相关的 77 条测试全部通过。 |
| 2026-11-21 | 第 2 步完成 | App 层照方案改完，新增 4 条测试放在 `ExportingLanguageCountsTests`；连同原有的导出完成页测试、C++ 展示测试和两个边界检查，App 层 22 条测试全部通过。整个 App 经 Tuist workspace 编过（Debug，不签名）：给新 worktree 做 `./TuistScript.sh install` 时，连 GitHub 的 HTTPS 先两次被对端断开（HTTP/2 流被重置、TLS 读到意外的 EOF），第三次才装上；在那之前先拿编好的包对改过的三个 App 文件做了 `swiftc -typecheck`，也通过。`./TuistScript.sh check` 只报原有的那一条（`Tuist.swift` 缺 `SwiftSectionTestingMacros`），本次没有增删 target，Tuist 描述不用跟着改。 |
| 2026-11-21 | 文档判断 | 不写使用指南或实现说明：导出没有使用指南，规则在本提案、`AGENTS.md` 与代码注释里。没有新术语；术语表的「C++ 对象」改成导出会写出它们，`AGENTS.md` 的 RuntimeViewerCore 一段改成 App 的两条导出路径也要 C++ 对象、CLI 不要，提案索引的暂缓项改为 Find、MCP 与 CLI。`AGENTS.md` 在 `next` 上已有 72,129 字节，超过它自己定的 64 KiB 上限，是原有问题；这次只多了 224 字节。 |
| 2026-11-21 | 实现完成，待用户看过后收尾 | 两步都已提交；在本地合进常驻检出的 `next`，不推送。界面（配置页的 C++ 一组、摘要与完成页的计数）没有目视，留给用户看。 |
| 2026-11-21 | 用户看过，配置页改为可滚动 | 用户在 App 里看了 QuartzCore 的导出：Objective-C、Swift、C++ 三组都显示时，配置页超出窗口里的框，压到 Cancel 与 Next 上。单个导出和批量导出的配置页都把内容放进滚动视图（文档视图翻转、宽度跟随滚动区、滚动条自动隐藏），批量那页三组总是全显示，也一起改了。整个 App 重新经 Tuist 编过。之后用户确认这个功能可以收尾。编号与 Implemented 留到 `next` 推送的那次，与长类型拆行、欢迎窗口、起始页按进入 `next` 的先后一起取号。 |
| 2026-11-22 | 落地为 0107 | 四份草案随 `next` 的同一次推送按进入 `next` 的先后取号：0104 长类型拆行、0105 欢迎窗口、0106 起始页、0107 导出 C++ 对象；状态改 Implemented，随 v3.0.0-beta.10 发布。 |

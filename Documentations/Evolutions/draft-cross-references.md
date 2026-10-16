# Draft - 交叉引用：调用层级、被调与类型引用

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-10-16
- **最后更新**: 2026-10-16
- **所属愿景**: 无（CLI 与 MCP 部分沿用[《无头 RuntimeViewer》](../Visions/HeadlessRuntimeViewer.md)「GUI、命令行与 MCP 三个前端共用同一套命令词汇」的取向，但不推进该愿景的步骤）
- **关联提案**: [0029-find-navigator](0029-find-navigator.md)（Find 导航页、成员定位与高亮）、[0047-open-command-registry-and-injection-module](0047-open-command-registry-and-injection-module.md)（命令扩展范式）、[0037-local-runtime-xpc-service](0037-local-runtime-xpc-service.md)（本地运行时 service）、[0055-engine-scoped-background-work](0055-engine-scoped-background-work.md)（按 Engine 共享的后台工作与 Report）；MachOSwiftSection 侧的库提案（动工时创建）
- **实现分支 / PR**: `feature/cross-references`（worktree `.worktrees/RuntimeViewer-CrossReferences`）
- **配套文档**: 待定 —— 落地时判断：CLI / MCP 的目标写法与精度标注是否需要使用指南，全量索引的格式与失效规则是否需要实现说明

## 摘要

给 RuntimeViewer 加上从机器码里读出来的交叉引用：选中一个方法，能看到它**调了谁**（被调）、**谁调了它**（调用者，范围是整个系统共享缓存），以及**哪些方法用到了某个类型**（类型引用）。只分析有名字的函数——符号表里的，以及靠 ObjC 方法表、Swift 类型描述能叫出名字的；脱了符号、元数据也叫不出名字的代码不做。只支持 arm64 / arm64e。分析逻辑放进 MachOSwiftSection 的一个新 target，RuntimeViewer 新增一个命令扩展模块去调用它，三个前端共用：GUI（Find 导航页加 Call Hierarchy / Callees / Type References 三种模式，内容区的方法名上右键发起查询，Inspector 新增跟随光标的 References 标签）、CLI（`callers` / `callees` / `references`）和 MCP（`Callers` / `Callees` / `TypeReferences`）。查调用者有两条路：按需查询先用导入表和 selector 引用筛出可能相关的库、只扫这些库；第一次跨库查询时，本地运行时 service 在后台把整个 macOS 共享缓存扫一遍，按缓存 UUID 存盘，建好后自动切过去。精度如实标注：ObjC 以 selector 为准，能确定接收者类时标出类；Swift 的虚方法、协议方法、闭包调用给出候选目标。

## 动机

RuntimeViewer 现在只呈现**声明**：接口文本、成员，以及成员的地址（`RuntimeEngine.memberAddresses(for:memberName:)`，`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:1296`）。它回答不了「这个方法做了什么、谁在用它」。要回答这个问题，就得离开 RuntimeViewer：为目标库准备 IDA 数据库，在 IDA 里定位函数，再逐条看交叉引用。

本仓库自己的工作流就卡在这一步：

- `AGENTS.md` 的「How to establish a fact, cheapest first」（第 786–792 行）把「它调不调我的 hook、在什么条件下调」列为只能靠 idalib 反编译回答的问题，RuntimeViewer 在这里只负责提供地址。
- `Documentations/ResolvedIssues/` 里有 10 篇的定位过程用到了 IDA 或反编译。典型的是[侧栏焦点停在导航容器上](../ResolvedIssues/2026-09-24-sidebar-focus-parked-on-a-navigation-container.md)：第 81–104 行逐个找出 AppKit 里是谁在调 `makeFirstResponder:`（`-[NSWindow _handleLeftMouseDownEvent:isDelayedEvent:]` 的 0x1859dbc2c、`-[NSTableView mouseDown:]` 的 0x184c890cc……），这本身就是「`makeFirstResponder:` 的调用者」这一条查询。
- 经 MCP 与 `runtime-viewer-cli` 工作的 agent 完全没有交叉引用可用，只能拿 `members` 给出的地址再去开 IDA。

用户的原始需求（2026-10-16）：「从汇编中检查引用关系……比如在某个方法里面调用了别的方法，交叉引用功能」，并限定「只做有符号的函数，被脱掉符号的函数不做」。

## 前期调研

除特别注明外，实测都在 macOS 26.7（25G229）、Apple 芯片、arm64e 系统共享缓存上进行，工具是系统自带的 `dyld_info`。

### 系统框架里的调用长什么样（实测）

`-[NSWindow makeKeyAndOrderFront:]`（0x184AE35C0）里的全部调用：

```
0x184AE35D4   bl       _objc_msgSend$_makeKeyRegardlessOfVisibility
0x184AE35E4   bl       "_objc_msgSend$orderWindow:relativeTo:"
0x184AE3604   b        _objc_msgSend$_enableEnablingKeyEquivalentForDefaultButtonCell
```

从 Xcode 14 的工具链起，每个 ObjC 消息发送都会跳到一段以 selector 命名的小中转代码（`__objc_stubs` 段，下称 **selector 桩**），系统框架也是这么编的：AppKit 的 `__objc_stubs` 有 1,098,432 字节，Foundation 有 183,200 字节。所以看跳转目标就知道发的是什么消息，不必往回追 `x1` 寄存器。

整库统计（用 `dyld_info -disassemble` 全量反汇编，再按调用目标的名字归类；「直接调用」指 `bl`，以及跳到有名字目标的 `b`；「间接调用」指 `blr`、`blraa` 等跳到寄存器里地址的调用）：

| | AppKit | SwiftUICore |
|---|---|---|
| `__text` 大小 | 17,731,664 字节 | 13,996,136 字节 |
| 指令数（含桩代码段） | 约 473 万 | 约 351 万 |
| 调用点总数 | 702,444 | 345,829 |
| 目标能静态确定 | 93.1% | 86.7% |
| 间接调用 | 2.1%（15,034） | 13.2%（45,769） |
| 跳进无符号代码 | 4.8%（33,755） | 0.04%（137） |

直接调用按目标再细分：

- **AppKit**（687,410 个）：selector 桩 43.2%，ObjC 的 retain / release 一类内存管理调用 28.1%，C 函数等其他具名目标 13.2%，其他 ObjC 运行时函数 5.2%，无符号地址 4.9%，Swift 运行时 3.6%，`objc_msgSendSuper` 1.1%，直接调用 ObjC 方法 0.5%。
- **SwiftUICore**（300,060 个）：具名 Swift 函数 81.3%（其中 153,236 个其实是经 `__auth_stubs` 的跨库调用，见下节），outlined copy / destroy 这类编译器生成的值操作 10.5%，类型元数据访问器 4.5%，C 函数等 2.6%，selector 桩 1.1%。

结论：以 ObjC 为主的代码几乎全能认；以 Swift 为主的代码有一成多是虚方法、协议方法和闭包的间接调用。AppKit 近三成调用是内存管理调用，SwiftUICore 一成是 outlined 值操作，这些都得默认滤掉。

### 中转代码的名字不能照搬最近的符号（实测）

SwiftUICore 的 `__auth_stubs` 有 35,120 字节，共 2,195 个 16 字节的桩，每个都是 `adrp x17 / add / ldr x16, [x17] / braa x16, x17`。`dyld_info` 把它们全部标成了同一个名字 `_$s7SwiftUI11DisplayListV10PropertiesVs9OptionSetAAsAFP8rawValuex03RawI0Qz_tcfCTW`，而真正叫这个名字的，是 0x22D961B2C 处一个只有三条指令的函数。跳进这些桩的 `bl` 有 153,236 个，占 SwiftUICore 全部 `bl`（279,270 个）的 54.9%；同时整个库里没有一个调用目标叫 `_swift_retain` / `_swift_release`，可见被认错的多半就是跨库的 retain / release 等调用（推测，未逐个核对）。所以桩必须单独解析：按 MachOKit 解码出的桩，取它的间接符号序号或它取指针的那个槽位，不能按地址去找最近的符号。

### 进程里能看到多少符号（实测）

| | 本地符号 | 导出符号 | 导入符号 | 间接符号表 |
|---|---|---|---|---|
| AppKit | 166,824 | 4,090 | 4,993 | 12,637 |
| SwiftUICore | 140,368 | 46,108 | 3,682 | 5,609 |

（数据来自 `dyld_info -load_commands` 的 `LC_DYSYMTAB`。）`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/` 下没有单独的 `.symbols` 文件，本地符号就在每个镜像自己的 `LC_SYMTAB` 里，而 MachOKit 的 `MachOImage.symbols64` 读的正是它（`MachOKit/Sources/MachOKit/MachOImage.swift:215-225`）。所以**在 macOS 上，进程内的 RuntimeViewer 能看到系统库几乎全部函数的名字**；`dyld_info -lookup_va` 也能把 0x184AE3608 叫成 `_NSWindowWakeDeferredIfNeeded` 这种不导出的 C 函数。

iOS 真机把本地符号放在单独的 `.symbols` 文件里，不映射进进程，`DyldCacheLoaded.localSymbolsInfo`（`DyldCacheLoaded.swift:183-191`）在那里是空的——这是推测，未在真机上核实。因此「靠元数据能叫出名字的方法也算」这条决定，对真机和第三方 App 的发布版意义最大。

### 跨库调用者可以先筛库（实测 + 推测）

- **导出函数**：共享缓存构建时把能直达的跨库调用改成了直接跳转，但调用方的导入记录还在。AppKit 对 `objc_retain` 的调用全是直接 `bl`，`dyld_info -imports` 里照样列着 `_objc_retain (from libobjc)`。所以「谁可能从外面调 S」就等于「导入了 S 的库」。（实测）
- **ObjC 消息**：每个库的 `__DATA_CONST,__objc_selrefs` 列出它引用的全部 selector（AppKit 有 332,784 字节，即 41,598 条），按 selector 名字就能筛出可能发送它的库。共享缓存里不同库的 selector 引用是否指向同一份字符串、从而可以直接比指针，尚未核实；方案按名字比较，不依赖这一点。
- **不导出的函数**：别的库调不到它（经函数指针的除外），只需查它所在的那个库。

### 规模（实测）

- 本机共享缓存有 3,648 个镜像，`__text` 合计约 2,740 MiB（`dyld_info -all_dyld_cache -segments`），约为 AppKit 的 162 倍。
- `dyld_info` 把 AppKit 全量反汇编成文本再统计，用了约 9 秒；SwiftUICore 约 7 秒。这只能当上限参考：它要输出几百万行文本，而专用扫描只认少数几种指令，应该快得多，但**未实测**。
- Mac Catalyst 进程与普通 macOS 进程用的是同一份缓存：`/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit [arm64e]` 就在 `dyld_info -all_dyld_cache` 的列表里。Rosetta 下运行的进程用另一份 `dyld_shared_cache_x86_64`。

### arm64e 上的间接调用（实测 + 推测）

SwiftUICore 里的两种典型形态：

```
0x22D963A88   ldr      x9, [x8, #0x30]!       ; 从表里取函数指针，x8 指向表项
0x22D963A98   mov      x17, x8
0x22D963A9C   movk     x17, #0x60f0, lsl #48  ; 表项地址与一个 16 位常量混合成鉴别值
0x22D963AA0   blraa    x9, x17

0x22D963D18   mov      x17, #0x489d           ; 只有 16 位常量
0x22D963D1C   blraa    x1, x17                ; 闭包 / 函数值调用
```

第一种从表（虚表或协议见证表）里取指针，表内偏移就写在 `ldr` 里；第二种是函数值调用。那个 16 位常量是指针认证（pointer authentication）的鉴别值。Swift 为虚表项、见证表项按声明，为函数值按函数类型来算这个值——**推测**：如果属实，它能把候选目标缩小到具体的声明，即使不知道接收者是什么类型。落地第一步对照编译器源码（`/Volumes/SwiftProjects/swift-project`）核实。

### 现成的零件（代码出处）

- **MachOKit**（RuntimeViewer 钉在 `next` 分支的 `ecae5d19`，其中已含上游作者 2026-09-28 加入的桩解码 `63231eb`，0.54.0 起发布）：
  - `SectionProtocol.stubs(in:)` / `objcStubs(in:)`（`Sources/MachOKit/LoadCommand/Model/Section+Stubs.swift`）。`Stub` 带 `address`、`indirectSymbolIndex` 与 `branch: .viaSlot / .direct / .unknown`（`Model/Stub.swift`）；`ObjCStub` 带 `selectorReference` 和 `selector(in:)`（`Model/ObjCStub.swift`）。
  - `StubDecoder` 能认 arm64 的四种桩形态，包括缓存构建器改写后的单条 `B`（`Model/StubDecoder.swift:133-188`）；目前没有针对缓存镜像的测试。
  - `closestSymbol`（`Protocol/MachORepresentable.swift:446-470`）、`functionStarts`、`indirectSymbols`；`DyldCacheLoaded.machOImages()` 不经 `dlopen` 就能枚举缓存里的每个镜像（`DyldCacheLoaded.swift:196`）。
- **MachOSwiftSection**（RuntimeViewer 钉在 `next` 分支的 `b7be58ec`）：
  - Capstone 已经链进每个引擎进程，链路是 `RuntimeViewerCore` → `SwiftDeclaration` / `SwiftDeclarationRendering` / `SwiftIndexing` → `SwiftThunkAnalysis` → Capstone。只开了 AArch64 后端（MachOSwiftSection `Package.swift:223-241`，swift-capstone `Package.swift:101-110`），X86 声明了但没有开。
  - `SwiftThunkAnalysis` 有一套与反汇编引擎无关的指令词汇 `ThunkInstruction`（`call`、`branch`、`indirectCall`、`materializePageAddress`、`loadFromMemory`、`signOrAuthenticatePointer`……），Capstone 只出现在 `CapstoneThunkDecoder.swift` 这一个文件里；`ThunkRegisterTracker` 负责跟踪 `adrp` + `add` 拼出来的地址。
  - `SymbolIndexStore` 收集本地与导出符号（`Sources/MachO/MachOSymbols/SymbolIndexStore.swift`）。
- **RuntimeViewer**：
  - 引擎只经内存里的 `MachOImage` 读镜像（`DyldUtilities.machOImage(forPath:)`，`RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/DyldUtilities.swift:179-211`），没有离线路径。
  - 成员：`RuntimeMemberDeclaration` / `RuntimeMemberKind` / `RuntimeMemberMatch`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeMemberDeclaration.swift`）、`RuntimeMemberDeclarationLocator`（`RuntimeViewerCore/Sources/RuntimeViewerCore/Search/`）、`RuntimeMemberAddress`（mangled 符号名与未滑动地址）。Find 的成员命中经 `ContentHighlightRequest` 滚到声明行并闪一下（`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Content/ContentHighlightRequest.swift`、`Find/FindViewModel.swift:348-372`）。
  - 内容区只有类型名带链接（`.type` span，`RuntimeViewerApplication/Theme/FrozenSemanticString+ThemeProfile.swift:52-183`），成员名没有身份；右键菜单也只出现在类型名上（`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentTextViewController.swift:161-177`、`ContentSourceEditorViewController.swift:230-242`）。
  - 命令扩展：`RuntimeEngine.addCommandExtension(named:install:)`（`RuntimeEngineCommandRegistrar.swift:197-208`），范式是 `RuntimeViewerInjection`；需要进度、可跨连接取消的命令走 `RuntimeEngineProgressCommand`（`RuntimeEngineCommand.swift`）。
  - 后台工作：`RuntimeEngineBackgroundWork`，以及 Find 语料（`RuntimeInterfaceCorpusStore`，在引擎进程里，256 MB 的 LRU 预算，不存盘）；App Nap 由 `BackgroundWorkProcessActivity` 挡住。
  - CLI 一个意图对应一个子命令（`RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/Model/Command.swift`、`CommandLine/Subcommands.swift`），全局选项已有 `--source`、`--json`、`--timeout`；MCP 工具是 `MCPBridgeServer` 上的 `@MCPTool` 方法（`memberAddresses` 在第 391 行附近）。

### 前人怎么做的

- **Xcode**：Find 导航页有 Call Hierarchy 模式（Xcode 27.2 beta 2 的 IDEFoundation 里有 `IDEBatchFindCallHierarchyQuery`，IDEKit 里有 `IDEFindNavigatorCallHierarchyQuery`），编辑器的 Related Items 菜单里有 Callers / Callees。本提案的 GUI 照这两处来做。
- **IDA / Hopper**：ObjC 消息发送一律按 selector 给出交叉引用，不推断接收者；虚方法调用不给目标。本提案的精度分级与它们一致，只多了「能确定时标出接收者类」和「给出候选目标」。
- **`dyld_info`**：`-disassemble` 会给调用目标起名，`-dlopens` / `-dlsyms` 会静态读出 `dlopen` / `dlsym` 的参数——苹果自己的工具就在做调用点分析。但它会把桩认错（见上文），不能当数据源。
- **swift-decompiler**（同级仓库）：一套完整的提升与结构化管线。它自己的 `AGENTS.md` 记录，Capstone 参考路径在大函数上跑不完（一个 312 个基本块的函数，420 秒内结构化不完）。交叉引用只需要调用点，不需要提升，所以不以它为基础。

### 验证过什么、还没验证什么

- 已验证：上文标「实测」的各条。
- 未验证（落地第一步做）：在 App 进程里读取未加载缓存镜像的代码；专用扫描的吞吐，以及全量索引的大小与耗时；arm64e 鉴别常量能否反查到声明；iOS 真机与 Simulator 上本地符号放在哪里；缓存里的 selector 引用是否已唯一化。

## 提议方案

一句话概括：**MachOSwiftSection 负责从一个镜像里读出「有名字的函数」和「每个函数引用了什么」，RuntimeViewer 负责查询、索引、路由和三个前端。**

1. **有名字的函数**：符号表里位于代码段的符号；ObjC 类与分类的方法表里的实现（`-[类 selector]`）；Swift 类型描述、虚表、协议遵循里能找到实现地址的方法。同一地址上的多个名字合并为一个函数。其余代码不分析，作为调用目标出现时显示为「无符号函数 0x…」。
2. **引用**：逐条解码有名字函数的 arm64 指令，认出直接调用与尾调用、selector 桩与传统的 `objc_msgSend`、super 发送、经桩的跨库调用、类型引用（Swift 元数据访问器、按 mangled 名字实例化类型、ObjC 类引用）以及间接调用。
3. **精度**：ObjC 以 selector 为准，接收者是 `self`、类字面量（`[NSWindow alloc]`）或 super 时标出类并允许按类过滤，否则标为「接收者未知」；Swift 间接调用给出候选目标，并标为「候选」；retain / release、outlined 值操作等运行时辅助调用默认隐藏。
4. **查询**：查「调了谁」只解码这一个函数；查「谁调了它」和「哪些方法用到某个类型」时，本库直接扫，跨库则先按导入表与 selector 引用筛库再扫；第一次跨库查询时，本地运行时 service 在后台建全量索引并存盘，建好后跨库查询改走索引。
5. **前端**：Find 导航页的三种新模式、内容区右键、Inspector 的 References 标签；CLI 三个子命令；MCP 三个工具。
6. **范围**：跨库指整个共享缓存，加上目标进程里已加载的非系统库。全量索引只为本机这份 macOS 缓存而建，本地引擎、Mac Catalyst 引擎、注入的 macOS 进程共用；Simulator 与 iOS 真机只做按需查询。只支持 arm64 / arm64e。

### 非目标

- 给脱了符号、元数据也叫不出名字的代码划定函数边界或起名。
- x86_64：Intel Mac，以及 Rosetta 下运行的进程。
- 字符串常量与全局变量的引用。
- 完整的接收者类型推断（跨调用、跨返回值的数据流分析）。
- 在 RuntimeViewer 里显示反汇编或伪代码。
- Simulator 与 iOS 真机的全量索引；从缓存文件离线建索引。
- 经数据结构间接传递的引用（存进表里的回调）和 `performSelector:`、`NSSelectorFromString` 这类动态派发——静态分析看不见。
- 修改现有的 Find 模式、Relationships 标签或生成侧的语义标注。

## 详细设计

### 1. 分层

```
MachOSwiftSection / CrossReferenceAnalysis（新 target，名字暂定）
    有名字的函数、单函数的引用提取、桩与 selector 解析、类型引用、运行时辅助调用分类、预筛
        ↑
RuntimeViewerCore 包 / RuntimeViewerCrossReferences（新模块，命令扩展）
    引擎命令；本库扫描与会话缓存；跨库按需扫描；全量索引的构建与读取（在本地运行时 service 里）
        ↑
RuntimeViewerEngineManagement / RuntimeCrossReferenceRouter（新类型）
    决定一次查询交给哪个引擎、能不能用本机的全量索引、结果怎样合并；App 与 CLI host 共用
        ↑
App（Find / 内容区 / Inspector / Report） · CLI（callers / callees / references） · MCP（Callers / Callees / TypeReferences）
```

`RuntimeViewerCore` 模块本身一行不改（`AGENTS.md` Development Guidelines 第 9 条）。和 `RuntimeViewerInjection` 一样，**每个 serve 引擎并链接了新模块的进程，都要在入口调用一次 `RuntimeCrossReferences.install()`**，漏调不会有编译错误；落地时把这条义务写进 `AGENTS.md`。

### 2. MachOSwiftSection：`CrossReferenceAnalysis`（形状，以库提案为准）

签名只列 `MachOImage`；是否对 `MachOFile` 泛型由库提案决定（离线建索引是本提案的非目标）。

```swift
import MachOKit

/// A function the analysis can name.
public struct NamedFunction: Hashable, Sendable {
    public enum Name: Hashable, Sendable {
        /// From the symbol table: mangled Swift, C, or `-[Class selector]`.
        case symbol(String)
        /// From an Objective-C method list, when the symbol was stripped.
        case objectiveCMethod(className: String, selector: String, isClassMethod: Bool)
        /// From a Swift method descriptor or witness, when the symbol was stripped.
        case swiftMethod(descriptorAddress: UInt64)
    }

    /// Unslid address of the first instruction.
    public let address: UInt64
    /// Bytes up to the next function start.
    public let size: Int
    public let name: Name
    /// Other symbols at the same address, from identical code folding.
    public let foldedSymbolNames: [String]
}

/// What an Objective-C send's receiver is known to be.
public enum ReceiverClassHint: Hashable, Sendable {
    /// The method's own receiver, still in the register it arrived in, or a copy of it.
    case methodReceiver
    /// Loaded from a class reference: `[NSWindow alloc]`.
    case classLiteral(String)
    case unknown
}

/// Evidence for an indirect call's possible targets.
public struct IndirectCallEvidence: Hashable, Sendable {
    /// Displacement of the load that produced the callee, when it came from a table.
    public let tableOffset: Int64?
    /// The 16-bit constant blended into the arm64e discriminator, when there is one.
    public let pointerAuthenticationConstant: UInt16?
}

public enum CodeReferenceTarget: Hashable, Sendable {
    /// A function in this image, or in another shared-cache image after the cache builder bypassed the stub.
    case address(UInt64)
    /// Through one of this image's symbol stubs, resolved to the imported symbol.
    case importedSymbol(name: String)
    case messageSend(selector: String, receiver: ReceiverClassHint)
    case superMessageSend(selector: String, className: String?)
    /// A call to a Swift type metadata accessor (`$s…Ma`).
    case typeMetadataAccessor(symbolName: String)
    /// A type instantiated from its mangled name (`__swift_instantiateConcreteTypeFromMangledName`).
    case mangledTypeName(String)
    /// An Objective-C class reference (`__objc_classrefs`, `objc_alloc`, `objc_opt_class`).
    case objectiveCClass(name: String)
    case indirect(IndirectCallEvidence)
}

public struct CodeReference: Hashable, Sendable {
    /// Unslid address of the referencing instruction.
    public let instructionAddress: UInt64
    public let isTailCall: Bool
    public let target: CodeReferenceTarget
    /// A retain or release, an outlined value operation, or another runtime helper.
    public let isRuntimeHelperCall: Bool
}

public enum CrossReferenceAnalysis {
    public static func namedFunctions(in machO: MachOImage) throws -> [NamedFunction]
    public static func references(madeBy function: NamedFunction, in machO: MachOImage) throws -> [CodeReference]
    /// Images whose imports include `symbolName` — the only ones that can call it from outside its own image.
    public static func images(importing symbolName: String, among candidates: [MachOImage]) -> [MachOImage]
    /// Images whose selector references include `selector`.
    public static func images(referencingSelector selector: String, among candidates: [MachOImage]) -> [MachOImage]
}
```

### 3. 解码与分类

对每个有名字的函数，从起点解码到下一个函数的起点；`LC_DATA_IN_CODE` 标出的数据区跳过。只关心下表中的几类指令，其余指令只用来更新寄存器跟踪器（沿用 `ThunkRegisterTracker` 的做法：只记录能确定的地址与立即数，推不出来的就记为未知，绝不猜测）：

| 指令 | 产生什么 |
|---|---|
| `bl imm` | 调用 `address(imm)`，再按目标所在的段分类 |
| `b imm`，目标在本函数之外或是已知函数的起点 | 尾调用，分类同上 |
| `blr` / `blraa` / `blraaz` / `blrab` / `blrabz` | 间接调用，附带表内偏移与鉴别常量 |
| 函数末尾的 `br` / `braa` | 间接尾调用 |
| `adrp` 加 `add` 或 `ldr` | 地址进入跟踪器：selector 引用、类引用、mangled 名字的缓存变量、GOT 槽 |
| `movk x17, #imm, lsl #48` | 记下紧随其后的 `blraa` 所用的鉴别常量 |

调用目标按它落在哪里分类：

| 目标落在 | 解释成 |
|---|---|
| 本镜像的 `__objc_stubs` | `messageSend`：selector 由 `ObjCStub.selector(in:)` 给出；接收者看调用前 `x0` 的来源 |
| `objc_msgSend`（传统写法） | `messageSend`：selector 取调用前 `x1` 里装入的 selector 引用 |
| `objc_msgSendSuper2` | `superMessageSend`：类取自 `__objc_superrefs` |
| 本镜像的 `__stubs` / `__auth_stubs` | `importedSymbol`：桩的间接符号序号给出名字，再与它取指针的槽位交叉核对 |
| 本镜像里有名字的函数 | `address` |
| 别的缓存镜像（缓存构建器绕过了桩） | `address`：按缓存镜像的地址区间找到所在镜像，再到它的函数表里查 |
| `$s…Ma` 元数据访问器 | `typeMetadataAccessor` |
| `__swift_instantiateConcreteTypeFromMangledName(V2)`、`swift_getTypeByMangledName*` | `mangledTypeName`：名字取自 `x0` 指向的缓存变量 |
| 以上都不是 | 无符号代码 |

运行时辅助调用的名单由库维护，包括 `objc_retain*`、`objc_release*`、`objc_autorelease*`、`objc_storeStrong`、`objc_*Weak*`、`swift_retain*`、`swift_release*`、`swift_bridgeObject*`、`swift_unknownObject*`、`swift_beginAccess` / `swift_endAccess`、outlined copy / destroy 这类 `WO*` 后缀的函数、`__swift_destroy_boxed_opaque_existential_*` 等。结果里只打标记，过滤交给前端。

### 4. 精度规则

- **ObjC 接收者**：调用前的 `x0` 是方法入口时的 `x0`，或者是它的副本（编译器常把它挪进 `x19`–`x28`）→ `methodReceiver`；来自类引用 → `classLiteral`；super 发送 → 类已知；其余情况记为 `unknown`。查调用者时，`-[NSWindow makeKeyAndOrderFront:]` 的结果是所有发送 `makeKeyAndOrderFront:` 的地方：接收者已知但不属于 `NSWindow` 这一系的排除，未知的保留，并标为「按 selector 匹配」。
- **Swift 间接调用**：(a) 接收者类型已知（比如就是方法自己的 `self`）时，按表内偏移查这个类的虚表或协议见证表，得到唯一目标；(b) 否则，如果鉴别常量能反查到声明（第一步核实），按常量取候选；(c) 两者都不行时，按表内偏移列出所有类型在这个偏移上的方法，作为候选。候选一律标为「候选」，查调用者时也算在内，所以虚方法与协议方法的调用者不会整批漏掉。
- **代码合并**（identical code folding，链接器把完全相同的函数体合并成一份）：按地址算作一个函数，显示主名并注明「与 N 个函数代码相同」；查其中任何一个名字的调用者，得到的都是这个地址的全部调用者。
- **泛型特化**：`…Tg5` 等特化副本归到原声明名下，查原声明的调用者时，包含调用特化副本的地方。
- **无符号目标**：显示为「无符号函数 0x…」，不能再往下展开；无符号函数本身不会出现在调用者结果里。

### 5. RuntimeViewer：线上类型与引擎命令

新模块 `RuntimeViewerCrossReferences` 放在 `RuntimeViewerCore` 包内，依赖 `RuntimeViewerCore`、`RuntimeViewerCommunication`，以及 MachOSwiftSection 的 `CrossReferenceAnalysis`。

```swift
import Foundation
import RuntimeViewerCore

/// A member of a runtime object, as a cross reference points at it.
public struct RuntimeMemberReference: Hashable, Codable, Sendable {
    public let object: RuntimeObject
    public let name: String
    public let kind: RuntimeMemberKind
    public let isStatic: Bool
}

/// A function the analysis can name.
public struct RuntimeFunctionReference: Hashable, Codable, Sendable {
    public let imagePath: String
    /// Unslid address of the first instruction.
    public let address: UInt64
    /// As RuntimeViewer prints it: `-[NSWindow makeKeyAndOrderFront:]`, `SwiftUI.ViewGraph.updateOutputs()`, `CFRelease`.
    public let displayName: String
    /// The symbol the name came from, mangled for Swift; `nil` when only metadata names it.
    public let symbolName: String?
    /// The member this function implements, when it maps to one.
    public let member: RuntimeMemberReference?
    /// Other symbols sharing this address because the linker folded identical code.
    public let foldedSymbolCount: Int
}

public enum RuntimeCrossReferenceKind: String, Hashable, Codable, Sendable {
    case call
    case tailCall
    case messageSend
    case superMessageSend
    case typeReference
    case indirectCall
}

public enum RuntimeCrossReferencePrecision: String, Hashable, Codable, Sendable {
    /// The instruction names its target.
    case exact
    /// An Objective-C send whose receiver's class is not known.
    case matchedBySelector
    /// One of several targets an indirect call may reach.
    case candidate
}

public enum RuntimeCrossReferenceTarget: Hashable, Codable, Sendable {
    case function(RuntimeFunctionReference)
    case selector(name: String, receiverClassName: String?)
    case type(name: String, object: RuntimeObject?)
    case unnamedCode(imagePath: String, address: UInt64)
}

public struct RuntimeCrossReference: Hashable, Codable, Sendable {
    /// The function the referencing instruction belongs to.
    public let referencingFunction: RuntimeFunctionReference
    /// Unslid address of the referencing instruction.
    public let instructionAddress: UInt64
    public let kind: RuntimeCrossReferenceKind
    public let target: RuntimeCrossReferenceTarget
    public let precision: RuntimeCrossReferencePrecision
    public let isRuntimeHelperCall: Bool
}

public enum RuntimeCrossReferenceSubject: Hashable, Codable, Sendable {
    case function(imagePath: String, address: UInt64)
    case member(RuntimeMemberReference)
    /// Every send of this selector, whatever the receiver.
    case selector(String)
}

public enum RuntimeCrossReferenceScope: Hashable, Codable, Sendable {
    case image(path: String)
    /// The whole dyld shared cache plus every loaded image outside it.
    case allImages
}

public struct RuntimeCrossReferenceQueryOptions: Hashable, Codable, Sendable {
    public var includesRuntimeHelperCalls = false
    /// Keeps only sends whose receiver is known to be this class, or is unknown.
    public var receiverClassName: String?
    public var resultLimit: Int?
}

public struct RuntimeCrossReferenceQueryProgress: Hashable, Codable, Sendable {
    public let scannedImageCount: Int
    public let totalImageCount: Int
}

public struct RuntimeCrossReferenceQueryResult: Hashable, Codable, Sendable {
    public enum Source: String, Hashable, Codable, Sendable {
        case onDemandScan
        case persistentIndex
    }

    public let references: [RuntimeCrossReference]
    /// `false` when a limit, a time budget or a cancellation cut the scan short.
    public let isComplete: Bool
    public let source: Source
}

public struct RuntimeSharedCacheIdentity: Hashable, Codable, Sendable {
    public let uuid: UUID
    public let architecture: String
}

public enum RuntimeCrossReferenceIndexState: Hashable, Codable, Sendable {
    /// Not a macOS shared-cache engine, or not arm64 / arm64e.
    case unavailable(reason: String)
    case notBuilt(RuntimeSharedCacheIdentity)
    case building(RuntimeSharedCacheIdentity, completedImageCount: Int, totalImageCount: Int)
    case ready(RuntimeSharedCacheIdentity, byteCount: Int64)
}
```

调用方 API（命令类型归在 `RuntimeCrossReferences` 命名空间下，与 `RuntimeInjection` 的写法相同）：

```swift
extension RuntimeEngine {
    /// What `subject` references. Decodes that one function only.
    public func callees(
        of subject: RuntimeCrossReferenceSubject,
        options: RuntimeCrossReferenceQueryOptions
    ) async throws -> RuntimeCrossReferenceQueryResult

    /// Who references `subject` within `scope`.
    public func callers(
        of subject: RuntimeCrossReferenceSubject,
        in scope: RuntimeCrossReferenceScope,
        options: RuntimeCrossReferenceQueryOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
    ) async throws -> RuntimeCrossReferenceQueryResult

    /// Which functions reference the type `object` within `scope`.
    public func typeReferences(
        to object: RuntimeObject,
        in scope: RuntimeCrossReferenceScope,
        options: RuntimeCrossReferenceQueryOptions,
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceQueryProgress) async -> Void
    ) async throws -> RuntimeCrossReferenceQueryResult

    /// The shared cache this engine's process maps, so a router can tell which engines can share one index.
    public func sharedCacheIdentity() async throws -> RuntimeSharedCacheIdentity?

    public func crossReferenceIndexState() async throws -> RuntimeCrossReferenceIndexState

    /// Builds the persistent index of this engine's shared cache. Only the local runtime engine is asked to.
    public func buildCrossReferenceIndex(
        reportProgress: @escaping @Sendable (RuntimeCrossReferenceIndexState) async -> Void
    ) async throws -> RuntimeCrossReferenceIndexState
}

extension RuntimeEngine.CommandName {
    static let crossReferenceCallees = Self("crossReferenceCallees")
    static let crossReferenceCallers = Self("crossReferenceCallers")
    static let crossReferenceTypeReferences = Self("crossReferenceTypeReferences")
    static let sharedCacheIdentity = Self("sharedCacheIdentity")
    static let crossReferenceIndexState = Self("crossReferenceIndexState")
    static let buildCrossReferenceIndex = Self("buildCrossReferenceIndex")
}
```

- 线上名字保留 Core 的命名空间前缀（`RuntimeViewerInjection` 的 `RuntimeInjection+CommandNames.swift` 讲了原因：拼出来的完整字符串就是线上契约）。
- `callers`、`typeReferences`、`buildCrossReferenceIndex` 是 `RuntimeEngineProgressCommand`，并把 `cancelsAcrossConnections` 设为 `true`：调用方一取消，请求就从提供服务的那一端撤回。
- 旧引擎（没有这个扩展的载荷、旧版 App 的对端）对这些命令没有处理器，派发会失败；前端统一显示「这个引擎不支持交叉引用（需要更新载荷或 App）」，与注入能力查询的处理方式一致。

### 6. 查询路径

**调了谁**：在 subject 所在的镜像里找到函数——成员沿用 `memberAddresses` 的取法得到实现地址，ObjC 方法用 IMP；selector 作为 subject 没有意义，直接报错——然后只解码这一个函数。函数通常不到 1 KB，预计瞬间完成（未实测）。

**本库的调用者与类型引用**：第一次查某个镜像时，把它的全部有名字函数扫一遍，把「目标 → 引用」的反向表留在引擎进程里。每个镜像一份，会话内有效，按字节预算做 LRU 淘汰，做法与 Find 语料相同。

**跨库按需查询**：

1. 预筛：导出符号 → 导入了它的镜像；ObjC 方法 → 引用了这个 selector 的镜像；类型 → 导入了它的类型描述符（`$s…Mn`）、元数据访问器（`$s…Ma`）或 `_OBJC_CLASS_$_…` 的镜像；不导出的函数 → 只有它所在的镜像。候选镜像取自 `DyldCacheLoaded.machOImages()`，再加上进程里已加载的非缓存镜像。
2. 逐个扫描候选镜像（复用本库扫描的反向表），按镜像报告进度，结果随到随出。
3. 取消与时限：调用方取消即撤回（`cancelsAcrossConnections`）；MCP 的 30 秒或 CLI 的 `--timeout` 一到，就返回已有结果并标 `isComplete == false`。

**全量索引**：

- **触发**：某个引擎第一次收到跨库查询，且它映射的是本机这份 macOS 缓存（`sharedCacheIdentity` 与本地引擎相同）时，路由器请本地引擎开始建索引；这次查询本身仍走按需查询。
- **谁来建**：在 App 里是本地运行时 service（`RuntimeViewerLocalRuntimeService`，不受沙盒限制）；在 CLI 独立 host 里是 host 进程自己（它的 `.local` 引擎在进程内）。
- **怎么建**：用 `DyldCacheLoaded.machOImages()` 枚举全部镜像，有界并发、utility 优先级，前台查询优先（沿用[后台索引给前台加载让路](0027-background-indexing-yields-to-foreground.md)的做法）。建索引期间 App 持有 `BackgroundWorkProcessActivity`：service 的优先级跟着等待它的请求走，App 一进入 App Nap，service 就只剩效率核可用（见 `AGENTS.md` 中 `RuntimeViewerLocalRuntimeService` 那一段）。
- **存在哪**：`~/Library/Caches/RuntimeViewer/CrossReferences/<缓存 UUID>/`，Debug 版是 `RuntimeViewer-Debug`，与设置文件的分法一致。格式带版本信息（格式版本、缓存 UUID、架构）；先写进临时目录，再整体改名到位；读取时整块映射进内存。内容包括字符串表、函数表（按地址排序），以及按目标分组的引用表（目标可以是函数地址、selector 或类型键）。具体布局写进实现说明。
- **失效**：缓存 UUID 变了（系统更新）就是另一份索引；建新索引时删掉本机已不存在的 UUID 目录；格式版本变了就重建。
- **复用**：本地引擎、Mac Catalyst 引擎、注入的 macOS 进程，只要 `sharedCacheIdentity` 相同，缓存镜像的部分都查这一份；目标进程里不在缓存中的镜像，仍由那个引擎按需扫描，结果由路由器合并。
- **进度**：Report 导航页新增一类条目「Cross-Reference Index」，显示镜像进度，可以取消。

**路由**：`RuntimeViewerEngineManagement` 新增 `RuntimeCrossReferenceRouter`，不依赖 AppKit / RxSwift，App 与 CLI host 共用。对引擎 E 的一次跨库查询：如果 E 与本地引擎共享缓存且索引已就绪，缓存部分查索引，非缓存部分交给 E 按需扫描，再合并；否则整体交给 E 按需扫描，并在条件满足时触发建索引。Simulator 与 iOS 真机的引擎只走按需查询。

### 7. GUI

**Find 导航页**：`FindMode` 新增三个 case。界面细节通过逆向 Xcode 27 的 `IDEFindNavigatorCallHierarchyQuery` 来对齐，不照着截图调。

| 模式 | 标题 | 查询框 | 结果 |
|---|---|---|---|
| `callHierarchy` | Call Hierarchy | 方法（`-[NSWindow makeKeyAndOrderFront:]`、Swift 名、符号名）或 selector | 调用者树：每个节点是一个函数，展开一层就查一次它的调用者 |
| `callees` | Callees | 方法 | 被调树：同样逐层展开 |
| `typeReferences` | Type References | 类型名 | 引用该类型的函数，按库、按类型分组 |

- 查询框的写法与 CLI 的目标写法相同（见第 8 节）。范围控件对这三种模式生效，默认查全部镜像，可以缩小到当前镜像。
- 每行显示函数名、所在镜像、调用点数量和精度标记（「按 selector」「候选」）；底部过滤栏加一个「显示运行时调用」开关。
- 结果能对应到某个类型成员时，点击沿用 Find 现成的成员高亮（`ContentHighlightRequest`），跳到声明行；对应不到的行（C 函数、无符号代码）只显示，不跳转。
- `FindResultNode.Content` 新增 `case crossReference(function: RuntimeFunctionReference, references: [RuntimeCrossReference])`，子节点按需加载。

**内容区右键**：内容区现在只有类型名带身份。成员这边不改生成侧的语义标注，而是按行对齐：利用 `RuntimeMemberDeclarationLocator` 已有的「成员 → 声明行」对应关系，把右键点到的那一行映射到成员。成员行的右键菜单加「Find Call Hierarchy」「Find Callees」，类型名的右键菜单加「Find Type References」，两条文本路径（`NSTextView` 与 SourceEditor）都要加。菜单项把查询填进 Find 导航页并切换过去；菜单命令的快捷键照 Xcode 的按键绑定（落地时从 Xcode 的绑定里取）。

**Inspector 的 References 标签**：

- `TabKind` 新增 `.references`，有成员的对象才显示。
- 跟随内容区光标：`DocumentState` 新增「光标所在成员」（`RuntimeMemberReference?`），由两条文本路径在选区变化时按行对齐更新。光标落在某个成员的声明里时，显示它的调用者、被调和类型引用三段；不在任何成员里时，显示当前类型本身的类型引用。
- 每段只列一层，行可点击跳转；段尾的「Show in Find Navigator」把同一条查询交给 Find，展开成树。
- 列表按 `AGENTS.md` 的导航列表规则，用 `SelfSizingTableView.scrollableNavigationListTableView()`；加载状态用 `withLoadingPlaceholder`；光标在同一个声明里移动时不重新查询（按成员身份比较）。

**Report 导航页**：全量索引构建期间多出一行，显示镜像进度，可以取消。

### 8. CLI 与 MCP

CLI 子命令（`Command` 新增 `.callers`、`.callees`、`.typeReferences`，都是只读的、可重试的）：

```
runtime-viewer-cli callers '-[NSWindow makeKeyAndOrderFront:]'
runtime-viewer-cli callers 'makeKeyAndOrderFront:' --selector
runtime-viewer-cli callers 'SwiftUI.ViewGraph.updateOutputs()' --image SwiftUICore
runtime-viewer-cli callers 0x184AE35C0 --image AppKit --scope image
runtime-viewer-cli callees '-[NSWindow makeKeyAndOrderFront:]' --include-runtime
runtime-viewer-cli references NSWindow --limit 200 --json
```

- **目标写法**：ObjC 写成 `-[类 selector]` 或 `+[类 selector]`；Swift 写可读名（与 `members` 输出的写法相同）；也可以写符号名（mangled 或 C 符号）；或者写 `0x` 开头的地址，这时必须配合 `--image`。加 `--selector` 时，参数被当作 selector，查它的所有发送者。
- **选项**：`--image`、`--scope image` 或 `--scope all`（`callers` 与 `references` 默认 `all`）、`--receiver <类>`、`--include-runtime`、`--limit <n>`；全局的 `--source`、`--json`、`--timeout` 照常可用。
- 在终端里于 stderr 显示镜像进度，Ctrl-C 取消；超时或取消时输出已有结果并注明不完整，退出码沿用现有约定。
- 同一个提交里更新 `AgentPlugins/runtime-viewer/` 的 skill，并把两个插件清单的 `version` 加一（`AGENTS.md` 第 478 行），同时更新 [`Guides/CommandLineInterface.md`](../Guides/CommandLineInterface.md)。

MCP 工具是 `MCPBridgeServer` 上的 `@MCPTool(hints: [.readOnly])` 方法，转成 PascalCase 后叫 `Callers` / `Callees` / `TypeReferences`：

```swift
func callers(windowIdentifier: String, target: String, imagePath: String? = nil, imageName: String? = nil, scope: String? = nil, receiverClassName: String? = nil, includeRuntimeHelperCalls: Bool = false, limit: Int? = nil) async throws -> MCPCrossReferencesResponse
func callees(windowIdentifier: String, target: String, imagePath: String? = nil, imageName: String? = nil, includeRuntimeHelperCalls: Bool = false) async throws -> MCPCrossReferencesResponse
func typeReferences(windowIdentifier: String, typeName: String, imagePath: String? = nil, imageName: String? = nil, scope: String? = nil, limit: Int? = nil) async throws -> MCPCrossReferencesResponse
```

每次调用最多等 30 秒，到时返回已有结果；响应里 `isComplete` 为 `false`，并注明后台仍在扫描（或全量索引正在构建），提示稍后重试。

### 9. 错误

- 引擎是 x86_64：报 `unsupportedArchitecture`；GUI 里三种模式和 References 标签置灰，并说明原因。
- 引擎没有这个扩展（旧载荷、旧版对端）：见第 5 节。
- 目标找不到：沿用 `members` 的「类型 / 成员不存在」错误。selector 没有任何发送者时返回空结果，不算错误。

## 替代方案考量

下面每条，要么是澄清提问里被否掉的方向，要么是调研中排除的做法。

- **第一版只做「调了谁」，或只查本库调用者**：用户要求第一版就能跨库找调用者——查公开 API 被谁用，正是最常见的问题。
- **先只做 CLI / MCP、GUI 另起提案；或只做 GUI**：三个前端共用一套命令，分开做反而要把目标写法与精度标注重复设计一遍。
- **只做调用**：类型是 RuntimeViewer 的导航单位，「哪些方法用到了这个类型」顺着现有导航就能用起来，代价只是多认几种调用目标。
- **再加字符串与全局变量引用**：要识别更多取地址的形态，还要为字符串和全局变量各做一套展示，留给后续提案。
- **分析逻辑全放在 RuntimeViewer 的新模块里**：离线的 `swift-section` 用不上；也违背了「二进制分析的规则放在 MachOSwiftSection，RuntimeViewer 只负责显示」的既有做法（[0031](0031-private-discriminator-tag.md)）。
- **新建一个独立的库**：多一个仓库、多一套发版流程；而 MachOSwiftSection 已经有 Capstone、thunk 分析和符号索引。
- **跨库只算目标进程已加载的库**：问「全系统谁在用」时会漏掉没加载的框架，而整个缓存本来就映射在每个进程里。
- **每次查询自己选一组库**：多一步选择；需要缩小范围时，用 Find 的范围控件或 CLI 的 `--scope` 即可。
- **只做按需查询，或只做全量索引**：前者每次查热门 selector 都要扫几百个库；后者第一次查询要等好几分钟。两者都做，按需查询立即可用，索引建好后自动切换。
- **ObjC 只按 selector**：能确定接收者的情况很常见（发给 `self` 的消息、类方法），标出来几乎不花成本，还能按类过滤。**完整推断接收者类型**则需要跨调用、跨返回值的数据流分析，工作量接近反编译器。
- **Swift 间接调用只列位置，或干脆不显示**：虚方法与协议方法的调用者会整批漏掉，而 SwiftUICore 里间接调用占全部调用的 13%。
- **单独开一个引用导航页**：要重复实现 Find 已有的查询框、范围控件和结果树。
- **每个引擎各建各的全量索引**：要处理目标进程的沙盒路径、真机上几分钟的满载扫描，以及分散在各处的多份索引。
- **只认符号表里的函数**：第三方 App 的发布版通常只剩导出符号，iOS 真机上的系统库也可能几乎一片空白（推测）。
- **同时支持 x86_64**：x86 指令是变长的，桩、selector 发送、虚方法调用的指令形态全都不同，相当于把识别工作再做一遍；而 macOS 26 是最后一个支持 Intel Mac 的版本。
- **App 启动后自动建索引，或只在手动执行命令时建**：前者每次系统更新后的第一次启动，都要在后台扫上几分钟；后者多一个步骤，大多数人永远用不上索引。
- **Inspector 只在右键时更新，或列出当前类型的全部方法**：前者每次都要多点一下；后者在索引建好之前，要为每个方法各查一遍调用者，太慢。
- **CLI 只加一个 `xrefs` 子命令、用参数选方向**：参数组合多；现有 CLI 是一个意图对应一个子命令（`hierarchy`、`relationships`、`members`）。
- **复用 swift-decompiler**：它是提升与结构化的管线，其 Capstone 参考路径在大函数上跑不完；交叉引用只需要调用点。
- **经 IDA（idalib）出交叉引用**：每个库都要先有 `.i64`，引擎进程和真机里都用不上，也绕不开 IDA 的许可。
- **解析 `dyld_info -disassemble` 的输出**：它把 SwiftUICore 一半以上的 `bl` 认错了目标，只能读 macOS 上的镜像，也不认元数据里的方法名。

## 影响

### 用户可见变化

- Find 导航页的模式路径多出三项：Call Hierarchy、Callees、Type References。
- 内容区右键：成员行多出「Find Call Hierarchy」「Find Callees」，类型名多出「Find Type References」；原有的 Jump to Definition、Open in New Tab 不变。
- Inspector 对有成员的对象多出一个 References 标签。
- 全量索引构建期间，Report 导航页多出一行。
- CLI 多出 `callers`、`callees`、`references` 三个子命令；MCP 多出 `Callers`、`Callees`、`TypeReferences` 三个工具。
- 不移除、不改变任何现有行为。

### 可发现性

- 入口在三处常用的位置：Find 的模式路径、内容区右键、Inspector 标签；菜单命令和快捷键照 Xcode。
- 默认开启，没有开关：平时不占用资源，全量索引只在第一次跨库查询时才开始建。
- CLI 的 `--help` 与 agent 插件的 skill 同批更新；装了插件的 agent 在插件版本号变化后会拿到新的用法。

### 数据与配置兼容

- 新增缓存目录 `~/Library/Caches/RuntimeViewer[-Debug]/CrossReferences/`。大小未实测，落地第一步量出来后写回本节。它放在 Caches 下，被系统清理或用户删除后，下次查询会自动重建。
- 不改动设置、书签或任何已有文件，无需迁移。
- 线上协议只新增命令；旧载荷与旧对端收到这些命令时派发失败，前端提示需要更新，不影响其他功能。

### 平台与最低版本

- 最低系统版本不变。新模块跟随 `RuntimeViewerCore` 的平台列表。
- macOS 本机、Mac Catalyst、注入的 macOS 进程：按需查询，并共用全量索引。
- iOS Simulator、iOS 真机（越狱版与注入）：只有按需查询；真机上可能拿不到系统库的本地符号（推测），但元数据能叫出名字的方法仍然覆盖。
- x86_64 引擎（Intel Mac、Rosetta 下的进程）：明确提示不支持。

### 发布

- 不需要新的权限、entitlement 或隐私清单条目：本地运行时 service 不受沙盒限制，写入的是用户自己的 Caches 目录。
- 不影响公证，也不影响 Sparkle 更新。App 体积几乎不变：Capstone 本来就链接在内。
- 发版顺序：带 `CrossReferenceAnalysis` 的 MachOSwiftSection 版本必须先发布，RuntimeViewer 的 `main` 才能用上（`main` 只针对已发布的依赖版本编译）。

## 落地步骤

1. **核实前提**（不写产品代码，结论写回「前期调研」）：在 App 进程里读取一个未加载缓存镜像的 `__text` 与符号表；测量 Capstone 与手写解码在 AppKit / SwiftUICore 上的吞吐，估算全量索引的耗时与大小；对照编译器源码核实 arm64e 鉴别常量能否反查到声明；核实 iOS 真机与 Simulator 上本地符号放在哪里。任何一条结论推翻了设计，就回到本提案修改，并重新确认。
2. **MachOSwiftSection 的库提案与 `CrossReferenceAnalysis`**：有名字的函数、单函数的引用提取、桩与 selector 解析、类型引用、运行时辅助调用分类、预筛；写 fixture 测试，并与 `dyld_info` / IDA 抽样对照。批量扫描如果采用手写解码，以 Capstone 的结果做对照测试。然后发版。
3. **`RuntimeViewerCrossReferences` 模块**：线上类型与命令；在 `AGENTS.md`「Injection commands」那张表列出的全部入口调用 `install()`，并把这条义务写进 `AGENTS.md`；本库扫描与会话缓存；跨库按需扫描（预筛、进度、取消）；路由器。
4. **CLI 与 MCP**：三个子命令、三个工具，agent 插件的 skill 与版本号，以及 `Guides/CommandLineInterface.md`。
5. **全量索引**：在本地运行时 service 里构建并存盘，失效与清理，App Nap 防护，Report 条目，跨引擎复用。
6. **Find 导航页的三种模式**：逆向 Xcode 27 的 Call Hierarchy 来对齐界面；结果树、范围控件、精度标记、运行时调用开关；按 `RuntimeViewerApplicationTests` 的规则写 ViewModel 契约测试。
7. **内容区右键与 Inspector 的 References 标签**：成员按行对齐、两条文本路径的菜单、光标所在成员、标签本身及其 ViewModel 测试。

每一步都能单独构建、单独验证；从第 3 步起，每一步都可以单独合入。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计需要：一份使用指南（目标写法、精度标注的含义、哪些引用静态看不见），一份实现说明（全量索引的格式、失效与复用规则）。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 预计有：交叉引用、全量交叉引用索引、按需查询与预筛、候选目标、运行时辅助调用。同批次登记进 `Documentations/Glossary.md`。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-16 | Created as Draft | 用户原话：「从汇编中检查引用关系这个好实现吗，比如在某个方法里面调用了别的方法，交叉引用功能」；中途限定「只做有符号的函数，被脱掉符号的函数不做」；随后要求「写一份完整提案」，按完整档拷问了四轮 |
| 2026-10-16 | 范围：调了谁 + 跨库的调用者 | 第一轮。推荐的「调了谁 + 本库调用者」与「只做调了谁」被否：第一版就要跨库 |
| 2026-10-16 | 前端：GUI、CLI、MCP 都做 | 第一轮。落地顺序是先引擎与 CLI / MCP，再做 GUI。否：先 CLI + MCP、GUI 另起提案；只做 GUI |
| 2026-10-16 | 引用种类：调用 + 类型引用 | 第一轮。否：只做调用；再加字符串与全局变量 |
| 2026-10-16 | 分析逻辑放进 MachOSwiftSection | 第一轮。否：全放在 RuntimeViewer 的新模块里；新建独立的库 |
| 2026-10-16 | 跨库范围：整个共享缓存 + 已加载的非系统库 | 第二轮。否：只算已加载的库；每次查询自己选 |
| 2026-10-16 | 查询：按需查询与全量索引都做，索引建好后自动切换 | 第二轮。推荐的「先按需查询、索引格式按能存盘设计、存盘留作后续」被否；也否了「只做全量索引」 |
| 2026-10-16 | ObjC：selector + 能确定的接收者类 | 第二轮。否：只按 selector；完整推断接收者类型 |
| 2026-10-16 | Swift 间接调用：列出并给出候选目标 | 第二轮。否：只列位置；不显示 |
| 2026-10-16 | GUI：Find 导航页三种模式 + 内容区右键，再加 Inspector 的 References 标签 | 第三轮，用户回答「1+2」。否：单独开一个引用导航页 |
| 2026-10-16 | 全量索引：本机一份，由本地运行时 service 来建 | 第三轮。否：每个引擎各建各的 |
| 2026-10-16 | 有名字的函数 = 符号表 + 元数据能叫出名字的方法 | 第三轮。否：只认符号表 |
| 2026-10-16 | 只支持 arm64 / arm64e | 第三轮。否：同时支持 x86_64 |
| 2026-10-16 | 全量索引在第一次跨库查询时开始建 | 第四轮。否：App 启动后自动建；只在手动执行命令时建 |
| 2026-10-16 | Inspector 标签跟随内容区光标 | 第四轮。否：只在右键时更新；列出当前类型的全部方法 |
| 2026-10-16 | CLI 三个子命令，MCP 三个工具 | 第四轮。否：一个 `xrefs` 命令带方向参数 |
| 2026-10-16 | 采用的默认假设 | 运行时辅助调用默认隐藏，三个前端都有开关；无符号目标显示地址；Find 的两种树逐层展开，范围控件生效；界面逆向 Xcode 来对齐；结果分组，可跳转的跳到声明行；代码合并按地址算，泛型特化归到原声明；MCP 30 秒上限，返回部分结果；建索引期间防 App Nap，前台优先；先实测 Capstone 再决定是否手写解码；暂定名 `CrossReferenceAnalysis` / `RuntimeViewerCrossReferences`；MachOSwiftSection 动工时另写库提案并引用本提案。共识清单列出后，用户没有逐条表态，直接要求「开分支先推送提案」，按确认处理 |
| 2026-10-16 | 写提案时补充的设计细节 | 未单独询问：菜单命令的快捷键照 Xcode；内容区的成员按行对齐，不改生成侧的语义标注；路由器放在 `RuntimeViewerEngineManagement`；CLI 独立 host 在自己进程里建索引。落地前有异议再改 |
| 2026-10-16 | 术语表登记推迟到落地 | 草案阶段的术语还可能改名；收尾时按「落地步骤」末尾的清单登记 |

# 0056 - 交叉引用：调用层级、被调与类型引用

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-16
- **最后更新**: 2026-10-19
- **所属愿景**: 无（CLI 与 MCP 部分沿用[《无头 RuntimeViewer》](../Visions/HeadlessRuntimeViewer.md)「GUI、命令行与 MCP 三个前端共用同一套命令词汇」的取向，但不推进该愿景的步骤）
- **关联提案**: [0029-find-navigator](0029-find-navigator.md)（Find 导航页、成员定位与高亮）、[0047-open-command-registry-and-injection-module](0047-open-command-registry-and-injection-module.md)（命令扩展范式）、[0037-local-runtime-xpc-service](0037-local-runtime-xpc-service.md)（本地运行时 service）、[0055-engine-scoped-background-work](0055-engine-scoped-background-work.md)（按 Engine 共享的后台工作与 Report）；MachOSwiftSection 侧的库提案 [0072-cross-reference-analysis](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0072-cross-reference-analysis.md)（MachOSwiftSection 的 `next`，2026-10-19 合入）
- **实现分支 / PR**: `feature/cross-references`（worktree `.worktrees/RuntimeViewer-CrossReferences`）；引擎与界面（落地步骤第 1–3、5、6 步）2026-10-19 合入 `next`，第 4 步在同一分支上继续
- **配套文档**: 待定 —— 落地时判断：CLI / MCP 的目标写法与精度标注是否需要使用指南；两种桩布局、鉴别常量反查这些解析规则是否需要实现说明

## 摘要

给 RuntimeViewer 加上从机器码里读出来的交叉引用：选中一个方法，能看到它**调了谁**（被调）、**谁调了它**（调用者，范围是引擎已索引的镜像），以及**哪些方法用到了某个类型**（类型引用）。函数的名字只取自符号表，以及 ObjC 方法表、Swift 类型描述能叫出名字的方法，不为脱了符号的代码推测名字；没有名字的函数照样扫描，作为调用者时显示成「无符号函数 0x…」。只支持 arm64 / arm64e。分析逻辑放进 MachOSwiftSection 的一个新 target，RuntimeViewer 新增一个命令扩展模块去调用它，三个前端共用：GUI（Find 导航页加 Call Hierarchy / Callees / Type References 三种模式，内容区的方法名上右键发起查询，Inspector 新增跟随光标的 References 标签）、CLI（`callers` / `callees` / `references`）和 MCP（`Callers` / `Callees` / `TypeReferences`）。查调用者一律按需扫描：先按导入的名字（C 与 ObjC 函数，含别的库改名再导出的名字）、链接关系（Swift 函数与类型）和 selector 引用筛出可能相关的库，只扫这些库，扫过的库在会话内缓存结果；实测扫完整个共享缓存也只要 1–4 秒，所以不做存盘的全量索引。精度如实标注：ObjC 以 selector 为准，能确定接收者类时标出类；Swift 的虚方法、协议方法给出候选目标，闭包调用只标出签名形态。

## 动机

RuntimeViewer 现在只呈现**声明**：接口文本、成员，以及成员的地址（`RuntimeEngine.memberAddresses(for:memberName:)`，`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:1296`）。它回答不了「这个方法做了什么、谁在用它」。要回答这个问题，就得离开 RuntimeViewer：为目标库准备 IDA 数据库，在 IDA 里定位函数，再逐条看交叉引用。

本仓库自己的工作流就卡在这一步：

- `AGENTS.md` 的「How to establish a fact, cheapest first」（第 786–792 行）把「它调不调我的 hook、在什么条件下调」列为只能靠 idalib 反编译回答的问题，RuntimeViewer 在这里只负责提供地址。
- `Documentations/ResolvedIssues/` 里有 10 篇的定位过程用到了 IDA 或反编译。典型的是[侧栏焦点停在导航容器上](../ResolvedIssues/2026-09-24-sidebar-focus-parked-on-a-navigation-container.md)：第 81–104 行逐个找出 AppKit 里是谁在调 `makeFirstResponder:`（`-[NSWindow _handleLeftMouseDownEvent:isDelayedEvent:]` 的 0x1859dbc2c、`-[NSTableView mouseDown:]` 的 0x184c890cc……），这本身就是「`makeFirstResponder:` 的调用者」这一条查询。
- 经 MCP 与 `runtime-viewer-cli` 工作的 agent 完全没有交叉引用可用，只能拿 `members` 给出的地址再去开 IDA。

用户的原始需求（2026-10-16）：「从汇编中检查引用关系……比如在某个方法里面调用了别的方法，交叉引用功能」，并限定「只做有符号的函数，被脱掉符号的函数不做」。落地第一步实测无符号函数占全缓存的一半，用户把这条调整为「不起名，但作为调用者照样列出地址」（见决策日志）。

## 前期调研

除特别注明外，实测都在 macOS 26.7（25G229）、Apple 芯片、arm64e 系统共享缓存上进行，工具是系统自带的 `dyld_info`。落地第一步在 macOS 27.2 上复测并补齐了未验证的各条，结果与两版之间的差别见本节末的[「落地第一步的核实」](#落地第一步的核实2026-10-16)。

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

（数据来自 `dyld_info -load_commands` 的 `LC_DYSYMTAB`。）`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/` 下没有单独的 `.symbols` 文件，本地符号就在每个镜像自己的 `LC_SYMTAB` 里，而 MachOKit 的 `MachOImage.symbols64` 读的正是它（`MachOKit/Sources/MachOKit/MachOImage.swift:215-225`）。所以在 macOS 上，镜像里留着的本地符号进程内都读得到；`dyld_info -lookup_va` 也能把 0x184AE3608 叫成 `_NSWindowWakeDeferredIfNeeded` 这种不导出的 C 函数。（原句是「进程内的 RuntimeViewer 能看到系统库几乎全部函数的名字」，见下面的更正。）

**2026-10-19 更正：本地符号在，不等于每个函数都有名字。** 上面只数了符号条数，没有按函数起点核对。按函数起点核对（`dyld_info -function_starts` 对没有确切符号的起点打印「前一个符号+偏移」，这样的起点算无名），macOS 26.7 整个缓存 1308 万个函数起点里 37.8% 没有符号，各镜像差别很大：

| 镜像 | 无名起点 | | 镜像 | 无名起点 |
|---|---|---|---|---|
| Foundation | 0% | | Charts | 91% |
| libswiftCore | 4% | | SwiftData | 83% |
| SwiftUICore | 6% | | `_MapKit_SwiftUI` | 81% |
| SwiftUI | 10% | | WidgetKit | 74% |
| AppKit | 13% | | AppIntents | 54% |

过半无名的镜像有 677 个，大量是用 Swift 写的框架，也有 libLLVM 这类 C++ 库。无名起点没有一个是导出的：剥掉的全是内部代码。符号剥掉之后，ObjC 方法还能从方法列表叫出名字，Swift 只有元数据访问函数、一次性初始化函数和类的虚表方法能从元数据叫出名字；结构体和枚举的方法、协议见证、值见证、闭包、特化都没有任何记录。所以在剥了符号的 Swift 框架里，一个类型的引用大多显示成 Unnamed function。

还能从元数据补回、不必猜的（估算）：名字齐全的 Swift 镜像（SwiftUICore、SwiftUI、libswiftCore、Combine）里，协议见证占全部函数的 11–18%，值见证占 4–13%，两者都能从见证表确定是谁的哪一项。剥了符号的镜像里另有 13–16% 的无名函数只是一条跳转（SwiftData 696、WidgetKit 1,444、Charts 1,504 个），但九成以上跳向的目标本身也无名，按目标起名补不回多少；它们多半是合并后的协议见证，见证表会直接指向它们。闭包、特化、结构体和枚举的方法补不回来。

iOS 真机把本地符号放在单独的 `.symbols` 文件里，不映射进进程，`DyldCacheLoaded.localSymbolsInfo`（`DyldCacheLoaded.swift:183-191`）在那里是空的。落地第一步读离线缓存核实：真机缓存里的本地符号条目和地址都还在，名字全是 `<redacted>`，真名只在不映射的 `.symbols` 文件里；Simulator 与 macOS 一样能读到名字。因此「靠元数据能叫出名字的方法也算」这条决定，对真机和第三方 App 的发布版意义最大。

### 跨库调用者可以先筛库（实测 + 推测）

- **导出函数**：共享缓存构建时把能直达的跨库调用改成了直接跳转，但调用方的导入记录还在。AppKit 对 `objc_retain` 的调用全是直接 `bl`，`dyld_info -imports` 里照样列着 `_objc_retain (from libobjc)`。所以「谁可能从外面调 S」就等于「导入了 S 的库」。（实测，macOS 26.7。27 起跨库调用改经全缓存共用的 GOT 桩，导入记录仍在符号表的未定义符号里，27.2 的 AppKit 有 5,085 个。）
- **ObjC 消息**：每个库的 `__DATA_CONST,__objc_selrefs` 列出它引用的全部 selector（AppKit 有 332,784 字节，即 41,598 条），按 selector 名字就能筛出可能发送它的库。共享缓存里不同库的 selector 引用是否指向同一份字符串、从而可以直接比指针，尚未核实；方案按名字比较，不依赖这一点。
- **不导出的函数**：别的库调不到它（经函数指针的除外），只需查它所在的那个库。

### 规模（实测）

- 本机共享缓存有 3,648 个镜像，`__text` 合计约 2,740 MiB（`dyld_info -all_dyld_cache -segments`），约为 AppKit 的 162 倍。
- `dyld_info` 把 AppKit 全量反汇编成文本再统计，用了约 9 秒；SwiftUICore 约 7 秒。这只能当上限参考：它要输出几百万行文本，而专用扫描只认少数几种指令，应该快得多。落地第一步实测：手写解码扫完 macOS 27.2 的整个缓存只要 1–4 秒，见下文。
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

第一种从表里取指针，表内偏移就写在 `ldr` 里；第二种是函数值调用。那个 16 位常量是指针认证（pointer authentication）的鉴别值。当初推测 Swift 为虚表项、见证表项按声明，为函数值按函数类型来算这个值，从而能把候选目标缩小到具体的声明。落地第一步对照编译器源码核实：虚表与见证表确实按（根）声明算，闭包只按很粗的签名算；而上面第一个例子其实是 value witness 调用，常量由编译器写死。详见本节末「落地第一步的核实」。

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

### 落地第一步的核实（2026-10-16）

环境：macOS 27.2（26B5112a），Mac Studio（28 核：20 个性能核、8 个能效核），本机共享缓存。工具是一个只读的 Swift 探针：它在自己的进程里读映射进来的共享缓存，依赖 MachOKit 与 swift-capstone，代码放在 agent 临时目录 `/Volumes/DerivedData/Agents.noindex/claude/Probes/CrossReferences/ScanProbe`，不在仓库里。下文的数字除特别注明外都出自它。

**进程内读取未加载的缓存镜像：可以。** 探针进程加载了 396 个镜像，`DyldCacheLoaded.machOImages()` 枚举出 4,113 个，每个的 `__text`、符号表、函数起点和 `__objc_selrefs` 都能读。AppKit 没有加载，照样读到 189,326 个符号，其中本地符号 180,071 个。要防的只有一件事：`__text` 里夹着数据（跳转表之类），按指令解码会得到指向任意地址的「跳转」，读目标之前必须确认它落在缓存的可执行映射里，否则进程直接崩溃——探针第一次全量扫描就崩在这里。

**macOS 27 与 iOS 27 的缓存里，镜像不再带自己的桩（设计没有预料到）。**

| 缓存 | ObjC 消息桩 | 跨库调用桩 |
|---|---|---|
| macOS 15.8 至 26.7、iOS 26.3.1 真机 | 镜像自己的 `__objc_stubs` | 镜像自己的 `__auth_stubs` |
| macOS 27.2、iOS 27.0 真机 | 这两个段在镜像里大小为 0，改用全缓存共用的 selector 桩 | 全缓存共用的 GOT 桩 |
| iOS 27.0 Simulator（arm64） | 镜像自己的 `__objc_stubs` | 镜像自己的 `__stubs` |

（离线缓存用 `ipsw dyld macho` 读，macOS 27.2 在进程内读。）

- 共用的 selector 桩是 `adrp x1, 页; add x1, x1, #偏移; b <objc_msgSend 副本>`：`x1` 直接就是 selector 字符串的地址，跳去的 `objc_msgSend` 副本在 `libobjcMsgSend1.dylib` 里。同一个 selector 在不同子缓存里各有一份桩，被调用的桩有 1,552,332 个，只对应 1,042,853 个不同的 selector 字符串，所以 **selector 要以字符串地址为键**，不能以桩地址为键。
- 共用的 GOT 桩是 `adrp x17, 页; add x17, x17, #偏移; ldr x16, [x17]; braa x16, x17`。在进程内读出槽位里已绑定的指针、去掉指针认证位，就是真正的目标。
- 全缓存的直接调用目标：本镜像内 33.4%，共用 GOT 桩 53.9%，共用 selector 桩 12.7%，镜像之间的直接调用只剩 7,666 处。上文「AppKit 对 `objc_retain` 的调用全是直接 `bl`」只对 26.x 及更早成立。
- 27.2 上 `dyld_info -disassemble` 也给这些调用起不出名字，只打印地址。

**扫描吞吐与全量规模。**

| | 实测 |
|---|---|
| 镜像 / `__text` 合计 | 4,113 个 / 3,511 MiB（26.7 是 3,648 个 / 约 2,740 MiB） |
| 指令 / 函数起点（其中有符号） | 9.2 亿条 / 16,603,678 个（8,383,181 个） |
| `bl` / 尾调用 `b` / 间接调用（其中带鉴别常量） | 1.007 亿 / 615 万 / 798 万（660 万） |
| 运行时辅助调用占直接调用目标 | 26.5% |
| 有符号函数：排除辅助调用后的调用点 / 去重后的「函数 → 目标」边 | 4,050 万 / 2,569 万 |
| 无符号函数：同上 | 3,799 万 / 2,589 万 |
| 第一阶段：所有镜像的函数表与符号归类 | 墙钟 0.09 秒（CPU 合计 2.1 秒） |
| 第二阶段：手写解码扫完整个缓存 | 28 线程 1.0 秒，8 线程 2.3 秒，4 线程 4.1 秒（CPU 合计 16–25 秒）；探针常驻内存约 390 MB |

单线程解码 AppKit（19 MiB `__text`）：

| 解码方式 | 吞吐 |
|---|---|
| 手写解码（只认第 3 节那几类指令，其余指令只清寄存器状态） | 187 MiB/s（SwiftUICore 365 MiB/s） |
| Capstone C 迭代器，不带 detail | 7.3 MiB/s |
| Capstone C 迭代器，带 detail | 5.8 MiB/s |
| Capstone Swift 封装，带 detail（`SwiftThunkAnalysis` 现在的用法） | 3.7 MiB/s |

手写解码比 Capstone 快 25–50 倍；用 Capstone 扫全缓存约要 950 CPU 秒。全量索引若每条边存 8 字节（目标 4 字节、调用方 4 字节），只算有符号函数约 206 MB，连无符号函数约 413 MB；名字不必存，缓存的 `__LINKEDIT` 里本来就有，按符号序号引用即可。

**没有符号的函数比预想的多得多。** 即使在本地符号齐全的 macOS 上，全缓存也有一半函数起点没有符号（16,603,678 个里有 8,220,497 个）。3,987 个有代码的镜像中，1,563 个的函数一大半没有符号，227 个一个有符号的都没有，集中在新的 Swift 框架：SiriAppIntents（211,148 个全无符号）、IntelligenceFlow 系列、NewsFeed、GameStoreKit 等。AppKit 有 24,910 个（23%，4.7 MiB 代码），其中 15,257 个从不被 `b` / `bl` 直接调用，经函数指针、闭包、见证表到达；抽样看到的是 Swift 的惰性初始化函数、block 辅助函数和夹在代码里的跳转表。函数边界不必自己划定：缓存里的 `LC_FUNCTION_STARTS` 是完整的。注意 MachOKit 在内存镜像上给出的 `FunctionStart.offset` 已经是未滑动的绝对地址（它以 `__TEXT` 的 vmaddr 起算），与文档注释「相对 mach header 的偏移」不符。

**预筛的效果。** 全缓存经 `__objc_selrefs` 引用的 selector 有 1,391,951 个。一个 selector 被多少个镜像引用：中位数 1，第 90 百分位 2，第 99 百分位 15，最多 2,758（`init`）；`count` 1,809 个，`makeKeyAndOrderFront:` 105 个，`orderWindow:relativeTo:` 21 个，`_makeKeyRegardlessOfVisibility` 2 个。

**selector 引用已唯一化（macOS 27.2）。** AppKit、Foundation、UIKitCore、CoreData 共同引用的 568 个 selector，在四个镜像里的指针全部相同，字符串放在所有镜像的 `__TEXT` 之外。26.x 及更早没有在进程内核实。

**本地符号在各平台的位置。**

| 平台 | 本地符号在哪 | 进程内经 `LC_SYMTAB` 能否读到名字 |
|---|---|---|
| macOS 27.2 | 各镜像自己的 `LC_SYMTAB`，在映射进进程的 `.81.dyldlinkedit` 里，没有 `.symbols` 文件 | 能 |
| iOS Simulator 27.0、26.5 | 同上，没有 `.symbols` | 能 |
| iOS 真机 26.3.1、27.0 | 名字只在不映射的 `dyld_shared_cache_arm64e.symbols` 里。缓存里的本地符号条目和地址还在，名字全是 `<redacted>`，条目数约为 `.symbols` 的一半（27.0 UIKitCore 144,387 对 294,451） | 不能，只能拿到地址 |

真机上 App 进程能否读到 `.symbols`：未核实。

**arm64e 鉴别常量**（对照编译器源码、自编的 arm64e 目标文件和 SwiftUICore 三处核实）：
- 虚表项与协议见证表项：常量是 `getPointerAuthStableSipHash(SILDeclRef::mangle())` 再取 `% 0xFFFF + 1`，输入带 `$s` 前缀，取的是**根声明**（最早引入这个虚表格的声明，或协议要求本身），并与表格地址混合。能反查，但反查到的是根声明，候选目标还要展开成它的全部 override 或 witness，这一步的扇出才是主要歧义；16 位撞值是次要的（SwiftUICore 约 3,700 个声明，单个撞值概率约 5.6%），再比对 `ldr` 里的表内偏移就能排除。混合用的寄存器不一定是 `x17`，虚表调用用的是 `x16`。
- 函数值与闭包：常量来自一个很粗的签名串（`function:<参数个数>:<各参数>:<结果个数>:<各结果>:`，类一律写成 `-class`，间接传递的值写成 `-indirect`，不含泛型参数），**反查不到声明**，只能说出签名形态，最常见的几种形态被大量调用点共用。
- 本节开头「arm64e 上的间接调用」的第一个例子（`ldr x9, [x8, #0x30]!` 加 `movk x17, #0x60f0`）其实是 value witness 调用（`getEnumTagSinglePayload`），常量由编译器写死。SwiftUICore 里带混合常量的间接调用约 79% 是 value witness 调用。
- 只有常量、不与地址混合的调用点（`mov x17, #imm`）不一定是闭包：跨 resilient 父类的 `super` 方法查找也是这个形态，它的常量按声明算。
- 跨镜像调用另一个 resilient 模块的类方法或协议方法，编译器生成的是直接 `bl` 到导出的 dispatch thunk（名字以 `Tj` 结尾），本身带名字。所以按常量反查只需要查本镜像的声明。
- async 调用经 `autda` / `ldraa` 认证，扫描器要另外认这两类，否则会全部漏掉。

**对设计的影响。** 下面几条直接改写详细设计，不改变已定的方向：
- 第 3 节的分类表补上「共用 selector 桩」「共用 GOT 桩」，selector 的键改为字符串地址；26.x 及更早的镜像自带桩，两种布局都要认。
- 批量扫描用手写解码，Capstone 只在测试里作对照。
- 第 4 节精度规则第 2 条改为：value witness 调用归入运行时辅助调用、默认隐藏；虚表与见证表调用按（常量、表内偏移）反查本镜像的根声明，再展开成 override 或 witness 作为候选；闭包调用只给签名形态，不给候选；跨镜像调用直接解析 `bl …Tj`；补认 `autda` / `ldraa`。

另有两条推翻了当初选择的前提，用户已重新确认，设计按新的决定改写（见决策日志）：
- 全量索引的前提是「建一次要好几分钟」，实测扫完整个缓存只要 1–4 秒 → 不做存盘索引，只按需扫描。
- 「无符号函数不进调用者结果」的前提是这类代码很少，实测它占全缓存调用点的一半，有 227 个镜像全无符号 → 无符号函数照样扫描，作为调用者时显示地址。

### 验证过什么、还没验证什么

- 已验证：上文标「实测」的各条，以及「落地第一步的核实」里的各条。
- 第 3 步验证过的：见「第 3 步的落地记录」。
- 未验证：真机上 App 进程能否读到 `.symbols`；26.x 及更早的缓存里 selector 引用是否唯一化（只在 27.2 上测过）；核心更少的机器上的实际扫描时间（只在 28 核机器上用 4、8 线程模拟过）。

## 提议方案

一句话概括：**MachOSwiftSection 负责从一个镜像里读出「函数表（能叫出名字的带上名字）」和「每个函数引用了什么」，RuntimeViewer 负责查询、会话缓存和三个前端。**

1. **函数**：边界取自 `LC_FUNCTION_STARTS`。名字取自符号表里位于代码段的符号、导出表、ObjC 类与分类方法表里的实现（`-[类 selector]`），以及 Swift 类型描述、虚表、协议遵循里能找到实现地址的方法；同一地址上的多个名字合并为一个函数。没有名字的函数照样扫描，显示为「无符号函数 0x…」，不推测名字。
2. **引用**：逐条解码每个函数的 arm64 指令，认出直接调用与尾调用、selector 桩与传统的 `objc_msgSend`、super 发送、经桩的跨库调用（镜像自带的桩，或 macOS 27 / iOS 27 起全缓存共用的桩）、类型引用（Swift 元数据访问器、按 mangled 名字实例化类型、ObjC 类引用）以及间接调用。
3. **精度**：ObjC 以 selector 为准，接收者是 `self`、类字面量（`[NSWindow alloc]`）或 super 时标出类并允许按类过滤，否则标为「接收者未知」；Swift 的虚表与见证表调用按鉴别常量和表内偏移反查根声明，展开成候选目标并标为「候选」，闭包调用只标出签名形态；value witness、retain / release、outlined 值操作等运行时辅助调用默认隐藏。
4. **查询**：查「调了谁」只解码这一个函数；查「谁调了它」和「哪些方法用到某个类型」时，本库直接扫，跨库则先筛库——C 与 ObjC 名字按导入（含别的库改名再导出的名字），Swift 函数与类型按链接关系，发送按 selector 引用，类按类对象上的符号——再扫候选库，同时扫几个由设置 Max Concurrent Scans 决定（默认 4）；扫过的库在会话内缓存命中。不做存盘的全量索引。
5. **前端**：Find 导航页的三种新模式、内容区右键、Inspector 的 References 标签；CLI 三个子命令；MCP 三个工具。
6. **范围**：只读引擎已索引的镜像——两种 section 都建好了的，即侧栏打开过的与后台索引读过的；没索引的镜像一律不扫，指定的镜像没索引时报错（2026-10-18 起；原为整个共享缓存加已加载的非系统库，见决策日志）。每个引擎在自己的进程里扫它映射的镜像，所有平台走同一条路径。只支持 arm64 / arm64e。

### 非目标

- 给脱了符号、元数据也叫不出名字的函数推测名字（它们照样扫描，只显示地址）。
- x86_64：Intel Mac，以及 Rosetta 下运行的进程。
- 字符串常量与全局变量的引用。
- 完整的接收者类型推断（跨调用、跨返回值的数据流分析）。
- 在 RuntimeViewer 里显示反汇编或伪代码。
- 存盘的全量交叉引用索引，以及从缓存文件离线建索引。
- 经数据结构间接传递的引用（存进表里的回调）和 `performSelector:`、`NSSelectorFromString` 这类动态派发——静态分析看不见。
- 修改现有的 Find 模式、Relationships 标签或生成侧的语义标注。

## 详细设计

### 1. 分层

```
MachOSwiftSection / CrossReferenceAnalysis（新 target，名字暂定）
    函数表与命名、单函数的引用提取、两种桩布局与 selector 解析、类型引用、鉴别常量反查、运行时辅助调用分类、预筛
        ↑
RuntimeViewerCore 包 / RuntimeViewerCrossReferences（新模块，命令扩展）
    引擎命令；本库扫描与会话缓存；跨库按需扫描（预筛、并发、进度、取消）
        ↑
App（Find / 内容区 / Inspector） · CLI（callers / callees / references） · MCP（Callers / Callees / TypeReferences）
```

原设计在引擎之上还有一层 `RuntimeCrossReferenceRouter`，它只为在全量索引与按需扫描之间选路、合并两边的结果而存在；不做存盘索引后去掉，查询直接发给文档所在的引擎。

`RuntimeViewerCore` 模块本身一行不改（`AGENTS.md` Development Guidelines 第 9 条）。和 `RuntimeViewerInjection` 一样，**每个 serve 引擎并链接了新模块的进程，都要在入口调用一次 `RuntimeCrossReferences.install()`**，漏调不会有编译错误；落地时把这条义务写进 `AGENTS.md`。

### 2. MachOSwiftSection：`CrossReferenceAnalysis`（形状，以库提案为准）

签名只列 `MachOImage`；是否对 `MachOFile` 泛型由库提案决定（离线建索引是本提案的非目标）。

```swift
import MachOKit

/// A function the analysis scans. Its bounds come from `LC_FUNCTION_STARTS`.
public struct CodeFunction: Hashable, Sendable {
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
    /// `nil` when neither a symbol nor metadata names it.
    public let name: Name?
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
    /// Which table the callee was loaded from, told apart by how the table pointer was authenticated.
    public enum Table: Hashable, Sendable {
        case classVirtualTable
        case protocolWitnessTable
        case valueWitnessTable
        /// A function value, or a table this analysis cannot identify.
        case none
    }

    public let table: Table
    /// Displacement of the load that produced the callee, when it came from a table.
    public let tableOffset: Int64?
    /// The 16-bit arm64e discriminator constant, when there is one.
    public let pointerAuthenticationConstant: UInt16?
    /// Whether the constant was blended with the slot address (`movk …, lsl #48`) or used alone (`mov x17, #imm`).
    public let isAddressBlended: Bool
}

public enum CodeReferenceTarget: Hashable, Sendable {
    /// A function in this image, or the function a shared-cache stub (macOS 27 / iOS 27) or GOT slot resolves to.
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
    public static func functions(in machO: MachOImage) throws -> [CodeFunction]
    public static func references(madeBy function: CodeFunction, in machO: MachOImage) throws -> [CodeReference]
    /// Images whose imports include `symbolName` — the only ones that can call it from outside its own image.
    public static func images(importing symbolName: String, among candidates: [MachOImage]) -> [MachOImage]
    /// Images whose selector references include `selector`.
    public static func images(referencingSelector selector: String, among candidates: [MachOImage]) -> [MachOImage]
}
```

### 3. 解码与分类

（以 MachOSwiftSection 的模块参考 `Documentations/Internal/Modules/CrossReferenceAnalysis.md` 为准，下表随第二批改写过。）

对每个函数（有名字的和没名字的），从起点解码到下一个函数的起点；`LC_DATA_IN_CODE` 标出的数据区跳过。解码是手写的：只认下表中的几类指令，其余指令只用来让寄存器跟踪器作废被写的寄存器（沿用 `ThunkRegisterTracker` 的做法：只记录能确定的地址与立即数，推不出来的就记为未知，绝不猜测）。实测它比 Capstone 快 25–50 倍；Capstone 只在测试里作对照。

| 指令 | 产生什么 |
|---|---|
| `bl imm` | 调用 `address(imm)`，再按目标所在的位置分类 |
| `b imm`，目标在本函数之外或是已知函数的起点 | 尾调用，分类同上 |
| `blr` / `blraa` / `blraaz` / `blrab` / `blrabz` | 间接调用，附带表、表内偏移与鉴别常量 |
| 函数末尾的 `br` / `braa` | 间接尾调用 |
| `autda` / `ldraa` | async 调用的函数指针认证，按间接调用处理 |
| `adrp` 加 `add` 或 `ldr` | 地址进入跟踪器：selector 引用、类引用、mangled 名字的缓存变量、GOT 槽 |
| `movk xN, #imm, lsl #48` 与 `mov x17, #imm` | 记下随后的 `blraa` 所用的鉴别常量，以及它是否与地址混合；混合用的寄存器不固定（虚表调用用 `x16`） |
| 带常量的 `autda`（isa 用 0x6ae1，value witness table 用 0x2e3f） | 记下表指针的来源：类的虚表、value witness table；从参数寄存器取的表是协议见证表 |

调用目标按它落在哪里分类。`__text` 里夹着数据，按指令解码会得到指向任意地址的「跳转」，所以读任何目标之前，先确认它落在缓存的可执行映射或本镜像里：

| 目标落在 | 解释成 |
|---|---|
| 本镜像的 `__objc_stubs`（macOS 26、iOS 26 及更早，以及 Simulator） | `messageSend`：selector 由 `ObjCStub.selector(in:)` 给出；接收者看调用前 `x0` 的来源 |
| 全缓存共用的 selector 桩（macOS 27、iOS 27：`adrp x1; add x1; b <objc_msgSend 副本>`） | `messageSend`：`x1` 就是 selector 字符串，以字符串地址为键 |
| `objc_msgSend`（传统写法） | `messageSend`：selector 取调用前 `x1` 里装入的 selector 引用 |
| `objc_msgSendSuper2` | `superMessageSend`：类取自 `__objc_superrefs` |
| 本镜像的 `__stubs` / `__auth_stubs` | 读出桩取指针的槽位：dyld 加载时已经绑定，槽里就是真正的目标（`address`）；槽读不出时才退回桩的间接符号给出的名字（`importedSymbol`）。macOS / iOS 26 及更早的缓存把桩改写成直接跳转，这一种目前按名字报（MachOSwiftSection 审查记录 2026-10-17 第 A7 条） |
| 全缓存共用的 GOT 桩（`adrp x17; add x17; ldr x16, [x17]; braa x16, x17`） | `address`：读出槽位里绑定的指针、去掉指针认证位，就是真正的目标 |
| 本镜像里的函数 | `address` |
| 别的缓存镜像（26 及更早，缓存构建器绕过了桩） | `address`：按缓存镜像的地址区间找到所在镜像，再到它的函数表里查 |
| 类型的元数据访问器（`__swift5_types` 列出的描述符 +12 处指向它） | 调用照常报，另报一处类型引用（`.swiftType(descriptor:)`）；没有描述符的访问器（泛型实例、存在类型）按符号名报 |
| `__swift_instantiateConcreteTypeFromMangledName(V2)`、`swift_getTypeByMangledName*` | 类型引用（`.swiftTypeName(.mangledName)`）：V2 的名字取自 `x1` 指向的 `{偏移, 长度}` 记录；旧形态的缓存变量一经实例化就只剩元数据，不报 |
| 以上都不是 | 无法识别的目标，只显示地址 |

运行时辅助调用的名单由库维护，包括 `objc_retain*`、`objc_release*`、`objc_autorelease*`、`objc_storeStrong`、`objc_*Weak*`、`swift_retain*`、`swift_release*`、`swift_bridgeObject*`、`swift_unknownObject*`、`swift_beginAccess` / `swift_endAccess`、outlined copy / destroy 这类 `WO*` 后缀的函数、`__swift_destroy_boxed_opaque_existential_*` 等，以及经 value witness table 的调用。结果里只打标记，过滤交给前端。

### 4. 精度规则

- **ObjC 接收者**：调用前的 `x0` 是方法入口时的 `x0`，或者是它的副本（编译器常把它挪进 `x19`–`x28`）→ `methodReceiver`；来自类引用 → `classLiteral`；super 发送 → 类已知；其余情况记为 `unknown`。查调用者时，`-[NSWindow makeKeyAndOrderFront:]` 的结果是所有发送 `makeKeyAndOrderFront:` 的地方：接收者已知但不属于 `NSWindow` 这一系的排除，未知的保留，并标为「按 selector 匹配」。
- **Swift 间接调用**：先按表的来源分开，value witness 调用归入运行时辅助调用。虚表与协议见证表调用：(a) 接收者类型已知（比如就是方法自己的 `self`）时，按表内偏移查这个类的虚表或协议见证表，得到唯一目标；(b) 否则用（鉴别常量、表内偏移）反查本镜像里引入这个表格的根声明（常量是根声明 mangled 名字的哈希，落地第一步已核实），再把根声明展开成它的全部 override 或全部 witness，作为候选。跨镜像调用 resilient 模块的方法走导出的 dispatch thunk（`…Tj`），是带名字的直接调用，不需要反查。闭包等函数值调用的常量只对应很粗的签名，不给候选，只标出签名形态（参数与结果的个数和传递方式）。候选一律标为「候选」，查调用者时也算在内，所以虚方法与协议方法的调用者不会整批漏掉。
- **代码合并**（identical code folding，链接器把完全相同的函数体合并成一份）：按地址算作一个函数，显示主名并注明「与 N 个函数代码相同」；查其中任何一个名字的调用者，得到的都是这个地址的全部调用者。
- **泛型特化**：`…Tg5` 等特化副本归到原声明名下，查原声明的调用者时，包含调用特化副本的地方。
- **无符号函数**：作为目标时显示为「无符号函数 0x…」；作为调用者时同样显示地址和所在镜像，不能跳到声明。它自己的调用者照样能查（地址已知），但这类函数多半经指针到达（AppKit 的无符号函数有六成从不被 `b` / `bl` 直接调用），通常查不到。

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

/// A function the analysis scanned, named or not.
public struct RuntimeFunctionReference: Hashable, Codable, Sendable {
    public let imagePath: String
    /// Unslid address of the first instruction.
    public let address: UInt64
    /// As RuntimeViewer prints it: `-[NSWindow makeKeyAndOrderFront:]`, `SwiftUI.ViewGraph.updateOutputs()`, `CFRelease`;
    /// `nil` when neither a symbol nor metadata names it.
    public let displayName: String?
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
    /// Named or not: an unnamed function is a function reference whose names are `nil`.
    case function(RuntimeFunctionReference)
    /// A stub whose slot could not be followed, by the symbol it imports.
    case importedSymbol(name: String)
    case selector(name: String, receiverClassName: String?)
    case type(name: String, object: RuntimeObject?)
    case indirect(tableOffset: Int64?, pointerAuthenticationConstant: UInt16?)
    /// A branch to code no image holds, or data in `__text` that decoded as one.
    case unrecognizedCode(address: UInt64)
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

/// Only images the engine has indexed — both sections built — are ever scanned.
public enum RuntimeCrossReferenceScope: Hashable, Codable, Sendable {
    /// One image, which the engine must have indexed.
    case image(path: String)
    /// Every image the engine has indexed.
    case indexedImages
}

public struct RuntimeCrossReferenceQueryOptions: Hashable, Codable, Sendable {
    public var includesRuntimeHelperCalls = false
    /// Keeps only sends whose receiver is known to be this class, or is unknown.
    public var receiverClassName: String?
    public var resultLimit: Int?
    /// How many images the engine's process scans at once, across every query; the latest
    /// query's count stays, `nil` leaves it (four until one sets it).
    public var maximumConcurrentScans: Int?
    /// Set: every image is read from its prepared index (prepared now if it has none), and the
    /// process keeps at most this many bytes of them. `nil`: each image is scanned for the query.
    public var preparedIndexByteLimit: Int?
}

/// `prepareCrossReferences`: the resident limit, the scan width, and whether to go ahead of
/// the preparations waiting.
public struct RuntimeCrossReferencePreparationOptions: Hashable, Codable, Sendable {
    public var residentByteLimit: Int
    public var maximumConcurrentScans: Int?
    public var isPrioritized: Bool
}

public struct RuntimeCrossReferencePreparationProgress: Hashable, Codable, Sendable {
    public let scannedFunctionCount: Int
    public let functionCount: Int
}

public struct RuntimeCrossReferencePreparation: Hashable, Codable, Sendable {
    public let referenceCount: Int
    public let byteCount: Int
}

/// Carries what the images finished since the last report held: over a whole query the
/// reports add up to the result, so a caller that stops waiting keeps what it saw.
public struct RuntimeCrossReferenceQueryProgress: Hashable, Codable, Sendable {
    public let scannedImageCount: Int
    public let totalImageCount: Int
    public let references: [RuntimeCrossReference]
}

public struct RuntimeCrossReferenceQueryResult: Hashable, Codable, Sendable {
    public let references: [RuntimeCrossReference]
    /// `false` when `resultLimit` cut the scan short.
    public let isComplete: Bool
}

public enum RuntimeCrossReferenceError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedArchitecture
    case imageNotFound(path: String)
    /// 范围指定的镜像没有索引，查询不读它的代码。
    case imageNotIndexed(path: String)
    case functionNotFound(imagePath: String, address: UInt64)
    case memberNotFound(objectName: String, memberName: String)
    case selectorHasNoCallees(String)
    /// 类型引用的对象不是 ObjC 类或 Swift 的结构体、枚举、类，或者它的镜像不定义它。
    case typeNotFound(objectName: String)
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

    /// Who references `subject` within `scope`, among the images the engine has indexed.
    public func callers(
        of subject: RuntimeCrossReferenceSubject,
        in scope: RuntimeCrossReferenceScope = .indexedImages,
        options: RuntimeCrossReferenceQueryOptions = RuntimeCrossReferenceQueryOptions(),
        reportProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferenceQueryResult

    /// Which functions reference the type `object` within `scope`: an Objective-C class,
    /// or a Swift struct, enum or class.
    public func typeReferences(
        to object: RuntimeObject,
        in scope: RuntimeCrossReferenceScope = .indexedImages,
        options: RuntimeCrossReferenceQueryOptions = RuntimeCrossReferenceQueryOptions(),
        reportProgress: (@Sendable (RuntimeCrossReferenceQueryProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferenceQueryResult

    /// Reads an indexed image's cross references ahead of the queries and keeps them (2026-10-18).
    public func prepareCrossReferences(
        forImageAt imagePath: String,
        options: RuntimeCrossReferencePreparationOptions,
        reportProgress: (@Sendable (RuntimeCrossReferencePreparationProgress) async -> Void)? = nil
    ) async throws -> RuntimeCrossReferencePreparation

    /// Zero drops every prepared image.
    public func setPreparedCrossReferenceByteLimit(_ byteLimit: Int) async throws
}

extension RuntimeEngine.CommandName {
    static let crossReferenceCallees = Self("crossReferenceCallees")
    static let crossReferenceCallers = Self("crossReferenceCallers")
    static let crossReferenceTypeReferences = Self("crossReferenceTypeReferences")
    static let crossReferencePrepare = Self("crossReferencePrepare")
    static let crossReferenceSetPreparedByteLimit = Self("crossReferenceSetPreparedByteLimit")
}
```

- 线上名字保留 Core 的命名空间前缀（`RuntimeViewerInjection` 的 `RuntimeInjection+CommandNames.swift` 讲了原因：拼出来的完整字符串就是线上契约）。
- `callers` 与 `typeReferences` 是 `RuntimeEngineProgressCommand`，并把 `cancelsAcrossConnections` 设为 `true`：调用方一取消，请求就从提供服务的那一端撤回。
- `typeReferences` 随 MachOSwiftSection 第二批落地（第 3 步时库还不产生类型引用）。一处类型引用是取类对象或类型元数据的指令（直接取址、经 GOT 槽、调用元数据访问器），或按 mangled 名字实例化、名字里提到这个类型的调用；结果的种类都是 `typeReference`，目标是 `.type(name:object:)`，带着查询的那个对象。只认 ObjC 类与 Swift 的结构体、枚举、类；协议与别的对象报 `typeNotFound`。
- 旧引擎（没有这个扩展的载荷、旧版 App 的对端）对这些命令没有处理器，派发会失败；前端统一显示「这个引擎不支持交叉引用（需要更新载荷或 App）」，与注入能力查询的处理方式一致。

### 6. 查询路径

查询在提供引擎的那个进程里执行：扫描读的是这个进程自己映射的镜像和共享缓存。App 的「My Mac」由本地运行时 service 回答，注入的载荷回答它所在的进程。分析器（MachOSwiftSection 的 `CrossReferenceAnalyzer`）是进程镜像的快照，每次查询前比对一遍缓存外已加载的镜像，变了就换一个新的，此前的扫描结果一并作废（镜像序号可能变了）。

**调了谁**：在 subject 所在的镜像里找到函数，然后只解码这一个函数。按 AppKit 的平均值，解码一个函数约 1 微秒。

- 成员经 `memberAddresses` 取实现地址，但那个接口为搜索框服务、按子串匹配，这里只认名字、种类、静态性都对得上的行：ObjC 方法一个函数，属性取 getter 与 setter，Swift 变量与下标取全部访问器，函数取全部同名重载（成员列表本来就不区分重载），初始化方法取 `init` 与 `allocator` 两种行。ivar、字段、枚举 case 没有代码，报「成员不存在」。
- selector 作为 subject 没有被调，直接报错。
- 被调目标的函数名需要目标镜像的函数表；分析器会记住这些表，记满 64 个镜像就换一个同样镜像集合的新分析器，把表放掉（镜像序号不变，扫描结果仍然有效）。

**谁调了它**（本库与跨库同一条路，一律按需扫描，不做存盘索引）：

0. 只在引擎已索引的镜像里找（`indexedImagePathList()`，与文本搜索判定的是同一批镜像）：范围是 `.indexedImages` 时候选从这批里挑，指定的单个镜像不在其中就报 `imageNotIndexed`。预筛读的链接关系与导出表仍看全部镜像——改名再导出某个符号的库可能没索引——但那只读头部信息，每个分析器读一次；解码代码只对已索引的镜像做。
1. 预筛：函数 → 它自己的镜像，加上 C 与 ObjC 名字（含代码合并留下的别名）的导入者；Swift 名字按链接关系——macOS 27.2 的缓存 4,113 个镜像只有 245 个在符号表里留着 Swift 的未定义符号，按导入筛会丢掉其余镜像里的调用者，所以凡是链接了函数所在镜像（直接，或经再导出）的镜像都算。ObjC 方法另加引用了它 selector 的镜像（`__objc_selrefs`）；selector → 引用了它的镜像。类型 → 类的定义镜像加类或元类地址上任一符号的导入者（Swift 类再加链接者），Swift 类型 → 链接了定义镜像的镜像（标准库与导入的类型，名字里会直接拼出来，凡是 Swift 镜像都算）。实测按 selector 筛，中位数只剩 1 个镜像，第 99 百分位 15 个，最多 2,758 个（`init`）。预筛「不漏」由 MachOSwiftSection 的抽样测试保证：在预筛丢掉的镜像里每 16 个扫 1 个，不许有一处引用。
2. 有界并发地扫描候选镜像，每个镜像只留命中这个 subject 的引用（`references(to:inImageAt:)`），不建整镜像的反向表——库第一批实测一张 AppKit 的整表约 100 MB，并发建整表的峰值会让分配器留下上 GB 的脏页。同时扫几个镜像由查询选项 `maximumConcurrentScans` 决定，整个进程共用这一个上限、以最近一次查询带来的为准；App 传设置 › Search › Cross References 的 Max Concurrent Scans（默认 4，可调到核数，与后台索引的 Max Concurrent Tasks 一样）。扫描在会话自己的 utility 优先级队列上跑，不占 Swift 协作线程池：扫一个镜像是不让出的同步计算，占着协作线程会让同进程的侧栏、内容区请求干等（原为核数减一个任务、跑在协作线程池上，见「第二次试用后的修改」）。设置 Keep Cross References Ready 开着时（默认），查询带上 `preparedIndexByteLimit`，每个候选镜像都从预先准备好的紧凑表里读，表没准备好就当场准备、排在队首，不另外现扫（见「预先准备引用表」）。每扫完一个镜像报一次进度，进度里带着这个镜像的结果；调用方中途放弃时，手里已经有这些。
3. 取消与时限：调用方取消即撤回（`cancelsAcrossConnections`），扫描在下一个镜像前停下并抛出取消。`resultLimit` 到了就停，结果标 `isComplete == false`。MCP 的 30 秒与 CLI 的 `--timeout` 由前端实现：到时取消，用进度里已收到的结果。
4. 会话内的扫描缓存：按「扫描键 → 各镜像的命中」存（调用者按查询键，类型按类对象或描述符的位置——同名的类可能分属 macOS 与 Mac Catalyst 两个变体），64 MB 预算，按最近使用淘汰。同一个主体再查一次（重试、调用层级的同一节点展开两次），已扫过的镜像直接用，只扫剩下的。单个主体的结果超出预算（`init` 的调用者）就不缓存，每次重扫——这是不做存盘索引的代价。

**ObjC 发送的精度**（第 4 节规则的落地）：查某个方法的调用者时，selector 相同的发送逐条判断。接收者是发送方法自己的 `self` 时，发送方法是类方法则接收者是类对象、否则是实例；类对象够不到实例方法（根类 `NSObject`、`NSProxy` 的实例方法除外，按名字认），实例够不到类方法，这两种排除。类名与目标方法相同记「确定」，不同记「按 selector」（可能是子类，不查类层级）；接收者未知记「按 selector」；super 发送不知道父类，记「按 selector」。代码合并把多个方法并成一个函数时，按其中任何一个能够到就算。直接按 selector 查时，每处发送都是「确定」。

**跨镜像的 Swift 虚方法与协议方法**：调用经导出的 dispatch thunk（`…Tj`）进来，第 3 步还没把 thunk 当作调用者的入口，这类调用者要等第三批（间接调用与候选目标）一起补上。

原设计在这里还有「全量索引」（由本地运行时 service 在第一次跨库查询时建好、按缓存 UUID 存进 `~/Library/Caches`）和「路由」（`RuntimeCrossReferenceRouter`）两部分。落地第一步实测扫完整个缓存只要 1–4 秒，用户据此决定不做存盘索引，这两部分连同 Report 导航页的索引条目一并删去，理由见决策日志。

### 7. GUI

**Find 导航页**：`FindMode` 新增三个 case。界面细节通过逆向 Xcode 27 的 `IDEFindNavigatorCallHierarchyQuery` 来对齐，不照着截图调。

| 模式 | 标题 | 查询框 | 结果 |
|---|---|---|---|
| `callHierarchy` | Call Hierarchy | 方法（`-[NSWindow makeKeyAndOrderFront:]`、Swift 名、符号名）或 selector | 调用者树：每个节点是一个函数，展开一层就查一次它的调用者 |
| `callees` | Callees | 方法 | 被调树：同样逐层展开 |
| `typeReferences` | Type References | 类型名 | 引用该类型的函数，按库、按类型分组 |

- 查询框的写法与 CLI 的目标写法相同（见第 8 节）。范围控件对这三种模式生效，默认查全部已索引的镜像（范围按钮写的就是 In Indexed Images），可以缩小到当前镜像或挑选的镜像。
- 设置 › Search 新增 Cross References 一节：Keep Cross References Ready（默认开，后台为每个已索引的镜像准备引用表）、Resident Limit（默认 256 MB）、Max Concurrent Scans（同时读几个镜像，1 到核数，默认 4），Find 与 Inspector 的查询都带上它们。
- Report 导航页新增 Cross References 一类：正在准备、在等的镜像（可取消）与结束的历史。
- 每行显示函数名（无符号函数显示「无符号函数 0x…」）、所在镜像、调用点数量和精度标记（「按 selector」「候选」）；底部过滤栏加一个「显示运行时调用」开关。
- 结果能对应到某个类型成员时，点击沿用 Find 现成的成员高亮（`ContentHighlightRequest`），跳到声明行；对应不到的行（C 函数、无符号函数）只显示，不跳转。
- `FindResultNode.Content` 新增 `case crossReference(function: RuntimeFunctionReference, references: [RuntimeCrossReference])`，子节点按需加载。

**内容区右键**：内容区现在只有类型名带身份。成员这边不改生成侧的语义标注，而是按行对齐：利用 `RuntimeMemberDeclarationLocator` 已有的「成员 → 声明行」对应关系，把右键点到的那一行映射到成员。成员行的右键菜单加「Find Call Hierarchy」「Find Callees」，类型名的右键菜单加「Find Type References」，两条文本路径（`NSTextView` 与 SourceEditor）都要加。菜单项把查询填进 Find 导航页并切换过去；菜单命令的快捷键照 Xcode 的按键绑定（落地时从 Xcode 的绑定里取）。

**Inspector 的 References 标签**：

- `TabKind` 新增 `.references`，有成员的对象才显示。
- 跟随内容区光标：`DocumentState` 新增「光标所在成员」（`RuntimeMemberReference?`），由两条文本路径在选区变化时按行对齐更新。光标落在某个成员的声明里时，显示它的调用者、被调和类型引用三段；不在任何成员里时，显示当前类型本身的类型引用。
- 每段只列一层，行可点击跳转；段尾的「Show in Find Navigator」把同一条查询交给 Find，展开成树。
- 列表按 `AGENTS.md` 的导航列表规则，用 `SelfSizingTableView.scrollableNavigationListTableView()`；加载状态用 `withLoadingPlaceholder`；光标在同一个声明里移动时不重新查询（按成员身份比较）。

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
- **选项**：`--image`、`--scope image` 或 `--scope indexed`（`callers` 与 `references` 默认 `indexed`：只查 host 已索引的镜像，没索引的要先 `load`）、`--receiver <类>`、`--include-runtime`、`--limit <n>`；全局的 `--source`、`--json`、`--timeout` 照常可用。（2026-10-18 范围改为只读已索引镜像，原写法 `--scope all` 随之改名；第 4 步动工时再定。）
- 在终端里于 stderr 显示镜像进度，Ctrl-C 取消；超时或取消时输出已有结果并注明不完整，退出码沿用现有约定。
- 同一个提交里更新 `AgentPlugins/runtime-viewer/` 的 skill，并把两个插件清单的 `version` 加一（`AGENTS.md` 第 478 行），同时更新 [`Guides/CommandLineInterface.md`](../Guides/CommandLineInterface.md)。

MCP 工具是 `MCPBridgeServer` 上的 `@MCPTool(hints: [.readOnly])` 方法，转成 PascalCase 后叫 `Callers` / `Callees` / `TypeReferences`：

```swift
func callers(windowIdentifier: String, target: String, imagePath: String? = nil, imageName: String? = nil, scope: String? = nil, receiverClassName: String? = nil, includeRuntimeHelperCalls: Bool = false, limit: Int? = nil) async throws -> MCPCrossReferencesResponse
func callees(windowIdentifier: String, target: String, imagePath: String? = nil, imageName: String? = nil, includeRuntimeHelperCalls: Bool = false) async throws -> MCPCrossReferencesResponse
func typeReferences(windowIdentifier: String, typeName: String, imagePath: String? = nil, imageName: String? = nil, scope: String? = nil, limit: Int? = nil) async throws -> MCPCrossReferencesResponse
```

每次调用最多等 30 秒，到时返回已有结果；响应里 `isComplete` 为 `false`，并注明扫完的镜像已经缓存，重试会接着扫剩下的。

### 9. 错误

- 引擎是 x86_64：报 `unsupportedArchitecture`；GUI 里三种模式和 References 标签置灰，并说明原因。
- 引擎没有这个扩展（旧载荷、旧版对端）：见第 5 节。
- 目标找不到：沿用 `members` 的「类型 / 成员不存在」错误。selector 没有任何发送者时返回空结果，不算错误。
- 指定的镜像没有索引：报 `imageNotIndexed`（「AppKit is not indexed. Cross references read indexed images only: load it first.」），不扫。

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
- **存盘的全量索引**（原设计：按需查询与全量索引都做，索引建好后自动切换）：前提是扫一遍整个缓存要好几分钟。落地第一步实测只要 1–4 秒，而存盘索引要多一整套构建、存储（约 200–400 MB）、失效与进度展示；用户据此改为只做按需扫描。「只做存盘索引、iOS 仍按需」同时被否。
- **无符号函数不进调用者结果**（原设计）：前提是这类代码很少。落地第一步实测全缓存一半的函数没有符号，它们发出的调用约占调用点的一半，227 个镜像全无符号；用户改为显示地址。
- **把闭包、block 这类无符号函数归到取它地址的有名字函数下**：比只显示地址更准确，但要多认一类「取函数地址」的引用，留给后续。
- **ObjC 只按 selector**：能确定接收者的情况很常见（发给 `self` 的消息、类方法），标出来几乎不花成本，还能按类过滤。**完整推断接收者类型**则需要跨调用、跨返回值的数据流分析，工作量接近反编译器。
- **Swift 间接调用只列位置，或干脆不显示**：虚方法与协议方法的调用者会整批漏掉，而 SwiftUICore 里间接调用占全部调用的 13%。
- **单独开一个引用导航页**：要重复实现 Find 已有的查询框、范围控件和结果树。
- **每个引擎各建各的全量索引**：要处理目标进程的沙盒路径、真机上几分钟的满载扫描，以及分散在各处的多份索引。（不做存盘索引后已不适用。）
- **只认符号表里的函数**：第三方 App 的发布版通常只剩导出符号；iOS 真机上系统库的本地符号名字全是 `<redacted>`（落地第一步核实）；macOS 上也有 227 个镜像一个有符号的函数都没有。
- **同时支持 x86_64**：x86 指令是变长的，桩、selector 发送、虚方法调用的指令形态全都不同，相当于把识别工作再做一遍；而 macOS 26 是最后一个支持 Intel Mac 的版本。
- **App 启动后自动建索引，或只在手动执行命令时建**：前者每次系统更新后的第一次启动，都要在后台扫上几分钟；后者多一个步骤，大多数人永远用不上索引。（不做存盘索引后已不适用。）
- **Inspector 只在右键时更新，或列出当前类型的全部方法**：前者每次都要多点一下；后者要为每个方法各查一遍调用者，太慢。
- **CLI 只加一个 `xrefs` 子命令、用参数选方向**：参数组合多；现有 CLI 是一个意图对应一个子命令（`hierarchy`、`relationships`、`members`）。
- **复用 swift-decompiler**：它是提升与结构化的管线，其 Capstone 参考路径在大函数上跑不完；交叉引用只需要调用点。
- **经 IDA（idalib）出交叉引用**：每个库都要先有 `.i64`，引擎进程和真机里都用不上，也绕不开 IDA 的许可。
- **解析 `dyld_info -disassemble` 的输出**：它把 SwiftUICore 一半以上的 `bl` 认错了目标，只能读 macOS 上的镜像，也不认元数据里的方法名。

## 影响

### 用户可见变化

- Find 导航页的模式路径多出三项：Call Hierarchy、Callees、Type References。
- 内容区右键：成员行多出「Find Call Hierarchy」「Find Callees」，类型名多出「Find Type References」；原有的 Jump to Definition、Open in New Tab 不变。
- Inspector 对有成员的对象多出一个 References 标签。
- CLI 多出 `callers`、`callees`、`references` 三个子命令；MCP 多出 `Callers`、`Callees`、`TypeReferences` 三个工具。
- 不移除、不改变任何现有行为。

### 可发现性

- 入口在三处常用的位置：Find 的模式路径、内容区右键、Inspector 标签；菜单命令和快捷键照 Xcode。
- 默认开启：已索引的镜像在后台准备好引用表（进度见 Report 导航页），查询直接读表；在设置 › Search 里可以关掉准备（查询改为现扫）、调内存上限与同时读几个镜像。
- CLI 的 `--help` 与 agent 插件的 skill 同批更新；装了插件的 agent 在插件版本号变化后会拿到新的用法。

### 数据与配置兼容

- 不写任何文件：准备好的引用表与扫描结果只在引擎进程的内存里，按字节预算淘汰。常驻的五个镜像约 50 MiB。
- 设置新增三项，挂在已有的 `search` 下：`maximumConcurrentCrossReferenceScans`（默认 4）、`isCrossReferencePreparationEnabled`（默认开）、`crossReferenceResidentByteLimitMegabytes`（默认 256）；旧的设置文件没有它们时取默认值，无需迁移。不改动书签或任何已有文件。
- 线上协议只新增命令；旧载荷与旧对端收到这些命令时派发失败，前端提示需要更新，不影响其他功能。

### 平台与最低版本

- 最低系统版本不变。新模块跟随 `RuntimeViewerCore` 的平台列表。
- 所有平台走同一条路径：每个引擎在自己的进程里按需扫描它映射的那份缓存。macOS 26 及更早与 macOS 27 的两种桩布局都支持。
- iOS Simulator：能读到系统库的本地符号，与 macOS 相同。iOS 真机（越狱版与注入）：系统库的本地符号只剩地址、名字是 `<redacted>`，导出符号与元数据能叫出名字的方法照样有名字，其余显示为无符号函数。
- x86_64 引擎（Intel Mac、Rosetta 下的进程）：明确提示不支持。

### 发布

- 不需要新的权限、entitlement 或隐私清单条目，不写任何文件。
- 不影响公证，也不影响 Sparkle 更新。App 体积几乎不变：Capstone 本来就链接在内。
- 发版顺序：带 `CrossReferenceAnalysis` 的 MachOSwiftSection 版本必须先发布，RuntimeViewer 的 `main` 才能用上（`main` 只针对已发布的依赖版本编译）。

## 落地步骤

1. **核实前提**（已完成，结论见「前期调研 › 落地第一步的核实」）：在 App 进程里读取一个未加载缓存镜像的 `__text` 与符号表；测量 Capstone 与手写解码在 AppKit / SwiftUICore 上的吞吐，估算全量扫描的耗时与规模；对照编译器源码核实 arm64e 鉴别常量能否反查到声明；核实 iOS 真机与 Simulator 上本地符号放在哪里。任何一条结论推翻了设计，就回到本提案修改，并重新确认。
2. **MachOSwiftSection 的库提案与 `CrossReferenceAnalysis`**：函数表与命名、单函数的引用提取、两种桩布局（镜像自带的桩与全缓存共用的桩）与 selector 解析、类型引用、鉴别常量反查、运行时辅助调用分类、预筛。批量扫描用手写解码，写 fixture 测试，并以 Capstone 的结果和 `dyld_info` / IDA 抽样作对照。然后发版。
3. **`RuntimeViewerCrossReferences` 模块**：线上类型与命令；在 `AGENTS.md`「Injection commands」那张表列出的全部入口调用 `install()`，并把这条义务写进 `AGENTS.md`；本库扫描与会话缓存；跨库按需扫描（预筛、并发、进度、取消）。**已完成（2026-10-16）**，`typeReferences` 随 MachOSwiftSection 第二批于 2026-10-17 补上，记录见「第 3 步的落地记录」与「第 3 步续：类型引用」。
4. **CLI 与 MCP**：三个子命令、三个工具，agent 插件的 skill 与版本号，以及 `Guides/CommandLineInterface.md`。**顺序已调整（2026-10-17）**：放到第 5、6 步之后，界面做完、没有问题再做。
5. **Find 导航页的三种模式**：逆向 Xcode 27 的 Call Hierarchy 来对齐界面；结果树、范围控件、精度标记、运行时调用开关；按 `RuntimeViewerApplicationTests` 的规则写 ViewModel 契约测试。**已完成（2026-10-17）**，记录见「第 5 步的落地记录」。
6. **内容区右键与 Inspector 的 References 标签**：成员按行对齐、两条文本路径的菜单、光标所在成员、标签本身及其 ViewModel 测试。**已完成（2026-10-17）**，记录见「第 6 步的落地记录」。

原设计的第 5 步「全量索引」随存盘索引一起删去。

每一步都能单独构建、单独验证；从第 3 步起，每一步都可以单独合入。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计需要：一份使用指南（目标写法、精度标注的含义、哪些引用静态看不见），一份实现说明（两种桩布局、鉴别常量反查与无符号函数的处理规则）。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 预计有：交叉引用、按需扫描与预筛、候选目标、运行时辅助调用、全缓存共用桩、无符号函数。同批次登记进 `Documentations/Glossary.md`。

## 第 3 步的落地记录（2026-10-16）

**落地内容。** `RuntimeViewerCore` 包新增 target 与 product `RuntimeViewerCrossReferences`：线上类型（第 5 节）、两个命令 `crossReferenceCallees` / `crossReferenceCallers`、引擎侧的查询（`CrossReferenceQuery`）、进程级的会话（`CrossReferenceSession`：分析器与扫描缓存）、ObjC 发送的精度规则（`ObjectiveCSendMatching`）和命名（`CrossReferenceNaming`）。`RuntimeCrossReferences.install()` 接进了 `AGENTS.md` 那张表的全部七个进程、八处入口，义务写进了 `AGENTS.md`；三个 Xcode 工程里链接注入模块的 10 个 target、CLI 包的可执行 target 和 Tuist 描述的 6 个 target 都加上了新 product。MachOSwiftSection 临时钉在功能分支 `feature/cross-reference-analysis`，五份被跟踪的锁文件（Core、Packages、CommandLine 三个包，Debug 与 Distribution 两个 workspace）只有这一条 pin 变了（`RuntimeViewerServer.xcodeproj` 自带的那份本来就远落后于 workspace，没有动）；MachOSwiftSection 发版后改回版本钉。

**与设计的出入**（第 5、6 节已按实现改写）：

- `typeReferences` 推迟到 MachOSwiftSection 第二批：第一批的扫描器还不产生类型引用。
- 不建整镜像的反向表，扫描只留命中的引用；会话缓存改成「查询键 → 各镜像命中」，64 MB 预算。
- 进度事件带上这一批的结果，前端超时时手里有部分结果。
- 线上目标去掉 `unnamedCode(imagePath:address:)`：无符号函数就是名字为空的 `.function`。另加 `importedSymbol`、`indirect` 和 `unrecognizedCode(address:)`（落在所有镜像之外的跳转）。
- 并发数取处理器核数减一，不是核数：扫描是同步的计算，占满协作线程池会让进程里其他请求等上一两秒。
- ObjC 精度不查类层级，根类按名字认 `NSObject`、`NSProxy`（第 6 节）。
- 跨镜像经 dispatch thunk（`…Tj`）进来的 Swift 虚方法与协议方法调用者，第 3 步不收，随第三批。

**接入时发现的库缺陷。** 查 `-[NSObject description]` 的调用者，libobjc 里一条都没有。追下去：`-[NSObject debugDescription]` 在 macOS 27.2 上是 `adrp x8; add x1, x8, #…; b _objc_msgSend`——缓存构建器把读 selector 引用改写成了直接算出字符串地址，而第一批只认「从 selector 引用读来的 `x1`」，这些传统发送全被当成对 `objc_msgSend` 的普通调用。MachOSwiftSection `8eea8cb7` 修了它，回归测试改前红、改后绿；同一个提交补上了预筛「不漏」的抽样测试（此前只测过「筛得够狠」）。

**验证**（JHs-Mac-Studio-Ultra，macOS 27.2，Xcode 27.2；依赖全部走远端，MachOSwiftSection 为功能分支 `8eea8cb7`）：

- `RuntimeViewerCrossReferencesTests` 4 个套件 33 个测试通过：安装（两个命令都进了命令表，重复安装不重复）、线上格式（命令名、往返编码、错误描述）、匹配规则（ObjC 发送精度的每一种情形、成员行的筛选、显示名）、真实共享缓存上的查询（`-[NSWindow makeKeyAndOrderFront:]` 的被调、AppKit 里 `orderWindow:relativeTo:` 的发送者且进度之和等于结果、Foundation 经桩对 `CFRelease` 的调用落到 CoreFoundation、全部镜像查询确实经过预筛、上限截断、取消、会话缓存复用与预算、NSObject 成员的被调与调用者精度、ivar 报错）。
- MachOSwiftSection：`CrossReferenceAnalysisTests` 24 个、`SwiftThunkAnalysisTests` 82 个测试通过。
- 构建：macOS App（`RuntimeViewer-Debug.xcworkspace`、`RuntimeViewer macOS`、Debug）连同全部内嵌产物构建通过，App、本地运行时 service、内嵌 CLI、Catalyst 插件、macOS 与 Simulator 两份载荷的二进制里都有新模块的符号和线上命令名；CLI 包 `swift build` 通过；iOS App（`RuntimeViewer iOS`，通用 iOS Simulator 目标，只编译不启动）构建通过，有一条落在 `FoundationToolbox.o` 里的链接器警告，未与基线对比。
- Tuist：`TUIST_SCRIPT_ROOT=<agent 目录> ./TuistScript.sh check` 通过（项目接线、本地包 target 清单、两份锁文件、trait 设置都与原生工程一致）。
- `RuntimeViewerCore` 全量 `swift test`：Core 套件 499 个测试里 1 个失败（`RuntimeBackgroundIndexingManagerTests` 的批次取消，用的是假引擎与假路径，与本次无关），那次全量与三个平台的构建同时在跑；单独重跑这个套件 27 个全过。其余测试目标全过。
- 注入载荷照 `BuildRuntimeViewerServerXCFramework.sh` 的方式（Distribution workspace、`RuntimeViewerMobileServer`、Distribution 配置）构建：tvOS、visionOS 通过；watchOS 在依赖的部署目标校验阶段就失败（多个包的 watchOS 部署目标是 8.0，Xcode 27.2 只接受 9.0 起，另有 armv7k 已弃用），新模块还没开始编译。`next`（`aa935aa2`）用它自己的锁文件构建，失败完全相同，所以这个问题早于本次改动，没有在这里修。
- 没有验证：visionOS App 与越狱版 arm64e 变体的构建；经 XPC 或 TCP 的真实跨进程查询（测试只走了进程内派发，命令注册由安装测试覆盖）；Mac Catalyst 引擎上的查询。

**留给后面的**：给调用者起名时，有命中的镜像要再建一次函数表（扫描时建的那张已经丢了），查 `init` 这种上千个镜像都有命中的主体，每个镜像都多建一遍（多花多少没有测）。可以让 MachOSwiftSection 的过滤扫描顺带交出命中函数的 `CodeFunction`，随第二批一起做。

## 第 3 步续：类型引用（2026-10-17）

MachOSwiftSection 第二批落地后补上第 3 步推迟的 `typeReferences`，并接入第二批的其余变化。

**落地内容。**

- 新命令 `crossReferenceTypeReferences`（`TypeReferencesCommand`，报进度、跨连接取消）与 `RuntimeEngine.typeReferences(to:in:options:reportProgress:)`，新错误 `typeNotFound(objectName:)`。对象怎么换成库里的类型：ObjC 类按运行时名字在它的镜像里找类对象（`objectiveCClassLocations(named:inImageAt:)`）；Swift 的结构体、枚举、类按对象的 `name` 找描述符——RuntimeViewer 给 Swift 类型对象的名字就是库的 key（类型的 mangling），SwiftData 的 193 个 Swift 类型全部按名字找到。
- 调用者与类型引用共用一条扫描路径（`scan(_:for:…)`：先报会话里已扫过的镜像，再并发扫其余的，到上限就停）。会话缓存的键改为 `CrossReferenceScanKey`：调用者按查询键，类型按类对象或描述符的位置。
- 被调视图里出现类型引用：取类对象、Swift 类型的访问器或元数据、按名字实例化——一个名字提到几个类型就各报一条（`[SwiftUI.Text]` 报 `Swift.Array` 与 `SwiftUI.Text`）。类型显示成 RuntimeViewer 打印的样子，Swift 类的运行时名字 `_TtC7SwiftUI13PinnedBarView` 显示为 `SwiftUI.PinnedBarView`。
- 第二批给符号表没有名字的函数起了名（导出表、ObjC 方法表、Swift 元数据）。元数据重建的名字照符号的方式 demangle 显示，`symbolName` 为空——它不来自符号表。
- 第二批开始给出类字面量接收者（含 Swift 经 `objc_opt_self` 的），`ObjectiveCSendMatching` 早已按类字面量处理，所以按方法查调用者时，发给类字面量的发送不再一律「按 selector」：类对象够不到的实例方法排除，类名相同记「确定」。
- MachOSwiftSection 钉到功能分支的 `c2cefa9c`（第二批四个提交，加一个更正注释与文档里数字的提交），五份锁文件仍然只有这一条 pin 变了。

**接入时发现的缺陷：第 3 步的调用者预筛会漏掉 Swift 函数的跨库调用者。** MachOSwiftSection 写类型预筛的正确性测试时发现，macOS 27.2 的缓存里 4,113 个镜像只有 245 个在符号表里留着 Swift 的未定义符号，其余的经缓存构建器绑好的 GOT 桩调用 Swift 函数，却不留导入记录。第 3 步按「导入了它的符号」找跨库调用者，对 Swift 函数只会扫按名字导入它的少数镜像——`URL.path` 只有 44 个——其余调用它的镜像全被跳过。改为 MachOSwiftSection 新增的 `imageIndices(callingFunctionAt:symbolNames:among:)`：C 与 ObjC 名字仍按导入，Swift 名字按链接关系。回归测试 `swiftFunctionCandidatesFollowTheLinkage` 要求候选集包含每一个链接了 Foundation 的镜像，旧做法下失败。先写的那个行为测试（扫全部镜像、找到一处 Foundation 之外的调用者）在旧做法下也能通过——确实有少数镜像按名字导入——分辨不出，删掉了。这个问题是第 3 步引入的，`main` 上没有这个功能。

**验证**（JHs-Mac-Studio-Ultra，macOS 27.2，Xcode 27.2；依赖全部走远端，MachOSwiftSection 为 `c2cefa9c`）：

- `RuntimeViewerCrossReferencesTests` 4 个套件 40 个测试通过。新增的 7 个：类型引用请求的往返编码，Swift 函数的候选集跟着链接关系，ObjC 类在本镜像里的类型引用（`NSWindow`），Swift 类型的类型引用（`SwiftUI.Text`），跨镜像的类型引用（`URL` 在 Foundation 之外的缓存镜像里被找到），协议报 `typeNotFound`，以及类型扫描在会话里复用；原有的显示名、安装、错误描述测试补上了类型显示名、新命令与新错误。
- MachOSwiftSection：`CrossReferenceAnalysisTests` 45 个、`SwiftThunkAnalysisTests` 82 个测试通过。
- CLI 包 `swift build` 通过；macOS App（`RuntimeViewer-Debug.xcworkspace`、`RuntimeViewer macOS`、Debug）与 iOS App（`RuntimeViewer iOS`，通用 iOS Simulator 目标）构建通过，警告都是第 3 步已有的那几种，没有一条来自交叉引用。
- Tuist：`install` 后 `check` 通过（工程接线、本地包 target 清单、锁文件、trait 设置都与原生工程一致）。
- 没有验证：经 XPC 或 TCP 的真实跨进程查询（与第 3 步相同，命令注册由安装测试覆盖）；Mac Catalyst 引擎上的查询；注入载荷与越狱版的构建。

## 第 5 步的落地记录（2026-10-17）

**依据**：逆向 Xcode 27.2（27B5028f）的 IDEKit 与 IDEFoundation，证据（符号、地址、plist 键）记在 `/Volumes/RE/Xcode/27.2/README.md` 的「Find navigator: call hierarchy and symbol queries (2026-10-17)」一节；IDEFoundation 的导出与 IDA 库是这次新建的，在同版本目录下。

**照 Xcode 做的**：

- 模式名 Call Hierarchy，查询框占位文字「Method, Property, or Function」（`IDEFoundation.xcplugindata` 的 `queryTermPlaceholderText`），支持四种匹配方式与区分大小写，模式菜单里排在类型模式之后。Xcode 没有 Callees 与 Type References，这两种沿用同一套做法。
- 键入的词按名字找根：普通名字按匹配方式与大小写匹配方法、属性、函数（类型引用匹配类型）；带类型的写法（`-[NSWindow makeKeyAndOrderFront:]`、`NSWindow.title`）先找成员名、再精确比对类型，匹配方式与大小写不起作用。每个匹配是一个根，只收有代码的成员。
- 结果树按需加载：没加载的行一律带展开三角，展开时才查下一层，查出空的行三角消失；根到达时自动展开；一个函数又出现在自己这一支的上方时标为递归、不再加载；每层按标题 `-[NSString compare:]` 排序（区分大小写，大写在前）。
- 有结果时没有汇总行；底部过滤框在这三种模式里禁用（Xcode 的 `enableFilter` 是 `!lazilyFaultsChildren`）；结果行右键第一项是 Find Call Hierarchy，以该行为根重新查询，范围回到默认。

**与 Xcode 不同的地方，及原因**：

| 不同 | 原因 |
|---|---|
| 一个调用者一行，标出调用次数；Xcode 每个调用点一行 | 调用点只有指令地址、没有源码行，逐点成行会是一排看不出区别的重复行 |
| 范围限定在哪些镜像里找调用者与类型引用；Xcode 的调用层级不看范围 | 提案原设计；Callees 只读一个函数，范围按钮在这个模式里禁用 |
| 展开后、下一层回来前，显示一行「Loading…」，汇总栏显示扫描进度；Xcode 两者都没有 | 一次全缓存扫描要几秒，Xcode 的索引是立刻回答的 |
| 根超过 10 个时不自动展开；一次只加载一层，按展开的顺序排队 | 每个根、每一层都是一次扫描，每次扫描已占用除一个之外的全部核心 |
| 不预取下一层（Xcode 加载一层时顺带预取下一层，用来决定要不要显示三角） | 预取意味着对每个调用者再扫一遍；三角照 Xcode 对未加载的行一律显示 |
| 递归行的图标是 SF Symbol `arrow.triangle.2.circlepath`；Xcode 用自带的 `function_recursive` 图 | Xcode 的图片资源不能拿来用 |

**落地中顺带修掉的引擎问题**（各带一个修复前失败的测试）：

- 经框架符号链接加载的镜像（`Foundation.framework/Foundation`）查不到：链接指向的文件只在共享缓存里，文件系统解析不了。现在查不到时交给 dyld，按句柄找到它登记的那个名字（`imagesNamedThroughFrameworkSymlinksAreFound`）。
- 调用者与被调里的 ObjC 方法不带所属成员，点了无处可去：现在按名字带上类与 selector，类放在定义它的镜像里——方法所在镜像定义了这个类就是它，否则问运行时类是从哪个镜像加载的（`objectiveCCallersCarryTheirMember`）。
- 范围选了多个镜像时，客户端曾按范围里的路径过滤引擎的结果，而两边对同一个镜像的路径写法可能不同，结果会被滤空。现在逐个镜像发查询，路径由引擎所在进程解析（`scopesOfSeveralImages`）。

**还没做的**：Swift 的调用者与被调不带所属成员，点了不跳转（要从符号解出所属类型的 key，另做）；结果行没有 Xcode 的 Copy；x86_64 引擎没有把三种模式置灰（第 9 节），现在是展开时出一行错误说明。

**测试**：`FindCrossReferenceTreeTests`（分组、排序、加载与递归、名字解析，不需要引擎）、`FindViewModelCrossReferenceTests`（在共享测试引擎上，范围限定在 Foundation：三种模式、逐层展开、运行时调用开关、键入的词找根、右键命令、点击跳转、多镜像范围），以及 `RuntimeViewerCrossReferencesTests` 新增的两个引擎测试。

## 第 6 步的落地记录（2026-10-17）

**成员按行对齐**：Core 新增 `RuntimeObjectInterface.declaredMembersByLineNumber()`，用 Find 语料对齐成员时的同一套读行规则（`RuntimeMemberDeclarationLocator`）反过来读：每行声明的是哪个成员。只读这个接口自己语言的键（一行 ObjC 文字在两种语言下都能读出键）；一行有几个键时取函数、方法、属性，不取参数名；行首括号深度大于 1 的行属于嵌套类型，不算这个对象的；以 `case` 开头的是枚举 case，没有代码。内容区渲染时把有代码的成员以 `.runtimeViewerDeclaredMember` 属性标在整行上，和类型名用 `.link` 带 `RuntimeObject` 是同一个做法，两条文本路径都从属性读。

**入口**：

- 内容区右键：成员所在的行多出「Find Call Hierarchy」「Find Callees」，类型名多出「Find Type References」；`NSTextView` 与 SourceEditor 两条路径都有。
- 主菜单 Edit ▸ Find：「Find Call Hierarchy」（⌃⇧⌘H，照 Xcode 的 `Xcode.IDEKit.CmdDefinition.CallHierarchy`）、「Find Callees」「Find Type References」（Xcode 没有，不设快捷键）。前两项作用于光标所在的成员，第三项作用于当前显示的类型；对不上时置灰。
- 这几处命令都照 Xcode 的 Find Call Hierarchy：切到 Find 导航页、范围回到默认、填入名字立即查询、不把焦点移进查询框，并记进最近查询。

**光标所在成员**：`DocumentState.cursorMember`，由内容区在选区变化时更新，只认当前显示对象的成员。Inspector 的 References 标签与主菜单命令都跟随它。

**Inspector 的 References 标签**：ObjC 类、Swift 结构体、枚举、类显示这个标签。三段：调用者、被调（不含运行时辅助调用）、类型引用，各列一层，一段最多 200 行；光标不在成员上时只显示类型引用，并提示把光标放到方法或属性上。**只查对象所在的那一个镜像**（标题下注明「In AppKit」），要看全部镜像用段尾的 Show in Find Navigator；**标签不在屏幕上时什么都不查**，出现时再查隐藏期间变了的主题（2026-10-17 试用后改，见「试用后的修复」）。行可点击跳到成员的声明；段头的按钮把同一条查询交给 Find 导航页展开成树。每段各有一个状态值与一条管线，按各自的主题取消旧查询：光标换到另一个成员只重查调用，类型引用不动。

**还没做的**：SourceEditor 路径不跟随光标——桥接层没有选区变化的回调，要按 SourceEditor 模块的规矩（先有 dump、再改存根）另做；这条路径上右键菜单照常可用。嵌套类型里的成员在外层类型的内容里不提供命令（它们属于嵌套类型，不是这个对象的），要用就打开嵌套类型本身。

**测试**：`RuntimeDeclaredMemberTests`（Core，按行读成员的规则）、`ContentCrossReferenceTests`（成员属性、右键命令、光标成员、主菜单命令的目标）、`InspectorReferencesViewModelTests`（共享测试引擎，范围限定在 Foundation）。

## 试用后的修复（2026-10-17）

第 5、6 步落地后用户第一次试用（Debug 构建）：查 AppKit 内部结构体 `NSSmartNamingSuggestion` 的类型引用，Find 与 Inspector 一起转了几分钟，本地运行时服务占满 27 个核心。排查记录：[2026-10-17 交叉引用查询又慢又占满 CPU](../ResolvedIssues/2026-10-17-cross-reference-queries-slow-and-cpu-bound.md)。用户批准全部四项修复：

- 库：Swift 类型的预筛先看定义镜像导不导出它的符号，一个都不导出就只扫定义镜像（MachOSwiftSection `e470f193`，本仓库钉到它）。这次查询从 231 秒降到 6.8 秒（Debug）。
- Inspector：只在标签可见时查，只查对象所在的镜像。
- 引擎：会话共享进行中的扫描，同一镜像同一主题同时只扫一次。
- Find：展开行不再同步发布结果（RxSwift 的重入警告）。

Debug 构建里扫描器没有优化、比 Release 慢一个数量级以上，这一条不修。

## 第二次试用后的修改（2026-10-18）

用户换上 MachOSwiftSection `e470f193` 再试（Debug，从 Xcode 跑）：「目前太慢了，而且占用CPU太多了，直接100%啥也干不了」，并定下「分析只在已经索引的image里面进行，其他没加载索引的不分析」，随后补充「具体用多少核让用户可以决定，跟后台索引一样，设置里面可以改」。排查记在[同一篇排查记录](../ResolvedIssues/2026-10-17-cross-reference-queries-slow-and-cpu-bound.md)的「第二轮」。改了三处：

- **只扫已索引的镜像**：范围 `.allImages` 改名 `.indexedImages`，候选只从引擎已索引的镜像里挑（`indexedImagePathList()`，与文本搜索判定的是同一批）；指定的镜像没索引报 `imageNotIndexed`。Find 的范围按钮本来就写着 In Indexed Images，交叉引用却按整个缓存扫，现在两者一致。Callees 不变：只解码一个函数，被调目标在未索引的镜像里也照样列出名字。
- **扫描不占 Swift 协作线程池**：改在会话自己的 `OperationQueue` 上跑，utility 优先级，整个进程同时最多 N 个。此前每次查询开「核数减一」个任务，每个都在协作线程上不让出地解码一整个镜像：本地运行时服务的 28 个协作线程被占掉 27 个，同进程的侧栏、内容区请求排不上队。
- **N 由设置决定**：设置 › Search › Cross References 的 Max Concurrent Scans（1 到核数，默认 4，与后台索引的默认并发数相同），经查询选项 `maximumConcurrentScans` 带到服务进程，以最近一次查询带来的为准。

**测试**：新增五个，都在旧行为下确认过失败（临时把三处改回去跑，跑完恢复）——`indexedImagesBoundTheScan`（只索引 AppKit 时查 `makeKeyAndOrderFront:` 只扫 1 个镜像，旧行为扫到了 AppKit 以外）、`imagesNotIndexedAreRefused`、`queriesReadTheirEnginesIndexedImages`（真引擎只索引 libobjc：结果都在已索引镜像里，查 Foundation 报错）、`scansRunAFewAtATimeOffTheThreadPool`（上限 3 时 9 个扫描同时最多 3 个、utility 优先级、不在协作线程上；旧行为 9 个同时跑、default 优先级、在协作线程上）、`optionsSetHowManyImagesAreScannedAtOnce`。原有测试把全部镜像当作已索引（`makeQuery` 的默认值），宽度取核数以免拖慢；两个原先经引擎查 AppKit 的测试改走查询本身，因为新建的引擎没索引 AppKit。

Debug 构建里扫描器仍比 Release 慢几十倍，单扫 AppKit 仍要几秒，但只占一个核。

**同一轮修的显示问题**：Inspector 的 Type References 里，ObjC 方法的行只显示「-」，长的 Swift 名字只显示前半截、没有省略号，点一下才显示全文。结果行（Find 导航页与 Inspector 共用 `FindResultCellView`）的标题是富文本，AppKit 按富文本自己的段落样式折行，标签上设的 `lineBreakMode = .byTruncatingTail` 只管纯文本（`NSCell.wraps` 的文档）；标题没带段落样式，就按词折行，单行标签只画出第一行，`-[…` 在「-」后就能断。侧栏、Inspector 的关系与特化标签都把截断写进了富文本，只有 Find 结果行漏了。改为单行标题带 `.byTruncatingTail` 的段落样式（命中行仍可折成两行）；标题标签不再可选中——`Label(wrappingLabelWithString:)` 建出来是可选中的，一点就换成字段编辑器重画，这就是「点一下才显示」。测试 `FindResultNodeTests.longTitlesTruncateOnOneLine` 按 Inspector 的宽度画一行 ObjC 方法的标题：修复前只画到 7.5 点（一个「-」），修复后排到行尾。「有时整行是空的」没有复现，看修复后是否还出现。

## 预先准备引用表（2026-10-18）

上面几处改完，用户回复「不卡了，就是每次获取都太慢了，能像后台索引和搜索语料一样提前准备好吗」，并在两个问题里选了「紧凑表」「只放内存」。这一条修订 2026-10-16 的「不做存盘的全量索引，只按需扫描」：仍不存盘、仍不扫未索引的镜像，但已索引镜像的引用表预先建好、留在内存里。

**库（MachOSwiftSection `3ca49d4d`，五份锁文件钉到它）**：新增 `CodeReferenceIndex`，一个镜像的引用按「引用了什么」分组存放。选择子、导入名、类名每个只存一份；引用所在的函数与指令存成相对 `__text` 起点的 32 位偏移（一条 16 字节）；只留查调用者与查类型引用会读的引用（调用与尾调用、发送、导入名、类与 Swift 类型引用），间接调用和落在所有镜像之外的跳转不留。`referenceIndex(ofImageAt:)` 扫一遍建表，并留住镜像的函数表（给结果起名要用）；从表里读，`references(to:)` 与 `references(toSwiftType:in:)` 回答的和现扫的 `references(to:inImageAt:)`、`references(toSwiftType:inImageAt:)` 逐条相同，顺序也相同。macOS 27.2 实测（含名字的堆存储）：

| 镜像 | 紧凑表 | 库原有的整表 | Debug 下建表 |
|---|---|---|---|
| AppKit | 21 MiB（85.6 万条） | 67 MiB（87.5 万条） | 5.9 秒 |
| Foundation | 9 MiB | 34 MiB | 3.6 秒 |
| SwiftUICore | 9 MiB | 35 MiB | 3.5 秒 |
| libswiftCore | 1 MiB | 7 MiB | 1.0 秒 |

用户常驻索引的五个镜像加起来约 50 MiB，默认上限 256 MiB 放得下；Release 下建表比 Debug 快 20–50 倍。

**引擎（`RuntimeViewerCrossReferences`）**：会话按镜像存放准备好的表，有内存上限、按最近一次使用淘汰，一张大于上限的表照样回答、不留，换代时全部作废。建表与现扫共用会话那条 utility 队列与 Max Concurrent Scans；队列里，后台准备排在查询自己的现扫之后，查询等着的准备排在最前。同一个镜像不管谁要，只建一次：后到的等先开始的那次，查询等着它时把它提到最前。一个请求被取消立刻不再等；所有请求都走了，还没开始的就不开始，开始了的在下一次进度报告（每 2,048 个函数一次）时放弃。新命令 `prepareCrossReferences`（带进度、可跨连接取消，未索引的镜像回 `imageNotIndexed`）与 `setPreparedCrossReferenceByteLimit`（0 即全部丢掉）。查询选项新增 `preparedIndexByteLimit`：有值时候选镜像一律查表——表在建就等它，没有就当场建——不再另外现扫；没有值时照旧现扫，会话里按主题的扫描缓存也只在这时用。进度是各自送出的，可能晚于结果、也可能乱序，App 只取最远的那次。

**App**：`CrossReferencePreparationCoordinator`，每个引擎一个，与搜索语料的协调器并列挂在 `RuntimeEngineBackgroundWork` 上、同一引擎的窗口共用，文档打开时与另两个协调器一起建好，换引擎时跟着换。它在开始时请求引擎已索引的每个镜像，之后每索引一个就请求一个；开关打开时全部请求一遍，关掉时撤回所有请求并让引擎把上限设为 0；上限改了就告诉引擎；引擎重连后重来；被淘汰的镜像不再后台补建，下一次查到它时由查询当场建。Report 导航页新增「Cross References」类别：在准备的（「42% · 30,000 of 71,000 functions」，可取消）、在等的，以及结束的历史（提示里写引用条数与大小）；准备期间计入 `reportActivity`，不让 App Nap 拖慢服务。设置 › Search › Cross References：Keep Cross References Ready（默认开）、Resident Limit（默认 256 MB，32–4096）、Max Concurrent Scans；Find 与 Inspector 开着时把上限作为 `preparedIndexByteLimit` 带进每次查询。

**和设计不同的两处**（决策日志有记录）：开关关掉时 Report 里这一类不显示「Turned off in Settings」——关掉后查询照样能用（现扫），没有后台工作要报告，和关掉就查不到东西的索引、语料不同；`ViewModelTestEnvironment` 里这个开关默认关，开着会让每个打开文档的测试都在后台准备镜像，影响别的测试数的活动与 Report 行，讲它的测试自己打开。

**测试**：库 `CodeReferenceIndexTests` 6 个（Foundation 整表的每个键与索引逐条相同；AppKit 多个键一起查与过滤扫描逐条相同；`URL`、`JSONEncoder`、`Array` 从索引查与按类型扫描相同；大小不到整表一半；建表留住函数表；进度与停止）。引擎 `CrossReferencePreparationTests` 8 个（查表与现扫的结果相同；准备好之后再查什么都不扫；后台准备与查询共用一次准备；上限与淘汰、0 全丢；未索引的不建；唯一的请求取消后准备停下、什么都不留；引擎路径准备、拒绝、查表与现扫相同；线上格式）。App：`CrossReferencePreparationCoordinatorTests` 5 个（已索引的被准备并记入历史；后来索引的也准备；开关关撤回、再开重新准备；取消记为 cancelled；关着什么都不请求），`ReportViewModelTests.preparedCrossReferencesUnderTheirKind`（这一类排最后；关掉后没有 Turned off 行），`FindViewModelCrossReferenceTests.preparedLevelsListWhatScansList`（开着准备时调用层级一层的行与现扫相同）。库的交叉引用测试 66 个、引擎 61 个、App 570 个与设置 33 个都通过，macOS App 目标编译通过；没有在界面上实际点过。

## 第一次显示也秒出（2026-10-18）

上一节落地后用户试用：「现在就第一次显示的时候要加载一下，然后点击其他类型都是很快的秒出」，问是不是把初始化都挪到了第一次打开。不是：引用表从文档打开、镜像索引完就在后台建。第一次还要等，是查询还要现读几样只读一次、之后留着的东西。当时的解释给了三条——给结果起名的名字数据、Find 跨已索引镜像预筛用的两张表、刚启动时表还没建完——提议把前两条挪进后台；用户回复「第3点我能接受，本该如此」并批准开工。

**实测**（Debug，28 核，第一次查询现读的东西；当时向用户估的「名字数据 Debug 下好几秒、每个大镜像一两 MB」是错的，以这张表为准）：

| 现读的 | 谁会碰到 | 用时 | 留下的 |
|---|---|---|---|
| 补充名字的三个来源（导出表、ObjC 方法表、Swift 元数据） | 第一次给某镜像的结果起名：Inspector 与 Find 都会 | AppKit 0.29 s | 12 MiB |
| 每个 Swift 类型的 key | 第一次按 key 找某镜像里没有符号的类型（缓存里的内部类型都是） | AppKit 0.69 s、SwiftUICore 0.44 s | 3.3 MiB |
| 整个导出表的名字集合 | Find 第一次判断某镜像导出了某 Swift 类型没有 | SwiftUICore 0.09 s | 6 MiB |
| 改名再导出表 | Find 第一次跨已索引镜像查 C 函数、ObjC 方法或类 | 3.4 s，占满全部 28 核 | 1 MiB |
| 链接关系 | 同上，及 Swift 函数与类型 | 0.06 s | 1 MiB |

**库（MachOSwiftSection `251ed15b`，五份锁文件钉到它）**：能不读的改成不读——按 key 找类型只给描述符名字相同的类型算 key（约 1 毫秒），判断导出与否在导出表里按名字查三个符号，两处都对 Foundation 与 AppKit 的全部类型核对过结果不变；免不了的交给宿主提前读——`prepareNames(inImageAt:)`（三个来源、类名、类型符号）与 `preparePrefilters()`（链接关系与改名再导出表，只用调用线程：单线程 3.9 秒，28 核并行也要 3.4 秒，并行几乎不快）。另有 `approximateByteCount(ofImageDataAt:)` 估算一个镜像留着多少（与 malloc 实测差一成以内），`releaseImageData(exceptForImagesAt:)` 放掉指定镜像以外的。

**引擎**：
- 准备一个镜像在扫完之后接着读名字，进度多报一次「读名字」（`RuntimeCrossReferencePreparationProgress.isReadingNames`）；查询当场准备时也一样。
- 名字计入 Resident Limit：AppKit 从 21 MiB 记成 35 MiB（引用 21、名字连同函数表 14）。不计的话上限少算四成；用户常驻的五个镜像加起来仍在默认 256 MB 以内。
- 每一代的第一次准备完成后，在会话队列里排一个低优先级的任务读预筛表，只占 Max Concurrent Scans 里的一个；读的时候来了 Find 的查询，等它读完，不再并行读一遍。
- 起过名的镜像（预先准备的除外）超过 64 个时，只让分析器放掉预先准备之外的；此前是整个换掉分析器，预先读好的名字跟着丢了，浏览一阵被调之后第一次显示又会慢。准备好的镜像被淘汰（上限、关掉开关）时，它的名字一起放掉。

**App**：Report 里准备中的行在读名字时显示「Reading names」；进度乱序到达时按「先扫描、后读名字」取最远的一次。

**效果**（Debug，引擎进程内直接查，AppKit 准备好之后，Inspector 那种只查本镜像的查询；每种做法单独一个进程）：

| | 准备 AppKit | 第一次查 `NSWindow` 的类型引用 | 接着查 `NSView` | 再查 `NSWindow` | `makeKeyAndOrderFront:` 的调用者 |
|---|---|---|---|---|---|
| 改之前（准备只建表） | 5.8 s | 291 ms | 81 ms | 22 ms | 13 ms |
| 改之后 | 6.4 s | 21 ms | 57 ms | 20 ms | 13 ms |

Find 跨已索引镜像的第一次查询，另外省掉改名再导出表的 3.4 秒（后台读好之后）。界面上的感受（含连接往返与 Inspector 自己的加载）没有实测。

**仍然要等的**：刚启动、要查的镜像还没准备完（用户认为本该如此）；Callees 的目标在没索引的镜像里时，第一次给那个镜像的函数起名要现读它的导出表；预筛里按导入名比对、按类对象上的符号找别名，每次查询都现读，没有改。

**测试**：库 `PreparedImageDataTests` 5 个（预读之后三个来源、类名、类型符号都已读好，名字与不预读相同；估算随留着的东西增减；放掉只留指定镜像；预筛表一边预读一边被要，只建一次；单线程与并行读导出表结果相同），`SwiftTypeReferenceTests` 新增两个各跑 Foundation 与 AppKit（同名筛选的查找与比全部 key 相同；按名字查导出表与读整张表相同）。引擎 `CrossReferencePreparationTests` 新增 3 个、改 1 个：准备在最后报「读名字」、名字计入上限（上限只够引用、不够名字时不留）；超过函数表上限后分析器不换、预先准备的名字还在、别的镜像的放掉；第一次准备在后台读好预筛表；淘汰时连名字一起放掉。

## 加载一个镜像不再作废准备好的表（2026-10-19）

上一节落地后用户试用：「第一次显示类型引用依然要等很久，后面打开的就不用等待了」。原因不在准备得不够，而在准备好的表在用户点之前就被作废了。排查记录：[2026-10-19 第一次显示类型引用仍要等](../ResolvedIssues/2026-10-19-prepared-cross-references-dropped-when-an-image-loads.md)。

**原因**：会话原先只要看到共享缓存外的镜像列表有任何变化，就换一个分析器，准备好的引用表、读好的名字、扫描结果、预筛表全部作废。服务进程在常驻镜像准备完之后，会在后台建 Find 语料、生成 Swift 接口；其中一个元数据访问器触发了 FrontBoardServices 的 `+initialize`，它用 block 造方法，ObjC 运行时随之加载缓存外的 `libobjc-trampolines.dylib`。这每次启动都会发生（用户 10:25 那次运行在启动约两分钟后），App 的协调器以为表还在、不再请求，于是第一次查询当场重建（Debug 下 AppKit 约 6 秒），之后才秒出。上一节量的 21 ms 是在镜像列表钉死的测试会话上量的，测试会话一律钉死列表，正是为了躲开 trampolines 这个「干扰」。

**改动**（`RuntimeViewerCrossReferences`，库不变；用户批准「可以，都做」）：
- 只加载不换代：分析器认识的缓存外镜像仍是当前列表的前缀，就继续用它。缓存镜像编号固定，dyld 把新加载的镜像接在最后，原有编号都不变。
- 查询或准备要用的路径分析器找不到、而进程又加载过新镜像时，`analyzerIncludingImagesLoaded(since:)` 换一个包含新镜像的分析器，带着准备好的表、扫描结果和进行中的准备；名字在新分析器里按 high 优先级后台重读，预筛表在后面重读。会话新增 `numberingGeneration`（当前编号始于哪一代），表、扫描、准备按编号作废，不再按代。
- 分析器认识的镜像被卸载时照旧整个重来。
- 建分析器、换分析器、重来各记一条 info 日志。

**测试**：`CrossReferencePreparationTests` 新增 4 个，会话看到的缓存外镜像列表由测试控制——准备完再加载一个镜像，`URL` 的类型引用直接查表（修复前红：又准备一遍、用时 13.6 秒，修复后 5.8 秒）；被索引的新镜像让分析器换代、表留着、名字后台读好（修复前红）；认识的镜像被卸载照旧重来（前后都绿）；准备到一半换代，结果照样留下（修复前红）。

**真实 App**：用户当天用重新编过的 App 确认，准备完之后第一次打开类型引用直接出结果（「现在准备好是秒开了」）；没有量具体耗时。

## Inspector 的 References 标签改版（2026-10-19）

上一节在真实 App 里确认之后，用户对标签本身提了两点：「这里字体小一点，另外列表要占满整个inspector」。原先每段的行沿用 Find 导航页的样式（13pt 字、16pt 图标），比这一页其余 11pt 的字大一号；每段列表最高 240pt，整页再套一层滚动，只有一段时列表也停在半截。方案列给用户后批准「可以，改」。

**行**：Inspector 的行小一号——11pt 字（小号系统字，与这一页的「In AppKit」、提示、段标题同号）、14pt 图标（与一行字同高，不缩的话图标比字大一圈、上下也对不齐），行高固定为 20pt。`FindResultCellStyle.Metrics` 收着两套尺寸：`.navigator` 是 Find 导航页原来的，`.inspector` 是这一套；`InspectorReferenceCellViewModel` 用后者生成外观，`FindResultCellView` 按传入的尺寸摆图标。Find 导航页的行不变。

**布局**：去掉每段 240pt 的上限，几段一起分 Inspector 在标题与提示以下的高度，计算在 RuntimeViewerUI 的 `StackedHeightSharing`：每段至少拿到它的最小值、至多拿到它要的全部；没拿全的几段一样高。于是行少、放得下的段只占它要的高度，放不下的几段平分剩下的、各自在列表里滚，一直铺到 Inspector 底部；只有一段时（光标不在成员上），它就从段标题铺到底。每段的最小值是标题加上 80pt 的列表（三四行）；加载占位和提示消息不压缩。窗口矮到连这些最小值都放不下时，整页才滚动。各段的高度由一个自己摆放子视图的容器（`SectionsView`）按各段报出的需求算出，不靠 Auto Layout 的优先级去凑。需求从各部分自身的尺寸算（行高固定，所以列表多高事先就知道），不在布局过程中再跑一遍布局；为此 `SkeletonPlaceholderView` 新增 `contentHeight`。

**测试**：`StackedHeightSharingTests` 8 个（都放得下；一段放不下就铺满剩余；几段放不下时平分；不能压缩的段保持高度；平分不到最小值的段保持最小值；太矮时都给最小值、整页超出；要的少于最小值按最小值；空）、`SkeletonPlaceholderHeightTests`（`contentHeight` 与 Auto Layout 排出的高度相同，1 行与 5 行）、`FindResultNodeTests.inspectorRowsAreASizeDown`（Inspector 的行 11pt 字、14pt 图标，Find 导航页的仍是 13pt、16pt）。连同原有的 `FindResultNode`、`Find member rows`、`InspectorReferencesViewModel` 一起跑，五个套件 28 个测试通过（Xcode 27.0，`swift test` 退出码 0）。App 里改的两个文件，连同同样创建这种行的 `FindViewController`，用包测试编出的模块做了类型检查，通过。

**真实 App**：用户在重新编过的 App 里看过，「基本没啥问题了」。

## 无名函数收在最后、函数图标按语言上色（2026-10-19）

用户问「为什么 Swift 类型的引用很多都是没有名字的函数」。答案见前期调研「进程里能看到多少符号」一节的更正：很多 Swift 框架的本地符号被剥掉了，符号剥掉以后 Swift 的元数据又叫不出大多数函数的名字。用户随后要求：「Swift函数/方法图标用蓝色，C/C++函数用绿色，ObjC方法用橙色（现在是正常的），无名函数默认放最底下折叠起来」。方案列给用户后批准「可以，改」。

**图标**：Core 给 `RuntimeFunctionReference` 加了 `language`（`RuntimeFunctionLanguage`，按名字判断，不改线上格式）。有成员的看成员属于哪一边；有符号的看符号的拼法：Swift 修饰名是 Swift，`-[…]`、`+[…]` 是 ObjC 方法，其余（C 函数、C++、block）算 C/C++；既没有符号也没有成员却有名字的，名字来自 Swift 元数据，算 Swift。Find 导航页和 Inspector 的徽标随之上色：Swift 是蓝色 `f`，C/C++ 是绿色 `f`，ObjC 方法是橙色 `M`，无名函数仍是灰色 `f`；成员照旧用 `M`/`P`。被调里别的镜像导出的符号也按名字上色（原来一律灰色）。

**无名函数**：`FindCrossReferenceTree.gatheringUnnamedFunctions` 把每一层里没有名字的函数拿出来，按原顺序放到这一层最后一行「Unnamed Functions」下面（`FindCrossReferenceRow.Item.unnamedFunctions(count:)`，副标题写个数，再加上引用次数与精度）。调用者、被调、类型引用三种模式都这样：被调的其余行保持调用顺序；类型引用在每个镜像下面各有一行。Find 导航页的树只展开根和用户展开过的行，这一行于是默认折叠；它下面的函数是随这一层一起来的，展开不用再查，每个函数照常还能再展开、查它自己的调用者。Inspector 没有大纲视图，这一行用一个向右、展开后向下的箭头当图标，点一下展开或收起；每段只记住一个展开过的主题（`expandedUnnamedFunctions`），换到别的成员或类型时是折叠的。段标题的计数包含全部函数，「N of M」只在有行没列出来时出现。

**测试**：Core `CrossReferenceMatchingTests` 新增 2 个（符号拼法分出三种语言；函数的语言依次看成员、符号、元数据给的名字，没有名字就没有语言）。App：`FindCrossReferenceTreeTests` 新增 5 个（调用者、被调、类型引用里无名函数各收进最后一行；这一行默认折叠、下面的函数仍能加载；图标按语言上色，含导入的符号），`InspectorReferencesUnnamedFunctionsTests` 2 个（折叠时只占一行、计数照算全部；展开后函数跟在后面、箭头朝下、每行标识不重复）。

## 审查与修复（2026-10-17）

第 3 步续落地后，对本分支与 MachOSwiftSection 的 `feature/cross-reference-analysis` 一起做了一轮审查。本仓库的条目、裁决与测试记在 [2026-10-17 交叉引用审查记录](../KnownIssues/2026-10-17-cross-references-review-findings.md)；库那边的记在 MachOSwiftSection 的 `Roadmaps/2026-10-17-cross-reference-analysis-review-findings.md`。

**本仓库修了的**（每条都先写了修复前失败的测试）：

- 类型引用的目标对象去掉子节点，免得每条结果都把嵌套类型与特化整棵编码一遍（XR.C2）。
- 会话记住超出预算的扫描，同一代里不再记录，免得它每被问一次就把别的缓存挤掉一次、再留下半截（XR.C3）。
- 新 target 去掉没用到的 `RuntimeViewerCommunication` 依赖；会话单例注释说明为何不走 `@Dependency`（XR.C12）。
- 测试：两个「复用缓存」的测试改为跨全部镜像，第一次报多次、第二次只报一次（XR.D1）；类型的候选集按链接关系断言，另查一个不导入 `URL` 的镜像（XR.D4）；被调测试换成具体的接收者期望、错误描述检查带着主体、补上 `.member` 的往返编码与缓存外镜像的查询（XR.C13、XR.C1）。

**随 MachOSwiftSection 的修复得到的**（钉到 `0f1de10d`，五份锁文件只有这一条 pin 变了）：缓存外的镜像（注入的 App 自己的主程序、框架、插件）能按 dyld 的加载路径查到、结果里的路径也是加载路径（XR.C1）；被别的库改名再导出的 C 函数与类，跨库查调用者不再漏掉按新名字导入的镜像——缓存里有 1,438 条这样的再导出，AppKit 按 CoreGraphics 的名字调用了 273 个 SkyLight 函数；类型查询解开的名字不再留在进程级缓存里（XR.C6）；寄存器跟踪补上漏作废的写入。

**判为不修或误报的**：XR.C4、C5、C7、C8、C9、C11、B6，理由与复审条件见审查记录。循环头与跳转表落点保留 `x19`–`x28`（库那边的 A5）量过：现行做法错 0.02%–0.04% 的引用，几乎都是循环里那次发送的「精确 / 按 selector」标记，精确修法多花 35%–60% 的扫描时间；用户看过数据后定为保持现状，作为已知局限（库的 ReviewAdjudications A68）。

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
| 2026-10-16 | 状态 → Accepted | 用户得知「状态还是 Draft、默认假设没有逐条表态」后，指示「给这个分支建一个 worktree 然后开始实现」，视为批准 |
| 2026-10-16 | 状态 → In Progress；落地第一步完成 | 结论写入「前期调研 › 落地第一步的核实」。批量扫描用手写解码（按默认假设「先实测 Capstone 再决定」，实测快 25–50 倍）。桩布局、鉴别常量两条直接改写设计细节；全量索引与无符号函数两条推翻了当初的前提，交给用户重新确认 |
| 2026-10-16 | 不做存盘的全量索引，只按需扫描 | 重新确认。实测扫完整个缓存 1–4 秒，推翻了「建一次要好几分钟」的前提。否：照原设计两条路都做（索引约 200–400 MB，查询毫秒级）；只做存盘索引、iOS 仍按需。随之删去原第 5 步、`RuntimeCrossReferenceRouter`、索引相关的线上类型与命令、Report 条目和缓存目录；取代第二至四轮里关于全量索引的三条决定 |
| 2026-10-16 | 无符号函数照样扫描，作为调用者显示地址 | 重新确认。实测全缓存一半函数没有符号，它们发出的调用约占一半，227 个镜像全无符号。仍不推测名字，边界取自 `LC_FUNCTION_STARTS`。否：照原设计不显示；显示并归到取它地址的有名字函数下（留给后续）。修订用户最初「被脱掉符号的函数不做」的限定 |
| 2026-10-16 | 第 3 步：`typeReferences` 随 MachOSwiftSection 第二批落地 | 第一批的扫描器还不产生类型引用；先上一个只认 Swift 元数据访问器调用的版本，第二批时结果含义会变 |
| 2026-10-16 | 第 3 步：只按键扫描、不建整镜像反向表；会话缓存按「查询键 → 各镜像命中」，64 MB | 库第一批实测一张 AppKit 整表约 100 MB，并发建整表的峰值让分配器留下上 GB 脏页；原设计的「本库反向表」随之取消 |
| 2026-10-16 | 第 3 步：进度事件携带结果 | 前端（MCP 30 秒、CLI `--timeout`）到时取消，手里要有已扫镜像的结果 |
| 2026-10-16 | 第 3 步：线上目标改为 `importedSymbol` / `indirect` / `unrecognizedCode`，去掉 `unnamedCode` | 无符号函数本来就是函数，名字为空即可；落在所有镜像之外的地址没有镜像路径可填 |
| 2026-10-16 | 第 3 步：并发数为核数减一 | 扫描是同步计算，占满协作线程池会让同进程的其他请求干等 |
| 2026-10-16 | 第 3 步：ObjC 精度不查类层级，根类按名字认 | 被查的类常在没加载的镜像里，运行时问不到；接收者类不同只降为「按 selector」，不排除 |
| 2026-10-16 | 第 3 步完成（`typeReferences` 除外） | 记录见「第 3 步的落地记录」；接入时发现并修好 MachOSwiftSection 第一批漏认缓存内传统发送的缺陷（`8eea8cb7`） |
| 2026-10-17 | `typeReferences` 落地：ObjC 类按运行时名字、Swift 结构体 / 枚举 / 类按对象名字（即库的 key）换成库里的类型；协议等报 `typeNotFound` | MachOSwiftSection 第二批产出类型引用；RuntimeViewer 的 Swift 类型对象名就是 key（SwiftData 193 个全部找到） |
| 2026-10-17 | 调用者预筛对 Swift 名字改按链接关系（`imageIndices(callingFunctionAt:symbolNames:among:)`） | 缓存 4,113 个镜像只有 245 个留着 Swift 未定义符号，第 3 步按导入筛会漏掉其余镜像里的调用者；回归测试按候选集断言，行为测试分辨不出 |
| 2026-10-17 | 会话缓存的键改为扫描键，类型按类对象或描述符的位置 | 同名的类可能分属 macOS 与 Mac Catalyst 两个变体，按名字会混用结果 |
| 2026-10-17 | 审查后修复 XR.C2、C3、C12、D1、D4、C13；MachOSwiftSection 钉到 `0f1de10d`（缓存外镜像的路径、改名再导出、瞬时 demangle、寄存器写入） | 用户批准「先按你推荐的路径修」；逐条见 2026-10-17 交叉引用审查记录 |
| 2026-10-17 | 落地顺序调整：修完审查问题后先做第 5、6 步（界面），第 4 步（CLI 与 MCP）放最后 | 用户原话：「修完接UI，MCP和CLI放最后，没问题再做」 |
| 2026-10-17 | 库的审查 A5（循环头沿用 `x19`–`x28` 的旧值）保持现状 | 精确做法多花 35%–60% 的扫描时间，只换来 0.02%–0.04% 的引用；本仓库按接收者类不同只降级、不排除，这些错误不会让调用者从结果里消失 |
| 2026-10-17 | 第 5 步照 Xcode 27.2 的 Call Hierarchy 做：按需加载、根自动展开、递归标记、按标题排序、无汇总行、禁用过滤框、Xcode 的占位文字 | 逆向结果见「第 5 步的落地记录」与 `/Volumes/RE/Xcode/27.2/README.md`；用户要求「做得和 Xcode 一样」靠逆向而不是照截图 |
| 2026-10-17 | 与 Xcode 的六处不同（一个调用者一行、范围生效、Loading 行与进度、根多时不自动展开、一次一层、不预取） | 理由逐条见「第 5 步的落地记录」的表 |
| 2026-10-17 | 多镜像范围改为逐个镜像查询；引擎按 dyld 解析框架符号链接路径；ObjC 方法的调用者与被调带上所属成员 | 落地测试抓出的三个缺陷，各带修复前失败的测试 |
| 2026-10-17 | 第 6 步：成员按行对齐用 Core 的反向读行接口，以 `.runtimeViewerDeclaredMember` 属性标在内容文本上 | 和类型名的 `.link` 同一个做法，两条文本路径共用；读行规则与 Find 语料定位成员的是同一套，不另写一份 |
| 2026-10-17 | 主菜单只给 Find Call Hierarchy 设快捷键 ⌃⇧⌘H | 照 Xcode 的按键绑定；Callees 与 Type References 在 Xcode 里没有对应命令 |
| 2026-10-17 | Inspector 的 References 标签只给 ObjC 类与 Swift 结构体、枚举、类；SourceEditor 路径暂不跟随光标 | 这些类型的成员有代码、引用也找得到；SourceEditor 的桥接层没有选区回调，要另按该模块的规矩做 |
| 2026-10-17 | Inspector 的 References 标签只查对象所在的镜像，且只在可见时查 | 用户试用时 Inspector 每换一个对象就发起一次全部镜像的扫描，看不见时也查；用户选「只查对象所在的镜像」，全部镜像交给 Find |
| 2026-10-17 | 会话共享进行中的扫描（`sharedScan`）；展开行时下一层延到主线程下一轮再启动 | Find 与 Inspector 同时查同一主题各扫一遍；展开时同步发布引起 RxSwift 重入警告。各带修复前失败的测试 |
| 2026-10-18 | 交叉引用只扫引擎已索引的镜像：范围 `.allImages` 改名 `.indexedImages`，指定未索引的镜像报 `imageNotIndexed`；Callees 不受影响 | 用户原话：「分析只在已经索引的image里面进行，其他没加载索引的不分析」。取代 2026-10-16 第二轮的「跨库范围：整个共享缓存 + 已加载的非系统库」。Find 的范围本来就叫 Indexed Images |
| 2026-10-18 | 同时扫几个镜像改由设置 Max Concurrent Scans 决定（1 到核数，默认 4），经查询选项带到服务进程、全进程共用；扫描移到会话自己的 utility 队列，不占协作线程池 | 用户原话：「具体用多少核让用户可以决定，跟后台索引一样，设置里面可以改」。取代 2026-10-16 的「第 3 步：并发数为核数减一」：那条要给同进程的其他请求留线程，可留下的只有一个协作线程 |
| 2026-10-18 | 已索引镜像的引用表预先在后台建好、只放内存；用库里新做的紧凑表；查询查表，表没建好就提到队首建好再答 | 用户原话：「能像后台索引和搜索语料一样提前准备好吗」，选「紧凑表」「只放内存」。否：库现成的整表（一条引用约 80 字节，常驻的五个镜像估算 300–400 MB）；存到磁盘（要处理格式、失效与清理）。修订 2026-10-16「不做存盘的全量索引，只按需扫描」 |
| 2026-10-18 | 预先准备的默认假设 | 镜像一索引就排队建表、并发数沿用 Max Concurrent Scans、低优先级；进度进 Report 导航页；设置开关默认开、上限默认 256 MB、超出按最近使用淘汰；开关关掉回到现扫。提问前列给用户，用户没有异议 |
| 2026-10-18 | 实现中自定：关掉准备时 Report 里 Cross References 一类不显示「Turned off in Settings」 | 关掉后查询照样能用（现扫），没有后台工作要报告；索引与语料关掉会让功能失效，所以才需要那一行 |
| 2026-10-18 | 实现中自定：`ViewModelTestEnvironment` 里 Keep Cross References Ready 默认关 | 开着时每个在引擎上打开文档的测试都会在后台准备镜像，计入活动与 Report 行，别的测试数这些；讲它的测试自己打开 |
| 2026-10-18 | 实现中自定：被淘汰的镜像不在后台补建，由下一次查到它的查询当场建 | 后台补建会和查询抢上限，反复淘汰再补建；查询当场建与现扫的代价相当 |
| 2026-10-18 | 结果行的单行标题把截断写进富文本的段落样式；标题标签不可选中 | 用户试用时 Inspector 的行只显示「-」、点一下才显示。富文本不认标签的 `lineBreakMode`；与侧栏等其他列表的做法一致。用户回复「改」 |
| 2026-10-18 | 准备一个镜像时连同给结果起名的名字一起读好，每一代第一次准备后在后台读好 Find 预筛用的两张表 | 用户问第一次显示为何还要等，批准把起名数据与预筛表挪进后台；刚启动表没建完时要等，用户认为本该如此（「第3点我能接受，本该如此」） |
| 2026-10-18 | 实现中自定：按 key 找类型、判断类型导出与否改成不现读整张表，而不是挪进后台 | 实测这两样第一次分别要 0.7 秒与 0.1 秒、留 3–6 MiB；按名字先筛、在导出表里按名字查，第一次就只要约 1 毫秒、什么都不留，比提前读更省 |
| 2026-10-18 | 实现中自定：预筛表在后台只用一个线程读 | Debug 下单线程 3.9 秒、28 核并行 3.4 秒，并行几乎不快；后台占满所有核违背用户定的 Max Concurrent Scans |
| 2026-10-18 | 实现中自定：读好的名字计入 Resident Limit | 名字连同函数表，AppKit 与 Foundation 约为引用表的七成（AppKit 14 MiB 对 21 MiB），SwiftUICore 与 libswiftCore 比引用表还大；不计则上限少算一半上下；用户常驻的五个镜像仍在默认上限以内 |
| 2026-10-18 | 实现中自定：起过名的镜像超过 64 个时，只放掉预先准备之外的镜像，不再整个换掉分析器 | 换分析器会把预先读好的名字一起扔掉，浏览一阵被调之后第一次显示又会慢 |
| 2026-10-19 | 共享缓存外多加载一个镜像不再换分析器；查询要用到新加载的镜像时才换，并带着准备好的表、扫描结果和进行中的准备，名字与预筛表在新分析器里后台重读；分析器认识的镜像被卸载才整个重来 | 用户反馈第一次显示类型引用仍要等。lldb 挂在用户的 Debug 包上实测：常驻镜像准备完之后，服务进程生成接口时加载了 `libobjc-trampolines.dylib`，下一次查询便换代、作废全部准备好的表。给出「只加载不换」与「换时带过去」两项，用户回复「可以，都做」 |
| 2026-10-19 | 实现中自定：一条路径不对应任何镜像时，进程每加载一批新镜像，分析器为它换一次 | 要精确判断「找不到的路径是不是新加载的镜像」，测试就得在进程里真的加载一个缓存外镜像，没有稳妥可加载的；换的时候准备好的表照样保留，代价只是名字与预筛表在后台重读 |
| 2026-10-19 | Inspector 的 References 标签：行小一号（11pt 字、14pt 图标、行高 20pt），Find 导航页不变；去掉每段 240pt 的上限，几段分 Inspector 的高度——放得下的段只占所需，放不下的平分剩余、各自滚动，铺到 Inspector 底部；窗口矮到每段连 80pt 的列表（三四行）都放不下时整页滚动 | 用户确认秒开后提出「这里字体小一点，另外列表要占满整个inspector」。字号取这一页其余文字的 11pt、图标随字缩到 14pt、多段时的分法与窗口太矮时整页滚动，都是方案里写明的，用户回复「可以，改」；每段最少留 80pt 是实现中沿用导航列表原有的下限 |
| 2026-10-19 | 更正前期调研「进程里能看到多少符号」：macOS 26.7 缓存 37.8% 的函数起点没有符号，Swift 新框架多被剥，并记下靠元数据能补回的估算 | 用户问为什么 Swift 类型的引用多是无名函数；原句「几乎全部函数都有名字」只数了符号条数。用户同意更正 |
| 2026-10-19 | 函数图标按语言上色（Swift 蓝、C/C++ 绿、ObjC 橙、无名灰）；每层的无名函数收进最后一行「Unnamed Functions」，默认折叠，Find 导航页与 Inspector 都这样 | 用户提出；方案列给用户后回复「可以，改」 |
| 2026-10-19 | 实现中自定：Inspector 每段只记住一个展开过的主题，不另外在换主题时清掉 | 换到别的主题时那个主题本来就是折叠的；切回刚展开过的主题仍是展开，只要期间没在这一段展开别的。为此再写一条换主题时清状态的订阅，得在 Rx 管线中途改状态，不值得 |
| 2026-10-19 | 引擎与界面（落地步骤第 1–3、5、6 步）合入 next，取号 0056；状态保持 In Progress，第 4 步 CLI 与 MCP 在本分支继续 | 用户收尾时选「先合引擎和 GUI 进 next」：本提案写明从第 3 步起每一步都可以单独合入。MachOSwiftSection 的库提案先以 0072 合入它的 next（合并时把三个对照 Capstone 的测试移植到 swift-capstone 7，用户同意），Core 改回钉 MachOSwiftSection 的 next。配套专题文章与新术语这两项判断，留到第 4 步完成、状态改为 Implemented 时做 |

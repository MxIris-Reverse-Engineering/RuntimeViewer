# Draft - 交叉引用：调用层级、被调与类型引用

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-16
- **最后更新**: 2026-10-16
- **所属愿景**: 无（CLI 与 MCP 部分沿用[《无头 RuntimeViewer》](../Visions/HeadlessRuntimeViewer.md)「GUI、命令行与 MCP 三个前端共用同一套命令词汇」的取向，但不推进该愿景的步骤）
- **关联提案**: [0029-find-navigator](0029-find-navigator.md)（Find 导航页、成员定位与高亮）、[0047-open-command-registry-and-injection-module](0047-open-command-registry-and-injection-module.md)（命令扩展范式）、[0037-local-runtime-xpc-service](0037-local-runtime-xpc-service.md)（本地运行时 service）、[0055-engine-scoped-background-work](0055-engine-scoped-background-work.md)（按 Engine 共享的后台工作与 Report）；MachOSwiftSection 侧的库提案（动工时创建）
- **实现分支 / PR**: `feature/cross-references`（worktree `.worktrees/RuntimeViewer-CrossReferences`）
- **配套文档**: 待定 —— 落地时判断：CLI / MCP 的目标写法与精度标注是否需要使用指南；两种桩布局、鉴别常量反查这些解析规则是否需要实现说明

## 摘要

给 RuntimeViewer 加上从机器码里读出来的交叉引用：选中一个方法，能看到它**调了谁**（被调）、**谁调了它**（调用者，范围是整个系统共享缓存），以及**哪些方法用到了某个类型**（类型引用）。函数的名字只取自符号表，以及 ObjC 方法表、Swift 类型描述能叫出名字的方法，不为脱了符号的代码推测名字；没有名字的函数照样扫描，作为调用者时显示成「无符号函数 0x…」。只支持 arm64 / arm64e。分析逻辑放进 MachOSwiftSection 的一个新 target，RuntimeViewer 新增一个命令扩展模块去调用它，三个前端共用：GUI（Find 导航页加 Call Hierarchy / Callees / Type References 三种模式，内容区的方法名上右键发起查询，Inspector 新增跟随光标的 References 标签）、CLI（`callers` / `callees` / `references`）和 MCP（`Callers` / `Callees` / `TypeReferences`）。查调用者一律按需扫描：先用导入表和 selector 引用筛出可能相关的库，只扫这些库，扫过的库在会话内缓存结果；实测扫完整个共享缓存也只要 1–4 秒，所以不做存盘的全量索引。精度如实标注：ObjC 以 selector 为准，能确定接收者类时标出类；Swift 的虚方法、协议方法给出候选目标，闭包调用只标出签名形态。

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

（数据来自 `dyld_info -load_commands` 的 `LC_DYSYMTAB`。）`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/` 下没有单独的 `.symbols` 文件，本地符号就在每个镜像自己的 `LC_SYMTAB` 里，而 MachOKit 的 `MachOImage.symbols64` 读的正是它（`MachOKit/Sources/MachOKit/MachOImage.swift:215-225`）。所以**在 macOS 上，进程内的 RuntimeViewer 能看到系统库几乎全部函数的名字**；`dyld_info -lookup_va` 也能把 0x184AE3608 叫成 `_NSWindowWakeDeferredIfNeeded` 这种不导出的 C 函数。

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
- 未验证：真机上 App 进程能否读到 `.symbols`；26.x 及更早的缓存里 selector 引用是否唯一化（只在 27.2 上测过）；核心更少的机器上的实际扫描时间（只在 28 核机器上用 4、8 线程模拟过）。

## 提议方案

一句话概括：**MachOSwiftSection 负责从一个镜像里读出「函数表（能叫出名字的带上名字）」和「每个函数引用了什么」，RuntimeViewer 负责查询、会话缓存和三个前端。**

1. **函数**：边界取自 `LC_FUNCTION_STARTS`。名字取自符号表里位于代码段的符号、ObjC 类与分类方法表里的实现（`-[类 selector]`），以及 Swift 类型描述、虚表、协议遵循里能找到实现地址的方法；同一地址上的多个名字合并为一个函数。没有名字的函数照样扫描，显示为「无符号函数 0x…」，不推测名字。
2. **引用**：逐条解码每个函数的 arm64 指令，认出直接调用与尾调用、selector 桩与传统的 `objc_msgSend`、super 发送、经桩的跨库调用（镜像自带的桩，或 macOS 27 / iOS 27 起全缓存共用的桩）、类型引用（Swift 元数据访问器、按 mangled 名字实例化类型、ObjC 类引用）以及间接调用。
3. **精度**：ObjC 以 selector 为准，接收者是 `self`、类字面量（`[NSWindow alloc]`）或 super 时标出类并允许按类过滤，否则标为「接收者未知」；Swift 的虚表与见证表调用按鉴别常量和表内偏移反查根声明，展开成候选目标并标为「候选」，闭包调用只标出签名形态；value witness、retain / release、outlined 值操作等运行时辅助调用默认隐藏。
4. **查询**：查「调了谁」只解码这一个函数；查「谁调了它」和「哪些方法用到某个类型」时，本库直接扫，跨库则先按导入表与 selector 引用筛库，再并发扫候选库；扫过的库在会话内缓存反向表。不做存盘的全量索引。
5. **前端**：Find 导航页的三种新模式、内容区右键、Inspector 的 References 标签；CLI 三个子命令；MCP 三个工具。
6. **范围**：跨库指整个共享缓存，加上目标进程里已加载的非系统库。每个引擎在自己的进程里扫它映射的那份缓存，所有平台走同一条路径。只支持 arm64 / arm64e。

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
| 本镜像的 `__stubs` / `__auth_stubs` | `importedSymbol`：桩的间接符号序号给出名字，再与它取指针的槽位交叉核对 |
| 全缓存共用的 GOT 桩（`adrp x17; add x17; ldr x16, [x17]; braa x16, x17`） | `address`：读出槽位里绑定的指针、去掉指针认证位，就是真正的目标 |
| 本镜像里的函数 | `address` |
| 别的缓存镜像（26 及更早，缓存构建器绕过了桩） | `address`：按缓存镜像的地址区间找到所在镜像，再到它的函数表里查 |
| `$s…Ma` 元数据访问器 | `typeMetadataAccessor` |
| `__swift_instantiateConcreteTypeFromMangledName(V2)`、`swift_getTypeByMangledName*` | `mangledTypeName`：名字取自 `x0` 指向的缓存变量 |
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
    public let references: [RuntimeCrossReference]
    /// `false` when a limit, a time budget or a cancellation cut the scan short.
    public let isComplete: Bool
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
}

extension RuntimeEngine.CommandName {
    static let crossReferenceCallees = Self("crossReferenceCallees")
    static let crossReferenceCallers = Self("crossReferenceCallers")
    static let crossReferenceTypeReferences = Self("crossReferenceTypeReferences")
}
```

- 线上名字保留 Core 的命名空间前缀（`RuntimeViewerInjection` 的 `RuntimeInjection+CommandNames.swift` 讲了原因：拼出来的完整字符串就是线上契约）。
- `callers` 与 `typeReferences` 是 `RuntimeEngineProgressCommand`，并把 `cancelsAcrossConnections` 设为 `true`：调用方一取消，请求就从提供服务的那一端撤回。
- 旧引擎（没有这个扩展的载荷、旧版 App 的对端）对这些命令没有处理器，派发会失败；前端统一显示「这个引擎不支持交叉引用（需要更新载荷或 App）」，与注入能力查询的处理方式一致。

### 6. 查询路径

**调了谁**：在 subject 所在的镜像里找到函数——成员沿用 `memberAddresses` 的取法得到实现地址，ObjC 方法用 IMP；selector 作为 subject 没有意义，直接报错——然后只解码这一个函数。按 AppKit 的平均值，解码一个函数约 1 微秒。

**本库的调用者与类型引用**：第一次查某个镜像时，把它的全部函数（有名字的和没名字的）扫一遍，把「目标 → 引用」的反向表留在引擎进程里。每个镜像一份，会话内有效，按字节预算做 LRU 淘汰，做法与 Find 语料相同。实测单线程扫一个 AppKit（19 MiB 代码）约 0.1 秒，全缓存平均每个镜像约 6 毫秒。

**跨库查询**（一律按需扫描，不做存盘索引）：

1. 预筛：导出符号 → 导入了它的镜像（符号表里的未定义符号）；ObjC 方法 → 引用了这个 selector 的镜像（`__objc_selrefs`）；类型 → 导入了它的类型描述符（`$s…Mn`）、元数据访问器（`$s…Ma`）或 `_OBJC_CLASS_$_…` 的镜像；不导出的函数 → 只有它所在的镜像。候选镜像取自 `DyldCacheLoaded.machOImages()`，再加上进程里已加载的非缓存镜像。实测按 selector 筛，中位数只剩 1 个镜像，第 99 百分位 15 个，最多 2,758 个（`init`）。
2. 在引擎进程里有界并发地扫描候选镜像（并发数取处理器核数），复用已缓存的反向表，按镜像报告进度，结果随到随出。最坏情况是扫完整个缓存：实测 28 核约 1 秒，4 个线程约 4 秒。
3. 取消与时限：调用方取消即撤回（`cancelsAcrossConnections`）；MCP 的 30 秒或 CLI 的 `--timeout` 一到，就返回已有结果并标 `isComplete == false`。扫完的镜像留在缓存里，重试会接着扫剩下的。
4. 内存：全缓存去重后的「函数 → 目标」边约 5,200 万条（有名字和没名字的函数各占一半），全部留在内存里约要 600 MB，所以按字节预算淘汰。最热的几个 selector 每次都可能要重扫一部分镜像，这是不做存盘索引的代价。

原设计在这里还有「全量索引」（由本地运行时 service 在第一次跨库查询时建好、按缓存 UUID 存进 `~/Library/Caches`）和「路由」（`RuntimeCrossReferenceRouter`）两部分。落地第一步实测扫完整个缓存只要 1–4 秒，用户据此决定不做存盘索引，这两部分连同 Report 导航页的索引条目一并删去，理由见决策日志。

### 7. GUI

**Find 导航页**：`FindMode` 新增三个 case。界面细节通过逆向 Xcode 27 的 `IDEFindNavigatorCallHierarchyQuery` 来对齐，不照着截图调。

| 模式 | 标题 | 查询框 | 结果 |
|---|---|---|---|
| `callHierarchy` | Call Hierarchy | 方法（`-[NSWindow makeKeyAndOrderFront:]`、Swift 名、符号名）或 selector | 调用者树：每个节点是一个函数，展开一层就查一次它的调用者 |
| `callees` | Callees | 方法 | 被调树：同样逐层展开 |
| `typeReferences` | Type References | 类型名 | 引用该类型的函数，按库、按类型分组 |

- 查询框的写法与 CLI 的目标写法相同（见第 8 节）。范围控件对这三种模式生效，默认查全部镜像，可以缩小到当前镜像。
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
- **选项**：`--image`、`--scope image` 或 `--scope all`（`callers` 与 `references` 默认 `all`）、`--receiver <类>`、`--include-runtime`、`--limit <n>`；全局的 `--source`、`--json`、`--timeout` 照常可用。
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
- 默认开启，没有开关：平时不占用资源，只在查询时扫描。
- CLI 的 `--help` 与 agent 插件的 skill 同批更新；装了插件的 agent 在插件版本号变化后会拿到新的用法。

### 数据与配置兼容

- 不写任何文件：扫描结果只缓存在引擎进程的内存里，按字节预算淘汰。
- 不改动设置、书签或任何已有文件，无需迁移。
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
3. **`RuntimeViewerCrossReferences` 模块**：线上类型与命令；在 `AGENTS.md`「Injection commands」那张表列出的全部入口调用 `install()`，并把这条义务写进 `AGENTS.md`；本库扫描与会话缓存；跨库按需扫描（预筛、并发、进度、取消）。
4. **CLI 与 MCP**：三个子命令、三个工具，agent 插件的 skill 与版本号，以及 `Guides/CommandLineInterface.md`。
5. **Find 导航页的三种模式**：逆向 Xcode 27 的 Call Hierarchy 来对齐界面；结果树、范围控件、精度标记、运行时调用开关；按 `RuntimeViewerApplicationTests` 的规则写 ViewModel 契约测试。
6. **内容区右键与 Inspector 的 References 标签**：成员按行对齐、两条文本路径的菜单、光标所在成员、标签本身及其 ViewModel 测试。

原设计的第 5 步「全量索引」随存盘索引一起删去。

每一步都能单独构建、单独验证；从第 3 步起，每一步都可以单独合入。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 预计需要：一份使用指南（目标写法、精度标注的含义、哪些引用静态看不见），一份实现说明（两种桩布局、鉴别常量反查与无符号函数的处理规则）。写了就登记到头部的「配套文档」。
- **有没有引入新术语** —— 预计有：交叉引用、按需扫描与预筛、候选目标、运行时辅助调用、全缓存共用桩、无符号函数。同批次登记进 `Documentations/Glossary.md`。

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

# Draft - ObjC 类与 Swift 类互标角标、互相跳转

- **状态**: Implemented
- **创建日期**: 2026-09-24
- **最后更新**: 2026-09-24

## 摘要

同一个类在 sidebar 里有两个条目：ObjC 类列表里一个，Swift 列表里一个。今天只有 ObjC 那一侧说明了
「它其实是 Swift」——桥出的 Swift 类挂蓝色 `C`（`isSwiftClass`），`@objc @implementation` 类挂粉色
`C`（`isObjCImplementation`）；Swift 那一侧的条目（Swift class，或 `@objc @implementation` 的那个
`extension`）什么都不标，两边也没有互相跳转的入口。本提案给 Swift 侧补上角标，同样放在第二个图标位，
并在 sidebar 行的右键菜单里加一个「跳到另一面」的菜单项。

## 方案

**配对——ObjC 运行时名 remangle 出来就是 Swift 侧的键。** 桥出类的运行时名（`_TtC6AppKitP33_05EA…24FontPanelBIUSPopUpButton`）
demangle 再 remangle，得到的字符串就是 Swift 侧 `RuntimeObject.name`（`mangleAsString(typeName.node)`），直接当键查，
不必两边都打印出来再比。要点是只 remangle 其中的 `Type` 节点：运行时名 demangle 出来是完整的类型 mangling
（`Global(TypeMangling(Type(Class(…))))`），整棵 remangle 得到的是符号 `$s…CD`，而 Swift 侧的键是 `Type` 节点单独
mangle 的 `…C`。Inspector 的 Relationships 面板把桥出子类还原成 Swift 类用的也是这条路
（`RuntimeRelationshipsResolver.materializeObjCReference`），而且一直是整棵 remangle，所以**每个**桥出子类都被悄悄丢掉
了（见决策日志）；这次把这段收进 `RuntimeSwiftSection` 一处，两个功能共用，一起修好。private 类还要靠
MachOSwiftSection 从 `_symbolic` 符号还原鉴别符（其流水账 2026-09-24 两节）：还原之后 macOS 26.7 AppKit 注册到 ObjC
运行时的 183 个 Swift 类两侧名字逐字一致。`@objc(CustomName)` 的类名不是 mangling，仍配不上。`@objc @implementation`
这一对不靠名字：MachOSwiftSection 已把识别结果挂在 Swift 侧的 `extension` 上（`ExtensionDefinition.objcImplementation`，
带 ObjC 类名）。

**标记**——`RuntimeObject.Properties` 新增 `isObjCClass`（`1 << 4`），打在「本镜像的 `__objc_classlist` 里有它的类对象」
的 Swift class 上，与 ObjC 侧的 `isSwiftClass` 对称。`RuntimeSwiftSection` 读自己镜像的类表，只取带 Swift 位的类对象，
把运行时名 remangle 成键，建一张「Swift 键 → ObjC 类名」表；进程内的类多半已被运行时 realize，类名要经 `class_rw_t`
找回 `class_ro_t` 读。`isObjCImplementation` 的含义扩到 Swift 侧，同时打在那个 `extension` 上，一对条目带同一个标记。
打标在 `RuntimeSwiftSection` 的两个出口（`allObjects()` 与 `makeRuntimeObject(forMangledTypeName:)`），sidebar 与
Inspector 的关系行给出同一个答案。泛型类与特化出来的类没有静态类对象，不打标。

**角标**——`RuntimeObjectIcon.secondaryIcon(for:)` 加一支：`isObjCClass` 给橙色 `C`（ObjC 类的图标）；Swift 侧
`extension` 带 `isObjCImplementation` 时自动拿到粉色 `C`。规则是「角标画出另一面」：桥出类的另一面是普通 Swift 类 /
ObjC 类，所以两侧互为蓝、橙；`@implementation` 这一对两侧都用粉色标出这层关系。三处 cell ViewModel 本来就都走这个
函数，Sidebar、Inspector 的 Relationships 与 Specializations 同时生效。

**引擎**——新增 `RuntimeEngine.counterpart(for:) -> RuntimeObject?` 与 `CounterpartRequest`，登记进共享命令表，本地 XPC
service、远端进程与代理服务器自动可用。ObjC 桥出类 → Swift class（上面的 remangle）；ObjC `@implementation` 类 → 那个
`extension`；Swift class → 表里的 ObjC 类名；`@implementation` 的 `extension` → 识别结果里的 ObjC 类名。另两个方向都经
同一镜像的 ObjC section 物化，返回的对象与 sidebar 列出的同一个 key，跳过去后 sidebar 能选中对应行。`RuntimeObject`
上加一个只看 kind 与标记的 `counterpartKind`，UI 靠它同步决定菜单项出不出现、标题写什么。

**菜单**——加在 `SidebarRuntimeObjectViewController.contextMenuItems(for:clickedRow:)`（基类，对象列表与书签列表都有），
排在「Open in New Tab」之后：ObjC 桥出类「Jump to Swift Class」、ObjC `@implementation` 类「Jump to Swift
Implementation」、Swift 一侧「Jump to Objective-C Class」。点击后经 ViewModel 新增的 Input 查引擎，再
`selectionRouter.trigger(.push(_:))`，与点击 sidebar 行等价（进历史、sidebar 选中目标行）。新 Input 带默认值
`.empty()`，其余构造 Input 的地方（UIKit、测试）不用改。菜单项按标记出现，所以 ObjC 侧 `@objc(CustomName)` 的桥出类
也会有这一项，点了查不到时经 `errorRelay` 弹提示说明原因。

**验证**——Core 锚定 macOS 26 的 AppKit：`NSGlassEffectView` 与其 `extension` 互跳；private 桥出类
（`FontPanelBIUSPopUpButton`，以及嵌套的 `NSScrollPocket.ElementContainerModel`）互跳；AppKit 每个带 Swift 位、名字能
demangle 的 ObjC 类都找得到另一面并能跳回自己；`NSView`、Swift struct 返回 `nil`；两个出口的 `isObjCClass` 一致。
Relationships 另加一条回归：`NSObject` 的子类里要有桥出的 Swift 类。Application 覆盖角标选择与 ViewModel 收到请求后
push 出另一面、查不到时报错。

**依赖**——要带上述修复的 MachOSwiftSection。本地验证走本地依赖（`USING_LOCAL_DEPENDENCIES=1`，worktree 旁的
`MachOSwiftSection` 链接指向它的 next worktree）；本地 swift-capstone 按用户指示切到 `v5`（`next` 已是 capstone 6，trait
改名为 `AARCH64`，MachOSwiftSection 要的是 `ARM64`）。Release 要等 MachOSwiftSection 发版并同批提升 pin。

**连带变化**：Relationships 面板里桥出的 Swift 子类第一次真正出现（此前全部被丢掉，见决策日志）。另有一条随
MachOSwiftSection 修复一起到来、与本功能无关的：private Swift 类型的 `RuntimeObject.name` 在系统镜像里开始带鉴别符，
旧书签里存的这类对象名字对不上，会找不到接口。

**不做**：CLI 与 MCP 的模型和命令不动；内容区与 Inspector 列表的右键菜单不加这一项；旧书签存的是当时的对象快照，不带
新标记，重新加书签才会出现角标和菜单项；sidebar 的过滤面板只按泛型 / 特化过滤，新标记不进去。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-24 | Created as Draft | 用户要求：Swift 侧也展示 `isSwiftClass` / `isObjCImplementation`，放在第二个图标位，并给这两面加互相跳转的右键菜单项 |
| 2026-09-24 | 配对用类对象里的 Swift 描述符指针，不用 ObjC 运行时名 | AppKit 实测：147 个 `_TtC6AppKit` 类里 73 个是 private，名字两侧对不上；`@objc(CustomName)` 无法 demangle |
| 2026-09-24 | 新增 `isObjCClass`；`isObjCImplementation` 两侧共用 | 与 `isSwiftClass` 对称；`@implementation` 这一对是同一层关系，同一个标记配同一个粉色角标 |
| 2026-09-24 | 菜单只加在 sidebar 行上，排在「Open in New Tab」之后 | 用户点名的是右键菜单；基类统一加，对象列表和书签列表一起有 |
| 2026-09-24 | 改为按名字配对，取代上面「描述符指针」一行：两边 demangle 后比较，Swift 侧带私有鉴别符就连它一起比，不带就去掉 ObjC 侧的再比，撞名放弃 | 用户：「Swift 这边输出的名字是去掉了私有鉴别符的，你要比较加上就行了」「`RuntimeObject` 的 name 就是 mangledName，你重新 demangle 就行了」。核实后补上「不带」那一支：系统镜像里 Swift 侧的节点本身就没有鉴别符，不只是打印时藏掉；AppKit 的 191 个 Swift 类去掉鉴别符后不撞名。代价是 `@objc(CustomName)` 的类配不上 |
| 2026-09-24 | 撤掉「不带就去掉 ObjC 侧的再比」那一支，回到完整比较；鉴别符缺失改在 MachOSwiftSection 修 | 用户：「objc有私有鉴别符swift没有就是有问题，应该是SymbolicDemangler.demangleContext没有还原出来」。查实：`_symbolic` 符号（`_symbolic _____ 6AppKit24FontPanelBIUSPopUpButton33_05EA…LLC`，用户在 Hopper 里确认）带着鉴别符，`SymbolicDemangler` 没读；它挂在 `__swift5_typeref` 的 mangled name 上，按匿名上下文偏移查不到，改为顺着引用建索引。修复后 AppKit 183 个 Swift 类两侧名字全部一致 |
| 2026-09-24 | 配对改为「ObjC 运行时名 remangle 出的字符串直接当 Swift 侧的键」，与 Relationships 面板共用一段 | 用户：「现在没有这个问题了看怎么改」。两侧名字逐字一致之后，不再需要把两边打印出来比：remangle 出的就是 `RuntimeObject.name`，Relationships 面板本来就这样查，互相跳转复用它，并把它收进 `RuntimeSwiftSection` 一处 |
| 2026-09-24 | In Progress | 用户：「你再去把最初的RuntimeViewer需求写一下」 |
| 2026-09-24 | 顺手修 Relationships 面板丢掉全部桥出子类的问题 | 实现时 AppKit 的 183 个桥出类一个都配不上，查出是整棵 remangle 的问题（见「配对」）。`main` 上是同一段代码，自提交 c3eb2735 引入 relationships API 起如此；原有测试「Bridged class surfaces once…」只查「不会既是 Swift 又是 ObjC」，全部丢掉照样通过。补一条回归测试「Bridged subclasses surface as their Swift classes」，修复前红、修复后绿。同类写法（把 ObjC 运行时名当 Swift 键）全仓只此一处；草稿之前写的「MachOSwiftSection 修好后 Relationships 里的 private 子类自动回来」是错的，已更正。纪要：[ResolvedIssues/2026-09-24-relationships-dropped-every-bridged-subclass.md](../ResolvedIssues/2026-09-24-relationships-dropped-every-bridged-subclass.md) |
| 2026-09-24 | Implemented：`feature/objc-swift-class-counterparts` 合入 `next` | 用户：「都提交推送一下」。分三个提交：Relationships 修复（不依赖新版 MachOSwiftSection，可单独挑去 `main`）、会话开始前就在工作区里的 `displayName` 显示私有鉴别符（单独提交，去留独立）、本功能。验证：Core 本功能相关 20 个测试与 Application 全部 210 个测试通过，App（Debug、Xcode 27）编译通过，Debug 设置文件的 SHA 前后不变；Core 全量 513 个里，满载超时的 8 个 IPC 测试单独跑全过，Relationships 的 Swift 基线另有 4 行 `__C.Decimal…` → `__C.NSDecimal…`，来自 MachOSwiftSection 提案 0023，与本改动无关、未动。配套文档：不另写实现说明，方案与验证都在本提案，Relationships 的 bug 有 ResolvedIssues 纪要；没有新术语。Release 构建要等 MachOSwiftSection 发版、锁文件指向含 `_symbolic` 修复的版本后，private 类才配得上 |

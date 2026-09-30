# 0026 - ObjC 类与 Swift 类互标角标、互相跳转

- **状态**: Implemented
- **创建日期**: 2026-09-24
- **最后更新**: 2026-09-30

## 摘要

同一个类在 sidebar 里有两个条目：ObjC 类列表里一个，Swift 列表里一个。今天只有 ObjC 那一侧说明了
「它其实是 Swift」——桥出的 Swift 类挂蓝色 `C`（`isSwiftClass`），`@objc @implementation` 类挂粉色
`C`（`isObjCImplementation`）；Swift 那一侧的条目（Swift class，或 `@objc @implementation` 的那个
`extension`）什么都不标，两边也没有互相跳转的入口。本提案给 Swift 侧补上角标，同样放在第二个图标位，
并在 sidebar 行的右键菜单里加一个「跳到另一面」的菜单项。

## 方案

**配对——顺着类对象里的类型描述符指针。** Swift 类在 `__objc_classlist` 里的类对象就是它的 Swift 类元数据，其中的
`Description` 字段指向这个类的类型描述符，也就是 indexer 建出 Swift 侧 `TypeDefinition`、再建出 `RuntimeObject` 的那条
记录。`RuntimeSwiftSection` 扫一遍本镜像带 Swift 位的类对象，用 MachOSwiftSection 的
`ClassMetadataObjCInterop.descriptor(in:)` 读出描述符（arm64e 的指针签名在 `MachOImage.resolveOffset(at:)` 里剥掉），按描述符
在镜像里的偏移对上 indexer 的类型定义，建一张「Swift 键 ↔ ObjC 类名」双向表；Swift 键仍是 `mangleAsString(typeName.node)`，
与 sidebar 条目逐字一致。配对因此与 ObjC 名字长什么样无关：`_TtC…` 名字的类、带私有鉴别符的 private 类、用
`@objc(NSColorModel)` 改过名的类走同一条路。指向泛型描述符的类对象跳过，泛型类照旧不打标。Inspector 的 Relationships
面板把桥出子类还原成 Swift 类也查这张表（`RuntimeRelationshipsResolver.materializeObjCReference`），两个功能给不出不同的
答案。最初按名字配对（ObjC 运行时名 demangle 后只 remangle `Type` 节点当键）的做法，以及它为什么被换掉，见决策日志。
`@objc @implementation` 这一对不走这张表：它们的类对象没有 Swift 位，MachOSwiftSection 已把识别结果挂在 Swift 侧的
`extension` 上（`ExtensionDefinition.objcImplementation`，带 ObjC 类名）。

**标记**——`RuntimeObject.Properties` 新增 `isObjCClass`（`1 << 4`），打在「本镜像的 `__objc_classlist` 里有它的类对象」
的 Swift class 上，与 ObjC 侧的 `isSwiftClass` 对称，查的就是上面那张表。表里的 ObjC 类名读自类对象的 `class_ro_t`；
进程内的类多半已被运行时 realize，要经 `class_rw_t` 找回 `class_ro_t`。`isObjCImplementation` 的含义扩到 Swift 侧，同时打在那个 `extension` 上，一对条目带同一个标记。
打标在 `RuntimeSwiftSection` 的两个出口（`allObjects()` 与 `makeRuntimeObject(forMangledTypeName:)`），sidebar 与
Inspector 的关系行给出同一个答案。泛型类与特化出来的类没有静态类对象，不打标。

**角标**——`RuntimeObjectIcon.secondaryIcon(for:)` 加一支：`isObjCClass` 给橙色 `C`（ObjC 类的图标）；Swift 侧
`extension` 带 `isObjCImplementation` 时自动拿到粉色 `C`。规则是「角标画出另一面」：桥出类的另一面是普通 Swift 类 /
ObjC 类，所以两侧互为蓝、橙；`@implementation` 这一对两侧都用粉色标出这层关系。三处 cell ViewModel 本来就都走这个
函数，Sidebar、Inspector 的 Relationships 与 Specializations 同时生效。

**引擎**——新增 `RuntimeEngine.counterpart(for:) -> RuntimeObject?` 与 `CounterpartRequest`，登记进共享命令表，本地 XPC
service、远端进程与代理服务器自动可用。ObjC 桥出类 → Swift class（查上面那张表）；ObjC `@implementation` 类 → 那个
`extension`；Swift class → 表里的 ObjC 类名；`@implementation` 的 `extension` → 识别结果里的 ObjC 类名。另两个方向都经
同一镜像的 ObjC section 物化，返回的对象与 sidebar 列出的同一个 key，跳过去后 sidebar 能选中对应行。`RuntimeObject`
上加一个只看 kind 与标记的 `counterpartKind`，UI 靠它同步决定菜单项出不出现、标题写什么。

**菜单**——加在 `SidebarRuntimeObjectViewController.contextMenuItems(for:clickedRow:)`（基类，对象列表与书签列表都有），
排在「Open in New Tab」之后：ObjC 桥出类「Jump to Swift Class」、ObjC `@implementation` 类「Jump to Swift
Implementation」、Swift 一侧「Jump to Objective-C Class」。点击后经 ViewModel 新增的 Input 查引擎，再
`selectionRouter.trigger(.push(_:))`，与点击 sidebar 行等价（进历史、sidebar 选中目标行）。新 Input 带默认值
`.empty()`，其余构造 Input 的地方（UIKit、测试）不用改。菜单项按标记出现，点了查不到时经 `errorRelay` 弹提示。

**验证**——Core 锚定 macOS 26 的 AppKit：`NSGlassEffectView` 与其 `extension` 互跳；private 桥出类
（`FontPanelBIUSPopUpButton`，以及嵌套的 `NSScrollPocket.ElementContainerModel`）互跳；改过名的 `NSScrollPocket`
（`@objc(NSScrollPocket)`）互跳；AppKit 每个带 Swift 位的 ObjC 类（名字是不是 mangling 都算）都找得到另一面并能跳回
自己；`NSView`、Swift struct 返回 `nil`；两个出口的 `isObjCClass` 一致。Relationships 另加两条回归：`NSObject` 的子类里
要有桥出的 Swift 类；`NSView` 的子类里要有改过名的 `AppKit.NSScrollPocket`。Application 覆盖角标选择与 ViewModel 收到
请求后 push 出另一面、查不到时报错。

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
| 2026-09-27 | 配对改为顺着类对象里的类型描述符指针，取代上面「ObjC 运行时名 remangle 出的字符串直接当键」，等于回到本日志第二行的做法；remangle 那一段删掉，Relationships 查同一张表；在 Swift 接口里打印 `@objc(Name)` 不在本提案做 | 用户报告 AppKit 的 `NSColorModel` 两面对不上：ObjC 侧挂蓝色 `C`，跳转报 No counterpart，Swift 侧没有橙色 `C`。它是 `@objc(NSColorModel)` 改过名的 Swift 类，运行时名就是源码写的名字，不含模块与外层类型，从名字推不出 Swift 条目——即上面「改为按名字配对」一行记下的代价。编译器在类元数据的 flags 里置 `HasCustomObjCName`（`swift/lib/IRGen/GenMeta.cpp` 的 `getClassFlags`，`@objc(Name)` 与 `@_objcRuntimeName` 都置），只说明改过名，说明不了是哪个类；类对象里的描述符指针才是这层对应。用户问会不会影响 `@objc @implementation` 的判断：不会，那一对的类对象没有 Swift 位，走 `extension` 上的识别结果，不进这张表。用户：「分开来，比对只有 RV 要做，加 @objc(ClassName) 这个扔给 MachOSwiftSection-ObjCCustomName agent 做」，已交接；是否保留按名字配对那条路未表态，按推荐全部换成指针，一条路配所有桥出类。修复前 macOS 27 AppKit 有 74 个桥出类配不上；Relationships 里它们也整条丢失（`NSView` 的子类里没有 `NSScrollPocket`），ObjC 快照基线随之重录：`NSObject` 的子类 315 → 319、`NSCopying` 的遵循者 70 → 71，多出的都是 Foundation 的桥出类——三个改过名的（`_NSFileManagerBridge`、`_NSLocalizedStringResourceSwiftWrapper`、运行时名 `_NSKeyValueObservation` 的 `NSKeyValueObservation`），外加 `AttributeScopes._DefaultScopeRegistration`，它的运行时名是 mangling，按名字也没配上（原因未深究），其余各行逐字不变。弹窗里「名字不是 mangling、大概是 @objc 改名」那句说明删掉。验证（本地依赖、Xcode 27、macOS 27）：新增 `NSScrollPocket` 互跳、Relationships「A bridged subclass renamed with @objc(…) surfaces as its Swift class」，「每个桥出类都能往返」去掉只测 `_Tt` 名字的过滤——修复前这 3 条红、同批其余 16 条绿，修复后 Core 相关 7 个 suite 共 81 个测试里只剩快照 2 条红：ObjC 那条重录后绿，Swift 那条是上一行记过的 4 行 `__C.Decimal…` → `__C.NSDecimal…`，未动；Core 全量 523 个测试也只红这一条；Application 全部 233 个测试通过，Debug 设置文件 SHA 前后不变。同批文档：beta.5 changelog 删掉「改名类还不能配对」一句，ResolvedIssues 2026-09-24 纪要补「后续」一节 |
| 2026-09-30 | 落地编号 0026 | 已是 Implemented、实现在 `next` 上，按落地编号规则取 `origin/next` 与 `origin/main` 的全局最大值 0025 往后排；三份同批，按实现日期排序。 |

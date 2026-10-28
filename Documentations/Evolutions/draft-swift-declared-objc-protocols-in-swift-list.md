# Draft - Swift 列表列出 Swift 定义的 `@objc` 协议，并接上 ObjC 协议遵循

- **状态**: Accepted
- **创建日期**: 2026-10-28
- **最后更新**: 2026-10-28
- **实现分支 / PR**: `feature/swift-declared-objc-protocols-in-swift-list`（从 `next` 切，并回 `next`）
- **关联提案**: [0062](0062-swift-defined-objc-protocol-mark-and-filter.md)（ObjC 一侧的标记与过滤；本提案是它登记的暂缓后续项）；MachOSwiftSection 的 0079 `swift-declared-objc-protocols`（还原这些协议与遵循的上游实现）

## 摘要

Swift 源码定义的 `@objc` 协议没有 Swift protocol descriptor，Swift 列表一直看不到它们，只在 ObjC 列表里以 ObjC
协议的样子出现（0062 给它们加了 Swift 的 `P` 角标）；Swift 类对 ObjC 协议的遵循（含 `NSCopying` 这类导入的）在
Swift 接口里也全部丢失。MachOSwiftSection（下称 MSS）的提案 0079 已在它的 `next` 上把两者都还原出来。本提案把它
接进 RuntimeViewer：Swift 列表列出这些协议并打印声明与要求；类声明头部带上它采纳的 ObjC 协议；本镜像给别的模块的
类加的遵循列成 conformance 条目；同一个协议的 ObjC 与 Swift 两个条目互标角标、右键互相跳转，Filter Scope 加一行
同时选中两面。

## 方案

**依赖**

- MSS 的 pin 抬到它 `next` 上的 `07ed8467`（0079 的合并提交）。现在两个 workspace 的锁文件钉在 `d500d686`，
  Core、Packages、CommandLine 三个包的锁文件钉在更早的 `c5fe5756`。
- MachOObjCSection 一起抬到它 `next` 上的 `7b56479`（0.8.202 之后只多一个文档提交）：MSS 自 `cfccd785` 起要求
  `0.8.202..<0.9.0`，而 RuntimeViewer 对它钉的是 `branch: "next"`，根包的分支要求会盖过这个下限且不报错，不抬就
  一直停在 0.8.201（workspace）/ 0.8.200（三个包）。
- 只动这两条 pin，五份锁文件同改；其它 pin 不动，不跑 `UpdatePackagesScript.sh`——它把所有分支依赖一起推到最新，
  会混进无关的变化。`RuntimeViewerServer.xcodeproj` 自带的那份锁文件已落后多个版本（MSS `6ab2cd30`、
  MachOObjCSection 0.8.105），App 经 workspace 构建、读的是 workspace 的锁文件，它不动。

**Swift 列表**

- `RuntimeSwiftSection.allObjects()` 为 `indexer.objcProtocolDefinitions` 的每一项建一个条目。种类沿用
  `.swift(.type(.protocol))`，不新增种类：线上格式、按种类过滤、CLI 的类型过滤都照旧可用。名字是协议的 mangled
  name，与其它 Swift 协议同一规则；嵌套在类型里的（SE-0404，少见）也列在顶层，声明本身由 MSS 打在
  `extension 父类型 { … }` 里。
- 接口用 `SwiftDeclarationPrinter.printObjCProtocolDefinition(_:)` 打印：`@objc protocol` 头部（改过名的带
  `@objc(运行时名)`）、要求（Swift 签名取自本镜像里实现它的类，没有实现者的照 ClangImporter 的规则从 selector
  推出，再用 `@objc(selector)` 钉住），随后是默认实现。
- 这些协议的 protocol extension 以前单独列成「Swift Protocol Extension」条目。MSS 现在把它们挂到协议上当默认实现，
  所以 `allObjects()` 不再单独列它们，内容并进协议条目，与普通 Swift 协议的做法一致。指向旧条目的书签从此找不到
  对象，不做迁移：这种条目少，旧条目里也只有扩展成员、没有协议本身。
- 新位 `RuntimeObject.Properties.Flag.isObjCProtocol = 8`：MSS 把声明与本镜像的 ObjC 协议记录配上了
  （`objcRuntimeName != nil`）就带上。它是 `isSwiftProtocol` 的 Swift 面，与 `isObjCClass` 之于 `isSwiftClass`
  相同。用 `@objc(另一个名字)` 改了名、配不上记录的协议照样列出，只是不带这一位、没有跳转。

**类对 ObjC 协议的遵循**

- 本镜像的类：MSS 打印类声明时已把 `TypeDefinition.objcProtocolNames` 写进头部
  （`class DVTIconReference: NSObject, DVTResourceReference, NSCopying`），抬 pin 即得，RuntimeViewer 不改代码。
- 本镜像给别的模块的类加遵循的 extension（编译器把它记在 category 里，即 `indexer.objcCategoryConformances`）：
  用 `printObjCCategoryConformance(_:)` 打成 `extension NSDateFormatter: P {}`，按被扩展的类归档，与
  conformance extension 放在同一处——那个类已有 conformance 条目（`.swift(.conformance(.class))`）就并进去，没有就
  新建一个，名字与显示名照 conformance 条目的规则。

**两面互标与跳转**

- 角标：带 `isObjCProtocol` 的 Swift 条目画 ObjC 协议的图标，tooltip「Also Listed as an Objective-C Protocol」；
  ObjC 一侧带 `isSwiftProtocol` 的，tooltip 从「Defined in Swift」改成「Also Listed as a Swift Protocol」，照
  0062 当时的计划。
- `RuntimeObjectCounterpartKind` 加 `.swiftProtocol`、`.objcProtocol`，仍由种类加位推出；右键菜单
  「Jump to Swift Protocol」/「Jump to Objective-C Protocol」。配对表在 Swift section 里由 `objcProtocolDefinitions`
  建（运行时名 ↔ mangled name），与类的 `objcClassPairs` 同一做法。
- 副本：本镜像只是引用别的模块的 Swift `@objc` 协议时，ObjC 列表里也有它的记录、也带 `isSwiftProtocol`（0062 的
  决定），可本镜像的 Swift 列表没有它。从这种条目跳转时先找本镜像，找不到再按运行时名到其它已索引镜像的 Swift
  section 里找，于是定义它的镜像已索引时能跳过去；都找不到就照旧提示「No counterpart was found」。

**Filter Scope**

- 新增一行 `bridgedSwiftProtocol`，标题「Bridged Swift Protocol」，tooltip 照 Bridged Swift Class 的写法，排在它
  后面。`isSwiftProtocol` 改属 `[.bridgedSwiftProtocol, .swiftDefined]`，`isObjCProtocol` 属
  `[.bridgedSwiftProtocol]`，与类的两行同构。「Defined in Swift」一行不变，仍只作用于 ObjC 一侧。

**Find**

- 文本搜索自动覆盖新条目（语料按 `printedDefinitions(for:)` 打印）。Members 模式收录要求（名字取自要求的 Swift
  声明 node）与默认实现；成员地址只来自默认实现，要求没有符号。

**兼容**

- 没有新种类。位 8 是新的：旧 App 连上新 engine，照样看到新条目和它们的接口（由 engine 打印），只是没有角标和
  跳转；新 App 连旧 engine，只是没有这些条目。位 7 与它的 tooltip 自 0062 起只在 `next` 上、尚未发版，改 tooltip
  没有兼容问题。
- 存盘的 Find 语料按产出它的代码的 UUID 归档，新构建自然重建，不用处理。

**不做**

- Inspector 不专门处理 Swift 一侧的这类协议：Swift 的遵循表里没有 ObjC 协议的采纳者，关系与层级多半为空，要看就
  跳到 ObjC 一侧。
- CLI 与 MCP 的接口面不变：新条目对它们就是普通的 Swift 协议，打印走同一条 engine 路径；agent 插件不用改。
- MSS 自己登记的后续项（ABI 快照与 diff 收录这两类事实）。

**测试**

- Core：测试 bundle 里 0062 留下的两个 `@objc` 协议——`MangledSwiftObjCProtocolFixture`（运行时名 `_TtP…_`，
  配得上）与 `RenamedSwiftObjCProtocolFixture`（改成另一个名字，配不上）——断言 Swift 列表列出两者、只有前者带
  `isObjCProtocol`、接口含 `@objc protocol`，以及两个方向的跳转。再补四个夹具：`@objc(X) protocol X` 式的改名
  （配得上）、带 protocol extension 成员的协议（并进协议条目，不再单独列出）、采纳 `NSCopying` 的类（头部带上）、
  给 Foundation 的类加 `@objc` 协议遵循的 extension（新的 conformance 条目）。
- Packages：`RuntimeObjectScopeTests`（新位有行，新行选中两面）、角标与 tooltip、`counterpartKind` 的推导。

**文档**：本提案；`isSwiftProtocol` 文档注释里「Swift 列表还不列」一句，以及 `RuntimeObjectCounterpartKind` 与
`counterpart(for:)` 注释里只说「class」的地方，随代码改；落地时删掉提案索引「暂缓的后续项」里 0062 那一行。草案
《左栏改名》也要改几个 `Sidebar*` 文件，谁后落地谁按对方改。

### 落地步骤

每一步单独构建通过、相关测试通过后提交。

1. **抬 pin**：两条 pin、五份锁文件。Core 与 Packages 现有测试全过、App（Debug-arm64e）编译通过，先确认上游的
   变化本身没有弄坏什么。
2. **Swift 列表与打印**：列出 `objcProtocolDefinitions` 并打印，protocol extension 并入协议条目，category 遵循的
   条目，Find 的成员与成员地址；Core 测试。
3. **两面**：`isObjCProtocol`、counterpart 的两个新种类与配对表（含副本的跨镜像查找）、Filter Scope 新行、角标与
   tooltip、菜单标题；Core 与 Packages 测试，App 编译。
4. **收尾**：文档，按提案核对实际做出来的东西，完整验证。App 里的验收留给用户：DVTFoundation 的 Swift 列表列出
   11 个协议，`DVTIconReference` 的头部带 `DVTResourceReference, NSCopying`，两面互相跳转；
   `NFAImageDownloadObserver` 的副本在 DVTNFASupport 已索引时跳到那边。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-28 | Created as Draft，轻量档 | MSS 0079 已在它的 `next` 上输出 Swift 定义的 `@objc` 协议与类的 ObjC 协议遵循；用户要求接入，即 0062 登记的暂缓后续项 |
| 2026-10-28 | 不等 MSS 发版，直接抬 pin | RuntimeViewer 对 MSS 钉的是 `branch: "next"`，0062 写的「发版后接入」在这种钉法下就是「进它的 `next` 之后」 |
| 2026-10-28 | 沿用 `.swift(.type(.protocol))`，加位而不加种类 | 与 Swift 类的 `isObjCClass` 同构；新种类要改线上格式、图标与按种类的过滤，CLI 的类型过滤也得跟着改 |
| 2026-10-28 | 副本的跳转跨镜像查找 | 0062 决定副本也带 `isSwiftProtocol`；只在本镜像里找，副本的跳转必然落空，「Also Listed as a Swift Protocol」也就不成立 |
| 2026-10-28 | 状态 Draft → Accepted | 用户批准，开始实现 |

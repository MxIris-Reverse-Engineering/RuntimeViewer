# Draft - ObjC 列表标出 Swift 定义的协议，并能过滤掉 Swift 定义的类与协议

- **状态**: Accepted
- **创建日期**: 2026-10-28
- **最后更新**: 2026-10-28
- **所属愿景**: 无
- **实现分支 / PR**: `feature/swift-defined-objc-protocol-mark-and-filter`（从 `next` 切，并回 `next`）

## 摘要

Objective-C 列表里，Swift 定义的类带一个蓝色的 Swift `C` 角标；Swift 定义的 `@objc` 协议却和 ObjC
协议长得一样，尤其是用 `@objc(Name)` 改过名的，名字里看不出任何痕迹。Filter Scope 的 Bridged Swift Class
一行又同时作用于类的 ObjC 与 Swift 两面，设成 Exclude 会连 Swift 列表里的类一起藏掉，没法只把 ObjC
列表里这些「Swift 类型的 ObjC 面」去掉。本提案给 ObjC 协议加一个标志位和角标，并在 Filter Scope 加一行，
只作用于 ObjC 一侧由 Swift 定义的类和协议。

## 方案

**判据：本镜像 `__objc_protolist` 里这个名字的记录，任一份 `protocol_t.flags` 的 bit 0 为 1，或运行时名是
Swift 的旧式 mangling `_TtP…_`，就算 Swift 定义。** 标志位是主判据，改过名的协议只能靠它；名字只用来补
clang 生成的副本。

- 标志位是 Swift 的 `ProtocolDescriptorFlags::IsSwift`。Swift 编译器生成 `protocol_t` 时写
  `withSwift(!getProtocol()->hasClangNode())`（swift `lib/IRGen/GenClass.cpp` 的 `emitProtocol`）；clang 恒写 0
  （`clang/lib/CodeGen/CGObjCMac.cpp`）；objc4 的 `objc-runtime-new.h` 注明 bit 0–15 留给 Swift，运行时自己只用
  bit 29–31，dyld shared cache 给规范副本置的也是这两位。所以只判 `flags & 1`，不判相等。
- 这一位的含义是「记录出自 Swift 编译器」，即协议在 Swift 里定义——**可能定义在别的模块**：一个 Swift 镜像引用
  别的 Swift 模块定义的 `@objc` 协议时，也生成一份带这一位的弱定义副本（swift `lib/IRGen/GenObjC.cpp` 的
  `getObjCProtocolGlobalVars` 把它排进 `LazyObjCProtocolDefinitions`）。这种副本同样标：它也是 Swift 定义的协议，
  而 RuntimeViewer 本来就按镜像列出每一份副本。要判断「本镜像定义」得读 `__swift5_fieldmd` 里 kind 为
  `ObjCProtocol` 的记录，那是 MachOSwiftSection 输出 Swift 面时的事（见*不做的事*）。
- **clang 生成的副本这一位是 0**：ObjC 代码经 `-Swift.h` 用到 Swift 协议时，clang 在那个镜像里另生成一份，运行时
  名不变（`objc_runtime_name`），记录符号是 `_OBJC_PROTOCOL_$_<名字>`。名字规则把其中没改过名的补回来；还会漏的
  只有一种：别的模块里改过名的 Swift 协议，本镜像里只有 clang 的副本。
- **同名的记录可能不止一份**：Swift 的记录符号是 `_PROTOCOL_<名字>`、clang 的是 `_OBJC_PROTOCOL_$_<名字>`，
  链接器不会合并，同一镜像里两份都留在 `__objc_protolist`；而 `ObjCInterfaceIndexer` 按名字只保留最后一份
  （`ObjCInterfaceIndexer.swift` 的 `protocolByName[…] =`），留下哪份看顺序。所以判定不读 indexer 留下的那份，
  而是遍历本镜像 `__objc_protolist` 的全部记录，算出一组 Swift 定义的协议名。
- Xcode 自带的 DVTFoundation 实测：Swift 编译器生成的 11 条记录全为 1（含两个改过名的
  `DVTFieldReportDirectSourceProtocol`、`DVTFieldReportDiskWritePointQualitativeInsightProtocol`），clang 生成的
  97 条全为 0——其中 96 条是 ObjC 协议，1 条是 clang 为 DVTNFASupport 的 Swift 协议生成的副本
  `_TtP13DVTNFASupport24NFAImageDownloadObserver_`，正是名字规则要补的那种。

**Core**

- `RuntimeObject.Properties.Flag` 新增 `isSwiftProtocol = 7`（下一个位；位是线上格式），静态成员由这个 case 构造，
  文档注释写明上面的含义与局限。
- `RuntimeObjCSection` 建 section 时按上面的判据遍历一遍本镜像的 `__objc_protolist`，存下 Swift 定义的协议名；
  `allObjects()` 与 `makeRuntimeObject(forProtocolName:)` 都查这一组名字给 ObjC 协议带上它，保证侧栏与关系行
  一致。判据写成一个只吃「名字 + flags」的纯函数，方便单测。只用 MachOObjCSection 现有的
  `ObjCProtocolProtocol.flags`，上游不改。
- 旧版本的 engine 不会发这一位：新 App 连上去，只是协议没有角标、不受新行过滤，不出错。

**角标**

- `RuntimeObjectIcon.secondaryBadge(for:)` 加 `.swiftProtocol`，画 Swift 的 `P`，与类的蓝色 `C` 同一做法。
- tooltip 写「Defined in Swift」。Swift 一侧目前不列这类协议，所以不能照类的写法写「Also Listed as a Swift
  Protocol」；等 MachOSwiftSection 能输出它们、RuntimeViewer 接上之后再改。

**Filter Scope**

- `RuntimeObjectScope.Property` 新增 `swiftDefined`，按 `isSwiftClass` 与 `isSwiftProtocol` 过滤，排在
  `bridgedSwiftClass` 之后。标题「Defined in Swift」，tooltip「Objective-C classes and protocols defined in
  Swift」。设为 Exclude 就把 ObjC 列表里 Swift 定义的类与协议去掉，Swift 列表不受影响；设为 Only 则只看它们。
- `Bridged Swift Class` 一行不变，仍同时选中一个桥接类的两面（提案 0049 的决定）。于是 `isSwiftClass` 同属两行：
  `Property.init(filtering:)` 改为返回一组行的 `Property.rows(filtering:)`，仍是对 `Flag` 的穷尽 switch，
  「新加的位没有行就编译不过」的保证不变；各行的 `flags` 照旧由它反推。
- `@objc @implementation` 的类不算 Swift 定义：它在 ObjC 头文件里声明、只是实现写在 Swift 里，已有自己的一行。
- 行的显隐沿用现有规则：当前镜像里没有对象带这一行的任何一位，就不显示。

**测试**

- Core：判据的纯函数用合成的记录测——带位的改名协议、不带位的 `_TtP` 副本、普通 ObjC 协议、同名两份且只有一份
  带位（两种顺序都测）；再在当前系统里选一个带 Swift `@objc` 协议的镜像（落地时用 `swift-section objc` 选定），
  断言它的协议带 `isSwiftProtocol`、`NSCopying` 不带，`makeRuntimeObject(forProtocolName:)` 与 `allObjects()`
  给出同样的位。
- Packages：`RuntimeObjectScopeTests` 的映射断言改为「每一位至少属于一行」，补 `swiftDefined` 的位；新用例断言
  `swiftDefined` 设为 Exclude 时去掉带 `isSwiftClass` / `isSwiftProtocol` 的对象、保留只带 `isObjCClass` 的 Swift 类；
  角标选择补 `.swiftProtocol` 的用例。

**文档**：本提案；根 `AGENTS.md` Development Guidelines 第 9 条改成「一个位至少属于一行，可以属于多行」，并点名
`isSwiftClass`。术语表不加新词。

**不做的事**：Swift 一侧列出这类协议、类对 ObjC 协议的遵循，属于 MachOSwiftSection 的「输出 Swift 定义的
`@objc` 协议」（它的提案 `draft-swift-declared-objc-protocols`）；那边发版后，RuntimeViewer 另行接入，届时再给
Swift 面加对应的位并改 tooltip。

## 落地步骤

每一步单独构建通过、相关测试通过后提交。

1. **Filter Scope 的映射改成「一个位可属多行」**：`Property.init(filtering:)` 换成返回一组行的
   `Property.rows(filtering:)`，仍对 `Flag` 穷尽 switch；`flagsByProperty` 与 `RuntimeObjectScopeTests` 随之改，
   行为不变。验证：Packages 的 `RuntimeObjectScopeTests`。
2. **新位与新行**：Core 加 `Flag.isSwiftProtocol = 7`、静态成员、判据纯函数，`RuntimeObjCSection` 建 section 时
   算出 Swift 定义的协议名，`allObjects()` 与 `makeRuntimeObject(forProtocolName:)` 带上位；Packages 加
   `swiftDefined` 行（`isSwiftClass`、`isSwiftProtocol`），App 的 Filter Scope 补标题与 tooltip。验证：Core 的新
   测试、Packages 的 `RuntimeObjectScopeTests`、App 编译。
3. **角标**：`RuntimeObjectIcon` 加 `.swiftProtocol`（Swift 的 `P`，tooltip「Defined in Swift」）。验证：Packages
   测试与编译。
4. **收尾**：根 `AGENTS.md` 第 9 条改写；按提案核对实际做出来的东西；完整验证（Core 与 Packages 的相关套件、App
   编译）。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-28 | Created as Draft | ObjC 列表里 Swift 定义的协议无从辨认，Filter Scope 也没法只去掉 ObjC 一侧的 Swift 类型；用户要求补上标记与过滤 |
| 2026-10-28 | 判据用 `protocol_t.flags` 的 bit 0，不看名字 | 用 `@objc(Name)` 改过名的协议，名字里看不出 Swift；这一位由 Swift 编译器写入、clang 恒为 0，DVTFoundation 实测吻合 |
| 2026-10-28 | 引用别的 Swift 模块的协议时生成的弱副本也标 | 它同样是 Swift 定义的协议，RuntimeViewer 也本来按镜像列出每份副本；「本镜像定义」要读 `__swift5_fieldmd`，留给 MachOSwiftSection 输出 Swift 面时处理（该会话核实时指出副本这一点） |
| 2026-10-28 | 新增「Defined in Swift」一行，不拆 Bridged Swift Class | 后者同时作用于类的两面（0049），设为 Exclude 会连 Swift 列表里的类一起藏掉；新行只作用于 ObjC 一面，两行并存，代价是一个位可属两行 |
| 2026-10-28 | 判据加上运行时名 `_TtP…_`：标志位或名字任一成立即算（用户决定） | 只看标志位会漏掉 clang 生成的副本，DVTFoundation 里就有一条（MachOSwiftSection 那边核实时指出）；名字只补没改过名的副本，改过名的仍靠标志位 |
| 2026-10-28 | 同名记录任一份带位即算，不读 indexer 留下的那份 | Swift 与 clang 的记录符号名不同，同一镜像里两份并存，而 `ObjCInterfaceIndexer` 按名字只留最后一份，只看它会让结果取决于链接顺序 |
| 2026-10-28 | 补上「落地步骤」一节，拆成四步 | 精简提案原本没有落地步骤；按能各自构建通过拆分，第 1 步先把映射改成一个位可属多行、行为不变，新位与新行放在第 2 步一起落，否则加了位而没有行就编译不过 |
| 2026-10-28 | 状态 Draft → Accepted | 用户批准，开始实现 |

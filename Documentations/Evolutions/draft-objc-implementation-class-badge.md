# Draft - 给 @objc @implementation 实现的 ObjC 类加粉色角标

- **状态**: Accepted
- **创建日期**: 2026-09-22
- **最后更新**: 2026-09-22
- **所属愿景**: 无

## 摘要

Sidebar 里一个 Objective-C 类如果其实是 Swift 写的、只是以 ObjC 类的形式暴露出来（`class_t`
的 Swift 位置位，即 `isSwiftStable`），今天会在主图标旁边挂一个蓝色的 `C` 角标。SE-0436 的
`@objc @implementation` 是另一条路子：头文件仍是 ObjC 的，实现换成 Swift，而编译器产出的类是一个
**纯 ObjC 类**——Swift 位是清的，所以它永远拿不到那个蓝色角标，在列表里和普通 clang 类看起来一模一样。
MachOSwiftSection 的 `next` 分支新增了识别这类类的能力（`ObjCImplementationClasses`），本提案把它接进来，
给这类类挂一个**粉色 `C`** 角标。两种角标互斥：一个类的 class data 指针要么带 Swift 位、要么不带，
不可能同时是「Swift stable 类」和「`@objc @implementation` 类」。

## 方案

**数据侧**——`RuntimeObject.Properties` 增加一位 `isObjCImplementation`（`1 << 2`），与既有的
`isGeneric` / `isSpecialized` 同一套机制。不给 `RuntimeObjectKind` 加新 case，也不复用
`secondaryKind`：`secondaryKind` 的语义严格对应 class data 指针的 Swift 位，而给这个 enum 加 case 会牵动它的
`Comparable`（靠手写的 `level`）、`allCases`、CLI 的类型过滤和跨进程编码，代价与收益不成比例。
`Properties` 是 `OptionSet` + `@Default([])`，旧版本解码新负载不受影响。

**事实来源**——`SwiftInspection` 的 `ObjCImplementationClasses.all(in:)`（RuntimeViewerCore 已经
`@_spi(Internals) import SwiftInspection`）。它把 ObjC 侧的 `__objc_classlist` 与 Swift 侧的符号证据做
join，每个镜像构建一次并缓存。识别结果分两档：`definitive`（镜像导出了该类的 metadata accessor
`$sSo<Name>CMa`，或者该类扩展成员的 field-offset 符号 `…vpWvd`）与 `inferred`（符号被 strip，只剩
ivar 的 Swift 风格类型编码可依据）。**两档都标粉色角标**，界面上不做区分——被 strip 的用户自有 app
正是这个功能最该起作用的地方，而 `inferred` 档要求的编码形态是 clang 从不产出的。

**打标位置**——`RuntimeObjCSection`。它已经持有 `machO`，在 actor 上惰性构建一个类名 `Set<String>`，
`allObjects()`（sidebar 列表）与 `makeRuntimeObject(forClassName:)`（Inspector 的关系行）两条出口都用它。
这让 ObjC section 引用了 Swift 侧的模块，但这个索引本身就是 ObjC classlist 与 Swift 符号表的 join，
放在任何一侧都要跨一次界；放在出口处能保证两条路径给出同一个答案。

**图标侧**——`RuntimeObjectIcon` 增加粉色 `C`，以及一个统一的
`secondaryIcon(for object: RuntimeObject, size:)`，互斥关系（有 `isObjCImplementation` 就给粉色 `C`，
否则回落到 `secondaryKind` 映射）只写在这一个函数里。Sidebar、Inspector 的 Relationships 与
Specializations 三处 cell ViewModel 今天各自抄了一遍 `secondaryKind.map { icon(for:) }`，一并收拢到这个
入口，三个面板因此自动保持一致。

**不做**：`runtime-viewer-cli` 与 MCP 工具的输出模型不动；ObjC interface 的渲染文本不加注释。

**性能**——这个索引要额外走一遍镜像的 classlist（每个类读 `class_ro_t` 与 ivar 列表）和两遍符号扫描，
符号侧走的是 `SymbolIndexStore` 共享缓存，Swift 索引大概率已经建过。无条件启用，不加开关，
**这一轮也不测量**——用户明确要求把性能留到后面再谈。唯一的成本约束是惰性：索引在第一次列出
该镜像的对象时才构建，没被列过的镜像不付这笔钱。

**依赖**——上游能力在 MachOSwiftSection 的 `next` 分支上，而 RuntimeViewer 对它的 remote 依赖本来就写成
`branch: "next"`，所以不需要等 tag，只要把 `Package.resolved` 的 revision 推到含该提交的位置。

**验证**——`RuntimeObjCImplementationClassTests` 锚在 macOS 26 的 AppKit 上（`NSGlassEffectView`
是被这样重写的几十个类之一，`NSView` / `NSWindow` 是反例），覆盖 `allObjects()` 与
`makeRuntimeObject(forClassName:)` 两条出口，并断言被标记的对象 `secondaryKind` 一律为 `nil`——
互斥关系一旦不成立，图标那边就会悄悄用一个盖掉另一个。`RuntimeObjectIconTests` 钉住选择本身，
包括同时拿到两个标记时取粉色这条契约。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-22 | Created as Draft | 用户要求：ObjC 类若由 `@objc @implementation` 实现，用粉色 `C` 角标区别于纯 Swift 桥出类的蓝色 `C`，两者互斥 |
| 2026-09-22 | 用 `Properties` 新增一位，而不是给 `RuntimeObjectKind` 加 case 或复用 `secondaryKind` | 角标颜色由 kind 映射决定，加 case 会牵动 `Comparable` 的手写 `level`、`allCases`、CLI 类型过滤与跨进程编码；`Properties` 是 `OptionSet` + `@Default([])`，向后兼容 |
| 2026-09-22 | `definitive` 与 `inferred` 两档都标粉色，界面不区分 | 被 strip 的用户自有 app 正是该功能最该起作用之处；`inferred` 依据的 ivar 编码形态（`?` 或空）clang 从不产出 |
| 2026-09-22 | 三个 UI 面板统一走新的 `secondaryIcon(for:)` | 它们今天各自抄了一遍同样的映射，互斥规则只该有一处实现 |
| 2026-09-22 | 先无条件启用，用 signpost 实测，不预先加设置开关 | 索引成本未知，开关是要维护和落盘的长期负担，数据出来再定 |
| 2026-09-22 | 状态置为 Accepted，开始实现 | 用户「直接写就好了」 |
| 2026-09-22 | 这一轮不做性能测量 | 用户「性能问题后面再说」；索引改为惰性构建，未列出过对象的镜像不付成本 |

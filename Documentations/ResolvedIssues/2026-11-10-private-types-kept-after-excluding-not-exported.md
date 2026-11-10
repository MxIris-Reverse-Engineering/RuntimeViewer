# 2026-11-10 排除「未导出」之后，侧栏仍列出带 Private 标签的类型：没有本地符号的镜像里，扩展中的类型判不出导出与否

**调查日期：** 2026-11-10
**修复落地：** 2026-11-10。MachOSwiftSection 提案 0091（分支 `feature/export-verdict-without-local-symbols`），本仓库分支 `feature/export-verdict-without-local-symbols`；类型那一半随 MachOSwiftSection 的 pin 抬到含修复的 `next` 生效
**Severity：** Medium —— 筛选结果不对，不崩溃、不丢数据
**触发场景：** 侧栏 Filter Scope 把 Not Exported 设为 Exclude，浏览 macOS 27.2 的 AppKit

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 排除未导出之后，AppKit 的 `NSView._HitTestMap`、`NSGlassEffectContainerView.GlassGroup`、`NSGlassEffectView.BackingLayer` 等带 Private 标签的类型仍在列表里；私有的 Swift `@objc` 协议（`_TitleProviding` 等 5 个）也在 |
| **影响范围** | 没留本地符号的镜像：macOS 27.2 dyld shared cache 里的 AppKit（Foundation、SwiftUI、SwiftUICore 留着，不受影响），以及剥离过的 App。写在 ObjC 类扩展里的未导出类型全部判不出，AppKit 约 45 个，其中 33 个带 Private 标签，其余是 internal 的，没有标签、不显眼。私有 `@objc` 协议在任何镜像里都不判 |
| **根因** | 「Not Exported」标志只在 MachOSwiftSection 给出明确结论时打上。它先找描述符地址上的符号；找不到时把名字重新拼成符号名查导出表，但名字里只要有扩展上下文就放弃。AppKit 在缓存里只留导出、导入与 `_symbolic` 符号，而写在 ObjC 类里的类型，名字必然经过扩展上下文（`(extension in AppKit):__C.NSView`）。Swift 声明的 `@objc` 协议没有任何自己的符号，[0067](../Evolutions/0067-exported-declarations-filter.md) 的设计是判断不了就保留 |
| **Status** | **Fixed** —— MachOSwiftSection 只在带约束的扩展上放弃拼名字，私有与局部声明没有符号可判时判为未导出，私有 `@objc` 协议判为未导出；本仓库的 `@objc` 协议条目读这个结论，自己打印的类别 conformance 照同一规则过滤 |

---

## 现场

- 用 swift-section 0.24.0 跑 `interface --uses-system-dyld-shared-cache -n AppKit --exported-only --emit-private-source-files`：带私有鉴别器的声明仍有 25 个类型、32 个扩展留在输出里，Foundation、SwiftUI、SwiftUICore 都是 0。
- `swift-section dump --sections types` 里 AppKit 的私有成员符号 0 个，Foundation 153 个、SwiftUI 676 个：AppKit 在缓存里剥掉了本地符号。
- `dyld_info -exports` 列出的 AppKit 导出表里，经过扩展上下文的类型描述符（`Mn`）有 193 个；dump 里经过扩展上下文的类型有 238 个。差出来的约 45 个未导出类型，全部落在「判不出」那一档。

## 根因

1. MachOSwiftSection 的 `ExportStatus` 第一条腿找描述符地址上的符号，留着本地符号的镜像里总能答；AppKit 的未导出描述符上什么都没有。
2. 第二条腿把名字重新拼成符号名查导出表。为了不误删带约束扩展里的公开类型，它遇到任何扩展上下文都放弃（MachOSwiftSection 提案 0016）。但不带约束的扩展拼出来与编译器一致，这一刀砍宽了。
3. 名字里带私有鉴别器的声明，链接本来就不是 public，判不出时本可以判为未导出；`@objc` 协议则从来没有判过。
4. 侧栏的 Private 标签只看名字里有没有私有声明，不看导出与否，所以这批漏判在 Exclude 之后一眼就看得出来。

## 修复

- MachOSwiftSection（提案 0091）：
  - 第二条腿只在带约束的扩展上放弃。
  - 加第三条腿：前两条判不了时，私有或局部声明判为未导出，看名字或描述符外层的匿名上下文。
  - 私有 `@objc` 协议判为未导出；「只打印导出声明」时去掉它，也去掉只遵循它的 ObjC 类别。
- 本仓库：
  - `RuntimeSwiftSection` 构造 `@objc` 协议条目时读 `ObjCProtocolDefinition.exportStatus`，列表与按 mangled 名重建对象两处都读。
  - 它自己打印的类别 conformance（`PrintedDefinition.objcCategoryConformance`）改用 MachOSwiftSection 的 `SwiftInterfaceBuilder` 那条规则：类未导出，或者遵循的协议全是本镜像未导出的 `@objc` 协议，就在「只打印导出声明」时去掉。
  - MachOSwiftSection 的 pin 抬到含修复的 `next`。

## 复现与验证

- **复现**：swift-section 0.24.0 对 macOS 27.2 的 AppKit 跑 `interface --uses-system-dyld-shared-cache -n AppKit --exported-only --emit-private-source-files`，留下 25 个私有类型、32 个扩展。用 MachOSwiftSection `next`（`e7a3b984`，含修复）编出的 swift-section 再跑，带私有鉴别器的声明一个都不剩，`NSTextList` 遵循 `_TitleProviding` 的类别也不在了。
- **MachOSwiftSection 的回归测试**用现编夹具的三个变体（未剥离、只留 `_symbolic`、`strip -x`）：撤掉修复时 8 组测试变红，恢复后全绿；详见它的提案 0091。
- **本仓库的测试**（`SwiftExportedDeclarationsTests`）：
  - 原来断言私有 `@objc` 协议「不打标志」，改为断言打上，其余扩展、conformance 与非私有 `@objc` 协议条目仍不打。
  - 私有 `@objc` 协议加进「只打印导出声明时打印为空」那一组。
  - 新增一条：只遵循私有 `@objc` 协议的类别（测试 bundle 里 `ISO8601DateFormatter` 的类别）打印为空，遵循别的协议的类别（`ByteCountFormatter`）照旧。
- **先红后绿**：在 JH's MacBook Pro（macOS 27.2，Xcode 27.2）上，pin 抬上去、`RuntimeSwiftSection` 的改动撤掉时，「打标志」与「类别」两条变红，私有协议打印为空那条已经变绿（靠上游）；恢复后 `SwiftExportedDeclarationsTests`、`ObjCExportedDeclarationsTests`、`SwiftDeclaredObjCProtocolListTests`、`RuntimeInterfaceCorpusVisibilityTests` 共 35 个测试全过，`RuntimeViewerPackages` 用新的锁文件编译通过。
- **没做的**：没有启动 App 看侧栏与内容区；没有跑 Core 的全部测试，也没有编 App。

## 以前修过吗

没有。0067 加 Not Exported 时实测的四个镜像都留着本地符号，第一条腿全部命中，判不出的那几档没出现过；`@objc` 协议不判是 0067 有意的设计（「判断不了的不打」）。这次的不同在于：私有鉴别器本身就是判据。

## 教训

- 「实测都走第一条腿」只对留着本地符号的镜像成立。系统镜像剥不剥本地符号因框架而异（AppKit 剥，SwiftUI 不剥），抽样要包括剥过的。
- Private 标签与 Not Exported 来自两套独立的判断，前者只看名字。两者对不上时，先怀疑导出判定没有结论，而不是结论错了。

## 后续

- 用户手动做出的特化：私有声明来自泛型实参，描述符属于原型，沿用原型的结论，Exclude 时仍会带着 Private 标签留下，按设计如此。
- 私有 `@objc` 协议在 ObjC 一侧的条目（`_TtP…P33_…`）仍不打标志：MachOObjCSection 对协议不下结论。要做的话另开。

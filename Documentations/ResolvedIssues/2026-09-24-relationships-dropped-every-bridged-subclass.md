# 2026-09-24 Relationships 面板丢掉了全部桥出的 Swift 子类

**调查日期：** 2026-09-24
**修复落地：** 本日，分支 `next`，随提案 [draft-objc-swift-class-counterparts](../Evolutions/draft-objc-swift-class-counterparts.md) 一批
**Severity：** Medium —— 功能静默缺失：Inspector 的 Relationships 面板里，任何 ObjC 类的子类列表都看不到桥出的 Swift 子类，没有报错
**触发场景：** 查看任何有 Swift 子类的 ObjC 类（`NSObject`、`NSView`……）的 Relationships

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 子类列表里只有 ObjC 类；桥出的 Swift 子类（ObjC 类表里 `_TtC…` 那些）一个都不出现 |
| **影响范围** | 自提交 c3eb2735（引入 relationships API）起的所有版本，`main` 同样存在；与镜像、系统版本无关 |
| **根因** | 用 ObjC 运行时名找 Swift 类时，把整棵 demangle 结果拿去 remangle，得到的是符号而不是类型名，和 Swift 侧的键永远对不上 |
| **Status** | **Fixed** —— 只 remangle 其中的 `Type` 节点；这段收进 `RuntimeSwiftSection.makeRuntimeObject(forObjCRuntimeClassName:)`，Relationships 与 sidebar 的互相跳转共用 |

---

## 根因

`RuntimeRelationshipsResolver.materializeObjCReference` 把 ObjC 类表里带 Swift 位的类还原成 Swift 类：
`demangleAsNode(className, isType: false)` 再 `mangleAsString(node)`，拿结果去 `makeRuntimeObject(forMangledTypeName:)` 查。

- `_TtC6AppKit12IrisMaskView` 这种运行时名 demangle 出来是完整的**类型 mangling**：`Global(TypeMangling(Type(Class(…))))`
  （swift-demangling 的 `demangleObjCTypeName`），整棵 remangle 得到的是符号 `$s6AppKit12IrisMaskViewCD`。
- Swift 侧的键是 `mangleAsString(typeName.node)`，而 `typeName.node` 是 `SymbolicDemangler.demangleContext` 建出的 `Type(Class(…))`，
  remangle 得到 `6AppKit12IrisMaskViewC`。

查表是精确的字符串匹配，所以每一次都查不到，这个桥出类就被丢掉（注释里写的是「查不到时丢掉，而不是退回 ObjC kind」）。

## 为什么一直没发现

现有测试「Bridged class surfaces once with Swift kind in subclass list」只检查同一个类不会既以 Swift 又以 ObjC 身份出现——全部被
丢掉时这条照样成立。实现 sidebar 的互相跳转时，AppKit 的 183 个桥出类一个都配不上，才查到这里。

## 修复与验证

- `RuntimeSwiftSection.mangledTypeName(forObjCRuntimeClassName:)`：剥掉 `Global` / `TypeMangling`，只 remangle `Type` 节点。
- 新增回归测试「Bridged subclasses surface as their Swift classes」（`RelationshipsTests`）：`NSObject` 的子类里要有 Swift 类。
  `NSObject` 只走 ObjC 那一支，所以出现的 Swift 类都经过这条还原。修复前红（一个都没有），修复后绿。
- `RuntimeObjectCounterpartTests`：AppKit 的 183 个桥出类都能还原成 Swift 类并跳回来。
- `RelationshipsEquivalenceSnapshotTests` 的 ObjC 基线（`Snapshots/relationships-baseline.txt`）记的是修复前的输出，随之重录：
  `NSObject` 的子类 307 → 315、`NSCopying` 的遵循者 68 → 70，多出的 10 行全是 Foundation 里桥出的 Swift 类
  （`_BridgedURL`、`NSKeyValueObservation.Helper`、`__C.NSNotificationCenter.NotificationMessageKey` 等），其余各行与旧基线逐字相同。
  Swift 那份基线（`relationships-swift-baseline.txt`）另有 4 行 `__C.Decimal…` → `__C.NSDecimal…` 的差异，来自 MachOSwiftSection
  提案 0023（C 导入类型改用 ABI 名，9 月 9 日进入其 next），与本修复无关，未动。
- 同类写法（把 ObjC 运行时名当 Swift 键）全仓只此一处；`RuntimeEngine.objcReference(forSwiftMangledName:)` 只读节点里的标识符，
  不 remangle，不受影响。

private 类另有一层：它们的 Swift 侧名字要带私有鉴别符才对得上，这靠 MachOSwiftSection 从 `_symbolic` 符号还原鉴别符
（MachOSwiftSection 流水账 2026-09-24 两节）。

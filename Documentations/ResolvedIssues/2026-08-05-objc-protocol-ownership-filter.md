# 2026-08-05 协议归属过滤导致整个 image 的 ObjC 协议全部消失

**调查日期：** 2026-08-05
**修复落地：** 本日，见 `RuntimeViewerCore/Sources/RuntimeViewerCore/Indexing/RuntimeObjCInterfaceIndexer.swift`
**引入提交：** `8997bfea fix(core): drop imported protocols from per-image ObjC listing`（2026-06-14）
**Severity：** Major —— 受影响 image 的 ObjC 协议列表完全为空，且无任何报错提示
**触发场景：** 现场反馈 —— "UIKitCore image 看不到任何 ObjC 协议"

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | 打开 UIKitCore / Foundation 等 image，sidebar 里一个 ObjC 协议都没有；类、分类、C struct 均正常 |
| **影响范围** | 所有处于 dyld `upward` 依赖环中的 image。实测：UIKitCore、Foundation 全灭；AppKit、SwiftUI、CoreData、QuartzCore、WebKit、Photos 不受影响 |
| **根因** | 协议归属启发式假设"image 不会出现在自己的依赖闭包里"，而 `upward` 依赖的存在意义正是允许循环依赖 |
| **Status** | **Fixed** —— 移除归属过滤，`__objc_protolist` 全量列出 |

---

## 现象

`8997bfea` 之后，打开 UIKitCore 时协议一栏为空。同样地，Foundation 里看不到 `NSCoding` / `NSCopying` / `NSFastEnumeration`。不是"少了几个"，而是**一个都没有**——这个全有全无的形态本身就指向过滤条件恒真，而不是解析出错。

`RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RelationshipsTests.swift` 中已有的 Test 4（在 Foundation 里找 `NSCoding`）实际上从那时起就一直是失败的，只是没有被注意到。

---

## 根因

`8997bfea` 引入了 `ObjCProtocolOwnershipRegistry`，用来解决另一个真实问题：编译器会为**每一个**在编译期见过某 `@protocol` 声明的 image 都发射一份完整的 `protocol_t`，所以 `__objc_protolist` 里混着大量从依赖导入的协议（AppKit 里带着 `NSObject`、`CALayerDelegate`，SwiftUI 里带着 `NSWindowDelegate`……）。

它采用的归属规则是：

> 协议 P 被 image X **导入**（因而不列出），当且仅当 P 的某个其他携带者位于 X 的传递依赖闭包中。

代码里写下了这样一句关键假设：

```swift
// An image is never in its own dependency closure, so a protocol carried
// only by `machO` itself survives; one also carried by a dependency does not.
for carrierIndex in carrierIndices where closure.contains(carrierIndex) {
    return false
}
```

**这个假设不成立。** dyld 的 `upward` 依赖（`LC_LOAD_UPWARD_DYLIB`）存在的唯一目的就是表达循环依赖。用 `dyld_info -dependents` 实测：

```
UIKitCore  --upward--> PrintKitUI  --upward--> UIKitCore
UIKitCore  --upward--> ShareSheet  --upward--> UIKitCore
Foundation --------->  CoreFoundation --upward--> Foundation
```

于是 `dependencyClosure(UIKitCore)` 里包含 UIKitCore 自己的索引。而 UIKitCore 每一个协议的携带者列表里当然也有 UIKitCore 自己 —— 循环立刻成立，每个协议都被判成"从依赖导入的"，全部过滤掉。

两跳环实测结果（`dyld_info -dependents` 递归一层）：

| Image | 自环 |
|---|---|
| UIKitCore | ShareSheet, PrintKitUI |
| Foundation | CoreFoundation, CFNetwork, CoreAutoLayout, libswiftCore.dylib, libswift_StringProcessing.dylib |
| AppKit / SwiftUI / CoreData / QuartzCore / WebKit / AVFoundation / CoreImage / Photos | 无 |

AppKit 无自环，所以它一直是正常的 —— 这也解释了为什么问题看起来只出在少数几个框架上。

---

## 修复

**移除整个归属过滤**，`__objc_protolist` 全量列出：删除 `ObjCProtocolOwnershipRegistry`（约 120 行，含全 shared cache 扫描）与 `isProtocolOwnedByThisImage(_:)`，`prepare()` 里不再 `.filter`。

### 为什么不是修补启发式

考虑过两个更小的改法，都被否掉：

1. **把 image 自身从闭包里剔除**。能救回大部分，但环内其他成员仍在闭包中 —— 只要 ShareSheet / PrintKitUI（或 libswiftCore 之于 Foundation）也携带同一个协议，该协议仍会被错误判成导入。治标不治本。
2. **改用强连通分量（SCC）判定**：carrier 在闭包中**且**与当前 image 不同 SCC 才算导入。逻辑上是原规则的正确形式，但代价是环内框架（ShareSheet、PrintKitUI）会重新显示一大批 UIKit 协议，噪声换个地方冒出来。

根本问题是：**协议没有权威的"定义 image"**。类在自己 image 的 `__objc_classlist` 里恰好出现一次，协议没有这种性质。dyld shared cache 的协议哈希表确实记了一个 owning dylib index，但那是 cache 构建器按体积排序挑的（`CALayerDelegate` 会挑到 AppKit，正是想去掉的噪声）；objc runtime 的 canonical `Protocol *` 跟随同一个任意选择；dyld 加载顺序 / cache 枚举顺序也不是依赖拓扑序。以上均已实证否定。

所以任何归属判定都只能是启发式，而启发式出错的代价是**静默丢失** —— 用户看到的是"这个框架没有协议"，既没有报错也没有线索。相比之下，多列出一些从依赖导入的协议只是噪声，用户看得见、也能自己判断。**宁可多列，不可漏列。**

如果之后要重新做去噪，正确的方向是在 UI 层做可选的显示过滤（用户可开关、可见其被隐藏），而不是在索引层静默丢弃数据。

---

## 影响面

- 受影响 image 的协议恢复显示（UIKitCore、Foundation 等）。
- 未处于依赖环中的 image（AppKit、SwiftUI……）会重新列出从依赖导入的协议，回到 `8997bfea` 之前的行为：噪声变多，但没有数据丢失。
- 每个 image 的 `prepare()` 现在要为导入的协议多做一次 `info(in:)` 解码，索引变慢；同时省掉了首次索引时对整个 dyld shared cache 的一次性扫描（那是一笔不小的固定开销）。净影响未测量。

---

## 回归测试

`RuntimeViewerCore/Tests/RuntimeViewerCoreTests/ObjCProtocolListingTests.swift`：

- `imageInDependencyCycleListsProtocols` —— Foundation（处于 `upward` 环中）必须列出 `NSCoding` / `NSCopying` / `NSFastEnumeration`。修复前实测得到空集合 `[]`，四条断言全部失败。
- `imageOutsideDependencyCycleListsProtocols` —— AppKit（不在环中）必须列出 `NSWindowDelegate`。这是对照组，修复前就通过，用来保证修复没有把本来正确的路径改坏。

选 Foundation 而不是 UIKitCore 作为复现锚点：UIKitCore 是 Catalyst image，原生 macOS 测试进程加载不了；Foundation 有完全相同的自环形态，且在测试进程里天然可用。

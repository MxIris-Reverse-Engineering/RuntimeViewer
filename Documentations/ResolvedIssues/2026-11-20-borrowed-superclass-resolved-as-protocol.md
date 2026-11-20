# 2026-11-20 Mac Catalyst 类的 Hierarchy 把父类 `NSObject` 显示成 AppKit 里的 `NSObject` 协议

**调查日期：** 2026-11-20
**修复落地：** 本日，`next`
**Severity：** Medium —— Inspector 的 Hierarchy、Find 的 Ancestor Types 里有一级是错的：显示协议图标，所属镜像写成 AppKit，点进去打开的也是协议。其余数据不受影响
**触发场景：** 提案 0081（系统镜像的数据跨 engine 只存一份）落地后，在 My Mac (Mac Catalyst) 上选中一个父类是 `NSObject` 的类（例如 UIKitCore 的 `UIAnimator`）；当时 My Mac engine 没索引 libobjc，但索引过带 `NSObject` 协议副本的镜像（例如 AppKit）

---

## 一览

| 字段 | 内容 |
|---|---|
| **现象** | Hierarchy 第二级是 `NSObject`，图标是协议（Pr），副标题是 AppKit。`NSObject` 类定义在 libobjc，AppKit 只带着一份 `NSObject` 协议的副本 |
| **影响范围** | 2026-11-09 0081 落地起（`c425a08a`），v3.0.0-beta.9 之后，还没发版。所有借用系统镜像的 engine 都会遇到：Mac Catalyst、Load Frameworks 的独立实例，以及附加进程的文档。`main` 没有借用，不受影响 |
| **根因** | 借用方的服务进程不索引借来的镜像，父类一级只剩名字，于是交给归属 engine 按名字解析。归属 engine 取第一棵名字对得上的祖先树，不看它是类还是协议 |
| **Status** | **Fixed** —— 关系节点记下自己是类还是协议，跨 engine 解析时按名字和种类一起匹配；父类链在归属 engine 没索引定义镜像时按需建索引 |

---

## 根因

0081 之后，Mac Catalyst engine 借用 My Mac 的系统镜像，libobjc 也在其中，所以 Catalyst 服务进程不索引 libobjc。它给 `UIAnimator` 走父类链时，在自己的镜像里找不到 `NSObject`，只好记一个 unresolved 节点，节点上只有名字 `NSObject`。

`superclassChainAcrossOwners` 拿这个名字去问归属 engine（`ownersAncestorTrees(named:)`）。归属 engine 以 `^(?:NSObject)$` 查祖先树，然后取第一棵根节点名字对得上的树（`$0.root.isNamed(name)`），并不看根节点是类还是协议。ObjC 协议没有归属镜像：每个用到它的镜像都带一份副本，My Mac 索引过的 AppKit 就带着 `NSObject` 协议。My Mac 没索引 libobjc 时，能对上的只有这棵协议树，于是父类被换成了 AppKit 的 `NSObject` 协议。接下来对协议问父类链得到空链，Hierarchy 就停在这一级。即使 My Mac 索引了 libobjc，类和协议两棵树哪棵排在前面，也要看候选的排列顺序。

同一个按名字解析的函数还有两处调用，问题相同：

- **`refinedProtocolTreeAcrossOwners`**：unresolved 的协议节点可能被换成同名的类。
- **Find 的 Ancestor Types**（`RuntimeEngine+SpanningCommands.swift`）：祖先树里同时有父类节点和协议节点，替换结果又是只按名字存的，同名的类节点和协议节点会被换成同一棵树。实测纯 ObjC 类（如 `UIAnimator`、`XCTestExpectation`）会中招，因为它们的父类节点名就是裸的 `NSObject`。Swift 类不会：它的父类节点叫 `__C.NSObject`，名字带点，按限定名匹配，碰不到协议 `NSObject`。Hierarchy 走的是父类链，那里 Swift 类的父类名也是 `NSObject`，所以两种类都中招。

节点自己不记种类（`RuntimeRelationshipNode` 只有 `name`、`object`、`children`），所以光看节点分不出这个名字是类还是协议。

## 为什么测试没抓到

`SharedCacheSpanningTests` 里「借用方自己的类，父类链经归属 engine 解析」那条测试，事先让归属 engine 索引了 libobjc，类和协议两棵树都在，恰好类排在前面。没有哪条测试覆盖「归属 engine 只有协议副本、没有定义类的镜像」这个情形。现有的夹具也都是 Swift 类，而 Find 祖先树里的 Swift 类本来就碰不到这个问题（见上）。

## 修复

- `RuntimeRelationshipNode` 加可选字段 `typeKind`（`class` / `protocol`）。解析器建节点时写明：父类节点是 `class`，协议节点是 `protocol`；`init(object:children:)` 从对象推出。去掉了不带种类的 `init(name:object:children:)`，逼每个调用点写明种类；只换子节点的复制改用 `replacingChildren(_:)`，免得把种类丢掉。字段是可选的，旧 payload 不带它也能解码，新字段旧 payload 也会忽略。
- 按名字解析改为按「名字 + 种类」（`RuntimeRelationshipNode.UnresolvedType`）：`ownersAncestorTrees(for:)` 只认种类相同的根节点（`RuntimeObject.isType(_:)`），`unresolvedTypes` 与 `resolving` 以它为键。父类链一律按类找，协议树一律按协议找，节点写没写种类都一样，所以旧 payload 也不会出错；Find 的祖先树按节点写明的种类找，旧 payload 的节点不带种类，仍然只按名字。
- **父类链按需索引**：归属 engine 找不到这个类时，先问服务进程的运行时它定义在哪个镜像（`ImageNameOfObjectCommand`），再由那个镜像的归属 engine 建索引后重找，做法与 `interfaceAcrossOwners` 的第 2 步相同。于是 `UIAnimator` 的父类显示为 libobjc 的 `NSObject` 类。协议树和 Find 的祖先树不按需索引：协议到处都有副本，祖先树一次要解析的名字多，找不到就保留 unresolved 节点，只显示名字。

## 横向排查

- 跨 engine 按名字解析类型的入口只有 `ownersAncestorTrees` 一个，三个调用方都已改。
- `interfaceAcrossOwners` 按名字找引用时用的是 `objcReferencedObject` 造出的对象，对象本身带着种类（`.objc(.type(.class))` 或 `.protocol`），不受影响。
- `typeRelationships` 的 `externalRoots` 交给借用方的是完整的 `RuntimeObject`，带着种类，不受影响。
- `isNamedByQuery` 只用来给 Find 结果排序，同名的类和协议本来就都该列出，不受影响。

## 验证

`SharedCacheClassOrProtocolTests` 在测试进程里建一对 engine：归属 engine 只索引 libdispatch（带一份 `NSObject` 协议副本，体积小），不索引 libobjc；借用方的类来自两个不在 shared cache 里的镜像——本测试 bundle 里的一个 Swift `NSObject` 子类，以及测试进程加载的 XCTest 里的纯 ObjC 类 `XCTestExpectation`。三条测试：

- Swift 类的父类链：第一级是 libobjc 的 `NSObject` 类，而且归属 engine 为此索引了 libobjc。
- ObjC 类的父类链：同上，对应 `UIAnimator` 的情形。
- ObjC 类的 Ancestor Types：父类节点不是协议。

在 MacBook Pro（macOS 27.2、Xcode 27.2）上，只加测试、不带修复时三条都失败：两条父类链拿到的是 libdispatch 的 `NSObject` 协议，祖先树里的父类节点也成了协议。带上修复后三条通过。一开始祖先树那条用的是 Swift 夹具，修复前也能通过，查下去才发现 Swift 类在祖先树里的父类节点叫 `__C.NSObject`，于是改用 ObjC 类。`UnresolvedRelationshipNodeKindTests` 覆盖按种类替换、调用方指定的默认种类，以及旧 payload 不带 `typeKind` 时仍能解码。

同一次运行中，Core 里与关系树、shared cache、Inspector 层级和 Find 搜索相关的 25 个套件（135 个测试）全部通过；Packages 的 `InspectorHierarchyViewModelTests` 与 `ImageDisplayNameTests` 也通过。没有在 App 里人工点过 Mac Catalyst 窗口。

# Swift Object Tree Walkthrough

侧栏里一个镜像的 Swift 条目是怎么来的、点开一个条目看到的 interface 又是怎么拼出来的。两件事都在
`RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift`：`allObjects()`（`:206`）决定列出哪些节点、
每个节点挂哪些子节点，`interface(for:)`（`:341`）决定节点的文本。它们读的是 MachOSwiftSection 的
`SwiftDeclarationIndexer`（`Sources/Declaration/SwiftIndexing/SwiftDeclarationIndexer.swift`，下文简称「索引器」）建好的几张表。

行号指 2026-10-01 的 `next`。例子都是在 macOS 27 上实测得到的（`runtime-viewer-cli types` / `interface` 与
`swift-section dump`）。系统更新后名字和数量会变，规则不变。

## 1. 先看编译器：嵌套类型的父级记成什么

一个类型写在扩展里，二进制里它的父级不一定是那个扩展。编译器在
`swift/lib/IRGen/GenDecl.cpp` 里（父级 context descriptor 的 `ExtensionDecl` 分支）只在
`ExtensionDecl::isEquivalentToExtendedContext()` 成立时才把父级直接记成被扩展的类型，否则记成一个**扩展上下文**
（extension context descriptor）。成立的条件有三个（`swift/lib/AST/Decl.cpp:2246`）：

1. 扩展与类型属于**同一个定义模块**（`isInSameDefiningModule()`）；
2. 扩展**不带约束**；
3. 被扩展的不是存在类型。

另外，被扩展的如果是 ObjC 类，它没有 Swift 类型描述符，也一律记成扩展上下文。

第 1 条比较的是**编译时真正所属的模块**，并考虑 `@_originallyDefinedIn`。它不看二进制里名字上写的模块，所以从名字推断不出来。
SwiftUI 是现成的例子：SwiftUICore 以 `-module-abi-name SwiftUI` 编译（见 SDK 里 `SwiftUICore.swiftinterface` 的头部），
它的类型在二进制里都叫 `SwiftUI.X`。

```swift
// 同模块、不带约束：父级直接是 Foo，二进制里不留「写在扩展里」的痕迹
struct Foo {}
extension Foo { struct Bar {} }

// 带约束：扩展上下文
struct Box<T> {}
extension Box where T: Hashable { struct Bar {} }

// 别的模块的类型：扩展上下文。C 导入类型（模块 __C）属于这一类
extension AudioChannelLayout { struct UnsafePointer {} }        // libswiftCoreAudio

// 名字一样、模块不同：扩展上下文
// AccessibilityProperties 是 SwiftUICore 的内部类型，没有 @_originallyDefinedIn，
// 扩展写在 SwiftUI 模块里 → 比较 SwiftUI 与 SwiftUICore → 不同
extension SwiftUI.AccessibilityProperties {                       // SwiftUI 镜像
    struct TouchInfoKey {}
    struct RotorInfoKey {}
}

// 跨镜像却算同一模块：父级直接是 Color
// Color 定义在 SwiftUICore，但带 @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)，
// 与扩展所在的 SwiftUI 模块同名 → 视为同一定义模块
extension Color { struct EmphasizedColor {} }                     // SwiftUI 镜像，dump 里是 SwiftUI.Color.EmphasizedColor
```

在 `swift-section dump` 里，父级是扩展上下文的类型带 `(extension in 模块):` 前缀，例如
`struct (extension in SwiftUI):SwiftUI.AccessibilityProperties.TouchInfoKey`；`SwiftUI.Color.EmphasizedColor` 没有这个前缀。

父级直接是类型的那种情况，任何工具都恢复不出它原本写在扩展里：RuntimeViewer 和 `swift-section` 都把 `Bar` 打印在
`struct Foo { … }` 的 body 里。

## 2. 索引器把类型放进哪张表

| 表 | 内容 |
|---|---|
| `allTypeDefinitions` | 本镜像 `__swift5_types` 里的每个类型，嵌套的也算。C 导入类型只在 `showCImportedTypes` 为真时收（第 8 节） |
| `rootTypeDefinitions` | 没有父级的类型 |
| `TypeDefinition.typeChildren` / `.protocolChildren` | 父级是**本镜像里的类型**的嵌套类型 / 协议 |
| `typeExtensionDefinitions` | 键是 `ExtensionName`。内容有两种来源：一是成员扩展（按符号归组的方法、属性）；二是**合成扩展**，见下 |
| `protocolExtensionDefinitions` | 协议扩展 |
| `typeAliasExtensionDefinitions` | 对 typealias 的扩展，多数是 C typedef |
| `conformanceExtensionDefinitions` | 协议遵循 |

**合成扩展**：父级不是本镜像里的类型的嵌套类型，会被单独包成一个 `ExtensionDefinition`，放在它的 `.types` 里，按被扩展类型的键
存进 `typeExtensionDefinitions`。具体有三种来源：父级是扩展上下文、父级是别的镜像的类型（`EmphasizedColor` 这种）、父级只能通过符号找到。
代码在 `indexTypes()` 末尾处理 `unlinkedParentContextsByTypeName` 的那段。

嵌套协议只有一部分走这条路（`indexProtocols()`）：父级是扩展上下文时，同样生成合成扩展、放进 `.protocols`；父级是别的镜像的类型时，
**不**生成合成扩展，直接当成根协议。

**键怎么来**：合成扩展的键取自扩展上下文记录的「被扩展类型」。不带约束时，它与类型本身的键相同。实测 SwiftUI 里带约束的泛型扩展，
记的是把泛型参数绑到自身的形式：`OutlinePrimitive` 的合成扩展 `name` 是 `7SwiftUI16OutlinePrimitiveVyxq_q0_q1_q2_G`，
也就是 `OutlinePrimitive<A, B, C, D, E>`，与类型自己的 `7SwiftUI16OutlinePrimitiveV` 不相等。

## 3. `allObjects()`：列出哪些节点

```
根类型          rootTypeDefinitions             每个一个节点
根协议          rootProtocolDefinitions         每个一个节点
类型扩展        typeExtensionDefinitions        只列「键对应的类型不在本镜像 allTypeDefinitions 里」的
协议扩展        protocolExtensionDefinitions    只列「键对应的协议不在本镜像 allProtocolDefinitions 里」的
typealias 扩展  typeAliasExtensionDefinitions   全部列出
协议遵循        conformanceExtensionDefinitions 只列「键对应的类型不在本镜像 allTypeDefinitions 里」的
```

没列出来的扩展并没有丢，而是**并入**了被扩展的类型或协议的节点：
- 扩展的内容拼进那个节点的 interface（第 4 节）；
- 扩展里声明的类型、协议挂成那个节点的子节点（第 5 节）。

这样做是为了让本镜像定义的类型不会既出现一条「类型」、又出现一条「扩展」。

「在不在」只按**键是否相等**判断。所以同一个类型的扩展，可能一部分并入、一部分单独列出（第 7 节的 SwiftUI）。

## 4. 每个节点的 interface

节点对应什么记在 `InterfaceDefinitionName`（`:140`），`interface(for:)` 按它拼文本：

| 节点 | interface |
|---|---|
| 根类型 / 子类型 | 类型声明（`typeChildren`、`protocolChildren` 嵌在 body 里）+ 同键的 `typeExtensionDefinitions` + 同键的 `conformanceExtensionDefinitions` |
| 根协议 / 子协议 | 协议声明 + 默认实现扩展 + 同键的 `protocolExtensionDefinitions` |
| 扩展 / 协议遵循 / typealias 扩展 | 这一组 `ExtensionDefinition` 逐个打印 |
| 特化类型 | 特化后的 `TypeDefinition` |

所以被并入的合成扩展里的类型会出现在两处：
- 被扩展类型的 interface 里，以 `extension X { struct Y { … } }` 块的形式出现；
- 它自己的子节点，点开只显示 `Y` 本身。

## 5. 每个节点的子节点

类型节点（`makeRuntimeObject(for: TypeDefinition…)`，`:259`）：

```
children = typeChildren
         + 同键 typeExtensionDefinitions 里的 .types       ← 2026-10-01 补上
         + protocolChildren
         + 同键 typeExtensionDefinitions 里的 .protocols   ← 2026-10-01 补上
         + specializedChildren（用户做过的特化）
```

特化类型不取扩展里的类型，否则每个特化版本下都会重复一份；已经在 `typeChildren` 里的按 `typeName` 去重。

单独列出的扩展节点，子节点是这组扩展里全部的 `.types` 与 `.protocols`。

中间两项在 2026-10-01 之前没有。那时被并入的扩展里声明的类型，既不在扩展节点下（扩展节点被过滤掉了），也不在类型的子节点下，
侧栏里根本找不到。这种扩展只在「键对应的类型就在本镜像里」时才出现，实际上就是 C 导入类型；打开 C 导入类型（第 8 节）后，
它一下子变成了常见情况。回归测试：`SwiftIndexConfigurationTests` 的 `typesNestedInAnExtensionOfACImportedTypeAreListed`，
以及 `RuntimeObjectCounterpartTests` 的 `everyPairRoundTrips`。

## 6. 按镜像看例子

### libswiftObservation（小，纯 Swift）

一共 13 个 Swift 根节点：11 个 struct、1 个 enum、1 个 protocol，没有扩展节点。

- `Observation.ObservationRegistrar`（struct）：`Decodable`、`Encodable`、`Hashable`、`Equatable` 四个协议遵循都**并入**了，
  interface 里接在 struct 声明后面，侧栏没有单独的 conformance 节点。
- `Observation.Observable`（protocol）：根协议。
- `__C.os_unfair_lock_s`（struct）：C 导入类型。Observation 用它做锁，描述符在本镜像里，所以成了根节点。
- `Swift.Optional`、`Swift.Dictionary`：标准库类型也登记在本镜像的类型表里（`swift-section dump` 同样列出），所以也成了根节点。
  原因没有追查。

### libswiftCoreAudio（C 类型与合成扩展）

- `__C.AudioChannelLayout`（struct，C 导入）：CoreAudio 在 `extension AudioChannelLayout` 里声明了 `UnsafePointer`
  和 `UnsafeMutablePointer`。合成扩展的键与类型相同，于是并入，两个类型挂在 `__C.AudioChannelLayout` 下。interface 是：

  ```swift
  struct AudioChannelLayout { … }

  extension __C.AudioChannelLayout {
      struct UnsafeMutablePointer { … }
      struct UnsafePointer { … }
  }
  ```

  关掉 C 导入类型时，`__C.AudioChannelLayout` 不在索引里，这个扩展会单独列成一个 Struct Extension 节点
  「`__C.AudioChannelLayout`」，两个类型挂在扩展节点下。
- `Swift.UnsafeBufferPointer`、`Swift.UnsafeMutableBufferPointer`（Struct Extension）：扩展的是标准库类型，不在本镜像里，所以单独列出。
- `__C.CATapDescription`（Class Extension）：ObjC 类没有 Swift 描述符，扩展永远单独列出。

### AppKit（ObjC 类、C 类型、跨框架扩展都有）

Swift 根节点：319 个 class、266 个 struct、85 个 enum、104 个 protocol，其中 150 个是 `__C.` 类型。扩展与遵循节点：111 个 Class
Extension、17 个 Struct Extension、2 个 Enum Extension、5 个 Protocol Extension、2 个 TypeAlias Extension、22 个 Class
Conformance、8 个 Struct Conformance。

- **ObjC 类的扩展**：`__C.NSView` 同时有一个 Class Extension 节点和一个 Class Conformance 节点。扩展节点下挂着 AppKit 在
  `extension NSView` 里声明的类型，例如 `__C.NSView.LayoutRegion`；`LayoutRegion` 自己的 `AdaptivityAxis` 是它的普通子节点（`typeChildren`）。
- **C 类型的扩展，描述符在本镜像**：`__C.NSAnimationEffect`（enum）是根节点。`extension NSAnimationEffect` 里声明的
  `(__CompletionHandlerDelegate in _9E6F…)` 是它的子节点；这个类同时桥接到 ObjC，`everyPairRoundTrips` 就是靠它发现子节点丢失的。
  `__C.CGMutablePathRef`（CF 类型）下的 `Curve` 也是同一种情况。
- **C 类型的扩展，描述符不在本镜像**：`__C.NSBezelStyle`、`__C.NSControlEvents`、`__C.NSOpenGLGlobalOption` 是 Struct Extension 节点，
  因为 AppKit 的类型表里没有这几个 C 类型。
- **扩展别的框架的类型**：`Foundation.AttributeScopes`（Enum Extension）下挂着 `AppKitAttributes`；Struct Extension 里还有
  `SwiftUI.EnvironmentValues`、`Foundation.IndexPath`、`os.Logger`。
- **协议扩展**：`SwiftUI.View`、`Swift.Sequence`、`__C._NSViewInteraction`（ObjC 协议）都单独列出。
- **typealias 扩展**：`__C.NSAppKitVersion`、`__C.NSAccessibilityAttributeName`。
- **`@objc @implementation`**：`NSGlassEffectView` 在 ObjC 一侧是 Objective-C Class，在 Swift 一侧是一个 Class Extension
  （带 `isObjCImplementation`）外加一个 Class Conformance。
- **两侧重复的 C 结构体**：有 11 个 C 结构体在 ObjC 一侧是「C Struct」，在 Swift 一侧又是「Swift Struct `__C.…`」，例如
  `CGAffineTransform`、`CGRect`、`NSEdgeInsets`、`_NSRange`。

### SwiftUI（带约束的扩展、拆在两个镜像里的模块）

- **`SwiftUI.OutlinePrimitive`**：一个 Struct 节点加一个 Struct Extension 节点。
  - Struct 节点：`struct OutlinePrimitive<A, B, C, D, E> { enum Base … }`，后面接着并入的
    `extension SwiftUI.OutlinePrimitive where C: SwiftUI.View, …`（成员扩展）和 `: SwiftUI.View`（协议遵循）。
  - Extension 节点（`name` 为 `7SwiftUI16OutlinePrimitiveVyxq_q0_q1_q2_G`）：
    `extension SwiftUI.OutlinePrimitive where A: …, E: SwiftUI.View { struct ExpansionProjection { … } }`。
    合成扩展的键是泛型参数绑到自身的形式，与类型本身的键不相等，所以单独列出，`ExpansionProjection` 挂在这里。

  `SwiftUI.Tab`、`SwiftUI.Section`、`SwiftUI.TimelineView` 也都各有这样一个扩展节点。
- **`SwiftUI.AccessibilityProperties` / `SwiftUI.AccessibilityActivationPoint`**：在 SwiftUI 镜像里只有 Struct Extension 节点。
  类型本身定义在 SwiftUICore 镜像，扩展里的 `TouchInfoKey`、`InteractionKind` 等挂在扩展节点下。在 SwiftUICore 镜像里，这两个类型是普通的根节点。
- **`SwiftUI.Color.EmphasizedColor`**：父级直接是 SwiftUICore 里的 `Color`（第 1 节最后一例）。`Color` 不在 SwiftUI 镜像里，
  索引器为它生成合成扩展，结果与上一条一样：单独的扩展节点，类型挂在下面。`SwiftUI.EnvironmentValues` 下的 `ImmersionKey`
  等也是这样。
- **协议**：`SwiftUI.TableRowContent`、`SwiftUI.Commands` 是根协议，各自的协议扩展都并入了（interface 里接着几个
  `extension SwiftUI.TableRowContent { … }`）。`SwiftUI.View`、`Observation.Observable`、`Combine.ObservableObject` 是别的镜像的协议，
  所以成了 Protocol Extension 节点。
- **typealias 扩展**：`__C.NSPasteboardType`、`__C.NSNotificationName` 等 6 个。

## 7. 索引配置：`RuntimeSwiftSection.indexConfiguration`

`SwiftDeclarationIndexConfiguration(showCImportedTypes: true)`，定义在 `:84`。section 自己的 indexer 和
`RuntimeSwiftSectionFactory` 的汇总 indexer 创建时都传它；`RuntimeSwiftInterfaceIndexer` 的初始化器要求调用方显式传入，自己不做决定。

**它在 indexer 的生命周期内不能变。** 对象列表（`allObjectsCache`）、节点到定义名的映射（`interfaceDefinitionNameByObject`）、
关系反查表都只在 section 创建时建一次。2026-10-01 之前，`updateConfiguration(using:transformer:)` 每次生成 interface 时都会再套一份
索引配置。两份一旦不一致（indexer 按 `false` 建，请求时套 `true`），第一次请求就会重建索引并清空映射，而对象列表的缓存没有清。
此后这个镜像的每个 Swift 节点都抛 `invalidRuntimeObject`，又被 `RuntimeEngine._interface` 的 `try?` 吞掉，表现为侧栏里点了没反应。
运行时切换的那段代码已经删掉，回归测试是 `SwiftIndexConfigurationTests`。

打开 C 导入类型后能看到的变化：

- 每个镜像多出一批 `__C.` 根节点：AppKit 150 个、SwiftUI 96 个、Foundation 68 个。
- 针对这些 C 类型的扩展改为并入，扩展里的类型挂到 C 类型节点下（第 3、5 节）。
- 同一个 C 结构体在 ObjC、Swift 两侧各出现一次（AppKit 有 11 个），目前没有去重。

## 8. 已知的不一致

- **同一组 `where` 约束的扩展可能拆在两个节点里**：只有成员的那部分并入类型节点，带嵌套类型的那个合成扩展单独成一个节点
  （`OutlinePrimitive`）。原因是两者的键来源不同。
- **C 结构体两侧重复**，见上节。
- **标准库类型出现在别的镜像的根节点里**（libswiftObservation 的 `Swift.Optional`），原因未查。

## 9. 想确认某个镜像的实际结构时

- `runtime-viewer-cli types --image <镜像> --json`：列出根节点及其种类，不展开子节点。
- `runtime-viewer-cli interface <displayName 或 mangled name> --image <镜像>`：按名字查找时会深入子节点。
  同名的类型节点与扩展节点要用 `name`（mangled）区分，比如上面 `OutlinePrimitive` 的两个。
- `swift-section dump --uses-system-dyld-shared-cache -p <安装路径>`：带 `(extension in 模块):` 前缀的就是父级为扩展上下文的类型。
- 判断一个类型是不是定义在本镜像里：看它的声明出现在哪个镜像的 dump 里，不要看名字里的模块（SwiftUICore 的类型都叫 `SwiftUI.`）。

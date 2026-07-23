# Swift Jump to Definition 设计文档

## 背景与动机

Content 文本视图中,ObjC 类型 token 早已支持右键 **Jump to Definition** / **Open in New Tab**,以及 ⌘-click / ⌘⇧-click 跳转。Swift 类型 token 则完全不能跳转,原因有三:

1. **身份对不上**:link 的 `RuntimeObject` 用 **token 显示字符串**当 `name` 构造(`SemanticString+ThemeProfile.attributedString(for:runtimeObjectName:)`),而 Swift 对象在 section 内的查找 key 是 **mangled name**(`RuntimeSwiftSection.makeRuntimeObject` 用 `mangleAsString(typeName.node)`)。二者永不相等,点击必然 miss → 弹"未找到" HUD。
2. **无跨 image 回退**:`RuntimeEngine._interface` 的 `.swift` 分支只查文档自身 image,缺少 ObjC 分支那样按名字全局查找定义 image 的回退。
3. **选中不一致**:link 只打在叶子 token 上。右键类型名只选中类型名;右键模块名却因 NSTextView 的 smart word selection(把 `Module.Type` 点号链当一个词)整段选中——行为割裂。

## 目标

1. Swift 类型 token 可右键 Jump to Definition / Open in New Tab,⌘-click / ⌘⇧-click 生效。UI 层零改动(只认 `.link` 里的 `RuntimeObject`)。
2. link span 覆盖**完整限定名**:右键模块名、点号、类型名任意位置,选中整个 `Module.Type` 并跳到该类型。
3. bound generic **不整体成 span**:`Dictionary<String, Foo>` 的基类型与各泛型实参各自独立可跳;`<` `>` `,` 及 sugar 标点(`[` `]` `?`)不带 link。右键基类型跳**未特化的泛型定义**。

## 核心设计:span-identity 贯穿打印链路

在打印期,把类型引用的 **mangled name 作为 span 身份**盖到 `SemanticString` 的每个 atomic component 上;RuntimeViewer 渲染时按身份构造 `.link`,相邻同身份的 component 因 `RuntimeObject` 相等在 `NSAttributedString` 中自动合并成一个 link run;点击时用 mangled name 经既有跨 image 索引解析定义。

```
SwiftPrinting TypeNodePrinter / BoundGenericNodePrintable        (MachOSwiftSection)
  nominal 节点 dispatch 时 push/pop "type reference scope"(携带 Node)
    ↓ NodePrinterTarget 钩子(协议定义在 swift-demangling)
SemanticString 维护 identifier 栈,append 时按栈顶盖章               (swift-semantic-string)
  component.identifier = mangleAsString(nominalNode)              (SwiftDeclarationRendering 的 conformance 实现钩子)
    ↓ RuntimeObjectInterface.interfaceString(Codable,跨 XPC/TCP)
attributedString():identifier 分组 → .link = RuntimeObject(name: identifier, ...)   (RuntimeViewerApplication)
    ↓ 点击
RuntimeEngine._interface .swift 分支:文档 image miss → factory mangledID 索引跨 image 回退  (RuntimeViewerCore)
```

### scope 栈规则

- 打印一个 nominal 引用(`.class` / `.structure` / `.enum` / `.protocol` / `.typeAlias`)时,push 该 nominal 的完整 Node;打印其完整限定名(模块、点号、类型名)期间所有 write 盖同一身份。
- 打印 bound generic(`.boundGenericClass` 等)时,push `nil` 作为 **barrier**:尖括号、逗号、sugar 标点归属于"无类型引用";基类型与各实参在递归进入各自 nominal case 时 push 自己的 scope。
- 栈"内层优先":嵌套 `Module.Outer.Inner` 打印 `Outer` 时栈顶是 Outer、打印 `Inner` 时是 Inner,故 `Module.Outer` 段跳 Outer、`.Inner` 段跳 Inner。

### memoization 安全性

两层 printer(swift-demangling 的 `NodePrinter`、MachOSwiftSection 的 `InterfaceNodePrintable`)都用 `swap`/`append` 缓存共享子树的渲染 fragment。push/pop 发生在 `dispatchPrintName` 内(即 `swap` 之后),fragment 自带完整且平衡的盖章;barrier 保证盖章只取决于子树本身,与"缓存按 Node 为 key"的假设一致。`append(SemanticString)` 直接搬运已盖章的 component,不重复盖章。

## 各仓库改动

### swift-demangling
- `NodePrinterTarget` 协议新增 `pushTypeReferenceScope(_ node: Node?)` / `popTypeReferenceScope()`,带默认空实现(`String` 等现有 target 零改动)。
- `NodePrinter.dispatchPrintName` 的 nominal case 与 boundGeneric case 各加 push/defer pop,覆盖 `printSemantic` 残留路径(extension header 协议名等)。

### swift-semantic-string
- `AtomicComponent` 新增 `identifier: String?`(默认 nil),手写 `Codable`(`encodeIfPresent` / `decodeIfPresent`,向后兼容旧 payload),覆写 `buildComponents()` 保留 `identifier`。
- `SemanticString` 新增 transient `identifierScopeStack` + `pushIdentifierScope` / `popIdentifierScope`;`append(_:type:)` 按栈顶盖章。栈不参与 `==` / `hash` / `Codable`。

### MachOSwiftSection
- SwiftPrinting `TypeNodePrintable.printNameInType` 的 nominal case push nominal Node;`BoundGenericNodePrintable.printNameInBoundGeneric` push barrier。
- SwiftDeclarationRendering `SemanticString: NodePrinterTarget` 实现两个钩子:`pushTypeReferenceScope` 对 Node `mangleAsString` 得身份(失败降级为 nil barrier),转调 `pushIdentifierScope`。mangled 格式与 `candidateIDMapping()` / `typeName(forMangledName:)` 天然一致。

### RuntimeViewerCore
- `RuntimeSwiftInterfaceIndexer`:`prepare()` 增建 `protocolNameByMangledName`,新增 `protocolName(forMangledName:)`(镜像 `typeName(forMangledName:)`,跨 sub-indexer fan-out)。
- `RuntimeSwiftSection`:新增 `makeRuntimeObject(forMangledProtocolName:)` 与 `protocolCandidateIDMapping()`。
- `RuntimeSwiftSectionFactory`:新增独立的 `indexedProtocolByCandidateID` + `indexedProtocol(forCandidateID:)`(与类型表分离,避免污染 specialization 候选);register/remove 生命周期同步维护。
- `RuntimeEngine._interface` 的 `.swift` 分支:文档 image 命中优先返回;miss 后调 `resolveSwiftReferenceInterface(mangledName:options:)` 三段回退:
  1. 跨 image Swift 类型(`indexedType`)。
  2. 跨 image Swift 协议(`indexedProtocol`)。
  3. ObjC-imported(`__C` module):demangle → 提取 identifier → 路由 ObjC 分支,实现 Swift → ObjC 跨语言跳转。
  每段都用定义 section 重建权威 `RuntimeObject`(正确的 imagePath / displayName / kind),使导航 push 落在真实 sidebar/tab 条目上。

### RuntimeViewerApplication
- `SemanticString+ThemeProfile.attributedString(for:runtimeObjectName:)`:`.swift` 文档走 identifier 驱动——`resolveSwiftLinkTargets` 预扫一遍,按 identifier 分组,取组内首个 `.type(kind,_)` token 经既有 `resolveTargetKind` 的 swift 映射决定 kind(无 `.type` token 的组——如 typealias 引用——不建 link),`name = identifier(mangled)`、`displayName = 组内拼接串`;同一 identifier 复用同一 `RuntimeObject` 实例。`.c` / `.objc` 文档保持原字符串驱动逻辑。

## 边界情况

| 场景 | 行为 |
|---|---|
| `Swift.Array` 任意位置右键 | 选中整个 `Swift.Array`,跳未特化 `Array` |
| `Dictionary<String, Foo>` | 基类型与实参各自独立 link;`<` `>` `,` 无 link |
| sugar `[Int]` / `Int?` | `Int` 可跳;`[` `]` `?` 无 link |
| 嵌套 `Module.Outer.Inner` | `Module.Outer` 段跳 Outer,`.Inner` 段跳 Inner |
| typealias 引用 | 无 link(identifier token 语义类型为 `.standard`) |
| ObjC-imported(NSObject 等) | 经 `__C` 回退跳 ObjC 定义 |
| 目标 image 未索引 | "未找到" HUD(既有行为) |
| 声明头自身名字(`struct Foo` 的 `Foo`) | 不走 TypeNodePrinter,无 identifier,无 link |

## 风险与降级

- `AtomicComponent` 加字段影响 `==` / `hash`:同一输入两次打印产出相同 identifier,确定性不变;interface 缓存与 SwiftDiffing 不受影响。
- 某条打印路径若漏 push(如手写的 `Swift.AnyObject`):该 token 无 identifier → 无 link,行为等同现状,属安全降级而非错误。
- mangled key 对齐由既有 relationships 跳转路径(同样 `makeRuntimeObject(forMangledTypeName:)` + `interface(for:)`)背书。

# 0003 - 泛型类型特化

- **状态**: Draft
- **作者**: JH
- **日期**: 2026-05-08
- **最后更新**: 2026-05-08

## 摘要

为泛型 Swift 类型(`class` / `struct` / `enum` 凡带 `<T, U>` 者)新增**用户驱动的特化(Generic Specialization)** 工作流:用户在 Inspector 选择具体的候选类型替换每个泛型参数,触发后 MachOSwiftSection 内部以已选 `SpecializationSelection` 注册一份"已特化的 Definition",RuntimeViewer 把它作为该泛型 RuntimeObject 的子节点暴露在 sidebar 中。点击该子节点即在 Content 区域看到泛型参数被替换为具体类型的源码,以及来自运行时 metadata 的 field offset / size / value witness 等原本无法静态获取的信息。

特化历史只在当前 Document 内记忆,关闭文档即丢。

## 动机

Runtime Viewer 当前对**泛型 Swift 类型**的展示有一个明显的天花板:

- 泛型类型的 metadata 在二进制中没有具象化(generic context 只有占位 parameter `A`/`B`/...),因此基于 metadata 的字段 —— `printFieldOffset`、`printTypeLayout`、`printEnumLayout` —— 在泛型类型上**全部为空或不可计算**。
- `RuntimeObject.Properties.isGeneric` 已经在 `RuntimeSwiftSection.makeRuntimeObject(for:isChild:)` 第 451 行被打上,但目前没有任何 UI 利用这个标记;Inspector 也只对 `.swift(.type(.class))` 路由到 `InspectorClassViewController` 展示类层次。
- 上游 `MachOSwiftSection` 已完成 `GenericSpecializer` 的核心算法(`makeRequest` / `validate` / `runtimePreflight` / `specialize`,详见该仓库 `Sources/SwiftInterface/GenericSpecializer/`),能把 `(typeDescriptor, selection) → SpecializationResult` 的全链路打通,**但还没有把"特化结果"作为可被 SwiftInterfacePrinter 重新渲染的一等 Definition 持久化下来**。

目标:

- 让用户能对任意 `isGeneric` 的 Swift 类型选定具体类型组合并触发特化。
- 特化后展示同一份 SwiftInterface 渲染管道,但泛型参数被替换为具体类型,且 metadata-driven 的字段(field offset 等)填上真实数值。
- 特化历史在 Document 生命周期内可重复访问 / 切换。
- 不污染 Sidebar 的索引主路径,不改 `RuntimeObject` 的核心序列化字段。

### 非目标

- **不**实现源码层面的字符串替换 —— 替换语义由 MachOSwiftSection 的渲染管道承担。
- **不**支持嵌套递归特化的 UI(`SpecializationSelection.Argument.specialized`)—— v1 仅支持 `.candidate` / `.metatype` 两种简单 argument。
- **不**跨 Document / 跨会话持久化用户做过的特化组合(关闭文档丢)。
- **不**支持 TypePack / Value generics(`GenericSpecializer.makeRequest` 已经显式拒绝这两种,UI 上以禁用 + 解释展示)。
- **不**支持远程 source(XPC / directTCP / Bonjour)的特化 —— `GenericSpecializer.specialize` 要求 `MachO == MachOImage` 即镜像必须在当前进程内加载,远程源 v1 在 UI 上展示"该 source 不支持特化"占位。
- **不**承担 MachOSwiftSection 内部的 specialized-Definition 存储 / 渲染实现 —— 这是上游工作(详见"前置依赖"章节)。

## 提议方案

### 前置依赖:MachOSwiftSection 上游 API 契约

本提案在 RuntimeViewer 这边的所有改动都以 MachOSwiftSection 提供以下 API 为前提。**该上游工作必须先完成**;在它就绪之前,RuntimeViewer 这一侧不动代码,本提案保持 Draft 状态。

约定的 API surface(命名待上游 finalize,这里给出语义和最小信号):

```swift
// === SwiftInterfaceIndexer / TypeDefinition ===

extension TypeDefinition {
    /// 该泛型类型已注册的特化版本。非泛型类型恒为 []。
    /// 与 `typeChildren`(嵌套类型)语义平行 —— 一层挂载,不再递归嵌套。
    public internal(set) var specializedTypeDefinitions: [TypeDefinition] { get }

    /// 标识当前 Definition 是否是某个泛型 Definition 的特化版本。
    /// `nil` 表示这是原始(generic / non-generic)Definition。
    public var specializationOrigin: SpecializationOrigin? { get }
}

public struct SpecializationOrigin: Sendable {
    /// 派生自的原始泛型 TypeDefinition(retained)。
    public let baseTypeDefinition: TypeDefinition
    /// 用于派生的用户选择。
    public let selection: SpecializationSelection
    /// 来自 specialize() 的运行时结果,用于驱动 metadata-driven 字段。
    public let result: SpecializationResult
}

// === SwiftInterfaceIndexer ===

extension SwiftInterfaceIndexer where MachO == MachOImage {
    /// 注册一份新的特化 Definition 到 indexer,挂载到 baseTypeDefinition.specializedTypeDefinitions 末尾。
    /// 内部调用 GenericSpecializer.specialize(_:with:) 拿到 SpecializationResult,
    /// 然后构造一份"携带 specializationOrigin"的 TypeDefinition 注入。
    /// 重复 selection 直接返回已存在的 Definition(去重)。
    @discardableResult
    public func registerSpecialization(
        of baseTypeDefinition: TypeDefinition,
        with selection: SpecializationSelection
    ) async throws -> TypeDefinition

    /// 移除一份特化 Definition(可选,v1 不一定使用)。
    public func unregisterSpecialization(_ specialized: TypeDefinition)
}

// === SwiftInterfacePrinter ===

// printer.printTypeDefinition(_:) 检测到入参的 specializationOrigin != nil 时:
//   - 渲染签名时把 generic parameter token 替换为 selection 中对应的具体 TypeName
//   - 渲染字段时通过 SpecializationResult 拿到 metadata,填 field offset / size 等
//   - 不需要新 API,调用方仍走现有 `printer.printTypeDefinition(_:)`
```

**关键不变量(由上游保证)**:

1. `specializedTypeDefinitions` 不参与 indexer 的全量重建 —— 它是用户态注册的副产物,`reload` 不会清掉。
2. 特化 Definition 的 `typeName` 携带选定参数的 mangling(例如 `Box<Int, String>`),保证 `RuntimeObject.name` 唯一。
3. 同一 baseTypeDefinition 上重复 `registerSpecialization(of:with:)` 同一 selection 是幂等的,返回同一份 Definition。
4. printer 对特化 Definition 渲染时,所有现有 `SwiftGenerationOptions`(printFieldOffset / printTypeLayout / printEnumLayout / synthesizeOpaqueType ...)继续生效,差别只在"参数实际可解了"。

### 整体数据流

```
┌──────────────────────────────────────────────────────────────────────┐
│  RuntimeViewerUsingAppKit                                            │
│                                                                      │
│   InspectorSwiftTypeViewController (拓宽自 InspectorClassViewController)
│     ├── NSSegmentedControl: [Hierarchy | Specialization]             │
│     ├── InspectorClassHierarchyView    (复用,仅 class 显示)         │
│     └── InspectorSpecializationView    (新增)                        │
│           └── StatefulOutlineView                                    │
│               ├── Parameter row: name / requirements / candidate count
│               └── Candidate child row: typeName / source / isGeneric │
│           └── Specialize 按钮                                        │
└──────────────────────────────────────────────────────────────────────┘
                            ↕ RxSwift / @Observed
┌──────────────────────────────────────────────────────────────────────┐
│  RuntimeViewerApplication                                            │
│                                                                      │
│   InspectorSpecializationViewModel (新增,ViewModel<InspectorRoute>) │
│     · @Observed request: SpecializationRequest?                      │
│     · @Observed selection: SpecializationSelection                   │
│     · transform.input: parameterArgumentChanged / specializeClicked  │
│     · transform.output: nodes(Driver) / canSpecialize / errorAlerts  │
│                                                                      │
│   DocumentState (改动)                                               │
│     + @Observed specializationHistory:                               │
│           [RuntimeObject.ID: [SpecializationSelection]]              │
└──────────────────────────────────────────────────────────────────────┘
                            ↕ async / await
┌──────────────────────────────────────────────────────────────────────┐
│  RuntimeViewerCore                                                   │
│                                                                      │
│   RuntimeEngine (改动)                                               │
│     + func specializationRequest(for: RuntimeObject)                 │
│           async throws -> SpecializationRequest                      │
│     + func specialize(_: RuntimeObject,                              │
│                       with: SpecializationSelection)                 │
│           async throws -> RuntimeObject  // 新派生的子 RuntimeObject │
│                                                                      │
│   RuntimeSwiftSection (actor,改动)                                  │
│     + lazy var specializer: GenericSpecializer<MachOImage>           │
│     + func specializationRequest(for:) async throws → request        │
│     + func specialize(for:with:) async throws → 新子 RuntimeObject   │
│     + makeRuntimeObject(for typeDefinition:) 增加将                  │
│         typeDefinition.specializedTypeDefinitions 映射为 children    │
│                                                                      │
│   RuntimeObject (改动)                                               │
│     + Properties.isSpecialized                                       │
└──────────────────────────────────────────────────────────────────────┘
                            ↕ MachOSwiftSection 内部
                       (specializedTypeDefinitions /
                        registerSpecialization / printer)
```

### 组件

#### `RuntimeObject.Properties.isSpecialized`(新增 OptionSet 位)

`RuntimeObject` 是 `@Codable` 结构,新增一个 `Properties` 位即可,无破坏性。映射规则在 `RuntimeSwiftSection.makeRuntimeObject(for typeDefinition:isChild:)`:

```swift
// 现状(第 451 行附近)
if typeDefinition.type.contextDescriptorWrapper.contextDescriptor.layout.flags.isGeneric {
    properties.insert(.isGeneric)
}

// 新增
if typeDefinition.specializationOrigin != nil {
    properties.insert(.isSpecialized)
}

// 新增:把已注册的特化版本作为 children 暴露(类似已有的 typeChildren 路径)
let specializedChildren = try typeDefinition.specializedTypeDefinitions.map {
    try makeRuntimeObject(for: $0, isChild: true)
}
let allChildren = typeChildren + protocolChildren + specializedChildren
```

#### `RuntimeSwiftSection` 扩展(actor)

```swift
private lazy var specializer = GenericSpecializer(indexer: indexer)

func specializationRequest(for object: RuntimeObject) async throws -> SpecializationRequest {
    let typeDefinition = try requireTypeDefinition(for: object)
    return try specializer.makeRequest(for: typeDefinition.type.typeContextDescriptorWrapper)
}

func specialize(
    for object: RuntimeObject,
    with selection: SpecializationSelection
) async throws -> RuntimeObject {
    let baseTypeDefinition = try requireTypeDefinition(for: object)
    // 上游 API:注册新 Definition 并把它挂到 baseTypeDefinition.specializedTypeDefinitions
    let specializedDefinition = try await indexer.registerSpecialization(
        of: baseTypeDefinition,
        with: selection
    )
    let runtimeObject = try makeRuntimeObject(for: specializedDefinition, isChild: true)
    // 触发 sidebar 刷新通过 RuntimeEngine.reloadData() 走原有路径
    return runtimeObject
}

private func requireTypeDefinition(for object: RuntimeObject) throws -> TypeDefinition {
    guard let definitionName = nameToInterfaceDefinitionName[object],
          let typeName = definitionName.typeName else { throw Error.invalidRuntimeObject }
    if let root = indexer.rootTypeDefinitions[typeName] { return root }
    if let any = indexer.allTypeDefinitions[typeName] { return any }
    throw Error.invalidRuntimeObject
}
```

`interface(for:)` **完全不变**:它根据 `nameToInterfaceDefinitionName` 反查到 `TypeDefinition`,然后调 `printer.printTypeDefinition(_:)`。当 typeDefinition 是特化版本(`specializationOrigin != nil`)时,printer 内部会按上游约定的不变量做参数替换 + metadata-driven 字段填充。

#### `RuntimeEngine` 扩展(`RuntimeEngine+GenericSpecialization.swift`,新文件)

跨 source 分发遵循已有的 `request<T>(local:remote:)` 原语:

```swift
public func specializationRequest(for object: RuntimeObject) async throws -> SpecializationRequest {
    try await request {
        guard let swiftSection = swiftSectionFactory.cachedSection(for: object.imagePath) else {
            throw Error.imageNotIndexed
        }
        return try await swiftSection.specializationRequest(for: object)
    } remote: { _ in
        throw Error.specializationUnsupportedOnRemoteSource
    }
}

public func specialize(
    _ object: RuntimeObject,
    with selection: SpecializationSelection
) async throws -> RuntimeObject {
    try await request {
        guard let swiftSection = swiftSectionFactory.cachedSection(for: object.imagePath) else {
            throw Error.imageNotIndexed
        }
        let result = try await swiftSection.specialize(for: object, with: selection)
        await reloadData(isReloadImageNodes: false)   // 让 sidebar 拉起新子节点
        return result
    } remote: { _ in
        throw Error.specializationUnsupportedOnRemoteSource
    }
}
```

远程分支主动抛错而不是静默 no-op,理由见非目标章节(`GenericSpecializer.specialize` 要求 MachOImage 在当前进程内)。Inspector 侧需要展示这条错误为"该 source 不支持特化"。

#### `DocumentState` 扩展

```swift
@Observed
public var specializationHistory: [RuntimeObject.ID: [SpecializationSelection]] = [:]
```

**作用**:Inspector 切回某个泛型 RuntimeObject 时,从 history 读出过去做过的 selections 用于 prefill / 提示。**不**作为 `specializedTypeDefinitions` 的真实来源 —— 真实来源在 indexer。两者的关系:

- `indexer.specializedTypeDefinitions` 是**已注册并材料化**的特化(可被 sidebar 渲染、被 printer 使用)。
- `DocumentState.specializationHistory` 仅用于 Inspector 表单状态记忆 —— 用户可能选了一半就关掉,后续打开时 prefill。

Document 关闭时,`DocumentState` 整体随 Document 销毁,history 自然消失。indexer 上的 specialized Definitions 也随 RuntimeEngine 销毁而消失(engine 与 Document 同生命周期)。

#### `InspectorRoute` / `InspectorCoordinator` 改动

`InspectorRoute` 不变。`InspectorCoordinator.makeTransition(for:)` 第 33-54 行:

```swift
case .object(let runtimeObject):
    switch runtimeObject.kind {
    case .swift(.type):
        // 新:所有 Swift 类型(class / struct / enum / typeAlias)都路由到拓宽的 ViewController。
        // ViewController 内部按 (kind, isGeneric, isSpecialized) 决定显示哪些 segment。
        let viewModel = InspectorSwiftTypeViewModel(runtimeObject: runtimeObject,
                                                    documentState: documentState,
                                                    router: self)
        let viewController = InspectorSwiftTypeViewController()
        viewController.setupBindings(for: viewModel)
        return viewController

    case .objc(.type(.class)):
        // 现状保留 —— ObjC class 仍走 class hierarchy。
        ...

    default:
        ...   // placeholder
    }
```

#### `InspectorSwiftTypeViewController`(从 `InspectorClassViewController` 拓宽而来)

**类名重命名**:`InspectorClassViewController` → `InspectorSwiftTypeViewController`(同样重命名 ViewModel 与文件,保留单一文件多视图的组合)。`InspectorClassHierarchyView` 与 `InspectorClassViewModel` 现有的 hierarchy 数据流保留不动,只是被新的 segmented 容器嵌套。

布局:

```
+----------------------------------+
| NSSegmentedControl  [H][S]       |  ← segments 按 (kind, isGeneric) 动态出现
+----------------------------------+
|  ┌──────────────────────────┐    |
|  │  当前 segment 的子视图   │    |  ← 用 NSStackView 切换,只显示一个
|  └──────────────────────────┘    |
+----------------------------------+
```

Segment 出现规则:

| 类型 | isGeneric | Segments |
|------|-----------|----------|
| `class` | false | `[Hierarchy]` 单 segment(等价旧行为,SegmentedControl 隐藏) |
| `class` | true | `[Hierarchy, Specialization]` |
| `struct` / `enum` / `typeAlias` | false | placeholder(走 `InspectorPlaceholderViewController`,未在此 controller 显示) |
| `struct` / `enum` / `typeAlias` | true | `[Specialization]` 单 segment(SegmentedControl 隐藏) |

特化版本 RuntimeObject(`isSpecialized == true`)仍走"无 generic 元信息"分支 —— 它本身已经实例化,Inspector 不再展示 Specialization 表单(避免递归特化 v1 不支持)。

#### `InspectorSpecializationViewModel`(新增)

```swift
public final class InspectorSpecializationViewModel: ViewModel<InspectorRoute> {
    @Observed private(set) var request: SpecializationRequest?
    @Observed private(set) var selection: SpecializationSelection = [:]
    @Observed private(set) var loadState: LoadState = .idle
    @Observed private(set) var canSpecialize: Bool = false

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unsupported(reason: String)   // remote source 等
        case failed(message: String)
    }

    @MemberwiseInit(.public)
    public struct Input {
        let parameterArgumentChanged: Signal<(parameter: String,
                                              argument: SpecializationSelection.Argument)>
        let specializeClicked: Signal<Void>
    }

    public struct Output {
        let request: Driver<SpecializationRequest?>
        let selection: Driver<SpecializationSelection>
        let loadState: Driver<LoadState>
        let canSpecialize: Driver<Bool>
        let didProduceSpecialized: Signal<RuntimeObject>   // 触发 router.trigger(.next(.object(_)))
    }

    public func transform(_ input: Input) -> Output { ... }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState,
                router: any Router<InspectorRoute>) { ... }
}
```

**生命周期**:

1. init 后,VM 立即异步 `documentState.runtimeEngine.specializationRequest(for: runtimeObject)`,失败 → `loadState = .failed` 或 `.unsupported`,成功 → `loadState = .loaded`,`request = ...`。
2. selection 由 input 增量更新;每次更新后通过 `GenericSpecializer.validate(selection:for:)`(纯静态 validation,无需 image)计算 `canSpecialize`。
3. specializeClicked → `documentState.runtimeEngine.specialize(runtimeObject, with: selection)`,成功后:
   - `documentState.specializationHistory[runtimeObject.id, default: []].append(selection)`
   - 通过 `didProduceSpecialized` Signal 让 ViewController 触发 `router.trigger(.next(.object(specialized)))` — 即刻把 Inspector 推到新生成的 RuntimeObject 详情。
   - sidebar 通过 `engine.reloadData()` 异步刷新。

#### `InspectorSpecializationViewController`(新增)

布局:

```swift
contentView.hierarchy {
    VStackView(alignment: .leading, spacing: 8) {
        headerLabel                 // "Generic Specialization" + 类型简介
        outlineScrollView           // StatefulOutlineView 包裹 NSOutlineView
        validationMessageLabel      // 静态 validation 的 errors / warnings
        HStackView(spacing: 8) {
            specializeButton        // PushButton("Specialize"),disabled 直到 canSpecialize
            statusLabel             // loading 时旋转 + "Loading…",失败 / unsupported 时红字
        }
    }
}
```

OutlineView 内容(`SpecializationNode` enum):

```swift
private enum SpecializationNode: Hashable {
    case parameter(SpecializationRequest.Parameter,
                   selectedCandidate: SpecializationRequest.Candidate?)
    case candidate(parameterName: String, SpecializationRequest.Candidate)
}
```

- 顶层:每个 Parameter 一行。subtitle 串接 requirements 文字摘要(`"A: Hashable & Equatable"`);右侧 accessory 显示当前选中的候选名(没选时灰色 `"<choose>"`)。
- 展开:该参数下所有 Candidate 一行(typeName + `imagePath` 短格式 + isGeneric 红色徽标)。点击行即把该 candidate 设为该参数的 `.candidate(_:)` argument。
- `requirements.contains(.layout(.class))` 但候选 `isGeneric == true` 的行:展示禁用样式 + tooltip 解释(`SpecializerError.candidateRequiresNestedSpecialization` 的预防性 UI)。

OutlineView 复用现有 `RuntimeViewerUI/StatefulOutlineView`,差量更新走 RxAppKit staged-changeset。

#### Sidebar 刷新

特化注册成功后,RuntimeEngine 调 `reloadData(isReloadImageNodes: false)`。这会触发 `MainViewModel`/Sidebar 现有的全量重建路径 —— 已有这条路径,不需要新机制。新生成的特化 RuntimeObject 会作为原泛型 RuntimeObject 的最末 child 出现(由 `RuntimeSwiftSection.makeRuntimeObject` 中 `typeChildren + protocolChildren + specializedChildren` 的拼接顺序保证)。

Sidebar cell 不需要特殊渲染特化节点:`RuntimeObject.displayName` 由 specialized Definition 的 `typeName.name` 决定(例如 `Box<Int, String>`),用户能直观分辨。`Properties.isSpecialized` 留作未来 sidebar icon / 上下文菜单的钩子,v1 不消费。

### 数据流场景

#### 场景 A —— 用户首次特化一个泛型类型

```
用户点击 sidebar 中 isGeneric 的 RuntimeObject
  → MainCoordinator → ContentCoordinator + InspectorCoordinator
  → Inspector 路由到 InspectorSwiftTypeViewController(Specialization segment 默认选中)
  → InspectorSpecializationViewModel init:
      loadState = .loading
      request = await engine.specializationRequest(for: runtimeObject)   // GenericSpecializer.makeRequest
      loadState = .loaded
  → OutlineView 渲染 parameters + candidates
  → 用户对每个 parameter 点击候选,VM 增量更新 selection,validate() 通过 → canSpecialize = true
  → 用户点击 Specialize:
      specializedObject = await engine.specialize(runtimeObject, with: selection)
      documentState.specializationHistory[runtimeObject.id, default: []].append(selection)
      router.trigger(.next(.object(specializedObject)))   // Inspector 推进新 RuntimeObject
  → engine.reloadData → sidebar 出现新子节点
  → 用户在 Content 区域看到 Box<Int, String> 形式的源码 + field offsets
```

#### 场景 B —— 用户第二次访问同一泛型类型

```
用户点击同一 isGeneric RuntimeObject
  → InspectorSpecializationViewModel init:
      检查 documentState.specializationHistory[runtimeObject.id]
      若非空,可在 OutlineView 顶部展示 "Recent selections" 区(v1 选做)
  → 此时 indexer 上已有的特化 children 已经在 sidebar 里 —— 用户可直接点 sidebar
```

#### 场景 C —— 远程 source(XPC / Bonjour / directTCP)

```
runtimeEngine.kind == .remote
  → request<T>(local:remote:) 走 remote 分支 → throws .specializationUnsupportedOnRemoteSource
  → loadState = .unsupported(reason: "Specialization requires the image to be loaded in this process.")
  → OutlineView 隐藏,只显示该消息;Specialize 按钮 disabled
```

#### 场景 D —— `GenericSpecializer.specialize` 抛错(运行时 preflight 失败)

```
用户点 Specialize
  → engine.specialize(...) → SpecializerError.specializationFailed / .candidateRequiresNestedSpecialization / .witnessTableNotFound
  → ViewModel.errorRelay.accept(error) → 基类 ViewController 自动弹 alert
  → loadState 保持 .loaded,canSpecialize 保持 true,用户可改 selection 重试
```

#### 场景 E —— Document 关闭

```
Document.close()
  → DocumentState 整体释放 → specializationHistory 消失
  → RuntimeEngine 释放 → indexer / specializer / specializedTypeDefinitions 一同消失
```

无需特殊清理逻辑。

### 错误处理

| 失败位置 | 行为 | UI |
|---|---|---|
| `engine.specializationRequest` 抛 `notGenericType` | `loadState = .failed(...)` | 红字提示 + "This type is not generic" |
| `engine.specializationRequest` 抛 `unsupportedGenericParameter(.typePack)` | `loadState = .unsupported(...)` | OutlineView 隐藏 + "Variadic generics are not yet supported" |
| `engine.specialize` 抛 `candidateRequiresNestedSpecialization` | errorRelay → alert | 提示用户改用非泛型 candidate(v1 不支持嵌套特化) |
| `engine.specialize` 抛 `protocolRequirementNotSatisfied` 等 preflight 错误 | errorRelay → alert | 含具体 protocolName / parameterName |
| 远程 source | `loadState = .unsupported(...)` | 静态文案,不报错 |
| 候选已被 indexer 移除(竞态) | `engine.specialize` 抛 `candidateResolutionFailed` | errorRelay → alert |

### 边界条件

1. **同一 selection 重复 Specialize**:上游 `registerSpecialization` 幂等,返回已存在的 Definition;UI 上无声成功并切到该 RuntimeObject。
2. **特化期间用户切走当前 RuntimeObject**:`[weak self]` + Task 取消;Specialize 已发出的请求在 await 处响应取消。
3. **特化的特化(嵌套)**:v1 拒绝。`InspectorSwiftTypeViewController` 检测到当前 RuntimeObject `properties.contains(.isSpecialized)` 时不显示 Specialization segment。
4. **Source switch**:用户在 toolbar 切到远程 source 时,Inspector 的 specialization 表单进入 `.unsupported` 分支;切回 local 时重新 load request。复用 0002 提案中已有的 `documentState.$runtimeEngine.skip(1)` 订阅模式即可,但本提案不在 Inspector 层主动监听 —— ViewModel 的 init 触发 load,当 RuntimeObject 重新被选中时会重建 ViewModel。

### 假设

1. **MachOSwiftSection 上游已实现 `specializedTypeDefinitions` / `registerSpecialization` / printer 替换渲染**(见前置依赖)。RuntimeViewer 的实施动工 = 上游 PR 合并之时。
2. **`RuntimeObject.Codable` 兼容新增 `Properties` 位**:`Properties` 是 `OptionSet<Int>`,新增位向前兼容(老数据缺失新位 = 该位为 0)。
3. **特化 Definition 的 mangled name 唯一**:由上游保证,确保 `RuntimeObject(name: mangledName, ...)` 不会与已有 RuntimeObject 撞车。
4. **`reloadData(isReloadImageNodes: false)` 重建 sidebar 时保留展开状态**:已有路径满足;复用 0002 提案中 background indexing 已经验证过的 reload 模式。

### 测试策略

放在 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/Specialization/`(若 RuntimeViewerCore 自身能 mock indexer)与 `RuntimeViewerPackages/Tests/RuntimeViewerApplicationTests/Specialization/`。

1. **`RuntimeSwiftSectionSpecializationTests`**:
   - 对一个泛型类型调 `specializationRequest(for:)`,断言 parameters / requirements / candidates 与上游 `GenericSpecializer.makeRequest` 直接调用一致。
   - 调 `specialize(for:with:)` 后,`makeRuntimeObject` 输出的 children 中包含一个 `isSpecialized == true` 的 RuntimeObject,其 displayName 反映 selection。
   - 重复 specialize 同一 selection 幂等(返回相同 RuntimeObject)。
2. **`InspectorSpecializationViewModelTests`**(用 mock RuntimeEngine):
   - init 后 loadState 进入 `.loading` → `.loaded`。
   - `parameterArgumentChanged` 累积进 selection,canSpecialize 在所有 parameter 选完后转 true。
   - specializeClicked 成功 → `didProduceSpecialized` 发射;失败 → errorRelay 发射。
   - 远程 source mock → loadState `.unsupported`。
3. **UI**(无自动化,plan 含手动验证清单):
   - SegmentedControl 在 (class generic / class non-generic / struct generic / struct non-generic) 四种组合下出现 / 隐藏正确。
   - OutlineView 展开折叠保活,候选切换时 selection 视觉同步。
   - sidebar 出现新子节点;点击该节点 Content 显示替换后的源码,带 field offsets。

### 文件清单

#### 新增文件

```
RuntimeViewerCore/Sources/RuntimeViewerCore/
    RuntimeEngine+GenericSpecialization.swift

RuntimeViewerPackages/Sources/RuntimeViewerApplication/Inspector/
    InspectorSpecializationViewModel.swift
    InspectorSwiftTypeViewModel.swift                  (从 InspectorClassViewModel 拓宽)

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/
    InspectorSwiftTypeViewController.swift             (从 InspectorClassViewController 拓宽)
    InspectorSpecializationViewController.swift
    InspectorSpecializationOutlineCells.swift          (Parameter / Candidate cell)
```

#### 修改文件

```
RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObject.swift
    + Properties.isSpecialized

RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
    + lazy var specializer
    + specializationRequest(for:) / specialize(for:with:)
    + makeRuntimeObject(for typeDefinition:isChild:) 拼接 specializedTypeDefinitions 为 children
    + 给特化 typeDefinition 打上 isSpecialized

RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
    + Error.imageNotIndexed / .specializationUnsupportedOnRemoteSource

RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
    + @Observed specializationHistory: [RuntimeObject.ID: [SpecializationSelection]]

RuntimeViewerPackages/Sources/RuntimeViewerApplication/Inspector/InspectorClassViewModel.swift
    重命名为 InspectorSwiftTypeViewModel;原 class hierarchy 逻辑保留为内部子流程

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/InspectorClassViewController.swift
    重命名为 InspectorSwiftTypeViewController;加 NSSegmentedControl + 子视图切换

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/InspectorCoordinator.swift
    makeTransition 路由扩展:.swift(.type(_)) 全部走新 ViewController

RuntimeViewerCore/Package.swift
    确认 MachOSwiftSection 版本符合上游契约(必要时升级)
```

新文件加入 Xcode 项目通过 `xcodeproj` MCP 完成(参见 project memory)。

## 替代方案考量

### A. 不新建子 RuntimeObject,仅在 Inspector 内显示特化结果

让 Specialize 按钮把 `SpecializationResult` 的 metadata 直接渲染到 Inspector 的另一个 segment(field offsets 表格 / value witness 表格),不动 Content 区域、不改 sidebar、不依赖上游"specialized Definition 存储"。

被否决,理由:

- 失去"看到泛型参数被替换为具体类型"的核心 UX —— 这是用户提出的明确需求。
- 与 Content 区域的源码渲染管道脱节,`SwiftGenerationOptions`(printFieldOffset / printTypeLayout 等)无法复用。
- 若未来扩展为 generic 嵌套特化或多个特化对比,Inspector 局部表格不够延展。

### B. 在 RuntimeViewer 层做字符串 / SemanticString 替换

不依赖上游,RuntimeViewer 拿到原始 SemanticString 后,识别 generic parameter token 替换为 `selection` 中具体类型名。

被否决,理由:

- SemanticString 是结构化的(token / kind),手动重写会损失 jump-to-definition 等语义能力。
- field offsets / size 等 metadata-driven 字段无法用字符串替换得到,仍需 metadata 调用 → 还是要 GenericSpecializer 路径。
- 跨 module / 嵌套 generic 的替换易错(`A.Element.Element` 等关联类型路径)。
- "把渲染逻辑放到该放的地方":SwiftInterfacePrinter 已经知道 generic substitution 的所有上下文,RuntimeViewer 只是表层。

### C. 把特化历史持久化到磁盘

存到 `~/Library/Application Support/RuntimeViewer/Specializations/<documentID>.json`,跨 session 保留。

被否决(v1),理由:

- 用户已明确选择"Document 内记忆,关闭丢"(详见决策日志 2026-05-08)。
- selection 的 `.metatype` argument 是 `Any.Type`,不可序列化;`.candidate` 也依赖具体 image 在场,跨 session 不一定有效。
- 持久化模型设计需要单独提案。可作为后续提案推进。

### D. Inspector 入口走 Content 工具栏 / 右键菜单

让 Specialize 入口在 Content 区域,而非 Inspector 的新 segment。

被否决,理由:见决策日志 2026-05-08(用户选 "Inspector 面板新增 Tab")。Inspector 是属性 / 元信息的语义归属地,Content 是源码归属地;特化触发是元信息层面的动作,放 Inspector 是更一致的归类。

### E. OutlineView 改用分步向导 / Pop-up 表单

让用户一步步选 parameter,或每个 parameter 一行 Pop-up button。

被否决,理由:见决策日志 2026-05-08(用户选 "OutlineView:参数 + 候选展开")。OutlineView 的优势:候选数量大时可滚动 + 搜索;requirements / source / isGeneric flag 等附带信息有展示空间;与项目其他大量 OutlineView 风格一致。

## 影响

- **破坏性变更**:无。`isSpecialized` 是新 OptionSet 位,默认不存在 = 不影响老数据。Inspector ViewController / ViewModel 重命名(`InspectorClass*` → `InspectorSwiftType*`)是内部类型,没有公共 API 暴露。
- **受影响文件**:见上文文件清单。
- **是否需要迁移**:不需要。
- **性能影响**:特化注册路径异步,不阻塞 Inspector 加载。OutlineView candidate 列表可能很长(`indexer.allTypeNames`),首次展开时按需加载即可。
- **跨仓库依赖**:**强依赖** MachOSwiftSection 上游先实现"specialized Definition 存储 + printer 替换渲染"。本提案在上游 ready 之前不动代码。

## 决策日志

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-05-08 | 创建为 Draft | 起源于"为泛型 Swift 类型提供 field offset / metadata 视图"的需求 |
| 2026-05-08 | 入口放在 Inspector 新增 segment(而非 Content 工具栏 / 右键菜单) | Inspector 是元信息归属地;后续若要加 segment 也是顺势扩展。用户选项 |
| 2026-05-08 | 参数选择 UI 用 OutlineView 展开 candidates(而非 Pop-up / 分步向导 / Split) | 候选数量大、附带信息多,OutlineView 可滚动 / 搜索 / 与项目一致。用户选项 |
| 2026-05-08 | 特化结果新建一个 RuntimeObject 作为原泛型 RuntimeObject 的子节点 | 与 Content 渲染管道无缝衔接;用户可在 sidebar 切换不同特化对比;天然支持 isSpecialized 后续行为扩展。用户选项 |
| 2026-05-08 | Document 内记忆,关闭丢(不持久化到磁盘) | v1 范围控制;`SpecializationSelection.Argument.metatype` 不可序列化,持久化需要单独建模。用户选项 |
| 2026-05-08 | 拓宽 `InspectorClassViewController` → `InspectorSwiftTypeViewController` + Segmented(而非新建独立 ViewController / Inspector 根上加 NSTabViewController) | 单一入口,Coordinator 路由分支少;现有 Class Hierarchy 与新 Specialization 共享导航 stack。用户选项 |
| 2026-05-08 | 实施顺序:**先去 MachOSwiftSection 那边加 API,再回 RuntimeViewer 搭 UI**(而非并行 / 占位 protocol / 仅搭 UI 骨架) | 用户选项;避免双方契约漂移和后期返工 |
| 2026-05-08 | 远程 source(XPC / Bonjour / directTCP)在 v1 不支持特化 | `GenericSpecializer.specialize` 要求 `MachO == MachOImage`,即镜像必须在当前进程内加载。远程支持需要把 specialize 工作下推到目标进程并跨 RPC 回传 SpecializationResult — 单独提案 |
| 2026-05-08 | v1 不支持嵌套(已特化的特化)与 TypePack / Value generics | 上游 `GenericSpecializer` 已显式拒绝 typePack / value;嵌套特化(`Argument.specialized`)的 UI 设计复杂度需要单独考虑 |

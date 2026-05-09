# 0003 - 泛型类型特化

- **状态**: In Progress
- **作者**: JH
- **日期**: 2026-05-08
- **最后更新**: 2026-05-09

## 摘要

为泛型 Swift 类型(`class` / `struct` / `enum` 凡带 `<T, U>` 者)新增**用户驱动的特化(Generic Specialization)** 工作流:用户在 Inspector 的 Specialization tab 看到该泛型类型已注册的特化版本列表,点 `[+ Add Specialization]` 弹出 Sheet,Sheet 内表单为每个泛型参数选具体类型(候选选择走 Popover + 搜索)。提交后 RuntimeViewer 调用上游 `GenericSpecializer.specialize(_:with:)` 拿到 `SpecializationResult`,再通过 `TypeDefinition.specialize(with:in:)` 把它注册回原泛型 `TypeDefinition`,新生成的特化 `TypeDefinition` 作为该泛型 RuntimeObject 的子节点暴露在 sidebar 中。点击该子节点即在 Content 区域看到泛型参数被替换为具体类型的源码,以及来自运行时 metadata 的 field offset / size / value witness 等原本无法静态获取的信息。

## 动机

Runtime Viewer 当前对**泛型 Swift 类型**的展示有一个明显的天花板:

- 泛型类型的 metadata 在二进制中没有具象化(generic context 只有占位 parameter `A`/`B`/...),因此基于 metadata 的字段 —— `printFieldOffset`、`printTypeLayout`、`printEnumLayout` —— 在泛型类型上**全部为空或不可计算**。
- `RuntimeObject.Properties.isGeneric` 已经在 `RuntimeSwiftSection.makeRuntimeObject(for:isChild:)` 第 451 行被打上,但目前没有任何 UI 利用这个标记;Inspector 也只对 `.swift(.type(.class))` 路由到 `InspectorClassViewController` 展示类层次。
- 上游 `MachOSwiftSection` 已完成 `GenericSpecializer` 的核心算法 + `TypeDefinition.specialize(with:in:)` 的注册路径(`feature/specialized-type-definition` 分支),并且 `SwiftInterfaceBuilder` / `SwiftInterfacePrinter` 已经会自动迭代 `specializedTypeDefinitions` 渲染替换后的源码与 metadata-driven 字段。RuntimeViewer 这一侧只需要搭 UI 与数据流。

目标:

- 让用户能对任意 `isGeneric` 的 Swift 类型选定具体类型组合并触发特化。
- 特化后展示同一份 SwiftInterface 渲染管道,但泛型参数被替换为具体类型,且 metadata-driven 的字段填上真实数值。
- 已特化版本通过 sidebar 子节点直接访问,无需额外状态。
- 不污染 Sidebar 的索引主路径,不改 `RuntimeObject` 的核心序列化字段。

### 非目标

- **不**实现源码层面的字符串替换 —— 替换语义由 MachOSwiftSection 的渲染管道承担。
- **不**支持嵌套递归特化的 UI(`SpecializationSelection.Argument.specialized`)—— v1 仅支持 `.candidate` / `.metatype` 两种简单 argument。
- **不**跨 Document / 跨会话持久化用户做过的特化组合(关闭文档丢)。
- **不**支持 TypePack / Value generics(`GenericSpecializer.makeRequest` 已经显式拒绝这两种,UI 上以禁用 + 解释展示)。
- **不**支持远程 source(XPC / directTCP / Bonjour)的特化 —— `GenericSpecializer.specialize` 要求 `MachO == MachOImage` 即镜像必须在当前进程内加载,远程源 v1 在 UI 上展示"该 source 不支持特化"占位。
- **不**承担 MachOSwiftSection 内部的 specialized-Definition 存储 / 渲染实现 —— 已是上游既有能力。

## 提议方案

### 前置依赖:MachOSwiftSection 上游 API(已实现)

上游已经在 `MachOSwiftSection` 仓库 `feature/specialized-type-definition` 分支(commit `ee2a920`)实现以下 API,RuntimeViewer 直接调用即可:

```swift
// === SwiftInterface/Components/Definitions/TypeDefinition.swift ===
extension TypeDefinition {
    /// 该泛型类型已注册的特化版本。非泛型类型恒为 []。
    /// 一层挂载,不再递归嵌套(嵌套 v1 不支持)。
    public private(set) var specializedTypeDefinitions: [TypeDefinition]

    /// 特化版本携带的运行时 metadata。
    /// nil = 这是原始(generic / non-generic)Definition;
    /// 非 nil = 该 Definition 是 specialize(with:in:) 的产物,
    ///        printer 渲染时直接用它取 field offsets / type layout 等。
    public internal(set) var metadata: MetadataWrapper?

    /// 用 SpecializationResult 创建一份特化的 TypeDefinition,
    /// 追加到 self.specializedTypeDefinitions 末尾。
    /// 内部三层校验(必须 generic / metadata kind 兼容 / descriptor 同一)。
    @discardableResult
    public func specialize(
        with specializationResult: SpecializationResult,
        in machO: MachOImage
    ) async throws -> TypeDefinition

    public enum SpecializationError: LocalizedError {
        case notGenericType, metadataKindMismatch, descriptorMismatch, unsupportedMetadataKind
    }
}

// === SwiftInterface/GenericSpecializer ===
@_spi(Support)
public final class GenericSpecializer<MachO: MachOSwiftSectionRepresentableWithCache> {
    public init(indexer: SwiftInterfaceIndexer<MachO>)
    public func makeRequest(for: TypeContextDescriptorWrapper, ...) throws -> SpecializationRequest
    public func validate(selection:for:) -> SpecializationValidation       // 静态校验
}
@_spi(Support)
extension GenericSpecializer where MachO == MachOImage {
    public func runtimePreflight(selection:for:) -> SpecializationValidation
    public func specialize(_:with:metadataRequest:) throws -> SpecializationResult
}
```

**关键调用形态(两步)**:

```swift
let specializer = GenericSpecializer(indexer: indexer)         // 一次性构造,可缓存
let request = try specializer.makeRequest(for: typeDefinition.type.typeContextDescriptorWrapper)
// ... 用户填 selection ...
let result = try specializer.specialize(request, with: selection)
let specializedDefinition = try await typeDefinition.specialize(with: result, in: machO)
```

**SwiftInterfacePrinter 已自动渲染**:`SwiftInterfaceBuilder` 第 150-153 行已经会迭代每个 `typeDefinition` 的 `specializedTypeDefinitions` 并调 `printer.printTypeDefinition(specialized)`,该 printer 检测到 `metadata != nil` 时自动用 metadata 驱动 field offsets / type layout / 等所有 metadata-driven 字段。

**关键不变量(由上游保证)**:

1. `specializedTypeDefinitions` 是用户态产物,不参与 indexer 的全量重建,reload 不清掉。
2. printer 对特化 Definition 渲染时,所有现有 `SwiftGenerationOptions`(printFieldOffset / printTypeLayout / printEnumLayout / synthesizeOpaqueType ...)继续生效,差别在"参数实际可解了" + "metadata 字段填上"。
3. `specialize(with:in:)` 三层校验:必须 generic / metadata 与 descriptor kind 兼容 / descriptor offset 同一。校验失败抛 `SpecializationError`。

### 整体数据流

```
┌──────────────────────────────────────────────────────────────────────────┐
│  RuntimeViewerUsingAppKit                                                 │
│                                                                           │
│   InspectorSwiftTypeViewController (拓宽自 InspectorClassViewController)  │
│     ├── NSSegmentedControl: [Hierarchy | Specialization]                  │
│     ├── InspectorClassHierarchyView    (复用,仅 class 显示)              │
│     └── Specialization tab:                                               │
│           NSTableView 展示 specializedChildren                            │
│           [+ Add Specialization] PushButton                               │
│                                                                           │
│   SpecializationCoordinator (SceneCoordinator,新增,参照 ExportingCoordinator)
│     └─ SpecializationSheetWindowController (Document Window sheet)        │
│        Routes: initial / cancel / requestTypePicker / specializeCompleted │
│                                                                           │
│   SpecializationSheetViewController (Sheet 主体,新增)                    │
│     ├─ Header: "Specialize <TypeName>"                                    │
│     ├─ Form: 每行 [Parameter Label] [Choose Type… ▾]                      │
│     ├─ Validation message label                                           │
│     └─ [Cancel]    [Specialize]                                           │
│                                                                           │
│   TypePickerPopoverViewController (新增)                                  │
│     └─ NSSearchField + NSTableView (typeName + image / isGeneric badge)   │
└──────────────────────────────────────────────────────────────────────────┘
                            ↕ RxSwift / @Observed
┌──────────────────────────────────────────────────────────────────────────┐
│  RuntimeViewerApplication                                                 │
│                                                                           │
│   InspectorSwiftTypeViewModel (重命名自 InspectorClassViewModel)          │
│     · hierarchy: Driver<String>                                           │
│     · specializedChildren: Driver<[RuntimeObject]>                        │
│     · segmentVisibility: Driver<(showsHierarchy, showsSpecialization)>    │
│     · addSpecializationClicked / selectSpecializationClicked Signals      │
│                                                                           │
│   SpecializationSheetViewModel (新增,ViewModel<SpecializationRoute>)     │
│     · @Observed request / selection / loadState / canSpecialize / validation
│                                                                           │
│   TypePickerPopoverViewModel (新增)                                       │
│     · 候选过滤 / isGeneric 禁用 / didSelect Signal                        │
└──────────────────────────────────────────────────────────────────────────┘
                            ↕ async / await
┌──────────────────────────────────────────────────────────────────────────┐
│  RuntimeViewerCore                                                        │
│                                                                           │
│   RuntimeEngine                                                           │
│     + specializationRequest(for:) / specialize(_:with:)                   │
│       通过 request<T>(local:remote:) 分发,远程抛 unsupported             │
│                                                                           │
│   RuntimeSwiftSection (actor)                                            │
│     + lazy specializer: GenericSpecializer<MachOImage>                    │
│     + specializationRequest(for:) / specialize(for:with:)                 │
│     + makeRuntimeObject 把 specializedTypeDefinitions 拼为 children       │
│       并对 metadata != nil 的 typeDefinition 标 isSpecialized             │
│                                                                           │
│   RuntimeObject + Properties.isSpecialized                               │
└──────────────────────────────────────────────────────────────────────────┘
                            ↕ MachOSwiftSection
                  TypeDefinition.specialize(with:in:) /
                  specializedTypeDefinitions /
                  GenericSpecializer.specialize / SwiftInterfaceBuilder
```

### 组件

#### `RuntimeObject.Properties.isSpecialized`(新增 OptionSet 位)

```swift
public struct Properties: OptionSet, Codable, Hashable, Sendable {
    public static let isGeneric     = Self(rawValue: 1 << 0)
    public static let isSpecialized = Self(rawValue: 1 << 1)   // 新增
}
```

映射规则在 `RuntimeSwiftSection.makeRuntimeObject(for typeDefinition:isChild:)`(第 445-462 行附近):

```swift
if typeDefinition.type.contextDescriptorWrapper.contextDescriptor.layout.flags.isGeneric {
    properties.insert(.isGeneric)
}
if typeDefinition.metadata != nil {
    properties.insert(.isSpecialized)
}
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
    let request = try specializer.makeRequest(for: baseTypeDefinition.type.typeContextDescriptorWrapper)
    let result  = try specializer.specialize(request, with: selection)
    let specializedDefinition = try await baseTypeDefinition.specialize(with: result, in: machO)
    let runtimeObject = try makeRuntimeObject(for: specializedDefinition, isChild: true)
    interfaceByName.removeValue(forKey: object)   // Content 下次拉源码时拿到含特化版本的最新 interface
    return runtimeObject
}

private func requireTypeDefinition(for object: RuntimeObject) throws -> TypeDefinition {
    guard let definitionName = nameToInterfaceDefinitionName[object],
          let typeName = definitionName.typeName else { throw Error.invalidRuntimeObject }
    if let root = indexer.rootTypeDefinitions[typeName] { return root }
    if let any  = indexer.allTypeDefinitions[typeName]  { return any  }
    throw Error.invalidRuntimeObject
}
```

`interface(for:)` **完全不变**:仍按 `nameToInterfaceDefinitionName` 反查 `TypeDefinition` 调 `printer.printTypeDefinition(_:)`。printer 内部对 `metadata != nil` 的 specialized Definition 做参数替换 + metadata-driven 字段填充。

#### `RuntimeEngine+GenericSpecialization.swift`(新文件)

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

`RuntimeEngine.swift` 同时新增 `Error.imageNotIndexed` / `Error.specializationUnsupportedOnRemoteSource`。

#### `InspectorSwiftTypeViewController`(从 `InspectorClassViewController` 拓宽)

布局:

```
┌─ Inspector ────────────────────┐
│  [Hierarchy]  [Specialization] │  ← NSSegmentedControl,按 segmentVisibility 显隐
├────────────────────────────────┤
│  Specializations of Box<A,B>   │  ← Specialization tab 内容
│                                │
│  • Box<Int, String>            │
│  • Box<URL, Data>              │
│                                │
│        [+ Add Specialization]  │
└────────────────────────────────┘
```

Segments 出现规则:

| 类型 | isGeneric | isSpecialized | Segments |
|------|-----------|---------------|----------|
| `class` | false | false | `[Hierarchy]` 单 segment(隐藏 control) |
| `class` | true  | false | `[Hierarchy, Specialization]` |
| `class` | —     | true  | `[Hierarchy]`(特化版本不显 Specialization) |
| 非 class(struct/enum/typeAlias) | false | — | placeholder(走 `InspectorPlaceholderViewController`,该 VC 不接管) |
| 非 class | true  | false | `[Specialization]` 单 segment(隐藏 control) |
| 非 class | —     | true  | placeholder |

行为:

- Specialization tab 内是 NSTableView 单列,数据源 = `runtimeObject.children` 中 `properties.contains(.isSpecialized)` 的项
- 顶部说明 Label `"Specializations of <TypeName>"`,空列表时显 `"No specializations yet."`
- 行内容:displayName(例 `Box<Int, String>`)+ 右侧 `[×]` 按钮(v1 hidden,等上游加 unregister API 后启用)
- `[+ Add Specialization]` 点击 → `addSpecializationClickedRelay` → InspectorRoute → InspectorCoordinator.Delegate → MainCoordinator 启动 SpecializationCoordinator
- 行点击(`tableView.rx.selectedRow`)→ `selectSpecializationClickedRelay` → InspectorRoute.selectRuntimeObject → MainCoordinator 改 `documentState.selectedRuntimeObject`(Sidebar 自动定位)

`InspectorSwiftTypeViewModel` 暴露:

```swift
public final class InspectorSwiftTypeViewModel: ViewModel<InspectorRoute> {
    @Observed private(set) var runtimeObject: RuntimeObject

    public struct Output {
        let hierarchy: Driver<String>                          // class 用
        let specializedChildren: Driver<[RuntimeObject]>       // 过滤 isSpecialized
        let segmentVisibility: Driver<(showsHierarchy: Bool, showsSpecialization: Bool)>
    }

    public struct Input {
        let addSpecializationClicked: Signal<Void>
        let selectSpecializationClicked: Signal<RuntimeObject>
    }

    public func transform(_ input: Input) -> Output {
        input.addSpecializationClicked.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.requestSpecializationSheet(runtimeObject))
        }.disposed(by: rx.disposeBag)

        input.selectSpecializationClicked.emitOnNext { [weak self] specialized in
            guard let self else { return }
            router.trigger(.selectRuntimeObject(specialized))
        }.disposed(by: rx.disposeBag)

        return Output(...)
    }
}
```

#### `InspectorRoute` / `InspectorCoordinator` 改动

`InspectorRoute` 加两个 case:

```swift
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum InspectorRoute: Routable {
    case placeholder
    case root(InspectableObject)
    case next(InspectableObject)
    case back
    case requestSpecializationSheet(RuntimeObject)   // 新增
    case selectRuntimeObject(RuntimeObject)          // 新增
}
```

`InspectorCoordinator`:

```swift
extension InspectorCoordinator {
    protocol Delegate: AnyObject {
        func inspectorCoordinator(_ coordinator: InspectorCoordinator,
                                  requestSpecializationSheetFor object: RuntimeObject)
        func inspectorCoordinator(_ coordinator: InspectorCoordinator,
                                  selectRuntimeObject object: RuntimeObject)
    }
}

final class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    weak var delegate: Delegate?

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        // ... 原有 cases
        case .object(let runtimeObject):
            switch runtimeObject.kind {
            case .swift(.type):
                let viewModel = InspectorSwiftTypeViewModel(runtimeObject: runtimeObject,
                                                            documentState: documentState,
                                                            router: self)
                let viewController = InspectorSwiftTypeViewController()
                viewController.setupBindings(for: viewModel)
                return .set([viewController], animated: true)
            case .objc(.type(.class)):
                // 现状保留 —— ObjC class 仍走 class hierarchy。
                ...
            default:
                ...   // placeholder
            }
        case .requestSpecializationSheet(let object):
            delegate?.inspectorCoordinator(self, requestSpecializationSheetFor: object)
            return .none()
        case .selectRuntimeObject(let object):
            delegate?.inspectorCoordinator(self, selectRuntimeObject: object)
            return .none()
        }
    }
}
```

`MainCoordinator` 实现 delegate:

```swift
extension MainCoordinator: InspectorCoordinator.Delegate {
    func inspectorCoordinator(_: InspectorCoordinator,
                              requestSpecializationSheetFor object: RuntimeObject) {
        let coord = SpecializationCoordinator(documentState: documentState,
                                              runtimeObject: object,
                                              parentWindow: windowController.window!)
        coord.delegate = self
        addChild(coord)
        coord.contextTrigger(.initial(object))
    }

    func inspectorCoordinator(_: InspectorCoordinator,
                              selectRuntimeObject object: RuntimeObject) {
        documentState.selectedRuntimeObject = object   // sidebar 自动联动
    }
}

extension MainCoordinator: SpecializationCoordinator.Delegate {
    func specializationCoordinator(_ coord: SpecializationCoordinator,
                                   didProduce specialized: RuntimeObject) {
        documentState.selectedRuntimeObject = specialized
    }
}
```

#### `SpecializationRoute` + `SpecializationCoordinator`(参照 ExportingCoordinator)

```swift
@AssociatedValue(.public)
@CaseCheckable(.public)
enum SpecializationRoute: Routable {
    case initial(RuntimeObject)
    case cancel
    case requestTypePicker(parameterName: String, anchor: NSView)
    case specializeCompleted(RuntimeObject)
}

typealias SpecializationTransition =
    Transition<SpecializationSheetWindowController, SpecializationSheetViewController>

final class SpecializationCoordinator:
    SceneCoordinator<SpecializationRoute, SpecializationTransition> {

    weak var delegate: Delegate?
    let documentState: DocumentState
    let runtimeObject: RuntimeObject

    protocol Delegate: AnyObject {
        func specializationCoordinator(_ coordinator: SpecializationCoordinator,
                                       didProduce specialized: RuntimeObject)
    }

    init(documentState: DocumentState,
         runtimeObject: RuntimeObject,
         parentWindow: NSWindow) {
        self.documentState = documentState
        self.runtimeObject = runtimeObject
        super.init(windowController: SpecializationSheetWindowController(),
                   initialRoute: nil)
        windowController.contentViewController = SpecializationSheetViewController(router: self)
        // sheet 由 parentWindow.beginSheet(windowController.window!) 显示;具体接入参照 ExportingCoordinator
    }

    override func prepareTransition(for route: SpecializationRoute) -> SpecializationTransition {
        switch route {
        case .initial(let object):
            let vm = SpecializationSheetViewModel(runtimeObject: object,
                                                   documentState: documentState,
                                                   router: self)
            let vc = SpecializationSheetViewController()
            vc.setupBindings(for: vm)
            return .show(vc)
        case .cancel:
            removeFromParent()
            return .endSheetOnTop()
        case .specializeCompleted(let specialized):
            delegate?.specializationCoordinator(self, didProduce: specialized)
            removeFromParent()
            return .endSheetOnTop()
        case .requestTypePicker(let parameterName, let anchor):
            let pickerVM = TypePickerPopoverViewModel(...)
            let pickerVC = TypePickerPopoverViewController()
            pickerVC.setupBindings(for: pickerVM)
            // 显示 popover 锚定在 anchor 上;popover 选中后通过回调写回 SheetVM 的 parameterArgumentChangedRelay
            let popover = NSPopover()
            popover.contentViewController = pickerVC
            popover.behavior = .transient
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            return .none()
        }
    }
}
```

#### `SpecializationSheetViewModel`

```swift
public final class SpecializationSheetViewModel: ViewModel<SpecializationRoute> {
    @Observed private(set) var request: SpecializationRequest?
    @Observed private(set) var selection: SpecializationSelection = [:]
    @Observed private(set) var loadState: LoadState = .idle
    @Observed private(set) var canSpecialize: Bool = false
    @Observed private(set) var validation: SpecializationValidation?

    public enum LoadState: Equatable {
        case idle, loading, loaded
        case unsupported(reason: String)
        case failed(message: String)
    }

    public struct Input {
        let parameterArgumentChanged: Signal<(parameterName: String,
                                              argument: SpecializationSelection.Argument)>
        let requestTypePickerClicked: Signal<(parameterName: String, anchor: NSView)>
        let specializeClicked: Signal<Void>
        let cancelClicked: Signal<Void>
    }

    public struct Output {
        let parameters: Driver<[SpecializationRequest.Parameter]>
        let selection: Driver<SpecializationSelection>
        let loadState: Driver<LoadState>
        let validation: Driver<SpecializationValidation?>
        let canSpecialize: Driver<Bool>
    }

    public func transform(_ input: Input) -> Output { ... }
}
```

生命周期:

1. init 异步 `engine.specializationRequest(for: runtimeObject)` → 设置 `request` + loadState 流转
2. `parameterArgumentChanged` → 增量更新 `selection`,跑静态 `validate(selection:for:)` 写 `validation` + `canSpecialize`
3. `requestTypePickerClicked` → `router.trigger(.requestTypePicker(parameterName, anchor))`
4. `specializeClicked` → `engine.specialize(runtimeObject, with: selection)` 成功 → `router.trigger(.specializeCompleted(specialized))`,失败 → `errorRelay.accept(...)`
5. `cancelClicked` → `router.trigger(.cancel)`

#### `SpecializationSheetViewController`

```swift
final class SpecializationSheetViewController:
    UXKitViewController<SpecializationSheetViewModel> {

    private let headerLabel = Label()
    private let formStack   = VStackView(alignment: .leading, spacing: 8) { }
    private let validationLabel = Label()
    private let cancelButton    = PushButton().then { $0.title = "Cancel" }
    private let specializeButton = PushButton().then { $0.title = "Specialize" }

    // 表单中每个 Parameter 一个 ParameterRowView 子视图
    // setupBindings(for:):
    //   output.parameters.driveOnNext { 重建 formStack 内的 ParameterRowView 列表 }
    //   output.canSpecialize.drive(specializeButton.rx.isEnabled)
    //   output.validation.driveOnNext { validationLabel.stringValue = $0?.summary ?? "" }
    //   output.loadState.driveOnNext { 切换 form / "unsupported" 文案 / failed 文案 }
    //   button click → relay
}

private final class ParameterRowView: NSView {
    let nameLabel:  Label                 // "A : Hashable"
    let chooseButton: PushButton          // 文字 = 当前 selection 的 typeName 或 "<choose>"
    var requestTypePicker: ((NSView) -> Void)?

    @objc private func chooseClicked() { requestTypePicker?(chooseButton) }
}
```

#### `TypePickerPopoverViewModel` + `TypePickerPopoverViewController`

```swift
public final class TypePickerPopoverViewModel: ViewModel<...> {
    private let allCandidates: [SpecializationRequest.Candidate]
    @Observed private(set) var filteredCandidates: [SpecializationRequest.Candidate] = []

    public struct Input {
        let searchTextChanged: Signal<String>
        let candidateClicked: Signal<SpecializationRequest.Candidate>
    }
    public struct Output {
        let filteredCandidates: Driver<[SpecializationRequest.Candidate]>
        let didSelect: Signal<SpecializationRequest.Candidate>
    }
}

final class TypePickerPopoverViewController:
    AppKitViewController<TypePickerPopoverViewModel> {

    let searchField = NSSearchField()
    let scrollView  = ScrollView()
    let tableView   = NSTableView()
    // 单列行:typeName + image short path 副标 + isGeneric 红色 badge(disabled)
    // popover.behavior = .transient,fixed width 320,高度按内容 200~400
}
```

#### Sidebar 刷新

特化注册成功后,RuntimeEngine 调 `reloadData(isReloadImageNodes: false)`,触发 sidebar 全量重建。新生成的特化 RuntimeObject 作为原泛型 RuntimeObject 的最末 child 出现(由 `RuntimeSwiftSection.makeRuntimeObject` 中 `typeChildren + protocolChildren + specializedChildren` 的拼接顺序保证)。`MainCoordinator.specializationCoordinator(_:didProduce:)` 同时把 `documentState.selectedRuntimeObject` 切到新节点,sidebar 自动定位 + Content 同步刷新。

`Properties.isSpecialized` 留作未来 sidebar icon / 上下文菜单的钩子,v1 不消费。

### 数据流场景

#### 场景 A —— 用户首次特化一个泛型类型

```
sidebar 点击 isGeneric 的 Box<A: Hashable, B>
  → MainCoordinator → InspectorCoordinator.makeTransition(.swift(.type(.struct)))
  → InspectorSwiftTypeViewController:[Specialization] 单 segment 显示空列表 + [+ Add]
  → 用户点 [+]
       → InspectorRoute.requestSpecializationSheet(object)
       → InspectorCoordinator.Delegate → MainCoordinator
            启动 SpecializationCoordinator,beginSheet 下拉
  → SpecializationSheetViewController loadState = .loading
       request = await engine.specializationRequest(for:)
       loadState = .loaded
  → 用户点 A 的 [Choose Type…]
       → SheetVM relay → router.trigger(.requestTypePicker("A", anchor))
       → Coordinator show TypePickerPopover
       用户搜 "String" → 点击 String → didSelect → popover 关闭
       → callback 写入 SheetVM.parameterArgumentChangedRelay(("A", .candidate(StringCandidate)))
  → 同样填 B
  → 静态 validate 通过 → canSpecialize = true
  → 用户点 [Specialize]
       engine.specialize(runtimeObject, with: selection)
         → RuntimeSwiftSection.specialize:
             specializer.specialize(request, with: selection) → SpecializationResult
             baseTypeDefinition.specialize(with: result, in: machO) → 新 TypeDefinition
             makeRuntimeObject(...) → 新 RuntimeObject
             interfaceByName.removeValue(forKey: object)
         → engine.reloadData(isReloadImageNodes: false)
       router.trigger(.specializeCompleted(specialized))
  → MainCoordinator.specializationCoordinator(_:didProduce:):
       documentState.selectedRuntimeObject = specialized
  → sidebar 自动定位到 Box<String, ...>(reloadData 已加进去)
       Content 显示替换后的源码 + field offsets
       Inspector 重建为该特化 RuntimeObject —— 只显 Hierarchy(class)或 placeholder(struct/enum)
```

#### 场景 B —— 用户回到原泛型类型,看见已特化版本

```
用户点 sidebar 中原 Box<A, B>(generic)
  → InspectorSwiftTypeViewController:[Specialization] tab 列表显示
       - Box<Int, String>
       - Box<URL, Data>
  → 行点击 → router.trigger(.selectRuntimeObject(specialized))
       → MainCoordinator → documentState.selectedRuntimeObject = specialized
       → sidebar 联动定位
  → 用户也可以再点 [+] 加新的特化(回到场景 A)
```

#### 场景 C —— 远程 source(XPC / Bonjour / directTCP)

```
runtimeEngine 是 XPC / Bonjour
  → InspectorSwiftTypeViewController 仍显 [Specialization] tab,
       列表为空(specializedTypeDefinitions 在远端不同步,留空是正确状态),
       [+] 按钮可点
  → 用户点 [+] → SpecializationCoordinator.initial → SheetVM init
       engine.specializationRequest 走 remote → throws .specializationUnsupportedOnRemoteSource
       loadState = .unsupported(reason: "Specialization requires the image to be loaded in this process.")
  → Sheet 内 Form 隐藏,展示该消息 + 仅 [Cancel] 按钮可点
```

#### 场景 D —— `specialize` 抛错(运行时 preflight 失败 / candidate 失败 / 上游 SpecializationError)

```
用户点 [Specialize] → engine.specialize → 抛
   GenericSpecializer.SpecializerError.specializationFailed
   / .candidateRequiresNestedSpecialization
   / .witnessTableNotFound
   / TypeDefinition.SpecializationError.metadataKindMismatch
   / .descriptorMismatch
  → SheetVM errorRelay → 基类 VC 自动弹 alert
  → loadState 保持 .loaded,canSpecialize 保持 true,用户可改 selection 重试
  → Sheet 不关闭
```

#### 场景 E —— 用户取消 / Document 关闭

```
取消:
  用户点 [Cancel] → router.trigger(.cancel)
  → coordinator removeFromParent + endSheetOnTop
  → 无副作用 —— specializedTypeDefinitions 不变

Document 关闭:
  DocumentState 释放 → RuntimeEngine 释放
  → indexer / specializer / 所有 typeDefinitions 包括 specializedTypeDefinitions 一同消失
  → 任何在途的 SpecializationCoordinator 也通过 parent ARC 释放
```

### 错误处理

| 失败位置 | 行为 | UI |
|---|---|---|
| `engine.specializationRequest` 抛 `notGenericType` | loadState = .failed | Sheet 内红字 + "This type is not generic" |
| `engine.specializationRequest` 抛 `unsupportedGenericParameter(.typePack/.value)` | loadState = .unsupported | Sheet 内 Form 隐藏 + "Variadic / value generics not yet supported" |
| `engine.specialize` 抛 `candidateRequiresNestedSpecialization` | errorRelay → alert | "Choose a non-generic candidate(嵌套特化 v1 不支持)" |
| `engine.specialize` 抛 `protocolRequirementNotSatisfied` 等 preflight 错误 | errorRelay → alert | 含 protocolName / parameterName |
| `TypeDefinition.SpecializationError`(metadataKindMismatch / descriptorMismatch) | errorRelay → alert | "Internal error: descriptor mismatch" + Sheet 内 disable |
| 远程 source | loadState = .unsupported | Sheet 内静态文案 |
| 候选已被 indexer 移除(竞态) | errorRelay → alert | "Candidate type is no longer available" |

### 边界条件

1. **同一 selection 重复 Specialize**:`TypeDefinition.specialize(with:in:)` 不去重(直接 append),会产生两个 displayName 相同的子节点。v1 接受这个事实;后续可在 RuntimeSwiftSection 层做 selection 哈希去重。
2. **特化期间用户关闭 Sheet**:Cancel 即关。已发出的 `engine.specialize` 是 await,用户点 Cancel 后 await 仍会 resume,但 coordinator 已 deinit,delegate 弱引用为 nil,结果丢弃。
3. **特化的特化(嵌套)**:v1 拒绝。InspectorSwiftTypeViewController 检测到 `properties.contains(.isSpecialized)` 时不显 Specialization tab。
4. **Source switch**:用户在 toolbar 切 source 时,任何打开的 Sheet 不主动关闭,VM 第一次 await 失败会进入 `.unsupported` / `.failed`。后续可加显式 source-switch 监听,v1 不做。

### 假设

1. **`RuntimeObject.Codable` 兼容新增 `Properties` 位**:`Properties` 是 `OptionSet<Int>`,新增位向前兼容(老数据缺失新位 = 该位为 0)。
2. **`reloadData(isReloadImageNodes: false)` 重建 sidebar 时保留展开状态**:已有路径满足。
3. **MachOSwiftSection 工作空间已切到 `feature/specialized-type-definition` 分支**:`MxIris-Reverse-Engineering.xcworkspace` 通过本地 checkout 拿到上游 API。后续上游分支合并到 main 后,RuntimeViewer 在 Package.swift 锁定相应版本。

### 测试策略

`RuntimeViewerCore/Tests/.../Specialization/`:

- `RuntimeSwiftSectionSpecializationTests`:specializationRequest 与上游一致;specialize 成功后 children 含 `isSpecialized == true` RuntimeObject;displayName 反映 selection;同 selection 重复 specialize 当前不去重(v1 行为)。

`RuntimeViewerPackages/Tests/.../Specialization/`(用 mock RuntimeEngine):

- `SpecializationSheetViewModelTests`:loadState 流转;parameterArgumentChanged 累积进 selection;canSpecialize 在所有 parameter 选完后转 true;specializeClicked 成功 → router.trigger(.specializeCompleted);失败 → errorRelay;远程 source mock → loadState `.unsupported`。
- `TypePickerPopoverViewModelTests`:搜索过滤即时生效;isGeneric candidate 标禁用;选中 emit didSelect。

UI(无自动化):手动验证清单

- SegmentedControl 在六种 (kind, isGeneric, isSpecialized) 组合下出现/隐藏正确
- Sheet 表单各 parameter 行布局正确,Choose Type popover 在按钮下方弹出
- TypePickerPopover 搜索过滤即时生效;isGeneric candidate 不可选(灰色 + tooltip)
- Specialize 成功后 sidebar 自动定位到新子节点;Content 显示替换后源码 + field offsets

### 文件清单

#### 新增文件

```
RuntimeViewerCore/Sources/RuntimeViewerCore/
    RuntimeEngine+GenericSpecialization.swift

RuntimeViewerPackages/Sources/RuntimeViewerApplication/Inspector/
    InspectorSwiftTypeViewModel.swift                  (从 InspectorClassViewModel 重命名拓宽)

RuntimeViewerPackages/Sources/RuntimeViewerApplication/Specialization/
    SpecializationSheetViewModel.swift
    TypePickerPopoverViewModel.swift

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/
    InspectorSwiftTypeViewController.swift             (从 InspectorClassViewController 重命名拓宽)

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/
    SpecializationRoute.swift
    SpecializationCoordinator.swift
    SpecializationSheetWindowController.swift
    SpecializationSheetViewController.swift
    TypePickerPopoverViewController.swift
```

#### 修改文件

```
RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObject.swift
    + Properties.isSpecialized

RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
    + lazy specializer
    + specializationRequest(for:) / specialize(for:with:)
    + makeRuntimeObject 拼接 specializedTypeDefinitions 为 children + 标 isSpecialized
    + interfaceByName 失效逻辑

RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
    + Error.imageNotIndexed / .specializationUnsupportedOnRemoteSource

RuntimeViewerPackages/Sources/RuntimeViewerApplication/Inspector/InspectorRoute.swift
    + case requestSpecializationSheet(RuntimeObject) / case selectRuntimeObject(RuntimeObject)

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/InspectorCoordinator.swift
    路由扩展 .swift(.type(_)) → InspectorSwiftTypeViewController
    实现 requestSpecializationSheet / selectRuntimeObject
    nested protocol Delegate

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
    实现 InspectorCoordinator.Delegate / SpecializationCoordinator.Delegate

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/InspectorClassHierarchyView.swift
    保留(被新 ViewController 嵌套使用)
```

UsingAppKit 的新 .swift 文件加入 Xcode project 通过 `xcodeproj` MCP 完成。SwiftPM 包内的新文件由 SwiftPM 自动发现。

## 替代方案考量

### A. 不新建子 RuntimeObject,仅在 Inspector 内显示特化结果

让 Specialize 把 `SpecializationResult` 的 metadata 直接渲染到 Inspector 的另一个 segment(field offsets 表格 / value witness 表格),不动 Content 区域、不改 sidebar。

被否决:失去"看到泛型参数被替换为具体类型"的核心 UX;与 Content 区域的源码渲染管道脱节;若未来扩展为多个特化对比,Inspector 局部表格不够延展。

### B. 在 RuntimeViewer 层做字符串 / SemanticString 替换

不依赖上游,RuntimeViewer 拿到原始 SemanticString 后自己识别 generic parameter token 替换。

被否决:SemanticString 是结构化的,手动重写损失 jump-to-definition;field offsets / size 仍需 metadata 调用,无法字符串替换得到;跨 module / 嵌套 generic 易错;渲染逻辑应放在 SwiftInterfacePrinter 而非 RuntimeViewer。

### C. 把特化历史持久化到磁盘

存到 `~/Library/Application Support/RuntimeViewer/Specializations/<documentID>.json`,跨 session 保留。

被否决(v1):`SpecializationSelection.Argument.metatype` 不可序列化;`.candidate` 依赖具体 image 在场,跨 session 不一定有效。可作为后续提案。

### D. Inspector 入口走 Content 工具栏 / 右键菜单

让 Specialize 入口在 Content 区域,而非 Inspector 的新 segment。

被否决:Inspector 是元信息归属地,Content 是源码归属地;特化触发是元信息层面动作。用户决策(2026-05-08)。

### E. OutlineView 双层 vs 列表 + Sheet + Popover

最初(2026-05-08)选择"Inspector 内 OutlineView 双层(Parameter→Candidate)+ 底部 Specialize 按钮"作为参数填写 UI,所有交互都在 Inspector 内完成。

后续(2026-05-09)改为"Inspector 内列表 + 触发主窗口 Sheet + Sheet 内 Pop-up + Pop-up 弹搜索 Popover":

- **表单空间充足** —— Sheet 是 Document Window 主窗口下拉,requirements / preflight 错误能完整展示
- **候选搜索体验** —— 候选可上千(`indexer.allTypeNames`),OutlineView 嵌套展开 + 滚动远不如 Popover 内 NSSearchField + NSTableView
- **模态隔离** —— Sheet 是清晰的"决定时刻",与 Inspector 内的"浏览态"分开
- **语义清爽** —— Inspector 主面板回归"已特化版本管理列表",符合"Inspector 是元信息归属地"

被否决的二级形态:Master-Detail 分栏(候选列表与 Parameter 选择都挤在 Inspector 内,空间不够);独立 Modal 类型选择器 sheet(双 sheet 嵌套体验差);NSMenu(NSPopUpButton 自带的 type-ahead 搜索体验差,候选无副信息展示)。详见决策日志 2026-05-09。

## 影响

- **破坏性变更**:无。`isSpecialized` 是新位,Inspector 重命名是内部类型。
- **受影响文件**:见上文文件清单。
- **是否需要迁移**:不需要。
- **性能影响**:特化注册路径异步;Popover candidate 列表可能上千,首次过滤需保证 60fps(用 NSDiffableDataSource 或 RxAppKit staged-changeset)。
- **跨仓库依赖**:**已就绪**。MachOSwiftSection 上游 API 在 `feature/specialized-type-definition` 分支已实现(commit `ee2a920`)。

## 决策日志

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-05-08 | 创建为 Draft | 起源于"为泛型 Swift 类型提供 field offset / metadata 视图"的需求 |
| 2026-05-08 | 入口放在 Inspector 新增 segment | Inspector 是元信息归属地;后续若要加 segment 也是顺势扩展。用户选项 |
| 2026-05-08 | 参数选择 UI 用 OutlineView 展开 candidates | (后被 2026-05-09 替代方案 E 推翻)候选数量大、附带信息多。用户选项 |
| 2026-05-08 | 特化结果新建一个 RuntimeObject 作为原泛型 RuntimeObject 的子节点 | 与 Content 渲染管道无缝衔接;sidebar 切换不同特化对比;天然支持 isSpecialized 后续扩展。用户选项 |
| 2026-05-08 | Document 内记忆,关闭丢(不持久化到磁盘) | v1 范围控制;.metatype argument 不可序列化。用户选项 |
| 2026-05-08 | 拓宽 InspectorClassViewController → InspectorSwiftTypeViewController + Segmented | 单一入口,Coordinator 路由分支少;Class Hierarchy 与新 Specialization 共享导航 stack。用户选项 |
| 2026-05-08 | 实施顺序:先 MachOSwiftSection 再 RuntimeViewer | 避免双方契约漂移和后期返工 |
| 2026-05-08 | 远程 source 在 v1 不支持特化 | `GenericSpecializer.specialize` 要求 MachO == MachOImage |
| 2026-05-08 | v1 不支持嵌套特化与 TypePack / Value generics | 上游显式拒绝 |
| 2026-05-09 | 上游 API 就绪:`TypeDefinition.specialize(with:in:)` + `specializedTypeDefinitions` + `metadata: MetadataWrapper?`(commit `ee2a920`) | RuntimeViewer 改用真实 API。先前契约里假设的 `registerSpecialization` / `SpecializationOrigin` 命名不再使用 —— 实际形态是"特化由 TypeDefinition 自身负责追加",`metadata` 取代 `specializationOrigin` 作为"是否特化"的判定 |
| 2026-05-09 | 砍掉 DocumentState.specializationHistory | 已特化版本本身就在 sidebar(由 indexer 持有),用户能直接通过 sidebar 浏览历史;"上次未完成的 selection prefill" 不在 v1 范围 |
| 2026-05-09 | UI 主形态从 OutlineView 双层 → 列表 + Sheet + Popover | 见替代方案 E。表单空间、搜索式候选选择、模态隔离三方面优势 |
| 2026-05-09 | Sheet 用 Document Window 主窗口 sheet(SceneCoordinator + WindowController 模式) | 与 ExportingCoordinator 一致,macOS 标准 modal sheet,空间足 |
| 2026-05-09 | 候选选择器用 Popover + NSSearchField + NSTableView | 候选可上千,搜索体验最好;比 NSMenu 强 |
| 2026-05-09 | 已特化版本列表行点击 → 改 documentState.selectedRuntimeObject(联动 Sidebar) | 全局联动一致;复用现有 selectedRuntimeObject 通道 |
| 2026-05-09 | 状态 Draft → In Progress | 上游 API ready,RuntimeViewer 侧开始实施 |

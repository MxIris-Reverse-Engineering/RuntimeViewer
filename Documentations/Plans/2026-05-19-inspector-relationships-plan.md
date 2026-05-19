# Inspector Relationships 实施计划

**日期:** 2026-05-19
**配套设计文档:** `2026-05-19-inspector-relationships-design.md`(原则、ADR、决策表、验收标准、非目标)

本文档列出 14 个有序实施步骤、每步的代码骨架与验证方法、UI 验证清单、构建命令、以及 Critic 在 v3 收敛时给出的 3 项实施期注意事项。

---

## Step 1:RuntimeViewerCore 新类型

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeRelationships.swift`(新增)

```swift
public struct RuntimeRelationships: Hashable, Sendable, Codable {
    public let subclasses: [RuntimeObject]
    public let conformingTypes: [RuntimeObject]

    public init(subclasses: [RuntimeObject], conformingTypes: [RuntimeObject]) { ... }

    public static let empty = RuntimeRelationships(subclasses: [], conformingTypes: [])
}
```

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

在 `CommandNames` 枚举(约 line 58,与 `case runtimeObjectHierarchy` 同位置)中追加:

```swift
case runtimeRelationshipsForObject
```

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectsLoadingProgress.swift`

在 `Phase` 枚举(当前末尾为 line 18 的 `case buildingObjects`)追加三个 case:

```swift
case indexingObjCSubclasses
case indexingObjCConformances
case indexingSwiftSubclasses
```

在 line 44–57 的 `description` switch 中添加:

```swift
case .indexingObjCSubclasses: return "Indexing Objective-C subclasses..."
case .indexingObjCConformances: return "Indexing Objective-C conformances..."
case .indexingSwiftSubclasses: return "Indexing Swift subclasses..."
```

**验证:** `swift build` 对 `RuntimeViewerCore` 成功;新结构体与 case 出现在模块表面。

---

## Step 2:`RuntimeObjCInterfaceIndexer`

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/Indexing/RuntimeObjCInterfaceIndexer.swift`(新文件,新目录)

```swift
public struct ObjCClassReference: Hashable, Sendable {
    public let className: String
    public let imagePath: String
    public let isSwiftStable: Bool
}

public final class RuntimeObjCInterfaceIndexer<MachO: MachORepresentable & Sendable>: Sendable {

    final class Storage: @unchecked Sendable {
        @Mutex var subclassesByClassName: [String: OrderedSet<ObjCClassReference>] = [:]
        @Mutex var conformingClassesByProtocolName: [String: OrderedSet<ObjCClassReference>] = [:]
        var subIndexers: [RuntimeObjCInterfaceIndexer<MachO>] = []
    }

    private let storage = Storage()
    private let eventHandler: RuntimeObjCInterfaceEvents.Handler?

    public init(eventHandler: RuntimeObjCInterfaceEvents.Handler? = nil) { ... }

    // Per-image feed (called from RuntimeObjCSection.prepare())
    public func index(class objcClass: ObjCClass, in machO: MachO, imagePath: String) throws
    public func index(category: ObjCCategory, in machO: MachO, imagePath: String) throws

    // Query
    public func subclasses(of className: String) -> [ObjCClassReference]
    public func conformingClasses(toProtocol protocolName: String) -> [ObjCClassReference]

    // Aggregation (mirror SwiftInterfaceIndexer.addSubIndexer)
    public func addSubIndexer(_ subIndexer: RuntimeObjCInterfaceIndexer<MachO>)
}

public enum RuntimeObjCInterfaceEvents {
    public struct Event: Sendable {
        public enum Kind: Sendable {
            case subclassIndexed(className: String, superclass: String, imagePath: String)
            case conformanceIndexed(className: String, protocolName: String, imagePath: String)
            case categoryConformanceIndexed(targetClassName: String, protocolName: String, imagePath: String)
        }
        public let kind: Kind
    }
    public typealias Handler = @Sendable (Event) -> Void
}
```

### 索引喂数据语义

- `index(class:in:imagePath:)`:读 `objcClass.superclass(in:)` → 将 `(superclass-name, ObjCClassReference(className: objcClass.name, imagePath, isSwiftStable: objcClass.isSwiftStable))` 写入 `subclassesByClassName`。读 `objcClass.protocols(in:)` → 对每个 adopted protocol,写入 `(protocolName, ref)` 到 `conformingClassesByProtocolName`。**该循环自动捕获 Swift 衍生类**,因为 `__objc_classlist` 对每个 `class Foo: NSObject` Swift 声明都会发射一条 `class_t` 记录;indexer 不需要任何 Swift 侧的知识来浮现这些类。
- `index(category:in:imagePath:)`:读 `category.protocols(in:)` 与 `category.classReference(in:)` → 将 `(protocolName, ObjCClassReference(className: targetClassName, imagePath, isSwiftStable: targetIsSwiftStable))` 写入 `conformingClassesByProtocolName`。Category 协议扩展了目标 class 的 conformance 集合。

`@Mutex`-保护的 `OrderedSet` 保留首次插入顺序,查询结果稳定。

**验证:** 单元测试构造 `Indexer`,手动喂入两条共享 superclass 的合成 class 记录,查询 `subclasses(of:)` 断言成员与顺序。

---

## Step 3:接入 `RuntimeObjCSectionFactory` 与 per-image `RuntimeObjCSection`

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift`

#### (a) Factory(现有 factory 段约 line 697–751)

在 `RuntimeObjCSectionFactory` 中添加属性:

```swift
public let objcInterfaceIndexer: RuntimeObjCInterfaceIndexer<MachOImage> = RuntimeObjCInterfaceIndexer()
```

在 factory 的 `section(for:)` 方法中,per-image 的 `RuntimeObjCSection` 构造完成后调用:

```swift
objcInterfaceIndexer.addSubIndexer(section.objcIndexer)
```

不需要 `await`:`section.objcIndexer` 声明为 `nonisolated let`(见下文 (b))。该调用与 `RuntimeSwiftSection.setupForFactory(_:)` → `factory.indexer.addSubIndexer(indexer)`(`RuntimeSwiftSection.swift:1186-1188`)精确对应。

#### (b) Per-image section

在 `RuntimeObjCSection` 中添加存储属性:

```swift
nonisolated let objcIndexer: RuntimeObjCInterfaceIndexer<MachOImage> = RuntimeObjCInterfaceIndexer()
```

`RuntimeObjCInterfaceIndexer` 是 `Sendable`,内部状态由 `@Mutex` 保护;`nonisolated` 引用方式与 `SwiftInterfaceIndexer` 通过 `factory.indexer` 跨 actor 边界引用的方式一致。可以在 actor 之外不 `await` 读取。

#### (c) 在 `prepare()` 中喂数据(现有 extraction 循环,line 194–264)

- 在 class 枚举循环内(line 194–217):构造完每个 `ObjCClassProtocol` / `ObjCClassGroup` 后,调用 `try objcIndexer.index(class: objcClass, in: machO, imagePath: imagePath)`。class 枚举循环开始处发出一次 `progressContinuation.yield(.init(phase: .indexingObjCSubclasses))`。
- 在 protocol 枚举循环内(line 219–233):indexer 没有 per-protocol 存储(协议作为 key 出现在 `conformingClassesByProtocolName` 中,由 adopting 类驱动);跳过。(协议本身的列举由 `.loadingObjCProtocols` 覆盖。)
- 在 category 枚举循环内(line 235–242):对每个 category 调用 `try objcIndexer.index(category: category, in: machO, imagePath: imagePath)`。Category 枚举循环开始处发出一次 `progressContinuation.yield(.init(phase: .indexingObjCConformances))`。

**验证:** 构建通过。Spot-check:用 `/System/Library/Frameworks/Foundation.framework/Foundation` 构造 `RuntimeObjCSection`,查询 `subclasses(of: "NSObject")`,确认结果同时包含 ObjC 子类(`NSArray`、`NSString`)和桥接到 ObjC 的 Swift 衍生子类。

---

## Step 4:`RuntimeSwiftSection` eager 子类反向表构建

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift`

#### (a) 存储(与其他 section 级状态同位置)

```swift
private var subclassesBySuperclassMangledName: [String: OrderedSet<String>] = [:]
```

Actor 隔离域已经串行化访问;此处不需要 `@Mutex`,加了反而会与 actor 隔离产生不良组合。对比 ObjC indexer 的存储:它位于 actor 之外,因此需要 `@Mutex`。

#### (b) 构建阶段 — 紧跟 line 217 的 `try await indexer.prepare()` 之后执行:

```swift
progressContinuation.yield(.init(phase: .indexingSwiftSubclasses))

for typeDefinition in indexer.allTypeDefinitions {
    guard case let classDescriptor as ClassDescriptor = typeDefinition.contextDescriptor else { continue }
    guard let superclassMangled = try? classDescriptor.superclassTypeMangledName(in: machO) else { continue }
    let childMangled = typeDefinition.mangledName
    subclassesBySuperclassMangledName[superclassMangled, default: OrderedSet()].append(childMangled)
}
```

构建时**不**判断「superclass 是 Swift 类还是 ObjC 类」。构建逐字记录所有 superclass mangled name。查询时无需分类,因为 engine 方法把 Swift-class 查询走该 map(以 Swift mangled name 为 key)、ObjC-class 查询走 ObjC indexer(以 ObjC class name 为 key),两路查询的 key 空间永不冲突。

#### (c) 公开查询方法(添加到 `RuntimeSwiftSection`)

```swift
public func subclasses(of superclassMangledName: String) -> [String] {
    subclassesBySuperclassMangledName[superclassMangledName]?.elements ?? []
}

public func conformingTypes(of protocolName: String) -> [String] {
    indexer.allConformingTypesByProtocolName[protocolName]?.map { $0.value.rawValue } ?? []
}
```

第二个方法复用现有的 `allConformingTypesByProtocolName`(由 `conformanceIndexingStarted/Completed` 事件构建),不需要 section 上的新存储。

#### (d) 提升 kind-mapping helper 到 internal

在 `RuntimeSwiftSection.swift:1206-1217`,把 `SwiftInterface.TypeName` 上的 `fileprivate var runtimeObjectKind: RuntimeObjectKind` 改为 `internal var runtimeObjectKind: RuntimeObjectKind`。如果 `SwiftInterface.ProtocolName.runtimeObjectKind` 或 `SwiftInterface.ExtensionName.runtimeObjectKindOfSwiftExtension` 也被 Step 5 的 `makeRuntimeObject` 用到,作同样的改动。这样 helper 才能被 `RuntimeEngine.makeRuntimeObject` 调用。

**验证:** 在含 `class Foo: Bar` 的二进制上,`section.subclasses(of: <Bar mangled>)` 包含 `<Foo mangled>`。在含 `struct S: P` 的二进制上,`section.conformingTypes(of: "P")` 包含 `"S"`。

---

## Step 5:Engine 方法

### 文件:`RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

#### 公开签名(添加在 `hierarchy(for:)` 之后,line 725–738 附近)

```swift
public func relationships(for object: RuntimeObject) async throws -> RuntimeRelationships
```

#### 私有 helper(添加到 `RuntimeEngine`)

```swift
private func makeRuntimeObject(name: String, imagePath: String, kind: RuntimeObjectKind) async -> RuntimeObject?
```

#### `makeRuntimeObject` 函数体,按 `kind` 分支:

- 对于 `.objc(.type(.class))` 或 `.objc(.type(.protocol))`:读 `objcSectionFactory.existingSection(for: imagePath)`;查 per-image class/protocol 缓存(`classes[name]` 用于 class,`protocols[name]` 用于 protocol — 即 `_objects(in:)` 在 `RuntimeEngine.swift:497-509` 使用的同一组 map);构造 `RuntimeObject(name:displayName:kind:secondaryKind:imagePath:children:)`,匹配 `_objects(in:)` 对同一条目的输出(注意:ObjC class 要传 `secondaryKind: objcClassGroup.objcClass.isSwiftStable ? .swift(.type(.class)) : nil`,参考 `RuntimeObjCSection.swift:322`)。
- 对于 `.swift(.type(.class))`、`.swift(.type(.struct))`、`.swift(.type(.enum))`、`.swift(.type(.protocol))`:读 `swiftSectionFactory.existingSection(for: imagePath)`;查 `indexer.allTypeDefinitions[TypeName(rawValue: name)]`(或 protocol map);构造一个 `RuntimeObject`,`displayName` 来自类型定义的 display string,`kind` 用传入的参数。
- 当 section 不存在、查找未命中、或 kind 不在以上集合时返回 `nil`。

#### `relationships(for:)` 函数体伪代码

1. **分类查询。**
   - 若 `object.kind` 不在 `{.objc(.type(.class)), .objc(.type(.protocol)), .swift(.type(.class)), .swift(.type(.protocol))}` 中,返回 `RuntimeRelationships.empty`。
   - 设 `wantsSubclasses = object.kind ∈ class kinds`;`wantsConformers = object.kind ∈ protocol kinds`。

2. **确定目标标识符。** 无合成名称桥接。
   - `objcKey: String?` — 当 `object.kind ∈ {.objc(.type(.class)), .objc(.type(.protocol))}` 时设为 `object.name`,**或者**当目标是一个在其定义 image 中有 ObjC 记录的 Swift class 时也设为 `object.name`。检测后者:读 `objcSectionFactory.existingSection(for: object.imagePath)?.classes[object.name]`,非空即说明 ObjC 记录存在。(覆盖 `class Foo: NSObject` 情况,无论是否标注 `@objc`,因为 Swift 编译器对任何有 ObjC 祖先的 class 都会发射 `__objc_classlist` 记录。)
   - `swiftMangledKey: String?` — 当 `object.kind` 是 Swift 且目标是 class 时设置。读 `swiftSectionFactory.existingSection(for: object.imagePath)?.indexer.allTypeDefinitions[TypeName(rawValue: object.name)]?.mangledName`。**绝不从 ObjC name 合成。**

3. **遍历 images 并联合结果。** 初始化两个 `OrderedSet<RuntimeObject>`(`subclasses`、`conformers`)。

   ```
   for imagePath in await loadedImagePaths where await isImageIndexed(path: imagePath):

       if wantsSubclasses:
           // ObjC 侧 — 对任何带 ObjC 记录的 class 类型目标执行。
           // 对纯 Swift class(无 objcKey),该分支跳过。
           if let objcKey {
               if let objcSection = await objcSectionFactory.existingSection(for: imagePath):
                   for ref in objcSection.objcIndexer.subclasses(of: objcKey):
                       let kind: RuntimeObjectKind = ref.isSwiftStable
                           ? .swift(.type(.class))
                           : .objc(.type(.class))
                       if let runtimeObject = await makeRuntimeObject(name: ref.className, imagePath: ref.imagePath, kind: kind):
                           subclasses.append(runtimeObject)
           }
           // Swift 侧 — 对任何 Swift class 目标执行。
           // 纯 Swift class 的纯 Swift 子类只在此处出现。
           // Swift 衍生的 ObjC 子类已被上面的 ObjC indexer 通过 __objc_classlist 捕获,
           // 因此当 objcKey != nil 时**不**走 Swift 反向表 — 否则会重复计入 Swift 衍生的 ObjC 子类。
           if let swiftMangledKey, objcKey == nil:
               if let swiftSection = await swiftSectionFactory.existingSection(for: imagePath):
                   for mangled in swiftSection.subclasses(of: swiftMangledKey):
                       guard let typeDefinition = swiftSection.indexer.allTypeDefinitions[…lookup by mangled…] else { continue }
                       let typeName = typeDefinition.typeName.name
                       let kind = typeDefinition.typeName.runtimeObjectKind  // Step 4(d) 中提升的 helper
                       if let runtimeObject = await makeRuntimeObject(name: typeName, imagePath: imagePath, kind: kind):
                           subclasses.append(runtimeObject)

       if wantsConformers:
           // ObjC 侧 — 用于 ObjC 协议。
           if object.kind == .objc(.type(.protocol)):
               if let objcSection = await objcSectionFactory.existingSection(for: imagePath):
                   for ref in objcSection.objcIndexer.conformingClasses(toProtocol: object.name):
                       let kind: RuntimeObjectKind = ref.isSwiftStable
                           ? .swift(.type(.class))
                           : .objc(.type(.class))
                       if let runtimeObject = await makeRuntimeObject(name: ref.className, imagePath: ref.imagePath, kind: kind):
                           conformers.append(runtimeObject)
           // Swift 侧 — 用于 Swift 协议。
           if object.kind == .swift(.type(.protocol)):
               if let swiftSection = await swiftSectionFactory.existingSection(for: imagePath):
                   for typeName in swiftSection.conformingTypes(of: object.name):
                       guard let typeDefinition = swiftSection.indexer.allTypeDefinitions[TypeName(rawValue: typeName)] else { continue }
                       let kind = typeDefinition.typeName.runtimeObjectKind
                       if let runtimeObject = await makeRuntimeObject(name: typeName, imagePath: imagePath, kind: kind):
                           conformers.append(runtimeObject)
   ```

   去重通过 `OrderedSet`(以 `RuntimeObject` 为 key,后者是 `Hashable`)。`isSwiftStable` filter 在每个 reference 上应用,把 bridged 类直接物化为 Swift `RuntimeObject`,因此 bridged 类只出现一次,kind 为 `.swift(.type(.class))`。

4. **按 `displayName` 排序**(case-insensitive, locale-aware)。

5. **返回** `RuntimeRelationships(subclasses: subclasses.elements, conformingTypes: conformers.elements)`。

### Bridge 注册

在 `RuntimeEngine.init` 的 line 335 附近(`setMessageHandlerBinding(forName: .runtimeObjectHierarchy, of: self) { $0.hierarchy(for:) }` 所在处)添加:

```swift
setMessageHandlerBinding(forName: .runtimeRelationshipsForObject, of: self) { $0.relationships(for:) }
```

### 远程派发

在 `RuntimeEngine.relationships(for:)` 函数体中,当运行在被代理的 engine 上时,沿用 `hierarchy(for:)`(line 736)的模式:

```swift
return try await $0.sendMessage(name: .runtimeRelationshipsForObject, request: object)
```

### Proxy server 注册

在 `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngineProxyServer.swift` 的 line 149 `.runtimeObjectHierarchy` handler 之后:

```swift
connection.setMessageHandler(name: RuntimeEngine.CommandNames.runtimeRelationshipsForObject.commandName) { (object: RuntimeObject) -> RuntimeRelationships in
    try await engine.relationships(for: object)
}
```

**验证:** 在本地索引了 Foundation 后,`engine.relationships(for: NSObjectRuntimeObject)` 返回的 `subclasses` 包含 `NSArray`、`NSString` 和已知的 Swift overlay 类。通过 proxy server,同一调用走 XPC 返回相同 payload(`Codable` 双向)。

---

## Step 6:Per-image scope 语义(跨 image 协议)

定义在 image A 的协议 `P` 可能在 image B 中有 conformer。Step 5 的查询遍历**所有** `loadedImagePaths`(由 `isImageIndexed` gate),跨 image 联合结果。目标 `RuntimeObject` 携带自己的 `imagePath`(定义 image),但搜索**不**限制在该单个 image。

在 `RuntimeEngine.relationships(for:)` 中加内联注释:

```swift
// The target object's `imagePath` is the *defining* image. Conformers
// and subclasses may live in *any* indexed image, so we iterate
// loadedImagePaths and union per-image results. Do not restrict to
// `object.imagePath` — that would miss cross-image conformers.
```

**验证:** Step 12 的测试 4 覆盖该路径:image B 中通过 category 采纳 image A 中协议的类应出现在结果中。

---

## Step 7:Inspector ViewModel

### 文件:`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Inspector/InspectorRelationshipsViewModel.swift`(新增)

```swift
public final class InspectorRelationshipsViewModel: ViewModel<InspectorRuntimeObjectRoute> {

    @Observed public private(set) var rows: [InspectorRelationshipsCellViewModel] = []
    @Observed public private(set) var sectionTitle: String = ""
    @Observed public private(set) var isEmpty: Bool = false
    @Observed public private(set) var emptyMessage: String = ""

    private let runtimeObject: RuntimeObject

    @MemberwiseInit(.public)
    public struct Input {
        let selectRelationshipClicked: Signal<InspectorRelationshipsCellViewModel>
    }

    public struct Output {
        let rows: Driver<[InspectorRelationshipsCellViewModel]>
        let sectionTitle: Driver<String>
        let isEmpty: Driver<Bool>
        let emptyMessage: Driver<String>
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: ...) { ... }

    public func transform(_ input: Input) -> Output {
        // 1. 同步根据 kind 设置 sectionTitle:
        //    - .objc(.type(.class)) | .swift(.type(.class))    -> "Subclasses"
        //    - .objc(.type(.protocol)) | .swift(.type(.protocol)) -> "Conforming Types"
        //
        // 2. 发起查询:
        //    Task { [weak self] in
        //        guard let self else { return }
        //        do {
        //            let result = try await documentState.runtimeEngine.relationships(for: runtimeObject)
        //            let payload = sectionTitle == "Subclasses" ? result.subclasses : result.conformingTypes
        //            await MainActor.run {
        //                self.rows = payload.map { InspectorRelationshipsCellViewModel(runtimeObject: $0) }
        //                self.isEmpty = payload.isEmpty
        //                self.emptyMessage = self.isEmpty
        //                    ? "No \(sectionTitle.lowercased()) found in indexed images."
        //                    : ""
        //            }
        //        } catch {
        //            await MainActor.run { self.errorRelay.accept(error) }
        //        }
        //    }
        //
        // 3. 接选择事件:
        input.selectRelationshipClicked.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            router.trigger(.selectRuntimeObject(cellViewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        return Output(
            rows: $rows.asDriver(),
            sectionTitle: $sectionTitle.asDriver(),
            isEmpty: $isEmpty.asDriver(),
            emptyMessage: $emptyMessage.asDriver()
        )
    }
}
```

`selectRuntimeObject` 路由 case 已经在 `InspectorRuntimeObjectRoute`(`InspectorRuntimeObjectCoordinator.swift:49`)存在,由 `InspectorClassViewModel` 在用户点击 superclass 时触发。直接复用,不要添加新 route case。

**验证:** 用 stub `DocumentState`(其 engine 返回固定的 `RuntimeRelationships`)单元测试实例化;对 class 与 protocol 输入断言 `rows`、`sectionTitle`、`isEmpty` 正确填充。

---

## Step 8:Inspector CellViewModel

### 文件:`RuntimeViewerPackages/Sources/RuntimeViewerApplication/Inspector/InspectorRelationshipsCellViewModel.swift`(新增)

```swift
public final class InspectorRelationshipsCellViewModel: NSObject, @unchecked Sendable {

    public let runtimeObject: RuntimeObject

    @Observed public private(set) var displayName: NSAttributedString
    @Observed public private(set) var icon: NSUIImage?

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        self.displayName = NSAttributedString {
            AText(runtimeObject.displayName)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
                .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
        }
        self.icon = runtimeObject.kind.icon  // 复用 RuntimeObjectKind 上的现有 helper
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension InspectorRelationshipsCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeObject { runtimeObject }
    public func isContentEqual(to source: InspectorRelationshipsCellViewModel) -> Bool {
        runtimeObject == source.runtimeObject
    }
}
#endif
```

**验证:** 单元测试断言两个 `runtimeObject` 相等的 cell view model 产生相等的 `differenceIdentifier` 和 `isContentEqual == true`。

---

## Step 9:Inspector ViewController

### 文件:`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/InspectorRelationshipsViewController.swift`(新增)

```swift
final class InspectorRelationshipsViewController: AppKitViewController<InspectorRelationshipsViewModel> {

    private let titleLabel = Label().then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
        $0.textColor = .secondaryLabelColor
    }
    private let emptyLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .tertiaryLabelColor
        $0.alignment = .center
    }
    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    override func loadView() {
        view = NSView()
        view.hierarchy {
            titleLabel
            scrollView
            emptyLabel
        }
        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.leading.trailing.equalToSuperview().inset(16)
        }
    }

    override func setupBindings(for viewModel: InspectorRelationshipsViewModel) {
        super.setupBindings(for: viewModel)

        let input = InspectorRelationshipsViewModel.Input(
            selectRelationshipClicked: tableView.rx
                .modelSelected(InspectorRelationshipsCellViewModel.self)
                .asSignal(onErrorSignalWith: .empty())
        )
        let output = viewModel.transform(input)

        output.rows
            .drive(tableView.rx.items) { (tableView, _, _, cellViewModel: InspectorRelationshipsCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RelationshipCellView.self)
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.sectionTitle.drive(titleLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.emptyMessage.drive(emptyLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.isEmpty.map { !$0 }.drive(emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)
        output.isEmpty.drive(scrollView.rx.isHidden).disposed(by: rx.disposeBag)
    }
}

extension InspectorRelationshipsViewController {
    fileprivate final class RelationshipCellView: TableCellView {
        private let iconImageView = ImageView()
        private let nameLabel = Label()

        override func setup() {
            super.setup()
            hierarchy {
                iconImageView
                nameLabel
            }
            iconImageView.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }
            nameLabel.snp.makeConstraints { make in
                make.leading.equalTo(iconImageView.snp.trailing).offset(6)
                make.trailing.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
            }
            nameLabel.maximumNumberOfLines = 1
        }

        func bind(to viewModel: InspectorRelationshipsCellViewModel) {
            rx.disposeBag = DisposeBag()
            viewModel.$displayName.asDriver().drive(nameLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
            viewModel.$icon.asDriver().drive(iconImageView.rx.image).disposed(by: rx.disposeBag)
        }
    }
}
```

**验证:** 按 Step 13 手动 UI 验证。

---

## Step 10:Tab 集成

### 文件:`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Inspector/InspectorRuntimeObjectCoordinator.swift`

#### (a) `InspectorRuntimeObjectRoute`(line 36–52 附近)添加:

```swift
case relationships
```

在 `prepareTransition(for:)` 中按 `.classHierarchy` 和 `.specialization` 的模式处理:

```swift
case .relationships:
    guard let index = tabConfiguration.relationshipsIndex else { return .none() }
    return .select(index: index)
```

#### (b) 扩展 `TabConfiguration`(line 92–105)

添加存储属性:

```swift
let needsRelationships: Bool
```

添加索引数学,替换现有的 `classHierarchyIndex` / `specializationIndex` 访问器为三 tab 感知的版本:

```swift
var classHierarchyIndex: Int? { needsClassHierarchy ? 0 : nil }

var relationshipsIndex: Int? {
    guard needsRelationships else { return nil }
    return needsClassHierarchy ? 1 : 0
}

var specializationIndex: Int? {
    guard needsSpecialization else { return nil }
    var index = 0
    if needsClassHierarchy { index += 1 }
    if needsRelationships { index += 1 }
    return index
}

var hasAnyTab: Bool { needsClassHierarchy || needsRelationships || needsSpecialization }
```

#### (c) 扩展 `TabConfiguration.compute(for:)`:

```swift
let needsRelationships: Bool = {
    switch runtimeObject.kind {
    case .objc(.type(.class)), .objc(.type(.protocol)),
         .swift(.type(.class)), .swift(.type(.protocol)):
        return true
    default:
        return false
    }
}()
```

#### (d) 扩展 `makeTabViewItems()`(现有方法 line 55–80)

当 `needsRelationships` 时插入 Relationships tab。Tab 顺序:`Class Hierarchy → Relationships → Specialization`。

```swift
if tabConfiguration.needsRelationships {
    let viewController = InspectorRelationshipsViewController()
    let viewModel = InspectorRelationshipsViewModel(
        runtimeObject: runtimeObject,
        documentState: documentState,
        router: self
    )
    viewController.setupBindings(for: viewModel)
    let tabItem = NSTabViewItem(viewController: viewController)
    tabItem.label = "Relationships"
    items.append(tabItem)
}
```

**验证:** 选中 class 时 Relationships 在 Class Hierarchy 和 Specialization 之间(`classHierarchyIndex == 0, relationshipsIndex == 1, specializationIndex == 2`)。选中无 Specialization 的 Swift class 时 `classHierarchyIndex == 0, relationshipsIndex == 1, specializationIndex == nil`。选中 struct/enum/extension 时无 Relationships tab。

---

## Step 11:Progress phase 接入

Step 1 声明的新 progress case 在以下位置 yield:

- `RuntimeObjCSection.prepare()` class 循环开始处:`progressContinuation.yield(.init(phase: .indexingObjCSubclasses))`。
- `RuntimeObjCSection.prepare()` category 循环开始处:`progressContinuation.yield(.init(phase: .indexingObjCConformances))`。
- `RuntimeSwiftSection.init` 中 `indexer.prepare()` 之后、反向表构建之前:`progressContinuation.yield(.init(phase: .indexingSwiftSubclasses))`。

(Swift conformance 索引 progress 已由 upstream `SwiftInterfaceIndexer` 通过 `conformanceIndexingStarted/Completed` 发出。)

**验证:** 手动打开大 framework 文档,观察 loading 指示器中三个新 phase 字符串闪过。

---

## Step 12:测试

### 文件:`RuntimeViewerCore/Tests/RuntimeViewerCoreTests/RelationshipsTests.swift`(新增)

Target:`RuntimeViewerCoreTests`(已存在,位于 `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/`)。**无 `Package.swift` 改动。无新 test target。无 fixture 二进制。**

测试针对加载到测试进程的真实系统 framework 进行断言。每个测试通过读取 framework 的当前内容固定预期结果(锚定到稳定、跨 macOS 版本不变的 API):

1. **同 image 内的 Swift 子类。** 加载 `/System/Library/Frameworks/Foundation.framework/Foundation`。索引。查询 Foundation 中有已知 overlay 子类的 Swift class(在实现期通过枚举 `swiftSection.allTypeDefinitions` 找到 `subclassesBySuperclassMangledName[mangled]` 非空者确定 anchor)。断言至少返回一个子类。
2. **ObjC 子类合并。** 加载 Foundation。断言 `relationships(for: NSObject).subclasses` 非空且包含 `NSArray`、`NSString`、`NSDictionary`(这些类从最早的 NeXTSTEP 起就存在,在项目支持的每个 macOS 版本中都在)。
3. **Swift 协议遵守。** 加载 Foundation。选一个有已知 conformer 的 Foundation Swift 协议(如 `LocalizedError`)。断言 `engine.relationships(for: LocalizedError).conformingTypes` 返回的 conformer 集合精确等于该 image 上 `swiftSection.conformingTypes(of: "LocalizedError")`,证明 engine 方法正确复用 indexer。
4. **带 category conformer 的 ObjC 协议。** 加载 Foundation + `/usr/lib/libobjc.A.dylib`。选 `NSCoding`。断言至少有一个类通过 category 采纳(通过检查 `objcIndexer.conformingClasses(toProtocol: "NSCoding")` 中 owning image 的 category 列表采纳了该协议来验证 — 测试断言 engine 方法的结果是 inline-adoption 集合的超集,证明 category 被捕获)。
5. **未索引 image 排除。** 加载 Foundation + SwiftUI。只索引 Foundation。构造一个属于 Foundation(已索引)的 `RuntimeObject`(`NSObject`)。调用 `engine.relationships(for: NSObject)`。断言返回的 `subclasses` 排除所有 `imagePath` 匹配 SwiftUI 路径的类。调用不抛出。
6. **`isSwiftStable` 去重。** 加载 Foundation。选一个 Swift overlay 中已知的 `@objc class`(测试在运行时通过扫描 `objcSection.classes` 寻找 `objcClass.isSwiftStable == true` 的条目找到一个 anchor,断言扫描至少产生一个 — Foundation 的 Swift overlay 中有这类条目)。查询 `relationships(for: <某 ObjC 根类>).subclasses`。断言 bridged 类只出现一次,且该次出现的 `kind == .swift(.type(.class))`。
7. **Transitive 排除(A5)。** 计划阶段已验证 Swift 编译器对每个 `class C: P` 声明发射单条 `ProtocolConformanceDescriptor` 记录。`SwiftInterfaceIndexer.indexConformances()`(`RuntimeViewerCore/.build/checkouts/MachOSwiftSection/Sources/SwiftInterface/SwiftInterfaceIndexer.swift:422-446`)逐条遍历 `currentStorage.protocolConformances` 并写入 `conformingTypesByProtocolName[protocolName].append(typeName)`,无传递合成。测试断言:对 Foundation/SwiftUI 中已知的 `protocol P: Q` 与 `class C: P` 案例(anchor 通过扫描 indexer 的 `protocolDefinitions` 中 `requiredProtocols` 非空的协议确定),`engine.relationships(for: Q).conformingTypes` 不包含 `C`。

**验证:** `swift test --filter RelationshipsTests` 全部 7 个测试通过。

---

## Step 13:UI 验证清单

打开一份 RuntimeViewer 文档,执行:

1. 加载 `/System/Library/Frameworks/Foundation.framework/Foundation`(ObjC + Swift overlay)和 `/System/Library/Frameworks/SwiftUI.framework/SwiftUI`(Swift)。
2. 通过 sidebar 操作对两个 image 触发索引。
3. 在 sidebar 中选中 `NSObject`:
   - Relationships tab 在 Class Hierarchy 和 Specialization 之间可见。
   - section title 显示「Subclasses」。
   - 列表非空,包含 ObjC 条目(如 `NSArray`)和 Swift overlay 条目。
   - 点击 `NSArray` 在 sidebar 中选中该项。
4. 选中 `NSCoding`(ObjC 协议):
   - section title 显示「Conforming Types」。
   - 列表包含所有已索引 image 中的 conformer,含通过 category 采纳的 conformer。
5. 选中一个 Swift class(例如 SwiftUI 中的 `View`):
   - 已索引 image 中存在子类时显示子类,否则空态显示「No subclasses found in indexed images.」。
6. 选中一个 Swift 协议(例如 `Identifiable`):
   - 显示 conformer 列表。
7. 选中 struct、enum、extension、category:
   - Relationships tab **不可见**。

**验证:** 手动视觉确认。每个步骤截图至 `Documentations/Plans/inspector-relationships-screenshots/` 作为证据。

---

## Step 14:构建验证

按顺序执行(命令用 `&&` 链接,因为它们顺序相依):

```bash
swift package update --package-path /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && \
swift package update --package-path /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerPackages
```

Workspace 构建。规范构建路径是同级目录的 workspace `/Volumes/Code/Personal/MxIris-Reverse-Engineering.xcworkspace`,它把 MachOKit / MachOObjCSection / MachOSwiftSection 的本地 checkout 串起来。该 workspace 按项目 CLAUDE.md 是必备构建产物。

```bash
xcodebuild build \
  -workspace /Volumes/Code/Personal/MxIris-Reverse-Engineering.xcworkspace \
  -scheme RuntimeViewerUsingAppKit \
  -configuration Debug \
  -destination 'generic/platform=macOS' 2>&1 | xcsift
```

测试:

```bash
xcodebuild test \
  -workspace /Volumes/Code/Personal/MxIris-Reverse-Engineering.xcworkspace \
  -scheme RuntimeViewerCore-Package \
  -only-testing:RuntimeViewerCoreTests/RelationshipsTests 2>&1 | xcsift
```

**验证:** 构建绿。全部 7 个测试通过。

---

## 实施期注意事项(来自 Critic v3)

这些是非阻塞的实施期注意事项,在 Step 5 与 Step 12 实施过程中处理。

### W1. 把 `RuntimeSwiftSection.indexer` 提升为 `internal`

Step 5 的 `makeRuntimeObject` 函数体和 per-image `swiftMangledKey` 查找都要访问 `swiftSection.indexer.allTypeDefinitions[…]`。`RuntimeSwiftSection.swift:67` 当前声明为 `private var indexer`。把它改成 `internal var indexer`(若可以,改成 `internal let indexer` 更好)。与 Step 4(d) 中 `runtimeObjectKind` 的提升对称。同模块(`RuntimeViewerCore`),`internal` 足够。

更干净的替代:在 `RuntimeSwiftSection` 上扩展公开方法 `func typeDefinitionRuntimeObjectKind(forMangledName:) -> RuntimeObjectKind?`,封装 `allTypeDefinitions` 查找和 `runtimeObjectKind` 映射,这样根本不向 engine 方法暴露 `indexer`。两种形态都可接受。

### W2. 增加 Test 8 — 三层链(Bridged class 的 Swift 子类)去重

当前 AC6 覆盖了 bridged 类去重(`@objc class Foo: NSObject` 只出现一次,kind 为 `.swift(.type(.class))`)。增加一个针对三层链的互补测试:`class Bar: Foo`,其中 `Foo: NSObject`。`Foo` 和 `Bar` 都有 `class_t` 记录(Bar 的 superclass `class_t` 指向 Foo)。断言 `relationships(for: Foo).subclasses` 恰好包含一次 `Bar`,且 kind 正确,即使 ObjC indexer 通过 `Bar.objcClass.superclass(in:) == Foo.objcClass` 浮现它,而 Swift 反向表也可能通过 `Bar.superclassTypeMangledName == Foo.mangledName` 浮现它。Step 5 line 274 的 `OrderedSet<RuntimeObject>` 去重已经强制了该不变量,测试把该不变量显式化。

Anchor 候选:Foundation overlay 中任何根在 `NSObject` 的二层 Swift 子类链。用 Test 1 的运行时发现扫描模式;若未找到二层链,通过 `XCTSkipIf` 跳过。

### W3. ObjC 分支的 `makeRuntimeObject` 使用默认 `properties`

Architect v3 指出 Step 5 line 260 写「matching what `_objects(in:)` emits」,但未明确说明 `properties:` 的处理。在 `RuntimeObjCSection.swift:321-322` 确认:ObjC class 发射的 `RuntimeObject` **不**传 `properties:` 参数 — 使用默认空值。Swift 分支在 `RuntimeSwiftSection.swift:484` 中**会**填充 `properties`(如 `.isGeneric`、`.isSpecialized`)。执行者:仔细阅读 `_objects(in:)`,精确镜像它对每个 kind 的参数列表。ObjC class/protocol 分支不传 `properties:`;Swift class/struct/enum/protocol 分支传(来源于 Swift 类型定义)。

### W4. 运行时发现 anchor 的测试用 `XCTSkipIf` 包裹

对 Step 12 中所有运行时发现 anchor 的测试(Test 1 枚举、Test 6 扫描、Test 7 transitive 扫描,以及新增的 Test 8),把发现步骤包在 `try XCTSkipIf(matches.isEmpty, "no anchor type found in indexed image; skipping")` 内。这把「发现返回零」转换为 skip 而非假阴性失败 — 对未来重排 Foundation overlay 的 macOS 版本鲁棒。

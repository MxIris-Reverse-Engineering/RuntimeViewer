# 0004 - DifferentiableBox 与 Lazy Cell ViewModel 渲染范式

- **状态**: Draft
- **作者**: JH
- **日期**: 2026-05-18
- **最后更新**: 2026-05-18
- **关联**: `Documentations/Plans/specialization-typepicker-perf-r2.md`(本提案的首个落地场景)

## 摘要

在 `RuntimeViewerArchitectures` 引入泛型轻量结构 `DifferentiableBox<Model>`,把任意 `Hashable` 领域模型适配为 DifferenceKit `Differentiable`,使 `NSTableView` / `NSOutlineView` 的 `rx.items` / `rx.nodes` 数据源可以以"轻量身份元素 + cell 渲染时 lazy 构造 cellViewModel"的方式工作。配套沉淀一条命名清晰的 **Lazy Cell VM** 渲染范式,扩展 CLAUDE.md 的 "NSTableView / NSOutlineView Rx Data Source" 章节,作为大数据集 (典型 N >= 1k) 场景下的可选模式;同时显式标注其**适用边界**——仅适用于 cellViewModel 在 init 后状态不再变化的"一次性输出"型 cell。

## 动机

CLAUDE.md 在 "NSTableView / NSOutlineView Rx Data Source" 段落约定了 cell ViewModel wrapper / `box.makeView(ofClass:)` / `Differentiable` conform 的统一形态,该约定对**小到中等数据集**(N <= 数百)是合理的——cellViewModel 构造代价分摊到每行只有几十微秒,eager 全集构造无可观察延迟。

但当数据规模上一个量级(N >= 1k),eager 构造模式会暴露两类性能问题:

1. **driver 数组本身的构造成本** —— 即使 `NSTableView` 只渲染可视区域 ~12 行,喂给 `tableView.rx.items` 的数组必须是全集。该数组若由"重 cellViewModel"组成,init 阶段必须把 N 个 cellViewModel 全部 alloc 完才能赋给 driver。
2. **重 cellViewModel 的隐含开销** —— 项目内 cellViewModel 普遍含若干 `@Observed`(即 `BehaviorRelay`)+ `NSAttributedString` builder + icon cache lookup。单个 init ~50-150 µs;10k 行 = 500-1500 ms 主线程阻塞。

`SpecializationTypePickerViewModel` 是该模式的直接受害者:无约束泛型参数(如 `Array<T>`)的候选集合 = 当前镜像全部加载类型,实测可达 10k+ 量级,导致 popover 打开瞬间主线程冻结。详见关联 plan。

类似量级的场景在仓库内**有先例**:`SidebarRootViewModel` 在 `ConcurrentDispatchQueueScheduler(qos: .userInteractive)` 上构造整棵 cellViewModel 树,已经把"构造代价异步化"做掉了——但那是另一条路(eager + off-main),代价是 cellViewModel 必须 `Sendable` 安全且每次数据变化都要重跑全集构造。后续若再出现"数据集大 + 数据 mostly static + cellViewModel 完全由模型派生"的场景(典型如:类型选择 popover、framework 浏览、symbol 跳转列表等),需要一个**与 NSTableView 自身 lazy 渲染语义对齐**的统一模式,而不是每个模块各自发明 wrapper。

把"本地包一层 Hashable model 为 Differentiable"提升为通用工具,有四个收益:

- **单点维护** —— `Differentiable` conform 的写法、`#if canImport(AppKit) && !targetEnvironment(macCatalyst)` 平台保护、`differenceIdentifier` / `isContentEqual` 默认实现全部在一处定义,后续若 DifferenceKit / DifferenceKit-Swift 6 重命名 API 只改一处。
- **强制适用边界文档化** —— 通过 `DifferentiableBox` 文件顶部的 docstring,把"何时该用 lazy cellVM 模式 / 何时绝对不能用"写在 API 表面,避免误用。
- **CLAUDE.md 约定的合规性** —— 该约定明文禁止跨包 retroactive `Differentiable` 扩展(`extension RuntimeObject: @retroactive Differentiable {}` 等)。`DifferentiableBox<Model>` 作为本地泛型 wrapper,既能装任何跨包 `Hashable` 模型,又不破坏该约定。
- **与现有 cellViewModel 约定共存** —— 不取消 `XxxCellViewModel: Differentiable` 现有写法(Sidebar / Inspector 多处已用),只是给"大数据集 + static cellVM"开一条额外路径。

### 非目标

- **不**重构 Sidebar / Inspector 既有 cellViewModel 数据源 —— 它们多数 cellViewModel 持有跨数据周期的 `@Observed` 订阅,不在 lazy 模式适用范围。
- **不**在 `DifferentiableBox` 上叠加额外功能(如选中状态、filter 高亮 metadata、动画 hint)—— 若某模块需要 row 层 mutable 状态,应自建本地 struct conform `Differentiable`,而非给通用 wrapper 加字段。这是 invariant 不是 limitation。
- **不**引入新的 `tableView.rx.items` 适配器或新的 cell 复用机制 —— RxAppKit 现有 `rx.items` / `rx.nodes` + `box.makeView(ofClass:)` 已足够支撑该模式,本提案只是在数据层包一层 wrapper。
- **不**为该模式编写自动化滚动 / lazy 重建测试基础设施 —— 性能验证沿用 Instruments + `os_signpost`,与已有 `RuntimeViewerCore` test 套件不耦合。
- **不**修改 DifferenceKit 依赖版本或引入新的 diff 算法。
- **不**支持 SwiftUI / Combine 路径 —— 项目核心 UI 栈是 AppKit + RxSwift,SwiftUI 仅限 Settings(CLAUDE.md 硬约束)。

## 提议方案

### API 设计

新增文件 `RuntimeViewerPackages/Sources/RuntimeViewerArchitectures/DifferentiableBox.swift`:

```swift
import Foundation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import DifferenceKit
#endif

/// Lightweight value wrapper that lifts any `Hashable` model into a row
/// element suitable for `tableView.rx.items` / `outlineView.rx.nodes`,
/// so per-row `cellViewModel` instances can be constructed lazily inside
/// the cell builder closure rather than eagerly at data-source init time.
///
/// ## When to use
///
/// - Data set is large (N >= ~1k) and eager `cellViewModel` construction
///   shows up as a main-thread bottleneck in Instruments.
/// - The `cellViewModel`'s state is **fully determined at init time** from
///   the model alone and does **not** subscribe to any ongoing state
///   (no `@Observed` properties that mutate after init, no Rx pipelines
///   fed by external sources, no async loading).
///
/// ## When NOT to use
///
/// - `cellViewModel` owns long-lived subscriptions or mutable `@Observed`
///   state that updates over the row's lifetime — e.g. Sidebar's
///   filter-aware attributed name, Inspector's async metadata loading.
///   Lazy reconstruction discards subscription identity; downstream
///   observers attached to the previous instance get dropped on the floor.
/// - The model has fewer than ~hundreds of rows. Eager `cellViewModel`
///   construction is already cheap; the wrapper just adds indirection.
/// - You need per-row UI state that cannot be derived from the model
///   (e.g. expanded/collapsed flag, multi-select checkmark, drag preview).
///   Build a local struct conforming to `Differentiable` directly instead
///   of extending this wrapper — adding mutable fields here breaks the
///   identity invariant for every other consumer.
///
/// ## Identity contract
///
/// `differenceIdentifier == model` and `isContentEqual` compares the
/// underlying model by `==`. This means **two `DifferentiableBox<Model>` values
/// are considered the same row iff their models are `==`-equal**. If
/// `Model` is a value type whose equality includes presentation-only
/// fields, those fields will spuriously trigger `Changeset` updates.
/// Choose `Model`'s `Equatable` / `Hashable` carefully — typically a
/// domain primary key.
public struct DifferentiableBox<Model: Hashable>: Hashable {
    public let model: Model

    public init(_ model: Model) {
        self.model = model
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension DifferentiableBox: Differentiable {
    public var differenceIdentifier: Model { model }

    public func isContentEqual(to source: DifferentiableBox<Model>) -> Bool {
        model == source.model
    }
}
#endif
```

设计要点:

1. **`struct` 而非 `class`** —— 值语义,N=10k 全集构造仅是 N 次 struct 拷贝(每个含 1 个 `let model`),无 alloc 开销;`Sendable` 自动推导(`Model: Hashable + Sendable` 时整体 `Sendable`)。
2. **`differenceIdentifier: Model` 而非 `differenceIdentifier: Self`** —— 由 `Model` 的 `Hashable` 提供身份;若 `Model` 实例间 `==` 相等(典型如同一 mangled name 的 candidate),DifferenceKit 会判定为"同一行"而非"删除+插入"。
3. **不暴露 `init()` 默认值** —— 强制调用方显式传入 model,避免 "空 row" 隐式存在。
4. **`#if canImport(AppKit) && !targetEnvironment(macCatalyst)` 保护** —— DifferenceKit 在该 plan 下只对 AppKit 平台开放(与 `SpecializationTypePickerCellViewModel: Differentiable` 现有保护一致);UIKit / Catalyst 下 `DifferentiableBox` 仍可用作 `Hashable` 容器,但失去 DifferenceKit conform。

### Lazy Cell ViewModel 渲染范式

调用方按以下范式接入:

```swift
// ViewModel
typealias CandidateBox = DifferentiableBox<RuntimeSpecializationRequest.Candidate>

@Observed
public private(set) var filteredRows: [CandidateBox] = []

// init
let allRows = candidates.sorted().map(CandidateBox.init)
filteredRows = allRows

// ViewController
output.filteredRows
    .drive(tableView.rx.items) { (tableView, _, _, row: CandidateBox) -> NSView? in
        let cellView = tableView.box.makeView(ofClass: SomeCellView.self)
        let cellViewModel = SpecializationTypePickerCellViewModel(candidate: row.model)
        cellView.bind(to: cellViewModel)
        return cellView
    }
    .disposed(by: rx.disposeBag)
```

与现有 CLAUDE.md "NSTableView / NSOutlineView Rx Data Source" 约定对比:

| 维度 | 现行 eager 模式 | Lazy Cell VM 模式(本提案) |
|---|---|---|
| `rx.items` 数组元素 | `[XxxCellViewModel]` | `[DifferentiableBox<Model>]` |
| cellViewModel 构造时机 | ViewModel init 全集 alloc | cell builder 闭包内按需 alloc |
| `Differentiable` conform 位置 | cellViewModel 自身 | `DifferentiableBox` |
| 适合 cellViewModel 类型 | stateful(含 ongoing `@Observed`) | static(init 后状态不变) |
| 适合数据规模 | 任意 | 推荐 N >= 1k |
| `Output` 字段类型 | `Driver<[XxxCellViewModel]>` | `Driver<[DifferentiableBox<Model>]>` |
| Input 点击 Signal | `Signal<XxxCellViewModel>` | `Signal<DifferentiableBox<Model>>` |

### 适用 / 反模式案例

**适用案例 #1: SpecializationTypePickerViewModel(本提案首落地)**

- N 可达 10k+(无约束泛型参数)
- `SpecializationTypePickerCellViewModel` 在 init `:50-70` 一次性同步赋值 `primaryIcon` / `secondaryIcon` / `title` / `subtitle`,之后从不刷新
- 完全符合 lazy 模式条件

**适用案例 #2: 未来的 framework / symbol 浏览 popover**(假设场景)

- 数据来自 `RuntimeEngine` 一次性 dump
- cellViewModel 只显示 symbol name + icon,无后续 mutation
- 符合 lazy 模式

**反模式案例 #1: SidebarRuntimeObjectCellViewModel**

- 含 `@Observed displayName: NSAttributedString` 会响应 filter / search 持续刷新
- 若 lazy 重建,filter 一变化 cellViewModel 整体被丢弃重建,subscription 失效,attributed name 不会刷新
- **必须保留 eager 1:1 长寿命 cellViewModel 数组**(即 Sidebar 现状)

**反模式案例 #2: 含异步加载状态的 cell**

- 例如 cellViewModel 在 init 后 `Task { let icon = await loadIcon(...); self.icon = icon }`
- lazy 重建后异步 Task 仍 reference 老 cellViewModel,新 cellViewModel 永远拿不到 icon
- 必须 eager

### 关联落地: SpecializationTypePicker

本提案通过后,SpecializationTypePicker 性能优化(详见 `Documentations/Plans/specialization-typepicker-perf-r2.md`)的 Phase 2 直接使用 `DifferentiableBox<RuntimeSpecializationRequest.Candidate>` 作为 driver 元素类型,在 Specialization 模块内 `typealias CandidateBox = DifferentiableBox<...>` 取本地短别名:

```swift
// RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/CandidateBox.swift
typealias CandidateBox = DifferentiableBox<RuntimeSpecializationRequest.Candidate>
```

不再新建具体 `struct CandidateBox` —— 减少一次抽象层。

### CLAUDE.md 更新

在 "NSTableView / NSOutlineView Rx Data Source" 段落末尾追加一个 "9. Lazy Cell ViewModel for large data sets" 小节,内容包括:

- 何时考虑该模式(N 量级 + cellVM 状态特征)
- 必须验证的反模式条件(cellVM 不能含 ongoing `@Observed` / 异步加载)
- 示例代码(就用 SpecializationTypePicker 作为 canonical example)
- 与 eager 模式的判别决策树

不修改前 8 个 sub-section(它们都是 cellVM 1:1 模式的标准做法)。

## 风险与假设

### 风险

1. **被误用为通用"懒加载"工具** —— 用户看到名字 `DifferentiableBox` + 简洁 API,可能在 stateful cellVM 场景套用,导致 UI 不响应数据变化。**Mitigation**: docstring 中 "When NOT to use" 段落明确列三条反模式;PR review 模板中加一条 "是否含 ongoing `@Observed`?"。
2. **`Model` 的 `Equatable` 含 presentation 字段导致 diff 抖动** —— 若 `Model` 实例间 `==` 包含非身份字段(如格式化后的 displayName),DifferenceKit 会把"内容刷新"误判为"行替换",DiffKit 算 changeset 时仍会 emit update event。**Mitigation**: docstring "Identity contract" 段落显式说明,推荐使用 primary key 类型作为 `Model`,或在 `Model` 自身的 `Equatable` 上做精确控制。
3. **跨 Swift 版本 / DifferenceKit 升级断裂** —— 若上游 DifferenceKit 重命名 `differenceIdentifier` / `isContentEqual`,所有调用方需要同步改。**Mitigation**: 集中在 `DifferentiableBox` 一处,只改一处即可。
4. **lazy 模式下滚动期间反复 alloc cellViewModel** —— NSTableView 复用 cell view 但不复用 cellViewModel,快速滚动时每行触发新 cellVM 构造。**Mitigation**: 已在关联 plan 的 R-7 量化为 ~50-150 µs/cell × 100 行 = 5-15 ms,<16 ms 单帧;若实测超出,优先做 cellVM 内部延后 (`NSAttributedString` 移至 `bind(to:)`),不在 `DifferentiableBox` 层加 cache。

### 假设

1. **`Model` 类型稳定的 `Hashable` 实现** —— 假定调用方传入的 `Model` 在 popover / 列表生命周期内 hash 稳定。本提案不强制 `Model` 是 reference type(struct/enum 均可),只要 `Hashable` 实现可信。
2. **DifferenceKit 在 AppKit 平台可用** —— 已通过 `RuntimeViewerArchitectures` 现有依赖确认;UIKit / Catalyst 因 `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` 保护不受影响。
3. **`RuntimeViewerArchitectures` 是新通用工具的合适归宿** —— 该 package 当前承载 ViewModel 基类 / Coordinator 基类 / Router 抽象等基础设施。`DifferentiableBox` 属同层。
4. **不需要 `Identifiable` conform** —— Swift `Identifiable` 协议要求 `id: Hashable` 但 ID 类型可与 model 类型不同;DifferenceKit 直接需要 `Differentiable.differenceIdentifier`,二者目标重叠但不强制对齐。本提案先不加 `Identifiable` conform,后续若 SwiftUI 互操作有需要再补。

### 测试策略

- **类型 / 编译级**: `RuntimeViewerArchitectures` 包内加 unit test `DifferentiableBoxTests`:
  - `DifferentiableBox<Int>(42).differenceIdentifier == 42`
  - 两个相同 model 的 `DifferentiableBox` 实例 `isContentEqual = true`
  - 不同 model `isContentEqual = false`
  - `DifferentiableBox<Int>: Hashable` 在 `Set` / `Dictionary` 中行为正常
- **性能级**: 本提案不引入性能基准 —— 性能验证由调用方负责(关联 plan 的 Phase 0 baseline + Phase 2 AC-1/AC-2/AC-9)
- **UI 级**: 手测 SpecializationTypePicker 在 Phase 2 落地后的行为(详见关联 plan AC 列表)

### 文件清单

#### 新增文件

```
RuntimeViewerPackages/Sources/RuntimeViewerArchitectures/
    DifferentiableBox.swift

RuntimeViewerPackages/Tests/RuntimeViewerArchitecturesTests/
    DifferentiableBoxTests.swift
```

#### 修改文件

```
CLAUDE.md
    新增小节 "9. Lazy Cell ViewModel for large data sets"

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/
    CandidateBox.swift                          (新增,但仅是 typealias 文件)
    SpecializationTypePickerViewModel.swift     (Phase 2 落地)
    SpecializationTypePickerViewController.swift(Phase 2 落地)
```

## 替代方案考量

### A. 不抽象,继续每个模块本地写 `struct CandidateBox`

让 Specialization 直接定义 `struct CandidateBox: Hashable + Differentiable`,不上移到 Architectures。

被否决:未来任何模块复用同一模式都要写一遍相同的 conformance 代码;`Differentiable` 的 `#if canImport(...)` 平台保护、`differenceIdentifier` / `isContentEqual` 默认实现都要重复;不利于把"适用边界"集中文档化(每个模块文件顶部 docstring 总会有人忽略掉)。

### B. Protocol-only 方案:`protocol DiffableRow: Differentiable { associatedtype Model: Hashable; var model: Model { get } }`

```swift
public protocol DiffableRow: Differentiable {
    associatedtype Model: Hashable
    var model: Model { get }
}
extension DiffableRow {
    public var differenceIdentifier: Model { model }
    public func isContentEqual(to source: Self) -> Bool { model == source.model }
}
```

调用方仍需写 `struct CandidateBox: DiffableRow { let model: Candidate }`。

被否决:相对于泛型 `DifferentiableBox<Model>` 多了一层 boilerplate(每个模块一个 struct);命名权"留给调用方"带来收益微弱,因为 `DifferentiableBox<Candidate>` + `typealias CandidateBox = DifferentiableBox<Candidate>` 已经能给出短别名;`associatedtype` 在跨模块使用时偶尔会卡 type inference,不如直接泛型清晰。

### C. 把 cellViewModel cache 放进 `DifferentiableBox`

让 `DifferentiableBox` 在内部持有一个 `weak var cellViewModel: AnyObject?`,首次构造时缓存,再次访问时复用。

被否决:`DifferentiableBox` 是值类型,加 weak 引用就要转 class,失去结构性优势;cache 应该放在更上层(NSCache / Dictionary on ViewModel),且只在性能实测后再加(R-7 当前估算不需要,YAGNI);把 cache 耦合进 wrapper 让"何时清理"语义变得复杂(用户切换 query → 整个 driver 数组重建 → 老 DifferentiableBox 全部 release → cellViewModel 跟着 release → 真正用户继续浏览时 cache 完全 miss),反而退化为 eager 模式。

### D. 使用 Swift `Identifiable` 而非 `DifferentiableBox`

直接 `extension SomeModel: Identifiable + Differentiable {}`,不引入 wrapper。

被否决:CLAUDE.md 明文禁止跨包 retroactive `Differentiable` —— 本提案核心动机之一就是合规规避该禁令;`Identifiable` 与 `Differentiable` 是两个独立协议,即使 model 已经 `Identifiable`,DifferenceKit 仍需要单独 conform。

### E. 使用 swift-collections 的 `Identified<ID, Value>` 或 swift-identified-collections

引入 third-party `Identified<...>` 类型作为通用 wrapper。

被否决:引入新依赖与 CLAUDE.md "不引入新第三方依赖" 隐性约束相悖;`DifferentiableBox` 实现仅 ~30 行,自建成本远低于依赖管理成本;`swift-identified-collections` 的设计目标是 `IdentifiedArray` 集合类型,与本提案的"单行 wrapper"目标不完全对齐。

## 落地步骤

按以下顺序独立 commit:

1. **Step 1 (本提案)**: 创建 `RuntimeViewerArchitectures/DifferentiableBox.swift` + `DifferentiableBoxTests` + CLAUDE.md 新小节;`swift build` / `swift test` 通过
2. **Step 2 (关联 plan Phase 2)**: 在 Specialization 模块下 `typealias CandidateBox = DifferentiableBox<RuntimeSpecializationRequest.Candidate>` + 重构 `SpecializationTypePickerViewModel` 与 ViewController;通过关联 plan 的 AC-1 / AC-2 / AC-5 / AC-9 / AC-10
3. **Step 3 (可选,跨 evolution)**: 若有第二个模块按 lazy 模式使用 `DifferentiableBox`,在该模块的 PR 描述中引用本提案,让 reviewer 复核适用边界条件

提案通过 = Step 1 + Step 2 全部 ship + 关联 plan 的 AC 全部满足;状态从 Draft 转为 Accepted。

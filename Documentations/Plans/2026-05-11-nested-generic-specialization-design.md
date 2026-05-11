# Nested Generic Specialization Design

## Problem

The current specialization sheet (introduced in evolution 0003) rejects generic
candidates for any generic parameter — the type picker disables every candidate
whose descriptor is itself generic (`Array`, `Dictionary`, `Optional`, …) with
a red "GENERIC" badge and a "not supported in v1" tooltip. Users can only bind
concrete non-generic leaf types (`Int`, `String`, …) to generic parameters.

Upstream `MachOSwiftSection` has now landed full nested specialization support
via `SpecializationSelection.Argument.boundGeneric(baseCandidate:innerArguments:)`:

- A generic candidate is selected with a recursive selection of its own
  parameters.
- The specializer builds the inner `SpecializationRequest` from the candidate's
  descriptor, then specializes it and feeds the resulting metadata into the
  outer key-arguments buffer.
- Outer constraints (e.g. `A : Hashable`) are validated against the resolved
  inner metadata at preflight time and surface as
  `.protocolRequirementNotSatisfied` with the **outer** parameter name.
- Recursion is depth-bounded (`maxBindingDepth = 16`); breaches surface as a
  typed `boundGenericInnerFailed(parameterName:underlying:)`.

The downstream specialization UI must be redesigned to let users express
selections like `Box<Array<Int>>` or `Container<Dictionary<String, [User]>>`.

## Solution

Replace the flat `NSGridView`-based form with a tree-driven `NSOutlineView`.
Each row represents a generic parameter; selecting a generic candidate expands
the row into child rows for that candidate's own inner parameters (lazily
fetched from the engine). The on-the-wire selection is computed by walking the
row tree rather than maintained as a flat dictionary.

## Design

### Wire / engine layer

#### Recursive `RuntimeSpecializationSelection`

`RuntimeSpecializationSelection.arguments` changes from `[String: Candidate]`
to `[String: Argument]`:

```swift
public struct RuntimeSpecializationSelection: Codable, Hashable, Sendable {
    public var arguments: [String: Argument]
    public init(arguments: [String: Argument] = [:]) { ... }

    public enum Argument: Codable, Hashable, Sendable {
        case candidate(RuntimeSpecializationRequest.Candidate)
        case boundGeneric(
            baseCandidate: RuntimeSpecializationRequest.Candidate,
            innerArguments: [String: Argument]
        )
    }
}
```

`setCandidate(_:for:)` becomes `setArgument(_:for:)`. This is a **breaking wire
change** but is acceptable: the v1 sheet shipped only on
`feature/generic-specialization` and has no external consumers yet.

#### New engine method

```swift
extension RuntimeEngine {
    public func specializationRequest(
        forCandidate candidateID: String,
        in imagePath: String
    ) async throws -> RuntimeSpecializationRequest
}
```

Server-side implementation in `RuntimeSwiftSection`:

1. Decode `candidateID` (mangled name) back into a `SwiftInterface.TypeName`.
2. Locate the corresponding `TypeDefinition` via
   `factory.indexer.allTypeDefinitions[typeName]` — the cross-image aggregate
   exposed by the section factory's shared sub-indexer.
3. `specializer.makeRequest(for: typeDef.type.typeContextDescriptorWrapper)`.
4. Translate to `RuntimeSpecializationRequest` via the existing
   `makeRuntimeSpecializationRequest(from:)`.

New wire command: `CommandNames.specializationRequestForCandidate`. Registered
on both `RuntimeEngine.setupMessageHandlerForServer` and
`RuntimeEngineProxyServer.setupRequestHandlers`.

`EngineError` gains:

```swift
case boundGenericInnerFailed(parameterName: String, underlying: String)
case unindexedCandidate(displayName: String, imagePath: String)
```

`unindexedCandidate` covers the case where the user picks a candidate whose
defining image is not yet indexed (e.g. cross-image candidates surfaced by the
shared aggregate but not loaded for inspection). The UI presents this as a
recoverable error suggesting the user load the image first.

#### Recursive `resolveUpstreamSelection`

`RuntimeSwiftSection.resolveUpstreamSelection` becomes recursive. For each
`.boundGeneric` argument:

1. Match `baseCandidate` against the upstream request's candidates for the
   outer parameter by `(id, imagePath)`.
2. Resolve the matched candidate's `TypeName` back to a `TypeDefinition`.
3. Build the upstream inner request:
   `specializer.makeRequest(for: innerTypeDef.type.typeContextDescriptorWrapper)`.
4. Recurse to resolve `innerArguments` against the inner request.
5. Emit upstream `.boundGeneric(baseCandidate: matched, innerArguments: resolved)`.

#### Tree-walked `typeArgumentNodes`

`RuntimeSwiftSection.specialize`'s typeName rewriting currently only walks the
top level of `upstreamSelection`, skipping non-`.candidate` arguments. It now
becomes a recursive walk that produces nested `BoundGenericStructure(...)`
nodes so the resulting `TypeDefinition.typeName` prints as e.g.
`Box<Array<Int>>` instead of `Box<Array>`.

### Application layer

#### Per-row ViewModel

Introduce `SpecializationRowViewModel` under
`RuntimeViewerApplication/Specialization/`:

```swift
public final class SpecializationRowViewModel: NSObject, OutlineNodeType,
                                                @unchecked Sendable {
    public let parameterPath: [String]                          // ["A"], ["A","B"], …
    public let parameter: RuntimeSpecializationRequest.Parameter

    @Observed public private(set) var selectedCandidate: Candidate?
    @Observed public private(set) var children: [SpecializationRowViewModel]
    @Observed public private(set) var loadState: InnerLoadState
    @Observed public private(set) var buttonTitle: String
    @Observed public private(set) var descriptionText: NSAttributedString

    public var isLeaf: Bool { children.isEmpty && loadState == .idle }

    public enum InnerLoadState: Equatable, Sendable {
        case idle
        case loading
        case failed(String)
    }
}
```

`argument: RuntimeSpecializationSelection.Argument?` is computed:

- No `selectedCandidate` → `nil`.
- Non-generic candidate → `.candidate(c)`.
- Generic candidate + all child rows produce non-`nil` `argument` →
  `.boundGeneric(baseCandidate: c, innerArguments: [child.parameter.name: child.argument!])`.
- Generic candidate + any child missing → `nil` (propagates up).

`Differentiable` is keyed by `parameterPath`; the conformance is gated
`#if canImport(AppKit) && !targetEnvironment(macCatalyst)` per the existing
sidebar / inspector cell-VM pattern.

#### `SpecializationViewModel` changes

State:

- Replaces `selection: RuntimeSpecializationSelection` with
  `@Observed private(set) var topLevelRows: [SpecializationRowViewModel]`. The
  wire-level `selection` is recomputed from the row tree at preflight /
  specialize time via a private helper.

`Input` gains:

```swift
public let requestTypePickerClicked: Signal<[String]>           // parameterPath
```

(replaces the prior `Signal<String>`; the row tree no longer keys by simple
parameter name).

`Output` gains:

```swift
public let rows: Driver<[SpecializationRowViewModel]>
public let expandRow: Signal<SpecializationRowViewModel>
```

`expandRow` is fired explicitly by the VM after `applyArgumentChange` finishes
populating a row's children; the VC subscribes and calls
`outlineView.expandItem(row, expandChildren: false)`.

`applyArgumentChange(path:candidate:)`:

1. Locate row by `path` walking `topLevelRows`.
2. Assign `selectedCandidate`; clear any existing children.
3. If candidate is non-generic, emit `canSpecialize` recompute and stop.
4. If candidate is generic, set `loadState = .loading`, await
   `documentState.runtimeEngine.specializationRequest(forCandidate:in:)`, then
   build child rows from `innerRequest.parameters`, set `loadState = .idle`,
   emit `expandRow`.

#### Type picker changes

`SpecializationTypePickerViewModel`:

- `parameterName: String` → `parameterPath: [String]`.
- The `guard !candidate.isGeneric else { return }` short-circuit in
  `transform(_:)` is removed — generic candidates emit `didSelectCandidate`
  like any other.

### UI layer

#### Outline form

`SpecializationViewController` swaps the `NSGridView` + per-row dictionary for
an `NSOutlineView` inside a `ScrollView`. The outline has a single column (the
`outlineColumn`); each cell hosts an `HStackView` with the description label
and the choose button. The disclosure triangle is drawn by `NSOutlineView`
automatically.

```
┌── Specialize Box ─────────────────────────────────────────┐
│ ▼ A : Hashable                          [ Array<…>     ]  │
│      ▼ A                                [ Dictionary<…> ]  │
│           A : Hashable                  [ String       ]  │
│           B                             [ Int          ]  │
│      B : Equatable                      [ Choose Type…  ]  │
│                                                            │
│  (status / preflight errors)                               │
│                              [ Cancel ]  [ Specialize  ]   │
└────────────────────────────────────────────────────────────┘
```

Data binding uses `outlineView.rx.nodes`; the data source builder closure
returns the controller's private `ParameterRowCellView`:

```swift
output.rows
    .drive(outlineView.rx.nodes) { (outlineView, _, row: SpecializationRowViewModel) in
        let cellView = outlineView.box.makeView(ofClass: ParameterRowCellView.self)
        cellView.bind(to: row)
        return cellView
    }
    .disposed(by: rx.disposeBag)
```

#### Cell view

```swift
extension SpecializationViewController {
    fileprivate final class ParameterRowCellView: TableCellView {
        private let descriptionLabel = Label()
        private let chooseButton = PushButton(
            title: "Choose Type…", titleFont: .systemFont(ofSize: 13))
        let clickRelay = PublishRelay<[String]>()

        override func setup() {
            super.setup()
            let stack = HStackView(spacing: 8) {
                descriptionLabel
                chooseButton
            }
            hierarchy { stack }
            stack.snp.makeConstraints { ... }
        }

        func bind(to row: SpecializationRowViewModel) {
            rx.disposeBag = DisposeBag()
            row.$descriptionText.asDriver()
                .drive(descriptionLabel.rx.attributedStringValue)
                .disposed(by: rx.disposeBag)
            row.$buttonTitle.asDriver()
                .drive(chooseButton.rx.title)
                .disposed(by: rx.disposeBag)
            chooseButton.rx.click
                .asSignal()
                .emit(with: self) { $0.clickRelay.accept(row.parameterPath) }
                .disposed(by: rx.disposeBag)
        }
    }
}
```

Cells are recycled via `outlineView.box.makeView(ofClass:)` per the project
convention; the cell's `clickRelay` is consumed by the controller through a
single forwarding relay wired into `Input.requestTypePickerClicked`.

#### Auto-expansion

After `applyArgumentChange` finishes a generic selection it fires
`output.expandRow`; the controller subscribes:

```swift
output.expandRow.emitOnNext { [weak self] row in
    guard let self else { return }
    outlineView.expandItem(row, expandChildren: false)
}
.disposed(by: rx.disposeBag)
```

#### Popover anchoring

`anchorView(forParameter:)` is renamed to `anchorView(forPath:)`. It walks the
outline by parameter path (translating `[String]` to a `SpecializationRowViewModel`,
then to the outline view's row index, then to the cell view's `chooseButton`).
The `SpecializationCoordinator` uses this anchor for the type-picker popover.

#### Type picker cell

`SpecializationTypePickerViewController.tableView(_:shouldSelectRow:)` is
removed (generic candidates are now selectable). The red "GENERIC" badge is
recolored blue and relabelled "Nested" — informational rather than prohibitive.
Tooltip changes to: "Selecting this opens a nested specialization for the type's
own generic parameters."

#### Route changes

```swift
public enum SpecializationRoute: Routable {
    case cancel
    case dismiss
    case requestTypePicker(parameterPath: [String])             // was: parameterName: String
    case didSelectCandidate(
        parameterPath: [String],                                 // was: parameterName: String
        candidate: RuntimeSpecializationRequest.Candidate)
    case specializeCompleted(RuntimeObject)
}
```

### Validation

`SpecializationViewModel.performSpecialize` keeps the existing two-stage call:

1. `runtimePreflight(for:with:)` — surfaces `.protocolRequirementNotSatisfied`
   and friends. Upstream reports violations against the **outermost** parameter
   name even when the underlying mismatch sits inside a `boundGeneric` chain.
   v1 keeps these messages in the bottom `statusLabel`; row-level inline
   diagnostics are deferred to a v2 enhancement.
2. `specialize(_:with:)` — succeeds and triggers `.specializeCompleted`.

Depth-limit errors (`maxBindingDepth = 16`) bubble up as
`EngineError.boundGenericInnerFailed`; the localized description includes the
outer parameter name.

## Scope

### Changed files

| File | Change |
|------|--------|
| `RuntimeViewerCore/.../Common/RuntimeSpecialization.swift` | `arguments` → `[String: Argument]`; add `Argument` enum |
| `RuntimeViewerCore/.../RuntimeEngine.swift` | New `CommandNames.specializationRequestForCandidate`; new public `specializationRequest(forCandidate:in:)`; `EngineError.boundGenericInnerFailed`, `EngineError.unindexedCandidate` |
| `RuntimeViewerCore/.../RuntimeEngine+GenericSpecialization.swift` | Route inner-request method to `RuntimeSwiftSection` |
| `RuntimeViewerCore/.../Core/RuntimeSwiftSection.swift` | New `specializationRequest(forCandidateID:)`; recursive `resolveUpstreamSelection`; tree-walked `typeArgumentNodes`; translate upstream `boundGenericInnerFailed` |
| `RuntimeViewerCore/.../RuntimeEngineProxyServer.swift` | Register new command handler |
| `RuntimeViewerCore/Tests/.../RuntimeSpecializationTests.swift` | Update to new `Argument` shape; add nested round-trip case |
| `RuntimeViewerApplication/Specialization/SpecializationRowViewModel.swift` | **New** — per-row VM, Differentiable, OutlineNodeType |
| `RuntimeViewerApplication/Specialization/SpecializationViewModel.swift` | Row tree replaces flat selection; lazy inner-request fetch; `expandRow` signal |
| `RuntimeViewerApplication/Specialization/SpecializationTypePickerViewModel.swift` | Path-keyed parameter; drop `isGeneric` gating |
| `RuntimeViewerUsingAppKit/Specialization/SpecializationViewController.swift` | `NSGridView` → `NSOutlineView`; new cell type; path-anchored picker; `expandRow` drive |
| `RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewController.swift` | Remove `shouldSelectRow` gate; recolor "GENERIC" badge to "Nested" |
| `RuntimeViewerUsingAppKit/Specialization/SpecializationCoordinator.swift` | `parameterName` → `parameterPath: [String]` in route enum |

### Unchanged

- `RuntimeSpecializationValidation` — diagnostic shape stays identical; outer
  parameter naming carries the violation up the chain.
- `SpecializationWindowController` — no shell change.
- `InspectorSwiftSpecializationViewController` / `…ViewModel` — sidebar splice
  via `RuntimeDataChange.specializationAdded` works unchanged for the outermost
  specialized type.
- Sidebar — `specializationAdded` continues to fire for the outermost
  specialized type only; nested `Array<Int>` etc. are not registered as
  independent sidebar entries.

### Wire compatibility

`RuntimeSpecializationSelection`'s wire shape changes (flat `Candidate` map →
tagged `Argument` enum). Mixed-version client/server pairs will fail to decode
each other's payloads. Acceptable: the v1 sheet is only shipped on the current
unmerged feature branch, with no external consumers.

## Platform

- macOS 15+ (the existing Specialization sheet platform requirement; no change).
- `NSOutlineView` and `RxAppKit`'s `rx.nodes` adapter are available on every
  supported platform.
- Upstream `MachOSwiftSection` `boundGeneric` support is present in the
  workspace's local checkout already (`feature/generic-specializer` branch
  merged). No SPM re-resolution required when building through
  `../MxIris-Reverse-Engineering.xcworkspace`.

## Open Questions

1. **Cross-image inner candidates.** The recursive `resolveUpstreamSelection`
   relies on the shared sub-indexer aggregate covering candidates from images
   other than the one hosting the outer generic (`Array` / `Dictionary` etc.
   live in stdlib). The aggregate already underwrites the existing flat
   candidate list, so this should "just work", but the nested path is a new
   consumer — confirm with a smoke test specializing
   `Box<Array<Int>>` where `Box` lives in the test image and `Array` lives in
   stdlib.

2. **Inner-request caching.** First iteration fetches the inner request on
   every generic selection (no caching). If lazy-fetch latency becomes
   user-visible — likely fine for in-process / XPC, possibly perceptible over
   Bonjour — add an actor-side cache keyed by `(candidateID, imagePath)`.

3. **Row-level validation surfacing.** v1 keeps preflight errors in the bottom
   `statusLabel`. A v2 enhancement could parse the parameter-name chain in
   `RuntimeSpecializationValidation.Error` and scope the message to the
   offending row's `loadState = .failed(...)`.

4. **Re-selecting an already-bound generic row.** v1 semantics: clicking the
   button on a row that already has a `selectedCandidate` re-opens the picker
   and (on a new selection) destroys the existing child subtree. No migration
   of inner selections, even if the new candidate shares parameter names. This
   matches the current sheet's "re-pick replaces" behaviour and avoids a
   half-migrated tree.

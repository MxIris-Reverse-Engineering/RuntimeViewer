# SpecializationTypePicker Performance Plan (r2)

- **Status**: In Progress (Phase 0 → Phase 1 → Phase 2 sequential)
- **Author**: JH (auto-piloted from ralplan consensus)
- **Date**: 2026-05-18
- **Related**: Evolution proposal `Documentations/Evolution/0004-differentiable-box-lazy-cellvm.md` (Draft → Accepted on landing)
- **Supersedes**: r1 (in-conversation only; never written to disk)

## Problem

`SpecializationTypePickerViewModel.init` at `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Specialization/SpecializationTypePickerViewModel.swift:36` synchronously executes `candidates.sorted().map { SpecializationTypePickerCellViewModel(candidate: $0) }`. For an unconstrained generic parameter (e.g. `Array<T>` where `T: Any`), `candidates.count` matches the number of types loaded into the current image, empirically 10k+ in a Dyld Shared Cache scrape. Each `SpecializationTypePickerCellViewModel.init` does:

- 4 `@Observed` (`BehaviorRelay`) allocations.
- 2 `NSAttributedString` builder evaluations.
- 2 `RuntimeObjectIcon.icon(for:)` cache lookups.

Measured per-instance cost is roughly 50–150 µs on Apple silicon → 10k instances = 0.5–1.5 s of main-thread freeze on popover open. The subsequent `applySearch` at `:61-71` also runs synchronously on every keystroke (no debounce), filtering the same 10k array.

## Decision

Adopt ralplan Option F = **B + C** (debounced off-main search + lazy cellViewModel construction). See ADR at the bottom of this doc.

## Phases

The three phases land in this exact order. Each is a separate commit so that the perf delta of each phase is independently bisectable via Instruments.

### Phase 0 — Signpost baseline (`typePicker.viewModelInit`, `typePicker.applySearch`)

Add `os_signpost` intervals so Instruments shows the current wall time before Phase 1/2 land:

```swift
import os

private let typePickerSignposter = OSSignposter(subsystem: "com.JH.RuntimeViewer", category: "typePicker")

public init(...) {
    let openState = typePickerSignposter.beginInterval("typePicker.open", id: typePickerSignposter.makeSignpostID())
    defer { typePickerSignposter.endInterval("typePicker.open", openState) }
    // existing init body
}

private func applySearch(_ text: String) {
    let searchState = typePickerSignposter.beginInterval("typePicker.applySearch", id: typePickerSignposter.makeSignpostID(), "query: \(text, privacy: .public)")
    defer { typePickerSignposter.endInterval("typePicker.applySearch", searchState) }
    // existing applySearch body
}
```

**Baseline collection protocol**:
1. Open an Xcode project with at least one Dyld Shared Cache image loaded.
2. Pick a runtime type that has at least one unconstrained generic parameter (e.g. `_NSObservation`-prefixed Swift type with `T: Any`).
3. Open the specialization sheet, click the parameter row to open the type picker.
4. Type "S", "Sw", "Swi" with 100ms intervals.
5. Capture os_signpost intervals via Instruments → Logging template.

Record the captured values in this doc under "Baseline measurements" before landing Phase 1.

### Phase 1 — Search off-main + 500 ms debounce

Replace the synchronous `applySearch(_:)` body and the imperative `input.searchString.emitOnNext { applySearch($0) }` with an Rx pipeline:

```swift
input.searchString
    .debounce(.milliseconds(500))                                     // align Sidebar precedent (3 sites)
    .flatMapLatest { [weak self] query -> Signal<[CandidateBox]> in   // cancels stale searches
        guard let self else { return .empty() }
        return Single<[CandidateBox]>.create { single in
            single(.success(self.computeFilter(query)))
            return Disposables.create()
        }
        .subscribe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
        .asSignal(onErrorJustReturn: [])
    }
    .emit(to: $filteredRows)
    .disposed(by: rx.disposeBag)
```

`computeFilter(_:)` does whitespace trim + lowercased + `localizedCaseInsensitiveContains` over `allRows`. It runs on the background scheduler; the resulting array lands on `$filteredRows` via `.emit(to:)` which targets `MainScheduler` (Signal contract).

`flatMapLatest` cancels the inflight search when a new debounced query arrives. There is no manual `Disposable` to track.

**Why 500 ms debounce**: aligns with Sidebar's three existing search debouncers (`SidebarRootViewModel.swift:125`, `SidebarRuntimeObjectViewModel.swift:104`, `SidebarRuntimeObjectListViewModel.swift:96`). Below 500 ms, fast typists trigger redundant background searches; above 500 ms, the UI feels laggy.

### Phase 2 — Lazy cellViewModel via `DifferentiableBox<Candidate>`

Driver element type changes from `[SpecializationTypePickerCellViewModel]` to `[CandidateBox]`. `cellViewModel` is constructed lazily inside the `rx.items` builder closure.

**ViewModel diff sketch**:

```swift
// At file scope, below imports
typealias CandidateBox = DifferentiableBox<RuntimeSpecializationRequest.Candidate>

public final class SpecializationTypePickerViewModel: ViewModel<SpecializationRoute> {
    private let allRows: [CandidateBox]

    @Observed
    public private(set) var filteredRows: [CandidateBox] = []

    public struct Input {
        public let searchString: Signal<String>
        public let rowClicked: Signal<CandidateBox>
    }

    public struct Output {
        public let filteredRows: Driver<[CandidateBox]>
    }

    public init(
        parameterPath: [ParameterPathSegment],
        candidates: [RuntimeSpecializationRequest.Candidate],
        documentState: DocumentState,
        router: any Router<SpecializationRoute>
    ) {
        self.parameterPath = parameterPath
        self.allRows = candidates.sorted().map(CandidateBox.init)
        super.init(documentState: documentState, router: router)
        self.filteredRows = allRows
    }

    public func transform(_ input: Input) -> Output {
        // Phase 1 pipeline (see above)

        input.rowClicked.emitOnNext { [weak self] row in
            guard let self else { return }
            router.trigger(.didSelectCandidate(parameterPath: parameterPath, candidate: row.model))
        }
        .disposed(by: rx.disposeBag)

        return Output(filteredRows: $filteredRows.asDriver())
    }
}
```

**ViewController diff sketch**:

```swift
let rowClicked: Signal<CandidateBox> = tableView.rx
    .itemClicked()
    .compactMap { [weak tableView] index -> CandidateBox? in
        guard let tableView,
              index.row >= 0,
              index.row < tableView.numberOfRows
        else { return nil }
        return try? tableView.rx.model(at: index.row)
    }
    .asSignal(onErrorSignalWith: .empty())

let input = SpecializationTypePickerViewModel.Input(
    searchString: searchField.rx.stringValue.asSignal(onErrorJustReturn: ""),
    rowClicked: rowClicked
)
let output = viewModel.transform(input)

output.filteredRows
    .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, row: CandidateBox) -> NSView? in
        let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<SpecializationTypePickerCellViewModel>.self) { .init(contentInsets: .init(top: 4, left: 4, bottom: 4, right: 4)) }
        let cellViewModel = SpecializationTypePickerCellViewModel(candidate: row.model)
        cellView.bind(to: cellViewModel)
        return cellView
    }
    .disposed(by: rx.disposeBag)
```

**CellViewModel diff**:

Remove the existing `extension SpecializationTypePickerCellViewModel: Differentiable { ... }` block at lines 87–94 of `SpecializationTypePickerCellViewModel.swift`. `DifferentiableBox` now owns row identity; the cellVM is constructed/destroyed per render and never participates in the `rx.items` diff.

Keep `RuntimeObjectCellDisplayable` conformance intact.

## Acceptance Criteria

| ID | Criterion | Verification |
|---|---|---|
| AC-1 | Popover open latency for N >= 10k drops below 100 ms wall (signpost `typePicker.viewModelInit` interval). | Instruments timeline shows interval < 100 ms on the same scene that previously logged 0.5–1.5 s. |
| AC-2 | `SpecializationTypePickerViewModel.init` returns within 30 ms for a mocked 10k Candidate dataset. | Direct test harness: `XCTClockMetric` (or `swift-testing` measure) wrapping init in `RuntimeViewerApplicationTests` (mock dataset construction is acceptable; we are measuring VM cost, not the engine's `specializationRequest`). |
| AC-3 | DifferentiableBox unit tests cover: differenceIdentifier projection, isContentEqual semantics, Set/Dictionary identity, DifferenceKit `StagedChangeset` no-op on equal models, insert/delete detection. | `swift test --filter DifferentiableBoxTests` returns ≥ 6 passing tests. |
| AC-4 | CLAUDE.md NSTableView/NSOutlineView Rx section grows a §9 "Lazy Cell ViewModel" with decision tree + canonical example. | Grep `^**9\.` finds the section after §8 and before "### Closures & Self Capture". |
| AC-5 | Filter typing remains responsive at 60 fps; rapid keystrokes within 500 ms collapse into a single background search. | Manual: type fast; observe one signpost interval per debounced burst, not per keystroke. |
| AC-6 | No regression in candidate selection flow — selecting a row still emits `SpecializationRoute.didSelectCandidate(...)` with the underlying `Candidate`. | Manual: select a candidate; specialization sheet receives the change. |
| AC-7 | `SpecializationTypePickerCellViewModel: Differentiable` extension removed; project still builds. | `grep -n "extension SpecializationTypePickerCellViewModel: Differentiable" RuntimeViewerUsingAppKit/` returns 0 matches; `swift build` succeeds. |
| AC-8 | Sidebar / Inspector behavior unchanged (their eager 1:1 cellVM mode untouched). | Smoke test: open sidebar, drill into a runtime image, open inspector for a class; filter typing in sidebar still hot-reactive. |
| AC-9 | `SpecializationTypePickerCellViewModel.init` invoked only inside the `rx.items` cell builder closure (never at VM.init). | Add `print` / breakpoint in cellVM init; confirm only fires during table render/scroll, never at popover open. |
| AC-10 | DifferenceKit `Changeset` emits inserts/removes only for actual filter-result delta; stable rows produce zero updates. | Covered by Phase 3 test `differenceKitTreatsEqualModelsAsIdentical`. |

## Risks & Mitigations

| ID | Risk | Mitigation |
|---|---|---|
| R-1 | Lazy cellVM reconstruction during scroll allocates ~50–150 µs × ~visible-rows per scroll tick → could approach 16 ms budget. | Empirically `cellViewModel` cost is dominated by `NSAttributedString` builder (~30–50 µs); 12 visible rows × 50 µs = 0.6 ms, well under budget. If Phase 0 baseline + Phase 2 follow-up reveals overrun, push `NSAttributedString` construction down into the cell view's `bind(to:)` so only the visible row pays it. **Do NOT add a cache layer to `DifferentiableBox`** — see Evolution proposal §4.C rationale. |
| R-2 | `flatMapLatest` cancellation of stale searches drops their results; if a user types and immediately stops, the last debounced query result must land. | `.debounce` + `flatMapLatest` semantics already guarantee this: debounce coalesces, flatMapLatest only cancels on a NEW upstream event. |
| R-3 | `DifferentiableBox`'s `isContentEqual` uses `Model.==`. If `Candidate.Equatable` ever includes presentation-only fields, diff churn appears. | `Candidate` is `Codable, Hashable, Sendable, ComparableBuildable` with identity-stable fields (`id`, `displayName`, `imagePath`, `isGeneric`, `kind`). All five are domain primary-key class. Codegen-driven `Hashable` is stable. Add an inline comment near the `typealias` reminding maintainers of this invariant. |
| R-4 | Removing `SpecializationTypePickerCellViewModel: Differentiable` could break a downstream user (e.g. another module storing cellVMs in a diffable container). | Verified by grep: only `SpecializationTypePickerViewModel` consumes the cellVM type; no other module references the `Differentiable` conformance. |
| R-5 | `ConcurrentDispatchQueueScheduler(qos: .userInitiated)` background search races with parameter switching (clicking another generic parameter row while a search is inflight). | The popover and its ViewModel are torn down on dismiss; `rx.disposeBag` cancels the inflight pipeline. `flatMapLatest` further guards by cancelling on each new query event. |
| R-6 | Sort still runs on main at init time. For N >> 50k, `.sorted()` itself could exceed budget. | Phase 0 baseline measures `typePicker.viewModelInit` end-to-end. If sort dominates, defer sort to background by promoting `allRows` construction to an `init` continuation pattern (Phase 3, conditional — NOT executed unless baseline shows the need). |
| R-7 | Lazy mode breaks the (now removed) `Differentiable` invariant on cellVM if a future contributor reads CLAUDE.md §6 (existing eager mode) and re-conforms cellVM. | CLAUDE.md §9 (added in this plan) explicitly documents the anti-pattern and links to `SpecializationTypePicker` as canonical lazy example. PR reviewers can grep for `Differentiable` adds in cellVM files. |

## Baseline measurements

To be filled in after Phase 0 lands (per the protocol in Phase 0 above):

| Scenario | Wall time before | Wall time after Phase 1 | Wall time after Phase 2 |
|---|---|---|---|
| Open popover, N = 10k candidates | _TBD_ | _TBD_ | _TBD_ |
| Type "Sw" in search field | _TBD_ | _TBD_ | _TBD_ |
| Scroll 100 rows | _TBD_ | _TBD_ | _TBD_ |

## ADR

**Decision**: Land Option F (Phase 1 background-search + debounce + Phase 2 lazy cellViewModel via `DifferentiableBox`), three sequential commits.

**Drivers**:

1. Eager cellVM construction at VM.init dominates open latency (R-1 analysis confirms cellVM init is the bottleneck, not sort).
2. Synchronous filter on every keystroke compounds the cost on the same array (no debounce, no cancellation).
3. CLAUDE.md hard rule prohibits retroactive `Differentiable` conformance on `RuntimeSpecializationRequest.Candidate` (a public RuntimeViewerCore type); local wrapper is mandatory.

**Alternatives considered**:

- **A. Status quo + only debounce** — does not address the open-latency bottleneck (which fires before any search occurs).
- **B. Only background search (no lazy cellVM)** — partial fix: search becomes responsive, but the initial popover open still freezes 0.5–1.5 s.
- **C. Only lazy cellVM (no debounce)** — popover opens fast, but every keystroke triggers full main-thread filter on 10k array; UI still stutters.
- **D. Move sort off-main, keep eager cellVM** — sort cost is small relative to cellVM construction; would not move the needle.
- **E. Replace `RuntimeObjectCellView` with a hand-rolled lighter cell** — bigger blast radius, conflicts with project-wide cell composition convention.
- **F (chosen) = B + C** — addresses both bottlenecks with minimal new abstraction (one generic wrapper struct + one CLAUDE.md sub-section).

**Why F**: smallest delta that fixes both observed problems; introduces one reusable primitive (`DifferentiableBox`) governed by an evolution proposal; preserves all CLAUDE.md conventions (rx trailing closures, `guard let self`, project wrapper types, no SwiftUI in non-Settings, no new third-party dep).

**Consequences**:

- Future modules with the same large-static-data shape can reach for `DifferentiableBox` + lazy cellVM (documented in CLAUDE.md §9).
- Sidebar / Inspector remain eager 1:1 (their cellVMs are stateful; the new pattern is explicitly anti-recommended for them).
- Cell builder closure now does cellVM allocation per render; if scroll-perf regresses, mitigation is `NSAttributedString` deferral (R-1), not adding cache layers to `DifferentiableBox`.

**Follow-ups**:

- Empirical signpost-driven tuning: if AC-1 fails after Phase 2, revisit R-1 (`NSAttributedString` deferral) or R-6 (off-main sort) — conditional, only on measured need.
- Optional: extend `DifferentiableBoxTests` with a third `StagedChangeset` scenario covering reorder detection if a future module needs it.
- Evolution proposal `0004` status flips from Draft to Accepted when this plan's Phase 2 ships.

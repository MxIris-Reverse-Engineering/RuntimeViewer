# Background Indexing — History Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-memory `HISTORY` section to `BackgroundIndexingPopoverViewController` so users can review every batch produced during the current document session (success / failure / cancelled), not just active or failure-retained batches.

**Architecture:** New `historyRelay` on `RuntimeBackgroundIndexingCoordinator` parallel to the existing `batchesRelay`. Finalized batches flow into history via the existing `apply(event:)` reduction. `BackgroundIndexingNode` gains a `.section(SectionKind, batches:)` case so the outline renders two top-level groups (`ACTIVE` always, `HISTORY` when non-empty). The popover's `Clear Failed` button is replaced by `Clear History`, which empties the new relay.

**Tech Stack:** Swift 6.2, RxSwift / RxCocoa / RxAppKit (staged-changeset diffing), `@Observable` state, AppKit `NSOutlineView` with `OutlineNodeType` / `Differentiable` from `RxAppKit`.

**Spec:** `Documentations/Evolution/0002-background-indexing.md` (2026-04-29 revisions — new History section, Alternative E revision, decision log entry).

---

## Pre-Flight

The working tree at plan-write time contains **pre-existing uncommitted changes** unrelated to this feature (Core renames `BackgroundIndexingEngineRepresenting.swift` → `RuntimeBackgroundIndexingEngineRepresenting.swift`, `ResolvedDependency.swift` → `RuntimeResolvedDependency.swift`, plus modifications to `RuntimeBackgroundIndexingManager.swift`, `RuntimeEngine+BackgroundIndexing.swift`, `MockBackgroundIndexingEngine.swift`, `RuntimeBackgroundIndexingManagerTests.swift`).

**Before starting this plan**, decide one of:

1. **Commit them first** under their own message (e.g. `refactor(core): adopt Runtime prefix for indexing helper types`) so this feature's commits stay focused.
2. **Stash them** (`git stash push --keep-index -m "pre-history-feature renames" -- RuntimeViewerCore/`) and pop after Task 4.
3. **Bundle them** if the engineer reviewing knows they belong with this feature (unlikely — check with the user first).

Default recommendation: **option 1**. Verify they build cleanly first.

The 0002 spec edits (`M Documentations/Evolution/0002-background-indexing.md`) ARE part of this feature — they should land in Task 1's commit so the spec and implementation arrive together.

---

## File Structure

| File | Touch | Responsibility |
|---|---|---|
| `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift` | Modify | Add history relay/API; route finalized batches into history; clear history on engine swap |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift` | Modify | Add `.section(SectionKind, batches:)` case + identifier + `OutlineNodeType.children` branch |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift` | Modify | Combine active+history into section-grouped `nodes`; rename `clearFailed`/`hasAnyFailure` to `clearHistory`/`hasAnyHistory` |
| `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift` | Modify | Replace `clearFailedButton` with `clearHistoryButton`; add `SectionHeaderCellView`; cell-provider branch for `.section`; section-aware expansion; updated empty-state binding |
| `Documentations/Evolution/0002-background-indexing.md` | Modify (already done) | Spec revisions land with Task 1 commit |

**Build target:** `RuntimeViewerUsingAppKit` (Debug). Workspace: `../MxIris-Reverse-Engineering.xcworkspace` (verified to exist; required per project CLAUDE.md to pick up local SPM checkouts).

**No automated tests.** This codebase has no test target for `RuntimeViewerApplication` (only `RuntimeViewerSettingsTests` exists). The original 0002 spec explicitly states "UI 不做自动化". Verification is build-pass + manual smoke test per the design's checklist (Task 4).

---

## Task 1: Coordinator — History data layer (additive)

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift`

**Goal:** Add `historyRelay` + public surface, populate it from `apply(event:)`, clear it on engine swap. **Don't change existing failure-retention behavior in `batchesRelay` yet** — that flips in Task 3 when the UI is ready to show history. Mid-state: history grows in memory but no UI consumer; behavior visible to user is unchanged.

- [ ] **Step 1: Add `historyRelay` storage and public accessors**

In `RuntimeBackgroundIndexingCoordinator.swift`, locate the existing `batchesRelay` declaration (around line 35-38):

```swift
private let batchesRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
private let aggregateRelay = BehaviorRelay<AggregateState>(
    value: .init(hasActiveBatch: false, hasAnyFailure: false, progress: nil)
)
```

Add immediately after `batchesRelay`:

```swift
private let historyRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
```

Then locate the `// MARK: - Public observables for UI` section (around line 61-69) and add after `aggregateStateObservable`:

```swift
public var historyObservable: Observable<[RuntimeIndexingBatch]> {
    historyRelay.asObservable()
}

// Synchronous accessors so the ViewModel can do `Observable.combineLatest`
// without re-subscribing inside drive callbacks. Mirror `batchesRelay.value`.
public var batchesValue: [RuntimeIndexingBatch] { batchesRelay.value }
public var historyValue: [RuntimeIndexingBatch] { historyRelay.value }
```

- [ ] **Step 2: Add `clearHistory()` to the public command surface**

Locate the `// MARK: - Public command surface` section (around line 71-108). After the existing `clearFailedBatches()` method, add:

```swift
public func clearHistory() {
    historyRelay.accept([])
}
```

Leave `clearFailedBatches()` untouched for now — it'll be removed in Task 3 once no caller remains.

- [ ] **Step 3: Route finalized batches into history**

In `apply(event:)`, locate the `.batchFinished` case (around line 148-167):

```swift
case .batchFinished(let finished):
    if finished.items.contains(where: {
        if case .failed = $0.state { return true } else { return false }
    }) {
        // Keep the failed batch in the list until the user dismisses it.
        if let batchIndex = batches.firstIndex(where: { $0.id == finished.id }) {
            batches[batchIndex] = finished
        }
    } else {
        batches.removeAll { $0.id == finished.id }
    }
    documentBatchIDs.remove(finished.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

Replace with (additive only — the existing branches stay; we just push into history):

```swift
case .batchFinished(let finished):
    var updatedHistory = historyRelay.value
    updatedHistory.insert(finished, at: 0)
    historyRelay.accept(updatedHistory)
    if finished.items.contains(where: {
        if case .failed = $0.state { return true } else { return false }
    }) {
        // Keep the failed batch in the list until the user dismisses it.
        // (Removed in Task 3 once history UI is wired.)
        if let batchIndex = batches.firstIndex(where: { $0.id == finished.id }) {
            batches[batchIndex] = finished
        }
    } else {
        batches.removeAll { $0.id == finished.id }
    }
    documentBatchIDs.remove(finished.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

Then locate the `.batchCancelled` case (around line 169-176):

```swift
case .batchCancelled(let cancelled):
    // Cancellation always removes — user already acknowledged the outcome.
    batches.removeAll { $0.id == cancelled.id }
    documentBatchIDs.remove(cancelled.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

Replace with:

```swift
case .batchCancelled(let cancelled):
    // Cancellation always removes from active. Now also lands in history
    // so the user can review what got cancelled.
    var updatedHistory = historyRelay.value
    updatedHistory.insert(cancelled, at: 0)
    historyRelay.accept(updatedHistory)
    batches.removeAll { $0.id == cancelled.id }
    documentBatchIDs.remove(cancelled.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

- [ ] **Step 4: Clear history on engine swap**

Locate `handleEngineSwap(to:)` (around line 224-264) and the comment block beginning `// 3) Drop UI state`. The current code:

```swift
// 3) Drop UI state — the old engine's batches no longer apply.
documentBatchIDs.removeAll()
batchesRelay.accept([])
refreshAggregate(batches: [])
```

Replace with:

```swift
// 3) Drop UI state — the old engine's batches and history no longer apply.
documentBatchIDs.removeAll()
batchesRelay.accept([])
historyRelay.accept([])
refreshAggregate(batches: [])
```

- [ ] **Step 5: Build to verify Coordinator compiles**

Use the `xcodebuildmcp-cli` skill to build the `RuntimeViewerUsingAppKit` scheme against the umbrella workspace.

```bash
xcodebuildmcp build --workspace ../MxIris-Reverse-Engineering.xcworkspace --scheme RuntimeViewerUsingAppKit --configuration Debug
```

Expected: BUILD SUCCEEDED. If unavailable, fall back to `xcodebuild -workspace ../MxIris-Reverse-Engineering.xcworkspace -scheme RuntimeViewerUsingAppKit -configuration Debug build 2>&1 | xcsift`.

- [ ] **Step 6: Commit**

The 0002 spec edits land here so the design and implementation introduce the history concept together.

```bash
git add Documentations/Evolution/0002-background-indexing.md \
        RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(background-indexing): add coordinator-level history relay

Finalized batches (success / failure / cancelled) now also flow into
historyRelay alongside the existing active-batch tracking. No UI consumer
yet — failure-retention in batchesRelay stays unchanged in this commit;
the history relay is wired so the popover can render it in the next
commit. handleEngineSwap clears history along with active batches since
the old engine's metadata no longer applies.
EOF
)"
```

---

## Task 2: Node enum extension + cell scaffolding (additive case)

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift`

**Goal:** Make `BackgroundIndexingNode` carry a `.section` case and give the outline view a cell that knows how to render section headers. The ViewModel still produces flat `[.batch, .batch, ...]` after this commit, so `.section` is never instantiated yet, but the type system and switch-exhaustiveness handle it. Adding both the producer and consumer side of an enum case in the same commit is the only way to keep the build green for an exhaustive switch.

- [ ] **Step 1: Extend `BackgroundIndexingNode` with `.section` case**

Open `BackgroundIndexingNode.swift`. Replace the entire file:

```swift
import RuntimeViewerCore
import RxAppKit

enum BackgroundIndexingNode: Hashable {
    case section(SectionKind, batches: [BackgroundIndexingNode])
    case batch(RuntimeIndexingBatch, items: [BackgroundIndexingNode])
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)

    enum SectionKind: Hashable {
        case active
        case history
    }
}

extension BackgroundIndexingNode: OutlineNodeType {
    var children: [BackgroundIndexingNode] {
        switch self {
        case .section(_, let batches): return batches
        case .batch(_, let items): return items
        case .item: return []
        }
    }
}

extension BackgroundIndexingNode: Differentiable {
    enum Identifier: Hashable {
        case section(SectionKind)
        case batch(RuntimeIndexingBatchID)
        case item(batchID: RuntimeIndexingBatchID, itemID: String)
    }

    // Identifier for `.section` is intentionally kind-only — not derived
    // from children. RxAppKit's staged changeset detects child insertions
    // and removals as nested diffs without recreating the section row,
    // which preserves the user's expand / collapse state across updates.
    var differenceIdentifier: Identifier {
        switch self {
        case .section(let kind, _):
            return .section(kind)
        case .batch(let batch, _):
            return .batch(batch.id)
        case .item(let batchID, let item):
            return .item(batchID: batchID, itemID: item.id)
        }
    }
}
```

- [ ] **Step 2: Add `SectionHeaderCellView` private nested class**

Open `BackgroundIndexingPopoverViewController.swift`. Locate the existing extension block at the bottom (`extension BackgroundIndexingPopoverViewController { ... }` containing `BatchCellView` and `ItemCellView`, starting around line 237). Add a new private nested class **at the top of that extension** (immediately after the extension brace, before `BatchCellView`):

```swift
extension BackgroundIndexingPopoverViewController {
    private final class SectionHeaderCellView: NSTableCellView {
        private let titleLabel = Label("").then {
            $0.font = .systemFont(ofSize: 11, weight: .semibold)
            $0.textColor = .secondaryLabelColor
        }
        private let countLabel = Label("").then {
            $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            $0.textColor = .tertiaryLabelColor
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let stack = HStackView(alignment: .centerY, spacing: 6) {
                titleLabel
                countLabel
            }

            addSubview(stack)
            stack.snp.makeConstraints { make in
                make.top.equalToSuperview().offset(4)
                make.bottom.equalToSuperview().offset(-4)
                make.leading.trailing.equalToSuperview()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(kind: BackgroundIndexingNode.SectionKind, count: Int) {
            switch kind {
            case .active:  titleLabel.stringValue = "ACTIVE"
            case .history: titleLabel.stringValue = "HISTORY"
            }
            countLabel.stringValue = "\(count)"
        }
    }

    private final class BatchCellView: NSTableCellView {
        // ... existing implementation unchanged ...
```

(Place the new `SectionHeaderCellView` class **inside** the existing extension, just before `BatchCellView`. Do not add a second extension block — keep them all in the one existing extension.)

- [ ] **Step 3: Add `.section` branch to outline cell provider**

In the same file, locate `setupBindings(for:)`'s `outlineView.rx.nodes` closure (around line 209-227):

```swift
output.nodes.drive(outlineView.rx.nodes) { [weak self] (outlineView: NSOutlineView, _: NSTableColumn?, node: BackgroundIndexingNode) -> NSView? in
    switch node {
    case .batch(let batch, _):
        let cell = outlineView.box.makeView(ofClass: BatchCellView.self)
        cell.bind(
            batch: viewModel.batch(for: batch.id),
            onCancel: { [weak self] in
                guard let self else { return }
                cancelBatchRelay.accept(batch.id)
            }
        )
        return cell
    case .item(let batchID, let item):
        let cell = outlineView.box.makeView(ofClass: ItemCellView.self)
        cell.bind(item: viewModel.item(for: batchID, itemID: item.id))
        return cell
    }
}
.disposed(by: rx.disposeBag)
```

Add a `.section` case at the top of the switch:

```swift
output.nodes.drive(outlineView.rx.nodes) { [weak self] (outlineView: NSOutlineView, _: NSTableColumn?, node: BackgroundIndexingNode) -> NSView? in
    switch node {
    case .section(let kind, let batches):
        let cell = outlineView.box.makeView(ofClass: SectionHeaderCellView.self)
        cell.configure(kind: kind, count: batches.count)
        return cell
    case .batch(let batch, _):
        let cell = outlineView.box.makeView(ofClass: BatchCellView.self)
        cell.bind(
            batch: viewModel.batch(for: batch.id),
            onCancel: { [weak self] in
                guard let self else { return }
                cancelBatchRelay.accept(batch.id)
            }
        )
        return cell
    case .item(let batchID, let item):
        let cell = outlineView.box.makeView(ofClass: ItemCellView.self)
        cell.bind(item: viewModel.item(for: batchID, itemID: item.id))
        return cell
    }
}
.disposed(by: rx.disposeBag)
```

- [ ] **Step 4: Build to verify exhaustive switches still pass**

```bash
xcodebuildmcp build --workspace ../MxIris-Reverse-Engineering.xcworkspace --scheme RuntimeViewerUsingAppKit --configuration Debug
```

Expected: BUILD SUCCEEDED. The `OutlineNodeType.children`, `Differentiable.differenceIdentifier`, and outline cell provider switches must all handle `.section`.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingNode.swift \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift
git commit -m "$(cat <<'EOF'
feat(background-indexing): add section node case + header cell

BackgroundIndexingNode gains a .section(SectionKind, batches:) case so
the popover outline can render top-level Active / History groups.
Identifier for the section is kind-only so RxAppKit's staged-changeset
preserves the user's expand-collapse state across updates. ViewModel
still produces flat batch nodes for now — sectioning is wired in the
next commit.
EOF
)"
```

---

## Task 3: Wire active+history into sections, swap the button

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift` (drop `clearFailedBatches`, drop failure-retention in `batchesRelay`)
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift`

**Goal:** Flip the user-visible behavior. ViewModel renders nodes as `[.section(.active, ...), .section(.history, ...)]`. Button renamed to `Clear History`. Failed batches no longer linger in `batchesRelay` — they're in history only. Recursive expansion swaps for section-aware expansion.

- [ ] **Step 1: ViewModel — replace `hasAnyFailure` with `hasAnyHistory`**

Open `BackgroundIndexingPopoverViewModel.swift`. Locate the `@Observed` property declarations (around line 11-15):

```swift
@Observed private(set) var nodes: [BackgroundIndexingNode] = []
@Observed private(set) var isEnabled: Bool = false
@Observed private(set) var hasAnyBatch: Bool = false
@Observed private(set) var hasAnyFailure: Bool = false
@Observed private(set) var subtitle: String = ""
```

Replace `hasAnyFailure` with `hasAnyHistory`:

```swift
@Observed private(set) var nodes: [BackgroundIndexingNode] = []
@Observed private(set) var isEnabled: Bool = false
@Observed private(set) var hasAnyBatch: Bool = false
@Observed private(set) var hasAnyHistory: Bool = false
@Observed private(set) var subtitle: String = ""
```

- [ ] **Step 2: ViewModel — rename Input/Output fields**

Locate the `Input` and `Output` structs (around line 28-46). Replace `clearFailed` with `clearHistory` in `Input`, and `hasAnyFailure` with `hasAnyHistory` in `Output`:

```swift
struct Input {
    let cancelBatch: Signal<RuntimeIndexingBatchID>
    let cancelAll: Signal<Void>
    let clearHistory: Signal<Void>
    let openSettings: Signal<Void>
}

struct Output {
    let nodes: Driver<[BackgroundIndexingNode]>
    let isEnabled: Driver<Bool>
    let hasAnyBatch: Driver<Bool>
    let hasAnyHistory: Driver<Bool>
    let subtitle: Driver<String>
    // Forwarded to the ViewController so it can call
    // `SettingsWindowController.shared.showWindow(nil)` directly — mirrors
    // MCPStatusPopoverViewController.swift:200-203 (no `MainRoute` case
    // exists for openSettings).
    let openSettings: Signal<Void>
}
```

- [ ] **Step 3: ViewModel — combine active + history into section nodes**

Locate the `transform(_:)` method (around line 48-107). The current implementation reads `coordinator.batchesObservable` and renders nodes with `Self.renderNodes`. Replace the `coordinator.batchesObservable` subscription block (around line 49-57) with a `combineLatest` of active and history:

```swift
Observable.combineLatest(
    coordinator.batchesObservable,
    coordinator.historyObservable
)
.map { active, history in
    Self.renderNodes(active: active, history: history)
}
.asDriver(onErrorJustReturn: [])
.driveOnNext { [weak self] newNodes in
    guard let self else { return }
    nodes = newNodes
    hasAnyBatch = !coordinator.batchesValue.isEmpty
    hasAnyHistory = !coordinator.historyValue.isEmpty
}
.disposed(by: rx.disposeBag)
```

- [ ] **Step 4: ViewModel — drop `hasAnyFailure` reading from aggregate state**

In the same `transform(_:)`, locate the `aggregateStateObservable` subscription (around line 59-66):

```swift
coordinator.aggregateStateObservable
    .asDriver(onErrorDriveWith: .empty())
    .driveOnNext { [weak self] state in
        guard let self else { return }
        subtitle = Self.subtitleFor(state)
        hasAnyFailure = state.hasAnyFailure
    }
    .disposed(by: rx.disposeBag)
```

Replace with (drop the `hasAnyFailure` line — `subtitle` still uses progress from `state`):

```swift
coordinator.aggregateStateObservable
    .asDriver(onErrorDriveWith: .empty())
    .driveOnNext { [weak self] state in
        guard let self else { return }
        subtitle = Self.subtitleFor(state)
    }
    .disposed(by: rx.disposeBag)
```

- [ ] **Step 5: ViewModel — wire `clearHistory` input**

In the same `transform(_:)`, locate the `clearFailed` input handler (around line 85-89):

```swift
input.clearFailed.emitOnNext { [weak self] in
    guard let self else { return }
    coordinator.clearFailedBatches()
}
.disposed(by: rx.disposeBag)
```

Replace with:

```swift
input.clearHistory.emitOnNext { [weak self] in
    guard let self else { return }
    coordinator.clearHistory()
}
.disposed(by: rx.disposeBag)
```

- [ ] **Step 6: ViewModel — update returned Output**

Locate the `return Output(...)` block at the end of `transform(_:)` (around line 99-106):

```swift
return Output(
    nodes: $nodes.asDriver(),
    isEnabled: $isEnabled.asDriver(),
    hasAnyBatch: $hasAnyBatch.asDriver(),
    hasAnyFailure: $hasAnyFailure.asDriver(),
    subtitle: $subtitle.asDriver(),
    openSettings: openSettingsRelay.asSignal()
)
```

Replace with:

```swift
return Output(
    nodes: $nodes.asDriver(),
    isEnabled: $isEnabled.asDriver(),
    hasAnyBatch: $hasAnyBatch.asDriver(),
    hasAnyHistory: $hasAnyHistory.asDriver(),
    subtitle: $subtitle.asDriver(),
    openSettings: openSettingsRelay.asSignal()
)
```

- [ ] **Step 7: ViewModel — update `renderNodes` to produce sections**

Locate the existing `renderNodes(from:)` static method (around line 151-160):

```swift
private static func renderNodes(from batches: [RuntimeIndexingBatch])
    -> [BackgroundIndexingNode]
{
    batches.map { batch in
        let itemNodes = batch.items.map { item in
            BackgroundIndexingNode.item(batchID: batch.id, item: item)
        }
        return .batch(batch, items: itemNodes)
    }
}
```

Replace with:

```swift
private static func renderNodes(active: [RuntimeIndexingBatch],
                                history: [RuntimeIndexingBatch])
    -> [BackgroundIndexingNode]
{
    let activeBatchNodes = active.map(makeBatchNode)
    var nodes: [BackgroundIndexingNode] = [.section(.active, batches: activeBatchNodes)]
    // History section is omitted entirely when empty so it doesn't clutter
    // the popover with an empty header. Active is always present so the
    // user always has the "ACTIVE" group as context.
    if !history.isEmpty {
        let historyBatchNodes = history.map(makeBatchNode)
        nodes.append(.section(.history, batches: historyBatchNodes))
    }
    return nodes
}

private static func makeBatchNode(_ batch: RuntimeIndexingBatch)
    -> BackgroundIndexingNode
{
    let itemNodes = batch.items.map { item in
        BackgroundIndexingNode.item(batchID: batch.id, item: item)
    }
    return .batch(batch, items: itemNodes)
}
```

- [ ] **Step 8: ViewController — rename button**

Open `BackgroundIndexingPopoverViewController.swift`. Locate the `clearFailedButton` declaration (around line 56-60):

```swift
private let clearFailedButton = NSButton().then {
    $0.bezelStyle = .accessoryBarAction
    $0.title = "Clear Failed"
    $0.isHidden = true
}
```

Replace with:

```swift
private let clearHistoryButton = NSButton().then {
    $0.bezelStyle = .accessoryBarAction
    $0.title = "Clear History"
    $0.isHidden = true
}
```

- [ ] **Step 9: ViewController — update button stack composition**

In the same file, locate `setupLayout()`'s `buttonStack` (around line 82-86):

```swift
let buttonStack = HStackView(spacing: 8) {
    cancelAllButton
    clearFailedButton
    closeButton
}
```

Replace with:

```swift
let buttonStack = HStackView(spacing: 8) {
    cancelAllButton
    clearHistoryButton
    closeButton
}
```

- [ ] **Step 10: ViewController — update Input wiring + bindings**

In `setupBindings(for:)`, locate the `Input` construction (around line 154-159):

```swift
let input = BackgroundIndexingPopoverViewModel.Input(
    cancelBatch: cancelBatchRelay.asSignal(),
    cancelAll: cancelAllButton.rx.click.asSignal(),
    clearFailed: clearFailedButton.rx.click.asSignal(),
    openSettings: openSettingsButton.rx.click.asSignal()
)
```

Replace with:

```swift
let input = BackgroundIndexingPopoverViewModel.Input(
    cancelBatch: cancelBatchRelay.asSignal(),
    cancelAll: cancelAllButton.rx.click.asSignal(),
    clearHistory: clearHistoryButton.rx.click.asSignal(),
    openSettings: openSettingsButton.rx.click.asSignal()
)
```

Then locate the `hasAnyFailure` binding (around line 181-183):

```swift
output.hasAnyFailure.not()
    .drive(clearFailedButton.rx.isHidden)
    .disposed(by: rx.disposeBag)
```

Replace with:

```swift
output.hasAnyHistory.not()
    .drive(clearHistoryButton.rx.isHidden)
    .disposed(by: rx.disposeBag)
```

- [ ] **Step 11: ViewController — update empty-state binding to include history**

Locate the existing empty-state binding pair (around line 193-203):

```swift
Driver.combineLatest(output.isEnabled, output.hasAnyBatch) { enabled, hasBatches in
    !enabled || hasBatches
}
.drive(emptyIdleView.rx.isHidden)
.disposed(by: rx.disposeBag)

Driver.combineLatest(output.isEnabled, output.hasAnyBatch) { enabled, hasBatches in
    !enabled || !hasBatches
}
.drive(scrollView.rx.isHidden)
.disposed(by: rx.disposeBag)
```

Replace with (factor in history so the empty state hides when only history exists):

```swift
let hasAnyContent = Driver.combineLatest(output.hasAnyBatch, output.hasAnyHistory) {
    $0 || $1
}

Driver.combineLatest(output.isEnabled, hasAnyContent) { enabled, hasContent in
    !enabled || hasContent
}
.drive(emptyIdleView.rx.isHidden)
.disposed(by: rx.disposeBag)

Driver.combineLatest(output.isEnabled, hasAnyContent) { enabled, hasContent in
    !enabled || !hasContent
}
.drive(scrollView.rx.isHidden)
.disposed(by: rx.disposeBag)
```

- [ ] **Step 12: ViewController — replace recursive expand with section-aware expand**

Locate the post-`output.nodes` expansion block (around line 229-233):

```swift
output.nodes.driveOnNext { [weak self] _ in
    guard let self else { return }
    outlineView.expandItem(nil, expandChildren: true)
}
.disposed(by: rx.disposeBag)
```

Replace with:

```swift
output.nodes.driveOnNext { [weak self] nodes in
    guard let self else { return }
    // Auto-expand only the ACTIVE section and its batches. HISTORY stays
    // collapsed by default; once the user expands it, NSOutlineView
    // preserves that state across diffs (the section identifier is
    // kind-only, see BackgroundIndexingNode.differenceIdentifier).
    for node in nodes {
        if case .section(.active, _) = node {
            outlineView.expandItem(node, expandChildren: true)
        }
    }
}
.disposed(by: rx.disposeBag)
```

- [ ] **Step 13: Coordinator — drop failure-retention in `apply(event:)`**

Open `RuntimeBackgroundIndexingCoordinator.swift`. Locate the `.batchFinished` case as modified in Task 1:

```swift
case .batchFinished(let finished):
    var updatedHistory = historyRelay.value
    updatedHistory.insert(finished, at: 0)
    historyRelay.accept(updatedHistory)
    if finished.items.contains(where: {
        if case .failed = $0.state { return true } else { return false }
    }) {
        // Keep the failed batch in the list until the user dismisses it.
        // (Removed in Task 3 once history UI is wired.)
        if let batchIndex = batches.firstIndex(where: { $0.id == finished.id }) {
            batches[batchIndex] = finished
        }
    } else {
        batches.removeAll { $0.id == finished.id }
    }
    documentBatchIDs.remove(finished.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

Replace with (failures now removed from active just like clean finishes — they live in history):

```swift
case .batchFinished(let finished):
    var updatedHistory = historyRelay.value
    updatedHistory.insert(finished, at: 0)
    historyRelay.accept(updatedHistory)
    batches.removeAll { $0.id == finished.id }
    documentBatchIDs.remove(finished.id)
    Task { [engine] in
        await engine.reloadData(isReloadImageNodes: false)
    }
```

- [ ] **Step 14: Coordinator — remove `clearFailedBatches()`**

In the same file, locate `clearFailedBatches()` (around line 91-108):

```swift
public func clearFailedBatches() {
    // Class is `@MainActor`; we're already on the main thread when called
    // from the popover's button. No hop required.
    let allBatches = batchesRelay.value
    let remaining = allBatches.filter { batch in
        !batch.items.contains { item in
            if case .failed = item.state { return true } else { return false }
        }
    }
    // Drop the cleared batches from documentBatchIDs as well — they're
    // already finalized on the manager side, but leaving their ids here
    // makes documentBatchIDs grow unboundedly and causes documentWillClose
    // to fire no-op cancel Tasks for ghost ids.
    let removedIDs = Set(allBatches.map(\.id)).subtracting(remaining.map(\.id))
    documentBatchIDs.subtract(removedIDs)
    batchesRelay.accept(remaining)
    refreshAggregate(batches: remaining)
}
```

Delete the entire method. After Task 3 the only caller was the old `Input.clearFailed` wiring, which was renamed to `clearHistory` in Step 5.

- [ ] **Step 15: Build to verify everything compiles**

```bash
xcodebuildmcp build --workspace ../MxIris-Reverse-Engineering.xcworkspace --scheme RuntimeViewerUsingAppKit --configuration Debug
```

Expected: BUILD SUCCEEDED. If there's a stray reference to `clearFailed` / `hasAnyFailure` / `clearFailedBatches` anywhere, the build will surface it — fix and rebuild.

- [ ] **Step 16: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/RuntimeBackgroundIndexingCoordinator.swift \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewModel.swift \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/BackgroundIndexingPopoverViewController.swift
git commit -m "$(cat <<'EOF'
feat(background-indexing): render Active / History sections in popover

Popover now groups batches under top-level ACTIVE (always present,
default-expanded) and HISTORY (rendered only when non-empty,
default-collapsed). Failed batches no longer linger in batchesRelay;
they land in history alongside successes and cancels. Clear Failed
button replaced by Clear History which empties historyRelay. Empty
state hides whenever active or history has content.
EOF
)"
```

---

## Task 4: Build verification + manual smoke test

**Files:** none modified.

This task is non-coding verification. No commits expected unless the smoke test surfaces a bug requiring an additional task.

- [ ] **Step 1: Clean build**

```bash
xcodebuildmcp clean --workspace ../MxIris-Reverse-Engineering.xcworkspace --scheme RuntimeViewerUsingAppKit
xcodebuildmcp build --workspace ../MxIris-Reverse-Engineering.xcworkspace --scheme RuntimeViewerUsingAppKit --configuration Debug
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Run the app and verify the smoke checklist**

Launch the built app via `xcodebuildmcp run` (or open from Xcode). Walk through the checklist from `Documentations/Evolution/0002-background-indexing.md` — the verification path was added with the 2026-04-29 design revision. Specifically:

1. Open Settings → Indexing → enable Background Indexing (depth ≥ 1).
2. Open a Document. The auto-launched `.appLaunch` batch appears under `ACTIVE`.
3. Wait for it to finish.
   - **Expected:** the batch disappears from `ACTIVE`. A `HISTORY` section appears containing one entry. The history section is collapsed by default.
4. Click the disclosure on `HISTORY`. The batch row appears (still collapsed). Click the disclosure on the batch — items show their final states.
5. Toggle Settings off, then on again. Confirm a new `.settingsEnabled` batch runs and lands in `HISTORY` newest-first when done.
6. Click `Clear History` in the footer. The `HISTORY` section disappears entirely; the `Clear History` button hides.
7. Trigger a failure (e.g. switch to a remote source whose dependencies are unreachable, or load an image whose deps include something Mach-O cannot open). The failed batch ends up in `HISTORY` — expand it and confirm the failed item shows the red xmark + error message.
8. Switch source (Local → XPC, or close + reopen the document). Confirm `HISTORY` clears.

- [ ] **Step 3: Quick code review of the diff**

Run `git diff main..HEAD -- RuntimeViewerPackages/ RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/` and skim. Common things to look for that are easy to miss in a manual smoke test:

- Did any reference to `clearFailedBatches` / `hasAnyFailure` / `Clear Failed` slip through? (`rg "clearFailed|hasAnyFailure|Clear Failed" RuntimeViewerPackages RuntimeViewerUsingAppKit` should return nothing meaningful.)
- Does `historyObservable` / `historyValue` get used only by the popover ViewModel, not other ViewModels? (Grep to confirm; cross-document leaks would mean the API surface should be tightened.)
- Did the `SectionHeaderCellView` end up inside the existing `extension BackgroundIndexingPopoverViewController { ... }` block, not a new extension?

If everything looks good and the smoke test passed, the feature is done. No further commits.

---

## Self-Review Notes

Spec coverage:

- ✅ Add `historyRelay` + public observable + `clearHistory()` — Task 1 Steps 1-2
- ✅ Route finalized batches into history (success / failure / cancelled) — Task 1 Step 3, Task 3 Step 13
- ✅ Clear history on engine swap — Task 1 Step 4
- ✅ `BackgroundIndexingNode.section` case + identifier + children — Task 2 Step 1
- ✅ `SectionHeaderCellView` private nested type — Task 2 Step 2
- ✅ Cell provider handles `.section` — Task 2 Step 3
- ✅ Active always rendered, history rendered only when non-empty — Task 3 Step 7
- ✅ Active default-expanded, history default-collapsed — Task 3 Step 12
- ✅ `Clear Failed` → `Clear History` button + binding — Task 3 Steps 8-10
- ✅ Drop `hasAnyFailure` / `Output.hasAnyFailure` / `clearFailedBatches()` — Task 3 Steps 1-2, 4-6, 14
- ✅ Empty-state hides when active OR history has content — Task 3 Step 11

Type / naming consistency check:

- `historyRelay` / `historyObservable` / `historyValue` consistent across Coordinator and ViewModel.
- `hasAnyHistory` consistent across ViewModel `@Observed`, Output struct, and ViewController binding.
- `Input.clearHistory` consistent across ViewModel struct and ViewController construction site.
- `clearHistory()` (Coordinator) called from `transform`'s `input.clearHistory.emitOnNext`.
- `BackgroundIndexingNode.SectionKind.{active,history}` cases consistent across enum, identifier, `SectionHeaderCellView.configure`, and `renderNodes`.

No placeholders detected. All code blocks are complete; all build / commit commands are concrete.

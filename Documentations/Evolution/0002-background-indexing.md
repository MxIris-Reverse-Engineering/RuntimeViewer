# 0002 - Background Indexing

- **Status**: Accepted
- **Author**: JH
- **Date**: 2026-04-24
- **Last Updated**: 2026-04-24

## Summary

Add an opt-in **Background Indexing** feature that eagerly parses ObjC and Swift metadata for the dependency closure of images already loaded in the target process. Work is driven by a per-`RuntimeEngine` Swift-Concurrency actor (`RuntimeBackgroundIndexingManager`), configured from Settings, surfaced in a Toolbar popover with live progress, and cancellable on demand.

## Motivation

Runtime Viewer currently indexes an image (parses ObjC/Swift metadata) only when the user explicitly opens it. For images that the target process has already loaded via dyld — e.g. UIKit, Foundation, and their transitive dependency closure — the first lookup pays a visible parsing cost because the work was never amortized.

Goals:

- Reduce user-perceived latency for common lookups by pre-parsing likely-to-be-used images.
- Preserve the existing on-demand `loadImage(at:)` path and its semantics.
- Let the user trade CPU for responsiveness via Settings (depth, concurrency).
- Give the user real-time visibility and a one-click cancel for running work.

### Non-goals

- No persistence of indexing history across app restarts (each session starts clean).
- No per-image (sub-batch) cancellation — batch-level cancellation only.
- No pause/resume. Only start / cancel.
- No automatic retry of failed items.
- No QoS tier beyond a single manual `prioritize(path:)` hook.
- No idle / low-power heuristics. Indexing runs regardless of system load.
- No exposure of indexing progress to MCP tools (MCP consumes results, not process state).
- No cross-Document / cross-Engine cache sharing beyond what already happens at the dyld level.
- No backwards-compatibility shims for callers assuming the old "loadImage == indexed" conflation.

## Proposed Solution

### Background Context

Source of truth captured during brainstorming and code verification:

- `RuntimeEngine` (actor) already tracks `imageList: [String]` (all dyld-known images) and `loadedImagePaths: Set<String>` (images we have processed via `loadImage(at:)`).
- Indexing for a single image currently happens inside `loadImage(at:)`: it calls `objcSectionFactory.section(for:)` and `swiftSectionFactory.section(for:)` and then triggers `reloadData()`.
- `MachOImage.dependencies: [DependedDylib]` gives the dependency list. MachOKit collapses `LC_LOAD_WEAK_DYLIB` into `DependType.load`, so only `.load`, `.reexport`, `.upwardLoad`, `.lazyLoad` are ever observed.
- The `Semaphore` package (`groue/Semaphore`) is already resolved for `RuntimeViewerCommunication`. It must be re-declared as an explicit product dependency of the `RuntimeViewerCore` target before the manager can import it.
- `MCPStatusPopoverViewController` + `MCPStatusToolbarItem` are the template for a Toolbar-anchored, RxSwift-driven popover.
- `RuntimeEngine` exposes a `request<T>(local:remote:)` dispatch primitive (`RuntimeEngine.swift:468`) used by every public method whose result depends on the target process (local vs. XPC/TCP). All new public engine methods introduced here use the same primitive.

### Terminology: Loaded vs. Indexed

This distinction is load-bearing.

- **Loaded** — the image is registered with dyld in the target process (appears in `DyldUtilities.imageNames()`). Being loaded says nothing about whether Runtime Viewer has parsed its ObjC / Swift metadata.
- **Indexed** — both `RuntimeObjCSectionFactory` and `RuntimeSwiftSectionFactory` have a **successfully-parsed** cached section for the image's path. Failure to parse does **not** count as indexed, which means failed paths will be retried on the next batch (see alternative D for why this is intentional).

A new API — `RuntimeEngine.isImageIndexed(path:)` — answers the indexed question. The existing `isImageLoaded(path:)` continues to answer the loaded question. Background indexing deduplication always uses `isImageIndexed`.

### Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerUsingAppKit (App target — no Runtime prefix)        │
│                                                                   │
│   Toolbar:    BackgroundIndexingToolbarItem (NSToolbarItem subclass)
│                + BackgroundIndexingToolbarItemView (NSProgressIndicator
│                  overlaid on SFSymbol icon)                       │
│                                                                   │
│   Popover:   BackgroundIndexingPopoverViewController              │
│                + BackgroundIndexingPopoverViewModel (ViewModel<MainRoute>)
│                + BackgroundIndexingNode enum (batch / item)       │
└───────────────────────────────────────────────────────────────────┘
                                ↕ RxSwift (UI binding layer only)
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerApplication (new types carry Runtime prefix)        │
│                                                                   │
│   RuntimeBackgroundIndexingCoordinator (class)                    │
│     ·  Subscribes to Document lifecycle and engine image-load events
│     ·  Observes Settings.backgroundIndexing via withObservationTracking
│     ·  Calls engine.backgroundIndexingManager.startBatch(...)     │
│     ·  Bridges the manager's AsyncStream<Event> into an RxSwift   │
│        Observable<[RuntimeIndexingBatch]> consumed by the popover │
│     ·  Exposes aggregate state (Driver<IndexingToolbarState>)     │
└───────────────────────────────────────────────────────────────────┘
                                ↕ async / await
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerCore (new types carry Runtime prefix)               │
│                                                                   │
│   RuntimeEngine (actor, existing)                                 │
│     + var backgroundIndexingManager: RuntimeBackgroundIndexingManager
│     + func isImageIndexed(path:) async throws -> Bool   (request/remote)
│     + func mainExecutablePath() async throws -> String  (request/remote)
│     + func loadImageForBackgroundIndexing(at:) async throws (request/remote)
│     + nonisolated var imageDidLoadPublisher: some Publisher<String, Never>
│                                                                   │
│   RuntimeBackgroundIndexingManager (actor, new — core)            │
│     public API:                                                   │
│       · events: AsyncStream<RuntimeIndexingEvent>                 │
│       · batches: [RuntimeIndexingBatch]                           │
│       · startBatch(rootImagePath:depth:maxConcurrency:reason:)    │
│              -> RuntimeIndexingBatchID                            │
│       · cancelBatch(_:)                                           │
│       · cancelAllBatches()                                        │
│       · prioritize(imagePath:)                                    │
│     internals:                                                    │
│       · activeBatches: [RuntimeIndexingBatchID: BatchState]       │
│       · AsyncSemaphore per batch for concurrency control          │
│       · per-batch driving Task hosting a TaskGroup                │
│                                                                   │
│   Sendable value types (all Hashable):                            │
│     RuntimeIndexingBatch, RuntimeIndexingBatchID,                 │
│     RuntimeIndexingTaskItem, RuntimeIndexingTaskState,            │
│     RuntimeIndexingEvent, RuntimeIndexingBatchReason,             │
│     ResolvedDependency                                            │
│                                                                   │
│   Utility:                                                        │
│     DylibPathResolver — resolves @rpath / @executable_path /      │
│     @loader_path install names against rpaths + image path        │
└───────────────────────────────────────────────────────────────────┘
```

### Remote Dispatch Model

All new `RuntimeEngine` public methods — `isImageIndexed`, `mainExecutablePath`, `loadImageForBackgroundIndexing` — are wrapped in the existing `request<T>(local:remote:)` primitive:

```swift
public func isImageIndexed(path: String) async throws -> Bool {
    try await request {
        objcSectionFactory.hasCachedSection(for: path)
            && swiftSectionFactory.hasCachedSection(for: path)
    } remote: { senderConnection in
        try await senderConnection.sendMessage(
            name: .isImageIndexed, request: path)
    }
}
```

Three new `CommandNames` cases — `.isImageIndexed`, `.mainExecutablePath`, `.loadImageForBackgroundIndexing` — are added, and the server-side handler table (`RuntimeEngine.swift:276-302`) gains:

```swift
setMessageHandlerBinding(forName: .isImageIndexed,            of: self) { $0.isImageIndexed(path:) }
setMessageHandlerBinding(forName: .mainExecutablePath,        of: self) { $0.mainExecutablePath }
setMessageHandlerBinding(forName: .loadImageForBackgroundIndexing, of: self) { $0.loadImageForBackgroundIndexing(at:) }
```

`RuntimeBackgroundIndexingManager` itself runs **server-side only**. The manager's events, batches, and cancellation APIs are not mirrored over XPC in this proposal; the UI consumes manager state from the hosting process via the coordinator. Mirroring is left to a follow-up if needed.

### Components

#### `RuntimeBackgroundIndexingManager` (actor)

Owns every running batch and every event stream. Created by `RuntimeEngine` at init, holds an unowned reference back to the engine.

```swift
public actor RuntimeBackgroundIndexingManager {
    public nonisolated var events: AsyncStream<RuntimeIndexingEvent> { ... }

    public func startBatch(
        rootImagePath: String,
        depth: Int,
        maxConcurrency: Int,
        reason: RuntimeIndexingBatchReason
    ) async -> RuntimeIndexingBatchID

    public func cancelBatch(_ id: RuntimeIndexingBatchID)
    public func cancelAllBatches()
    public func prioritize(imagePath: String)
    public func currentBatches() -> [RuntimeIndexingBatch]
}
```

#### Sendable value types

```swift
public struct RuntimeIndexingBatchID: Hashable, Sendable { public let raw: UUID }

public enum RuntimeIndexingBatchReason: Sendable, Hashable {
    case appLaunch
    case imageLoaded(path: String)
    case manual
    case settingsEnabled
}

public enum RuntimeIndexingTaskState: Sendable, Hashable {
    case pending
    case running
    case completed
    case failed(message: String)
    case cancelled
}

public struct RuntimeIndexingTaskItem: Sendable, Identifiable, Hashable {
    public let id: String          // image path (install name if unresolved)
    public let resolvedPath: String?
    public var state: RuntimeIndexingTaskState
    public var hasPriorityBoost: Bool
}

public struct RuntimeIndexingBatch: Sendable, Identifiable, Hashable {
    public let id: RuntimeIndexingBatchID
    public let rootImagePath: String
    public let depth: Int
    public let reason: RuntimeIndexingBatchReason
    public var items: [RuntimeIndexingTaskItem]
    public var isCancelled: Bool
    public var isFinished: Bool
}

public struct ResolvedDependency: Sendable, Hashable {
    public let installName: String
    public let resolvedPath: String?
}

public enum RuntimeIndexingEvent: Sendable {
    case batchStarted(RuntimeIndexingBatch)
    case taskStarted(batchID: RuntimeIndexingBatchID, path: String)
    case taskFinished(batchID: RuntimeIndexingBatchID, path: String,
                      result: RuntimeIndexingTaskState)
    case taskPrioritized(batchID: RuntimeIndexingBatchID, path: String)
    case batchFinished(RuntimeIndexingBatch)
    case batchCancelled(RuntimeIndexingBatch)
}
```

All value types are `Hashable` so they compose into `BackgroundIndexingNode: Hashable` without extra conformance work.

#### `RuntimeBackgroundIndexingCoordinator`

Created once per Document (held by `DocumentState`). Responsibilities:

1. Observe `Settings.backgroundIndexing` via `withObservationTracking` (see Settings section) → enable / disable / restart.
2. Listen for the engine's `imageDidLoadPublisher` → start a dependency batch for that image.
3. Listen for Sidebar's image-selection signal → call `manager.prioritize(path:)`.
4. Bridge `manager.events` (AsyncStream) → `eventRelay: PublishRelay<RuntimeIndexingEvent>` (RxSwift).
5. Maintain `batchesRelay: BehaviorRelay<[RuntimeIndexingBatch]>` reduced from events. **Finished batches that contain any failed item are retained** in `batchesRelay` until the user explicitly dismisses them via "Clear Failed" in the popover; clean finishes and cancels drop out immediately.
6. Expose `aggregateStateDriver: Driver<IndexingToolbarState>`. `hasFailures` is derived from the retained failed batches.
7. Own per-Document batch tracking: `[Document.ID: Set<RuntimeIndexingBatchID>]`.

### Data Flow Scenarios

#### Scenario A — App launch / Document opened with indexing enabled

```
Document opens
  → DocumentState ready, RuntimeEngine available
  → Coordinator.documentDidOpen(documentState)
      reads Settings.backgroundIndexing
      if !isEnabled → return
      rootPath = try await engine.mainExecutablePath()
      batchID = await engine.backgroundIndexingManager.startBatch(
          rootImagePath: rootPath,
          depth: settings.depth,
          maxConcurrency: settings.maxConcurrency,
          reason: .appLaunch)
      Toolbar item transitions idle → indexing
```

#### Scenario B — User loads a new image at runtime

```
User action → documentState.loadImage(at: path)
  → RuntimeEngine.loadImage(at:) (existing path completes)
  → Engine emits imageDidLoadPublisher(path)
  → Coordinator (if isEnabled):
      batchID = manager.startBatch(
          rootImagePath: path,
          depth: settings.depth,
          maxConcurrency: settings.maxConcurrency,
          reason: .imageLoaded(path: path))
      Dependency graph expansion skips items already indexed
```

#### Scenario C — User selects an image already queued

```
Sidebar selection change → SidebarViewModel emits imageSelected(path)
  → Coordinator → manager.prioritize(imagePath: path)
      manager walks activeBatches, finds pending items matching path
      marks hasPriorityBoost = true, adds to priorityBoostPaths set
      emits .taskPrioritized
      running / completed / absent paths: silent no-op
```

#### Scenario D — Document closed

```
Document.close()
  → Coordinator.documentWillClose(documentState)
      for batchID in Coordinator.batchesFor(document):
          await manager.cancelBatch(batchID)
      remove document entry
```

#### Scenario E — Settings toggle (via `withObservationTracking`)

```
Coordinator.subscribeToSettings():
    withObservationTracking {
        let snapshot = Settings.shared.backgroundIndexing
        _ = snapshot.isEnabled
        _ = snapshot.depth
        _ = snapshot.maxConcurrency
    } onChange: { [weak self] in
        Task { @MainActor in
            self?.handleSettingsChange()
            self?.subscribeToSettings()   // re-register
        }
    }

handleSettingsChange:
    isEnabled false → true:
        for every open Document: run Scenario A (root = mainExecutablePath)
        (do NOT replay historical loadImage calls)
    isEnabled true → false:
        await manager.cancelAllBatches()
    depth / maxConcurrency change while enabled:
        no-op against running batches; values apply to the next startBatch.
```

Rationale: `Settings` is declared `@Observable`, so `withObservationTracking` is the native fit. Re-registering on each change is the documented one-shot-observer recovery pattern; it keeps the observer alive across each settings mutation without adding Combine infrastructure.

#### Scenario F — User cancels from the popover

```
Popover cancel button → ViewModel cancelBatchRelay.accept(batchID)
  → Coordinator → await manager.cancelBatch(id)
      batch's driving Task → task.cancel()
      TaskGroup children inherit cancellation
      runSingleIndex catches CancellationError → item state .cancelled
      already-completed items retain .completed
      emits .batchCancelled
```

### Dependency Graph Expansion

Implemented by `expandDependencyGraph(rootPath:depth:)` inside the manager. Runs synchronously at the start of `startBatch` so the batch's total item count is known before the first `taskStarted` event fires — this keeps the popover progress bar accurate from the first frame.

```swift
// Pseudocode
func expandDependencyGraph(rootPath: String, depth: Int) async
    -> [RuntimeIndexingTaskItem]
{
    var visited: Set<String> = []
    var items: [RuntimeIndexingTaskItem] = []
    var frontier: [(path: String, level: Int)] = [(rootPath, 0)]

    while !frontier.isEmpty {
        let (path, level) = frontier.removeFirst()
        guard visited.insert(path).inserted else { continue }

        if await engine.isImageIndexed(path: path) { continue }

        items.append(.init(id: path, resolvedPath: path,
                           state: .pending, hasPriorityBoost: false))
        guard level < depth else { continue }

        for dep in await engine.dependencies(for: path) {
            if let resolved = dep.resolvedPath {
                if !visited.contains(resolved) {
                    frontier.append((resolved, level + 1))
                }
            } else if visited.insert(dep.installName).inserted {
                items.append(.init(id: dep.installName, resolvedPath: nil,
                                   state: .failed(message: "path unresolved"),
                                   hasPriorityBoost: false))
            }
        }
    }
    return items
}
```

`Array.removeFirst()` is sufficient for the depths we allow (≤ 5); a deque is not warranted.

#### Dependency type filter

- **Included**: `.load`, `.reexport`, `.upwardLoad`.
- **Skipped**: `.lazyLoad` — lazy-loaded dylibs may never actually load at runtime, so eagerly parsing them is speculative and wasteful.

`LC_LOAD_WEAK_DYLIB` is decoded by MachOKit as `DependType.load` (see `MachOImage.swift:168-173`); the `.weakLoad` enum case never arrives from `dependencies`, so no explicit branch is needed.

#### Path resolution (`DylibPathResolver`)

Install names come in four shapes:

| Shape | Resolution |
|-------|------------|
| `/System/Library/...` (absolute) | Use as-is. Verify file exists. |
| `@rpath/Foo.framework/Foo` | For each `LC_RPATH` on the rooting image, substitute and take the first existing path. |
| `@executable_path/...` | Substitute using the main executable's directory. |
| `@loader_path/...` | Substitute using the current image's directory. |

Returns `String?` — `nil` maps to a `.failed("path unresolved")` task item that does not recurse.

### Concurrency Model

Entirely Swift Concurrency — no `OperationQueue`, no `DispatchQueue`, no RxSwift in the work path. RxSwift is used only at the UI binding layer inside the coordinator.

```swift
// Manager internals (sketch)
private func runBatch(id: RuntimeIndexingBatchID) async {
    let state = activeBatches[id]!
    eventsContinuation.yield(.batchStarted(state.batch))

    let semaphore = AsyncSemaphore(value: state.maxConcurrency)
    await withTaskGroup(of: Void.self) { group in
        while let item = popNextPrioritizedPending(batchID: id) {
            try? await semaphore.waitUnlessCancelled()
            if Task.isCancelled { break }
            group.addTask { [weak self] in
                defer { Task { await semaphore.signal() } }
                await self?.runSingleIndex(batchID: id, path: item.id)
            }
        }
    }

    finalizeBatch(id)    // emits .batchFinished or .batchCancelled
}

private func runSingleIndex(batchID: RuntimeIndexingBatchID,
                            path: String) async {
    updateItemState(batchID, path, .running)
    eventsContinuation.yield(.taskStarted(batchID: batchID, path: path))
    do {
        try Task.checkCancellation()
        try await engine.loadImageForBackgroundIndexing(at: path)
        updateItemState(batchID, path, .completed)
        eventsContinuation.yield(.taskFinished(
            batchID: batchID, path: path, result: .completed))
    } catch is CancellationError {
        updateItemState(batchID, path, .cancelled)
    } catch {
        let message = error.localizedDescription
        updateItemState(batchID, path, .failed(message: message))
        eventsContinuation.yield(.taskFinished(
            batchID: batchID, path: path, result: .failed(message: message)))
    }
}
```

#### Priority queue mechanics

Each batch state owns an `Array<String>` of pending paths and a `Set<String>` of priority-boost members. `prioritize(imagePath:)` only mutates the set (and emits `.taskPrioritized`); the pop helper scans the pending array for the first boosted path, falling back to the array head when none is boosted. Priority cannot preempt an already-running child task — Swift structured concurrency does not support that. `prioritize` on a running or completed path is a silent no-op.

#### `AsyncSemaphore`

From `groue/Semaphore`. The dependency is already resolved at package level but is only declared for `RuntimeViewerCommunication`; this proposal adds an explicit `.product(name: "Semaphore", package: "Semaphore")` entry to the `RuntimeViewerCore` target's dependency list.

#### UI refresh suppression

`loadImageForBackgroundIndexing(at:)` does **not** call `reloadData()`. Calling it N times during a batch would storm the sidebar. The coordinator triggers `await engine.reloadData(isReloadImageNodes: false)` once per `.batchFinished` / `.batchCancelled` event so the sidebar picks up the newly-indexed icons in a single update.

### Settings

#### `BackgroundIndexing` struct (`Settings+Types.swift`)

```swift
@Codable @MemberInit public struct BackgroundIndexing {
    @Default(false) public var isEnabled: Bool
    @Default(1)     public var depth: Int               // valid 1...5
    @Default(4)     public var maxConcurrency: Int      // valid 1...8
    public static let `default` = Self()
}
```

Added to the root `Settings` class (which is `@Observable`) as:

```swift
@Default(BackgroundIndexing.default)
public var backgroundIndexing: BackgroundIndexing = .init() {
    didSet { scheduleAutoSave() }
}
```

Persisted by the existing `SettingsFileSystemStorage` auto-save. No Combine publisher is added to `Settings`.

#### `BackgroundIndexingSettingsView` (SwiftUI)

At `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/BackgroundIndexingSettingsView.swift`. Reached via a new `SettingsPage.backgroundIndexing` case in `SettingsRootView.swift` (icon `square.stack.3d.down.right`, title `"Background Indexing"`).

Form contents:
- `Toggle "Enable background indexing"` bound to `$settings.isEnabled`.
- Caption paragraph explaining behavior.
- `Stepper` for depth (1...5), caption explaining the semantics.
- `Stepper` for maxConcurrency (1...8), caption noting the CPU tradeoff.

Cancel-all stays in the popover footer, not in Settings.

#### Settings change propagation

The coordinator subscribes via `withObservationTracking` on `Settings.shared.backgroundIndexing`, re-registering inside `onChange`. See Scenario E for the concrete flow.

### UI: Toolbar Item + Popover

#### `BackgroundIndexingToolbarItem`

`NSToolbarItem` subclass registered in `MainToolbarController.swift`. Identifier `backgroundIndexing`. Placed next to the existing `mcpStatus` item in default and allowed identifier lists (the existing case is literally `mcpStatus(sender:)`, not `mcpStatusPopover`).

`view` is a `BackgroundIndexingToolbarItemView` (NSView) holding a centered 16pt icon (SF Symbol `square.stack.3d.down.right`) with an `NSProgressIndicator(style: .spinning)` overlaid when state is `indexing` or `hasFailures`. A small red badge dot is drawn over the bottom-right corner for `hasFailures`.

`IndexingToolbarState` enum: `.idle`, `.disabled`, `.indexing(percent: Double?)`, `.hasFailures(percent: Double?)`.

The view binds to a `Driver<IndexingToolbarState>` pushed from the coordinator via a weakly-held observer set at toolbar construction.

Clicking the item triggers the **existing** `MainRoute` surface with a new case:

```swift
case backgroundIndexing(sender: NSView)
```

Note the name has **no `Popover` suffix**, matching the sibling `mcpStatus(sender:)` precedent.

#### `BackgroundIndexingPopoverViewController`

Base class `UXKitViewController<BackgroundIndexingPopoverViewModel>`. The ViewModel is `ViewModel<MainRoute>` — there is **no** separate `BackgroundIndexingPopoverRoute`. All routing goes through `MainRoute` cases (`openSettings`, `dismiss`, etc.) that already exist at the main level. Fixed width 380, height from ~120 (empty state) up to 400 (outline view with scroll).

Content layout:

- Header: `Label("Background Indexing")` plus a subtitle `Label` reading the aggregate progress.
- Empty state A (disabled): icon + "Background indexing is disabled" + `"Open Settings"` button.
- Empty state B (enabled, no batches): icon + "No active indexing tasks".
- Body: `StatefulOutlineView` rendering `BackgroundIndexingNode`.
- Footer: `HStackView` with `Cancel All` button (disabled when no active batch), `Clear Failed` button (visible only when there are retained failed batches), and `Close` button.

`BackgroundIndexingNode`:

```swift
enum BackgroundIndexingNode: Hashable {
    case batch(RuntimeIndexingBatch)
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)
}
```

Outline cells:

- Batch row: title derived from `reason`, `"{completed}/{total}"`, and a cancel button. Clicking cancel fires `cancelBatchRelay.accept(batchID)`.
- Item row: status icon (pending grey dot / running spinning / completed green ✓ / failed red ✗ / cancelled grey ⊘) + display name + secondary label. Failed rows show the full install name and the error message. Rows with `hasPriorityBoost == true` show a `"priority"` tag.

Defensive outline-view data source branches use `preconditionFailure("unexpected outline item type")` rather than returning a zero-initialized batch, so mis-wired callers surface immediately.

#### `BackgroundIndexingPopoverViewModel`

```swift
final class BackgroundIndexingPopoverViewModel: ViewModel<MainRoute> {
    @Observed private(set) var nodes: [BackgroundIndexingNode] = []
    @Observed private(set) var isEnabled: Bool = false
    @Observed private(set) var hasAnyBatch: Bool = false
    @Observed private(set) var subtitle: String = ""

    struct Input {
        let cancelBatch: Signal<RuntimeIndexingBatchID>
        let cancelAll: Signal<Void>
        let clearFailed: Signal<Void>
        let openSettings: Signal<Void>
    }
    struct Output {
        let nodes: Driver<[BackgroundIndexingNode]>
        let isEnabled: Driver<Bool>
        let hasAnyBatch: Driver<Bool>
        let subtitle: Driver<String>
    }

    func transform(_ input: Input) -> Output { ... }
}
```

`isEnabled` is kept in sync with `Settings.shared.backgroundIndexing.isEnabled` via the **same** `withObservationTracking` re-registration loop used by the coordinator — it is not read once in `transform` and forgotten. The popover's empty states therefore react to the Settings toggle while open.

`input.openSettings.emitOnNext` fires `router.trigger(.openSettings)` — the existing `MainRoute.openSettings` case.

### Error Handling

| Failure site | Behavior | UI |
|---|---|---|
| `MachOImage(name: path)` returns nil during graph expansion | Item → `.failed("cannot open MachOImage")`, no recursion | red ✗ + tooltip |
| `@rpath` / `@executable_path` / `@loader_path` unresolved | Item → `.failed("path unresolved")`, no recursion | red ✗ + original install name |
| `DyldUtilities.loadImage` throws (codesign, sandbox, missing file) | Item → `.failed(dlopenError.localizedDescription)` | red ✗ |
| ObjC section parse throws | Item → `.failed(objcParseError)` | red ✗ |
| Swift section parse throws | Item → `.failed(swiftParseError)`. `isImageIndexed` stays false because at least one factory has no cache for this path | red ✗ |
| `Task.checkCancellation` throws | Item → `.cancelled`, no error event | grey ⊘ |
| Coordinator receives event after Document released | `[weak self]` drops event silently | — |

`isImageIndexed(path:)` requires **both** factories to have a successfully-cached entry. Failure to parse leaves no cache entry, so the path re-enters the next batch's frontier. This is intentional — see alternative D.

### Race / Edge Conditions

1. **User manual `loadImage(path)` while a background batch is indexing the same path.**
   The ObjC / Swift factories must serialize per-path parsing so two concurrent callers do not both parse. The plan phase verifies (and, if needed, introduces a `[String: Task<Section, Error>]` in-flight map inside each factory).

2. **Batch cancellation with partially-completed items.**
   Completed items retain `.completed`; `loadedImagePaths` inserts are not rolled back. In-flight items that receive `CancellationError` mid-parse may leave the factories with partial sections — acceptable for this iteration; `isImageIndexed` then returns false and a future explicit load redoes the work.

3. **Multiple batches for the same root.**
   The manager dedupes: if an active batch already has `rootImagePath == root` and `reason`'s discriminant matches, return its existing `RuntimeIndexingBatchID` instead of starting another.

4. **Document closure while events are mid-flight.**
   `AsyncStream.Continuation.finish()` is called when the engine (and its manager) deinit. The coordinator's `Task { for await event in manager.events }` exits cleanly.

### Assumptions

1. **`DocumentState.runtimeEngine` is immutable for the lifetime of a Document.** The property is declared `@Observed public var runtimeEngine: RuntimeEngine = .local` (`DocumentState.swift:10-11`) for historical reasons, but callers do not reassign it after Document creation. The coordinator captures `engine = documentState.runtimeEngine` once at init; if this assumption is violated, batches are dispatched to the wrong engine. A doc comment on the property reinforces this contract.

2. **`RuntimeBackgroundIndexingManager` runs in the engine's hosting process only.** For remote (XPC / directTCP) sources, the *engine methods* are mirrored via `request { local } remote: { RPC }`, but the *manager* lives in the server-side engine's actor. UI clients consume manager state only from their local engine reference.

3. **Settings mutation frequency is low.** `withObservationTracking` re-registration fires once per property mutation. Because Settings sliders / toggles run at human-UI cadence, the re-registration cost is negligible.

### Testing Strategy

Added under `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/`.

1. `DylibPathResolverTests`
   - `@rpath` single + multiple `LC_RPATH`, hit + miss.
   - `@executable_path` and `@loader_path` substitution.
   - Absolute path passthrough.
2. `RuntimeBackgroundIndexingManagerTests` using a `MockBackgroundIndexingEngine` (`@unchecked Sendable`) conforming to a new internal `BackgroundIndexingEngineRepresenting` protocol.
   - Graph expansion at depth 0, 1, 2; already-indexed short-circuit.
   - `prioritize` causes the next dispatch to pick a boosted path. **Timing-based assertions are replaced with event-order assertions** (`taskStarted` sequence) to avoid CI flakiness.
   - `cancelBatch` stops in-flight work, marks remaining pending items cancelled.
   - Concurrency cap honored (spy counter never exceeds configured value).
   - Event ordering: `batchStarted` precedes any `taskStarted`; `batchFinished` last.
3. `RuntimeIndexingBatch` / event reducers if non-trivial reduction logic ends up on the coordinator side.

UI is not automated (no existing UI test harness); the plan includes a manual verification checklist.

### File Inventory

#### New files

```
RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/
    RuntimeBackgroundIndexingManager.swift
    RuntimeIndexingBatch.swift
    RuntimeIndexingBatchID.swift
    RuntimeIndexingBatchReason.swift
    RuntimeIndexingTaskItem.swift
    RuntimeIndexingTaskState.swift
    RuntimeIndexingEvent.swift
    ResolvedDependency.swift
    BackgroundIndexingEngineRepresenting.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/
    DylibPathResolver.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/
    RuntimeEngine+BackgroundIndexing.swift

RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/
    DylibPathResolverTests.swift
    RuntimeBackgroundIndexingManagerTests.swift
    MockBackgroundIndexingEngine.swift

RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/
    BackgroundIndexingSettingsView.swift

RuntimeViewerPackages/Sources/RuntimeViewerApplication/BackgroundIndexing/
    RuntimeBackgroundIndexingCoordinator.swift

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/BackgroundIndexing/
    BackgroundIndexingToolbarItem.swift
    BackgroundIndexingToolbarItemView.swift
    BackgroundIndexingPopoverViewController.swift
    BackgroundIndexingPopoverViewModel.swift
    BackgroundIndexingNode.swift
```

Note the absence of a `BackgroundIndexingPopoverRoute.swift` — routing is via `MainRoute`.

#### Modified files

```
RuntimeViewerCore/Package.swift
    + add .product(name: "Semaphore", package: "Semaphore") to RuntimeViewerCore target

RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
    + BackgroundIndexing struct

RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift
    + backgroundIndexing property

RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift
    + SettingsPage.backgroundIndexing case and contentView branch

RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
    + backgroundIndexingManager stored property (set at end of init)
    + isImageIndexed(path:) with request/remote dispatch
    + mainExecutablePath() with request/remote dispatch
    + loadImageForBackgroundIndexing(at:) with request/remote dispatch
    + imageDidLoadPublisher (PassthroughSubject<String, Never>)
    + emit imageDidLoadSubject.send(path) on loadImage(at:) success
    + access level bumped to internal on objcSectionFactory / swiftSectionFactory
    + new CommandNames + setMessageHandlerBinding handlers for the three new methods

RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
    + hasCachedSection(for:) inspector
    + optional per-path in-flight dedupe (plan verifies)

RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift
    + backgroundIndexingCoordinator property
    + doc comment asserting runtimeEngine immutability

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainRoute.swift
    + backgroundIndexing(sender:) case (no "Popover" suffix)

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift
    + backgroundIndexing item identifier + factory
    + wireBackgroundIndexing(item:) hookup

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
    + backgroundIndexing(sender:) transition case

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift
    + invoke coordinator.documentDidOpen / documentWillClose
```

All new files under `RuntimeViewerUsingAppKit/.../BackgroundIndexing/` must be added to the Xcode project manually (consistent with the MCPServer pattern noted in project memory).

## Alternatives Considered

### A. Subscribe to `Settings` via a new `Combine.PassthroughSubject`

Add a `PassthroughSubject<Settings, Never>` to `Settings`, emit from `scheduleAutoSave`, and let the coordinator subscribe with Combine. Rejected because `Settings` is already `@Observable` — adding a parallel Combine channel would duplicate the source of truth and force future readers to pick one. `withObservationTracking` is the native fit and scales to the few properties we observe.

### B. Separate `BackgroundIndexingPopoverRoute` enum

Mirror the `MCPStatusPopover` structure and define a dedicated Route enum. Rejected because `MainCoordinator` is already bound to `SceneCoordinator<MainRoute, MainTransition>`; adding a second, conditional `Router` conformance would not compile. Forwarding via a separate adapter was considered but is heavier than just adding a case to `MainRoute`, which costs one line.

### C. Non-dispatching local-only engine extensions

Keep `isImageIndexed` / `mainExecutablePath` / `loadImageForBackgroundIndexing` as pure local reads (no `request { local } remote: { RPC }` wrapping). Rejected because this would silently return wrong data when the document targets a remote source (XPC / directTCP) — the local engine has no knowledge of the remote process's loaded images.

### D. Cache empty/nil parse results to create an "attempted" bit

Let `hasCachedSection(for:)` count failed parses as indexed, so failures are not retried. Rejected: the factory cache currently stores a successful `Section` value, and introducing a `Result<Section, Error>` or parallel `attemptedFailures` set propagates through many call sites. The simpler semantics — "indexed" = "parsed successfully" — means failed paths retry on the next batch, which is acceptable given how rare deterministic-but-recoverable parse failures are in practice.

### E. Drop finished/cancelled batches from the UI immediately

Simpler reducer logic: when `.batchFinished` / `.batchCancelled` arrives, remove the batch from the coordinator relay and the popover forgets it existed. Rejected because failed batches carry actionable information; silently losing them means the toolbar's `hasFailures` indicator never surfaces. Instead, finished batches with any `.failed` item are retained until the user clicks `Clear Failed` in the popover.

## Impact

- **Breaking changes**: No. The feature is opt-in (default off) and does not alter the existing `loadImage(at:)` semantics.
- **Files affected**: see File Inventory above.
- **Migration needed**: No. Settings defaults are written by the existing `@Codable` path; absent keys fall back to the `@Default` values.

## Decision Log

| Date | Decision | Reason |
|------|----------|--------|
| 2026-04-24 | Created as Draft | Spec derived from brainstorming on opt-in, Swift-Concurrency-based background indexing for dyld-loaded dependency closures |
| 2026-04-24 | Settings subscription → `withObservationTracking` | `Settings` is `@Observable`; avoid parallel Combine channel |
| 2026-04-24 | `BackgroundIndexingPopoverRoute` merged into `MainRoute` | `MainCoordinator` is `SceneCoordinator<MainRoute, …>`; conditional second conformance not compilable |
| 2026-04-24 | All new engine methods use `request { local } remote: { RPC }` | Remote (XPC / directTCP) sources would otherwise read local-process data |
| 2026-04-24 | `isImageIndexed` = "successfully parsed" only | Avoids Result-wrapping every factory cache entry; failed paths retry |
| 2026-04-24 | `DocumentState.runtimeEngine` treated as immutable | Coordinator captures engine once at init; reassignment is out of scope |
| 2026-04-24 | Finished batches with failures retained until dismissed | Preserves actionable failure information; drives toolbar `hasFailures` state |
| 2026-04-24 | Status → Accepted | Review decisions incorporated; plan regenerated to match |

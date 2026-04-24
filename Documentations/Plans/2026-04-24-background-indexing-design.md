# Background Indexing Design

## Overview

Runtime Viewer currently indexes an image (parses ObjC/Swift metadata) only when the user explicitly opens it. For images that the target process already has loaded via dyld — e.g. UIKit, Foundation, and the rest of the transitive dependency closure — the first lookup pays a visible parsing cost.

**Background Indexing** is an opt-in feature that eagerly parses ObjC/Swift metadata for the dependency closure of known images. It runs on a per-Document basis, inside each `RuntimeEngine` actor, driven by Swift Concurrency. It is configurable from Settings, its progress is visible in a Toolbar popover, and running batches can be cancelled.

## Goals

- Reduce user-perceived latency for common lookups by pre-parsing likely-to-be-used images.
- Preserve the existing on-demand `loadImage(at:)` path and its semantics.
- Let the user trade CPU for responsiveness via Settings (depth, concurrency).
- Give the user real-time visibility and a one-click cancel for running work.

## Non-Goals (explicit YAGNI)

- No persistence of indexing history across app restarts (each session starts clean).
- No per-image (sub-batch) cancellation — batch-level cancellation only.
- No pause/resume. Only start / cancel.
- No automatic retry of failed items.
- No QoS tier beyond a single manual `prioritize(path:)` hook.
- No idle / low-power heuristics. Indexing runs regardless of system load.
- No exposure of indexing progress to MCP tools (MCP consumes results, not process state).
- No cross-Document / cross-Engine cache sharing beyond what already happens at the dyld level.
- No backwards-compatibility shims for callers assuming the old "loadImage == indexed" conflation.

## Background Context from the Codebase

Source of truth captured during brainstorming:

- `RuntimeEngine` (actor) already tracks `imageList: [String]` (all dyld-known images) and `loadedImagePaths: Set<String>` (images we have processed via `loadImage(at:)`).
- Indexing for a single image currently happens inside `loadImage(at:)`: it calls `objcSectionFactory.section(for:)` and `swiftSectionFactory.section(for:)` and then triggers `reloadData()`.
- `MachOImage.dependencies: [DependedDylib]` (MachOKit) gives the dependency list with a `type` discriminator (`load` / `weakLoad` / `reexport` / `upwardLoad` / `lazyLoad`).
- The `Semaphore` package (groue/Semaphore — `AsyncSemaphore`) is already resolved.
- `MCPStatusPopoverViewController` + `MCPStatusToolbarItem` are the existing template for a Toolbar-anchored, RxSwift-driven popover.

## Terminology: Loaded vs. Indexed

This distinction is load-bearing. The rest of the doc uses it strictly.

- **Loaded** — the image is registered with dyld in the target process (appears in `DyldUtilities.imageNames()`). Being loaded says nothing about whether Runtime Viewer has parsed its ObjC / Swift metadata.
- **Indexed** — both `RuntimeObjCSectionFactory` and `RuntimeSwiftSectionFactory` have a cached section for the image's path, meaning metadata extraction has been attempted and the result (possibly empty) is memoized.

A new API — `RuntimeEngine.isImageIndexed(path:) -> Bool` — answers the indexed question. The existing `isImageLoaded(path:)` continues to answer the loaded question. Background indexing deduplication always uses `isImageIndexed`.

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerUsingAppKit (App target — no Runtime prefix)         │
│                                                                    │
│   Toolbar:    BackgroundIndexingToolbarItem (NSToolbarItem subclass)
│                + BackgroundIndexingToolbarItemView (NSProgressIndicator
│                  overlaid on SFSymbol icon)                        │
│                                                                    │
│   Popover:   BackgroundIndexingPopoverViewController               │
│                + BackgroundIndexingPopoverViewModel                │
│                + BackgroundIndexingNode enum (batch / item)        │
└───────────────────────────────────────────────────────────────────┘
                                ↕ RxSwift (UI binding layer only)
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerApplication (new types carry Runtime prefix)         │
│                                                                    │
│   RuntimeBackgroundIndexingCoordinator (class)                     │
│     ·  Subscribes to Document lifecycle and engine image-load events
│     ·  Reads Settings.backgroundIndexing                           │
│     ·  Calls engine.backgroundIndexingManager.startBatch(...)      │
│     ·  Bridges the manager's AsyncStream<Event> into an RxSwift    │
│        Observable<[RuntimeIndexingBatch]> consumed by the popover  │
│     ·  Exposes aggregate state (Driver<IndexingToolbarState>)       │
└───────────────────────────────────────────────────────────────────┘
                                ↕ async / await
┌───────────────────────────────────────────────────────────────────┐
│  RuntimeViewerCore (new types carry Runtime prefix)                │
│                                                                    │
│   RuntimeEngine (actor, existing)                                  │
│     + var backgroundIndexingManager: RuntimeBackgroundIndexingManager
│     + func isImageIndexed(path:) -> Bool                           │
│     + func mainExecutablePath() -> String                          │
│     + func loadImageForBackgroundIndexing(at:) async throws (internal)
│                                                                    │
│   RuntimeBackgroundIndexingManager (actor, new — core)             │
│     public API:                                                    │
│       · events: AsyncStream<RuntimeIndexingEvent>                  │
│       · batches: [RuntimeIndexingBatch]                            │
│       · startBatch(rootImagePath:depth:maxConcurrency:reason:)     │
│              -> RuntimeIndexingBatchID                             │
│       · cancelBatch(_:)                                            │
│       · cancelAllBatches()                                         │
│       · prioritize(imagePath:)                                     │
│     internals:                                                     │
│       · activeBatches: [RuntimeIndexingBatchID: BatchState]        │
│       · AsyncSemaphore per batch for concurrency control           │
│       · per-batch driving Task hosting a TaskGroup                 │
│                                                                    │
│   Sendable value types (new):                                      │
│     RuntimeIndexingBatch, RuntimeIndexingBatchID,                  │
│     RuntimeIndexingTaskItem, RuntimeIndexingTaskState,             │
│     RuntimeIndexingEvent, RuntimeIndexingBatchReason               │
│                                                                    │
│   Utility (new):                                                   │
│     DylibPathResolver — resolves @rpath / @executable_path /       │
│     @loader_path install names against a MachOImage                │
└───────────────────────────────────────────────────────────────────┘
```

## Components

### `RuntimeBackgroundIndexingManager` (actor)

Owns every running batch and every event stream. Created by `RuntimeEngine` at init, unowned-references the engine back.

```swift
public actor RuntimeBackgroundIndexingManager {
    public nonisolated var events: AsyncStream<RuntimeIndexingEvent> { ... }

    public func startBatch(
        rootImagePath: String,
        depth: Int,
        maxConcurrency: Int,
        reason: RuntimeIndexingBatchReason
    ) -> RuntimeIndexingBatchID

    public func cancelBatch(_ id: RuntimeIndexingBatchID)
    public func cancelAllBatches()
    public func prioritize(imagePath: String)
    public func currentBatches() -> [RuntimeIndexingBatch]
}
```

### Sendable value types

```swift
public struct RuntimeIndexingBatchID: Hashable, Sendable { let raw: UUID }

public enum RuntimeIndexingBatchReason: Sendable {
    case appLaunch
    case imageLoaded(path: String)
    case manual
    case settingsEnabled
}

public enum RuntimeIndexingTaskState: Sendable, Equatable {
    case pending
    case running
    case completed
    case failed(message: String)
    case cancelled
}

public struct RuntimeIndexingTaskItem: Sendable, Identifiable {
    public let id: String          // image path (install name if unresolved)
    public let resolvedPath: String?
    public var state: RuntimeIndexingTaskState
    public var hasPriorityBoost: Bool
}

public struct RuntimeIndexingBatch: Sendable, Identifiable {
    public let id: RuntimeIndexingBatchID
    public let rootImagePath: String
    public let depth: Int
    public let reason: RuntimeIndexingBatchReason
    public var items: [RuntimeIndexingTaskItem]
    public var isCancelled: Bool
    public var isFinished: Bool
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

### `RuntimeBackgroundIndexingCoordinator`

Created once per Document (held by `DocumentState` or a peer). Responsibilities:

1. Listen for `Settings.backgroundIndexing` changes → enable / disable / restart.
2. Listen for engine's `didLoadImage(path:)` signal → start a dependency batch for that image.
3. Listen for Sidebar's image-selection signal → call `manager.prioritize(path:)`.
4. Bridge `manager.events` (AsyncStream) → `eventRelay: PublishRelay<RuntimeIndexingEvent>` (RxSwift).
5. Maintain `batchesRelay: BehaviorRelay<[RuntimeIndexingBatch]>` reduced from events, for the popover to drive off of.
6. Expose `aggregateStateDriver: Driver<IndexingToolbarState>` used by the Toolbar item.
7. Own per-Document batch tracking: `[Document.ID: Set<RuntimeIndexingBatchID>]`.

## Data Flow Scenarios

### Scenario A — App launch / Document opened with indexing enabled

```
Document opens
  → DocumentState ready, RuntimeEngine available
  → Coordinator.documentDidOpen(documentState)
      reads Settings.backgroundIndexing
      if !isEnabled → return
      rootPath = await engine.mainExecutablePath()
      batchID = await engine.backgroundIndexingManager.startBatch(
          rootImagePath: rootPath,
          depth: settings.depth,
          maxConcurrency: settings.maxConcurrency,
          reason: .appLaunch)
      Toolbar item transitions idle → indexing
```

### Scenario B — User loads a new image at runtime

```
User action → documentState.loadImage(at: path)
  → RuntimeEngine.loadImage(at:) (existing synchronous path completes)
  → Engine emits didLoadImage(path) via existing Observable
  → Coordinator (if isEnabled):
      batchID = manager.startBatch(
          rootImagePath: path,
          depth: settings.depth,
          maxConcurrency: settings.maxConcurrency,
          reason: .imageLoaded(path: path))
      Dependency graph expansion skips items already indexed
```

### Scenario C — User selects an image already queued

```
Sidebar selection change → SidebarViewModel emits imageSelected(path)
  → Coordinator → manager.prioritize(imagePath: path)
      manager walks activeBatches, finds pending items matching path
      marks hasPriorityBoost = true, dequeues + enqueues at head
      emits .taskPrioritized
      running / completed / absent paths: silent no-op
```

### Scenario D — Document closed

```
Document.close()
  → Coordinator.documentWillClose(documentState)
      for batchID in Coordinator.batchesFor(document):
          await manager.cancelBatch(batchID)
      remove document entry
```

### Scenario E — Settings toggle

```
isEnabled false → true:
    for every open Document: run Scenario A
    (main executable only; do NOT replay historical loadImage calls)

isEnabled true → false:
    await manager.cancelAllBatches() for every document's engine

depth or maxConcurrency changed (isEnabled stays true):
    no-op against running batches. Next startBatch picks up new values.
```

### Scenario F — User cancels from the popover

```
Popover cancel button → ViewModel cancelBatchRelay.accept(batchID)
  → Coordinator → await manager.cancelBatch(id)
      batch's driving Task → task.cancel()
      TaskGroup children inherit cancellation
      runSingleIndex catches CancellationError → item state .cancelled
      already-completed items retain .completed (loadedImagePaths stays)
      emits .batchCancelled
```

## Dependency Graph Expansion

Implemented by `expandDependencyGraph(rootPath:depth:)` inside the manager. Runs synchronously at the start of `startBatch` so the batch's total item count is known before the first `taskStarted` event fires — this keeps the popover progress bar accurate from the first frame.

```swift
// Pseudocode
func expandDependencyGraph(rootPath: String, depth: Int) async
    -> [RuntimeIndexingTaskItem]
{
    var visited: Set<String> = []
    var items: [RuntimeIndexingTaskItem] = []
    var frontier: Deque<(path: String, level: Int)> = [(rootPath, 0)]

    while let (path, level) = frontier.popFirst() {
        guard visited.insert(path).inserted else { continue }

        if await engine.isImageIndexed(path: path) { continue }  // short-circuit

        guard let image = MachOImage(name: path) else {
            items.append(.init(id: path, resolvedPath: nil,
                               state: .failed("cannot open MachOImage"),
                               hasPriorityBoost: false))
            continue   // do NOT recurse past an unreadable image
        }

        items.append(.init(id: path, resolvedPath: path,
                           state: .pending, hasPriorityBoost: false))

        guard level < depth else { continue }

        for dep in image.dependencies where dep.type != .lazyLoad {
            guard let resolved = DylibPathResolver.resolve(
                installName: dep.dylib.name, from: image)
            else {
                items.append(.init(id: dep.dylib.name, resolvedPath: nil,
                                   state: .failed("path unresolved"),
                                   hasPriorityBoost: false))
                continue
            }
            frontier.append((resolved, level + 1))
        }
    }
    return items
}
```

### Dependency type filter

Included: `.load`, `.weakLoad`, `.reexport`, `.upwardLoad`.
Skipped: `.lazyLoad` — lazy-loaded dylibs may never actually load at runtime, so eagerly parsing them is speculative and wasteful.

### Path resolution (`DylibPathResolver`)

Install names come in three shapes:

| Shape | Resolution |
|-------|------------|
| `/System/Library/...` (absolute) | Use as-is. Verify file exists. |
| `@rpath/Foo.framework/Foo` | For each `LC_RPATH` on the rooting image, substitute and take the first existing path. |
| `@executable_path/...` | Substitute using the main executable's directory. |
| `@loader_path/...` | Substitute using the current image's directory. |

Returns `String?` — `nil` means resolution failed.

## Concurrency Model

Entirely Swift Concurrency — no `OperationQueue`, no `DispatchQueue`, no RxSwift in the work path. RxSwift is used only at the UI binding layer inside the Coordinator.

```swift
// Manager internals, pseudocode
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

### Priority queue mechanics

Each batch state owns a `Deque<String>` of pending paths. `prioritize(imagePath:)` removes the path from its current position and inserts it at the head. `popNextPrioritizedPending(batchID:)` always pops from the head, so priority-boosted items run next when a slot opens.

Priority cannot preempt an already-running child task — Swift structured concurrency does not support that. `prioritize` on a running or completed path is a silent no-op, intentional per brainstorming.

### `AsyncSemaphore`

From `groue/Semaphore`, already in `Package.resolved`. Used to cap concurrent child tasks at `maxConcurrency`. `waitUnlessCancelled()` propagates parent cancellation.

### UI refresh suppression

`loadImageForBackgroundIndexing(at:)` does **not** call `reloadData()`. Calling it N times during a batch would storm the sidebar. The coordinator triggers `await engine.reloadData(isReloadImageNodes: false)` once per `.batchFinished` event so the sidebar picks up the newly-indexed icons in a single update.

## Settings

### `BackgroundIndexing` struct (in `RuntimeViewerSettings/Settings+Types.swift`)

```swift
@Codable @MemberInit public struct BackgroundIndexing {
    @Default(false) public var isEnabled: Bool
    @Default(1)     public var depth: Int               // valid 1...5
    @Default(4)     public var maxConcurrency: Int      // valid 1...8
    public static let `default` = Self()
}
```

Added to the root `Settings` struct as `@Default(BackgroundIndexing.default) public var backgroundIndexing: BackgroundIndexing`. Persisted by the existing `SettingsFileSystemStorage` auto-save mechanism.

### `BackgroundIndexingSettingsView` (SwiftUI)

Lives at `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/BackgroundIndexingSettingsView.swift`. Reached via `SettingsPage.backgroundIndexing` (new case in `SettingsRootView.swift`, icon `square.stack.3d.down.right`, title `"Background Indexing"`).

Form contents:
- `Toggle "Enable background indexing"` bound to `$settings.isEnabled`.
- Caption paragraph explaining behavior.
- `Stepper` for depth (1...5), caption explaining the semantics.
- `Stepper` for maxConcurrency (1...8), caption noting the CPU tradeoff.

Cancel-all live action stays out of Settings; it belongs in the popover (see below).

### Settings change propagation

`RuntimeBackgroundIndexingCoordinator` subscribes to settings changes. The concrete subscription path is TBD at the plan phase — options to evaluate: Combine publisher on `Settings`, a lightweight `SettingsSubject` relay, or polling `@AppSettings` reflection. Whichever path, the semantics are:

- `isEnabled`: false → true triggers Scenario A for each open Document.
- `isEnabled`: true → false triggers `cancelAllBatches` on each engine.
- `depth` / `maxConcurrency` change while enabled: no-op against running batches; values apply to the next `startBatch`.

## UI: Toolbar Item + Popover

### `BackgroundIndexingToolbarItem`

`NSToolbarItem` subclass registered in `MainToolbarController.swift`. Identifier `backgroundIndexing`. Placed next to `mcpStatus` in default + allowed identifier lists.

`view` is a `BackgroundIndexingToolbarItemView` (NSView) holding a centered 16pt icon (SF Symbol `square.stack.3d.down.right`) with an `NSProgressIndicator(style: .spinning)` overlaid when state is `indexing` or `hasFailures`. A small red badge dot is drawn over the bottom-right corner for `hasFailures`.

`IndexingToolbarState` enum: `.idle`, `.disabled`, `.indexing(percent: Double?)`, `.hasFailures(percent: Double?)`.

The view binds to a `Driver<IndexingToolbarState>` pushed from the Coordinator via a weakly-held observer set at toolbar construction.

Clicking the item posts `backgroundIndexingPopover(sender:)` on `MainCoordinator`, analogous to the MCP popover route.

### `BackgroundIndexingPopoverViewController`

Base class `UXKitViewController<BackgroundIndexingPopoverViewModel>`. Fixed width 380, height from ~120 (empty state) up to 400 (outline view with scroll).

#### Content layout

- Header: `Label("Background Indexing")` plus a subtitle `Label` reading the aggregate progress.
- Empty state A (disabled): icon + "Background indexing is disabled" + `"Open Settings"` button.
- Empty state B (enabled, no batches): icon + "No active indexing tasks".
- Body: `StatefulOutlineView` rendering `BackgroundIndexingNode`.
- Footer: `HStackView` with `Cancel All` button (disabled when no active batch) and `Close` button.

#### `BackgroundIndexingNode`

```swift
enum BackgroundIndexingNode {
    case batch(RuntimeIndexingBatch)
    case item(batchID: RuntimeIndexingBatchID, item: RuntimeIndexingTaskItem)
}
```

Outline cells:

- Batch row: a short title derived from `reason` (`"App launch indexing"` / `"MyFramework.framework deps"` / etc.), `"{completed}/{total}"`, and a cancel button. Clicking cancel fires `cancelBatchRelay.accept(batchID)`.
- Item row: status icon (pending grey dot / running spinning / completed green ✓ / failed red ✗ / cancelled grey ⊘) + display name + secondary label. Failed rows show the full install name and the error message. Rows with `hasPriorityBoost == true` show a `"priority"` tag.

### `BackgroundIndexingPopoverViewModel`

```swift
final class BackgroundIndexingPopoverViewModel: ViewModel<BackgroundIndexingPopoverRoute> {
    @Observed private(set) var nodes: [BackgroundIndexingNode] = []
    @Observed private(set) var isEnabled: Bool = false
    @Observed private(set) var hasAnyBatch: Bool = false
    @Observed private(set) var subtitle: String = ""

    struct Input {
        let cancelBatch: Signal<RuntimeIndexingBatchID>
        let cancelAll: Signal<Void>
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

Relays forward to the Coordinator's async APIs wrapped in `Task { ... }` blocks.

### Popover presentation

New route case in `MainRoute`:

```swift
case backgroundIndexingPopover(sender: NSView)
```

`MainCoordinator.prepareTransition` builds the VC + VM and returns `.presentOnRoot(..., mode: .asPopover(...))`.

## Error Handling

| Failure site | Behavior | UI |
|---|---|---|
| `MachOImage(name: path)` returns nil | Item → `.failed("cannot open MachOImage")`, no recursion | red ✗ + tooltip |
| `@rpath` / `@executable_path` / `@loader_path` unresolved | Item → `.failed("path unresolved")`, no recursion | red ✗ + original install name |
| `DyldUtilities.loadImage` throws (codesign, sandbox, missing file) | Item → `.failed(dlopenError.localizedDescription)` | red ✗ |
| ObjC section parse throws | Item → `.failed(objcParseError)` | red ✗ |
| Swift section parse throws | Item → `.failed(swiftParseError)`. `isImageIndexed` stays false because at least one factory has no cache for this path | red ✗ |
| `Task.checkCancellation` throws | Item → `.cancelled`, no error event | grey ⊘ |
| Coordinator receives event after Document released | `[weak self]` drops event silently | — |

`isImageIndexed` demands that **both** factories have a cached entry for the path. To distinguish "tried and found nothing" from "never tried", each factory will cache empty / nil results as well — the cache key's presence becomes the "attempted" bit. A follow-up in the plan will verify the factories support this without regression (the current `isExisted` return already implies they do).

## Race / Edge Conditions

1. **User manual `loadImage(path)` while a background batch is indexing the same path.**
   The ObjC / Swift factories must serialize per-path parsing so two concurrent callers do not both parse. The plan phase will verify (and, if needed, introduce a `[String: Task<Section, Error>]` in-flight map inside each factory).

2. **Batch cancellation with partially-completed items.**
   Completed items retain `.completed`; `loadedImagePaths` inserts are not rolled back. In-flight items that receive `CancellationError` mid-parse may leave the factories with partial sections — acceptable for this iteration; `isImageIndexed` will then return false and a future explicit load will redo the work.

3. **Multiple batches for the same root.**
   The manager dedupes: if an active batch already has `rootImagePath == root` and `reason`'s discriminant matches, return its existing `RuntimeIndexingBatchID` instead of starting another.

4. **Document closure while events are mid-flight.**
   `AsyncStream.Continuation.finish()` is called when the engine (and its manager) deinit. The Coordinator's `Task { for await event in manager.events }` exits cleanly.

## Testing Strategy

Added under `RuntimeViewerCore/Tests/RuntimeViewerCoreTests/BackgroundIndexing/`.

1. `DylibPathResolverTests`
   - `@rpath` single + multiple `LC_RPATH`, hit + miss.
   - `@executable_path` and `@loader_path` substitution.
   - Absolute path passthrough.
2. `RuntimeBackgroundIndexingManagerTests` using a `MockBackgroundIndexingEngine` conforming to a new internal `BackgroundIndexingEngineRepresenting` protocol.
   - Graph expansion at depth 0, 1, 2; already-indexed short-circuit.
   - `prioritize` repositions pending items; no-op on running / completed.
   - `cancelBatch` stops in-flight work, marks remaining pending items cancelled.
   - Concurrency cap honored (spy counter never exceeds configured value).
   - Event ordering: `batchStarted` precedes any `taskStarted`; `batchFinished` last.
3. `RuntimeIndexingBatch` / event reducers if non-trivial reduction logic ends up on the Coordinator side.

UI is not automated (no existing UI test harness); the plan will include a manual verification checklist.

## File Inventory

### New files

```
RuntimeViewerCore/Sources/RuntimeViewerCore/BackgroundIndexing/
    RuntimeBackgroundIndexingManager.swift
    RuntimeIndexingBatch.swift
    RuntimeIndexingBatchID.swift
    RuntimeIndexingBatchReason.swift
    RuntimeIndexingTaskItem.swift
    RuntimeIndexingTaskState.swift
    RuntimeIndexingEvent.swift
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
    BackgroundIndexingPopoverRoute.swift
    BackgroundIndexingNode.swift
```

### Modified files

```
RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift
    + BackgroundIndexing struct
    + Settings.backgroundIndexing property

RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift
    + SettingsPage.backgroundIndexing case and contentView branch

RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
    + backgroundIndexingManager lazy property
    + isImageIndexed(path:)
    + mainExecutablePath()

RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift
RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
    + hasCachedSection(for:) inspector
    + in-flight task dedupe if plan verifies it is missing

RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift
    + backgroundIndexing item identifier + factory
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
    + backgroundIndexingPopover(sender:) route
RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift
    + create RuntimeBackgroundIndexingCoordinator per Document
```

All new files under `RuntimeViewerUsingAppKit/.../BackgroundIndexing/` must be added to the Xcode project manually (consistent with the MCPServer pattern noted in project memory).

## Open Questions (deferred to plan phase)

1. **Settings change subscription path** — confirm which existing mechanism the `Coordinator` can hook into without inventing new infrastructure.
2. **Factory in-flight dedupe** — verify whether `RuntimeObjCSectionFactory` / `RuntimeSwiftSectionFactory` already serialize concurrent `section(for:)` calls, or if an in-flight task map must be added.
3. **Remote engine parity** — whether the `backgroundIndexingManager` + events need to be wired over `RuntimeViewerCommunication` for the remote (XPC / directTCP) case. Current scope assumes server-side execution only; remote UI parity may need a follow-up pass.
4. **Main executable path retrieval** — confirm the exact MachOKit / dyld helper used for dyld image index 0 in both local and server-injected contexts.

These are specification gaps that the plan phase will close with code reads; they do not change the design.

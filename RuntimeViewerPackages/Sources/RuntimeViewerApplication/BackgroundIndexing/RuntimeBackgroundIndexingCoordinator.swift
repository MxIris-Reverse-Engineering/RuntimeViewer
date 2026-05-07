import Foundation
import Observation
import RuntimeViewerCore
import RxSwift
import RxRelay
import Dependencies

#if canImport(RuntimeViewerSettings)
import RuntimeViewerSettings
#endif

@MainActor
public final class RuntimeBackgroundIndexingCoordinator {
    /// Soft cap on `historyRelay` size. A long-running session that triggers
    /// many `imageLoaded` notifications would otherwise grow history without
    /// bound; once this cap is exceeded we drop the oldest entries from the
    /// tail (history is inserted at index 0, so the tail is the oldest).
    /// The user can still manually clear via `clearHistory()`.
    private static let maxHistoryEntries = 100

    public struct AggregateState: Equatable, Sendable {
        public var hasActiveBatch: Bool
        public var hasAnyFailure: Bool
        public var progress: Double?   // 0...1, nil when idle

        public init(hasActiveBatch: Bool, hasAnyFailure: Bool, progress: Double?) {
            self.hasActiveBatch = hasActiveBatch
            self.hasAnyFailure = hasAnyFailure
            self.progress = progress
        }
    }

    private unowned let documentState: DocumentState
    /// The engine this coordinator currently drives. Mutable so `MainCoordinator`
    /// can switch sources (Local ↔ XPC ↔ Bonjour) without recreating the
    /// coordinator: an RxSwift subscription on `documentState.$runtimeEngine`
    /// picks up reassignments and rewires the pumps onto the new engine's
    /// `backgroundIndexingManager`.
    private var engine: RuntimeEngine
    private let disposeBag = DisposeBag()

    private let batchesRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
    private let historyRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
    private let aggregateRelay = BehaviorRelay<AggregateState>(
        value: .init(hasActiveBatch: false, hasAnyFailure: false, progress: nil)
    )

    /// Authoritative active-batches storage. Mutated synchronously inside
    /// `apply(event:)`; copied into `batchesRelay` only on flush so that
    /// task-level events (one per started/finished image) don't fan out a
    /// full subscriber storm 100+ times per second during a busy batch.
    private var stagedBatches: [RuntimeIndexingBatch] = []
    /// Pending history archives from `batchFinished` / `batchCancelled`,
    /// delivered to `historyRelay` only after the corresponding active-batch
    /// removal has been published — see `flushPendingUpdates` for the
    /// active-then-history ordering rationale.
    private var pendingHistoryAdditions: [RuntimeIndexingBatch] = []
    private var hasPendingActiveChange = false
    private var pendingAggregateRefresh = false
    /// `true` while `scheduleCoalescedFlush` has a `Task` outstanding that
    /// will call `flushPendingUpdates` on the next runloop tick. Guards
    /// against piling up redundant flush tasks when events arrive in bursts.
    private var hasScheduledFlush = false

    /// One frame at 60Hz. Coalesces task-level events that arrive together
    /// (e.g. `taskFinished(A)` immediately followed by `taskStarted(B)` as a
    /// worker picks up the next item) into a single relay publish so the
    /// popover redraws at a sustainable rate.
    private static let coalesceWindowNanos: UInt64 = 16_000_000

    private var documentBatchIDs: Set<RuntimeIndexingBatchID> = []
    private var eventPumpTask: Task<Void, Never>?
    private var imageLoadedPumpTask: Task<Void, Never>?
    private var lastKnownIsEnabled: Bool = false

    public init(documentState: DocumentState) {
        self.documentState = documentState
        self.engine = documentState.runtimeEngine
        startEventPump()
        #if canImport(RuntimeViewerSettings)
        startImageLoadedPump()
        bootstrapSettingsObservation()
        #endif
        bootstrapEngineObservation()
    }

    deinit {
        eventPumpTask?.cancel()
        imageLoadedPumpTask?.cancel()
    }

    // MARK: - Public observables for UI

    public var batchesObservable: Observable<[RuntimeIndexingBatch]> {
        batchesRelay.asObservable()
    }

    public var aggregateStateObservable: Observable<AggregateState> {
        aggregateRelay.asObservable()
    }

    public var historyObservable: Observable<[RuntimeIndexingBatch]> {
        historyRelay.asObservable()
    }

    // MARK: - Public command surface

    public func cancelBatch(_ id: RuntimeIndexingBatchID) {
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelBatch(id)
        }
    }

    public func cancelAllBatches() {
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelAllBatches()
        }
    }

    public func prioritize(imagePath: String) {
        Task { [engine] in
            await engine.backgroundIndexingManager.prioritize(imagePath: imagePath)
        }
    }

    public func clearHistory() {
        // Drop pending archives too — otherwise a `.batchFinished` whose
        // history hop was waiting on the coalesce window would still land
        // after the user cleared.
        pendingHistoryAdditions.removeAll()
        historyRelay.accept([])
    }

    // MARK: - Event pump (AsyncStream → Relay)

    private func startEventPump() {
        // The class is `@MainActor`, so this Task and its `for await` loop
        // run on the main actor. `apply(event:)` can be called synchronously
        // without an extra `MainActor.run` hop.
        eventPumpTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.engine.backgroundIndexingManager.events
            for await event in stream {
                self.apply(event: event)
            }
        }
    }

    private func apply(event: RuntimeIndexingEvent) {
        // Lifecycle events (batch{Started,Finished,Cancelled}) are rare and
        // user-visible, so they bypass the coalesce window and flush the
        // current state immediately. Per-task events (task{Started,Finished,
        // Prioritized}) only schedule a coalesced flush — see
        // `scheduleCoalescedFlush` for the rate cap.
        var requiresImmediateFlush = false

        switch event {
        case .batchStarted(let batch):
            stagedBatches.append(batch)
            hasPendingActiveChange = true
            pendingAggregateRefresh = true
            requiresImmediateFlush = true
        case .taskStarted(let id, let path):
            if mutateTaskItem(batchID: id, path: path, { item in
                item.state = .running
            }) {
                hasPendingActiveChange = true
                pendingAggregateRefresh = true
            }
        case .taskFinished(let id, let path, let result):
            if mutateTaskItem(batchID: id, path: path, { item in
                item.state = result
            }) {
                hasPendingActiveChange = true
                pendingAggregateRefresh = true
            }
        case .taskPrioritized(let id, let path):
            // Priority boost doesn't change progress / hasFailure / hasActive,
            // so we skip the aggregate refresh.
            if mutateTaskItem(batchID: id, path: path, { item in
                item.hasPriorityBoost = true
            }) {
                hasPendingActiveChange = true
            }
        case .batchFinished(let finished):
            stagedBatches.removeAll { $0.id == finished.id }
            documentBatchIDs.remove(finished.id)
            pendingHistoryAdditions.append(finished)
            hasPendingActiveChange = true
            pendingAggregateRefresh = true
            requiresImmediateFlush = true
            Task { [engine] in
                await engine.reloadData(isReloadImageNodes: false)
            }
        case .batchCancelled(let cancelled):
            // Cancellation always removes from active. Now also lands in history
            // so the user can review what got cancelled.
            stagedBatches.removeAll { $0.id == cancelled.id }
            documentBatchIDs.remove(cancelled.id)
            pendingHistoryAdditions.append(cancelled)
            hasPendingActiveChange = true
            pendingAggregateRefresh = true
            requiresImmediateFlush = true
            Task { [engine] in
                await engine.reloadData(isReloadImageNodes: false)
            }
        }

        if requiresImmediateFlush {
            flushPendingUpdates()
        } else {
            scheduleCoalescedFlush()
        }
    }

    /// Locates `(batchID, path)` inside `stagedBatches` and applies `mutate`
    /// in place. Returns `true` on a successful hit so the caller can flip
    /// the appropriate dirty flags. Returns `false` when the batch or item
    /// can't be found — stale events that arrive after a swap or
    /// cancellation must not poison the flush state.
    private func mutateTaskItem(
        batchID: RuntimeIndexingBatchID,
        path: String,
        _ mutate: (inout RuntimeIndexingTaskItem) -> Void
    ) -> Bool {
        guard let batchIndex = stagedBatches.firstIndex(where: { $0.id == batchID }),
              let itemIndex = stagedBatches[batchIndex].items.firstIndex(where: { $0.id == path })
        else { return false }
        mutate(&stagedBatches[batchIndex].items[itemIndex])
        return true
    }

    /// Asks main-actor to call `flushPendingUpdates` on the next runloop tick
    /// (~16ms out). Idempotent: bursty events that all arrive inside the
    /// window collapse into a single publish.
    private func scheduleCoalescedFlush() {
        guard !hasScheduledFlush else { return }
        hasScheduledFlush = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.coalesceWindowNanos)
            self?.flushPendingUpdates()
        }
    }

    /// Publishes `stagedBatches` to `batchesRelay`, then drains pending
    /// `historyAdditions` into `historyRelay`. See the active-then-history
    /// ordering note: any batch that just transitioned to history must have
    /// already disappeared from `batchesRelay` before it appears in
    /// `historyRelay`, otherwise `combineLatest(batches, history)` would emit
    /// a transient frame with the same `differenceIdentifier` in both
    /// sections and DifferenceKit's behavior is undefined.
    private func flushPendingUpdates() {
        hasScheduledFlush = false
        guard hasPendingActiveChange || !pendingHistoryAdditions.isEmpty else {
            return
        }
        let activeChanged = hasPendingActiveChange
        let aggregateChanged = pendingAggregateRefresh
        hasPendingActiveChange = false
        pendingAggregateRefresh = false

        if activeChanged {
            batchesRelay.accept(stagedBatches)
        }
        if aggregateChanged {
            refreshAggregate(batches: stagedBatches)
        }
        // Now safe to push history: subscribers see (new batches without
        // finished, new history with finished) — a fully consistent state.
        if !pendingHistoryAdditions.isEmpty {
            let toArchive = pendingHistoryAdditions
            pendingHistoryAdditions = []
            for batch in toArchive {
                appendToHistory(batch)
            }
        }
    }

    private func appendToHistory(_ batch: RuntimeIndexingBatch) {
        var updatedHistory = historyRelay.value
        updatedHistory.insert(batch, at: 0)
        if updatedHistory.count > Self.maxHistoryEntries {
            updatedHistory.removeLast(updatedHistory.count - Self.maxHistoryEntries)
        }
        historyRelay.accept(updatedHistory)
    }

    private func refreshAggregate(batches: [RuntimeIndexingBatch]) {
        let hasActive = !batches.isEmpty
        let hasFailure = batches.contains { batch in
            batch.items.contains { item in
                if case .failed = item.state { return true }
                return false
            }
        }
        let totalItems = batches.reduce(0) { $0 + $1.totalCount }
        let doneItems = batches.reduce(0) { $0 + $1.finishedCount }
        let progress: Double? = totalItems > 0
            ? Double(doneItems) / Double(totalItems)
            : nil
        aggregateRelay.accept(
            .init(hasActiveBatch: hasActive, hasAnyFailure: hasFailure,
                  progress: progress))
    }

    // MARK: - Engine swap (source switch)

    /// Subscribes to `documentState.$runtimeEngine`. When `MainCoordinator`
    /// reassigns the engine on a source switch, `handleEngineSwap` tears down
    /// the old pumps, cancels in-flight document batches on the old manager,
    /// and rewires onto the new engine's manager.
    private func bootstrapEngineObservation() {
        // skip(1) — BehaviorRelay replays its current value on subscribe; that
        // value matches the engine captured in init, so we don't need to react
        // to it. Only subsequent reassignments are real source switches.
        documentState.$runtimeEngine
            .skip(1)
            .subscribeOnNext { [weak self] newEngine in
                guard let self else { return }
                self.handleEngineSwap(to: newEngine)
            }
            .disposed(by: disposeBag)
    }

    private func handleEngineSwap(to newEngine: RuntimeEngine) {
        // Capture the old engine before we overwrite, so we can dispatch a
        // cancel to its manager covering both already-tracked batches and
        // any swap-window arrivals.
        let oldEngine = engine

        // 1) Stop pumps tied to the old engine. The Tasks were `for await`
        //    looping over an AsyncStream owned by the old manager; cancelling
        //    them ends the loops cleanly.
        eventPumpTask?.cancel()
        imageLoadedPumpTask?.cancel()
        eventPumpTask = nil
        imageLoadedPumpTask = nil

        // 2) Cancel **all** in-flight batches on the old manager — not just
        //    the ones in `documentBatchIDs`. A `startBatch` Task that
        //    suspended before its id was inserted into `documentBatchIDs`
        //    would otherwise leak: the `self.engine === engine` guard in
        //    `startMainExecutableBatch` / `handleImageLoaded` correctly drops
        //    its id, but the batch itself remains active on the old manager
        //    and runs to completion uninterrupted, occupying CPU and the
        //    section-cache slots until the old engine is finally deinit'd.
        //    `cancelAllBatches` covers both already-tracked batches and any
        //    swap-window arrivals.
        //
        //    Fire-and-forget — old engine's manager will deinit shortly.
        Task {
            await oldEngine.backgroundIndexingManager.cancelAllBatches()
        }

        // 3) Drop UI state — the old engine's batches and history no longer apply.
        //    Also reset the coalescing state so that any flush task currently
        //    sleeping out the 16ms window sees clean buffers when it wakes.
        documentBatchIDs.removeAll()
        stagedBatches.removeAll()
        pendingHistoryAdditions.removeAll()
        hasPendingActiveChange = false
        pendingAggregateRefresh = false
        batchesRelay.accept([])
        historyRelay.accept([])
        refreshAggregate(batches: [])

        // 4) Switch the captured engine reference.
        engine = newEngine

        // 5) Restart pumps on the new engine's manager.
        startEventPump()
        #if canImport(RuntimeViewerSettings)
        startImageLoadedPump()
        // If the feature is enabled, treat the swap like a fresh document
        // open — the new engine's main executable should be indexed.
        documentDidOpen()
        #endif
    }
}

#if canImport(RuntimeViewerSettings)
extension RuntimeBackgroundIndexingCoordinator {
    public func documentDidOpen() {
        startMainExecutableBatch(reason: .appLaunch)
    }

    /// Shared logic for "index the main executable" batches. Both the document
    /// open path (reason `.appLaunch`) and the off→on settings toggle (reason
    /// `.settingsEnabled`) funnel through here so the popover's title-by-reason
    /// branch surfaces the correct label instead of always saying "App launch
    /// indexing".
    private func startMainExecutableBatch(reason: RuntimeIndexingBatchReason) {
        // The class is `@MainActor`, so this Task inherits main-actor isolation
        // and can mutate `documentBatchIDs` synchronously after the awaits.
        // Capture `engine` at task creation so every await below targets the
        // same engine even if `handleEngineSwap` reassigns `self.engine` while
        // we are suspended — otherwise we could submit the old engine's root
        // path to the new engine's manager and leak a stray batch id into
        // `documentBatchIDs`.
        Task { [weak self, engine] in
            guard let self else { return }
            let settings = self.currentBackgroundIndexingSettings()
            guard settings.isEnabled else { return }
            // mainExecutablePath is `async throws` because remote (XPC / TCP)
            // sources may fail; on launch we silently skip the batch in that
            // case rather than surface the error to the user.
            guard let root = try? await engine.mainExecutablePath(),
                  !root.isEmpty else { return }
            let id = await engine.backgroundIndexingManager.startBatch(
                rootImagePath: root,
                depth: settings.depth,
                maxConcurrency: settings.maxConcurrency,
                reason: reason)
            // If the engine swapped while we were suspended, the batch landed
            // on the now-old manager which `handleEngineSwap` has already
            // cleaned up; don't pollute `documentBatchIDs` with an id whose
            // manager we no longer drive.
            guard self.engine === engine else { return }
            self.documentBatchIDs.insert(id)
        }
    }

    public func documentWillClose() {
        let ids = documentBatchIDs
        documentBatchIDs.removeAll()
        Task { [engine] in
            for id in ids {
                await engine.backgroundIndexingManager.cancelBatch(id)
            }
        }
    }

    private func startImageLoadedPump() {
        // Class is `@MainActor`; this Task and `for await` loop run on the main
        // actor. `handleImageLoaded` doesn't need a `MainActor.run` hop.
        // Capture `engine` so the pump (and the `handleImageLoaded` call below)
        // stay bound to the engine that owned this pump at startup, even if
        // `self.engine` is reassigned by `handleEngineSwap` mid-flight.
        imageLoadedPumpTask = Task { [weak self, engine] in
            guard let self else { return }
            // Combine.Publisher.values bridges to AsyncSequence on macOS 12+ /
            // iOS 15+; the project's deployment targets satisfy this. Errors are
            // Never on this publisher, so no try is needed.
            for await path in engine.imageDidLoadPublisher.values {
                await self.handleImageLoaded(path: path, on: engine)
            }
        }
    }

    private func handleImageLoaded(path: String, on engine: RuntimeEngine) async {
        let settings = currentBackgroundIndexingSettings()
        guard settings.isEnabled else { return }
        // If `documentDidOpen` is currently indexing the same path (e.g. dyld
        // fires this notification for the main executable right after launch),
        // the manager dedups by `rootImagePath` and returns the existing
        // batch's id. Inserting it into `documentBatchIDs` is a no-op on the
        // Set when it's already tracked.
        let id = await engine.backgroundIndexingManager.startBatch(
            rootImagePath: path,
            depth: settings.depth,
            maxConcurrency: settings.maxConcurrency,
            reason: .imageLoaded(path: path))
        // If the engine swapped while we were suspended on `startBatch`, the
        // id belongs to the old manager and `handleEngineSwap` has already
        // cleared `documentBatchIDs`; don't reintroduce a stale id.
        guard self.engine === engine else { return }
        self.documentBatchIDs.insert(id)
    }

    private func currentBackgroundIndexingSettings() -> Settings.Indexing.BackgroundMode {
        @Dependency(\.settings) var settings
        return settings.indexing.backgroundMode
    }

    private func bootstrapSettingsObservation() {
        self.lastKnownIsEnabled = currentBackgroundIndexingSettings().isEnabled
        self.subscribeToSettings()
    }

    private func subscribeToSettings() {
        withObservationTracking {
            let snapshot = currentBackgroundIndexingSettings()
            _ = snapshot.isEnabled
            _ = snapshot.depth
            _ = snapshot.maxConcurrency
        } onChange: { [weak self] in
            // onChange fires off the main actor synchronously after any mutation.
            // Hop back to MainActor to (a) handle the change and (b) re-register.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleSettingsChange()
                self.subscribeToSettings()
            }
        }
    }

    private func handleSettingsChange() {
        let latest = currentBackgroundIndexingSettings()
        let wasEnabled = lastKnownIsEnabled
        lastKnownIsEnabled = latest.isEnabled
        if !wasEnabled && latest.isEnabled {
            // Scenario E: off→on. Use `.settingsEnabled` so the popover's
            // title-by-reason mapping shows "Settings enabled" instead of
            // the misleading "App launch indexing".
            startMainExecutableBatch(reason: .settingsEnabled)
        } else if wasEnabled && !latest.isEnabled {
            Task { [engine] in
                await engine.backgroundIndexingManager.cancelAllBatches()
            }
        }
        // depth / maxConcurrency changes: intentional no-op; next startBatch picks
        // up the new values.
    }
}
#endif

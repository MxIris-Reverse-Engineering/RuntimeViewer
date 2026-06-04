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

    /// Authoritative staging state for in-flight batches plus the dirty flags
    /// the flush path consumes. Lives behind an `NSLock` rather than on the
    /// main actor so that the worker→coordinator AsyncStream pump can apply
    /// 100+ task events per second without ever waking the main thread —
    /// only the 16ms coalesced flush hops to main.
    private let staging = StagingStore()

    /// One frame at 60Hz. Coalesces task-level events that arrive together
    /// (e.g. `taskFinished(A)` immediately followed by `taskStarted(B)` as a
    /// worker picks up the next item) into a single relay publish so the
    /// popover redraws at a sustainable rate.
    private static let coalesceWindowNanos: UInt64 = 16_000_000

    private var eventPumpTask: Task<Void, Never>?
    private var imageLoadedPumpTask: Task<Void, Never>?
    /// Pump that re-runs `startAlwaysIndexBatches()` after every fullReload.
    /// Required because remote engines (XPC / Bonjour) populate `imageList`
    /// asynchronously: the first `documentDidOpen` may see an empty list and
    /// resolve every imageName-only identifier to nil. Once the server's
    /// fullReload broadcast lands and the client's `imageList` is set, this
    /// pump retries. `dispatchedAlwaysIndexIdentifiers` gates re-entry so
    /// the pump idles for identifiers that have already produced a batch
    /// this engine session — otherwise every batch finish → `reloadData` →
    /// pump → empty-batch-start → finish → loop would spin forever.
    private var reloadDataPumpTask: Task<Void, Never>?
    private var lastKnownIsEnabled: Bool = false
    #if canImport(RuntimeViewerSettings)
    private var lastKnownAlwaysIndexEntries: [Settings.Indexing.AlwaysIndexEntry] = []
    /// Identifiers from `alwaysIndexEntries` that have successfully resolved
    /// to a path and had `startBatch` dispatched at least once during the
    /// current engine session. Used by `startAlwaysIndexBatches` to skip
    /// no-op re-entry triggered by the reload pump. Reset on engine swap,
    /// off→on toggle, and entry-list change so genuinely new work re-runs.
    private var dispatchedAlwaysIndexIdentifiers: Set<String> = []
    #endif

    public init(documentState: DocumentState) {
        self.documentState = documentState
        self.engine = documentState.runtimeEngine
        startEventPump()
        #if canImport(RuntimeViewerSettings)
        startImageLoadedPump()
        startReloadDataPump()
        bootstrapSettingsObservation()
        #endif
        bootstrapEngineObservation()
    }

    deinit {
        eventPumpTask?.cancel()
        imageLoadedPumpTask?.cancel()
        reloadDataPumpTask?.cancel()
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
        staging.clearPendingHistory()
        historyRelay.accept([])
    }

    // MARK: - Event pump (AsyncStream → Relay)

    private func startEventPump() {
        // Detached so the `for await` loop and `staging.applyEvent` run off the
        // main actor. With `maxConcurrency` workers churning, the manager fires
        // 100+ task events per second; under the previous main-actor pump each
        // event woke main once even though only the 16ms coalesced flush
        // actually publishes. Now main only wakes on `flush()` or the immediate
        // lifecycle flush below.
        let engine = self.engine
        eventPumpTask = Task.detached { [weak self] in
            let stream = await engine.backgroundIndexingManager.events
            for await event in stream {
                guard let self else { return }
                self.handleEvent(event, on: engine)
            }
        }
    }

    /// Off-main event entry point. Mutates the lock-protected staging state
    /// inline, then dispatches the minimal main-actor work the outcome
    /// requires (immediate flush for lifecycle events, scheduled flush for
    /// task events, `engine.reloadData` for batch terminations).
    nonisolated private func handleEvent(_ event: RuntimeIndexingEvent, on engine: RuntimeEngine) {
        let outcome = staging.applyEvent(event)

        if outcome.shouldReloadEngineImages {
            // Fire-and-forget: each finished/cancelled batch nudges the engine
            // to reload its non-image-node data. Detached + capture so the
            // dispatch isn't tied to coordinator isolation.
            Task { [engine] in
                await engine.reloadData(isReloadImageNodes: false)
            }
        }

        if outcome.requiresImmediateFlush {
            Task { @MainActor [weak self] in
                self?.flushPendingUpdates()
            }
        } else if outcome.didScheduleCoalescedFlush {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.coalesceWindowNanos)
                self?.flushPendingUpdates()
            }
        }
    }

    /// Drains the staging snapshot to the relays. Always runs on the main
    /// actor because `BehaviorRelay` subscribers (popover view models) expect
    /// main-thread delivery; the staging mutations themselves happened off-main.
    /// See the active-then-history ordering note: any batch that just
    /// transitioned to history must have already disappeared from
    /// `batchesRelay` before it appears in `historyRelay`, otherwise
    /// `combineLatest(batches, history)` would emit a transient frame with
    /// the same `differenceIdentifier` in both sections and DifferenceKit's
    /// behavior is undefined.
    private func flushPendingUpdates() {
        let snapshot = staging.snapshotForFlush()
        guard snapshot.hasWork else { return }

        if snapshot.activeChanged {
            batchesRelay.accept(snapshot.batches)
        }
        if snapshot.aggregateChanged {
            refreshAggregate(batches: snapshot.batches)
        }
        // Now safe to push history: subscribers see (new batches without
        // finished, new history with finished) — a fully consistent state.
        for batch in snapshot.historyAdditions {
            appendToHistory(batch)
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
        reloadDataPumpTask?.cancel()
        eventPumpTask = nil
        imageLoadedPumpTask = nil
        reloadDataPumpTask = nil

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
        staging.clearForEngineSwap()
        batchesRelay.accept([])
        historyRelay.accept([])
        refreshAggregate(batches: [])

        // 4) Switch the captured engine reference.
        engine = newEngine

        // 5) Restart pumps on the new engine's manager.
        startEventPump()
        #if canImport(RuntimeViewerSettings)
        startImageLoadedPump()
        startReloadDataPump()
        // New engine session — clear the dispatched-identifiers gate so the
        // always-index list re-dispatches against the new engine's image
        // list (which starts empty for remote engines).
        dispatchedAlwaysIndexIdentifiers.removeAll()
        // If the feature is enabled, treat the swap like a fresh document
        // open — the new engine's main executable should be indexed.
        // `documentDidOpen()` also triggers the always-index list.
        documentDidOpen()
        #endif
    }
}

#if canImport(RuntimeViewerSettings)
extension RuntimeBackgroundIndexingCoordinator {
    public func documentDidOpen() {
        startMainExecutableBatch(reason: .appLaunch)
        startAlwaysIndexBatches()
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
            self.staging.insertDocumentBatchID(id)
        }
    }

    public func documentWillClose() {
        let ids = staging.takeAllDocumentBatchIDs()
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
        self.staging.insertDocumentBatchID(id)
    }

    // MARK: - Always-index list

    /// Reads `Settings.Indexing.alwaysIndexEntries` and starts one batch
    /// per resolvable entry. Entries that don't resolve to a path in the
    /// engine's `imageList` are silently skipped — they remain in
    /// `lastKnownAlwaysIndexEntries` as still-pending so the next
    /// fullReload retry can pick them up.
    ///
    /// `followDependencies` controls the per-entry depth: when false, the
    /// batch is pinned to `depth: 0` so the BFS only emits the resolved
    /// image itself; when true, the global `BackgroundMode.depth` is used
    /// and the BFS walks the full dependency closure like the main-executable
    /// batch.
    ///
    /// The Manager dedups by `rootImagePath`, so re-entry on the same path
    /// is a cheap no-op that returns the existing batch id — making this
    /// method safe to call from multiple triggers (documentDidOpen, fullReload,
    /// settings change, engine swap).
    private func startAlwaysIndexBatches() {
        let entries = currentAlwaysIndexEntries()
        guard !entries.isEmpty else { return }
        // Gate: only process entries we haven't dispatched yet this session.
        // The reload pump re-enters here after every fullReload, including
        // ones our own batch finishes emit; without this filter we'd start
        // a fresh zero-item batch for each already-dispatched identifier,
        // which finishes immediately, fires reloadData, re-enters here,
        // loops forever.
        let pendingEntries = entries.filter {
            !dispatchedAlwaysIndexIdentifiers.contains($0.identifier)
        }
        guard !pendingEntries.isEmpty else { return }
        Task { [weak self, engine] in
            guard let self else { return }
            let settings = self.currentBackgroundIndexingSettings()
            guard settings.isEnabled else { return }
            // `engine.imageList` is `actor`-isolated; one hop fetches the
            // snapshot we'll use to resolve every identifier this round.
            // Remote engines populate `imageList` asynchronously via the
            // `imageList` message handler, so an early call here may see
            // `[]` — `startReloadDataPump` retries after fullReload, and
            // the gate above leaves unresolved identifiers eligible for
            // retry until they finally match a path in `imageList`.
            let imageList = await engine.imageList
            for entry in pendingEntries {
                guard let resolvedPath = resolveAlwaysIndexIdentifier(entry.identifier, in: imageList) else { continue }
                let effectiveDepth = entry.followDependencies ? settings.depth : 0
                let id = await engine.backgroundIndexingManager.startBatch(
                    rootImagePath: resolvedPath,
                    depth: effectiveDepth,
                    maxConcurrency: settings.maxConcurrency,
                    reason: .alwaysIndex(identifier: entry.identifier))
                guard self.engine === engine else { return }
                self.staging.insertDocumentBatchID(id)
                self.dispatchedAlwaysIndexIdentifiers.insert(entry.identifier)
            }
        }
    }

    /// Maps a user-supplied identifier to a path that exists in `imageList`.
    /// - Full imagePath (leading `/`): looked up verbatim against `imageList`
    ///   (which is already the patched form returned by `DyldUtilities.imageNames`).
    /// - imageName (no leading `/`): matched against `lastPathComponent` of
    ///   each entry. Strict equality — `Foundation` won't match `CoreFoundation`.
    /// Returns nil when no entry matches; caller should silent-skip.
    private nonisolated func resolveAlwaysIndexIdentifier(
        _ identifier: String,
        in imageList: [String]
    ) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return imageList.contains(trimmed) ? trimmed : nil
        } else {
            return imageList.first { ($0 as NSString).lastPathComponent == trimmed }
        }
    }

    /// Pump that listens for `engine.reloadDataPublisher` and retries
    /// `startAlwaysIndexBatches()` after each fullReload. Required so remote
    /// engines whose `imageList` arrives asynchronously can still resolve
    /// imageName identifiers once the list lands. Manager dedup keeps
    /// already-running batches unique across retries.
    private func startReloadDataPump() {
        reloadDataPumpTask = Task { [weak self, engine] in
            guard let self else { return }
            for await _ in engine.reloadDataPublisher.values {
                await MainActor.run {
                    guard self.engine === engine else { return }
                    self.startAlwaysIndexBatches()
                }
            }
        }
    }

    private func currentBackgroundIndexingSettings() -> Settings.Indexing.BackgroundMode {
        @Dependency(\.settings) var settings
        return settings.indexing.backgroundMode
    }

    private func currentAlwaysIndexEntries() -> [Settings.Indexing.AlwaysIndexEntry] {
        @Dependency(\.settings) var settings
        return settings.indexing.alwaysIndexEntries
    }

    private func bootstrapSettingsObservation() {
        self.lastKnownIsEnabled = currentBackgroundIndexingSettings().isEnabled
        self.lastKnownAlwaysIndexEntries = currentAlwaysIndexEntries()
        self.subscribeToSettings()
    }

    private func subscribeToSettings() {
        withObservationTracking {
            let snapshot = currentBackgroundIndexingSettings()
            _ = snapshot.isEnabled
            _ = snapshot.depth
            _ = snapshot.maxConcurrency
            // Track always-index entries too so the observation re-fires
            // when the user adds / edits / removes a row or flips the
            // per-row followDependencies toggle in Settings UI.
            _ = currentAlwaysIndexEntries()
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
            // the misleading "App launch indexing". Also re-trigger the
            // always-index list since this is effectively a fresh start —
            // clear the dispatched gate first so every entry runs again.
            dispatchedAlwaysIndexIdentifiers.removeAll()
            startMainExecutableBatch(reason: .settingsEnabled)
            startAlwaysIndexBatches()
        } else if wasEnabled && !latest.isEnabled {
            Task { [engine] in
                await engine.backgroundIndexingManager.cancelAllBatches()
            }
        }

        // Entry list changes: trigger always-index when content actually
        // changed and the feature is enabled. Adding / editing entries (or
        // flipping a per-row followDependencies toggle) kicks off batches
        // for the new content; removing entries is silent — already-running
        // batches keep running unless the user cancels them from the popover.
        // Toggling followDependencies on an existing entry also kicks off a
        // new batch: Manager dedup is by `rootImagePath`, so the existing
        // depth=0 batch stays the in-flight winner until it finishes. The
        // depth change picks up on the next start (e.g. document reopen).
        let previousEntries = lastKnownAlwaysIndexEntries
        let latestEntries = currentAlwaysIndexEntries()
        let entriesChanged = latestEntries != previousEntries
        lastKnownAlwaysIndexEntries = latestEntries
        // Skip when off→on already fired startAlwaysIndexBatches above to
        // avoid a duplicate (Manager dedup would no-op the second call, but
        // skipping the redundant Task hop is cleaner).
        if entriesChanged, latest.isEnabled, wasEnabled {
            // Drop identifiers no longer in the list and reset
            // followDependencies-flipped ones so they can re-dispatch with
            // the new depth. Identifiers whose row was untouched stay in
            // the set so we don't pointlessly re-run their batches.
            // Duplicate identifiers in either list collapse to "last wins";
            // a per-identifier resolution can only produce one rootImagePath
            // anyway, so equivalence under the last copy is good enough.
            let latestByID = Dictionary(latestEntries.map { ($0.identifier, $0) },
                                        uniquingKeysWith: { _, latest in latest })
            let previousByID = Dictionary(previousEntries.map { ($0.identifier, $0) },
                                          uniquingKeysWith: { _, latest in latest })
            dispatchedAlwaysIndexIdentifiers = dispatchedAlwaysIndexIdentifiers.filter { identifier in
                guard let latestEntry = latestByID[identifier] else { return false }
                guard let previousEntry = previousByID[identifier] else { return true }
                return latestEntry == previousEntry
            }
            startAlwaysIndexBatches()
        }
        // depth / maxConcurrency changes: intentional no-op; next startBatch picks
        // up the new values.
    }
}
#endif

// MARK: - StagingStore

extension RuntimeBackgroundIndexingCoordinator {
    /// Outcome of `StagingStore.applyEvent` — tells the coordinator what main-
    /// actor work the event triggered. Computed under the staging lock so the
    /// "did I just take ownership of the in-flight flush?" decision is atomic.
    fileprivate struct ApplyOutcome {
        var requiresImmediateFlush: Bool = false
        var didScheduleCoalescedFlush: Bool = false
        var shouldReloadEngineImages: Bool = false
    }

    /// Snapshot taken at the start of a flush. The lock is released before the
    /// coordinator publishes to the relays, so subscribers run unblocked while
    /// the next batch of events keeps mutating the staging store.
    fileprivate struct FlushSnapshot {
        let activeChanged: Bool
        let aggregateChanged: Bool
        let batches: [RuntimeIndexingBatch]
        let historyAdditions: [RuntimeIndexingBatch]

        var hasWork: Bool { activeChanged || aggregateChanged || !historyAdditions.isEmpty }
    }

    /// Lock-protected staging for `RuntimeBackgroundIndexingCoordinator`.
    /// Holds everything the off-main event pump touches; the coordinator's
    /// main-actor methods only see snapshots produced under the same lock.
    /// `@unchecked Sendable` because synchronization is via `NSLock` rather
    /// than the data-race detector.
    fileprivate final class StagingStore: @unchecked Sendable {
        private let lock = NSLock()

        // All fields below are touched only under `lock`.
        private var stagedBatches: [RuntimeIndexingBatch] = []
        private var pendingHistoryAdditions: [RuntimeIndexingBatch] = []
        private var hasPendingActiveChange = false
        private var pendingAggregateRefresh = false
        /// `true` while a `Task { @MainActor } sleep+flush` pair is outstanding.
        /// Set under the lock when an event causes a coalesced flush to be
        /// scheduled, cleared under the lock by `snapshotForFlush`. Bursty
        /// events that all arrive inside the window collapse into a single
        /// publish exactly as before.
        private var hasScheduledFlush = false
        private var documentBatchIDs: Set<RuntimeIndexingBatchID> = []

        /// Mutates the staged state for one event from the manager's
        /// AsyncStream. Returns the work the coordinator owes to the main
        /// actor. Stale events that arrive after a swap or cancellation —
        /// where the batch / item can no longer be located — are dropped
        /// silently rather than poisoning the dirty flags.
        func applyEvent(_ event: RuntimeIndexingEvent) -> ApplyOutcome {
            lock.lock()
            defer { lock.unlock() }

            var outcome = ApplyOutcome()

            switch event {
            case .batchStarted(let batch):
                stagedBatches.append(batch)
                hasPendingActiveChange = true
                pendingAggregateRefresh = true
                outcome.requiresImmediateFlush = true
            case .taskStarted(let id, let path):
                if mutateTaskItemLocked(batchID: id, path: path, { item in
                    item.state = .running
                }) {
                    hasPendingActiveChange = true
                    pendingAggregateRefresh = true
                }
            case .taskFinished(let id, let path, let result):
                if mutateTaskItemLocked(batchID: id, path: path, { item in
                    item.state = result
                }) {
                    hasPendingActiveChange = true
                    pendingAggregateRefresh = true
                }
            case .taskPrioritized(let id, let path):
                // Priority boost doesn't change progress / hasFailure /
                // hasActive, so we skip the aggregate refresh.
                if mutateTaskItemLocked(batchID: id, path: path, { item in
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
                outcome.requiresImmediateFlush = true
                outcome.shouldReloadEngineImages = true
            case .batchCancelled(let cancelled):
                // Cancellation always removes from active. Lands in history
                // too so the user can review what got cancelled.
                stagedBatches.removeAll { $0.id == cancelled.id }
                documentBatchIDs.remove(cancelled.id)
                pendingHistoryAdditions.append(cancelled)
                hasPendingActiveChange = true
                pendingAggregateRefresh = true
                outcome.requiresImmediateFlush = true
                outcome.shouldReloadEngineImages = true
            }

            // Schedule a coalesced flush only when nothing else has staked a
            // claim on the next-tick wake-up. The immediate-flush path will
            // pick up the same dirty flags so the scheduled task would be a
            // duplicate.
            if !outcome.requiresImmediateFlush, !hasScheduledFlush,
               hasPendingActiveChange || !pendingHistoryAdditions.isEmpty {
                hasScheduledFlush = true
                outcome.didScheduleCoalescedFlush = true
            }

            return outcome
        }

        /// Locates `(batchID, path)` and mutates the item in place. Returns
        /// `true` only on a hit so the caller knows the dirty flags are
        /// meaningful. Must be called with `lock` already held.
        private func mutateTaskItemLocked(
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

        /// Resets dirty flags + drains pending history under the lock and
        /// returns the snapshot to publish. `hasScheduledFlush` is cleared
        /// here so the next event that arrives after the snapshot is taken
        /// can stake a claim on the *next* coalesced flush.
        func snapshotForFlush() -> FlushSnapshot {
            lock.lock()
            defer { lock.unlock() }
            let activeChanged = hasPendingActiveChange
            let aggregateChanged = pendingAggregateRefresh
            let historyAdditions = pendingHistoryAdditions

            hasPendingActiveChange = false
            pendingAggregateRefresh = false
            pendingHistoryAdditions = []
            hasScheduledFlush = false

            // Snapshot batches only when the flush will actually publish them
            // — saves an array copy on the priority-boost-only path.
            let batches = (activeChanged || aggregateChanged) ? stagedBatches : []

            return FlushSnapshot(
                activeChanged: activeChanged,
                aggregateChanged: aggregateChanged,
                batches: batches,
                historyAdditions: historyAdditions
            )
        }

        func clearForEngineSwap() {
            lock.lock()
            defer { lock.unlock() }
            stagedBatches.removeAll()
            pendingHistoryAdditions.removeAll()
            hasPendingActiveChange = false
            pendingAggregateRefresh = false
            hasScheduledFlush = false
            documentBatchIDs.removeAll()
        }

        func clearPendingHistory() {
            lock.lock()
            defer { lock.unlock() }
            pendingHistoryAdditions.removeAll()
        }

        func insertDocumentBatchID(_ id: RuntimeIndexingBatchID) {
            lock.lock()
            defer { lock.unlock() }
            documentBatchIDs.insert(id)
        }

        func takeAllDocumentBatchIDs() -> Set<RuntimeIndexingBatchID> {
            lock.lock()
            defer { lock.unlock() }
            let ids = documentBatchIDs
            documentBatchIDs.removeAll()
            return ids
        }
    }
}

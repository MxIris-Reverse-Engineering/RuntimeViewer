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

    // Synchronous accessors so the ViewModel can do `Observable.combineLatest`
    // without re-subscribing inside drive callbacks. Mirror `batchesRelay.value`.
    public var batchesValue: [RuntimeIndexingBatch] { batchesRelay.value }
    public var historyValue: [RuntimeIndexingBatch] { historyRelay.value }

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

    public func clearHistory() {
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
        var batches = batchesRelay.value
        switch event {
        case .batchStarted(let batch):
            batches.append(batch)
        case .taskStarted(let id, let path):
            batches = batches.map { mutating($0) { batch in
                guard batch.id == id, let itemIndex = batch.items.firstIndex(where: { $0.id == path })
                else { return }
                batch.items[itemIndex].state = .running
            }}
        case .taskFinished(let id, let path, let result):
            batches = batches.map { mutating($0) { batch in
                guard batch.id == id, let itemIndex = batch.items.firstIndex(where: { $0.id == path })
                else { return }
                batch.items[itemIndex].state = result
            }}
        case .taskPrioritized(let id, let path):
            batches = batches.map { mutating($0) { batch in
                guard batch.id == id, let itemIndex = batch.items.firstIndex(where: { $0.id == path })
                else { return }
                batch.items[itemIndex].hasPriorityBoost = true
            }}
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
            // The manager finalized this batch regardless of failure status —
            // it's already removed from `activeBatches`. Drop it from
            // `documentBatchIDs` too so `documentWillClose` doesn't fire
            // no-op cancel Tasks for ghost ids. The UI side decision to keep
            // failed batches visible is independent of this bookkeeping.
            documentBatchIDs.remove(finished.id)
            Task { [engine] in
                await engine.reloadData(isReloadImageNodes: false)
            }

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
        }
        batchesRelay.accept(batches)
        refreshAggregate(batches: batches)
    }

    private func mutating<Value>(_ value: Value, _ mutate: (inout Value) -> Void) -> Value {
        var copy = value
        mutate(&copy)
        return copy
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
        let doneItems = batches.reduce(0) { $0 + $1.completedCount }
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
        // best-effort cancel to its manager for any document batches we own.
        let oldEngine = engine
        let oldBatchIDs = documentBatchIDs

        // 1) Stop pumps tied to the old engine. The Tasks were `for await`
        //    looping over an AsyncStream owned by the old manager; cancelling
        //    them ends the loops cleanly.
        eventPumpTask?.cancel()
        imageLoadedPumpTask?.cancel()
        eventPumpTask = nil
        imageLoadedPumpTask = nil

        // 2) Best-effort cancel of in-flight batches on the old manager.
        //    Fire-and-forget — old engine's manager will deinit shortly.
        if !oldBatchIDs.isEmpty {
            Task {
                for id in oldBatchIDs {
                    await oldEngine.backgroundIndexingManager.cancelBatch(id)
                }
            }
        }

        // 3) Drop UI state — the old engine's batches and history no longer apply.
        documentBatchIDs.removeAll()
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
        Task { [weak self] in
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
        imageLoadedPumpTask = Task { [weak self] in
            guard let self else { return }
            // Combine.Publisher.values bridges to AsyncSequence on macOS 12+ /
            // iOS 15+; the project's deployment targets satisfy this. Errors are
            // Never on this publisher, so no try is needed.
            for await path in self.engine.imageDidLoadPublisher.values {
                await self.handleImageLoaded(path: path)
            }
        }
    }

    private func handleImageLoaded(path: String) async {
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

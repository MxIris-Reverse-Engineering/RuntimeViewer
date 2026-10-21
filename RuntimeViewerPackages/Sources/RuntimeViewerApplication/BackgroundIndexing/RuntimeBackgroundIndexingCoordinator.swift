import Combine
import Foundation
import Observation
import RuntimeViewerCore
import RxSwift
import RxRelay
import Dependencies

#if canImport(RuntimeViewerSettings)
import RuntimeViewerSettings
#endif

/// Drives one engine's background indexing for every document on the engine, and keeps what the
/// Report navigator lists of it: the batches under way and, newest first, those that ended.
///
/// One per engine, shared by the documents on it — see `RuntimeEngineBackgroundWork`. They all
/// hear every batch the engine's manager runs, and there used to be a coordinator per document:
/// each dispatched the Always Index rows again, and each kept a history of its own, begun when it
/// opened, so two windows on one engine showed two different Reports. Brought into being with the
/// engine's work when the first document on the engine starts its background work, and closed when
/// the last one leaves.
@MainActor
public final class RuntimeBackgroundIndexingCoordinator {
    /// Soft cap on `historyRelay` size. A long-running session that triggers
    /// many always-index retries would otherwise grow history without bound;
    /// once this cap is exceeded we drop the oldest entries from the tail
    /// (history is inserted at index 0, so the tail is the oldest). The user
    /// can still manually clear via `clearHistory()`.
    private static let maxHistoryEntries = 100

    /// The engine whose background indexing this coordinator drives.
    private let engine: RuntimeEngine

    /// The last document on the engine left; see `close()`.
    private var isClosed = false

    /// Moves on each time what the coordinator dispatched stops counting: the
    /// engine coming back with a new process behind it, the coordinator
    /// closing. A dispatch that comes back under an older value was made for a
    /// process, or a coordinator, that is gone; see `isCurrent(_:)`.
    private var session = 0

    private let batchesRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
    private let historyRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
    /// Whether a batch is under way — what the Report navigator's tab marks. The rest of what the
    /// toolbar popover used to show, the overall progress and whether anything failed, went with
    /// it, and nothing reads it any more.
    private let hasActiveBatchRelay = BehaviorRelay<Bool>(value: false)

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
    /// Pump that retries the always-index rows after every fullReload.
    /// Required because remote engines (XPC / Bonjour) populate `imageList`
    /// asynchronously: the first `documentDidOpen` may see an empty list and
    /// resolve every imageName-only identifier to nil. Once the server's
    /// fullReload broadcast lands and the client's `imageList` is set, this
    /// pump retries. `dispatchedAlwaysIndexIdentifiers` gates re-entry so
    /// the pump idles for rows already dispatched this engine session, and a
    /// retry waits for the passes still dispatching
    /// (`alwaysIndexPassesUnderWay`): every batch's end reloads the engine,
    /// so without both, one pass's batches ending would set off pass after
    /// pass over the same rows.
    private var reloadDataPumpTask: Task<Void, Never>?
    #if canImport(RuntimeViewerSettings)
    @Dependency(\.settings)
    private var settings
    /// `documentDidOpen()` has run: a document opened on the engine.
    private var hasStarted = false
    /// Whether the engine was ready when last heard from, so a `false → true`
    /// edge — a new process behind the engine — can be told from the state
    /// replayed on subscribing.
    private var engineWasReady = false
    private var engineReadinessSubscription: AnyCancellable?
    /// Last observed values of each Settings.Indexing toggle, used by
    /// `handleSettingsChange` to detect transitions and dispatch only the
    /// minimal start / cancel work. Seeded by `bootstrapSettingsObservation`.
    private var lastKnownMasterEnabled: Bool = false
    private var lastKnownHeuristicEnabled: Bool = false
    private var lastKnownCustomEnabled: Bool = false
    /// What `custom.entries` asked of the engine when last looked at, as
    /// `alwaysIndexDispatches(of:)` projects it. Compared in place of the
    /// entries themselves, so an edit that changes nothing on this engine —
    /// another engine's choice on a row — is not taken for one that does.
    private var lastKnownAlwaysIndexDispatches: [AlwaysIndexDispatch] = []
    /// Identifiers from `custom.entries` that have successfully resolved
    /// to a path and had `startBatch` dispatched at least once during the
    /// current engine session — whether that started a batch, joined one,
    /// or found the image indexed already. Used by `startAlwaysIndexBatches`
    /// to skip no-op re-entry triggered by the reload pump. Reset when the
    /// engine comes back with a new process, on master off→on, custom off→on,
    /// and a change to what the entries ask of this engine, so genuinely new
    /// work re-runs.
    private var dispatchedAlwaysIndexIdentifiers: Set<String> = []
    /// Always-index passes of the current engine session still dispatching.
    /// A pass's rows enter `dispatchedAlwaysIndexIdentifiers` only as each
    /// dispatch comes back, so a pass started meanwhile would dispatch them
    /// a second time; the reload pump waits for these instead.
    private var alwaysIndexPassesUnderWay = 0
    /// An engine reload asked for a retry while a pass was dispatching; it
    /// runs once none is.
    private var isAlwaysIndexRetryPending = false
    #endif

    /// Brought into being by `RuntimeEngineBackgroundWork` for its engine.
    init(engine: RuntimeEngine) {
        self.engine = engine
        startEventPump()
        #if canImport(RuntimeViewerSettings)
        startReloadDataPump()
        bootstrapSettingsObservation()
        observeEngineReadiness()
        #endif
    }

    deinit {
        eventPumpTask?.cancel()
        reloadDataPumpTask?.cancel()
    }

    // MARK: - Public observables for UI

    public var batchesObservable: Observable<[RuntimeIndexingBatch]> {
        batchesRelay.asObservable()
    }

    public var hasActiveBatchObservable: Observable<Bool> {
        hasActiveBatchRelay.asObservable()
    }

    public var historyObservable: Observable<[RuntimeIndexingBatch]> {
        historyRelay.asObservable()
    }

    // MARK: - Public command surface

    /// Every command below speaks for every document on the engine: they all
    /// show this coordinator's batches and history.
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

    /// The last document on the engine left — closed, or moved to another
    /// engine. Nobody is left to show the engine's batches, so every one still
    /// under way is cancelled, and the coordinator asks for nothing again: not
    /// on an engine reload, not on a settings change, not on the engine coming
    /// back. Its history goes with it; the next document on the engine gets a
    /// coordinator of its own. `RuntimeEngineBackgroundWork` calls this.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        session += 1
        eventPumpTask?.cancel()
        reloadDataPumpTask?.cancel()
        eventPumpTask = nil
        reloadDataPumpTask = nil
        #if canImport(RuntimeViewerSettings)
        engineReadinessSubscription = nil
        alwaysIndexPassesUnderWay = 0
        isAlwaysIndexRetryPending = false
        #endif
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelAllBatches()
        }
    }

    /// Whether `session` is still the coordinator's: it has not closed, and
    /// the engine has not come back with a new process since.
    private func isCurrent(_ session: Int) -> Bool {
        !isClosed && self.session == session
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
                self.handleEvent(event)
            }
        }
    }

    /// Off-main event entry point. Mutates the lock-protected staging state
    /// inline, then dispatches the minimal main-actor work the outcome
    /// requires (immediate flush for lifecycle events, scheduled flush for
    /// task events). The engine's reload after a batch ends is the manager's
    /// own, once per batch however many documents are on the engine.
    nonisolated private func handleEvent(_ event: RuntimeIndexingEvent) {
        let outcome = staging.applyEvent(event)

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
            refreshHasActiveBatch(batches: snapshot.batches)
        }
        // Now safe to push history: subscribers see (new batches without
        // finished, new history with finished) — a fully consistent state.
        for batch in snapshot.historyAdditions {
            appendToHistory(batch)
        }
    }

    private func appendToHistory(_ batch: RuntimeIndexingBatch) {
        var updatedHistory = historyRelay.value
        // One entry per batch, should its end ever be heard twice.
        updatedHistory.removeAll { $0.id == batch.id }
        updatedHistory.insert(batch, at: 0)
        if updatedHistory.count > Self.maxHistoryEntries {
            updatedHistory.removeLast(updatedHistory.count - Self.maxHistoryEntries)
        }
        historyRelay.accept(updatedHistory)
    }

    private func refreshHasActiveBatch(batches: [RuntimeIndexingBatch]) {
        let hasActiveBatch = !batches.isEmpty
        if hasActiveBatchRelay.value != hasActiveBatch {
            hasActiveBatchRelay.accept(hasActiveBatch)
        }
    }
}

#if canImport(RuntimeViewerSettings)
extension RuntimeBackgroundIndexingCoordinator {
    /// A document opened on the engine. The first one starts the engine's
    /// background indexing — the main executable and the Always Index rows, as
    /// Settings has them — and from then on the engine reloading, Settings
    /// changing and the engine coming back carry it on, whichever windows are
    /// open. Every later document finds it started: the rows were dispatched
    /// for the engine, not for a window, and each window dispatching them
    /// again is what filled every Report on the engine with batches of 0
    /// images.
    public func documentDidOpen() {
        guard !isClosed, !hasStarted else { return }
        hasStarted = true
        dispatchForOpening()
    }

    /// What opening dispatches, and what an engine coming back with a new
    /// process needs dispatched again.
    private func dispatchForOpening() {
        let indexing = settings.indexing
        guard indexing.isEnabled else { return }
        if indexing.heuristic.isEnabled {
            startMainExecutableBatch(reason: .appLaunch)
        }
        if indexing.custom.isEnabled {
            startAlwaysIndexBatches()
        }
    }

    // MARK: - The engine coming back

    /// Follows the engine's readiness. A `false → true` edge is a new process
    /// behind the engine — the local runtime service relaunched, a peer
    /// reconnected, the engine's first connection — which has indexed none of
    /// what the old one had. The coordinator hears of it from the engine
    /// itself, whatever the documents on it have open: a document walks back
    /// to the image list only when it had something open, and the coordinator
    /// used to hear of the new process only through that walk.
    private func observeEngineReadiness() {
        engineWasReady = engine.state.isReady
        engineReadinessSubscription = engine.statePublisher
            .map(\.isReady)
            .sink { [weak self] isReady in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleEngineReadinessChange(isReady)
                }
            }
    }

    private func handleEngineReadinessChange(_ isReady: Bool) {
        guard !isClosed else { return }
        let becameReadyAgain = isReady && !engineWasReady
        engineWasReady = isReady
        guard becameReadyAgain else { return }
        engineDidReset()
    }

    /// What ran on the old process is cancelled, and opening's dispatch runs
    /// again on the new one. The history stays: it reads as what was indexed
    /// on the engine, as it did across a document's resets.
    private func engineDidReset() {
        session += 1
        alwaysIndexPassesUnderWay = 0
        isAlwaysIndexRetryPending = false
        dispatchedAlwaysIndexIdentifiers.removeAll()
        Task { [weak self, engine, session] in
            // Before anything is dispatched again: a batch of the old process
            // still under way would otherwise be handed back for its root,
            // and end cancelled with the row counted as dispatched.
            await engine.backgroundIndexingManager.cancelAllBatches()
            guard let self, self.isCurrent(session), self.hasStarted else { return }
            self.dispatchForOpening()
        }
    }

    // MARK: - Dispatching

    /// Shared logic for "index the main executable" batches. Both the opening
    /// path (reason `.appLaunch`) and the off→on settings toggle (reason
    /// `.settingsEnabled`) funnel through here so the Report's title-by-reason
    /// branch surfaces the correct label instead of always saying "App launch
    /// indexing". Callers are responsible for checking master / heuristic
    /// enablement before invoking — this method does not re-check.
    private func startMainExecutableBatch(reason: RuntimeIndexingBatchReason) {
        // The class is `@MainActor`, so this Task inherits main-actor isolation.
        // `session` is captured at task creation: a batch set up for a process
        // that has gone, or after the last document left, must not be taken
        // for one of the current session.
        Task { [weak self, engine, session] in
            guard let self, self.isCurrent(session) else { return }
            let indexing = self.settings.indexing
            // Re-check both gates after the Task hop because the settings
            // observation may have flipped a toggle between the caller's check
            // and this Task running.
            guard indexing.isEnabled, indexing.heuristic.isEnabled else { return }
            // mainExecutablePath is `async throws` because remote (XPC / TCP)
            // sources may fail; on launch we silently skip the batch in that
            // case rather than surface the error to the user.
            guard let root = try? await engine.mainExecutablePath(),
                  !root.isEmpty, self.isCurrent(session) else { return }
            let batchIdentifier = await engine.backgroundIndexingManager.startBatch(
                rootImagePath: root,
                depth: indexing.heuristic.depth,
                maxConcurrency: indexing.maxConcurrency,
                reason: reason)
            self.batchDidStart(batchIdentifier, in: session)
        }
    }

    /// A batch a dispatch of `session` started has come back. The last
    /// document left while it was being set up — after the close had
    /// cancelled every batch on the engine — and nobody is left to show it
    /// either.
    private func batchDidStart(_ batchIdentifier: RuntimeIndexingBatchID?, in session: Int) {
        guard isClosed, let batchIdentifier else { return }
        Task { [engine] in
            await engine.backgroundIndexingManager.cancelBatch(batchIdentifier)
        }
    }

    // MARK: - Always-index list

    /// One always-index entry as it applies to this coordinator's engine:
    /// the image to resolve and whether to follow its dependencies. An entry
    /// that is switched off, or limited to other engines, has none.
    struct AlwaysIndexDispatch: Equatable {
        let identifier: String
        let followDependencies: Bool
    }

    /// Projects `entries` onto the engine, in list order: what each enabled
    /// entry that applies here asks this engine to index.
    private func alwaysIndexDispatches(of entries: [Settings.Indexing.AlwaysIndexEntry]) -> [AlwaysIndexDispatch] {
        let engineKey = Settings.Indexing.EngineReference.key(for: engine)
        return entries
            .filter { $0.isEnabled && $0.applies(toEngineWithKey: engineKey) }
            .map { AlwaysIndexDispatch(identifier: $0.identifier, followDependencies: $0.followDependencies) }
    }

    /// Reads `Settings.Indexing.custom.entries` and asks the manager to index
    /// each resolvable entry that applies to this engine. Entries that don't
    /// resolve to a path in the engine's `imageList` are silently skipped —
    /// they stay out of `dispatchedAlwaysIndexIdentifiers`, so the next
    /// fullReload retry can pick them up.
    ///
    /// `isEnabled` is the per-row switch: disabled entries are skipped at
    /// dispatch time with the same semantics as a removed row — an
    /// already-running batch finishes naturally, only future dispatches
    /// are suppressed. Re-enabling changes what the entries ask of this
    /// engine, which resets the dispatched gate in `handleSettingsChange`
    /// so the entry re-dispatches. An entry limited to other engines is
    /// skipped the same way: on this engine it is a row switched off.
    ///
    /// `followDependencies` controls the per-entry depth: when false, the
    /// batch is pinned to `depth: 0` so the BFS only emits the resolved
    /// image itself; when true, the heuristic sub-mode's `depth` is reused
    /// so the BFS walks the full dependency closure like the main-executable
    /// batch.
    ///
    /// The manager hands a request for a root under way the batch running it,
    /// and starts none for an image indexed already, so re-entry on the same
    /// path is cheap — making this method safe to call from multiple
    /// triggers (opening, settings change, the engine coming back; the reload
    /// pump comes in through `retryAlwaysIndexBatches()`). Callers are
    /// responsible for checking master / custom enablement before invoking.
    private func startAlwaysIndexBatches() {
        guard !isClosed else { return }
        // Gate: only process entries we haven't dispatched yet this
        // session. The reload pump re-enters here after every fullReload,
        // including the ones the engine's own batches cause as they end;
        // without this filter every end would dispatch every row again.
        let pendingDispatches = alwaysIndexDispatches(of: settings.indexing.custom.entries).filter {
            !dispatchedAlwaysIndexIdentifiers.contains($0.identifier)
        }
        guard !pendingDispatches.isEmpty else { return }
        alwaysIndexPassesUnderWay += 1
        Task { [weak self, engine, session] in
            guard let self else { return }
            await self.dispatchAlwaysIndexEntries(pendingDispatches, on: engine, in: session)
            self.alwaysIndexPassDidEnd(in: session)
        }
    }

    /// One pass over `dispatches`, in list order.
    private func dispatchAlwaysIndexEntries(
        _ dispatches: [AlwaysIndexDispatch],
        on engine: RuntimeEngine,
        in session: Int
    ) async {
        guard isCurrent(session) else { return }
        let indexing = settings.indexing
        // Re-check both gates after the Task hop (mirrors
        // `startMainExecutableBatch`).
        guard indexing.isEnabled, indexing.custom.isEnabled else { return }
        // `engine.imageList` is `actor`-isolated; one hop fetches the
        // snapshot we'll use to resolve every identifier this round.
        // Remote engines populate `imageList` asynchronously via the
        // `imageList` message handler, so an early call here may see
        // `[]` — `startReloadDataPump` retries after fullReload, and
        // the gate leaves unresolved identifiers eligible for
        // retry until they finally match a path in `imageList`.
        let imageList = await engine.imageList
        guard isCurrent(session) else { return }
        for dispatch in dispatches {
            guard let resolvedPath = resolveAlwaysIndexIdentifier(dispatch.identifier, in: imageList) else { continue }
            let effectiveDepth = dispatch.followDependencies ? indexing.heuristic.depth : 0
            // No batch comes back for an image indexed already; the row is
            // dispatched all the same.
            let batchIdentifier = await engine.backgroundIndexingManager.startBatch(
                rootImagePath: resolvedPath,
                depth: effectiveDepth,
                maxConcurrency: indexing.maxConcurrency,
                reason: .alwaysIndex(identifier: dispatch.identifier))
            guard isCurrent(session) else {
                batchDidStart(batchIdentifier, in: session)
                return
            }
            dispatchedAlwaysIndexIdentifiers.insert(dispatch.identifier)
        }
    }

    /// A pass is over. Once none is under way, the retry an engine reload
    /// asked for meanwhile runs.
    private func alwaysIndexPassDidEnd(in session: Int) {
        // A pass of a session that is over: the engine coming back, or the
        // close, reset the count.
        guard isCurrent(session) else { return }
        alwaysIndexPassesUnderWay -= 1
        guard alwaysIndexPassesUnderWay == 0, isAlwaysIndexRetryPending else { return }
        isAlwaysIndexRetryPending = false
        let indexing = settings.indexing
        guard indexing.isEnabled, indexing.custom.isEnabled else { return }
        startAlwaysIndexBatches()
    }

    /// The reload pump's way in. A pass still dispatching has not put its
    /// rows in the gate yet, so a pass started now would dispatch them a
    /// second time — every engine reload during a pass used to start one, the
    /// reloads its own batches' ends cause included. The retry waits for the
    /// passes under way instead.
    private func retryAlwaysIndexBatches() {
        guard alwaysIndexPassesUnderWay == 0 else {
            isAlwaysIndexRetryPending = true
            return
        }
        startAlwaysIndexBatches()
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

    /// Pump that listens for `engine.reloadDataPublisher` and retries the
    /// always-index rows after each fullReload. Required so remote engines
    /// whose `imageList` arrives asynchronously can still resolve imageName
    /// identifiers once the list lands. The manager has a retry join the
    /// batches already running.
    private func startReloadDataPump() {
        reloadDataPumpTask = Task { [weak self, engine] in
            guard let self else { return }
            for await _ in engine.reloadDataPublisher.values {
                await MainActor.run {
                    guard !self.isClosed else { return }
                    let indexing = self.settings.indexing
                    guard indexing.isEnabled, indexing.custom.isEnabled else { return }
                    self.retryAlwaysIndexBatches()
                }
            }
        }
    }

    private func bootstrapSettingsObservation() {
        let indexing = settings.indexing
        self.lastKnownMasterEnabled = indexing.isEnabled
        self.lastKnownHeuristicEnabled = indexing.heuristic.isEnabled
        self.lastKnownCustomEnabled = indexing.custom.isEnabled
        self.lastKnownAlwaysIndexDispatches = alwaysIndexDispatches(of: indexing.custom.entries)
        self.subscribeToSettings()
    }

    private func subscribeToSettings() {
        withObservationTracking {
            let snapshot = settings.indexing
            _ = snapshot.isEnabled
            _ = snapshot.maxConcurrency
            _ = snapshot.heuristic.isEnabled
            _ = snapshot.heuristic.depth
            _ = snapshot.custom.isEnabled
            // Track custom entries too so the observation re-fires when the
            // user adds / edits / removes a row, flips a per-row toggle
            // (isEnabled / followDependencies) or changes a row's engines in
            // Settings UI.
            _ = snapshot.custom.entries
        } onChange: { [weak self] in
            // onChange fires off the main actor synchronously after any mutation.
            // Hop back to MainActor to (a) handle the change and (b) re-register.
            Task { @MainActor [weak self] in
                // A closed coordinator stops listening.
                guard let self, !self.isClosed else { return }
                self.handleSettingsChange()
                self.subscribeToSettings()
            }
        }
    }

    /// Reconciles the three Indexing toggles (master / heuristic / custom)
    /// against their last-known values. The matrix:
    ///
    /// - master off → on : honor whatever sub-toggles are on by dispatching
    ///   their batches with `.settingsEnabled` (heuristic) / always-index
    ///   refresh (custom).
    /// - master on → off : cancel **every** active batch.
    /// - heuristic off → on (master stays on) : dispatch a fresh main-
    ///   executable batch.
    /// - heuristic on → off (master stays on) : cancel only batches whose
    ///   reason `isHeuristic`; custom batches keep running.
    /// - custom off → on (master stays on) : reset the dispatched-identifiers
    ///   gate and dispatch always-index.
    /// - custom on → off (master stays on) : cancel only batches whose
    ///   reason `isCustom`; heuristic batches keep running.
    /// - what custom.entries ask of the engine changed (both stay on) :
    ///   drop removed identifiers from the gate, reset edited ones, dispatch
    ///   fresh entries. An edit that only touches other engines changes
    ///   nothing here.
    ///
    /// `depth` / `maxConcurrency` changes are intentional no-ops; next
    /// `startBatch` picks up the new values. The manager counts
    /// `maxConcurrency` across all batches, so from then on it bounds the
    /// batches still running too.
    private func handleSettingsChange() {
        let indexing = settings.indexing
        let wasMaster = lastKnownMasterEnabled
        let wasHeuristic = lastKnownHeuristicEnabled
        let wasCustom = lastKnownCustomEnabled
        let nowMaster = indexing.isEnabled
        let nowHeuristic = indexing.heuristic.isEnabled
        let nowCustom = indexing.custom.isEnabled
        lastKnownMasterEnabled = nowMaster
        lastKnownHeuristicEnabled = nowHeuristic
        lastKnownCustomEnabled = nowCustom

        if !wasMaster && nowMaster {
            // Master off→on: treat as a fresh start. Reset the dispatched gate
            // so every custom entry re-runs. Each sub-mode dispatches only if
            // its own toggle is on.
            dispatchedAlwaysIndexIdentifiers.removeAll()
            if nowHeuristic {
                startMainExecutableBatch(reason: .settingsEnabled)
            }
            if nowCustom {
                startAlwaysIndexBatches()
            }
            // Sync the entries baseline so the entries-changed branch below
            // doesn't double-fire after this off→on sweep.
            lastKnownAlwaysIndexDispatches = alwaysIndexDispatches(of: indexing.custom.entries)
            return
        }

        if wasMaster && !nowMaster {
            // Master on→off: stop everything; sub-toggles are now irrelevant.
            Task { [engine] in
                await engine.backgroundIndexingManager.cancelAllBatches()
            }
            // Don't update the entries baseline here — if the user flips
            // master back on later, we want the same baseline to compare
            // against on the next change.
            return
        }

        // From here on, master stayed on. Reconcile each sub-toggle in turn.

        if nowMaster {
            if !wasHeuristic && nowHeuristic {
                startMainExecutableBatch(reason: .settingsEnabled)
            } else if wasHeuristic && !nowHeuristic {
                Task { [engine] in
                    await engine.backgroundIndexingManager.cancelBatches(matching: { $0.reason.isHeuristic })
                }
            }

            if !wasCustom && nowCustom {
                // Custom off→on while master stays on: reset the gate so
                // every entry dispatches (same semantics as master off→on
                // for custom).
                dispatchedAlwaysIndexIdentifiers.removeAll()
                startAlwaysIndexBatches()
            } else if wasCustom && !nowCustom {
                Task { [engine] in
                    await engine.backgroundIndexingManager.cancelBatches(matching: { $0.reason.isCustom })
                }
            }
        }

        // Entry list changes: trigger always-index when what the entries ask
        // of this engine actually changed and both master + custom are
        // enabled. Adding / editing entries (or flipping a per-row toggle,
        // or adding this engine to a row) kicks off batches for the new
        // content; removing entries — and disabling a row via its isEnabled
        // switch, or taking this engine off it — is silent: already-running
        // batches keep running unless the user cancels them from the Report
        // navigator, and `startAlwaysIndexBatches` skips those rows on future
        // dispatches. Changing only other engines' choice on a row leaves the
        // projection as it was, so nothing happens here. Toggling
        // followDependencies on an existing entry also kicks off a new batch:
        // Manager dedup is by `rootImagePath`, so the existing depth=0 batch
        // stays the in-flight winner until it finishes. The depth change
        // picks up on the next start (the engine's next coordinator, say).
        let previousDispatches = lastKnownAlwaysIndexDispatches
        let latestDispatches = alwaysIndexDispatches(of: indexing.custom.entries)
        let dispatchesChanged = latestDispatches != previousDispatches
        lastKnownAlwaysIndexDispatches = latestDispatches
        // Skip when custom off→on already fired startAlwaysIndexBatches
        // above to avoid a duplicate (Manager dedup would no-op the second
        // call, but skipping the redundant Task hop is cleaner).
        if dispatchesChanged, nowMaster, nowCustom, wasCustom {
            // Drop identifiers no longer asked of this engine and reset
            // followDependencies-flipped ones so they can re-dispatch with
            // the new depth. Identifiers whose dispatch was untouched stay in
            // the set so we don't pointlessly re-run their batches.
            // Duplicate identifiers in either list collapse to "last wins";
            // a per-identifier resolution can only produce one rootImagePath
            // anyway, so equivalence under the last copy is good enough.
            let latestByIdentifier = Dictionary(latestDispatches.map { ($0.identifier, $0) },
                                                uniquingKeysWith: { _, latest in latest })
            let previousByIdentifier = Dictionary(previousDispatches.map { ($0.identifier, $0) },
                                                  uniquingKeysWith: { _, latest in latest })
            dispatchedAlwaysIndexIdentifiers = dispatchedAlwaysIndexIdentifiers.filter { identifier in
                guard let latestDispatch = latestByIdentifier[identifier] else { return false }
                guard let previousDispatch = previousByIdentifier[identifier] else { return true }
                return latestDispatch == previousDispatch
            }
            startAlwaysIndexBatches()
        }
    }
}
#endif

// MARK: - StagingStore

extension RuntimeBackgroundIndexingCoordinator {
    /// Outcome of `StagingStore.applyEvent` — tells the coordinator what main-
    /// actor work the event triggered. Computed under the staging lock so the
    /// "did I just take ownership of the in-flight flush?" decision is atomic.
    struct ApplyOutcome {
        var requiresImmediateFlush: Bool = false
        var didScheduleCoalescedFlush: Bool = false
    }

    /// Snapshot taken at the start of a flush. The lock is released before the
    /// coordinator publishes to the relays, so subscribers run unblocked while
    /// the next batch of events keeps mutating the staging store.
    struct FlushSnapshot {
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
    /// than the data-race detector. Internal so its tests can drive it event
    /// by event (`RuntimeBackgroundIndexingStagingTests`).
    final class StagingStore: @unchecked Sendable {
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

        /// Mutates the staged state for one event from the manager's
        /// AsyncStream. Returns the work the coordinator owes to the main
        /// actor. Stale events that arrive after a cancellation — where the
        /// batch / item can no longer be located — are dropped silently
        /// rather than poisoning the dirty flags.
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
            // Only a batch starting or ending changes whether one is under
            // way, so task events leave that refresh alone.
            case .taskStarted(let id, let path):
                if mutateTaskItemLocked(batchID: id, path: path, { item in
                    item.state = .running
                }) {
                    hasPendingActiveChange = true
                }
            case .taskFinished(let id, let path, let result):
                if mutateTaskItemLocked(batchID: id, path: path, { item in
                    item.state = result
                }) {
                    hasPendingActiveChange = true
                }
            case .taskPrioritized(let id, let path):
                if mutateTaskItemLocked(batchID: id, path: path, { item in
                    item.hasPriorityBoost = true
                }) {
                    hasPendingActiveChange = true
                }
            case .batchFinished(let finished):
                stagedBatches.removeAll { $0.id == finished.id }
                pendingHistoryAdditions.append(finished)
                hasPendingActiveChange = true
                pendingAggregateRefresh = true
                outcome.requiresImmediateFlush = true
            case .batchCancelled(let cancelled):
                // Cancellation always removes from active. Lands in history
                // too so the user can review what got cancelled.
                stagedBatches.removeAll { $0.id == cancelled.id }
                pendingHistoryAdditions.append(cancelled)
                hasPendingActiveChange = true
                pendingAggregateRefresh = true
                outcome.requiresImmediateFlush = true
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

        func clearPendingHistory() {
            lock.lock()
            defer { lock.unlock() }
            pendingHistoryAdditions.removeAll()
        }
    }
}

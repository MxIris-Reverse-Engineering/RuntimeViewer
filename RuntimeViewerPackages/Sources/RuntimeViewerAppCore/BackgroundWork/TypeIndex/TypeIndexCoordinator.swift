import Combine
import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Follows where the SDK type index of the engine's serving process stands —
/// the index that resolves the `__C.` type names of printed interfaces — for
/// the Report navigator's Imported Type Names rows and the toolbar's activity
/// display.
///
/// Built like `CrossReferencePreparationCoordinator`: one per engine, shared
/// by every document on the engine (see `RuntimeEngineBackgroundWork`). Unlike
/// it, the coordinator asks the engine for no work: the serving process
/// indexes on its own, as the images it prints need their SDK modules, and
/// this coordinator only asks it how far it is (`RuntimeEngine.typeIndexStatus()`):
///
/// 1. once as it starts, and again whenever the engine comes back with a new
///    process behind it;
/// 2. each time the process finishes a batch (`RuntimeDataChange.typeNamesResolved`);
/// 3. every `pollingIntervalNanoseconds` while a batch is queued on any
///    platform — the broadcast comes only as a batch ends, and the queued
///    count grows between two of them. Polling stops once nothing is building.
///
/// One round trip at a time: calls made while one is in flight coalesce into a
/// single one after it. An engine whose process has no type index — an iOS
/// device, an injected process, an older peer — answers `.empty`, and the
/// Report navigator then shows nothing for it.
@MainActor
public final class TypeIndexCoordinator {
    /// What the coordinator asks for the engine's status with. Test seam: the
    /// engine's own `typeIndexStatus()` unless a test hands another in.
    typealias StatusProvider = @Sendable () async -> RuntimeTypeIndexStatus

    /// How often the status is asked for while a batch is queued.
    nonisolated static let defaultPollingIntervalNanoseconds: UInt64 = 2_000_000_000

    private let engine: RuntimeEngine

    private let statusProvider: StatusProvider

    private let pollingIntervalNanoseconds: UInt64

    /// The engine's `.typeNamesResolved` broadcasts.
    private var dataChangeSubscription: AnyCancellable?

    /// The engine's readiness; see `observeEngineReadiness()`.
    private var engineReadinessObserver: RuntimeEngineReadinessEdgeObserver?

    private var refreshTask: Task<Void, Never>?

    private var isRefreshPending = false

    /// The wait before the next poll, while the index is building.
    private var pollingTask: Task<Void, Never>?

    /// The last document on the engine left; see `close()`.
    private var isClosed = false

    /// Where the engine's type index stands, as last answered; `.empty` before
    /// the first answer and for an engine without one.
    @RxObserved
    public private(set) var status: RuntimeTypeIndexStatus = .empty

    /// Whether a batch is queued on any platform.
    public var hasActiveIndexing: Driver<Bool> {
        $status.asDriver()
            .map(\.isBuilding)
            .distinctUntilChanged()
    }

    /// Whether a refresh or a poll is still under way. Test seam.
    var hasWorkUnderWay: Bool {
        refreshTask != nil || pollingTask != nil
    }

    /// Brought into being by `RuntimeEngineBackgroundWork` for its engine.
    /// `statusProvider` and `pollingIntervalNanoseconds` are test seams.
    init(
        engine: RuntimeEngine,
        statusProvider: StatusProvider? = nil,
        pollingIntervalNanoseconds: UInt64 = TypeIndexCoordinator.defaultPollingIntervalNanoseconds
    ) {
        self.engine = engine
        self.statusProvider = statusProvider ?? { [engine] in
            await engine.typeIndexStatus()
        }
        self.pollingIntervalNanoseconds = pollingIntervalNanoseconds
        observeEngineReadiness()
        observeTypeNamesResolved()
        refresh()
    }

    deinit {
        refreshTask?.cancel()
        pollingTask?.cancel()
    }

    // MARK: - Refreshing

    /// Asks the engine's process where its type index stands (`status`). One
    /// round trip at a time: calls made while one is in flight coalesce into a
    /// single one after it.
    public func refresh() {
        guard !isClosed else { return }
        guard refreshTask == nil else {
            isRefreshPending = true
            return
        }
        let statusProvider = statusProvider
        refreshTask = Task { [weak self] in
            // Closed, or the engine reset, before the task got to run: nothing is asked.
            guard !Task.isCancelled else { return }
            let newStatus = await statusProvider()
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            if status != newStatus {
                status = newStatus
            }
            updatePolling()
            if isRefreshPending {
                isRefreshPending = false
                refresh()
            }
        }
    }

    /// Schedules the next poll while a batch is queued, and stops polling once
    /// none is.
    private func updatePolling() {
        guard !isClosed, status.isBuilding else {
            cancelPolling()
            return
        }
        guard pollingTask == nil else { return }
        let pollingIntervalNanoseconds = pollingIntervalNanoseconds
        pollingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            guard let self, !Task.isCancelled else { return }
            pollingTask = nil
            refresh()
        }
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshPending = false
    }

    /// The last document on the engine left — closed, or moved to another
    /// engine: nothing is asked of the engine again. `RuntimeEngineBackgroundWork`
    /// calls this.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        dataChangeSubscription = nil
        engineReadinessObserver = nil
        cancelRefresh()
        cancelPolling()
    }

    // MARK: - Triggers

    /// Each batch the serving process finishes, on any platform, moves the
    /// status on.
    private func observeTypeNamesResolved() {
        dataChangeSubscription = engine.dataChangePublisher
            .filter { change in
                if case .typeNamesResolved = change { true } else { false }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    self.refresh()
                }
            }
    }

    private func observeEngineReadiness() {
        engineReadinessObserver = RuntimeEngineReadinessEdgeObserver(engine: engine) { [weak self] _ in
            guard let self, !isClosed else { return }
            engineDidReset()
        }
    }

    /// The process behind the engine is a new one, with an index of its own:
    /// what was known of the old one goes, and the new one is asked.
    private func engineDidReset() {
        cancelRefresh()
        cancelPolling()
        status = .empty
        refresh()
    }
}

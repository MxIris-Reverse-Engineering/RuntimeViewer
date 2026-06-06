import Foundation
import Observation
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import RxCocoa
import RxSwift

final class BackgroundIndexingPopoverViewModel: ViewModel<MainRoute> {
    @Observed private(set) var nodes: [BackgroundIndexingNode] = []
    @Observed private(set) var isEnabled: Bool = false
    @Observed private(set) var hasAnyBatch: Bool = false
    @Observed private(set) var hasAnyHistory: Bool = false
    @Observed private(set) var subtitle: String = ""

    struct Input {
        let cancelBatch: Signal<RuntimeIndexingBatchID>
        let cancelAll: Signal<Void>
        let clearHistory: Signal<Void>
        let openSettings: Signal<Void>
        let close: Signal<Void>
    }

    struct Output {
        let nodes: Driver<[BackgroundIndexingNode]>
        let isEnabled: Driver<Bool>
        let hasAnyBatch: Driver<Bool>
        let hasAnyHistory: Driver<Bool>
        let subtitle: Driver<String>
    }

    func transform(_ input: Input) -> Output {
        Observable.combineLatest(
            documentState.backgroundIndexingCoordinator.batchesObservable,
            documentState.backgroundIndexingCoordinator.historyObservable
        )
        .map { active, history in
            (Self.renderNodes(active: active, history: history), active, history)
        }
        .asDriver(onErrorJustReturn: ([], [], []))
        .driveOnNext { [weak self] newNodes, active, history in
            guard let self else { return }
            nodes = newNodes
            hasAnyBatch = !active.isEmpty
            hasAnyHistory = !history.isEmpty
        }
        .disposed(by: rx.disposeBag)

        documentState.backgroundIndexingCoordinator.aggregateStateObservable
            .asDriver(onErrorDriveWith: .empty())
            .driveOnNext { [weak self] state in
                guard let self else { return }
                subtitle = Self.subtitleFor(state)
            }
            .disposed(by: rx.disposeBag)

        // ViewModel base class is `@MainActor`, so `transform` runs on the
        // main actor; we can subscribe synchronously and seed the initial
        // value below.
        bootstrapIsEnabledObservation()

        input.openSettings.emit(to: appRouter.rx.trigger(.settings)).disposed(by: rx.disposeBag)

        input.close.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)

        input.cancelBatch.emitOnNext { [weak self] id in
            guard let self else { return }
            documentState.backgroundIndexingCoordinator.cancelBatch(id)
        }
        .disposed(by: rx.disposeBag)

        input.cancelAll.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.backgroundIndexingCoordinator.cancelAllBatches()
        }
        .disposed(by: rx.disposeBag)

        input.clearHistory.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.backgroundIndexingCoordinator.clearHistory()
        }
        .disposed(by: rx.disposeBag)

        return Output(
            nodes: $nodes.asDriver(),
            isEnabled: $isEnabled.asDriver(),
            hasAnyBatch: $hasAnyBatch.asDriver(),
            hasAnyHistory: $hasAnyHistory.asDriver(),
            subtitle: $subtitle.asDriver()
        )
    }

    /// Fine-grained driver scoped to a single batch. Cells subscribe to this
    /// directly because RxAppKit's `elementUpdated` path uses
    /// `NSOutlineView.reloadItem(_:)`, which only marks the row for redisplay —
    /// it does not re-invoke `viewFor:item:`, so the cell would otherwise show
    /// stale data until scroll/click forces a relayout.
    /// Searches both active and history relays so HISTORY rows render their
    /// archived final state instead of the empty placeholder.
    func batch(for id: RuntimeIndexingBatchID) -> Driver<RuntimeIndexingBatch> {
        Observable.combineLatest(
            documentState.backgroundIndexingCoordinator.batchesObservable,
            documentState.backgroundIndexingCoordinator.historyObservable
        )
        .compactMap { active, history in
            active.first(where: { $0.id == id })
                ?? history.first(where: { $0.id == id })
        }
        .distinctUntilChanged()
        .asDriver(onErrorDriveWith: .empty())
    }

    /// Same rationale as `batch(for:)`, scoped to one item inside a batch.
    func item(for batchID: RuntimeIndexingBatchID, itemID: String)
        -> Driver<RuntimeIndexingTaskItem> {
        Observable.combineLatest(
            documentState.backgroundIndexingCoordinator.batchesObservable,
            documentState.backgroundIndexingCoordinator.historyObservable
        )
        .compactMap { active, history in
            let batch = active.first(where: { $0.id == batchID })
                ?? history.first(where: { $0.id == batchID })
            return batch?.items.first(where: { $0.id == itemID })
        }
        .distinctUntilChanged()
        .asDriver(onErrorDriveWith: .empty())
    }

    /// Seeds `isEnabled` from settings once and registers the observation.
    /// Mirrors `RuntimeBackgroundIndexingCoordinator.bootstrapSettingsObservation`'s
    /// "seed on bootstrap, only re-register on change" pattern. Bound to the
    /// master switch — `isEnabled` represents "the background-indexing feature
    /// is on", regardless of which sub-mode (heuristic / custom) is doing the
    /// work.
    private func bootstrapIsEnabledObservation() {
        isEnabled = settings.indexing.isEnabled
        registerIsEnabledObservation()
    }

    /// Registers a one-shot Observation tracker. Re-registers itself on every
    /// change because Observation's `withObservationTracking` is single-fire —
    /// the `onChange` closure runs once, then the tracker is gone.
    private func registerIsEnabledObservation() {
        withObservationTracking {
            _ = settings.indexing.isEnabled
        } onChange: { [weak self] in
            // `onChange` fires off the main actor right after a mutation;
            // hop back to the main actor to read the latest value and
            // re-register the observation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = self.settings.indexing.isEnabled
                self.registerIsEnabledObservation()
            }
        }
    }

    private static func renderNodes(
        active: [RuntimeIndexingBatch],
        history: [RuntimeIndexingBatch]
    )
        -> [BackgroundIndexingNode] {
        var nodes: [BackgroundIndexingNode] = [
            .section(.active, batchCount: active.count, groups: makeReasonGroups(for: active, kind: .active))
        ]
        // History section is omitted entirely when empty so it doesn't clutter
        // the popover with an empty header. Active is always present so the
        // user always has the "ACTIVE" group as context.
        if !history.isEmpty {
            nodes.append(.section(.history, batchCount: history.count, groups: makeReasonGroups(for: history, kind: .history)))
        }
        return nodes
    }

    /// Buckets a section's batches by `reason.category`, emitting one
    /// `.reasonGroup` per non-empty category in a stable order
    /// (heuristic → always index → manual). Batch order inside each group
    /// preserves the input order, which matches how the coordinator queues
    /// them.
    ///
    /// `.alwaysIndex` groups flatten their batches' items directly into the
    /// group's children — each entry's batch typically contains just one item
    /// (or a small follow-dependency closure), so an intermediate batch row
    /// would just repeat the entry's image name. `.heuristic` and `.manual`
    /// keep the batch nesting because their batches usually contain many
    /// items each (full dependency closure for a document).
    private static func makeReasonGroups(
        for batches: [RuntimeIndexingBatch],
        kind: BackgroundIndexingNode.SectionKind
    )
        -> [BackgroundIndexingNode] {
        let categoryOrder: [RuntimeIndexingBatchReason.Category] = [
            .heuristic, .alwaysIndex, .manual
        ]
        var bucketed: [RuntimeIndexingBatchReason.Category: [RuntimeIndexingBatch]] = [:]
        for batch in batches {
            bucketed[batch.reason.category, default: []].append(batch)
        }
        return categoryOrder.compactMap { category in
            guard let groupBatches = bucketed[category], !groupBatches.isEmpty else {
                return nil
            }
            let children: [BackgroundIndexingNode]
            switch category {
            case .alwaysIndex:
                children = groupBatches.flatMap { batch in
                    batch.items.map { item in
                        BackgroundIndexingNode.item(batchID: batch.id, item: item)
                    }
                }
            case .heuristic, .manual:
                children = groupBatches.map(makeBatchNode)
            }
            return BackgroundIndexingNode.reasonGroup(
                kind, category, batchCount: groupBatches.count, children: children
            )
        }
    }

    private static func makeBatchNode(_ batch: RuntimeIndexingBatch)
        -> BackgroundIndexingNode {
        let itemNodes = batch.items.map { item in
            BackgroundIndexingNode.item(batchID: batch.id, item: item)
        }
        return .batch(batch, items: itemNodes)
    }

    private static func subtitleFor(
        _ state: RuntimeBackgroundIndexingCoordinator.AggregateState
    ) -> String {
        guard state.hasActiveBatch, let progress = state.progress else {
            return "Idle"
        }
        let percent = Int(progress * 100)
        return "\(percent)% complete"
    }
}

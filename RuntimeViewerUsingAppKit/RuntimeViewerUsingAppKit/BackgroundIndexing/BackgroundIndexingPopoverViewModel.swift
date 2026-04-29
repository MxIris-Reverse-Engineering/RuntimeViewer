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

    private let coordinator: RuntimeBackgroundIndexingCoordinator
    private let openSettingsRelay = PublishRelay<Void>()

    init(documentState: DocumentState,
         router: any Router<MainRoute>,
         coordinator: RuntimeBackgroundIndexingCoordinator)
    {
        self.coordinator = coordinator
        super.init(documentState: documentState, router: router)
    }

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

    func transform(_ input: Input) -> Output {
        Observable.combineLatest(
            coordinator.batchesObservable,
            coordinator.historyObservable
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

        coordinator.aggregateStateObservable
            .asDriver(onErrorDriveWith: .empty())
            .driveOnNext { [weak self] state in
                guard let self else { return }
                subtitle = Self.subtitleFor(state)
            }
            .disposed(by: rx.disposeBag)

        // ViewModel base class is `@MainActor`, so `transform` runs on the
        // main actor; we can subscribe synchronously and seed the initial
        // value below.
        subscribeToIsEnabled()

        input.cancelBatch.emitOnNext { [weak self] id in
            guard let self else { return }
            coordinator.cancelBatch(id)
        }
        .disposed(by: rx.disposeBag)

        input.cancelAll.emitOnNext { [weak self] in
            guard let self else { return }
            coordinator.cancelAllBatches()
        }
        .disposed(by: rx.disposeBag)

        input.clearHistory.emitOnNext { [weak self] in
            guard let self else { return }
            coordinator.clearHistory()
        }
        .disposed(by: rx.disposeBag)

        // Forward openSettings to output so the ViewController can call
        // `SettingsWindowController.shared.showWindow(nil)` directly.
        input.openSettings.emitOnNext { [weak self] in
            guard let self else { return }
            openSettingsRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        return Output(
            nodes: $nodes.asDriver(),
            isEnabled: $isEnabled.asDriver(),
            hasAnyBatch: $hasAnyBatch.asDriver(),
            hasAnyHistory: $hasAnyHistory.asDriver(),
            subtitle: $subtitle.asDriver(),
            openSettings: openSettingsRelay.asSignal()
        )
    }

    /// Fine-grained driver scoped to a single batch. Cells subscribe to this
    /// directly because RxAppKit's `elementUpdated` path uses
    /// `NSOutlineView.reloadItem(_:)`, which only marks the row for redisplay —
    /// it does not re-invoke `viewFor:item:`, so the cell would otherwise show
    /// stale data until scroll/click forces a relayout.
    func batch(for id: RuntimeIndexingBatchID) -> Driver<RuntimeIndexingBatch> {
        coordinator.batchesObservable
            .compactMap { $0.first(where: { $0.id == id }) }
            .distinctUntilChanged()
            .asDriver(onErrorDriveWith: .empty())
    }

    /// Same rationale as `batch(for:)`, scoped to one item inside a batch.
    func item(for batchID: RuntimeIndexingBatchID, itemID: String)
        -> Driver<RuntimeIndexingTaskItem>
    {
        coordinator.batchesObservable
            .compactMap { batches in
                batches.first(where: { $0.id == batchID })?
                    .items.first(where: { $0.id == itemID })
            }
            .distinctUntilChanged()
            .asDriver(onErrorDriveWith: .empty())
    }

    private func subscribeToIsEnabled() {
        withObservationTracking {
            _ = settings.indexing.backgroundMode.isEnabled
        } onChange: { [weak self] in
            // `onChange` fires off the main actor right after a mutation;
            // hop back to the main actor to read the latest value and
            // re-register the observation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = self.settings.indexing.backgroundMode.isEnabled
                self.subscribeToIsEnabled()
            }
        }
        // Seed the current value synchronously on initial subscribe.
        isEnabled = settings.indexing.backgroundMode.isEnabled
    }

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

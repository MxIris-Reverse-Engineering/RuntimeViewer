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
    @Observed private(set) var hasAnyFailure: Bool = false
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
        let clearFailed: Signal<Void>
        let openSettings: Signal<Void>
    }

    struct Output {
        let nodes: Driver<[BackgroundIndexingNode]>
        let isEnabled: Driver<Bool>
        let hasAnyBatch: Driver<Bool>
        let hasAnyFailure: Driver<Bool>
        let subtitle: Driver<String>
        // Forwarded to the ViewController so it can call
        // `SettingsWindowController.shared.showWindow(nil)` directly — mirrors
        // MCPStatusPopoverViewController.swift:200-203 (no `MainRoute` case
        // exists for openSettings).
        let openSettings: Signal<Void>
    }

    func transform(_ input: Input) -> Output {
        coordinator.batchesObservable
            .map(Self.renderNodes)
            .asDriver(onErrorJustReturn: [])
            .driveOnNext { [weak self] newNodes in
                guard let self else { return }
                nodes = newNodes
                hasAnyBatch = !newNodes.isEmpty
            }
            .disposed(by: rx.disposeBag)

        coordinator.aggregateStateObservable
            .asDriver(onErrorDriveWith: .empty())
            .driveOnNext { [weak self] state in
                guard let self else { return }
                subtitle = Self.subtitleFor(state)
                hasAnyFailure = state.hasAnyFailure
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

        input.clearFailed.emitOnNext { [weak self] in
            guard let self else { return }
            // Task 24 will add `coordinator.clearFailedBatches()`; for now
            // this is a TODO no-op. Reading `self` keeps the closure
            // well-formed and silences a "weak self captured but not used"
            // warning.
            _ = self
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
            hasAnyFailure: $hasAnyFailure.asDriver(),
            subtitle: $subtitle.asDriver(),
            openSettings: openSettingsRelay.asSignal()
        )
    }

    private func subscribeToIsEnabled() {
        withObservationTracking {
            _ = settings.backgroundIndexing.isEnabled
        } onChange: { [weak self] in
            // `onChange` fires off the main actor right after a mutation;
            // hop back to the main actor to read the latest value and
            // re-register the observation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = self.settings.backgroundIndexing.isEnabled
                self.subscribeToIsEnabled()
            }
        }
        // Seed the current value synchronously on initial subscribe.
        isEnabled = settings.backgroundIndexing.isEnabled
    }

    private static func renderNodes(from batches: [RuntimeIndexingBatch])
        -> [BackgroundIndexingNode]
    {
        var out: [BackgroundIndexingNode] = []
        for batch in batches {
            out.append(.batch(batch))
            for item in batch.items {
                out.append(.item(batchID: batch.id, item: item))
            }
        }
        return out
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

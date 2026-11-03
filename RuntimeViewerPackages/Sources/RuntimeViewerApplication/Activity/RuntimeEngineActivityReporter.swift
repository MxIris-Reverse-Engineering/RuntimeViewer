import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Works out an engine's activity reports — one run per kind of background work — from its three
/// coordinators, once for every document on the engine: part of `RuntimeEngineBackgroundWork`.
///
/// Each kind's work is read at most every `inputSamplingInterval`: the coordinators change many
/// times a second while images index, and the activity display shows a new state at most once a
/// second anyway.
@MainActor
final class RuntimeEngineActivityReporter {
    static let inputSamplingInterval: RxTimeInterval = .milliseconds(250)

    /// The engine's reports as of the latest change of its work.
    @RxObserved
    private(set) var snapshot: ActivityReportsSnapshot = .empty

    private var indexingTracker = ActivityRunTracker(kind: .backgroundIndexing)

    private var corpusTracker = ActivityRunTracker(kind: .searchableInterfaces)

    private var crossReferenceTracker = ActivityRunTracker(kind: .crossReferences)

    /// The batches the indexing run under way has had. A batch that finishes leaves the coordinator's
    /// batches for its history, where its last states are read from.
    private var indexingRunBatchIdentifiers: Set<RuntimeIndexingBatchID> = []

    private let now: () -> Date

    private let disposeBag = DisposeBag()

    init(
        indexingCoordinator: RuntimeBackgroundIndexingCoordinator,
        corpusCoordinator: FindCorpusCoordinator,
        crossReferencePreparationCoordinator: CrossReferencePreparationCoordinator,
        scheduler: SchedulerType = MainScheduler.instance,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now

        Observable.combineLatest(indexingCoordinator.batchesObservable, indexingCoordinator.historyObservable) { activeBatches, history in
            IndexingWork(activeBatches: activeBatches, history: history)
        }
        .throttle(Self.inputSamplingInterval, latest: true, scheduler: scheduler)
        .subscribeOnNextMainActor { [weak self] work in
            guard let self else { return }
            updateIndexing(with: work)
        }
        .disposed(by: disposeBag)

        Observable.combineLatest(
            corpusCoordinator.$buildStatesByImagePath.asObservable(),
            corpusCoordinator.$restoringImagePaths.asObservable(),
            corpusCoordinator.$prioritizedImagePaths.asObservable()
        ) { buildStates, restoringImagePaths, prioritizedImagePaths in
            CorpusWork(buildStates: buildStates, restoringImagePaths: restoringImagePaths, prioritizedImagePaths: prioritizedImagePaths)
        }
        .throttle(Self.inputSamplingInterval, latest: true, scheduler: scheduler)
        .subscribeOnNextMainActor { [weak self] work in
            guard let self else { return }
            updateCorpora(with: work)
        }
        .disposed(by: disposeBag)

        crossReferencePreparationCoordinator.$preparationStatesByImagePath.asObservable()
            .throttle(Self.inputSamplingInterval, latest: true, scheduler: scheduler)
            .subscribeOnNextMainActor { [weak self] preparationStates in
                guard let self else { return }
                updateCrossReferences(with: preparationStates)
            }
            .disposed(by: disposeBag)
    }

    // MARK: - Background indexing

    struct IndexingWork {
        var activeBatches: [RuntimeIndexingBatch]
        var history: [RuntimeIndexingBatch]
    }

    private func updateIndexing(with work: IndexingWork) {
        let activeBatchIdentifiers = Set(work.activeBatches.map(\.id))
        indexingRunBatchIdentifiers.formUnion(activeBatchIdentifiers)
        let finishedRunBatches = work.history.filter { indexingRunBatchIdentifiers.contains($0.id) && !activeBatchIdentifiers.contains($0.id) }
        let items = (work.activeBatches + finishedRunBatches).flatMap(Self.workItems(of:))
        let endedReport = indexingTracker.update(items: items, now: now())
        if indexingTracker.currentReport == nil {
            indexingRunBatchIdentifiers.removeAll()
        }
        publish(endedReport: endedReport)
    }

    static func workItems(of batch: RuntimeIndexingBatch) -> [ActivityWorkItem] {
        let isUserRequested = batch.reason == .manual
        return batch.items.map { item in
            ActivityWorkItem(identifier: "\(batch.id.raw.uuidString)/\(item.id)", state: workItemState(of: item.state), isUserRequested: isUserRequested)
        }
    }

    static func workItemState(of taskState: RuntimeIndexingTaskState) -> ActivityWorkItem.State {
        switch taskState {
        case .pending:
            .waiting
        case .running:
            .running(fractionCompleted: nil)
        case .completed:
            .succeeded
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    // MARK: - Searchable interfaces

    struct CorpusWork {
        var buildStates: [String: RuntimeInterfaceCorpusBuildState]
        var restoringImagePaths: Set<String>
        var prioritizedImagePaths: Set<String>
    }

    private func updateCorpora(with work: CorpusWork) {
        var items: [ActivityWorkItem] = []
        for (imagePath, buildState) in work.buildStates {
            var state = Self.workItemState(of: buildState)
            // Reading a stored corpus is work under way too, whatever the image's state says.
            if work.restoringImagePaths.contains(imagePath), !state.isActive {
                state = .running(fractionCompleted: nil)
            }
            guard state.isActive || corpusTracker.isInCurrentRun(imagePath) else { continue }
            items.append(ActivityWorkItem(identifier: imagePath, state: state, isUserRequested: work.prioritizedImagePaths.contains(imagePath)))
        }
        for imagePath in work.restoringImagePaths where work.buildStates[imagePath] == nil {
            items.append(ActivityWorkItem(identifier: imagePath, state: .running(fractionCompleted: nil)))
        }
        let endedReport = corpusTracker.update(items: items, now: now())
        publish(endedReport: endedReport)
    }

    static func workItemState(of buildState: RuntimeInterfaceCorpusBuildState) -> ActivityWorkItem.State {
        switch buildState {
        case .pending:
            .waiting
        case .building(let progress):
            .running(fractionCompleted: progress.total > 0 ? Double(progress.built) / Double(progress.total) : nil)
        case .built:
            .succeeded
        case .failed:
            .failed
        }
    }

    // MARK: - Cross references

    private func updateCrossReferences(with preparationStates: [String: CrossReferencePreparationState]) {
        var items: [ActivityWorkItem] = []
        for (imagePath, preparationState) in preparationStates {
            let state = Self.workItemState(of: preparationState)
            guard state.isActive || crossReferenceTracker.isInCurrentRun(imagePath) else { continue }
            items.append(ActivityWorkItem(identifier: imagePath, state: state))
        }
        let endedReport = crossReferenceTracker.update(items: items, now: now())
        publish(endedReport: endedReport)
    }

    static func workItemState(of preparationState: CrossReferencePreparationState) -> ActivityWorkItem.State {
        switch preparationState {
        case .pending:
            .waiting
        case .preparing(let progress):
            .running(fractionCompleted: progress.functionCount > 0 ? Double(progress.scannedFunctionCount) / Double(progress.functionCount) : nil)
        case .prepared:
            .succeeded
        case .failed:
            .failed
        }
    }

    // MARK: - Publishing

    private func publish(endedReport: ActivityReport?) {
        var newSnapshot = snapshot
        newSnapshot.runningReports = [indexingTracker.currentReport, corpusTracker.currentReport, crossReferenceTracker.currentReport]
            .compactMap { $0 }
            .sorted { $0.startDate > $1.startDate }
        if let endedReport {
            newSnapshot.lastCompletedReport = endedReport
        }
        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }
    }
}

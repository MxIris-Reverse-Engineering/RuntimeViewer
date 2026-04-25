import Foundation
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
    private let engine: RuntimeEngine
    private let disposeBag = DisposeBag()

    private let batchesRelay = BehaviorRelay<[RuntimeIndexingBatch]>(value: [])
    private let aggregateRelay = BehaviorRelay<AggregateState>(
        value: .init(hasActiveBatch: false, hasAnyFailure: false, progress: nil)
    )

    private var documentBatchIDs: Set<RuntimeIndexingBatchID> = []
    private var eventPumpTask: Task<Void, Never>?

    public init(documentState: DocumentState) {
        self.documentState = documentState
        self.engine = documentState.runtimeEngine
        startEventPump()
    }

    deinit { eventPumpTask?.cancel() }

    // MARK: - Public observables for UI

    public var batchesObservable: Observable<[RuntimeIndexingBatch]> {
        batchesRelay.asObservable()
    }

    public var aggregateStateObservable: Observable<AggregateState> {
        aggregateRelay.asObservable()
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
        case .batchFinished(let finished), .batchCancelled(let finished):
            batches.removeAll { $0.id == finished.id }
            documentBatchIDs.remove(finished.id)
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
}

#if canImport(RuntimeViewerSettings)
extension RuntimeBackgroundIndexingCoordinator {
    public func documentDidOpen() {
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
                reason: .appLaunch)
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

    private func currentBackgroundIndexingSettings() -> Settings.BackgroundIndexing {
        @Dependency(\.settings) var settings
        return settings.backgroundIndexing
    }
}
#endif

import Foundation
import Semaphore

public actor RuntimeBackgroundIndexingManager {
    private let engine: any BackgroundIndexingEngineRepresenting
    private let stream: AsyncStream<RuntimeIndexingEvent>
    private let continuation: AsyncStream<RuntimeIndexingEvent>.Continuation

    private var activeBatches: [RuntimeIndexingBatchID: BatchState] = [:]

    init(engine: any BackgroundIndexingEngineRepresenting) {
        self.engine = engine
        var cont: AsyncStream<RuntimeIndexingEvent>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    deinit { continuation.finish() }

    public nonisolated var events: AsyncStream<RuntimeIndexingEvent> { stream }

    public func currentBatches() -> [RuntimeIndexingBatch] {
        activeBatches.values.map(\.batch)
    }

    public func startBatch(
        rootImagePath: String,
        depth: Int,
        maxConcurrency: Int,
        reason: RuntimeIndexingBatchReason
    ) async -> RuntimeIndexingBatchID {
        let id = RuntimeIndexingBatchID()
        let items = await expandDependencyGraph(rootPath: rootImagePath, depth: depth)
        let batch = RuntimeIndexingBatch(
            id: id, rootImagePath: rootImagePath, depth: depth,
            reason: reason, items: items,
            isCancelled: false, isFinished: false)
        let state = BatchState(batch: batch, maxConcurrency: max(1, maxConcurrency))
        activeBatches[id] = state
        continuation.yield(.batchStarted(batch))

        let drivingTask = Task { [weak self] in
            guard let self else { return }
            await self.runBatch(id: id)
        }
        activeBatches[id]?.drivingTask = drivingTask
        return id
    }

    // Placeholder — Task 7 replaces with real BFS.
    func expandDependencyGraph(rootPath: String, depth: Int)
        async -> [RuntimeIndexingTaskItem]
    {
        if (try? await engine.isImageIndexed(path: rootPath)) == true { return [] }
        return [.init(id: rootPath, resolvedPath: rootPath,
                      state: .pending, hasPriorityBoost: false)]
    }

    private func runBatch(id: RuntimeIndexingBatchID) async {
        guard var state = activeBatches[id] else { return }
        // Empty batch finishes immediately.
        if state.batch.items.isEmpty {
            finalize(id: id, cancelled: false)
            return
        }
        // Task 8 implements real execution. For now mark all items completed.
        for index in state.batch.items.indices {
            state.batch.items[index].state = .completed
        }
        activeBatches[id] = state
        finalize(id: id, cancelled: false)
    }

    private func finalize(id: RuntimeIndexingBatchID, cancelled: Bool) {
        guard var state = activeBatches[id] else { return }
        state.batch.isFinished = true
        state.batch.isCancelled = cancelled
        activeBatches[id] = state
        if cancelled {
            continuation.yield(.batchCancelled(state.batch))
        } else {
            continuation.yield(.batchFinished(state.batch))
        }
        activeBatches[id] = nil
    }

    struct BatchState {
        var batch: RuntimeIndexingBatch
        var maxConcurrency: Int
        var drivingTask: Task<Void, Never>?
        var priorityBoostPaths: Set<String> = []
    }
}

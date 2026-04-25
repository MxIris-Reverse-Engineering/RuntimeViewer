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

    func expandDependencyGraph(rootPath: String, depth: Int)
        async -> [RuntimeIndexingTaskItem]
    {
        var visited: Set<String> = []
        var items: [RuntimeIndexingTaskItem] = []
        var frontier: [(path: String, level: Int)] = [(rootPath, 0)]

        while !frontier.isEmpty {
            let (path, level) = frontier.removeFirst()
            guard visited.insert(path).inserted else { continue }

            // `try?` — if the engine errors out (e.g. remote XPC drops mid-batch),
            // treat the image as unindexed; loadImageForBackgroundIndexing will
            // surface a real failure later. This matches Evolution 0002 Alt D:
            // failure ≠ indexed.
            if (try? await engine.isImageIndexed(path: path)) == true { continue }

            // Non-root paths that can't be opened as MachO go straight to
            // `.failed` and don't recurse — saves a wasted dlopen attempt later.
            // Root is always represented so that the batch has at least one item.
            if path != rootPath {
                let canOpen = await engine.canOpenImage(at: path)
                if !canOpen {
                    items.append(.init(id: path, resolvedPath: path,
                                       state: .failed(message: "cannot open MachOImage"),
                                       hasPriorityBoost: false))
                    continue
                }
            }

            items.append(.init(id: path, resolvedPath: path,
                               state: .pending, hasPriorityBoost: false))
            guard level < depth else { continue }

            // `try?` — if dependency lookup fails, treat as no deps; the path
            // itself is still pending and will be retried on next batch.
            let deps = (try? await engine.dependencies(for: path)) ?? []
            for dep in deps {
                if let resolved = dep.resolvedPath {
                    if !visited.contains(resolved) {
                        frontier.append((resolved, level + 1))
                    }
                } else {
                    if visited.insert(dep.installName).inserted {
                        items.append(.init(id: dep.installName, resolvedPath: nil,
                                           state: .failed(message: "path unresolved"),
                                           hasPriorityBoost: false))
                    }
                }
            }
        }
        return items
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

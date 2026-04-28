import Foundation
import Semaphore

public actor RuntimeBackgroundIndexingManager {
    /// `unowned` because the engine owns this manager
    /// (`RuntimeEngine.backgroundIndexingManager`); a strong back-reference
    /// would form a retain cycle that leaks engine + manager + section caches
    /// on every source switch.
    private unowned let engine: any BackgroundIndexingEngineRepresenting
    private let stream: AsyncStream<RuntimeIndexingEvent>
    private let continuation: AsyncStream<RuntimeIndexingEvent>.Continuation

    private var activeBatches: [RuntimeIndexingBatchID: BatchState] = [:]

    init(engine: any BackgroundIndexingEngineRepresenting) {
        self.engine = engine
        (self.stream, self.continuation) = AsyncStream<RuntimeIndexingEvent>.makeStream()
    }

    deinit { continuation.finish() }

    public nonisolated var events: AsyncStream<RuntimeIndexingEvent> { stream }

    public func currentBatches() -> [RuntimeIndexingBatch] {
        activeBatches.values.map(\.batch)
    }

    public func cancelBatch(_ id: RuntimeIndexingBatchID) {
        guard let state = activeBatches[id] else { return }
        activeBatches[id]?.batch.isCancelled = true
        state.drivingTask?.cancel()
        // The driving task's finalize() will emit .batchCancelled.
    }

    public func cancelAllBatches() {
        let ids = Array(activeBatches.keys)
        for id in ids { cancelBatch(id) }
    }

    public func prioritize(imagePath: String) {
        for (id, var state) in activeBatches {
            if let itemIndex = state.batch.items.firstIndex(where: {
                $0.id == imagePath && $0.state == .pending
            }) {
                state.batch.items[itemIndex].hasPriorityBoost = true
                state.priorityBoostPaths.insert(imagePath)
                activeBatches[id] = state
                continuation.yield(.taskPrioritized(batchID: id, path: imagePath))
            }
        }
    }

    public func startBatch(
        rootImagePath: String,
        depth: Int,
        maxConcurrency: Int,
        reason: RuntimeIndexingBatchReason
    ) async -> RuntimeIndexingBatchID {
        // Dedup before doing any expansion work. Real-world trigger:
        // `documentDidOpen` dispatches `.appLaunch` on the main executable
        // and dyld's add-image notification simultaneously fires
        // `handleImageLoaded` with the same path, dispatching `.imageLoaded`.
        // Two concurrent batches on the same root would duplicate work and
        // race for the same section caches.
        //
        // We dedup by `rootImagePath` only — `reason` is intentionally
        // ignored so `.appLaunch` ↔ `.imageLoaded(path:)` (which have
        // different discriminants) collapse together. Callers that want
        // a fresh batch must wait for the previous one to finish.
        if let existingId = findActiveBatchID(forRootImagePath: rootImagePath) {
            return existingId
        }

        let id = RuntimeIndexingBatchID()
        let items = await expandDependencyGraph(rootPath: rootImagePath, depth: depth)

        // Re-check after the suspension: actor reentrancy means another
        // `startBatch` call for the same root could have raced us through
        // its own `expandDependencyGraph`. The check + insert below is
        // atomic on the actor (no awaits between them) so the loser of the
        // race always sees the winner's insertion.
        if let existingId = findActiveBatchID(forRootImagePath: rootImagePath) {
            return existingId
        }

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

    private func findActiveBatchID(forRootImagePath rootImagePath: String)
        -> RuntimeIndexingBatchID?
    {
        activeBatches.first { _, state in
            !state.batch.isFinished && state.batch.rootImagePath == rootImagePath
        }?.key
    }

    func expandDependencyGraph(rootPath: String, depth: Int)
        async -> [RuntimeIndexingTaskItem]
    {
        var visited: Set<String> = []
        var items: [RuntimeIndexingTaskItem] = []
        // `ancestorRpaths` carries the LC_RPATH entries collected from every
        // loader walking up the chain to `rootPath`. dyld combines these with
        // the visited image's own LC_RPATH when resolving `@rpath/...`, so a
        // child framework with no LC_RPATH still resolves siblings via the
        // host's rpath. Root starts with `[]` and each level appends the
        // current image's own rpaths before descending. We don't dedup —
        // dyld doesn't either, and order matters for first-match resolution.
        var frontier: [(path: String, level: Int, ancestorRpaths: [String])] =
            [(rootPath, 0, [])]

        while !frontier.isEmpty {
            let (path, level, ancestorRpaths) = frontier.removeFirst()
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
            let deps = (try? await engine.dependencies(
                for: path, ancestorRpaths: ancestorRpaths)) ?? []
            // Pre-compute the ancestor list for the next level once. Failing
            // this lookup degrades the next level to "no inherited rpaths",
            // matching the `try?` failure-mode of `dependencies`/`isImageIndexed`.
            let ownRpaths = (try? await engine.rpaths(for: path)) ?? []
            let descendantAncestors = ancestorRpaths + ownRpaths
            for dep in deps {
                if let resolved = dep.resolvedPath {
                    if !visited.contains(resolved) {
                        frontier.append((resolved, level + 1, descendantAncestors))
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
        guard let startState = activeBatches[id] else { return }
        let maxConcurrency = startState.maxConcurrency

        // Pending paths in FIFO order, skipping already-terminal items.
        var pending = startState.batch.items
            .filter { !$0.state.isTerminal }
            .map(\.id)

        if pending.isEmpty {
            finalize(id: id, cancelled: false)
            return
        }

        let semaphore = AsyncSemaphore(value: maxConcurrency)
        var wasCancelled = false

        await withTaskGroup(of: Void.self) { group in
            while !pending.isEmpty {
                let path = popNextPrioritizedPath(batchID: id, pending: &pending)
                do {
                    try await semaphore.waitUnlessCancelled()
                } catch {
                    wasCancelled = true
                    break
                }
                if Task.isCancelled { wasCancelled = true; break }
                group.addTask { [weak self] in
                    defer { semaphore.signal() }
                    await self?.runSingleIndex(batchID: id, path: path)
                }
            }
            await group.waitForAll()
        }
        finalize(id: id, cancelled: wasCancelled || Task.isCancelled)
    }

    /// Selects the next path to dispatch. Priority-boosted paths jump to the head.
    private func popNextPrioritizedPath(
        batchID: RuntimeIndexingBatchID, pending: inout [String]
    ) -> String {
        if let state = activeBatches[batchID],
           let boostedPendingIndex = pending.firstIndex(where: { state.priorityBoostPaths.contains($0) })
        {
            return pending.remove(at: boostedPendingIndex)
        }
        return pending.removeFirst()
    }

    private func runSingleIndex(batchID: RuntimeIndexingBatchID, path: String) async {
        updateItemState(batchID: batchID, path: path, state: .running)
        continuation.yield(.taskStarted(batchID: batchID, path: path))
        do {
            try Task.checkCancellation()
            try await engine.loadImageForBackgroundIndexing(at: path)
            updateItemState(batchID: batchID, path: path, state: .completed)
            continuation.yield(.taskFinished(batchID: batchID, path: path,
                                             result: .completed))
        } catch is CancellationError {
            updateItemState(batchID: batchID, path: path, state: .cancelled)
        } catch {
            let state: RuntimeIndexingTaskState =
                .failed(message: error.localizedDescription)
            updateItemState(batchID: batchID, path: path, state: state)
            continuation.yield(.taskFinished(batchID: batchID, path: path,
                                             result: state))
        }
    }

    private func updateItemState(batchID: RuntimeIndexingBatchID,
                                 path: String,
                                 state: RuntimeIndexingTaskState)
    {
        guard var batchState = activeBatches[batchID] else { return }
        if let itemIndex = batchState.batch.items.firstIndex(where: { $0.id == path }) {
            batchState.batch.items[itemIndex].state = state
            activeBatches[batchID] = batchState
        }
    }

    private func finalize(id: RuntimeIndexingBatchID, cancelled: Bool) {
        guard var state = activeBatches[id] else { return }
        let effectiveCancel = cancelled || state.batch.isCancelled
        state.batch.isFinished = true
        state.batch.isCancelled = effectiveCancel
        // Mark any still-pending or running items as cancelled so the UI reflects state.
        if effectiveCancel {
            for itemIndex in state.batch.items.indices
            where state.batch.items[itemIndex].state == .pending
                || state.batch.items[itemIndex].state == .running
            {
                state.batch.items[itemIndex].state = .cancelled
            }
        }
        activeBatches[id] = state
        if effectiveCancel {
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

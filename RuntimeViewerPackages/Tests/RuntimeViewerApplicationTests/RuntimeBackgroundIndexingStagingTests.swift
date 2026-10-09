import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The indexing coordinator's staging across an engine swap and back (PR121.57). Swapping away
/// archives the old engine's running batches as cancelled and asks that engine to stop them; a
/// subscription made after swapping back replayed such a batch as under way, so it stood among the
/// running batches and in the history at once, and its real end then landed in the history a second
/// time — two rows with one identity, which neither the outline nor the cell ViewModel cache
/// supports. Events go into the staging store one by one here, so the outcome does not hang on the
/// timing of a real swap.
@Suite("RuntimeBackgroundIndexingStaging")
struct RuntimeBackgroundIndexingStagingTests {
    @Test("a batch archived by a swap and replayed after swapping back stays out of the running batches")
    func replayedArchivedBatchStaysInactive() {
        let staging = RuntimeBackgroundIndexingCoordinator.StagingStore()
        let batch = Self.runningBatch()
        _ = staging.applyEvent(.batchStarted(batch))
        _ = staging.snapshotForFlush()
        #expect(staging.drainForEngineSwap().activeBatches.map(\.id) == [batch.id])

        var replayed = batch
        replayed.isCancelled = true
        _ = staging.applyEvent(.batchStarted(replayed))

        let batches = staging.snapshotForFlush().batches
        #expect(!batches.contains { $0.id == batch.id }, "the replayed batch is running again: \(batches.map(\.id))")
    }

    @Test("the real end of an archived batch replaces the archive instead of adding a second entry")
    func endOfArchivedBatchReplacesArchive() {
        let staging = RuntimeBackgroundIndexingCoordinator.StagingStore()
        let batch = Self.runningBatch()
        _ = staging.applyEvent(.batchStarted(batch))
        _ = staging.snapshotForFlush()
        _ = staging.drainForEngineSwap()
        var replayed = batch
        replayed.isCancelled = true
        _ = staging.applyEvent(.batchStarted(replayed))
        _ = staging.snapshotForFlush()

        var ended = replayed
        ended.isFinished = true
        ended.items = ended.items.map { item in
            var cancelledItem = item
            cancelledItem.state = item.state.isTerminal ? item.state : .cancelled
            return cancelledItem
        }
        _ = staging.applyEvent(.batchCancelled(ended))

        let snapshot = staging.snapshotForFlush()
        #expect(snapshot.historyAdditions.isEmpty, "the archived batch's end was added to the history again")
        #expect(snapshot.historyReplacements.map(\.id) == [batch.id])
    }

    @Test("a batch that ends without a swap still goes to the history once")
    func endWithoutSwapIsAddedOnce() {
        let staging = RuntimeBackgroundIndexingCoordinator.StagingStore()
        let batch = Self.runningBatch()
        _ = staging.applyEvent(.batchStarted(batch))
        _ = staging.snapshotForFlush()
        var finished = batch
        finished.isFinished = true

        _ = staging.applyEvent(.batchFinished(finished))

        let snapshot = staging.snapshotForFlush()
        #expect(snapshot.historyAdditions.map(\.id) == [batch.id])
        #expect(snapshot.historyReplacements.isEmpty)
        #expect(!snapshot.batches.contains { $0.id == batch.id })
    }

    private static func runningBatch() -> RuntimeIndexingBatch {
        RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: "/Applications/Sample.app/Contents/MacOS/Sample",
            depth: 1,
            reason: .appLaunch,
            items: [
                RuntimeIndexingTaskItem(id: "/usr/lib/libobjc.A.dylib", resolvedPath: "/usr/lib/libobjc.A.dylib", state: .completed, hasPriorityBoost: false),
                RuntimeIndexingTaskItem(id: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", resolvedPath: nil, state: .running, hasPriorityBoost: false),
            ],
            isCancelled: false,
            isFinished: false
        )
    }
}

import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The indexing coordinator's staging, event by event, so the outcome does not hang on the timing
/// of a real batch. A batch archived as cancelled when a document moved to another engine used to
/// be listed twice once the document came back (PR121.57); the coordinator is the engine's now and
/// archives nothing, and the test for that case is in `RuntimeBackgroundIndexingSharedEngineTests`.
@Suite("RuntimeBackgroundIndexingStaging")
struct RuntimeBackgroundIndexingStagingTests {
    @Test("a batch that ends leaves the running batches and goes to the history once")
    func endIsAddedToTheHistoryOnce() {
        let staging = RuntimeBackgroundIndexingCoordinator.StagingStore()
        let batch = Self.runningBatch()
        _ = staging.applyEvent(.batchStarted(batch))
        _ = staging.snapshotForFlush()
        var finished = batch
        finished.isFinished = true

        _ = staging.applyEvent(.batchFinished(finished))

        let snapshot = staging.snapshotForFlush()
        #expect(snapshot.historyAdditions.map(\.id) == [batch.id])
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

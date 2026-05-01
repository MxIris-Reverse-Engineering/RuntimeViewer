import Testing
@testable import RuntimeViewerCore

@Suite struct RuntimeIndexingValueTypesTests {
    @Test func batchIDIsUnique() {
        let a = RuntimeIndexingBatchID()
        let b = RuntimeIndexingBatchID()
        #expect(a != b)
    }

    @Test func taskItemIsNotCompletedWhenPending() {
        let item = RuntimeIndexingTaskItem(id: "/foo", resolvedPath: "/foo",
                                           state: .pending, hasPriorityBoost: false)
        #expect(!item.state.isTerminal)
    }

    @Test func taskStateFailedIsTerminal() {
        let state = RuntimeIndexingTaskState.failed(message: "boom")
        #expect(state.isTerminal)
    }

    @Test func taskStateCancelledIsTerminal() {
        #expect(RuntimeIndexingTaskState.cancelled.isTerminal)
    }

    @Test func taskStateCompletedIsTerminal() {
        #expect(RuntimeIndexingTaskState.completed.isTerminal)
    }

    @Test func batchProgressReportsCompletedFraction() {
        let items: [RuntimeIndexingTaskItem] = [
            .init(id: "/a", resolvedPath: "/a", state: .completed, hasPriorityBoost: false),
            .init(id: "/b", resolvedPath: "/b", state: .completed, hasPriorityBoost: false),
            .init(id: "/c", resolvedPath: "/c", state: .pending, hasPriorityBoost: false),
            .init(id: "/d", resolvedPath: "/d", state: .failed(message: "x"), hasPriorityBoost: false),
        ]
        let batch = RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: "/root",
            depth: 1,
            reason: .manual,
            items: items,
            isCancelled: false,
            isFinished: false
        )
        #expect(batch.completedCount == 3)   // completed + failed both count toward "done"
        #expect(batch.totalCount == 4)
    }
}

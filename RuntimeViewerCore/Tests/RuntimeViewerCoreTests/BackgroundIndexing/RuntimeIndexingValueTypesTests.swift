import XCTest
@testable import RuntimeViewerCore

final class RuntimeIndexingValueTypesTests: XCTestCase {
    func test_batchID_isUnique() {
        let a = RuntimeIndexingBatchID()
        let b = RuntimeIndexingBatchID()
        XCTAssertNotEqual(a, b)
    }

    func test_taskItem_isNotCompletedWhenPending() {
        let item = RuntimeIndexingTaskItem(id: "/foo", resolvedPath: "/foo",
                                           state: .pending, hasPriorityBoost: false)
        XCTAssertFalse(item.state.isTerminal)
    }

    func test_taskState_failedIsTerminal() {
        let state = RuntimeIndexingTaskState.failed(message: "boom")
        XCTAssertTrue(state.isTerminal)
    }

    func test_taskState_cancelledIsTerminal() {
        XCTAssertTrue(RuntimeIndexingTaskState.cancelled.isTerminal)
    }

    func test_taskState_completedIsTerminal() {
        XCTAssertTrue(RuntimeIndexingTaskState.completed.isTerminal)
    }

    func test_batch_progress_reportsCompletedFraction() {
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
        XCTAssertEqual(batch.completedCount, 3)   // completed + failed both count toward "done"
        XCTAssertEqual(batch.totalCount, 4)
    }
}

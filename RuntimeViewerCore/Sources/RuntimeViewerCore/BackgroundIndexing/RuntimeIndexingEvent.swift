public enum RuntimeIndexingEvent: Sendable {
    case batchStarted(RuntimeIndexingBatch)
    case taskStarted(batchID: RuntimeIndexingBatchID, path: String)
    case taskFinished(batchID: RuntimeIndexingBatchID, path: String,
                      result: RuntimeIndexingTaskState)
    case taskPrioritized(batchID: RuntimeIndexingBatchID, path: String)
    case batchFinished(RuntimeIndexingBatch)
    case batchCancelled(RuntimeIndexingBatch)
}

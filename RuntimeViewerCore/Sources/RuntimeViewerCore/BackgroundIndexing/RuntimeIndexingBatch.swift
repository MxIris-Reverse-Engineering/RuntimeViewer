public struct RuntimeIndexingBatch: Sendable, Identifiable, Hashable {
    public let id: RuntimeIndexingBatchID
    public let rootImagePath: String
    public let depth: Int
    public let reason: RuntimeIndexingBatchReason
    public var items: [RuntimeIndexingTaskItem]
    public var isCancelled: Bool
    public var isFinished: Bool

    public init(id: RuntimeIndexingBatchID, rootImagePath: String, depth: Int,
                reason: RuntimeIndexingBatchReason,
                items: [RuntimeIndexingTaskItem],
                isCancelled: Bool, isFinished: Bool) {
        self.id = id
        self.rootImagePath = rootImagePath
        self.depth = depth
        self.reason = reason
        self.items = items
        self.isCancelled = isCancelled
        self.isFinished = isFinished
    }

    public var totalCount: Int { items.count }
    public var completedCount: Int { items.lazy.filter { $0.state.isTerminal }.count }
    public var progress: Double {
        guard totalCount > 0 else { return 1 }
        return Double(completedCount) / Double(totalCount)
    }
}

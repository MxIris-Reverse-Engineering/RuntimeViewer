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

    /// Items that have reached any terminal state (`.completed`, `.failed`,
    /// `.cancelled`). Drives `progress` because progress should reach 100%
    /// once every item has stopped processing, regardless of outcome.
    public var finishedCount: Int { items.lazy.filter { $0.state.isTerminal }.count }

    /// Items that finished with `.completed` only. Use this for UI labels
    /// where the user reads "X done out of Y" as "X succeeded".
    public var succeededCount: Int {
        items.lazy.filter { item in
            if case .completed = item.state { return true }
            return false
        }
        .count
    }

    public var failedCount: Int {
        items.lazy.filter { item in
            if case .failed = item.state { return true }
            return false
        }
        .count
    }

    public var cancelledCount: Int {
        items.lazy.filter { item in
            if case .cancelled = item.state { return true }
            return false
        }
        .count
    }

    public var progress: Double {
        guard totalCount > 0 else { return 1 }
        return Double(finishedCount) / Double(totalCount)
    }
}

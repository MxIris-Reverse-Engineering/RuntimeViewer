public struct RuntimeIndexingTaskItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let resolvedPath: String?
    public var state: RuntimeIndexingTaskState
    public var hasPriorityBoost: Bool

    public init(id: String, resolvedPath: String?,
                state: RuntimeIndexingTaskState,
                hasPriorityBoost: Bool) {
        self.id = id
        self.resolvedPath = resolvedPath
        self.state = state
        self.hasPriorityBoost = hasPriorityBoost
    }
}

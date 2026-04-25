public enum RuntimeIndexingTaskState: Sendable, Hashable {
    case pending
    case running
    case completed
    case failed(message: String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .pending, .running: return false
        }
    }
}

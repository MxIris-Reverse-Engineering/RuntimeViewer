import Foundation
import RuntimeViewerCrossReferences

/// Where an image's prepared cross references stand, as the engine's
/// `CrossReferencePreparationCoordinator` follows them.
public enum CrossReferencePreparationState: Hashable, Sendable {
    /// Asked for; the engine's process has not started on it.
    case pending
    case preparing(RuntimeCrossReferencePreparationProgress)
    case prepared(RuntimeCrossReferencePreparation)
    case failed(message: String)

    /// Waiting or being prepared.
    public var isActive: Bool {
        switch self {
        case .pending, .preparing: true
        case .prepared, .failed: false
        }
    }

    public var isPrepared: Bool {
        if case .prepared = self { return true }
        return false
    }
}

/// A preparation the engine's coordinator saw come to an end — prepared,
/// failed, or withdrawn by the user — kept for the Report navigator's
/// history.
public struct CrossReferenceFinishedPreparation: Hashable, Sendable, Identifiable {
    public enum Outcome: Hashable, Sendable {
        case prepared(RuntimeCrossReferencePreparation)
        case failed(message: String)
        /// The user withdrew the request. A query still waiting for the
        /// image keeps its preparation going.
        case cancelled
    }

    public let id: UUID

    public let imagePath: String

    public let outcome: Outcome

    public let finishedAt: Date

    public init(id: UUID = UUID(), imagePath: String, outcome: Outcome, finishedAt: Date) {
        self.id = id
        self.imagePath = imagePath
        self.outcome = outcome
        self.finishedAt = finishedAt
    }
}

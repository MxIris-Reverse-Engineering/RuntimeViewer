import Foundation
import RuntimeViewerCore

/// A corpus build a document saw come to an end — built, failed, or
/// withdrawn by the user — kept for the Report navigator's history.
public struct FindCorpusFinishedBuild: Hashable, Sendable, Identifiable {
    public enum Outcome: Hashable, Sendable {
        case built(RuntimeInterfaceCorpusBuildSummary)
        case failed(message: String)
        /// The user withdrew this document's request. Another document
        /// still asking for the image keeps the build going, and the next
        /// trigger for the image asks again.
        case cancelled
    }

    public let id: UUID

    public let imagePath: String

    public let outcome: Outcome

    /// When the document saw the build end; `nil` for a corpus another
    /// document built, which the document only learned of from the engine's
    /// coverage.
    public let finishedAt: Date?

    public init(id: UUID = UUID(), imagePath: String, outcome: Outcome, finishedAt: Date?) {
        self.id = id
        self.imagePath = imagePath
        self.outcome = outcome
        self.finishedAt = finishedAt
    }
}

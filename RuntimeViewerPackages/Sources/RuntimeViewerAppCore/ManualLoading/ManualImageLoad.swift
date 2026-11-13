import Foundation
import RuntimeViewerCore

/// An image the user is loading, as the Report navigator's Manual Loading lists it while the work
/// runs (proposal `editor-jump-bar`): Load now in the sidebar, an image the sidebar or an editor
/// pane's jump bar opens that still had to be indexed, Load Frameworks…, a Find result or an object
/// in an image not indexed yet.
public struct ManualImageLoad: Hashable, Sendable {
    public let imagePath: String

    public let startedAt: Date

    /// How far the work has come, `nil` until it reports anything — and for a load that reports
    /// nothing, such as Load Frameworks….
    public internal(set) var fractionCompleted: Double?

    /// The phase under way, as the sidebar's progress view names it.
    public internal(set) var phaseDescription: String?

    /// How many loads of the image run at once: the sidebar and a pane can index the same image
    /// together, and the row stays until the last of them ends.
    var runningCount: Int

    init(imagePath: String, startedAt: Date) {
        self.imagePath = imagePath
        self.startedAt = startedAt
        self.runningCount = 1
    }
}

/// A load of `ManualImageLoad` that ended, one entry per ending, newest first in the Report.
public struct FinishedManualImageLoad: Hashable, Sendable, Identifiable {
    public enum Outcome: Hashable, Sendable {
        case loaded
        case failed(message: String)
        case cancelled
    }

    public let id: UUID

    public let imagePath: String

    public let startedAt: Date

    public let finishedAt: Date

    public let outcome: Outcome

    /// What the load took, start to end.
    public var duration: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }
}

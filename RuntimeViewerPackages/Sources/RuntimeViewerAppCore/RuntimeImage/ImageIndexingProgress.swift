import Foundation
import RuntimeViewerCore

/// How far the indexing of an image has come, as the sidebar's loading view shows it: what an
/// `ImageIndexingProgressView` draws, wherever it is — the sidebar's object list and bookmarks, an
/// editor pane's image page, and the start page's recent objects while the sidebar's image loads.
public struct ImageIndexingProgress: Equatable, Sendable {
    public let fraction: Double

    public let description: String

    /// "120/3400", or empty while the phase counts nothing.
    public let itemCount: String

    public static let preparing = ImageIndexingProgress(fraction: 0, description: "Preparing...", itemCount: "")

    public init(fraction: Double, description: String, itemCount: String) {
        self.fraction = fraction
        self.description = description
        self.itemCount = itemCount
    }

    init(_ progress: RuntimeObjectsLoadingProgress) {
        self.init(
            fraction: progress.overallFraction,
            description: progress.phase.displayDescription,
            itemCount: progress.totalCount > 0 ? "\(progress.currentCount)/\(progress.totalCount)" : ""
        )
    }
}

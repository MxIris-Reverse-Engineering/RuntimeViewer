import Foundation
import RuntimeViewerCore
// Not RxAppKit, which links on macOS only: this module exports RxAppKit on macOS and RxUIKit on
// the iOS family, and both declare `OutlineNodeType`.
import RuntimeViewerArchitectures

/// The two kinds of work the Report navigator lists, each the first level of its outline — the
/// part Xcode's own Report navigator gives to a scheme or a package.
public enum ReportCategory: Hashable, Sendable, CaseIterable {
    /// Batches of the background indexer, each with its images.
    case backgroundIndexing
    /// The corpora that make indexed images searchable by the Find navigator.
    case searchableInterfaces
}

/// What a row of the Report navigator stands for. Stable across updates, so a row keeps its cell,
/// its expansion and its selection while what it shows changes.
public enum ReportNodeIdentifier: Hashable, Sendable {
    case category(ReportCategory)
    /// The single row a category shows while its feature is turned off in Settings.
    case turnedOff(ReportCategory)
    case indexingBatch(RuntimeIndexingBatchID)
    case indexingItem(batchID: RuntimeIndexingBatchID, imagePath: String)
    /// A corpus queued or being printed, by image.
    case corpusBuild(imagePath: String)
    /// A corpus build that ended, one row per ending.
    case finishedCorpusBuild(UUID)
}

/// The trailing status of a row: the small spinner while its work runs, an issue mark once it went
/// wrong — Xcode's `IDELogNavigatorStatusView`.
public enum ReportRowStatus: Hashable, Sendable {
    case none
    case running
    case failed(message: String)
}

/// One row of the Report navigator's outline.
///
/// The tree is rebuilt as a value whenever the reports change, so the outline can diff it; what a
/// row shows lives in its `cellViewModel`, which is kept across rebuilds and updates in place —
/// progress reaches a row on screen without the outline reloading it.
public struct ReportNode: Hashable, OutlineNodeType {
    public let identifier: ReportNodeIdentifier

    public let cellViewModel: ReportCellViewModel

    public let children: [ReportNode]

    public init(identifier: ReportNodeIdentifier, cellViewModel: ReportCellViewModel, children: [ReportNode] = []) {
        self.identifier = identifier
        self.cellViewModel = cellViewModel
        self.children = children
    }

    /// Equality stays the synthesized, whole-subtree one — the outline adapter reloads only when
    /// the new tree differs from the old — but the hash is the identifier's alone. The outline
    /// hashes its items for every lookup, and a category's subtree is up to a hundred batches of
    /// images.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension ReportNode: Differentiable {
    public var differenceIdentifier: ReportNodeIdentifier { identifier }

    /// A row's own content changes through its cell ViewModel, never through the node, so only
    /// its children can make a node differ from the one it replaces.
    public func isContentEqual(to source: ReportNode) -> Bool {
        children.map(\.identifier) == source.children.map(\.identifier)
    }
}
#endif

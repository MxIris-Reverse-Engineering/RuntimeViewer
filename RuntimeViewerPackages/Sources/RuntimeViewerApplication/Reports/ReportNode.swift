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
    /// The row a category shows while the engine's process cannot do its kind of work: a peer
    /// older than searchable interfaces.
    case unsupportedByEngine(ReportCategory)
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

    /// Equality and the hash are the identifier's alone — RxAppKit's contract for outline nodes
    /// since 0.6.0. `NSOutlineView` keeps a row open across `reloadData()` only when the new item
    /// is equal to the old one, so a batch whose images changed must still equal itself; whether
    /// anything changed is `isContentEqual(to:)`'s question, asked of the whole subtree. The hash
    /// stays cheap too: the outline hashes its items for every lookup, and a category's subtree is
    /// up to a hundred batches of images.
    public static func == (leftNode: ReportNode, rightNode: ReportNode) -> Bool {
        leftNode.identifier == rightNode.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension ReportNode: Differentiable {
    public var differenceIdentifier: ReportNodeIdentifier { identifier }

    /// A row's own content changes through its cell ViewModel, never through the node, so a node
    /// differs from the one it replaces only in the shape of its subtree, or in a row whose cell
    /// ViewModel is another object — a cell on screen stays bound to the one it was made with until
    /// its row is reloaded. RxAppKit's reload adapter asks this of the first level alone and trusts
    /// the answer for every level below, so it walks the whole subtree.
    public func isContentEqual(to source: ReportNode) -> Bool {
        identifier == source.identifier
            && cellViewModel === source.cellViewModel
            && children.count == source.children.count
            && zip(children, source.children).allSatisfy { child, sourceChild in
                child.isContentEqual(to: sourceChild)
            }
    }
}
#endif

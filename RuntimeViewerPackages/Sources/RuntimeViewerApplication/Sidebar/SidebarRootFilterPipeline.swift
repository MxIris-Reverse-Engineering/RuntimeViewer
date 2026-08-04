import Foundation

/// Off-main text filtering for the root sidebar's image tree.
///
/// Mirrors `SidebarRuntimeObjectFilterPipeline`'s three-step shape
/// (snapshot on main → verdicts anywhere → apply on main) but replicates
/// the root sidebar's own legacy semantics, which differ from the
/// runtime-object tree's:
///
/// - matching is a plain `localizedCaseInsensitiveContains` against a
///   node's aggregate name (its own name plus every descendant's),
/// - a node whose OWN name matches shows its entire subtree unfiltered,
/// - otherwise its children are filtered recursively by their aggregates.
///
/// Aggregate names are computed inside the verdict step (post-order, one
/// pass over the value tree) rather than read off the cells, so even the
/// first query after an image-list rebuild pays no recursive string
/// concatenation on the main thread.
///
/// Alignment contract: the cell tree must not change shape between
/// `snapshot` and `apply`. `SidebarRootViewModel` enforces this with a
/// generation token bumped on every `$nodes` rebuild; `apply` still bails
/// out on a shape mismatch as the last line of defense.
enum SidebarRootFilterPipeline {
    struct SnapshotNode: Sendable {
        let name: String
        let children: [SnapshotNode]
    }

    struct VerdictNode {
        /// Indices into `children` that survive the filter, in input
        /// order. When the node's own name matches, this is ALL indices —
        /// the legacy cascade cleared the filter below a matching node.
        var filteredChildIndices: [Int]
        var children: [VerdictNode]
    }

    struct ForestVerdict {
        var filteredTopIndices: [Int]
        var topVerdicts: [VerdictNode]

        static let empty = ForestVerdict(filteredTopIndices: [], topVerdicts: [])
    }

    // MARK: - Snapshot (main actor)

    @MainActor
    static func snapshot(of cells: [SidebarRootCellViewModel]) -> [SnapshotNode] {
        cells.map { cell in
            SnapshotNode(name: cell.node.name, children: snapshot(of: cell.unfilteredChildren))
        }
    }

    // MARK: - Verdicts (any thread, cancellable)

    /// Computes the full verdict forest for a non-empty `query` (the
    /// empty query takes the synchronous `resetToUnfiltered` fast path
    /// instead). Checks for cooperative cancellation between top-level
    /// nodes; a cancelled run returns `.empty`, which callers must
    /// discard (they already do via their generation guard).
    static func verdicts(for forest: [SnapshotNode], query: String) -> ForestVerdict {
        var topVerdicts: [VerdictNode] = []
        topVerdicts.reserveCapacity(forest.count)
        var topAggregates: [String] = []
        topAggregates.reserveCapacity(forest.count)
        for node in forest {
            guard !Task.isCancelled else { return .empty }
            let (verdict, aggregate) = verdictNode(for: node, query: query)
            topVerdicts.append(verdict)
            topAggregates.append(aggregate)
        }
        let filteredTopIndices = forest.indices.filter {
            topAggregates[$0].localizedCaseInsensitiveContains(query)
        }
        return ForestVerdict(filteredTopIndices: filteredTopIndices, topVerdicts: topVerdicts)
    }

    /// Post-order recursion computing each node's verdict and its
    /// aggregate name ("name childAggregate1 childAggregate2 …") in the
    /// same pass.
    private static func verdictNode(for node: SnapshotNode, query: String) -> (verdict: VerdictNode, aggregate: String) {
        var childVerdicts: [VerdictNode] = []
        childVerdicts.reserveCapacity(node.children.count)
        var childAggregates: [String] = []
        childAggregates.reserveCapacity(node.children.count)
        for child in node.children {
            let (childVerdict, childAggregate) = verdictNode(for: child, query: query)
            childVerdicts.append(childVerdict)
            childAggregates.append(childAggregate)
        }

        let aggregate = childAggregates.isEmpty
            ? node.name
            : "\(node.name) \(childAggregates.joined(separator: " "))"

        let filteredChildIndices: [Int]
        if node.name.localizedCaseInsensitiveContains(query) {
            filteredChildIndices = Array(node.children.indices)
            unfilterSubtree(&childVerdicts)
        } else {
            filteredChildIndices = node.children.indices.filter {
                childAggregates[$0].localizedCaseInsensitiveContains(query)
            }
        }
        return (VerdictNode(filteredChildIndices: filteredChildIndices, children: childVerdicts), aggregate)
    }

    /// Rewrites a verdict subtree to "show everything" — used below a
    /// node whose own name matched the query.
    private static func unfilterSubtree(_ verdicts: inout [VerdictNode]) {
        for verdictIndex in verdicts.indices {
            verdicts[verdictIndex].filteredChildIndices = Array(verdicts[verdictIndex].children.indices)
            unfilterSubtree(&verdicts[verdictIndex].children)
        }
    }

    // MARK: - Apply (main actor)

    /// Installs the verdict forest onto the live cell tree and returns
    /// the ordered top-level filtered array. Bails out (returning `nil`)
    /// on a shape mismatch — that means the tree changed under the
    /// pipeline, so keeping the previous filter output is safer than
    /// applying misaligned verdicts.
    @MainActor
    static func apply(
        _ forestVerdict: ForestVerdict,
        to cells: [SidebarRootCellViewModel]
    ) -> [SidebarRootCellViewModel]? {
        guard applyNodes(verdicts: forestVerdict.topVerdicts, to: cells) else { return nil }
        return forestVerdict.filteredTopIndices.map { cells[$0] }
    }

    @MainActor
    private static func applyNodes(verdicts: [VerdictNode], to cells: [SidebarRootCellViewModel]) -> Bool {
        guard verdicts.count == cells.count else { return false }
        for (cell, verdict) in zip(cells, verdicts) {
            let unfilteredChildren = cell.unfilteredChildren
            guard applyNodes(verdicts: verdict.children, to: unfilteredChildren) else { return false }
            cell.applyFilterOutcome(filteredChildren: verdict.filteredChildIndices.map { unfilteredChildren[$0] })
        }
        return true
    }

    /// Synchronous reset for the empty-query fast path: every node shows
    /// its full child list again. Pointer writes only — no string work —
    /// so clearing the search never flashes a stale tree.
    @MainActor
    static func resetToUnfiltered(_ cells: [SidebarRootCellViewModel]) {
        for cell in cells {
            let unfilteredChildren = cell.unfilteredChildren
            resetToUnfiltered(unfilteredChildren)
            cell.applyFilterOutcome(filteredChildren: unfilteredChildren)
        }
    }
}

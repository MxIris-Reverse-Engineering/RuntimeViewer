import Foundation

/// Off-main text filtering for the sidebar's runtime-object tree.
///
/// The pipeline splits one filter pass into three steps so the expensive
/// part never blocks the main thread:
///
/// 1. `snapshot(of:scope:)` (main actor) — captures each node's haystack
///    string and scope verdict into an immutable value tree. Cheap: the
///    haystacks are cached on the cell view models.
/// 2. `verdicts(for:context:)` (any thread) — pure recursion mirroring the
///    legacy synchronous semantics level by level: children are
///    scope-pruned, then matched via `FilterEngine.match`, preserving each
///    mode's display order (fuzzy score order, contains input order).
/// 3. `apply(_:to:context:scope:)` (main actor) — walks the live cell tree
///    aligned with the verdict tree and installs each node's outcome.
///    Guarded didSets on the cells make untouched rows free, so the apply
///    step costs O(changed highlights), not O(nodes).
///
/// Alignment contract: the cell tree must not change shape between
/// `snapshot` and `apply`. `SidebarRuntimeObjectViewModel` enforces this
/// with a generation token — reloads and specialization splices bump the
/// generation, and a stale pipeline run is discarded instead of applied.
enum SidebarRuntimeObjectFilterPipeline {
    struct SnapshotNode: Sendable {
        let haystack: String
        let subtreePassesScope: Bool
        let children: [SnapshotNode]
    }

    struct VerdictNode {
        var result: FuzzyFilterResult?
        var orderedFilteredChildIndices: [Int]
        var children: [VerdictNode]
    }

    struct ForestVerdict {
        var orderedFilteredTopIndices: [Int]
        var topVerdicts: [VerdictNode]

        static let empty = ForestVerdict(orderedFilteredTopIndices: [], topVerdicts: [])
    }

    // MARK: - Snapshot (main actor)

    @MainActor
    static func snapshot(
        of cells: [SidebarRuntimeObjectCellViewModel],
        scope: RuntimeObjectScope
    ) -> [SnapshotNode] {
        cells.map { cell in
            SnapshotNode(
                haystack: cell.currentAndChildrenNames,
                subtreePassesScope: scope.isActive ? cell.matchesScopeRecursively(scope) : true,
                children: snapshot(of: cell.unfilteredChildren, scope: scope)
            )
        }
    }

    // MARK: - Verdicts (any thread, cancellable)

    /// Computes the full verdict forest. Checks for cooperative
    /// cancellation between top-level nodes; a cancelled run returns
    /// `.empty`, which callers must discard (they already do via their
    /// generation guard).
    static func verdicts(for forest: [SnapshotNode], context: FilterContext) -> ForestVerdict {
        var topVerdicts: [VerdictNode] = []
        topVerdicts.reserveCapacity(forest.count)
        for node in forest {
            guard !Task.isCancelled else { return .empty }
            topVerdicts.append(verdictNode(for: node, context: context))
        }

        let orderedFilteredTopIndices = stampMatches(
            of: forest,
            into: &topVerdicts,
            context: context
        )
        return ForestVerdict(
            orderedFilteredTopIndices: orderedFilteredTopIndices,
            topVerdicts: topVerdicts
        )
    }

    private static func verdictNode(for node: SnapshotNode, context: FilterContext) -> VerdictNode {
        var childVerdicts = node.children.map { verdictNode(for: $0, context: context) }
        let orderedFilteredChildIndices = stampMatches(
            of: node.children,
            into: &childVerdicts,
            context: context
        )
        return VerdictNode(
            result: nil,
            orderedFilteredChildIndices: orderedFilteredChildIndices,
            children: childVerdicts
        )
    }

    /// Scope-prunes `nodes`, matches the survivors' haystacks, stamps each
    /// match's highlight result onto the corresponding verdict, and returns
    /// the matched indices in display order — the exact semantics of the
    /// legacy per-level `FilterEngine.filter` call.
    private static func stampMatches(
        of nodes: [SnapshotNode],
        into verdicts: inout [VerdictNode],
        context: FilterContext
    ) -> [Int] {
        let scopedIndices = nodes.indices.filter { nodes[$0].subtreePassesScope }
        let matches = FilterEngine.match(context, haystacks: scopedIndices.map { nodes[$0].haystack })
        var orderedFilteredIndices: [Int] = []
        orderedFilteredIndices.reserveCapacity(matches.count)
        for match in matches {
            let nodeIndex = scopedIndices[match.haystackIndex]
            verdicts[nodeIndex].result = match.result
            orderedFilteredIndices.append(nodeIndex)
        }
        return orderedFilteredIndices
    }

    // MARK: - Apply (main actor)

    /// Installs the verdict forest onto the live cell tree and returns the
    /// ordered top-level filtered array. Bails out (returning `nil`) on a
    /// shape mismatch — that means the tree changed under the pipeline and
    /// the caller's generation guard failed to catch it, so keeping the
    /// previous filter output is safer than applying misaligned verdicts.
    @MainActor
    static func apply(
        _ forestVerdict: ForestVerdict,
        to cells: [SidebarRuntimeObjectCellViewModel],
        context: FilterContext,
        scope: RuntimeObjectScope
    ) -> [SidebarRuntimeObjectCellViewModel]? {
        guard applyNodes(verdicts: forestVerdict.topVerdicts, to: cells, context: context, scope: scope) else {
            return nil
        }
        return forestVerdict.orderedFilteredTopIndices.map { cells[$0] }
    }

    @MainActor
    private static func applyNodes(
        verdicts: [VerdictNode],
        to cells: [SidebarRuntimeObjectCellViewModel],
        context: FilterContext,
        scope: RuntimeObjectScope
    ) -> Bool {
        guard verdicts.count == cells.count else { return false }
        for (cell, verdict) in zip(cells, verdicts) {
            let unfilteredChildren = cell.unfilteredChildren
            guard applyNodes(verdicts: verdict.children, to: unfilteredChildren, context: context, scope: scope) else {
                return false
            }
            cell.applyFilterOutcome(
                context: context,
                scope: scope,
                result: verdict.result,
                filteredChildren: verdict.orderedFilteredChildIndices.map { unfilteredChildren[$0] }
            )
        }
        return true
    }
}

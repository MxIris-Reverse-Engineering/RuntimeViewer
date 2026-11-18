import Foundation

/// Off-main filtering for the root sidebar's image tree.
///
/// Mirrors `SidebarRuntimeObjectFilterPipeline`'s three-step shape
/// (snapshot on main → verdicts anywhere → apply on main), with the image
/// tree's own semantics: an image — a leaf — is shown when the names along its
/// path satisfy the filter (`NavigatorTextFilter`), and a directory is shown
/// when an image under it is.
///
/// - A term a name can satisfy — Contains, Begins With, Ends With, Like —
///   holds for an image when any name on its path does: the image's own, or
///   one of its directories'. A directory whose name matches therefore shows
///   everything under it, which is the legacy rule of the plain text query.
/// - Does Not Contain holds only while no name on the path contains its
///   value, so it hides a whole directory with everything under it.
/// - Every term must hold, as in Xcode's navigators.
///
/// With a single Contains term this is the legacy cascade: a node shows when
/// its own name or a descendant's matches, and a node whose own name matches
/// shows its whole subtree.
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
        /// Indices into `children` that survive the filter, in input order.
        var filteredChildIndices: [Int]
        var children: [VerdictNode]
    }

    struct ForestVerdict {
        var filteredTopIndices: [Int]
        var topVerdicts: [VerdictNode]

        static let empty = ForestVerdict(filteredTopIndices: [], topVerdicts: [])
    }

    /// What the names from the root down to a node have settled.
    private struct PathState {
        /// For each term a name can satisfy, whether one on the path does.
        var satisfiedInclusions: [Bool]
        /// Whether a name on the path contains a Does Not Contain value.
        var isExcluded: Bool
    }

    // MARK: - Snapshot (main actor)

    @MainActor
    static func snapshot(of cells: [SidebarRootCellViewModel]) -> [SnapshotNode] {
        cells.map { cell in
            SnapshotNode(name: cell.node.name, children: snapshot(of: cell.unfilteredChildren))
        }
    }

    // MARK: - Verdicts (any thread, cancellable)

    /// Computes the full verdict forest for a filter with at least one term
    /// (an empty one takes the synchronous `resetToUnfiltered` fast path
    /// instead). Checks for cooperative cancellation between top-level nodes;
    /// a cancelled run returns `.empty`, which callers must discard (they
    /// already do via their generation guard).
    static func verdicts(for forest: [SnapshotNode], matcher: NavigatorTextFilter.Matcher) -> ForestVerdict {
        // Contract tripwire: an empty filter passes everything, which the
        // fast path installs without building verdicts. The sole caller
        // upholds this today; a second call site is where it would silently
        // cost a full pass.
        assert(!matcher.isEmpty, "an empty filter takes the resetToUnfiltered fast path, never verdicts(for:matcher:)")
        let inclusionTerms = matcher.compiledTerms.filter { !$0.isExclusion }
        let exclusionTerms = matcher.compiledTerms.filter(\.isExclusion)
        let rootPathState = PathState(satisfiedInclusions: Array(repeating: false, count: inclusionTerms.count), isExcluded: false)
        var topVerdicts: [VerdictNode] = []
        topVerdicts.reserveCapacity(forest.count)
        var filteredTopIndices: [Int] = []
        for (nodeIndex, node) in forest.enumerated() {
            guard !Task.isCancelled else { return .empty }
            let (verdict, hasPassingImage) = verdictNode(
                for: node,
                inclusionTerms: inclusionTerms,
                exclusionTerms: exclusionTerms,
                inheritedPathState: rootPathState
            )
            topVerdicts.append(verdict)
            if hasPassingImage {
                filteredTopIndices.append(nodeIndex)
            }
        }
        return ForestVerdict(filteredTopIndices: filteredTopIndices, topVerdicts: topVerdicts)
    }

    /// The node's verdict, and whether an image at or under it passes. Below an
    /// excluded name nothing can pass, so the names there are not tested — the
    /// verdicts are still built, because `apply` walks every cell.
    private static func verdictNode(
        for node: SnapshotNode,
        inclusionTerms: [NavigatorTextFilter.CompiledTerm],
        exclusionTerms: [NavigatorTextFilter.CompiledTerm],
        inheritedPathState: PathState
    ) -> (verdict: VerdictNode, hasPassingImage: Bool) {
        var pathState = inheritedPathState
        if !pathState.isExcluded {
            pathState.isExcluded = exclusionTerms.contains { !$0.matches(node.name) }
        }
        if !pathState.isExcluded {
            for termIndex in inclusionTerms.indices where !pathState.satisfiedInclusions[termIndex] {
                pathState.satisfiedInclusions[termIndex] = inclusionTerms[termIndex].matches(node.name)
            }
        }

        guard !node.children.isEmpty else {
            let passes = !pathState.isExcluded && !pathState.satisfiedInclusions.contains(false)
            return (VerdictNode(filteredChildIndices: [], children: []), passes)
        }

        var childVerdicts: [VerdictNode] = []
        childVerdicts.reserveCapacity(node.children.count)
        var filteredChildIndices: [Int] = []
        for (childIndex, child) in node.children.enumerated() {
            let (childVerdict, childHasPassingImage) = verdictNode(
                for: child,
                inclusionTerms: inclusionTerms,
                exclusionTerms: exclusionTerms,
                inheritedPathState: pathState
            )
            childVerdicts.append(childVerdict)
            if childHasPassingImage {
                filteredChildIndices.append(childIndex)
            }
        }
        return (VerdictNode(filteredChildIndices: filteredChildIndices, children: childVerdicts), !filteredChildIndices.isEmpty)
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

    /// Synchronous reset for the empty-filter fast path: every node shows
    /// its full child list again. Pointer writes only — no string work —
    /// so clearing the filter never flashes a stale tree.
    @MainActor
    static func resetToUnfiltered(_ cells: [SidebarRootCellViewModel]) {
        for cell in cells {
            let unfilteredChildren = cell.unfilteredChildren
            resetToUnfiltered(unfilteredChildren)
            cell.applyFilterOutcome(filteredChildren: unfilteredChildren)
        }
    }
}

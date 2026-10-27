import Foundation

/// Off-main filtering for the sidebar's runtime-object tree.
///
/// The pipeline splits one filter pass into three steps so the expensive
/// part never blocks the main thread:
///
/// 1. `snapshot(of:scope:includesHaystacks:)` (main actor) — captures each
///    node's name, scope verdict and, when the pass has a fuzzy query,
///    haystack string into an immutable value tree. Cheap: the haystacks are
///    cached on the cell view models.
/// 2. `verdicts(for:context:nameMatcher:)` (any thread) — pure recursion
///    mirroring the legacy synchronous semantics level by level: each node
///    is kept when it, or a descendant, passes the scope and the text
///    filter's terms on its own name; the survivors are then matched against
///    the fuzzy query (`passInputs(for:filterMode:isCaseSensitive:)`) via
///    `FilterEngine.match`, preserving each mode's display order (fuzzy score
///    order, contains input order).
/// 3. `apply(_:to:context:scope:nameMatcher:)` (main actor) — walks the live
///    cell tree aligned with the verdict tree and installs each node's
///    outcome. Guarded didSets on the cells make untouched rows free, so the
///    apply step costs O(changed highlights), not O(nodes).
///
/// Alignment contract: the cell tree must not change shape between
/// `snapshot` and `apply`. `SidebarRuntimeObjectViewModel` enforces this
/// with a generation token — reloads and specialization splices bump the
/// generation, and a stale pipeline run is discarded instead of applied.
enum SidebarRuntimeObjectFilterPipeline {
    struct SnapshotNode: Sendable {
        /// What the typed text is fuzzy matched against: the node's name and
        /// every descendant's. Empty when the pass has no fuzzy query.
        let haystack: String
        /// The node's own name, which the text filter's terms test.
        let name: String
        /// Whether the node itself passes the scope.
        let passesScope: Bool
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

    // MARK: - Pass inputs

    /// What one pass filters with: the fuzzy query a Filter Mode runs, and the
    /// terms each object's own name is compared with.
    ///
    /// Without a Filter Mode every term — the tokens' and the typed text's —
    /// tests names. With one, the typed text's plain fragments stay a fuzzy
    /// query, matched against the name tree, ranked and highlighted as before;
    /// its fragments in token syntax (`!x`, `x*`, `*x`, a pattern) are compared
    /// as their tokens will be once the user presses Return, and so are the
    /// tokens.
    ///
    /// `isCaseSensitive` is the sidebar's Match Case, the polarity every search
    /// field shows; `FilterContext` states the opposite, and this is the one
    /// place the two meet.
    static func passInputs(
        for filter: NavigatorTextFilter,
        filterMode: FilterMode?,
        isCaseSensitive: Bool
    ) -> (context: FilterContext, nameMatcher: NavigatorTextFilter.Matcher) {
        let typedTerms = filter.typedTerms
        let fuzzyQueryTerms = filterMode == nil ? [] : typedTerms.filter { $0.comparison == .contains }
        let comparedTerms = filterMode == nil ? filter.allTerms : filter.terms + typedTerms.filter { $0.comparison != .contains }
        let context = FilterContext(
            query: fuzzyQueryTerms.map(\.value).joined(separator: " "),
            isCaseInsensitive: !isCaseSensitive,
            mode: filterMode
        )
        return (context, NavigatorTextFilter.Matcher(terms: comparedTerms, isCaseSensitive: isCaseSensitive))
    }

    // MARK: - Snapshot (main actor)

    /// `includesHaystacks` is off for a pass without a fuzzy query, which
    /// tests names only: right after a reload the haystack caches are cold,
    /// and building them is a full bottom-up name concatenation over the tree.
    @MainActor
    static func snapshot(
        of cells: [SidebarRuntimeObjectCellViewModel],
        scope: RuntimeObjectScope,
        includesHaystacks: Bool = true
    ) -> [SnapshotNode] {
        cells.map { cell in
            SnapshotNode(
                haystack: includesHaystacks ? cell.currentAndChildrenNames : "",
                name: cell.runtimeObject.displayName,
                passesScope: scope.isActive ? scope.passes(cell.runtimeObject) : true,
                children: snapshot(of: cell.unfilteredChildren, scope: scope, includesHaystacks: includesHaystacks)
            )
        }
    }

    // MARK: - Verdicts (any thread, cancellable)

    /// Computes the full verdict forest. Checks for cooperative
    /// cancellation between top-level nodes; a cancelled run returns
    /// `.empty`, which callers must discard (they already do via their
    /// generation guard).
    static func verdicts(
        for forest: [SnapshotNode],
        context: FilterContext,
        nameMatcher: NavigatorTextFilter.Matcher = .empty
    ) -> ForestVerdict {
        var topVerdicts: [VerdictNode] = []
        topVerdicts.reserveCapacity(forest.count)
        var topSubtreesPass: [Bool] = []
        topSubtreesPass.reserveCapacity(forest.count)
        for node in forest {
            guard !Task.isCancelled else { return .empty }
            let (verdict, subtreePasses) = verdictNode(for: node, context: context, nameMatcher: nameMatcher)
            topVerdicts.append(verdict)
            topSubtreesPass.append(subtreePasses)
        }

        let orderedFilteredTopIndices = stampMatches(
            of: forest,
            subtreesPass: topSubtreesPass,
            into: &topVerdicts,
            context: context
        )
        return ForestVerdict(
            orderedFilteredTopIndices: orderedFilteredTopIndices,
            topVerdicts: topVerdicts
        )
    }

    /// The node's verdict, and whether it or any descendant passes the scope
    /// and the name terms — what keeps a generic parent whose only
    /// specialized child the scope selects, or a type whose nested type the
    /// text names.
    private static func verdictNode(
        for node: SnapshotNode,
        context: FilterContext,
        nameMatcher: NavigatorTextFilter.Matcher
    ) -> (verdict: VerdictNode, subtreePasses: Bool) {
        var childVerdicts: [VerdictNode] = []
        childVerdicts.reserveCapacity(node.children.count)
        var childSubtreesPass: [Bool] = []
        childSubtreesPass.reserveCapacity(node.children.count)
        for child in node.children {
            let (childVerdict, childSubtreePasses) = verdictNode(for: child, context: context, nameMatcher: nameMatcher)
            childVerdicts.append(childVerdict)
            childSubtreesPass.append(childSubtreePasses)
        }
        let orderedFilteredChildIndices = stampMatches(
            of: node.children,
            subtreesPass: childSubtreesPass,
            into: &childVerdicts,
            context: context
        )
        let nodePasses = node.passesScope && nameMatcher.matches(node.name)
        let verdict = VerdictNode(
            result: nil,
            orderedFilteredChildIndices: orderedFilteredChildIndices,
            children: childVerdicts
        )
        return (verdict, nodePasses || childSubtreesPass.contains(true))
    }

    /// Drops the nodes whose subtree passes neither the scope nor the name
    /// terms, matches the survivors' haystacks against the typed text, stamps
    /// each match's highlight result onto the corresponding verdict, and
    /// returns the matched indices in display order — the semantics of the
    /// legacy per-level `FilterEngine.filter` call.
    private static func stampMatches(
        of nodes: [SnapshotNode],
        subtreesPass: [Bool],
        into verdicts: inout [VerdictNode],
        context: FilterContext
    ) -> [Int] {
        let keptIndices = nodes.indices.filter { subtreesPass[$0] }
        let matches = FilterEngine.match(context, haystacks: keptIndices.map { nodes[$0].haystack })
        var orderedFilteredIndices: [Int] = []
        orderedFilteredIndices.reserveCapacity(matches.count)
        for match in matches {
            let nodeIndex = keptIndices[match.haystackIndex]
            verdicts[nodeIndex].result = match.result
            orderedFilteredIndices.append(nodeIndex)
        }
        return orderedFilteredIndices
    }

    // MARK: - Identity fast path (main actor)

    /// Installs the "no filtering" outcome on every cell — the exact result
    /// `snapshot` → `verdicts` → `apply` produces for an empty query with an
    /// inactive scope and no name terms, minus the snapshot forest. The
    /// identity outcome needs no haystacks, so this never touches
    /// `currentAndChildrenNames` — whose per-cell cache is cold right after a
    /// reload, making the skipped snapshot a full bottom-up haystack build
    /// over the tree.
    @MainActor
    static func resetToUnfiltered(
        _ cells: [SidebarRuntimeObjectCellViewModel],
        context: FilterContext,
        scope: RuntimeObjectScope
    ) {
        for cell in cells {
            let unfilteredChildren = cell.unfilteredChildren
            resetToUnfiltered(unfilteredChildren, context: context, scope: scope)
            cell.applyFilterOutcome(
                context: context,
                scope: scope,
                nameMatcher: .empty,
                result: nil,
                filteredChildren: unfilteredChildren
            )
        }
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
        scope: RuntimeObjectScope,
        nameMatcher: NavigatorTextFilter.Matcher = .empty
    ) -> [SidebarRuntimeObjectCellViewModel]? {
        guard applyNodes(verdicts: forestVerdict.topVerdicts, to: cells, context: context, scope: scope, nameMatcher: nameMatcher) else {
            return nil
        }
        return forestVerdict.orderedFilteredTopIndices.map { cells[$0] }
    }

    @MainActor
    private static func applyNodes(
        verdicts: [VerdictNode],
        to cells: [SidebarRuntimeObjectCellViewModel],
        context: FilterContext,
        scope: RuntimeObjectScope,
        nameMatcher: NavigatorTextFilter.Matcher
    ) -> Bool {
        guard verdicts.count == cells.count else { return false }
        for (cell, verdict) in zip(cells, verdicts) {
            let unfilteredChildren = cell.unfilteredChildren
            guard applyNodes(verdicts: verdict.children, to: unfilteredChildren, context: context, scope: scope, nameMatcher: nameMatcher) else {
                return false
            }
            cell.applyFilterOutcome(
                context: context,
                scope: scope,
                nameMatcher: nameMatcher,
                result: verdict.result,
                filteredChildren: verdict.orderedFilteredChildIndices.map { unfilteredChildren[$0] }
            )
        }
        return true
    }
}

import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// Regression suite for the root sidebar's off-main filter pipeline.
///
/// History: before this change, every root-sidebar keystroke ran a
/// recursive `localizedCaseInsensitiveContains` cascade over the whole
/// image tree on the main thread (including building each node's
/// aggregate name on first use). The pipeline moves aggregate
/// construction and matching to the global executor; these tests pin the
/// legacy display semantics against an independent reference
/// implementation and exercise the full view-model path.
@Suite("SidebarRootFilterPipeline", .serialized)
@MainActor
struct SidebarRootFilterPipelineTests {
    private static let fixtureImagePaths = [
        "/System/Library/Frameworks/AppKit.framework/AppKit",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/PrivateFrameworks/NeedleKit.framework/NeedleKit",
        "/System/iOSSupport/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
        "/usr/lib/libNeedleHelper.dylib",
        "/usr/lib/swift/libswiftCore.dylib",
    ]

    // MARK: - Semantics parity against an independent reference

    @Test("pipeline output matches the legacy cascade semantics")
    func pipelineMatchesReferenceSemantics() throws {
        // "needle" hits leaf/framework names in two branches; "system"
        // hits a directory segment (matching-node-shows-subtree rule);
        // "framework" hits both segment and leaf names broadly;
        // "qqqqqq" hits nothing.
        for query in ["needle", "system", "framework", "swift", "qqqqqq"] {
            let rootImageNode = RuntimeImageNode.rootNode(for: Self.fixtureImagePaths, name: "Dyld Shared Cache")
            let cells = [SidebarRootCellViewModel(node: rootImageNode)]

            let snapshotForest = SidebarRootFilterPipeline.snapshot(of: cells)
            let forestVerdict = SidebarRootFilterPipeline.verdicts(for: snapshotForest, query: query)
            let filteredCells = try #require(
                SidebarRootFilterPipeline.apply(forestVerdict, to: cells)
            )

            let referenceForest = referenceFilteredForest(
                of: snapshotForest.map(referenceNode(from:)),
                query: query
            )
            #expect(
                displayedNameForest(of: filteredCells) == referenceForest,
                "query: '\(query)'"
            )
        }
    }

    @Test("empty-query reset restores the full tree")
    func emptyQueryResetRestoresFullTree() throws {
        let rootImageNode = RuntimeImageNode.rootNode(for: Self.fixtureImagePaths, name: "Dyld Shared Cache")
        let cells = [SidebarRootCellViewModel(node: rootImageNode)]
        let fullForest = displayedNameForest(of: cells)

        let snapshotForest = SidebarRootFilterPipeline.snapshot(of: cells)
        let forestVerdict = SidebarRootFilterPipeline.verdicts(for: snapshotForest, query: "needle")
        _ = try #require(SidebarRootFilterPipeline.apply(forestVerdict, to: cells))
        #expect(displayedNameForest(of: cells) != fullForest)

        SidebarRootFilterPipeline.resetToUnfiltered(cells)
        #expect(displayedNameForest(of: cells) == fullForest)
    }

    // MARK: - View model end-to-end

    @Test("view model end-to-end: coalesced search filters off-main and clear resets")
    func viewModelEndToEndSearch() async throws {
        let rootImageNode = RuntimeImageNode.rootNode(for: Self.fixtureImagePaths, name: "Dyld Shared Cache")
        let documentState = DocumentState()
        let mockRouter = MockRouter<SidebarRootRoute>()
        let viewModel = SidebarRootViewModel(
            documentState: documentState,
            router: mockRouter,
            nodesSource: .just([rootImageNode])
        )

        let nodesPopulated = try await pollUntil(timeout: .seconds(10)) {
            !viewModel.nodes.isEmpty
        }
        #expect(nodesPopulated, "nodesSource never populated the root cells")

        let searchStringRelay = PublishRelay<String>()
        let input = SidebarRootViewModel.Input(
            clickedNode: .never(),
            selectedNode: .never(),
            searchString: searchStringRelay.asSignal()
        )
        _ = viewModel.transform(input)

        searchStringRelay.accept("needle")
        let searchApplied = try await pollUntil(timeout: .seconds(10)) {
            viewModel.isFiltering && self.forestContainsNeedleBranchesOnly(viewModel.filteredNodes)
        }
        #expect(searchApplied, "search never converged on the needle-only tree")

        searchStringRelay.accept("")
        let cleared = try await pollUntil(timeout: .seconds(10)) {
            !viewModel.isFiltering && viewModel.filteredNodes.count == viewModel.nodes.count
        }
        #expect(cleared, "clearing the search never restored the full list")

        // The root cell must show its full child list again after reset.
        let rootCell = try #require(viewModel.nodes.first)
        #expect(rootCell.children.count == rootCell.unfilteredChildren.count)

        #expect(mockRouter.triggeredRoutes.isEmpty)
        withExtendedLifetime(mockRouter) {}
    }

    /// The "needle" query must keep exactly the two branches whose leaves
    /// carry the marker (NeedleKit.framework and libNeedleHelper.dylib)
    /// and prune everything else.
    private func forestContainsNeedleBranchesOnly(_ cells: [SidebarRootCellViewModel]) -> Bool {
        let leafNames = leafNodeNames(of: cells)
        return leafNames == Set(["NeedleKit", "libNeedleHelper.dylib"])
    }

    private func leafNodeNames(of cells: [SidebarRootCellViewModel]) -> Set<String> {
        var collected: Set<String> = []
        func visit(_ cell: SidebarRootCellViewModel) {
            if cell.children.isEmpty {
                collected.insert(cell.node.name)
            } else {
                cell.children.forEach(visit)
            }
        }
        cells.forEach(visit)
        return collected
    }

    // MARK: - Reference implementation (legacy cascade semantics)

    /// Value-tree mirror of a snapshot node, so the reference path shares
    /// the pipeline's input but nothing else.
    private struct ReferenceNode {
        let name: String
        let children: [ReferenceNode]
    }

    private func referenceNode(from snapshotNode: SidebarRootFilterPipeline.SnapshotNode) -> ReferenceNode {
        ReferenceNode(name: snapshotNode.name, children: snapshotNode.children.map(referenceNode(from:)))
    }

    private func referenceAggregate(of node: ReferenceNode) -> String {
        let childrenNames = node.children.map { referenceAggregate(of: $0) }.joined(separator: " ")
        return childrenNames.isEmpty ? node.name : "\(node.name) \(childrenNames)"
    }

    /// Independent re-statement of the legacy didSet cascade:
    /// - a top-level node survives iff its aggregate contains the query;
    /// - a node whose own name matches shows its entire subtree;
    /// - otherwise children are kept iff their aggregate matches,
    ///   recursively.
    private func referenceFilteredForest(of nodes: [ReferenceNode], query: String) -> [String] {
        nodes
            .filter { referenceAggregate(of: $0).localizedCaseInsensitiveContains(query) }
            .flatMap { referenceLines(for: $0, query: query, depth: 0) }
    }

    private func referenceLines(for node: ReferenceNode, query: String, depth: Int) -> [String] {
        let ownLine = String(repeating: "  ", count: depth) + node.name
        if node.name.localizedCaseInsensitiveContains(query) {
            return [ownLine] + node.children.flatMap { unfilteredLines(for: $0, depth: depth + 1) }
        }
        let survivingChildren = node.children.filter {
            referenceAggregate(of: $0).localizedCaseInsensitiveContains(query)
        }
        return [ownLine] + survivingChildren.flatMap { referenceLines(for: $0, query: query, depth: depth + 1) }
    }

    private func unfilteredLines(for node: ReferenceNode, depth: Int) -> [String] {
        [String(repeating: "  ", count: depth) + node.name]
            + node.children.flatMap { unfilteredLines(for: $0, depth: depth + 1) }
    }

    /// Indented name lines of the *displayed* (filtered) tree.
    private func displayedNameForest(of cells: [SidebarRootCellViewModel], depth: Int = 0) -> [String] {
        cells.flatMap { cell -> [String] in
            [String(repeating: "  ", count: depth) + cell.node.name]
                + displayedNameForest(of: cell.children, depth: depth + 1)
        }
    }

    private func pollUntil(
        timeout: Duration,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Pins the empty-query fast path of the sidebar filter pipeline.
///
/// `scheduleRefilter()` used to serve the empty-query / inactive-scope case
/// by building a full snapshot forest and running it through
/// `verdicts` → `apply` — a bottom-up haystack build over the whole tree
/// (cold caches right after a reload) whose output is, by definition, the
/// identity (PR #88 review, finding 4). The fast path now calls
/// `resetToUnfiltered`, which installs the identity outcome directly.
/// These tests prove the two produce the same observable cell state, so
/// the snapshot-free rewrite cannot drift from the legacy semantics.
@Suite("SidebarFilterFastPath")
@MainActor
struct SidebarFilterFastPathTests {
    private let emptyContext = FilterContext(query: "", isCaseInsensitive: true, mode: nil)
    private let inactiveScope = RuntimeObjectScope()

    @Test("resetToUnfiltered matches the snapshot pipeline's identity output")
    func resetMatchesSnapshotPipelineIdentity() throws {
        let pipelineTree = makeTree()
        let resetTree = makeTree()

        // Legacy fast path: full snapshot -> empty-context verdicts -> apply.
        let snapshotForest = SidebarRuntimeObjectFilterPipeline.snapshot(of: [pipelineTree], scope: inactiveScope)
        let verdictForest = SidebarRuntimeObjectFilterPipeline.verdicts(for: snapshotForest, context: emptyContext)
        let applied = SidebarRuntimeObjectFilterPipeline.apply(
            verdictForest, to: [pipelineTree], context: emptyContext, scope: inactiveScope
        )
        #expect(applied?.map(\.runtimeObject) == [pipelineTree.runtimeObject])

        // Snapshot-free fast path.
        SidebarRuntimeObjectFilterPipeline.resetToUnfiltered([resetTree], context: emptyContext, scope: inactiveScope)

        try expectIdenticalFilterState(pipelineTree, resetTree)
    }

    @Test("resetToUnfiltered clears a previously applied filter back to identity")
    func resetClearsPreviousFilter() throws {
        let tree = makeTree()
        let filteringContext = FilterContext(query: "Second", isCaseInsensitive: true, mode: nil)

        let snapshotForest = SidebarRuntimeObjectFilterPipeline.snapshot(of: [tree], scope: inactiveScope)
        let verdictForest = SidebarRuntimeObjectFilterPipeline.verdicts(for: snapshotForest, context: filteringContext)
        _ = SidebarRuntimeObjectFilterPipeline.apply(
            verdictForest, to: [tree], context: filteringContext, scope: inactiveScope
        )
        #expect(tree.children.count == 1, "the filtering pass must prune to the single matching child")
        #expect(tree.children.first?.runtimeObject.displayName == "Module.Root.Second")

        SidebarRuntimeObjectFilterPipeline.resetToUnfiltered([tree], context: emptyContext, scope: inactiveScope)

        try expectIdentityFilterState(tree)
    }

    // MARK: - Assertions

    /// Both trees must expose the same post-pass state on every node:
    /// stamped context, no highlight result, and an unpruned child list.
    private func expectIdenticalFilterState(
        _ expected: SidebarRuntimeObjectCellViewModel,
        _ actual: SidebarRuntimeObjectCellViewModel
    ) throws {
        #expect(actual.filterContext == expected.filterContext)
        #expect(actual.filterResult == nil && expected.filterResult == nil)
        #expect(actual.children.map(\.runtimeObject) == expected.children.map(\.runtimeObject))
        #expect(actual.children.count == actual.unfilteredChildren.count)
        for (expectedChild, actualChild) in zip(expected.children, actual.children) {
            try expectIdenticalFilterState(expectedChild, actualChild)
        }
    }

    private func expectIdentityFilterState(_ cell: SidebarRuntimeObjectCellViewModel) throws {
        #expect(cell.filterContext == emptyContext)
        #expect(cell.filterResult == nil)
        #expect(cell.children.map(\.runtimeObject) == cell.unfilteredChildren.map(\.runtimeObject))
        for child in cell.children {
            try expectIdentityFilterState(child)
        }
    }

    // MARK: - Fixtures

    private func makeTree() -> SidebarRuntimeObjectCellViewModel {
        let grandchild = object(name: "Root.Second.Leaf", displayName: "Module.Root.Second.Leaf")
        let root = object(
            name: "Root",
            displayName: "Module.Root",
            children: [
                object(name: "Root.First", displayName: "Module.Root.First"),
                object(name: "Root.Second", displayName: "Module.Root.Second", children: [grandchild]),
            ]
        )
        return SidebarRuntimeObjectCellViewModel(runtimeObject: root, forOpenQuickly: false)
    }

    private func object(
        name: String,
        displayName: String,
        children: [RuntimeObject] = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName,
            kind: .swift(.type(.struct)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            children: children,
            properties: []
        )
    }
}

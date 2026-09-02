import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Text filtering of the image tree lives in `SidebarRootFilterPipeline`
/// (covered by `SidebarRootFilterPipelineTests`); the cell only owns its
/// tree shape, its appearance, and the slot the pipeline installs results into.
@Suite("SidebarRootCellViewModel")
@MainActor
struct SidebarRootCellViewModelTests {
    private let root = SidebarRootCellViewModel(
        node: Fixtures.imageTree(
            rootName: "Root",
            imagePaths: [
                "/usr/lib/libobjc.A.dylib",
                "/System/Library/Frameworks/Foundation.framework/Foundation",
            ]
        )
    )

    @Test("children are sorted by name and leaves are the images")
    func childrenSortedAndLeavesDetected() {
        #expect(root.children.map(\.node.name) == ["System", "usr"])
        #expect(root.isLeaf == false)

        let libobjc = root.children[1].children[0].children[0]
        #expect(libobjc.node.name == "libobjc.A.dylib")
        #expect(libobjc.isLeaf)
    }

    @Test("the iterator walks the tree depth-first in sorted order")
    func iteratorWalksDepthFirst() {
        let names = IteratorSequence(root.makeIterator()).map(\.node.name)

        #expect(names == ["Root", "System", "Library", "Frameworks", "Foundation.framework", "Foundation", "usr", "lib", "libobjc.A.dylib"])
    }

    @Test("applyFilterOutcome swaps the visible children while the unfiltered list stays intact")
    func applyFilterOutcomeSwapsVisibleChildren() {
        let usr = root.children[1]

        root.applyFilterOutcome(filteredChildren: [usr])

        #expect(root.children.map(\.node.name) == ["usr"])
        #expect(root.unfilteredChildren.map(\.node.name) == ["System", "usr"])

        root.applyFilterOutcome(filteredChildren: root.unfilteredChildren)
        #expect(root.children.map(\.node.name) == ["System", "usr"])
    }

    @Test("appearance carries the node's name and an icon")
    func appearanceDerivedFromNode() {
        #expect(root.appearance.name.string == "Root")
        #expect(root.appearance.icon != nil)
    }
}

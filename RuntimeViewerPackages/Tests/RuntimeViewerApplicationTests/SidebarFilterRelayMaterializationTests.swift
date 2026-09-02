import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// Guards the saving from the proposal *`@RxObserved` 惰性创建 relay*: the
/// wrapper allocates its `BehaviorRelay` on the first `$property` access, so
/// the bulk paths that visit every row — the text filter, the scope filter,
/// type-select — must stay on `wrappedValue`. One stray `$appearance` in any
/// of them would materialize a relay plus an `NSRecursiveLock` per row and
/// silently undo the saving.
@Suite("SidebarFilterRelayMaterialization")
@MainActor
struct SidebarFilterRelayMaterializationTests {
    @Test("text and scope filtering over an object tree materialize no appearance relay")
    func objectTreeFilteringMaterializesNoRelay() throws {
        let cells = makeTreeRuntimeObjects(parentCount: 200, childrenPerParent: 3)
            .map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
        #expect(materializedRows(in: cells).isEmpty)

        let contexts = [
            FilterContext(query: "Needle", isCaseInsensitive: true, mode: nil),
            FilterContext(query: "Needle", isCaseInsensitive: false, mode: .fuzzySearch),
            FilterContext(query: "", isCaseInsensitive: true, mode: nil),
        ]
        for context in contexts {
            for scope in [RuntimeObjectScope(), RuntimeObjectScope(generic: .only)] {
                let snapshotForest = SidebarRuntimeObjectFilterPipeline.snapshot(of: cells, scope: scope)
                let verdictForest = SidebarRuntimeObjectFilterPipeline.verdicts(for: snapshotForest, context: context)
                _ = try #require(
                    SidebarRuntimeObjectFilterPipeline.apply(verdictForest, to: cells, context: context, scope: scope)
                )
            }
        }
        // What type-select does for every row AppKit visits.
        for cell in allRows(in: cells) {
            _ = cell.appearance.title.string
        }

        #expect(materializedRows(in: cells).isEmpty)
    }

    @Test("binding a cell view materializes only that row's relay")
    func bindingMaterializesOnlyTheBoundRow() {
        let cells = makeTreeRuntimeObjects(parentCount: 10, childrenPerParent: 2)
            .map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }

        // `appearanceDriver` is what `RuntimeObjectCellView.bind(to:)` subscribes.
        _ = cells[3].appearanceDriver

        #expect(materializedRows(in: cells) == [cells[3].runtimeObject.displayName])
    }

    @Test("image list filtering materializes no appearance relay")
    func imageListFilteringMaterializesNoRelay() throws {
        let imagePaths = (0 ..< 300).map { "/System/Library/Frameworks/Generated\($0).framework/Generated\($0)" }
        let rootCell = SidebarRootCellViewModel(node: Fixtures.imageTree(rootName: "Others", imagePaths: imagePaths))
        let cells = [rootCell]

        for query in ["Generated1", "Generated"] {
            let snapshotForest = SidebarRootFilterPipeline.snapshot(of: cells)
            let verdictForest = SidebarRootFilterPipeline.verdicts(for: snapshotForest, query: query)
            _ = try #require(SidebarRootFilterPipeline.apply(verdictForest, to: cells))
        }
        SidebarRootFilterPipeline.resetToUnfiltered(cells)
        // What type-select does for every row AppKit visits.
        for cell in allRootRows(in: cells) {
            _ = cell.appearance.name.string
        }

        let rows = allRootRows(in: cells)
        #expect(rows.filter { $0.node.isLeaf }.count == 300)
        #expect(rows.allSatisfy { !$0.hasMaterializedAppearanceRelay })
    }

    // MARK: - Helpers

    private func allRows(in cells: [SidebarRuntimeObjectCellViewModel]) -> [SidebarRuntimeObjectCellViewModel] {
        cells.flatMap { [$0] + allRows(in: $0.unfilteredChildren) }
    }

    private func materializedRows(in cells: [SidebarRuntimeObjectCellViewModel]) -> [String] {
        allRows(in: cells)
            .filter { $0.hasMaterializedAppearanceRelay }
            .map { $0.runtimeObject.displayName }
    }

    private func allRootRows(in cells: [SidebarRootCellViewModel]) -> [SidebarRootCellViewModel] {
        cells.flatMap { [$0] + allRootRows(in: $0.unfilteredChildren) }
    }

    private func makeTreeRuntimeObjects(parentCount: Int, childrenPerParent: Int) -> [RuntimeObject] {
        (0 ..< parentCount).map { parentIndex in
            let children = (0 ..< childrenPerParent).map { childIndex -> RuntimeObject in
                let marker = (parentIndex.isMultiple(of: 100) && childIndex == 0) ? "Needle" : ""
                return Fixtures.runtimeObject(name: "TestFramework.GeneratedParent\(parentIndex).\(marker)Child\(childIndex)")
            }
            return Fixtures.runtimeObject(
                name: "TestFramework.GeneratedParent\(parentIndex)",
                children: children,
                properties: parentIndex.isMultiple(of: 3) ? [.isGeneric] : []
            )
        }
    }
}

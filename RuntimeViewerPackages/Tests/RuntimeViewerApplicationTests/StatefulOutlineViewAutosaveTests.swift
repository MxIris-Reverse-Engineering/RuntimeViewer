import AppKit
import Foundation
import Testing
import RuntimeViewerUI

/// Regression suite for `StatefulOutlineView`'s coalesced expansion
/// autosave.
///
/// History: before this change, every `itemDidExpand` / `itemDidCollapse`
/// notification triggered a full row walk plus a `UserDefaults` write. An
/// option-click "expand all" posts one notification per expandable item,
/// so a burst over N rows cost O(N²) row visits and N defaults writes.
/// The persist is now scheduled once per burst and flushed on the next
/// main-queue turn (`expansionAutosavePersistCount` is the seam that pins
/// this).
@Suite("StatefulOutlineViewAutosave", .serialized)
@MainActor
struct StatefulOutlineViewAutosaveTests {
    @Test("an expand-all burst coalesces into a single persist walk")
    func expandAllBurstCoalescesIntoOneWalk() async throws {
        let parentCount = 60
        let dataSource = OutlineTreeDataSource(parentCount: parentCount)
        let outlineView = StatefulOutlineView()
        let column = NSTableColumn(identifier: .init("primary"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = dataSource

        let autosaveName = "StatefulOutlineViewAutosaveTests-\(UUID().uuidString)"
        let userDefaultsKey = "NSOutlineView Items \(autosaveName)"
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        outlineView.persistentObjectForExpansion = { item in
            (item as? OutlineTreeItem)?.identifier
        }
        outlineView.expansionAutosaveName = autosaveName
        outlineView.reloadData()

        outlineView.expandItem(nil, expandChildren: true)
        #expect(outlineView.numberOfRows == parentCount * 2)

        // The burst itself must not persist synchronously — the legacy
        // implementation had already walked the rows dozens of times by
        // this point.
        #expect(outlineView.expansionAutosavePersistCount == 0)

        let flushed = try await pollUntil(timeout: .seconds(5)) {
            outlineView.expansionAutosavePersistCount > 0
        }
        #expect(flushed, "coalesced persist never ran")

        // Give any stragglers a chance to run, then pin the coalescing.
        // Notification delivery through `OperationQueue.main` may
        // interleave one extra flush with the burst; the legacy behavior
        // was one walk per expanded item (60+), so ≤ 2 still pins the
        // regression hard.
        try await Task.sleep(for: .milliseconds(200))
        #expect(outlineView.expansionAutosavePersistCount <= 2)

        let persistedIdentifiers = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []
        #expect(Set(persistedIdentifiers) == Set(dataSource.parents.map(\.identifier)))
    }

    @Test("a collapse after the flush persists the removal")
    func collapsePersistsRemoval() async throws {
        let parentCount = 8
        let dataSource = OutlineTreeDataSource(parentCount: parentCount)
        let outlineView = StatefulOutlineView()
        let column = NSTableColumn(identifier: .init("primary"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = dataSource

        let autosaveName = "StatefulOutlineViewAutosaveTests-\(UUID().uuidString)"
        let userDefaultsKey = "NSOutlineView Items \(autosaveName)"
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        outlineView.persistentObjectForExpansion = { item in
            (item as? OutlineTreeItem)?.identifier
        }
        outlineView.expansionAutosaveName = autosaveName
        outlineView.reloadData()

        outlineView.expandItem(nil, expandChildren: true)
        let allPersisted = try await pollUntil(timeout: .seconds(5)) {
            let persisted = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []
            return Set(persisted) == Set(dataSource.parents.map(\.identifier))
        }
        #expect(allPersisted, "initial expand-all never persisted")

        let collapsedParent = dataSource.parents[0]
        outlineView.collapseItem(collapsedParent)
        let removalPersisted = try await pollUntil(timeout: .seconds(5)) {
            let persisted = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []
            return !persisted.isEmpty && !persisted.contains(collapsedParent.identifier)
        }
        #expect(removalPersisted, "collapse never persisted the removal")
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

// MARK: - Fixture data source

private final class OutlineTreeItem: NSObject {
    let identifier: String
    let children: [OutlineTreeItem]

    init(identifier: String, children: [OutlineTreeItem] = []) {
        self.identifier = identifier
        self.children = children
    }
}

/// Minimal expandable tree: `parentCount` parents with one leaf child
/// each, so `expandItem(nil, expandChildren: true)` posts one
/// `itemDidExpand` notification per parent.
private final class OutlineTreeDataSource: NSObject, NSOutlineViewDataSource {
    let parents: [OutlineTreeItem]

    init(parentCount: Int) {
        self.parents = (0 ..< parentCount).map { parentIndex in
            OutlineTreeItem(
                identifier: "parent-\(parentIndex)",
                children: [OutlineTreeItem(identifier: "child-\(parentIndex)")]
            )
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let treeItem = item as? OutlineTreeItem else { return parents.count }
        return treeItem.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let treeItem = item as? OutlineTreeItem else { return parents[index] }
        return treeItem.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let treeItem = item as? OutlineTreeItem else { return false }
        return !treeItem.children.isEmpty
    }
}

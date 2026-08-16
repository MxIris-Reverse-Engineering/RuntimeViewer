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

    // MARK: - Staleness guard
    //
    // Coalescing moved the persist walk one main-queue turn after the
    // expand that scheduled it. Expand / collapse notifications are
    // delivered synchronously — `NotificationCenter` runs the block inline
    // when the observer queue is the posting queue — so the schedule always
    // happens on the tree the user acted on, but the flush does not: a data
    // change landing in the coalescing window makes the walk describe a
    // different tree. The rebuilt tree comes back fully collapsed, so the
    // walk collected nothing and wrote an empty array over the user's saved
    // state. That loss is permanent: `restoreExpansionFromAutosave()` runs
    // once per document, driven by `nodesIndexed.first()`.

    @Test("a tree replacement between the expand and the flush must not wipe the persisted state")
    func treeReplacedByReloadDataBeforeFlushKeepsPersistedState() async throws {
        let parentCount = 8
        let dataSource = OutlineTreeDataSource(parentCount: parentCount)
        let outlineView = makeOutlineView(dataSource: dataSource)
        let autosaveName = "StatefulOutlineViewAutosaveTests-\(UUID().uuidString)"
        let userDefaultsKey = "NSOutlineView Items \(autosaveName)"
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        outlineView.persistentObjectForExpansion = { item in
            (item as? OutlineTreeItem)?.identifier
        }
        outlineView.expansionAutosaveName = autosaveName
        outlineView.reloadData()

        outlineView.expandItem(nil, expandChildren: true)
        let savedIdentifiers = Set(dataSource.parents.map(\.identifier))
        let persisted = try await pollUntil(timeout: .seconds(5)) {
            Set(UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []) == savedIdentifiers
        }
        #expect(persisted, "initial expand-all never persisted")

        let walksBeforeReplacement = outlineView.expansionAutosavePersistCount

        // One main-queue turn, three synchronous steps: the user collapses a
        // row (which schedules the coalesced flush inline), then a
        // `.fullReload` — broadcast on every image load — replaces the tree.
        outlineView.collapseItem(dataSource.parents[0])
        dataSource.replaceTree(parentCount: parentCount, generation: 1)
        outlineView.reloadData()

        try await Task.sleep(for: .milliseconds(300))

        let survivingIdentifiers = Set(UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? [])
        #expect(
            survivingIdentifiers == savedIdentifiers,
            "the stale flush overwrote the saved expansion state with \(survivingIdentifiers.sorted())"
        )
        #expect(
            outlineView.expansionAutosavePersistCount == walksBeforeReplacement,
            "the flush walked a tree the user never acted on"
        )
    }

    @Test("an incremental row replacement between the expand and the flush must not wipe the persisted state")
    func treeReplacedIncrementallyBeforeFlushKeepsPersistedState() async throws {
        let parentCount = 8
        let dataSource = OutlineTreeDataSource(parentCount: parentCount)
        let outlineView = makeOutlineView(dataSource: dataSource)
        let autosaveName = "StatefulOutlineViewAutosaveTests-\(UUID().uuidString)"
        let userDefaultsKey = "NSOutlineView Items \(autosaveName)"
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        outlineView.persistentObjectForExpansion = { item in
            (item as? OutlineTreeItem)?.identifier
        }
        outlineView.expansionAutosaveName = autosaveName
        outlineView.reloadData()

        outlineView.expandItem(nil, expandChildren: true)
        let savedIdentifiers = Set(dataSource.parents.map(\.identifier))
        let persisted = try await pollUntil(timeout: .seconds(5)) {
            Set(UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []) == savedIdentifiers
        }
        #expect(persisted, "initial expand-all never persisted")

        let walksBeforeReplacement = outlineView.expansionAutosavePersistCount

        // The path the app actually takes. With every row a new object the
        // changeset carries no `elementUpdated`, so RxAppKit's adapter stays
        // on the incremental branch (`setData` → `removeItems` →
        // `insertItems`) instead of falling back to `reloadData()`.
        outlineView.collapseItem(dataSource.parents[0])
        let replacedRowCount = dataSource.parents.count
        dataSource.replaceTree(parentCount: parentCount, generation: 1)
        outlineView.beginUpdates()
        outlineView.removeItems(at: IndexSet(0 ..< replacedRowCount), inParent: nil, withAnimation: [])
        outlineView.insertItems(at: IndexSet(0 ..< parentCount), inParent: nil, withAnimation: [])
        outlineView.endUpdates()

        try await Task.sleep(for: .milliseconds(300))

        let survivingIdentifiers = Set(UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? [])
        #expect(
            survivingIdentifiers == savedIdentifiers,
            "the stale flush overwrote the saved expansion state with \(survivingIdentifiers.sorted())"
        )
        #expect(
            outlineView.expansionAutosavePersistCount == walksBeforeReplacement,
            "the flush walked a tree the user never acted on"
        )
    }

    @Test("collapsing every row on an unchanged tree still persists the empty state")
    func collapsingEveryRowPersistsAnEmptyState() async throws {
        let parentCount = 8
        let dataSource = OutlineTreeDataSource(parentCount: parentCount)
        let outlineView = makeOutlineView(dataSource: dataSource)
        let autosaveName = "StatefulOutlineViewAutosaveTests-\(UUID().uuidString)"
        let userDefaultsKey = "NSOutlineView Items \(autosaveName)"
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        outlineView.persistentObjectForExpansion = { item in
            (item as? OutlineTreeItem)?.identifier
        }
        outlineView.expansionAutosaveName = autosaveName
        outlineView.reloadData()

        outlineView.expandItem(nil, expandChildren: true)
        let savedIdentifiers = Set(dataSource.parents.map(\.identifier))
        let persisted = try await pollUntil(timeout: .seconds(5)) {
            Set(UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []) == savedIdentifiers
        }
        #expect(persisted, "initial expand-all never persisted")

        // An empty result is legitimate when it describes the tree the user
        // acted on — the staleness guard must key on the data changing, not
        // on the walk coming back empty.
        for parent in dataSource.parents {
            outlineView.collapseItem(parent)
        }

        let emptied = try await pollUntil(timeout: .seconds(5)) {
            (UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] ?? []).isEmpty
        }
        #expect(emptied, "collapsing every row never persisted the empty state")
    }

    // MARK: - Helpers

    private func makeOutlineView(dataSource: OutlineTreeDataSource) -> StatefulOutlineView {
        let outlineView = StatefulOutlineView()
        let column = NSTableColumn(identifier: .init("primary"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = dataSource
        return outlineView
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
    private(set) var parents: [OutlineTreeItem]

    init(parentCount: Int, generation: Int = 0) {
        self.parents = Self.makeParents(parentCount: parentCount, generation: generation)
    }

    /// Replaces every item with a freshly allocated one, the way the root
    /// sidebar does: `SidebarRootViewModel` maps each `$nodes` emission
    /// through `SidebarRootCellViewModel.init`, and the empty
    /// `Differentiable` conformance resolves `differenceIdentifier` to
    /// `self` (NSObject pointer identity), so every row is a new item and
    /// the rebuilt tree comes back fully collapsed.
    func replaceTree(parentCount: Int, generation: Int) {
        parents = Self.makeParents(parentCount: parentCount, generation: generation)
    }

    private static func makeParents(parentCount: Int, generation: Int) -> [OutlineTreeItem] {
        (0 ..< parentCount).map { parentIndex in
            OutlineTreeItem(
                identifier: "generation\(generation)-parent-\(parentIndex)",
                children: [OutlineTreeItem(identifier: "generation\(generation)-child-\(parentIndex)")]
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

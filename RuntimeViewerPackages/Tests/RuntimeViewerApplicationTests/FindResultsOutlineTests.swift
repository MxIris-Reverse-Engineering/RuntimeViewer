import AppKit
import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
@testable import RuntimeViewerApplication

/// The Find page's results outline under updates, bound the way the page binds it: a diffing
/// adapter over the nodes, in a window outside every display.
///
/// History: every batch of a search, every widening search and every filter keystroke brings new
/// node instances, and nodes compared by pointer — AppKit took each update for rows it had never
/// seen, the types the user collapsed opened again and the selection landed on whatever row now
/// had the selected row's number (PR121.07).
@Suite("Find results outline", .serialized)
@MainActor
struct FindResultsOutlineTests {
    @Test("a later batch keeps the type the user collapsed collapsed and the hit the user selected selected")
    func laterBatchKeepsCollapseAndSelection() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.publish([FindResultFixtures.type("Alpha", hitCount: 2), FindResultFixtures.type("Beta", hitCount: 1)])
        fixture.outlineView.expandItem(nil, expandChildren: true)
        fixture.outlineView.collapseItem(try #require(fixture.typeNode(named: "Beta")))
        let selectedHit = try #require(fixture.typeNode(named: "Alpha")?.children.last)
        fixture.outlineView.selectRowIndexes(IndexSet(integer: fixture.outlineView.row(forItem: selectedHit)), byExtendingSelection: false)

        // The next batch: new instances of every row on screen, and one more type.
        fixture.publish([
            FindResultFixtures.type("Alpha", hitCount: 2),
            FindResultFixtures.type("Beta", hitCount: 1),
            FindResultFixtures.type("Gamma", hitCount: 1),
        ])

        let alpha = try #require(fixture.typeNode(named: "Alpha"))
        #expect(fixture.outlineView.isItemExpanded(alpha))
        #expect(!fixture.outlineView.isItemExpanded(try #require(fixture.typeNode(named: "Beta"))))
        let selectedItem = fixture.outlineView.item(atRow: fixture.outlineView.selectedRow) as? FindResultNode
        #expect(selectedItem?.identifier == alpha.children.last?.identifier)
    }

    /// A filter change that keeps part of a type reloads the outline, and AppKit keeps a reloaded
    /// selection by row number: with a row gone above it, the selection lands on the next hit.
    @Test("after a reload the selection is put back on the hit the user selected")
    func reloadPutsTheSelectionBack() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let object = FindResultFixtures.object(named: "Alpha")
        let first = FindResultFixtures.hit(in: "Alpha", lineNumber: 1, lineText: "- (void)first;")
        let second = FindResultFixtures.hit(in: "Alpha", lineNumber: 2, lineText: "- (void)second;")
        let third = FindResultFixtures.hit(in: "Alpha", lineNumber: 3, lineText: "- (void)third;")
        fixture.present([FindResultFixtures.type(object, hits: [first, second, third]), FindResultFixtures.type("Beta", hitCount: 1)], selectedIdentifiers: [])
        let selectedHit = try #require(fixture.typeNode(named: "Alpha")?.children.last)
        fixture.outlineView.selectRowIndexes(IndexSet(integer: fixture.outlineView.row(forItem: selectedHit)), byExtendingSelection: false)

        // The filter keeps two of the three hits — new rows, the same identifiers as before.
        let filtered = FindResultNode.object(object, matchCount: 2, children: [
            FindResultNode.textMatch(first, index: 0),
            FindResultNode.textMatch(third, index: 2),
        ])
        fixture.publish([filtered, FindResultFixtures.type("Beta", hitCount: 1)])
        let selectedByAppKit = fixture.outlineView.item(atRow: fixture.outlineView.selectedRow) as? FindResultNode
        #expect(selectedByAppKit?.identifier != selectedHit.identifier, "AppKit kept the selection on the same item by itself; this test no longer shows why the page puts it back")

        fixture.present([filtered, FindResultFixtures.type("Beta", hitCount: 1)], selectedIdentifiers: [selectedHit.identifier])

        let selectedItem = fixture.outlineView.item(atRow: fixture.outlineView.selectedRow) as? FindResultNode
        #expect(selectedItem?.identifier == selectedHit.identifier)
        #expect(fixture.outlineView.isItemExpanded(filtered))
    }

    /// The page tells its ViewModel which rows the user collapsed from the outline's collapse
    /// notifications; an update that takes an expanded row away must not count as one.
    @Test("an update that removes an expanded row reports no collapse")
    func removingAnExpandedRowReportsNoCollapse() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.present([FindResultFixtures.type("Alpha", hitCount: 1), FindResultFixtures.type("Beta", hitCount: 2)], selectedIdentifiers: [])
        var collapsedItems: [Any] = []
        let observer = NotificationCenter.default.addObserver(forName: NSOutlineView.itemDidCollapseNotification, object: fixture.outlineView, queue: nil) { notification in
            collapsedItems.append(notification.userInfo?["NSObject"] as Any)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Beta goes, by the diff's deletion; then Alpha changes, which the diff turns into a reload.
        fixture.present([FindResultFixtures.type("Alpha", hitCount: 1)], selectedIdentifiers: [])
        fixture.present([FindResultFixtures.type("Alpha", hitCount: 3)], selectedIdentifiers: [])

        #expect(collapsedItems.isEmpty)
    }

    @Test("only a single row the user chose activates; reloads and selections the list makes do not")
    func onlyTheUsersChoiceActivates() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        var activatedIdentifiers: [String] = []
        var selectionChangeIdentifiers: [String] = []
        let activationSubscription = fixture.outlineView.rx.userActivatedItem(FindResultNode.self)
            .subscribeOnNext { activation in activatedIdentifiers.append(activation.item.identifier) }
        // The page's old navigation source, for contrast: it reports what the list does too.
        let selectionChangeSubscription = fixture.outlineView.rx.modelSelected()
            .subscribeOnNext { (node: FindResultNode) in selectionChangeIdentifiers.append(node.identifier) }
        defer {
            activationSubscription.dispose()
            selectionChangeSubscription.dispose()
        }

        fixture.present([FindResultFixtures.type("Alpha", hitCount: 2)], selectedIdentifiers: [])
        // What a reload and the page's own selection restore do.
        fixture.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        fixture.present([FindResultFixtures.type("Alpha", hitCount: 1)], selectedIdentifiers: ["object-of-nothing"])
        #expect(activatedIdentifiers.isEmpty)
        #expect(!selectionChangeIdentifiers.isEmpty)

        // What AppKit asks the delegate when the user clicks one row, then ⌘-clicks a second.
        let delegate = try #require(fixture.outlineView.delegate)
        _ = delegate.outlineView?(fixture.outlineView, selectionIndexesForProposedSelection: IndexSet(integer: 0))
        _ = delegate.outlineView?(fixture.outlineView, selectionIndexesForProposedSelection: IndexSet([0, 1]))
        #expect(activatedIdentifiers == [try #require(fixture.typeNode(named: "Alpha")).identifier])
    }
}

// MARK: - Fixture

extension FindResultsOutlineTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let outlineView: StatefulOutlineView
        private(set) var displayedNodes: [FindResultNode] = []
        private let nodesRelay = PublishRelay<[FindResultNode]>()
        private let disposeBag = DisposeBag()

        init() {
            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.outlineView = outlineView
            outlineView.style = .sourceList
            outlineView.allowsMultipleSelection = true
            scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.orderFrontRegardless()
            // The Find page's binding: a diffing adapter over the nodes.
            outlineView.rx.nodes(source: nodesRelay, options: .diffable)({ (_: NSOutlineView, _: NSTableColumn?, _: FindResultNode) -> NSView? in
                NSTableCellView()
            }, nil)
            .disposed(by: disposeBag)
        }

        func publish(_ nodes: [FindResultNode]) {
            displayedNodes = nodes
            nodesRelay.accept(nodes)
            outlineView.layoutSubtreeIfNeeded()
        }

        /// What the page does with an update: the nodes to the data source, then the presentation
        /// the ViewModel would make of them with nothing collapsed.
        func present(_ nodes: [FindResultNode], selectedIdentifiers: Set<String>) {
            publish(nodes)
            FindResultsPresentation(
                nodes: nodes,
                nodesToExpand: FindResultsOutline.nodesToExpand(in: nodes, collapsedIdentifiers: [], isRelationshipTree: false),
                nodesToSelect: FindResultsOutline.nodes(in: nodes, identifiedBy: selectedIdentifiers)
            )
            .apply(to: outlineView)
            outlineView.layoutSubtreeIfNeeded()
        }

        func typeNode(named name: String) -> FindResultNode? {
            displayedNodes.first { node in
                if case .object(let object, _) = node.content { return object.name == name }
                return false
            }
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }
}

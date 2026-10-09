import AppKit
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
import Testing
@testable import RuntimeViewerApplication

/// The Report navigator's tree bound to a real outline the way its page binds it — a
/// `StatefulOutlineView` in the source list style, `rx.nodes(options: [])` — with the cell
/// ViewModels kept across rebuilds as `ReportViewModel` keeps them. A change below the first level
/// reaches the screen, and a reload leaves expansion and selection on their items (PR121.53).
///
/// `ReportNode` compared its whole subtree in `==` and only its children's identifiers in
/// `isContentEqual(to:)`. RxAppKit's reload adapter asks `isContentEqual` of the first level alone,
/// so a change further down never reloaded the outline; and `NSOutlineView` keeps a row open across
/// `reloadData()` only for an item `==` to the old one, so every row whose subtree changed came
/// back collapsed.
@Suite("ReportOutlineBinding", .serialized)
@MainActor
struct ReportOutlineBindingTests {
    @Test("a filter that drops images under a batch removes their rows")
    func changeBelowFirstLevelReachesTheOutline() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let batchIdentifier = RuntimeIndexingBatchID()
        fixture.publish(batches: [(batchIdentifier, ["/A", "/B", "/C"])])
        fixture.expandEveryRow()
        #expect(fixture.outlineView.numberOfRows == 5)

        fixture.publish(batches: [(batchIdentifier, ["/B"])])

        #expect(fixture.outlineView.numberOfRows == 3)
    }

    @Test("a reload keeps open the rows whose identity it kept")
    func reloadKeepsExpansion() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let runningBatch = RuntimeIndexingBatchID()
        fixture.publish(batches: [(runningBatch, ["/A", "/B"])])
        fixture.expandEveryRow()

        fixture.publish(batches: [(RuntimeIndexingBatchID(), ["/C"]), (runningBatch, ["/A", "/B"])])

        #expect(fixture.isExpanded(.category(.backgroundIndexing)))
        #expect(fixture.isExpanded(.indexingBatch(runningBatch)))
    }

    @Test("a row inserted above the selected one leaves the selection on its item")
    func reloadKeepsSelectionOnItsItem() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let selectedBatch = RuntimeIndexingBatchID()
        fixture.publish(batches: [(selectedBatch, ["/A"])])
        fixture.expandEveryRow()
        let selectedRow = try #require(fixture.row(of: .indexingBatch(selectedBatch)))
        fixture.outlineView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)

        fixture.publish(batches: [(RuntimeIndexingBatchID(), ["/C"]), (selectedBatch, ["/A"])])

        let selectedNode = fixture.outlineView.item(atRow: fixture.outlineView.selectedRow) as? ReportNode
        #expect(selectedNode?.identifier == .indexingBatch(selectedBatch))
    }
}

extension ReportOutlineBindingTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let outlineView: StatefulOutlineView

        private let nodesRelay = BehaviorRelay<[ReportNode]>(value: [])
        private var cellViewModelsByIdentifier: [ReportNodeIdentifier: ReportCellViewModel] = [:]
        private let disposeBag = DisposeBag()

        init() {
            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.outlineView = outlineView
            outlineView.style = .sourceList
            outlineView.rowHeight = 24
            // What the Report page sets.
            outlineView.preservesSelectedItemAcrossReloads = true
            scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.orderFrontRegardless()

            outlineView.rx.nodes(source: nodesRelay.asObservable(), options: [])({ (_: NSOutlineView, _: NSTableColumn?, _: ReportNode) -> NSView? in
                NSTableCellView()
            }, nil)
            .disposed(by: disposeBag)
        }

        func tearDown() {
            window.orderOut(nil)
        }

        /// Publishes a Background Indexing category holding `batches`, newest first, one row per
        /// image path under each — the shape `ReportViewModel` builds.
        func publish(batches: [(identifier: RuntimeIndexingBatchID, imagePaths: [String])]) {
            let batchNodes = batches.map { batch in
                node(.indexingBatch(batch.identifier), children: batch.imagePaths.map { imagePath in
                    node(.indexingItem(batchID: batch.identifier, imagePath: imagePath))
                })
            }
            nodesRelay.accept([node(.category(.backgroundIndexing), children: batchNodes)])
            outlineView.layoutSubtreeIfNeeded()
        }

        func expandEveryRow() {
            outlineView.expandItem(nil, expandChildren: true)
        }

        func row(of identifier: ReportNodeIdentifier) -> Int? {
            (0 ..< outlineView.numberOfRows).first { row in
                (outlineView.item(atRow: row) as? ReportNode)?.identifier == identifier
            }
        }

        func isExpanded(_ identifier: ReportNodeIdentifier) -> Bool {
            guard let row = row(of: identifier) else { return false }
            return outlineView.isItemExpanded(outlineView.item(atRow: row))
        }

        private func node(_ identifier: ReportNodeIdentifier, children: [ReportNode] = []) -> ReportNode {
            let cellViewModel = cellViewModelsByIdentifier[identifier] ?? ReportCellViewModel(identifier: identifier)
            cellViewModelsByIdentifier[identifier] = cellViewModel
            return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
        }
    }
}

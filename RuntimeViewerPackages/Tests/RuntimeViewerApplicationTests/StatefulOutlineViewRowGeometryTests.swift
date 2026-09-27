import AppKit
import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerUI

/// Regression suite for rows of the runtime-object sidebar drawn over each other.
///
/// History: in a source list outline with group rows, AppKit adds spacing above every group row
/// but the first, so rows differ in height and the table places the rows it has not measured at an
/// estimated position. `-[NSOutlineView setDelegate:]` turns that estimation on. After a reload or
/// an expansion far down the list, the next layout left part of the visible rows at the old
/// estimate, and the following scroll drew rows over them: the sidebar showed two names on one row
/// after filtering, or after a jump to an object far down the list. `StatefulOutlineView` now turns
/// the estimation off on every change of delegate. Background:
/// `Documentations/ResolvedIssues/2026-09-27-sidebar-rows-drawn-over-each-other.md`.
///
/// The fixture is shaped like the sidebar: a `StatefulOutlineView` in the source list style, bound
/// through RxAppKit's sections adapter — whose delegate proxy re-assigns the delegate when a
/// forward delegate is installed, as the sidebar's view controller does — to kind sections with
/// nested types. The nested types are load-bearing: with no expandable row, AppKit places every row
/// correctly even while estimating.
@Suite("StatefulOutlineViewRowGeometry", .serialized)
@MainActor
struct StatefulOutlineViewRowGeometryTests {
    @Test("a reload far down the list draws no row over another")
    func reloadFarDownDrawsNoRowOverAnother() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        var overlaps: [String] = []
        for originY in stride(from: CGFloat(17000), through: 27000, by: 500) {
            fixture.scroll(toOriginY: originY)
            fixture.republishSections()
            fixture.scroll(toOriginY: originY + 100)
            overlaps += fixture.overlappingRowViewPairs().map { pair in "reload at y \(Int(originY)): \(pair)" }
        }

        #expect(overlaps.isEmpty, "\(overlaps.count) pairs of rows drawn over each other: \(overlaps.prefix(3))")
    }

    /// Every position gets a list of its own. Measured while estimating: an expansion goes wrong
    /// only on a list that has just jumped far down, and in a sweep over one list the earlier
    /// steps left every later position clean — a sweep passed whatever AppKit did. The positions
    /// are the ones where a fresh list went wrong, all within the last 2,200 pt of the list; at
    /// y 23000 to 26000 it did not.
    @Test(
        "expanding a nested type right after a jump far down the list draws no row over another",
        arguments: [26500, 27000, 27500, 28000] as [CGFloat]
    )
    func expansionAfterJumpFarDownDrawsNoRowOverAnother(originY: CGFloat) throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.scroll(toOriginY: originY)
        let node = try #require(fixture.visibleNodeWithNestedTypes())
        let rowCountBeforeExpanding = fixture.outlineView.numberOfRows
        fixture.outlineView.expandItem(node)
        fixture.layOutAndDisplay()
        try #require(fixture.outlineView.numberOfRows == rowCountBeforeExpanding + node.children.count)
        fixture.scroll(toOriginY: originY - 100)

        let overlaps = fixture.overlappingRowViewPairs()
        #expect(overlaps.isEmpty, "\(overlaps.count) pairs of rows drawn over each other after expanding \(node.title): \(overlaps.prefix(3))")
    }
}

// MARK: - Fixture

extension StatefulOutlineViewRowGeometryTests {
    /// Nine kind sections over 1,183 rows, the proportions of an image's list, bound the way the
    /// sidebar binds them, in a window outside every display.
    @MainActor
    final class Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let outlineView: StatefulOutlineView
        let sections: [Section]

        private let sectionsRelay = BehaviorRelay<[Section]>(value: [])
        private let forwardDelegate = ForwardDelegate()
        private let disposeBag = DisposeBag()

        init() {
            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.scrollView = scrollView
            self.outlineView = outlineView
            outlineView.style = .sourceList
            outlineView.rowHeight = 24
            scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 680)

            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 680),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.orderFrontRegardless()

            sections = Self.makeSections()

            let sectionHeaderProvider: Reactive<NSOutlineView>.OutlineSectionHeaderViewProvider<Section> = { outlineView, _, section in
                let cellView = outlineView.makeView(withIdentifier: TitleCellView.reuseIdentifier, owner: nil) as? TitleCellView ?? TitleCellView()
                cellView.titleLabel.stringValue = section.title
                return cellView
            }
            let cellProvider: Reactive<NSOutlineView>.OutlineCellViewProvider<Node> = { outlineView, _, node in
                let cellView = outlineView.makeView(withIdentifier: TitleCellView.reuseIdentifier, owner: nil) as? TitleCellView ?? TitleCellView()
                cellView.titleLabel.stringValue = node.title
                return cellView
            }
            let sectionsSource = sectionsRelay.asObservable().map { sections in
                sections.map { ArraySection(model: $0, elements: $0.nodes) }
            }
            outlineView.rx.sections(source: sectionsSource)(sectionHeaderProvider, cellProvider, nil).disposed(by: disposeBag)
            // What the sidebar's view controller does after binding; the proxy re-assigns the
            // outline's delegate to pick up the new forward delegate.
            outlineView.rx.setDelegate(forwardDelegate).disposed(by: disposeBag)

            sectionsRelay.accept(sections)
            scrollView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        /// The same sections again, which the sections adapter answers with `reloadData()` — what
        /// every filter keystroke and every full reload of the sidebar comes to.
        func republishSections() {
            sectionsRelay.accept(sections)
            layOutAndDisplay()
        }

        func scroll(toOriginY originY: CGFloat) {
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: 0, y: originY))
            scrollView.reflectScrolledClipView(clipView)
            layOutAndDisplay()
        }

        /// What the window does at the end of a run loop turn.
        func layOutAndDisplay() {
            outlineView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        /// The first node with nested types on screen, skipping the top five rows so that rows
        /// above it are on screen when it expands.
        func visibleNodeWithNestedTypes() -> Node? {
            let visibleRows = outlineView.rows(in: outlineView.visibleRect)
            return (visibleRows.location + 5 ..< visibleRows.location + visibleRows.length).lazy
                .compactMap { row in self.outlineView.item(atRow: row) as? Node }
                .first { node in !node.children.isEmpty }
        }

        /// The titles of every two displayed row views whose frames overlap.
        func overlappingRowViewPairs() -> [String] {
            let rowViews = outlineView.subviews
                .compactMap { $0 as? NSTableRowView }
                .filter { rowView in !rowView.isHidden && rowView.alphaValue > 0.01 && !rowView.isFloating }
            var pairs: [String] = []
            for firstIndex in rowViews.indices {
                for secondIndex in rowViews.indices where secondIndex > firstIndex {
                    let overlap = rowViews[firstIndex].frame.intersection(rowViews[secondIndex].frame)
                    if overlap.height > 1, overlap.width > 1 {
                        pairs.append("\(title(of: rowViews[firstIndex])) / \(title(of: rowViews[secondIndex]))")
                    }
                }
            }
            return pairs
        }

        private func title(of rowView: NSTableRowView) -> String {
            let cellView = rowView.subviews.lazy.compactMap { $0 as? TitleCellView }.first
            return cellView?.titleLabel.stringValue ?? "<no cell>"
        }

        /// Section sizes follow AppKit's image: two large Objective-C sections, then seven Swift
        /// ones in which every tenth type has four nested types.
        private static func makeSections() -> [Section] {
            let sectionSizes = [700, 250, 45, 60, 25, 70, 3, 12, 18]
            return sectionSizes.enumerated().map { sectionIndex, nodeCount in
                Section(
                    index: sectionIndex,
                    nodes: (0 ..< nodeCount).map { nodeIndex in
                        let hasNestedTypes = sectionIndex >= 2 && nodeIndex % 10 == 0
                        let nestedTypes = hasNestedTypes
                            ? (0 ..< 4).map { nestedIndex in Node(title: "Nested \(sectionIndex).\(nodeIndex).\(nestedIndex)") }
                            : []
                        return Node(title: "Type \(sectionIndex).\(nodeIndex)", children: nestedTypes)
                    }
                )
            }
        }
    }

    /// A kind section: a struct compared by its index alone, like `SidebarRuntimeObjectSection`.
    struct Section: Hashable, Differentiable {
        let index: Int
        let nodes: [Node]

        var title: String { "Section \(index)" }

        static func == (leftSection: Section, rightSection: Section) -> Bool {
            leftSection.index == rightSection.index
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(index)
        }

        var differenceIdentifier: Int { index }

        func isContentEqual(to source: Section) -> Bool { index == source.index }
    }

    /// A runtime object's row: a reference type the outline keys on by identity.
    final class Node: NSObject, OutlineNodeType, Differentiable {
        let title: String
        let children: [Node]

        init(title: String, children: [Node] = []) {
            self.title = title
            self.children = children
        }

        var differenceIdentifier: ObjectIdentifier { ObjectIdentifier(self) }

        func isContentEqual(to source: Node) -> Bool { self === source }
    }

    final class TitleCellView: NSTableCellView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("TitleCellView")

        let titleLabel = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            identifier = Self.reuseIdentifier
            addSubview(titleLabel)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    /// Stands in for the sidebar view controller, which the delegate proxy forwards to.
    final class ForwardDelegate: NSObject, NSOutlineViewDelegate {}
}

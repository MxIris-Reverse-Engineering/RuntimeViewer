import AppKit
import Testing
import RuntimeViewerUI

/// `StatefulOutlineView.selectRowBringingIntoView(_:)` — Reveal in Sidebar Navigator and the
/// sidebar following the selection — brings a row out from under everything pinned over the
/// list: the bars the list runs under (`NavigatorScrollViewLayout`) and the floating section
/// header of the row's section.
///
/// The fixture is a sidebar page reduced to what the scrolling reads: a sectioned outline whose
/// group rows float, under a top bar and over a bottom bar laid out by the real layout, in a
/// window outside every display.
@Suite("StatefulOutlineView bringing a row into view", .serialized)
@MainActor
struct StatefulOutlineViewRevealTests {
    @Test(
        "a row under the pinned section header or the top bar is brought out from under them",
        arguments: [4, -10] as [CGFloat]
    )
    func rowUnderThePinnedHeaderIsBroughtOut(distanceBelowTheTopBar: CGFloat) throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let row = fixture.row(ofItem: 20, inSection: 0)
        fixture.scroll(row: row, toDistanceBelowTheTopBar: distanceBelowTheTopBar)
        #expect(NSLocationInRange(row, fixture.outlineView.rows(in: fixture.outlineView.visibleRect)), "the row should start inside the visible rect")

        fixture.outlineView.selectRowBringingIntoView(row)
        fixture.layoutAndDisplay()

        #expect(fixture.outlineView.selectedRow == row)
        #expect(fixture.isUncovered(row: row), "the row stayed under the pinned header or the bar: \(fixture.coverage(of: row))")
    }

    @Test("a row under the bottom bar is brought out from under it")
    func rowUnderTheBottomBarIsBroughtOut() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let row = fixture.row(ofItem: 20, inSection: 0)
        let rowRect = fixture.outlineView.rect(ofRow: row)
        let clipView = fixture.scrollView.contentView
        // The row's bottom four points below the top of the bottom bar.
        fixture.scroll(toY: rowRect.maxY - 4 - (clipView.bounds.height - clipView.contentInsets.bottom))

        fixture.outlineView.selectRowBringingIntoView(row)
        fixture.layoutAndDisplay()

        #expect(fixture.isUncovered(row: row), "the row stayed under the bottom bar: \(fixture.coverage(of: row))")
    }

    @Test("the first object of the list is revealed below its section header, with the list back at its top")
    func firstRowIsRevealedBelowItsHeader() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let row = fixture.row(ofItem: 0, inSection: 0)
        fixture.scroll(toY: fixture.outlineView.rect(ofRow: fixture.row(ofItem: 30, inSection: 1)).minY)

        fixture.outlineView.selectRowBringingIntoView(row)
        fixture.layoutAndDisplay()

        #expect(fixture.isUncovered(row: row), "the row stayed under the pinned header or the bar: \(fixture.coverage(of: row))")
    }

    @Test("a row nothing covers is selected where it is")
    func uncoveredRowIsNotScrolled() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let row = fixture.row(ofItem: 20, inSection: 0)
        fixture.scroll(row: row, toDistanceBelowTheTopBar: 200)
        let boundsBefore = fixture.scrollView.contentView.bounds

        fixture.outlineView.selectRowBringingIntoView(row)
        fixture.layoutAndDisplay()

        #expect(fixture.outlineView.selectedRow == row)
        #expect(fixture.scrollView.contentView.bounds == boundsBefore)
    }
}

// MARK: - Fixture

extension StatefulOutlineViewRevealTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let containerView = NSView()
        let scrollView = NSScrollView()
        let outlineView = StatefulOutlineView()
        let topBarView = NSView()
        let bottomBarView = NSView()
        private let source = SectionedSource(sectionCount: 2, itemCountPerSection: 40)
        private var layout: NavigatorScrollViewLayout!

        init() {
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = containerView

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Column"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.headerView = nil
            outlineView.rowHeight = SectionedSource.rowHeight
            outlineView.floatsGroupRows = true
            outlineView.dataSource = source
            outlineView.delegate = source
            scrollView.documentView = outlineView
            scrollView.hasVerticalScroller = true

            containerView.hierarchy {
                scrollView
                topBarView
                bottomBarView
            }
            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            // The tab switcher's bar over the top of the list and the filter bar over its bottom.
            topBarView.snp.makeConstraints { make in
                make.top.equalTo(containerView.safeAreaLayoutGuide)
                make.leading.trailing.equalToSuperview()
                make.height.equalTo(52)
            }
            bottomBarView.snp.makeConstraints { make in
                make.leading.trailing.bottom.equalToSuperview()
                make.height.equalTo(44)
            }
            layout = NavigatorScrollViewLayout(scrollView: scrollView, topOverlayViews: [topBarView], bottomOverlayViews: [bottomBarView])

            window.orderFrontRegardless()
            layoutAndDisplay()
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
            layoutAndDisplay()
        }

        func row(ofItem itemIndex: Int, inSection sectionIndex: Int) -> Int {
            outlineView.row(forItem: source.sections[sectionIndex].items[itemIndex])
        }

        /// Scrolls so that the row's top is the given distance below the bottom edge of the top bar's
        /// inset; negative puts it under the bar.
        func scroll(row: Int, toDistanceBelowTheTopBar distance: CGFloat) {
            let clipView = scrollView.contentView
            scroll(toY: outlineView.rect(ofRow: row).minY - distance - clipView.contentInsets.top)
        }

        func scroll(toY y: CGFloat) {
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clipView)
            layoutAndDisplay()
        }

        /// Whether the row lies wholly in the part of the list no bar covers, below the header its
        /// section pins to the top while the section is scrolled under it.
        func isUncovered(row: Int) -> Bool {
            let coverage = coverage(of: row)
            return coverage.rowRect.minY >= coverage.uncoveredMinY && coverage.rowRect.maxY <= coverage.uncoveredMaxY
        }

        func coverage(of row: Int) -> (rowRect: NSRect, uncoveredMinY: CGFloat, uncoveredMaxY: CGFloat) {
            let clipView = scrollView.contentView
            let headerHeight = outlineView.parent(forItem: outlineView.item(atRow: row))
                .map { outlineView.rect(ofRow: outlineView.row(forItem: $0)).height } ?? 0
            return (
                outlineView.rect(ofRow: row),
                clipView.bounds.minY + clipView.contentInsets.top + headerHeight,
                clipView.bounds.maxY - clipView.contentInsets.bottom
            )
        }

        func layoutAndDisplay() {
            containerView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }

    /// Sections whose header is a group row, the shape of the sidebar's kind sections.
    @MainActor
    private final class SectionedSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let rowHeight: CGFloat = 24

        final class Section: NSObject {
            let title: String
            let items: [Item]

            init(title: String, items: [Item]) {
                self.title = title
                self.items = items
            }
        }

        final class Item: NSObject {
            let title: String

            init(title: String) {
                self.title = title
            }
        }

        let sections: [Section]

        init(sectionCount: Int, itemCountPerSection: Int) {
            sections = (0..<sectionCount).map { sectionIndex in
                Section(title: "Section \(sectionIndex)", items: (0..<itemCountPerSection).map { Item(title: "Item \(sectionIndex).\($0)") })
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item else { return sections.count }
            return (item as? Section)?.items.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let section = item as? Section else { return sections[index] }
            return section.items[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is Section
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            item is Section
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            NSTextField(labelWithString: (item as? Section)?.title ?? (item as? Item)?.title ?? "")
        }
    }
}

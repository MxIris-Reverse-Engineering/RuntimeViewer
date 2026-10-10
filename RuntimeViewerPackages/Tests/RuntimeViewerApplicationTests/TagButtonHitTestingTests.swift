import AppKit
import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerUI

/// Where a click on a list row's tag goes, asserted at the window's hit-test. Built with the macOS
/// 27 SDK, a system control receives a click only when the hit-test lands on it, and a delivered
/// click would depend on the SDK the test host links and on the window being key; the hit-test
/// does not.
///
/// The row is shaped like the sidebar's: a `StatefulOutlineView` in the source list style, bound
/// through RxAppKit, whose cell holds a title that takes the slack and a `TagButton` after it.
/// `TagButton` refuses the first responder, which the table view could take as a reason to keep
/// the click for itself; the first test is what says it does not.
@Suite("TagButtonHitTesting", .serialized)
@MainActor
struct TagButtonHitTestingTests {
    @Test("a click on a clickable tag in a list row reaches the tag")
    func clickableTagReceivesTheClick() throws {
        let fixture = Fixture(isTagClickable: true)
        defer { fixture.tearDown() }

        let tagButton = try #require(fixture.tagButton(inRow: 0))
        try #require(!tagButton.frame.isEmpty)
        let hitView = fixture.hitView(atCenterOf: tagButton)
        #expect(hitView.map { $0 === tagButton || $0.isDescendant(of: tagButton) } == true, "the click went to \(hitView.map { String(describing: type(of: $0)) } ?? "nothing")")
    }

    @Test("a click on a tag that only shows reaches the row instead")
    func displayOnlyTagLeavesTheClickToTheRow() throws {
        let fixture = Fixture(isTagClickable: false)
        defer { fixture.tearDown() }

        let tagButton = try #require(fixture.tagButton(inRow: 0))
        try #require(!tagButton.frame.isEmpty)
        let hitView = try #require(fixture.hitView(atCenterOf: tagButton))
        #expect(hitView !== tagButton && !hitView.isDescendant(of: tagButton), "the click went to the tag")
        #expect(hitView.isDescendant(of: fixture.outlineView), "the click went to \(String(describing: type(of: hitView))), outside the list")
    }
}

// MARK: - Fixture

extension TagButtonHitTestingTests {
    /// One row in a window outside every display.
    @MainActor
    final class Fixture {
        let window: NSWindow
        let outlineView: StatefulOutlineView

        private let nodesRelay = BehaviorRelay<[Node]>(value: [])
        private let disposeBag = DisposeBag()

        init(isTagClickable: Bool) {
            let (scrollView, outlineView): (NSScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            self.outlineView = outlineView
            outlineView.style = .sourceList
            outlineView.rowHeight = 24
            scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 200)

            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 260, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.orderFrontRegardless()

            let cellProvider: Reactive<NSOutlineView>.OutlineCellViewProvider<Node> = { outlineView, _, node in
                let cellView = outlineView.box.makeView(ofClass: TaggedCellView.self)
                cellView.configure(title: node.title, isTagClickable: node.isTagClickable)
                return cellView
            }
            outlineView.rx.nodes(source: nodesRelay.asObservable())(cellProvider).disposed(by: disposeBag)

            nodesRelay.accept([Node(title: "SwiftUI.EnabledKey", isTagClickable: isTagClickable)])
            scrollView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        func tagButton(inRow row: Int) -> TagButton? {
            (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TaggedCellView)?.tagButton
        }

        /// The view the window would deliver a click at the center of `view` to.
        func hitView(atCenterOf view: NSView) -> NSView? {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return window.contentView?.superview?.hitTest(point)
        }
    }

    final class Node: NSObject, OutlineNodeType, Differentiable {
        let title: String
        let isTagClickable: Bool
        let children: [Node] = []

        init(title: String, isTagClickable: Bool) {
            self.title = title
            self.isTagClickable = isTagClickable
        }

        var differenceIdentifier: ObjectIdentifier { ObjectIdentifier(self) }

        func isContentEqual(to source: Node) -> Bool { self === source }
    }

    /// The sidebar cell's layout: a title that takes the slack and truncates first, then a tag.
    final class TaggedCellView: TableCellView {
        let titleLabel = Label()

        let tagButton = TagButton()

        override func setup() {
            super.setup()
            let stackView = HStackView(spacing: 6) {
                titleLabel
                    .box
                    .contentHugging(h: .defaultLow)
                    .box
                    .contentCompressionResistance(h: .defaultLow)
                tagButton
            }
            hierarchy {
                stackView
            }
            stackView.snp.makeConstraints { make in
                make.top.bottom.equalToSuperview()
                make.leading.trailing.equalToSuperview().inset(4)
            }
            titleLabel.maximumNumberOfLines = 1
        }

        func configure(title: String, isTagClickable: Bool) {
            titleLabel.stringValue = title
            tagButton.title = "Private"
            tagButton.isClickable = isTagClickable
        }
    }
}

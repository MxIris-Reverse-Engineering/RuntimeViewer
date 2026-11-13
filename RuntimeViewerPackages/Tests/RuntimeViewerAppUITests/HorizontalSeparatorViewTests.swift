import AppKit
import Testing
import RuntimeViewerUI

/// Regression suite for the sidebar divider that could not be dragged after launch: a 1-point separator box laid across
/// the sidebar's first page held the whole sidebar at its minimum width.
///
/// The fixture is a split view with a sidebar and a content pane, laid out in a window outside every display, and a page
/// in the sidebar with a line across it — pinned to both edges and 1 point tall, as the navigator pages lay out the line
/// above their filter bar. The page goes into the sidebar 0 points wide, and the window lays it out once like that before
/// it gets the sidebar's width. That is what launch does to the sidebar's first page: the window's first constraint pass
/// runs from AppKitPlus's navigation bar while the window restores, before the split view has given the sidebar any
/// width, and a separator box sized then takes itself for a vertical line, with an intrinsic width of 1 at a hugging
/// priority of 750 that nothing invalidates afterwards.
///
/// The divider is moved with `setPosition(_:ofDividerAt:)`, the call a drag ends in. Background:
/// `Documentations/ResolvedIssues/2026-10-20-sidebar-divider-locked-by-a-separator.md`.
@Suite("Horizontal separator", .serialized)
@MainActor
struct HorizontalSeparatorViewTests {
    @Test("a horizontal separator first sized while its pane has no width leaves the divider free")
    func horizontalSeparatorLeavesDividerFree() {
        let fixture = Fixture(separator: HorizontalSeparatorView())
        defer { fixture.tearDown() }

        let sidebarWidth = fixture.sidebarWidth
        #expect(sidebarWidth > 0)
        fixture.moveDivider(toSidebarWidth: sidebarWidth + Fixture.dividerOffset)

        #expect(
            fixture.sidebarWidth == sidebarWidth + Fixture.dividerOffset,
            "The panes are \(fixture.splitView.arrangedSubviews.map(\.frame.width)) wide; the sidebar was \(sidebarWidth)."
        )
    }

    /// The precondition the test above stands on: the fixture reproduces the lock. A plain separator box set up the
    /// same way keeps the divider where it is, and lets it go once its intrinsic size is invalidated — so the divider
    /// can move in this fixture, and the box is what holds it. Should AppKit stop taking such a box for a vertical line,
    /// this fails, and the test above no longer proves anything.
    @Test("a plain separator box first sized while its pane has no width holds the divider")
    func plainSeparatorBoxHoldsDivider() {
        let separator = NSBox()
        separator.boxType = .separator
        let fixture = Fixture(separator: separator)
        defer { fixture.tearDown() }

        let sidebarWidth = fixture.sidebarWidth
        fixture.moveDivider(toSidebarWidth: sidebarWidth + Fixture.dividerOffset)

        #expect(fixture.sidebarWidth == sidebarWidth)

        separator.invalidateIntrinsicContentSize()
        fixture.layoutAndDisplay()
        fixture.moveDivider(toSidebarWidth: sidebarWidth + Fixture.dividerOffset)

        #expect(fixture.sidebarWidth == sidebarWidth + Fixture.dividerOffset)
    }
}

// MARK: - Fixture

extension HorizontalSeparatorViewTests {
    @MainActor
    final class Fixture {
        /// How far the tests move the divider.
        static let dividerOffset: CGFloat = 100

        let window: NSWindow

        let splitViewController = NSSplitViewController()

        let sidebarViewController = NSViewController()

        let contentViewController = NSViewController()

        /// The page in the sidebar, holding the line.
        let pageView = NSView()

        var splitView: NSSplitView { splitViewController.splitView }

        /// The width of the sidebar's arranged view, which the divider's position sets.
        var sidebarWidth: CGFloat { splitView.arrangedSubviews[0].frame.width }

        init(separator: NSView) {
            sidebarViewController.view = NSView()
            contentViewController.view = NSView()

            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
            sidebarItem.minimumThickness = 200
            sidebarItem.holdingPriority = NSLayoutConstraint.Priority(261)
            let contentItem = NSSplitViewItem(viewController: contentViewController)
            contentItem.minimumThickness = 300
            contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
            splitViewController.splitViewItems = [sidebarItem, contentItem]

            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 1000, height: 600),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            // The window takes its content view controller's view's size, so that view needs one first: without it the
            // window shrinks to both panes' minimum widths and no divider can move at all.
            splitViewController.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
            window.contentViewController = splitViewController
            window.orderFrontRegardless()
            layoutAndDisplay()

            pageView.hierarchy {
                separator
            }

            separator.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.bottom.equalToSuperview().inset(44)
                make.height.equalTo(1)
            }

            // Laid out once while it is still 0 points wide, as launch lays the sidebar's first page out.
            sidebarViewController.view.hierarchy {
                pageView
            }

            pageView.snp.makeConstraints { make in
                make.leading.top.bottom.equalToSuperview()
            }

            let zeroWidthConstraint = pageView.widthAnchor.constraint(equalToConstant: 0)
            zeroWidthConstraint.isActive = true
            layoutAndDisplay()

            zeroWidthConstraint.isActive = false
            pageView.snp.makeConstraints { make in
                make.trailing.equalToSuperview()
            }
            layoutAndDisplay()
        }

        func moveDivider(toSidebarWidth sidebarWidth: CGFloat) {
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
            layoutAndDisplay()
        }

        /// What the window does at the end of a run loop turn.
        func layoutAndDisplay() {
            splitViewController.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }
}

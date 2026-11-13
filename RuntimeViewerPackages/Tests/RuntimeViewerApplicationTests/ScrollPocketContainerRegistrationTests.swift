import AppKit
import Testing
import RuntimeViewerUI

/// Contract suite for `ScrollPocketContainerRegistration`, which keeps an editor pane's tab bar registered
/// with the top scroll pocket of the content on screen and moves it when the content changes.
///
/// A top pocket is as tall as the scroll view's top safe area united with the containers registered on that
/// edge, and shows only while the edge is always shown or has a container (UIFoundation's
/// ScrollPocketTests). The fixture's window has no toolbar over its content, so its scroll views have no
/// safe area, and a pocket as tall as the bar is the registration itself.
///
/// The fixture holds one scroll view at a time and swaps it the way a pane's navigation controller swaps
/// its content. Two scroll views laid over each other do not do: measured on macOS 27.2, AppKit gives the
/// front one a top pocket of its own whatever is registered.
@Suite("ScrollPocketContainerRegistration", .serialized)
@MainActor
struct ScrollPocketContainerRegistrationTests {
    @available(macOS 26.0, *)
    @Test("the bar becomes the top pocket of the scroll view it is registered with")
    func barIsRegisteredWithTheScrollView() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        #expect(fixture.topPocketHeight(of: fixture.firstScrollView) == 0)

        fixture.registration.scrollView = fixture.firstScrollView
        fixture.layoutAndDisplay()

        #expect(fixture.topPocketHeight(of: fixture.firstScrollView) == Fixture.barHeight)
    }

    @available(macOS 26.0, *)
    @Test("new content gets the bar only once the registration moves to its scroll view")
    func barMovesWithTheContent() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.registration.scrollView = fixture.firstScrollView
        fixture.layoutAndDisplay()
        fixture.show(fixture.secondScrollView)

        #expect(fixture.topPocketHeight(of: fixture.secondScrollView) == 0)

        fixture.registration.scrollView = fixture.secondScrollView
        fixture.layoutAndDisplay()

        #expect(fixture.registration.scrollView === fixture.secondScrollView)
        #expect(fixture.topPocketHeight(of: fixture.secondScrollView) == Fixture.barHeight)
    }

    @available(macOS 26.0, *)
    @Test("moving back takes the bar out of the pocket of the scroll view it leaves")
    func barLeavesThePocketBehind() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.registration.scrollView = fixture.firstScrollView
        fixture.show(fixture.secondScrollView)
        fixture.registration.scrollView = fixture.secondScrollView
        fixture.show(fixture.firstScrollView)
        fixture.registration.scrollView = fixture.firstScrollView
        fixture.show(fixture.secondScrollView)

        #expect(fixture.topPocketHeight(of: fixture.secondScrollView) == 0)
    }

    @available(macOS 26.0, *)
    @Test("no scroll view leaves the bar registered nowhere, and the same one again changes nothing")
    func noScrollViewUnregistersTheBar() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.registration.scrollView = fixture.firstScrollView
        fixture.registration.scrollView = fixture.firstScrollView
        fixture.layoutAndDisplay()
        #expect(fixture.topPocketHeight(of: fixture.firstScrollView) == Fixture.barHeight)

        fixture.registration.scrollView = nil
        fixture.layoutAndDisplay()

        #expect(fixture.registration.scrollView == nil)
        #expect(fixture.topPocketHeight(of: fixture.firstScrollView) == 0)
    }
}

// MARK: - Fixture

extension ScrollPocketContainerRegistrationTests {
    /// A pane reduced to what the registration touches: the scroll view of the content on screen filling a
    /// container, and a bar along the container's top edge, in a window outside every display.
    @MainActor
    final class Fixture {
        static let barHeight: CGFloat = 32

        let window: NSWindow
        let containerView = NSView()
        let firstScrollView = NSScrollView()
        let secondScrollView = NSScrollView()
        let barView: NSView
        let registration: ScrollPocketContainerRegistration

        init() {
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let barView = NSView()
            self.barView = barView
            registration = ScrollPocketContainerRegistration(containerView: barView, edge: .top)

            window.isReleasedWhenClosed = false
            window.contentView = containerView

            for scrollView in [firstScrollView, secondScrollView] {
                scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
                scrollView.hasVerticalScroller = true
            }

            containerView.hierarchy {
                barView
            }

            barView.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(Self.barHeight)
            }

            window.orderFrontRegardless()
            show(firstScrollView)
        }

        /// Puts `scrollView` under the bar in place of the one there, as a pane's navigation controller
        /// swaps the content of its active tab.
        func show(_ scrollView: NSScrollView) {
            for shownScrollView in [firstScrollView, secondScrollView] where shownScrollView !== scrollView {
                shownScrollView.removeFromSuperview()
            }
            if scrollView.superview == nil {
                containerView.addSubview(scrollView, positioned: .below, relativeTo: barView)
                scrollView.snp.makeConstraints { make in
                    make.edges.equalToSuperview()
                }
            }
            layoutAndDisplay()
        }

        @available(macOS 26.0, *)
        func topPocketHeight(of scrollView: NSScrollView) -> CGFloat {
            scrollView.box.scrollPocket(on: .top)?.frame.height ?? 0
        }

        /// What the window does at the end of a run loop turn.
        func layoutAndDisplay() {
            containerView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }
}

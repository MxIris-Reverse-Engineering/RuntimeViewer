import AppKit
import Testing
import RuntimeViewerUI

/// Contract suite for `NavigatorScrollViewLayout`, which lays the sidebar's lists out the way Xcode lays
/// out its navigators from macOS 26 on: the list runs the page's full height and the bars float over it.
///
/// The fixture is a page reduced to what the layout reads: a scroll view filling a container, a flipped
/// document much taller than it, and plain views standing in for the bars, laid out with Auto Layout in a
/// window outside every display. The safe area that reaches a page from outside — the toolbar's and the
/// tab switcher's bar — is the container's `additionalSafeAreaInsets`.
@Suite("NavigatorScrollViewLayout", .serialized)
@MainActor
struct NavigatorScrollViewLayoutTests {
    @available(macOS 26.0, *)
    @Test("a bar floating over the bottom edge becomes bottom safe area and bottom content inset")
    func bottomOverlayBecomesBottomInset() {
        let fixture = Fixture(bottomOverlayHeight: 44)
        defer { fixture.tearDown() }

        #expect(fixture.scrollView.additionalSafeAreaInsets.bottom == 44)
        #expect(fixture.scrollView.safeAreaInsets.bottom == 44)
        #expect(fixture.clipView.contentInsets.bottom == 44)
    }

    @available(macOS 26.0, *)
    @Test("the safe area from outside becomes the top content inset, with 8 points more")
    func outsideSafeAreaBecomesTopInset() {
        let fixture = Fixture(outsideTopInset: 80)
        defer { fixture.tearDown() }

        #expect(fixture.scrollView.additionalSafeAreaInsets.top == 0)
        #expect(fixture.clipView.contentInsets.top == 88)
        // A list that has not been scrolled starts at its top, below the bars.
        #expect(fixture.clipView.bounds.minY == -88)
    }

    @available(macOS 26.0, *)
    @Test("an overlay laid out below the outside safe area adds only its own height")
    func topOverlayBelowOutsideSafeAreaAddsItsHeight() {
        let fixture = Fixture(outsideTopInset: 80, topOverlayHeight: 72)
        defer { fixture.tearDown() }

        #expect(fixture.scrollView.additionalSafeAreaInsets.top == 72)
        #expect(fixture.scrollView.safeAreaInsets.top == 152)
        #expect(fixture.clipView.contentInsets.top == 160)
    }

    @available(macOS 26.0, *)
    @Test("a change of the outside safe area reaches the content inset without a call")
    func outsideSafeAreaChangeIsFollowed() {
        let fixture = Fixture(outsideTopInset: 52, bottomOverlayHeight: 44)
        defer { fixture.tearDown() }

        // What the tab switcher does once its bar has a height: 28 more on top of the toolbar's 52.
        fixture.containerView.additionalSafeAreaInsets.top = 80
        fixture.layOut()

        #expect(fixture.clipView.contentInsets.top == 88)
        #expect(fixture.clipView.contentInsets.bottom == 44)
    }

    @available(macOS 26.0, *)
    @Test("a change of the insets keeps the rows where they were")
    func insetChangeKeepsScrollPosition() {
        let fixture = Fixture(outsideTopInset: 52)
        defer { fixture.tearDown() }

        fixture.scroll(toDistanceFromTop: 100)
        fixture.containerView.additionalSafeAreaInsets.top = 80
        fixture.layOut()

        #expect(fixture.clipView.contentInsets.top == 88)
        #expect(fixture.clipView.bounds.minY + fixture.clipView.contentInsets.top == 100)
    }

    @available(macOS 26.0, *)
    @Test("a bar that moves after the layout is made is followed")
    func overlayFrameChangeIsFollowed() {
        let fixture = Fixture(bottomOverlayHeight: 44)
        defer { fixture.tearDown() }

        fixture.bottomOverlayHeightConstraint?.update(offset: 56)
        fixture.layOut()

        #expect(fixture.scrollView.additionalSafeAreaInsets.bottom == 56)
        #expect(fixture.clipView.contentInsets.bottom == 56)
    }

    @available(macOS 26.0, *)
    @Test("the clip view stops adjusting its insets and both edges always show their pocket")
    func clipViewAndPocketSettings() {
        let fixture = Fixture(bottomOverlayHeight: 44)
        defer { fixture.tearDown() }

        #expect(fixture.clipView.automaticallyAdjustsContentInsets == false)
        #expect(fixture.scrollView.automaticallyAdjustsContentInsets == true)
        #expect(fixture.scrollView.alwaysShownPocketEdges == 0b11)
    }

    // MARK: - Scroll pocket containers

    // A bottom pocket exists only while its edge is always shown or has a container, and the top pocket is
    // as tall as the top safe area united with its containers (UIFoundation's ScrollPocketTests). Taking the
    // always-shown edges away, or leaving the safe area out, is what makes a registration visible.

    @available(macOS 26.0, *)
    @Test("without a bar over the bottom edge, the bottom pocket goes once the edge is no longer always shown")
    func bottomPocketNeedsAlwaysShownEdgeWithoutBar() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.scrollView.box.alwaysShownScrollPocketEdges = []
        fixture.layOut()

        #expect((fixture.scrollView.box.scrollPocket(on: .bottom)?.frame.height ?? 0) == 0)
    }

    @available(macOS 26.0, *)
    @Test("the bar over the bottom edge is registered as a container of the bottom pocket")
    func bottomOverlayIsRegisteredWithBottomPocket() {
        let fixture = Fixture(bottomOverlayHeight: 44)
        defer { fixture.tearDown() }

        fixture.scrollView.box.alwaysShownScrollPocketEdges = []
        fixture.layOut()

        #expect(fixture.scrollView.box.scrollPocket(on: .bottom)?.frame.height == 44)
    }

    @available(macOS 26.0, *)
    @Test("an inherited bar is registered with the top pocket without adding safe area, and unregistered when it goes")
    func inheritedTopOverlayIsRegisteredAndUnregistered() {
        let fixture = Fixture(inheritedTopOverlayHeight: 28)
        defer { fixture.tearDown() }

        #expect((fixture.scrollView.box.scrollPocket(on: .top)?.frame.height ?? 0) == 0)

        fixture.layout.inheritedTopOverlayViews = [fixture.inheritedTopOverlayView]
        fixture.layOut()

        #expect(fixture.scrollView.additionalSafeAreaInsets.top == 0)
        #expect(fixture.scrollView.box.scrollPocket(on: .top)?.frame.height == 28)

        // Handing the same bar over again changes nothing; taking it away unregisters it.
        fixture.layout.inheritedTopOverlayViews = [fixture.inheritedTopOverlayView, fixture.inheritedTopOverlayView]
        fixture.layOut()
        #expect(fixture.scrollView.box.scrollPocket(on: .top)?.frame.height == 28)

        fixture.layout.inheritedTopOverlayViews = []
        fixture.layOut()

        #expect((fixture.scrollView.box.scrollPocket(on: .top)?.frame.height ?? 0) == 0)
    }

    @available(macOS 26.0, *)
    @Test("the bars are taken for bars")
    func barsAnswerTheBarElementStyle() {
        #expect(ScrollPocketBarView()._scrollPocketElementStyle == NSView.barScrollPocketElementStyle)
        #expect(NavigatorFilterControlBar()._scrollPocketElementStyle == NSView.barScrollPocketElementStyle)
    }

    @available(macOS 26.0, *)
    @Test("the pocket styles are Xcode's: 2 on both edges on macOS 26, the default 0 from macOS 27")
    func pocketStylesFollowXcode() {
        let fixture = Fixture(bottomOverlayHeight: 44)
        defer { fixture.tearDown() }

        let expectedStyle: Int
        if #available(macOS 27.0, *) {
            expectedStyle = 0
        } else {
            expectedStyle = 2
        }
        #expect(fixture.scrollView.box.scrollPocketStyle(on: .top) == expectedStyle)
        #expect(fixture.scrollView.box.scrollPocketStyle(on: .bottom) == expectedStyle)
    }
}

// MARK: - Fixture

extension NavigatorScrollViewLayoutTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let containerView = NSView()
        let scrollView = NSScrollView()
        let topOverlayView = NSView()
        let bottomOverlayView = NSView()
        /// Stands in for the tab switcher's bar: on the container's top edge, and no part of the page.
        let inheritedTopOverlayView = NSView()
        private(set) var bottomOverlayHeightConstraint: Constraint?
        private(set) var layout: NavigatorScrollViewLayout!

        var clipView: NSClipView { scrollView.contentView }

        init(
            outsideTopInset: CGFloat = 0,
            topOverlayHeight: CGFloat? = nil,
            bottomOverlayHeight: CGFloat? = nil,
            inheritedTopOverlayHeight: CGFloat = 0
        ) {
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = containerView
            containerView.additionalSafeAreaInsets = NSEdgeInsets(top: outsideTopInset, left: 0, bottom: 0, right: 0)

            scrollView.documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
            scrollView.hasVerticalScroller = true

            containerView.hierarchy {
                scrollView
                topOverlayView
                bottomOverlayView
                inheritedTopOverlayView
            }

            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            // The Find page's query area sits right below the safe area that reaches the page.
            topOverlayView.snp.makeConstraints { make in
                make.top.equalTo(containerView.safeAreaLayoutGuide)
                make.leading.trailing.equalToSuperview()
                make.height.equalTo(topOverlayHeight ?? 0)
            }

            // The filter bar sits on the page's bottom edge.
            bottomOverlayView.snp.makeConstraints { make in
                make.leading.trailing.bottom.equalToSuperview()
                bottomOverlayHeightConstraint = make.height.equalTo(bottomOverlayHeight ?? 0).constraint
            }

            inheritedTopOverlayView.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(inheritedTopOverlayHeight)
            }

            // Made before the first layout pass, as a page makes it in `viewDidLoad`: the frames it
            // reads arrive afterwards.
            layout = NavigatorScrollViewLayout(
                scrollView: scrollView,
                topOverlayViews: topOverlayHeight == nil ? [] : [topOverlayView],
                bottomOverlayViews: bottomOverlayHeight == nil ? [] : [bottomOverlayView]
            )

            window.orderFrontRegardless()
            layOut()
        }

        /// Scrolls the document so that its top is the given distance above the top of the content area.
        func scroll(toDistanceFromTop distance: CGFloat) {
            clipView.scroll(to: NSPoint(x: 0, y: distance - clipView.contentInsets.top))
            scrollView.reflectScrolledClipView(clipView)
            layOut()
        }

        /// What the window does at the end of a run loop turn.
        func layOut() {
            containerView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}

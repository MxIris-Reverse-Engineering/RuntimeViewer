import AppKit
import Testing
import RuntimeViewerUI
import UIFoundation

/// Contract suite for `ToolbarScrollPocketContainerView`, which the editor area puts its panes in.
///
/// Every scroll view under the title bar has a top scroll pocket of its own, and AppKit blurs all of them from one
/// capture, taken when the first is drawn: the toolbar over every pane after the first showed the window's background,
/// flat, and a minimap drawn over its own pane's pocket stayed sharp (measured on macOS 27.2). The container lays one
/// pocket over the toolbar's strip after all its content, so that one capture holds every pane.
///
/// The fixture is two scroll views side by side in the container, filling a window whose toolbar overlaps its content.
@Suite("ToolbarScrollPocketContainerView", .serialized)
@MainActor
struct ToolbarScrollPocketContainerViewTests {
    @available(macOS 26.0, *)
    @Test("one pocket lies over the toolbar's strip across every pane, drawn after them all")
    func onePocketCoversTheToolbarStripInFrontOfEveryPane() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let pocket = try #require(fixture.frontPocket)
        #expect(fixture.containerView.subviews.last === pocket)
        #expect(fixture.frameInWindow(of: pocket) == fixture.toolbarStrip)
        #expect(fixture.toolbarStrip.height > 0)
    }

    @available(macOS 26.0, *)
    @Test("the pocket's capture view lies behind every pane, over the same strip")
    func captureViewLiesBehindThePanes() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let captureView = try #require(fixture.frontPocket?.captureView)
        #expect(fixture.containerView.subviews.first === captureView)
        #expect(fixture.frameInWindow(of: captureView) == fixture.toolbarStrip)
    }

    @available(macOS 26.0, *)
    @Test("the pocket blurs in a backdrop group apart from the one the panes' own pockets share")
    func pocketBlursInAGroupOfItsOwn() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let pocket = try #require(fixture.frontPocket)
        let pocketGroupName = try #require(Fixture.contentBlurGroupName(in: pocket))
        let paneGroupName = try #require(fixture.leadingScrollView.box.scrollPocket(on: .top).flatMap(Fixture.contentBlurGroupName(in:)))
        #expect(pocketGroupName != paneGroupName)
    }

    @available(macOS 26.0, *)
    @Test("with the toolbar hidden the pocket has no height")
    func pocketFollowsTheToolbar() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.window.toolbar?.isVisible = false
        fixture.layoutAndDisplay()

        let pocket = try #require(fixture.frontPocket)
        #expect(pocket.frame.height == fixture.containerView.safeAreaInsets.top)
    }
}

// MARK: - Fixture

extension ToolbarScrollPocketContainerViewTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let containerView: ToolbarScrollPocketContainerView
        let leadingScrollView = Fixture.makeScrollView()
        let trailingScrollView = Fixture.makeScrollView()

        init() {
            let bounds = NSRect(x: 0, y: 0, width: 800, height: 500)
            window = NSWindow(
                contentRect: bounds.offsetBy(dx: -6000, dy: -6000),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.toolbar = NSToolbar(identifier: "ToolbarScrollPocketContainerViewTests")
            window.toolbarStyle = .unified

            let splitView = NSSplitView(frame: bounds)
            splitView.isVertical = true
            splitView.addArrangedSubview(leadingScrollView)
            splitView.addArrangedSubview(trailingScrollView)
            containerView = ToolbarScrollPocketContainerView(contentView: splitView)
            window.contentView = containerView

            window.orderFrontRegardless()
            layoutAndDisplay()
        }

        /// The pocket the container lays over its content, as a `ScrollPocketView` among its subviews.
        var frontPocket: ScrollPocketView? {
            containerView.subviews.compactMap { $0 as? ScrollPocketView }.first
        }

        /// The strip of the window the toolbar overlaps, across the container.
        var toolbarStrip: NSRect {
            let bounds = containerView.convert(containerView.bounds, to: nil)
            let depth = containerView.safeAreaInsets.top
            return NSRect(x: bounds.minX, y: bounds.maxY - depth, width: bounds.width, height: depth)
        }

        func frameInWindow(of view: NSView) -> NSRect {
            view.convert(view.bounds, to: nil)
        }

        /// What the window does at the end of a run loop turn, and then the Core Animation commit in which AppKit
        /// builds the pockets' layers.
        func layoutAndDisplay() {
            containerView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        func tearDown() {
            window.orderOut(nil)
        }

        /// The group of the backdrop layer a pocket blurs the content in — `ThinFilmContentBlurFill` or
        /// `HardPocketContentBlur` on macOS 27.2.
        static func contentBlurGroupName(in view: NSView) -> String? {
            func backdropLayers(in layer: CALayer) -> [CALayer] {
                (NSStringFromClass(type(of: layer)) == "CABackdropLayer" ? [layer] : []) + (layer.sublayers ?? []).flatMap { backdropLayers(in: $0) }
            }
            return view.layer.flatMap { layer in
                backdropLayers(in: layer).first { $0.name?.contains("ContentBlur") == true && !$0.isHidden }
            }
            .flatMap { $0.value(forKey: "groupName") as? String }
        }

        private static func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
            scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
            scrollView.hasVerticalScroller = true
            return scrollView
        }
    }
}

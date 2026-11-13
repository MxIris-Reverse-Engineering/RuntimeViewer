import AppKit
import AppKitPlus
import Testing
import RuntimeViewerUI

/// Regression suite for a Back button drawn in the toolbar's strip, above an editor pane showing its
/// tab bar (2026-11-06).
///
/// AppKitPlus hides a navigation bar by moving it above the top layout guide, not by hiding the view,
/// and a view does not clip what it holds (macOS 14 on). While a navigation controller's view ran
/// from the top of the window the bar sat outside it; an editor pane's content now starts below the
/// toolbar's strip when the pane shows its tab bar, so the bar was drawn in that strip, with whatever
/// its top item carried — the Back button AppKitPlus adds to a pushed page. What gave the pane's page
/// that button was not reproduced; with the bar hidden as a view, nothing it carries is drawn.
///
/// The fixture is a `BaseNavigationController` whose view starts 52 points below the top of the
/// window's content.
@Suite("Base navigation controller", .serialized)
@MainActor
struct BaseNavigationControllerTests {
    @Test("the navigation bar draws nothing above a navigation controller whose view starts below the top of the window")
    func navigationBarDrawsNothingAboveTheView() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.navigationController.setViewControllers([Fixture.makePage()], animated: false)
        fixture.settle()

        let navigationBar = fixture.navigationController.navigationBar
        let barFrame = navigationBar.convert(navigationBar.bounds, to: fixture.containerView)
        let isDrawn = !navigationBar.isHiddenOrHasHiddenAncestor && barFrame.intersects(fixture.containerView.bounds)
        #expect(!isDrawn, "the bar is drawn at \(barFrame) in a window content of \(fixture.containerView.bounds)")
    }
}

// MARK: - Fixture

extension BaseNavigationControllerTests {
    @MainActor
    final class Fixture {
        /// What lies above the navigation controller's view: the toolbar's strip, and a pane's tab bar.
        static let stripHeight: CGFloat = 52

        let window: NSWindow

        let containerView = NSView()

        let navigationController = BaseNavigationController()

        init() {
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = containerView
            let navigationView = navigationController.view
            navigationView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(navigationView)
            NSLayoutConstraint.activate([
                navigationView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Self.stripHeight),
                navigationView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                navigationView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                navigationView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
            window.orderFrontRegardless()
            settle()
        }

        /// A turn of the run loop, then layout and display: what happens between two of the
        /// user's actions.
        func settle() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            containerView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        static func makePage() -> NSViewController {
            let page = NSViewController(nibName: nil, bundle: nil)
            page.view = NSView()
            return page
        }
    }
}

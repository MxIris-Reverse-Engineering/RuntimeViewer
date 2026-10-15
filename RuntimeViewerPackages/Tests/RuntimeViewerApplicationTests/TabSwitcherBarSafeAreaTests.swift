import AppKit
import AppKitPlus
import Testing
import RuntimeViewerUI

/// Regression suite for the sidebar's tab switcher from macOS 26 on: the bar holding its segmented control floats
/// over the pages, and its height has to reach every page as safe area, so that a page's list starts below the bar.
///
/// The fixture is the app's `TabViewController` under `.underSegmentedControl`, laid out the same way — a root view
/// holding a content view, which holds the tab view filling it and the bar pinned to its safe area, with
/// `FloatingBarSafeAreaLayout` handing the bar's height to the tab view — and pages laid out like the sidebar's object
/// list: a container, the image-state tab view inside it, and the loaded view holding the list and the filter bar, run
/// by `NavigatorScrollViewLayout`. The toolbar's safe area is the root view's `additionalSafeAreaInsets`.
///
/// Every test here failed while the switcher wrote the bar's height from its `viewDidLayout`, which runs before AppKit
/// lays out the bar: the tab view's top inset stayed 0 and the list started at the toolbar's 52 + 8 instead of 88.
/// Background: `Documentations/ResolvedIssues/2026-10-15-sidebar-list-starts-under-the-tab-switcher-bar.md`.
@Suite("Tab switcher bar safe area", .serialized)
@MainActor
struct TabSwitcherBarSafeAreaTests {
    @available(macOS 26.0, *)
    @Test("the page's list starts below the bar after the first layout pass")
    func listStartsBelowBarAfterFirstLayoutPass() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let barHeight = fixture.switcherViewController.barView.frame.height
        #expect(barHeight > 0)
        #expect(fixture.switcherViewController.tabView.additionalSafeAreaInsets.top == barHeight)
        #expect(fixture.firstPageViewController.scrollView.safeAreaInsets.top == Fixture.toolbarInset + barHeight)
        #expect(
            fixture.firstPageViewController.clipView.contentInsets.top
                == Fixture.toolbarInset + barHeight + NavigatorScrollViewLayout.topContentInsetBeyondSafeArea
        )
    }

    @available(macOS 26.0, *)
    @Test("a page selected after the first layout pass starts below the bar too")
    func pageSelectedLaterStartsBelowBar() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        fixture.switcherViewController.tabView.selectTabViewItem(at: 1)
        fixture.layOut()

        let barHeight = fixture.switcherViewController.barView.frame.height
        #expect(
            fixture.secondPageViewController.clipView.contentInsets.top
                == Fixture.toolbarInset + barHeight + NavigatorScrollViewLayout.topContentInsetBeyondSafeArea
        )
    }

    @available(macOS 26.0, *)
    @Test("a change of the bar's height reaches the list")
    func barHeightChangeIsFollowed() {
        let fixture = Fixture()
        defer { fixture.tearDown() }

        let largeBarHeight = fixture.switcherViewController.barView.frame.height
        fixture.switcherViewController.segmentedControl.controlSize = .small
        fixture.layOut()

        let smallBarHeight = fixture.switcherViewController.barView.frame.height
        #expect(smallBarHeight < largeBarHeight)
        #expect(fixture.switcherViewController.tabView.additionalSafeAreaInsets.top == smallBarHeight)
        #expect(
            fixture.firstPageViewController.clipView.contentInsets.top
                == Fixture.toolbarInset + smallBarHeight + NavigatorScrollViewLayout.topContentInsetBeyondSafeArea
        )
    }
}

// MARK: - Fixture

extension TabSwitcherBarSafeAreaTests {
    @MainActor
    final class Fixture {
        /// Stands in for the toolbar's safe area, which reaches the sidebar from the window.
        static let toolbarInset: CGFloat = 52

        let window: NSWindow
        let switcherViewController = SwitcherViewController()
        let firstPageViewController = PageViewController()
        let secondPageViewController = PageViewController()

        init() {
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false

            // As in the app: the pages are loaded and handed to the switcher before the switcher's own view loads
            // (`setTabViewItems`, run by the coordinator while it is created), and the first one is selected.
            firstPageViewController.loadViewIfNeeded()
            secondPageViewController.loadViewIfNeeded()
            switcherViewController.tabView.addTabViewItem(NSTabViewItem(viewController: firstPageViewController))
            switcherViewController.tabView.addTabViewItem(NSTabViewItem(viewController: secondPageViewController))
            switcherViewController.tabView.selectTabViewItem(at: 0)
            for pageViewController in [firstPageViewController, secondPageViewController] {
                pageViewController.navigatorScrollViewLayout.inheritedTopOverlayViews = [switcherViewController.barView]
            }

            window.contentView = switcherViewController.view
            switcherViewController.view.additionalSafeAreaInsets = NSEdgeInsets(top: Self.toolbarInset, left: 0, bottom: 0, right: 0)

            window.orderFrontRegardless()
            layOut()
        }

        /// What the window does at the end of a run loop turn.
        func layOut() {
            switcherViewController.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }

    /// A tab view styled the way the app styles its two: without tabs and border, set before any content.
    static func makeBorderlessTabView() -> NSTabView {
        let tabView = NSTabView()
        tabView.tabViewType = .noTabsNoBorder
        tabView.tabPosition = .none
        tabView.tabViewBorderType = .none
        return tabView
    }

    /// `TabViewController` from macOS 26 on, under `.underSegmentedControl`.
    final class SwitcherViewController: NSLayerBackedViewController {
        let contentView = NSLayerBackedView()

        let tabView = TabSwitcherBarSafeAreaTests.makeBorderlessTabView()

        let barView = ScrollPocketBarView()

        let segmentedControl = NSSegmentedControl()

        private var barSafeAreaLayout: FloatingBarSafeAreaLayout?

        override func viewDidLoad() {
            super.viewDidLoad()

            view.hierarchy {
                contentView
            }

            contentView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            contentView.hierarchy {
                tabView
                barView.hierarchy {
                    segmentedControl
                }
            }

            barView.snp.makeConstraints { make in
                make.top.leading.trailing.equalTo(contentView.safeAreaLayoutGuide)
            }

            segmentedControl.snp.makeConstraints { make in
                make.top.bottom.equalToSuperview()
                make.leading.trailing.equalToSuperview().inset(8)
            }

            tabView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            barSafeAreaLayout = FloatingBarSafeAreaLayout(barView: barView, coveredView: tabView)

            segmentedControl.segmentCount = 2
            segmentedControl.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: nil), forSegment: 0)
            segmentedControl.setImage(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil), forSegment: 1)
            segmentedControl.controlSize = .large
            segmentedControl.selectedSegment = 0
        }
    }

    /// A page laid out like the sidebar's object list (`SidebarRuntimeObjectViewController`): its container, the tab
    /// view switching between the image states, and the loaded state's view holding the list.
    final class PageViewController: NSLayerBackedViewController {
        let containerView = NSView()

        let imageStateTabView = TabSwitcherBarSafeAreaTests.makeBorderlessTabView()

        let loadedView = LoadedView()

        var scrollView: ScrollView { loadedView.scrollView }

        var clipView: NSClipView { loadedView.scrollView.contentView }

        var navigatorScrollViewLayout: NavigatorScrollViewLayout { loadedView.navigatorScrollViewLayout }

        override func viewDidLoad() {
            super.viewDidLoad()

            view.hierarchy {
                containerView
            }

            containerView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            containerView.hierarchy {
                imageStateTabView
            }

            imageStateTabView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            let loadedItem = NSTabViewItem()
            loadedItem.view = loadedView
            imageStateTabView.addTabViewItem(loadedItem)
            imageStateTabView.selectTabViewItem(loadedItem)
        }
    }

    /// The loaded state of the object list (`SidebarRuntimeObjectViewController.ImageLoadedView`): the list reaching every
    /// edge, and the filter bar floating over its bottom edge.
    final class LoadedView: NSView {
        let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

        let filterControlBar = NavigatorFilterControlBar()

        private(set) var navigatorScrollViewLayout: NavigatorScrollViewLayout!

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            hierarchy {
                scrollView
                filterControlBar
            }

            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            filterControlBar.snp.makeConstraints { make in
                make.leading.trailing.bottom.equalToSuperview()
            }

            scrollView.autohidesScrollers = true
            scrollView.hidesVisualEffectView = true

            filterControlBar.filterField = NSFilterSearchField()
            filterControlBar.controlSize = .large

            // Made in `init`, before the view is in any window, as the app makes it.
            navigatorScrollViewLayout = NavigatorScrollViewLayout(scrollView: scrollView, bottomOverlayViews: [filterControlBar])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

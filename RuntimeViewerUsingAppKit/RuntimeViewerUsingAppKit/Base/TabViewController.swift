import AppKit
import AppKitPlus
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

struct TabViewItem {
    let normalSymbol: SFSymbols
    let selectedSymbol: SFSymbols
    let viewController: NSViewController
    /// While this is `true` the tab's symbol carries a dot — the Report navigator's tab while
    /// work is running. `nil` for a tab that never shows one.
    var activity: Driver<Bool>? = nil
}

class TabViewController: NSLayerBackedViewController {
    /// Transparent from macOS 26: the page sits directly on the split view item's glass, which no
    /// colour or material reproduces. The opaque backdrop a push / pop needs is inserted under the
    /// page for the length of the transition by `NavigationTransitionBackdropController` and removed
    /// afterwards. Background: `Documentations/ResolvedIssues/2026-09-18-sidebar-transition-backdrop-glass-replica.md`.
    private let contentView: NSView = if #available(macOS 26.0, *) {
        NSLayerBackedView()
    } else {
        NSVisualEffectView()
    }

    private let segmentedControl: any SegmentedControl = {
        if #available(macOS 26.0, *) {
            let segmentedControl = NSSegmentedControl()
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                segmentedControl.role = .tabs
            }
            #endif
            return segmentedControl
        } else {
            return AreaSegmentedControl()
        }
    }()

    /// The style is applied here rather than in `viewDidLoad` on purpose:
    /// `setTabViewItems` runs before the view ever loads — it only touches this
    /// stored property — and until the style lands AppKit still reserves room
    /// for a tab strip and a border. Subtracted from a zero bounds that gives a
    /// negative content rect, which macOS 27 reports as "Invalid view geometry".
    private let tabView = NSTabView().then {
        $0.tabViewType = .noTabsNoBorder
        $0.tabPosition = .none
        $0.tabViewBorderType = .none
    }

    /// Invoked when the user changes the active tab by tapping the
    /// segmented control. Programmatic selection (e.g. `set` / `select`
    /// transitions, autosave restore) does **not** trigger this callback,
    /// so callers can use it to persist "last user-selected tab" state
    /// without false positives during view setup.
    var onUserSelectIndex: ((Int) -> Void)?

    var autosaveName: String? {
        didSet {
            guard let autosaveName else { return }
            let index = UserDefaults.standard.integer(forKey: autosaveName)
            guard index >= 0, index < tabView.numberOfTabViewItems, index < segmentedControl.segmentCount else { return }
            tabView.selectTabViewItem(at: index)
            segmentedControl.selectedSegment = index
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            contentView.hierarchy {
                segmentedControl
                tabView
            }
        }

        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        segmentedControl.snp.makeConstraints { make in
            make.top.equalTo(contentView.safeAreaLayoutGuide)
            if #available(macOS 26.0, *) {
                make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide).inset(8)
            } else {
                make.leading.trailing.equalTo(contentView.safeAreaLayoutGuide)
            }
        }

        tabView.view.snp.makeConstraints { make in
            make.top.equalTo(segmentedControl.snp.bottom).offset(10)
            make.left.right.bottom.equalTo(contentView.safeAreaLayoutGuide)
        }

//        segmentedControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        segmentedControl.controlSize = .large
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(handleSegmentedControlAction(_:))
    }

    @objc private func handleSegmentedControlAction(_ sender: Any) {
        let index = segmentedControl.selectedSegment
        guard index >= 0, index < tabView.numberOfTabViewItems else { return }
        tabView.selectTabViewItem(at: index)
        if let autosaveName {
            UserDefaults.standard.set(index, forKey: autosaveName)
        }
        onUserSelectIndex?(index)
    }

    /// What an AppKitPlus navigation controller makes first responder once this page is on top —
    /// after a push, a pop or a `set`. Forwarded to the tab on screen, so the list inside it is
    /// what gets focus.
    ///
    /// An answer that refuses focus is not passed on: up to 0.4.4 AppKitPlus answers a page's plain
    /// root view by default, and while an ancestor container is first responder, right-clicking a
    /// row's text does not open the table's menu, and on macOS 27 a click no longer moves focus into
    /// the table — the selection draws grey. `nil` makes the window first responder, which clicks
    /// move off normally. Background:
    /// `Documentations/ResolvedIssues/2026-09-24-sidebar-focus-parked-on-a-navigation-container.md`.
    override var preferredFirstResponder: NSResponder? {
        guard let preferredFirstResponder = tabView.selectedTabViewItem?.viewController?.preferredFirstResponder else { return nil }
        if let preferredView = preferredFirstResponder as? NSView, !preferredView.acceptsFirstResponder {
            return nil
        }
        return preferredFirstResponder
    }

    var selectedTabViewItemIndex: Int {
        set {
            guard newValue >= 0, newValue < tabView.numberOfTabViewItems else { return }
            tabView.selectTabViewItem(at: newValue)
            if newValue < segmentedControl.segmentCount {
                segmentedControl.selectedSegment = newValue
            }
        }
        get { tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) } ?? NSNotFound }
    }

    /// Reconcile the tab strip against `tabViewItems`, keeping every view
    /// controller that survives the change.
    ///
    /// This used to remove every tab item and add the new set back.
    /// `NSTabView` installs the selected item's view as soon as the selection
    /// moves, so a full teardown swapped the visible view several times
    /// within a single runloop pass — a visible flash every time the
    /// inspected object's kind changed the tab set (selecting a protocol
    /// after a class drops the Hierarchy tab, for instance). Reconciling in
    /// place means an unchanged tab keeps its view throughout, and only the
    /// tabs that genuinely appear or disappear cost anything.
    func setTabViewItems(_ tabViewItems: [TabViewItem], selectedIndex: Int) {
        segmentedControl.segmentCount = tabViewItems.count
        self.tabViewItems = tabViewItems
        activeTabIndices = []
        activityDisposeBag = DisposeBag()
        for (index, tabViewItem) in tabViewItems.enumerated() {
            applySymbols(of: tabViewItem, at: index)
            tabViewItem.activity?.driveOnNext { [weak self] isActive in
                guard let self else { return }
                setActivity(isActive, forTabAt: index)
            }
            .disposed(by: activityDisposeBag)
        }

        let targetViewControllers = tabViewItems.map(\.viewController)

        // Move to the target tab before removing anything: removing the
        // selected item makes `NSTabView` fall back to a neighbour on its
        // own, installing a view that is about to be replaced anyway.
        if targetViewControllers.indices.contains(selectedIndex),
           let existingIndex = indexOfTabViewItem(for: targetViewControllers[selectedIndex]) {
            tabView.selectTabViewItem(at: existingIndex)
        }

        for existingItem in tabView.tabViewItems {
            guard !targetViewControllers.contains(where: { $0 === existingItem.viewController }) else { continue }
            tabView.removeTabViewItem(existingItem)
        }

        for (targetIndex, viewController) in targetViewControllers.enumerated() {
            if let existingIndex = indexOfTabViewItem(for: viewController) {
                guard existingIndex != targetIndex else { continue }
                let existingItem = tabView.tabViewItems[existingIndex]
                tabView.removeTabViewItem(existingItem)
                tabView.insertTabViewItem(existingItem, at: targetIndex)
            } else {
                tabView.insertTabViewItem(.init(viewController: viewController), at: targetIndex)
            }
        }

        selectedTabViewItemIndex = selectedIndex
    }

    private func indexOfTabViewItem(for viewController: NSViewController) -> Int? {
        tabView.tabViewItems.firstIndex { $0.viewController === viewController }
    }

    // MARK: - Activity

    /// The items last set, for re-applying a tab's symbols when its activity changes.
    private var tabViewItems: [TabViewItem] = []

    private var activeTabIndices: Set<Int> = []

    /// The subscriptions to the items' activity, replaced with the items.
    private var activityDisposeBag = DisposeBag()

    private func setActivity(_ isActive: Bool, forTabAt index: Int) {
        guard tabViewItems.indices.contains(index) else { return }
        if isActive {
            guard activeTabIndices.insert(index).inserted else { return }
        } else {
            guard activeTabIndices.remove(index) != nil else { return }
        }
        applySymbols(of: tabViewItems[index], at: index)
    }

    /// The segment's two images, both given the dot while the tab is active: before macOS 26 the
    /// selected segment shows the alternate image, from macOS 26 only the plain one.
    private func applySymbols(of tabViewItem: TabViewItem, at index: Int) {
        let isActive = activeTabIndices.contains(index)
        let normalImage = tabViewItem.normalSymbol.nsuiImgae
        let selectedImage = tabViewItem.selectedSymbol.nsuiImgae
        segmentedControl.setImage(isActive ? normalImage.withActivityDot() : normalImage, forSegment: index)
        segmentedControl.setAlternateImage(isActive ? selectedImage.withActivityDot() : selectedImage, forSegment: index)
    }
}

extension NSImage {
    /// The image with a dot in its top trailing corner, cut out of the symbol with a gap around
    /// it. Still a template: a segmented control tints the symbol and the dot alike, so the dot
    /// marks the tab by its shape, not its colour.
    fileprivate func withActivityDot() -> NSImage {
        let dotDiameter = (min(size.width, size.height) * 0.38).rounded()
        let gap: CGFloat = 1.5
        let badged = NSImage(size: size, flipped: false) { [self] bounds in
            draw(in: bounds)
            let dotRectangle = NSRect(x: bounds.maxX - dotDiameter, y: bounds.maxY - dotDiameter, width: dotDiameter, height: dotDiameter)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRectangle.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRectangle).fill()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = accessibilityDescription
        return badged
    }
}

extension TabViewController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        let index = tabView.indexOfTabViewItem(tabViewItem)
        guard index >= 0, index < tabView.numberOfTabViewItems else { return }
        guard let autosaveName else { return }
        UserDefaults.standard.set(index, forKey: autosaveName)
    }
}

import CocoaCoordinator

extension Transition where ViewController: TabViewController {
    static func select(index: Int) -> Self {
        Self(presentables: []) { windowController, viewController, options, completion in
            viewController?.selectedTabViewItemIndex = index
            completion?()
        }
    }

    static func set(_ tabViewItems: [TabViewItem], initialIndex: Int = 0) -> Self {
        Self(presentables: tabViewItems.map(\.viewController)) { windowController, viewController, options, completion in
            guard let viewController = viewController ?? ((windowController as? NSWindowController)?.contentViewController as? ViewController) else {
                completion?()
                return
            }
            viewController.setTabViewItems(tabViewItems, selectedIndex: initialIndex)
            completion?()
        }
    }
}

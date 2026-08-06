import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication

struct TabViewItem {
    let normalSymbol: SFSymbols
    let selectedSymbol: SFSymbols
    let viewController: NSViewController
}

class TabViewController: UXViewController {
    private let contentView: NSView = {
        if #available(macOS 26.0, *) {
            UXView()
        } else {
            NSVisualEffectView()
        }
    }()

    private let segmentedControl: any SegmentedControl = {
        if #available(macOS 26.0, *) {
            NSSegmentedControl()
        } else {
            AreaSegmentedControl()
        }
    }()

    private let tabView = NSTabView()

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

        tabView.tabViewType = .noTabsNoBorder
        tabView.tabPosition = .none
        tabView.tabViewBorderType = .none
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
        for (index, tabViewItem) in tabViewItems.enumerated() {
            segmentedControl.setImage(tabViewItem.normalSymbol.nsuiImgae, forSegment: index)
            segmentedControl.setAlternateImage(tabViewItem.selectedSymbol.nsuiImgae, forSegment: index)
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

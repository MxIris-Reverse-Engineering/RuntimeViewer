import AppKit
import RuntimeViewerUI

struct TabViewItem {
    let symbol: SFSymbols
    let viewController: NSViewController
}

class TabViewController: UXViewController {
    private let segmentedControl = NSSegmentedControl()

    private let tabView = NSTabView()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            segmentedControl
            tabView
        }

        segmentedControl.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.left.right.equalTo(view.safeAreaLayoutGuide).inset(8)
        }

        tabView.view.snp.makeConstraints { make in
            make.top.equalTo(segmentedControl.snp.bottom).offset(12)
            make.left.right.bottom.equalTo(view.safeAreaLayoutGuide)
        }

        segmentedControl.controlSize = .large
        segmentedControl.selectedSegment = 0
        segmentedControl.box.action { [weak self] segmentedControl in
            guard let self else { return }
            let indexOfSelectedItem = segmentedControl.indexOfSelectedItem
            guard indexOfSelectedItem >= 0, indexOfSelectedItem < tabView.tabViewItems.count else { return }
            selectedTabViewItemIndex = segmentedControl.indexOfSelectedItem
        }

        tabView.tabViewType = .noTabsNoBorder
        tabView.tabPosition = .none
        tabView.tabViewBorderType = .none
    }

    var selectedTabViewItemIndex: Int {
        set { tabView.selectTabViewItem(at: newValue) }
        get { tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) } ?? NSNotFound }
    }

    func setTabViewItems(_ tabViewItems: [TabViewItem]) {
        segmentedControl.segmentCount = tabViewItems.count
        for (index, tabViewItem) in tabViewItems.enumerated() {
            segmentedControl.setImage(tabViewItem.symbol.nsuiImgae, forSegment: index)
            tabView.addTabViewItem(.init(viewController: tabViewItem.viewController))
        }
    }

    func removeAllTabViewItems() {
        tabView.tabViewItems.forEach { tabView.removeTabViewItem($0) }
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

    static func set(_ presentables: [(symbol: SFSymbols, presentable: Presentable)]) -> Self {
        Self(presentables: presentables.map(\.presentable)) { windowController, viewController, options, completion in
            guard let viewController = viewController ?? ((windowController as? NSWindowController)?.contentViewController as? ViewController) else {
                completion?()
                return
            }
            viewController.removeAllTabViewItems()
            let tabViewItems: [TabViewItem] = presentables.filter { $0.presentable.viewController != nil }.map { .init(symbol: $0.symbol, viewController: $0.presentable.viewController!) }
            viewController.setTabViewItems(tabViewItems)
            completion?()
        }
    }
}

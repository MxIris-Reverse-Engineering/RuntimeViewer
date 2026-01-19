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
        segmentedControl.target = tabView
        segmentedControl.action = #selector(tabView.takeSelectedTabViewItemFromSender(_:))

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
            segmentedControl.setImage(tabViewItem.normalSymbol.nsuiImgae, forSegment: index)
            segmentedControl.setAlternateImage(tabViewItem.selectedSymbol.nsuiImgae, forSegment: index)
            tabView.addTabViewItem(.init(viewController: tabViewItem.viewController))
        }
    }

    func removeAllTabViewItems() {
        tabView.tabViewItems.forEach { tabView.removeTabViewItem($0) }
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

    static func set(_ tabViewItems: [TabViewItem]) -> Self {
        Self(presentables: tabViewItems.map(\.viewController)) { windowController, viewController, options, completion in
            guard let viewController = viewController ?? ((windowController as? NSWindowController)?.contentViewController as? ViewController) else {
                completion?()
                return
            }
            viewController.removeAllTabViewItems()
            viewController.setTabViewItems(tabViewItems)
            completion?()
        }
    }
}

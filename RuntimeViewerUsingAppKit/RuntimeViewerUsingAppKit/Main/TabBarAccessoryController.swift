import AppKit
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// Hosts the content tab bar (`TabBar`) as a full-width titlebar accessory
/// below the toolbar (Safari-style). Owned and driven by `MainWindowController`
/// off `MainViewModel` output — a dumb view controller with no business logic,
/// mirroring how `MainToolbarController` hosts the toolbar items.
///
/// Every tab shares the one document-level navigation history; selection /
/// close / creation are surfaced as signals the window controller forwards to
/// `MainViewModel`, which turns them into `SelectionRoute`s.
final class TabBarAccessoryController: NSTitlebarAccessoryViewController {
    private static let topSpacing: CGFloat = 8
    private static let bottomSpacing: CGFloat = 8
    private static let tabBarHeight: CGFloat = 30 + topSpacing + bottomSpacing

    private let tabBar = TabBar().then {
        $0.style = TabBar.SystemStyle.init()
    }

    private let addTabButton = NSButton().then {
        $0.isBordered = false
        $0.bezelStyle = .accessoryBar
        $0.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        $0.imagePosition = .imageOnly
        $0.toolTip = "New Tab"
    }

    private let closeIcon = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))

    /// Current tab rows the data source reads from. The `representedObject`
    /// handed to `TabBar` is the row itself, which carries its tab's
    /// `DocumentTab.id` and so survives a reload that renumbers everything.
    ///
    /// Handing over the row *index* instead would leave `TabBar` unable to
    /// tell one tab from another: closing a middle tab renumbers every row
    /// behind it, so the indices describe a set of tabs that no longer exists
    /// and the control falls back to matching by position — which cannot animate
    /// an insertion into the middle of the strip.
    private var items: [TabBarItem] = []

    /// Guards the selection feedback loop: `selectItemAtIndex(_:)` fires
    /// `tabBarDidChangeSelection`, which must be ignored while applying a
    /// state-driven snapshot.
    private var isApplyingSnapshot = false

    /// Guards against a post-close neighbour selection announced by the tab bar.
    ///
    /// Belt and braces since UIFoundation 0.14: `applySnapshot(_:)` re-selects
    /// from inside `didCloseItem`, and the bar reads that as the host taking
    /// the selection over, so it no longer moves to the *left* neighbour behind
    /// the close route's right-neighbour activation. Forwarding such an event
    /// would emit a spurious `switchTab`. Set on close, cleared on the next
    /// runloop pass — the snapshot itself is delivered synchronously, RxSwift's
    /// `MainScheduler` running inline when it is already on the main thread.
    private var isHandlingClose = false

    // MARK: - Outputs to the window controller

    let tabSelectedRelay = PublishRelay<Int>()
    let tabClosedRelay = PublishRelay<Int>()

    var newTabClicked: Signal<Void> { addTabButton.rx.click.asSignal() }

    // MARK: - Init

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        layoutAttribute = .bottom
        // A bottom accessory is force-sized to AppKit's standard height the
        // moment its view is installed — 36pt under Liquid Glass, 28pt before
        // it. Opting out here (it must happen before the view loads) is what
        // makes the frame set in `viewDidLoad` stick.
        automaticallyAdjustsSize = false
        // Drives the height while the window is in full screen; the frame set in
        // `viewDidLoad` covers every other state.
        fullScreenMinHeight = Self.tabBarHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View

    /// `NSTitlebarAccessoryViewController` vends the root view itself, and sizes
    /// the titlebar slot from that view's *frame* — a height constraint on it is
    /// not an input, it just loses to the required autoresizing constraint AppKit
    /// derives from the frame (and logs a conflict). Assigning the frame once
    /// here is enough: it survives window resizes and `isHidden` cycles.
    override func viewDidLoad() {
        super.viewDidLoad()

        view.frame.size.height = Self.tabBarHeight

        view.hierarchy {
            tabBar
            addTabButton
        }

        addTabButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
            make.width.equalTo(28)
        }

        tabBar.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(Self.topSpacing)
            make.bottom.equalToSuperview().inset(Self.bottomSpacing)
            make.leading.equalToSuperview()
            make.trailing.equalTo(addTabButton.snp.leading)
        }

        tabBar.dataSource = self
        tabBar.delegate = self
    }

    // MARK: - Snapshot

    func applySnapshot(_ snapshot: TabBarSnapshot) {
        // The window controller may drive the first snapshot before the
        // accessory's view (and therefore the TabBar data source) has
        // loaded; force-load so `reloadTabs()` is not a no-op.
        loadViewIfNeeded()
        items = snapshot.items
        isApplyingSnapshot = true
        tabBar.reloadTabs(animated: true)
        if snapshot.activeIndex >= 0, snapshot.activeIndex < items.count {
            tabBar.selectItemAtIndex(snapshot.activeIndex)
        }
        isApplyingSnapshot = false
    }

    private func item(from representedObject: Any) -> (index: Int, model: TabBarItem)? {
        guard let model = representedObject as? TabBarItem,
              let index = items.firstIndex(where: { $0.id == model.id })
        else { return nil }
        return (index, model)
    }
}

// MARK: - TabBar.DataSource

extension TabBarAccessoryController: TabBar.DataSource {
    func tabBarNumberOfTabs(_ tabBar: TabBar) -> Int {
        items.count
    }

    func tabBar(_ tabBar: TabBar, itemAtIndex index: Int) -> Any {
        items[index]
    }

    // Read straight off the represented object rather than looking it back up: the row *is* the item
    // now, and a button still showing a tab that has already left `items` must keep its title until
    // the reload retires it.
    func tabBar(_ tabBar: TabBar, titleForItem item: Any) -> String {
        (item as? TabBarItem)?.title ?? ""
    }

    func tabBar(_ tabBar: TabBar, iconForItem item: Any) -> NSImage? {
        guard let kind = (item as? TabBarItem)?.kind else { return nil }
        return RuntimeObjectIcon.icon(for: kind, size: 16)
    }

    func tabBar(_ tabBar: TabBar, closeIconForItem item: Any) -> NSImage? {
        closeIcon
    }

    func tabBar(_ tabBar: TabBar, closePositionForItem item: Any) -> TabBar.ClosePosition {
        .left
    }
}

// MARK: - TabBar.Delegate

extension TabBarAccessoryController: TabBar.Delegate {
    func tabBar(_ tabBar: TabBar, canSelectItem item: Any) -> Bool {
        true
    }

    func tabBar(_ tabBar: TabBar, canCloseItem item: Any) -> Bool {
        true
    }

    func tabBar(_ tabBar: TabBar, canReorderItem item: Any) -> Bool {
        // Phase 2 — drag reorder maps to `.moveTab`.
        false
    }

    func tabBar(_ tabBar: TabBar, canEditTitleOfItem item: Any) -> Bool {
        false
    }

    func tabBarDidChangeSelection(_ tabBar: TabBar, item: Any?) {
        guard !isApplyingSnapshot, !isHandlingClose, let item, let index = self.item(from: item)?.index else { return }
        tabSelectedRelay.accept(index)
    }

    func tabBar(_ tabBar: TabBar, didCloseItem item: Any) {
        guard let index = self.item(from: item)?.index else { return }
        isHandlingClose = true
        tabClosedRelay.accept(index)
        // Reset asynchronously rather than in `applySnapshot`: if the close
        // route is rejected (stale index) no snapshot comes back, and the flag
        // must not swallow the user's next real tab click.
        DispatchQueue.main.async { [weak self] in
            self?.isHandlingClose = false
        }
    }
}

import AppKit
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// Hosts the content tab bar (`TabsControl`) as a full-width titlebar accessory
/// below the toolbar (Safari-style). Owned and driven by `MainWindowController`
/// off `MainViewModel` output — a dumb view controller with no business logic,
/// mirroring how `MainToolbarController` hosts the toolbar items.
///
/// Every tab shares the one document-level navigation history; selection /
/// close / creation are surfaced as signals the window controller forwards to
/// `MainViewModel`, which turns them into `SelectionRoute`s.
final class TabBarAccessoryController: NSTitlebarAccessoryViewController {
    private static let tabBarHeight: CGFloat = 30

    private let tabsControl = TabsControl().then {
        $0.style = TabsControl.SystemStyle.init()
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
    /// handed to `TabsControl` is the row index into this array; a full reload
    /// on every snapshot keeps indices fresh.
    private var items: [TabBarItem] = []

    /// Guards the selection feedback loop: `selectItemAtIndex(_:)` fires
    /// `tabsControlDidChangeSelection`, which must be ignored while applying a
    /// state-driven snapshot.
    private var isApplyingSnapshot = false

    /// Guards against `TabsControl`'s own post-close neighbour selection.
    /// After `didCloseItem`, `TabsControl.closeTab(_:)` continues in the same
    /// call stack and auto-selects the *left* neighbour, firing
    /// `tabsControlDidChangeSelection` before the state-driven snapshot
    /// arrives (snapshot delivery is async). Forwarding that synthetic event
    /// would emit a spurious `switchTab` that overrides the close route's
    /// right-neighbour activation. Set on close, cleared on the next runloop
    /// pass — the synthetic selection is always synchronous with the close.
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
            tabsControl
            addTabButton
        }

        addTabButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
            make.width.equalTo(28)
        }

        tabsControl.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview()
            make.trailing.equalTo(addTabButton.snp.leading)
        }

        tabsControl.dataSource = self
        tabsControl.delegate = self
    }

    // MARK: - Snapshot

    func applySnapshot(_ snapshot: TabBarSnapshot) {
        // The window controller may drive the first snapshot before the
        // accessory's view (and therefore the TabsControl data source) has
        // loaded; force-load so `reloadTabs()` is not a no-op.
        loadViewIfNeeded()
        items = snapshot.items
        isApplyingSnapshot = true
        tabsControl.reloadTabs()
        if snapshot.activeIndex >= 0, snapshot.activeIndex < items.count {
            tabsControl.selectItemAtIndex(snapshot.activeIndex)
        }
        isApplyingSnapshot = false
    }

    private func item(from representedObject: Any) -> (index: Int, model: TabBarItem)? {
        guard let index = representedObject as? Int, items.indices.contains(index) else { return nil }
        return (index, items[index])
    }
}

// MARK: - TabsControl.DataSource

extension TabBarAccessoryController: TabsControl.DataSource {
    func tabsControlNumberOfTabs(_ control: TabsControl) -> Int {
        items.count
    }

    func tabsControl(_ control: TabsControl, itemAtIndex index: Int) -> Any {
        index
    }

    func tabsControl(_ control: TabsControl, titleForItem item: Any) -> String {
        self.item(from: item)?.model.title ?? ""
    }

    func tabsControl(_ control: TabsControl, iconForItem item: Any) -> NSImage? {
        guard let kind = self.item(from: item)?.model.kind else { return nil }
        return RuntimeObjectIcon.icon(for: kind, size: 16)
    }

    func tabsControl(_ control: TabsControl, closeIconForItem item: Any) -> NSImage? {
        closeIcon
    }

    func tabsControl(_ control: TabsControl, closePositionForItem item: Any) -> TabsControl.ClosePosition {
        .left
    }
}

// MARK: - TabsControl.Delegate

extension TabBarAccessoryController: TabsControl.Delegate {
    func tabsControl(_ control: TabsControl, canSelectItem item: Any) -> Bool {
        true
    }

    func tabsControl(_ control: TabsControl, canCloseItem item: Any) -> Bool {
        true
    }

    func tabsControl(_ control: TabsControl, canReorderItem item: Any) -> Bool {
        // Phase 2 — drag reorder maps to `.moveTab`.
        false
    }

    func tabsControl(_ control: TabsControl, canEditTitleOfItem item: Any) -> Bool {
        false
    }

    func tabsControlDidChangeSelection(_ control: TabsControl, item: Any?) {
        guard !isApplyingSnapshot, !isHandlingClose, let item, let index = self.item(from: item)?.index else { return }
        tabSelectedRelay.accept(index)
    }

    func tabsControl(_ control: TabsControl, didCloseItem item: Any) {
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

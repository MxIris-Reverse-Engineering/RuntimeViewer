import AppKit
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// One editor pane: its tab bar over the content of its active tab, which its own
/// `ContentCoordinator` shows.
///
/// The content runs the whole height of the pane — under the toolbar for a pane at the top, as the
/// content pane always has — and the tab bar floats over it: while the bar shows, the content's safe
/// area grows by the bar's height, so its text starts below the bar and scrolls under it.
final class EditorPaneViewController: BaseViewController<EditorPaneViewModel> {
    static let tabBarHeight: CGFloat = 30

    private let tabBarView = EditorPaneTabBarView()

    private let contentContainerView = NSView()

    private let backgroundClickedRelay = PublishRelay<Void>()

    /// What takes the keyboard focus when the pane takes the focus: the interface on screen, `nil`
    /// on the placeholder of an empty tab.
    var focusableContentView: NSView? {
        let contentNavigationController = children.first as? ContentNavigationController
        return (contentNavigationController?.topViewController as? EditorPaneContent)?.focusableView
    }

    /// Puts the content coordinator's view controller in the pane, once.
    func setContent(_ contentViewController: NSViewController) {
        loadViewIfNeeded()
        addChild(contentViewController)
        contentContainerView.hierarchy {
            contentViewController.view
        }
        contentViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            contentContainerView
            tabBarView
        }

        contentContainerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // Below the toolbar for a pane at the top of the window, at the pane's top otherwise.
        tabBarView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(Self.tabBarHeight)
        }
    }

    /// A click no view inside the pane took — on the placeholder of an empty tab, say — reaches the
    /// pane through the responder chain and gives it the focus. A click in the text never gets here:
    /// the text view takes it, and becoming first responder focuses the pane
    /// (`EditorAreaViewController`).
    override func mouseDown(with event: NSEvent) {
        backgroundClickedRelay.accept(())
        super.mouseDown(with: event)
    }

    override func setupBindings(for viewModel: EditorPaneViewModel) {
        super.setupBindings(for: viewModel)

        let input = EditorPaneViewModel.Input(
            tabSelected: tabBarView.tabSelectedRelay.asSignal(),
            tabClosed: tabBarView.tabClosedRelay.asSignal(),
            closeButtonClicked: tabBarView.closeButton.rx.click.asSignal(),
            backgroundClicked: backgroundClickedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.tabBarSnapshot.driveOnNext { [weak self] snapshot in
            guard let self else { return }
            tabBarView.applySnapshot(snapshot)
        }
        .disposed(by: rx.disposeBag)

        output.isTabBarHidden.driveOnNext { [weak self] isHidden in
            guard let self else { return }
            tabBarView.isHidden = isHidden
            contentContainerView.additionalSafeAreaInsets = NSEdgeInsets(top: isHidden ? 0 : Self.tabBarHeight, left: 0, bottom: 0, right: 0)
        }
        .disposed(by: rx.disposeBag)

        output.isFocused.driveOnNext { [weak self] isFocused in
            guard let self else { return }
            tabBarView.isFocused = isFocused
        }
        .disposed(by: rx.disposeBag)

        output.isCloseButtonHidden.drive(tabBarView.closeButton.rx.isHidden).disposed(by: rx.disposeBag)
    }
}

// MARK: - Tab Bar

/// The pane's tab bar: the button that closes the pane, then the tabs.
///
/// A dumb view: the tabs come in as a `TabBarSnapshot`, and a selection or a close goes out as the
/// tab's `DocumentTab.ID`, which the view model turns into a route.
private final class EditorPaneTabBarView: LayerBackedView, TabBar.DataSource, TabBar.Delegate {
    let closeButton = NSButton().then {
        $0.isBordered = false
        $0.bezelStyle = .accessoryBar
        $0.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Editor Pane")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        $0.imagePosition = .imageOnly
        $0.toolTip = "Close Editor Pane"
    }

    let tabSelectedRelay = PublishRelay<DocumentTab.ID>()

    let tabClosedRelay = PublishRelay<DocumentTab.ID>()

    /// Whether the pane has the focus. A pane without it draws its tabs dimmed.
    var isFocused = true {
        didSet {
            guard isFocused != oldValue else { return }
            tabBar.alphaValue = isFocused ? 1 : Self.unfocusedTabAlpha
        }
    }

    private static let unfocusedTabAlpha: CGFloat = 0.55

    private let tabBar = TabBar().then {
        $0.style = TabBar.SystemStyle.init()
    }

    private let closeIcon = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))

    /// The rows the data source reads. The `representedObject` handed to `TabBar` is the row
    /// itself, which carries its tab's `DocumentTab.id` and so survives a reload that renumbers
    /// every tab behind a closed one.
    private var items: [TabBarItem] = []

    /// Guards the selection feedback loop: `selectItemAtIndex(_:)` announces a selection, which must
    /// be ignored while a snapshot is being applied.
    private var isApplyingSnapshot = false

    /// Guards against a neighbour selection the bar announces itself after a close. Set on close,
    /// cleared on the next pass of the run loop — the snapshot is delivered synchronously, RxSwift's
    /// `MainScheduler` running inline on the main thread. Not cleared in `applySnapshot(_:)`: a
    /// close the router turns down sends no snapshot back, and the user's next click must count.
    private var isHandlingClose = false

    /// A stack, so that the tabs start at the leading edge while the close button is hidden: a
    /// stack view detaches a hidden arranged view, where a hidden view under constraints keeps its place.
    private lazy var contentStackView = HStackView(spacing: 4) {
        closeButton
        tabBar
    }

    override func setup() {
        super.setup()

        backgroundColor = .windowBackgroundColor

        hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.leading.equalToSuperview().inset(4)
        }

        closeButton.snp.makeConstraints { make in
            make.width.equalTo(20)
        }

        tabBar.snp.makeConstraints { make in
            make.height.equalTo(contentStackView)
        }

        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        tabBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tabBar.dataSource = self
        tabBar.delegate = self
    }

    func applySnapshot(_ snapshot: TabBarSnapshot) {
        items = snapshot.items
        isApplyingSnapshot = true
        tabBar.reloadTabs(animated: true)
        if snapshot.activeIndex >= 0, snapshot.activeIndex < items.count {
            tabBar.selectItemAtIndex(snapshot.activeIndex)
        }
        isApplyingSnapshot = false
    }

    private func item(from representedObject: Any) -> TabBarItem? {
        guard let item = representedObject as? TabBarItem, items.contains(where: { $0.id == item.id }) else { return nil }
        return item
    }

    // MARK: TabBar.DataSource

    func tabBarNumberOfTabs(_ tabBar: TabBar) -> Int {
        items.count
    }

    func tabBar(_ tabBar: TabBar, itemAtIndex index: Int) -> Any {
        items[index]
    }

    // Read straight off the represented object: a button still showing a tab that has already left
    // `items` keeps its title until the reload retires it.
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

    // MARK: TabBar.Delegate

    func tabBar(_ tabBar: TabBar, canSelectItem item: Any) -> Bool {
        true
    }

    func tabBar(_ tabBar: TabBar, canCloseItem item: Any) -> Bool {
        true
    }

    func tabBar(_ tabBar: TabBar, canReorderItem item: Any) -> Bool {
        false
    }

    func tabBar(_ tabBar: TabBar, canEditTitleOfItem item: Any) -> Bool {
        false
    }

    func tabBarDidChangeSelection(_ tabBar: TabBar, item: Any?) {
        guard !isApplyingSnapshot, !isHandlingClose, let item, let tabItem = self.item(from: item) else { return }
        tabSelectedRelay.accept(tabItem.id)
    }

    func tabBar(_ tabBar: TabBar, didCloseItem item: Any) {
        guard let tabItem = self.item(from: item) else { return }
        isHandlingClose = true
        tabClosedRelay.accept(tabItem.id)
        DispatchQueue.main.async { [weak self] in
            self?.isHandlingClose = false
        }
    }
}

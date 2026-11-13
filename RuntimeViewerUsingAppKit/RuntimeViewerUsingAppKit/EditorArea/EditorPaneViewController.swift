import AppKit
import AppKitPlus
import RxAppKit
import UIFoundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// One editor pane: its tab bar over the content of its active tab, which its own
/// `ContentCoordinator` shows.
///
/// From macOS 26 on the content runs the whole height of the pane, as Xcode 27.2's editor does
/// (RE notes "Editor panes — visuals" §6): under the toolbar for a pane at the top, and under the
/// tab bar while it shows. The content's safe area grows by the bar's height, so its text starts
/// below the bar, and the bar has no background of its own: it is registered as a container of the
/// top scroll pocket of the content on screen (`ScrollPocketContainerRegistration`), so AppKit's
/// scroll edge effect shows the text scrolled under the toolbar and the bar blurred, as Xcode's bar
/// backing, a scroll pocket of its own, does. The content's scroll view reaches the toolbar, so AppKit
/// registers the toolbar with that pocket itself. The pane follows the content on screen through its
/// `ContentNavigationController`, whose delegate it is.
///
/// Before macOS 26, which has no scroll pockets, the bar is opaque and the content starts at its top
/// edge while it shows.
///
/// The bar's geometry is Xcode 27.2's (`-[IDEEditorBar _contentRectForBoundsWidth:returningTargetHeight:]`,
/// IDEKit 0x146E64; RE notes "Editor panes — visuals" §3): a 28-point row of controls 8 points in from
/// each side, 4 points below it and 4 above — none above in a pane right under the toolbar
/// (`isToolbarAdjacent`) — so 36 points, or 32 in the top row.
final class EditorPaneViewController: BaseViewController<EditorPaneViewModel> {
    static let tabBarRowHeight: CGFloat = 28

    static let tabBarTopPadding: CGFloat = 4

    static let tabBarBottomPadding: CGFloat = 4

    /// The bar's height in this pane, top padding included.
    private var tabBarHeight: CGFloat {
        (isToolbarAdjacent ? 0 : Self.tabBarTopPadding) + Self.tabBarRowHeight + Self.tabBarBottomPadding
    }

    /// Whether the pane's top is under the toolbar — a pane of the layout's top row — which drops the
    /// bar's top padding.
    private var isToolbarAdjacent = false {
        didSet {
            guard isToolbarAdjacent != oldValue else { return }
            updateTabBarLayout()
        }
    }

    private var isTabBarHidden = true {
        didSet {
            guard isTabBarHidden != oldValue else { return }
            updateTabBarLayout()
        }
    }

    private let tabBarView = EditorPaneTabBarView()

    private let contentContainerView = NSView()

    /// Whether the content runs under the tab bar: from macOS 26 on.
    private static var contentRunsUnderTabBar: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// Keeps the tab bar registered with the top scroll pocket of the content on screen while the
    /// bar shows.
    private lazy var tabBarScrollPocketRegistration = ScrollPocketContainerRegistration(containerView: tabBarView, edge: .top)

    /// The content's top edge from macOS 26 on, and before it while the tab bar is hidden: the
    /// pane's own.
    private lazy var contentTopToPaneTopConstraint = contentContainerView.topAnchor.constraint(equalTo: containerView.topAnchor)

    /// The content's top edge before macOS 26 while the tab bar shows: the bar's.
    private lazy var contentTopToTabBarTopConstraint = contentContainerView.topAnchor.constraint(equalTo: tabBarView.topAnchor)

    private let backgroundClickedRelay = PublishRelay<Void>()

    /// What takes the keyboard focus when the pane takes the focus: the interface on screen, `nil`
    /// on the placeholder of an empty tab.
    var focusableContentView: NSView? {
        (contentNavigationController?.topViewController as? EditorPaneContent)?.focusableView
    }

    /// The scroll view of the content on screen, which the tab bar floats over: `nil` on the
    /// placeholder of an empty tab.
    private var contentScrollView: NSScrollView? {
        (contentNavigationController?.topViewController as? EditorPaneContent)?.contentScrollView
    }

    private var contentNavigationController: ContentNavigationController? {
        children.first as? ContentNavigationController
    }

    /// Puts the content coordinator's view controller in the pane, once.
    func setContent(_ contentViewController: NSViewController) {
        loadViewIfNeeded()
        addChild(contentViewController)
        (contentViewController as? ContentNavigationController)?.delegate = self
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

        // The top edge follows the tab bar (`updateTabBarLayout()`).
        contentContainerView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }

        // Below the toolbar for a pane at the top of the window, at the pane's top otherwise.
        tabBarView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(tabBarHeight)
        }
        updateTabBarLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        isToolbarAdjacent = view.safeAreaInsets.top > 0
        // Also kept up to date from the content navigation controller; this pass only catches a
        // content swap that reported nothing.
        updateTabBarScrollPocketRegistration()
    }

    /// The bar's height and padding, where the content starts, the content's safe area under the
    /// bar, and the bar's registration with the content's scroll pocket.
    private func updateTabBarLayout() {
        guard isViewLoaded else { return }
        tabBarView.isHidden = isTabBarHidden
        tabBarView.topPadding = isToolbarAdjacent ? 0 : Self.tabBarTopPadding
        tabBarView.snp.updateConstraints { make in
            make.height.equalTo(tabBarHeight)
        }
        // Off before on: both pin the same edge, and with the bar under the toolbar they disagree.
        if isTabBarHidden || Self.contentRunsUnderTabBar {
            contentTopToTabBarTopConstraint.isActive = false
            contentTopToPaneTopConstraint.isActive = true
        } else {
            contentTopToPaneTopConstraint.isActive = false
            contentTopToTabBarTopConstraint.isActive = true
        }
        contentContainerView.additionalSafeAreaInsets = NSEdgeInsets(top: isTabBarHidden ? 0 : tabBarHeight, left: 0, bottom: 0, right: 0)
        updateTabBarScrollPocketRegistration()
    }

    /// Registers the tab bar with the top scroll pocket of the content on screen while the bar shows,
    /// and with none while it is hidden. Before macOS 26 the registration does nothing.
    private func updateTabBarScrollPocketRegistration() {
        guard isViewLoaded else { return }
        tabBarScrollPocketRegistration.scrollView = isTabBarHidden ? nil : contentScrollView
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

        // Asked as the bar builds each tab's menu, which it does on every reload: the commands
        // depend on the tabs around it.
        tabBarView.commandsProvider = { [weak viewModel] tabID in
            viewModel?.commands(forTab: tabID) ?? []
        }

        let input = EditorPaneViewModel.Input(
            tabSelected: tabBarView.tabSelectedRelay.asSignal(),
            tabClosed: tabBarView.tabClosedRelay.asSignal(),
            closeButtonClicked: tabBarView.closeButton.rx.click.asSignal(),
            backgroundClicked: backgroundClickedRelay.asSignal(),
            tabCommandChosen: tabBarView.tabCommandChosenRelay.asSignal(),
            tabsReordered: tabBarView.tabsReorderedRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.tabBarSnapshot.driveOnNext { [weak self] snapshot in
            guard let self else { return }
            tabBarView.applySnapshot(snapshot)
        }
        .disposed(by: rx.disposeBag)

        output.isTabBarHidden.driveOnNext { [weak self] isHidden in
            guard let self else { return }
            isTabBarHidden = isHidden
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

// MARK: - NSNavigationControllerDelegate

extension EditorPaneViewController: NSNavigationControllerDelegate {
    /// The content of the active tab changed, or the pane's content first appeared: the tab bar
    /// follows it to its scroll view.
    func navigationController(_ navigationController: NSNavigationController, didShow viewController: NSViewController) {
        updateTabBarScrollPocketRegistration()
    }
}

// MARK: - Tab Bar

/// The pane's tab bar: the button that closes the pane, then the tabs, in a 28-point row 8 points in
/// from each side of its safe area, `topPadding` below its top.
///
/// From macOS 26 on it draws no background: it is a bar in the content's top scroll pocket, which
/// draws what is under it, and it answers `_scrollPocketElementStyle` as Xcode's bars do. Before
/// macOS 26 it is opaque.
///
/// A dumb view: the tabs come in as a `TabBarSnapshot`, and a selection or a close goes out as the
/// tab's `DocumentTab.ID`, which the view model turns into a route.
private final class EditorPaneTabBarView: LayerBackedView, TabBar.DataSource, TabBar.Delegate {
    /// Xcode's close-pane button: `xmark`, 23 points wide in the row (`-[IDEEditorSplittingController
    /// initWithEditorContext:]`, IDEKit 27.2 0x1416F0), with Xcode's tooltip and accessibility label.
    let closeButton = NSButton().then {
        $0.isBordered = false
        $0.bezelStyle = .accessoryBar
        $0.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Editor Pane")
        $0.imagePosition = .imageOnly
        $0.toolTip = "Close this Editor Pane"
        $0.setAccessibilityLabel("Close Editor Pane")
    }

    /// The space above the row, which the pane sets: none in a pane right under the toolbar.
    var topPadding: CGFloat = EditorPaneViewController.tabBarTopPadding {
        didSet {
            guard topPadding != oldValue else { return }
            contentStackView.snp.updateConstraints { make in
                make.top.equalToSuperview().offset(topPadding)
            }
        }
    }

    private static let rowHorizontalInset: CGFloat = 8

    private static let closeButtonWidth: CGFloat = 23

    let tabSelectedRelay = PublishRelay<DocumentTab.ID>()

    let tabClosedRelay = PublishRelay<DocumentTab.ID>()

    /// A command chosen in a tab's context menu.
    let tabCommandChosenRelay = PublishRelay<(command: EditorTabCommand, tabID: DocumentTab.ID)>()

    /// The tabs in the order a drag left them.
    let tabsReorderedRelay = PublishRelay<[DocumentTab.ID]>()

    /// What a tab's context menu offers, asked as the bar builds the menu (`EditorPaneViewModel.commands(forTab:)`).
    var commandsProvider: ((DocumentTab.ID) -> [EditorTabCommand])?

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
    ///
    /// `.fill`, which stretches the tabs, the view hugging least, over the rest of the row. An
    /// `HStackView` on AppKit defaults to NSStackView's `.gravityAreas`, which stretches nothing: the
    /// bar kept its fitting width, a few points, and drew only the empty capsule of its track.
    private lazy var contentStackView = HStackView(distribution: .fill, spacing: 4) {
        closeButton
        tabBar
    }

    @available(macOS 26.0, *)
    override var _scrollPocketElementStyle: Int {
        NSView.barScrollPocketElementStyle
    }

    override func setup() {
        super.setup()

        if #unavailable(macOS 26.0) {
            backgroundColor = .windowBackgroundColor
        }

        hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(topPadding)
            make.height.equalTo(EditorPaneViewController.tabBarRowHeight)
            make.leading.trailing.equalTo(safeAreaLayoutGuide).inset(Self.rowHorizontalInset)
        }

        closeButton.snp.makeConstraints { make in
            make.width.equalTo(Self.closeButtonWidth)
            make.height.equalTo(EditorPaneViewController.tabBarRowHeight)
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
        switch (item as? TabBarItem)?.icon {
        case .object(let kind)?:
            RuntimeObjectIcon.icon(for: kind, size: 16)
        case .image?:
            RuntimeImageNode.imageIcon
        case nil:
            nil
        }
    }

    func tabBar(_ tabBar: TabBar, closeIconForItem item: Any) -> NSImage? {
        closeIcon
    }

    func tabBar(_ tabBar: TabBar, closePositionForItem item: Any) -> TabBar.ClosePosition {
        .left
    }

    /// The tab's right-click menu. The bar builds it as it reloads, so it is rebuilt with every
    /// snapshot, which is when the tabs around it can change.
    func tabBar(_ tabBar: TabBar, menuForItem item: Any) -> NSMenu? {
        guard let tabItem = self.item(from: item), let commands = commandsProvider?(tabItem.id), !commands.isEmpty else { return nil }
        let menu = NSMenu()
        for command in commands {
            let menuItem = NSMenuItem(title: command.menuTitle, action: #selector(tabCommandMenuItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.image = command.menuImage
            menuItem.representedObject = EditorTabCommandMenuItemPayload(command: command, tabID: tabItem.id)
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func tabCommandMenuItemChosen(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? EditorTabCommandMenuItemPayload else { return }
        tabCommandChosenRelay.accept((payload.command, payload.tabID))
    }

    // MARK: TabBar.Delegate

    func tabBar(_ tabBar: TabBar, canSelectItem item: Any) -> Bool {
        true
    }

    func tabBar(_ tabBar: TabBar, canCloseItem item: Any) -> Bool {
        true
    }

    func tabBar(_ tabBar: TabBar, canReorderItem item: Any) -> Bool {
        true
    }

    /// A drag left the tabs in a new order. The rows follow at once, so a reload before the
    /// snapshot comes back does not put the tab back where it was; the view model works out which
    /// tab moved.
    func tabBar(_ tabBar: TabBar, didReorderItems reorderedItems: [Any]) {
        let reorderedTabItems = reorderedItems.compactMap { $0 as? TabBarItem }
        guard reorderedTabItems.count == items.count else { return }
        items = reorderedTabItems
        tabsReorderedRelay.accept(reorderedTabItems.map(\.id))
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

/// What a tab's menu item carries to its action.
private struct EditorTabCommandMenuItemPayload {
    let command: EditorTabCommand
    let tabID: DocumentTab.ID
}

extension EditorTabCommand {
    /// Xcode's titles for the closing commands; the object commands keep the title they have in
    /// every other menu.
    fileprivate var menuTitle: String {
        switch self {
        case .close: "Close Tab"
        case .closeOthers: "Close Other Tabs"
        case .closeToTheRight: "Close Tabs to the Right"
        case .runtimeObjectAction(let action): action.menuTitle
        }
    }

    fileprivate var menuImage: NSImage? {
        switch self {
        case .close, .closeOthers, .closeToTheRight: nil
        case .runtimeObjectAction(let action): action.menuImage
        }
    }
}

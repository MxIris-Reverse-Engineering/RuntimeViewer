import AppKit
import AppKitPlus
import RxAppKit
import UIFoundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// One editor pane: its tab bar and jump bar over the content of its active tab, which its own
/// `ContentCoordinator` shows.
///
/// From macOS 26 on the content runs the whole height of the pane, as Xcode 27.2's editor does
/// (RE notes "Editor panes — visuals" §6): under the toolbar for a pane at the top, and under the
/// bars while they show. The content's safe area grows by the bars' height, so its text starts
/// below them. What scrolls under a bar shows through the bar's own scroll edge effect, whose
/// capture view lies behind the content; under the toolbar, through the one the editor area lays
/// over all its panes (`ToolbarScrollPocketContainerView`). The content's own scroll pockets, which
/// AppKit gives every scroll view reaching the toolbar, lie behind all of them, in a backdrop group
/// of the pane's own: in the window's shared one they were drawn from a capture taken before the
/// next pane.
///
/// Before macOS 26, which has no scroll pockets, the bars are opaque and the content starts at the
/// first one's top edge.
///
/// The bar's geometry is Xcode 27.2's (`-[IDEEditorBar _contentRectForBoundsWidth:returningTargetHeight:]`,
/// IDEKit 0x146E64; RE notes "Editor panes — visuals" §3): a 28-point row of controls 8 points in from
/// each side, 4 points below it and 4 above — none above in a pane right under the toolbar
/// (`isToolbarAdjacent`) — so 36 points, or 32 in the top row.
///
/// Under the tab bar — or in its place while it is hidden — is the pane's jump bar (proposal
/// `editor-jump-bar`; RE notes "Editor jump bar"): the same row, with a 1-point border under it, so
/// 33 points, or 37 in a pane further down without a tab bar. Its row sits midway between its top
/// and its border, or right under the tab bar's row and its 4 points (`EditorPaneBarMetrics`, which
/// holds both bars' numbers). It shows only while the active tab shows something.
final class EditorPaneViewController: BaseViewController<EditorPaneViewModel> {
    /// Both bars' heights and the jump bar's row, from what the pane shows and where it is.
    private var barMetrics: EditorPaneBarMetrics {
        EditorPaneBarMetrics(isToolbarAdjacent: isToolbarAdjacent, isTabBarHidden: isTabBarHidden, isJumpBarHidden: isJumpBarHidden)
    }

    /// Whether the pane's top is under the toolbar — a pane of the layout's top row — which drops the
    /// bar's top padding.
    private var isToolbarAdjacent = false {
        didSet {
            guard isToolbarAdjacent != oldValue else { return }
            updateBarLayout()
        }
    }

    private var isTabBarHidden = true {
        didSet {
            guard isTabBarHidden != oldValue else { return }
            updateBarLayout()
        }
    }

    /// Whether the jump bar is hidden: the active tab shows nothing.
    private var isJumpBarHidden = true {
        didSet {
            guard isJumpBarHidden != oldValue else { return }
            updateBarLayout()
        }
    }

    private let tabBarView = EditorPaneTabBarView()

    private let jumpBarView = EditorPaneJumpBarView()

    /// The document's jump bar items, which the coordinator hands every pane before it binds it.
    var jumpBarItemStore: EditorJumpBarItemStore?

    private var jumpBarAdapter: EditorJumpBarAdapter?

    private let contentContainerView = NSView()

    /// Whether the content runs under the bars: from macOS 26 on.
    private static var contentRunsUnderTabBar: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// The content's top edge from macOS 26 on: the pane's own.
    private lazy var contentTopToPaneTopConstraint = contentContainerView.topAnchor.constraint(equalTo: containerView.topAnchor)

    /// The content's top edge before macOS 26: the first bar's, the bars being opaque there.
    private lazy var contentTopToTabBarTopConstraint = contentContainerView.topAnchor.constraint(equalTo: tabBarView.topAnchor)

    private let backgroundClickedRelay = PublishRelay<Void>()

    /// What takes the keyboard focus when the pane takes the focus: the interface on screen, `nil`
    /// on the placeholder of an empty tab.
    var focusableContentView: NSView? {
        (contentNavigationController?.topViewController as? EditorPaneContent)?.focusableView
    }

    private var contentNavigationController: ContentNavigationController? {
        children.first as? ContentNavigationController
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
            jumpBarView
        }

        // Behind the content, over each bar: the bar's edge effect replays the background from it.
        let barScrollPocketCaptureViews: [(barView: NSView, scrollPocketCaptureView: NSView?)] = [
            (tabBarView, tabBarView.scrollPocketCaptureView),
            (jumpBarView, jumpBarView.scrollPocketCaptureView),
        ]
        for (barView, scrollPocketCaptureView) in barScrollPocketCaptureViews {
            guard let scrollPocketCaptureView else { continue }
            containerView.addSubview(scrollPocketCaptureView, positioned: .below, relativeTo: contentContainerView)
            scrollPocketCaptureView.snp.makeConstraints { make in
                make.edges.equalTo(barView)
            }
        }

        // A backdrop group of the pane's own for the content's scroll pockets, which every pane's
        // would otherwise share with the window (`ToolbarScrollPocketContainerView`).
        contentContainerView.box.titlebarBackdropGroupName = "EditorPane-\(UUID().uuidString)"

        // The top edge follows the bars (`updateBarLayout()`).
        contentContainerView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }

        // Below the toolbar for a pane at the top of the window, at the pane's top otherwise.
        tabBarView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(barMetrics.tabBarHeight)
        }

        // Under the tab bar while it shows, in its place otherwise.
        jumpBarView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(barMetrics.jumpBarTopOffset)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(barMetrics.jumpBarHeight)
        }
        updateBarLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        isToolbarAdjacent = view.safeAreaInsets.top > 0
    }

    /// Which bars show, their heights and paddings, where the content starts, the content's safe
    /// area under the bars, and where the close button sits.
    private func updateBarLayout() {
        guard isViewLoaded else { return }
        let metrics = barMetrics
        tabBarView.isHidden = isTabBarHidden
        tabBarView.scrollPocketCaptureView?.isHidden = isTabBarHidden
        tabBarView.topPadding = metrics.tabBarTopPadding
        tabBarView.snp.updateConstraints { make in
            make.height.equalTo(metrics.tabBarHeight)
        }
        jumpBarView.isHidden = isJumpBarHidden
        jumpBarView.scrollPocketCaptureView?.isHidden = isJumpBarHidden
        jumpBarView.topPadding = metrics.jumpBarTopPadding
        jumpBarView.snp.updateConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(metrics.jumpBarTopOffset)
            make.height.equalTo(metrics.jumpBarHeight)
        }
        updateCloseButtonPlacement()
        // Off before on: both pin the same edge, and with the bar under the toolbar they disagree.
        if Self.contentRunsUnderTabBar {
            contentTopToTabBarTopConstraint.isActive = false
            contentTopToPaneTopConstraint.isActive = true
        } else {
            contentTopToPaneTopConstraint.isActive = false
            contentTopToTabBarTopConstraint.isActive = true
        }
        contentContainerView.additionalSafeAreaInsets = NSEdgeInsets(top: metrics.barsHeight, left: 0, bottom: 0, right: 0)
    }

    /// Whether the pane can be closed — there is another pane — which shows its close button.
    private var isCloseButtonHidden = true {
        didSet {
            guard isCloseButtonHidden != oldValue else { return }
            updateCloseButtonPlacement()
        }
    }

    /// The close button sits in the tab bar while that shows, and at the start of the jump bar
    /// otherwise, as in Xcode 27.2 (RE notes "Editor panes" §7). With both bars hidden — a tab that
    /// shows nothing, in a pane beside others that have one tab each — the pane shows no close
    /// button; Close Editor Pane in the menu still closes it.
    private func updateCloseButtonPlacement() {
        guard isViewLoaded else { return }
        tabBarView.closeButton.isHidden = isCloseButtonHidden
        jumpBarView.showsCloseButton = !isCloseButtonHidden && isTabBarHidden
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

        // The document's items, shared by its panes; made once per pane, as the path control is.
        if jumpBarAdapter == nil, let jumpBarItemStore {
            jumpBarAdapter = EditorJumpBarAdapter(pathControl: jumpBarView.pathControl, itemStore: jumpBarItemStore)
        }

        let input = EditorPaneViewModel.Input(
            tabSelected: tabBarView.tabSelectedRelay.asSignal(),
            tabClosed: tabBarView.tabClosedRelay.asSignal(),
            closeButtonClicked: Signal.merge(tabBarView.closeButton.rx.click.asSignal(), jumpBarView.closeButton.rx.click.asSignal()),
            backgroundClicked: backgroundClickedRelay.asSignal(),
            tabCommandChosen: tabBarView.tabCommandChosenRelay.asSignal(),
            tabsReordered: tabBarView.tabsReorderedRelay.asSignal(),
            jumpBarChoiceSelected: jumpBarAdapter?.choiceSelected ?? .empty()
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
            jumpBarAdapter?.isPaneFocused = isFocused
        }
        .disposed(by: rx.disposeBag)

        output.isCloseButtonHidden.driveOnNext { [weak self] isHidden in
            guard let self else { return }
            isCloseButtonHidden = isHidden
        }
        .disposed(by: rx.disposeBag)

        output.jumpBarLocation.driveOnNext { [weak self] location in
            guard let self else { return }
            jumpBarAdapter?.show(location)
        }
        .disposed(by: rx.disposeBag)

        output.isJumpBarHidden.driveOnNext { [weak self] isHidden in
            guard let self else { return }
            isJumpBarHidden = isHidden
        }
        .disposed(by: rx.disposeBag)
    }
}

// MARK: - Tab Bar

/// The pane's tab bar: the button that closes the pane, then the tabs, in a 28-point row 8 points in
/// from each side of its safe area, `topPadding` below its top.
///
/// From macOS 26 on its background is a scroll edge effect of its own, as Xcode's editor bars have:
/// the content under the bar blurred under a near-opaque replay of the background. Before macOS 26 it
/// is opaque.
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
    var topPadding: CGFloat = EditorPaneBarMetrics.padding {
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

    /// The edge effect behind the bar from macOS 26 on: Xcode's editor bar background, a
    /// `DVTEdgeOcclusionView` hosting a hard scroll pocket (`-[IDEEditorBar
    /// initWithCenterItem:showBottomBorder:]`, IDEKit 27.2 0x145EC0; RE notes "Editor panes — visuals" §6).
    private let scrollPocketView: ScrollPocketView? = {
        if #available(macOS 26.0, *) { ScrollPocketView(edge: .top) } else { nil }
    }()

    /// The capture view of the edge effect behind the bar, which the pane puts behind its content, over
    /// the bar: the effect replays the background from it. `nil` before macOS 26.
    var scrollPocketCaptureView: NSView? {
        scrollPocketView?.captureView
    }

    override func setup() {
        super.setup()

        if #unavailable(macOS 26.0) {
            backgroundColor = .windowBackgroundColor
        }

        if let scrollPocketView {
            addSubview(scrollPocketView)
            scrollPocketView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(topPadding)
            make.height.equalTo(EditorPaneBarMetrics.rowHeight)
            make.leading.trailing.equalTo(safeAreaLayoutGuide).inset(Self.rowHorizontalInset)
        }

        closeButton.snp.makeConstraints { make in
            make.width.equalTo(Self.closeButtonWidth)
            make.height.equalTo(EditorPaneBarMetrics.rowHeight)
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

// MARK: - Jump Bar

/// The pane's jump bar row (proposal `editor-jump-bar`), as Xcode 27.2's editor draws it
/// (`/Volumes/RE/Xcode/27.2-27B52/README.md`, "Editor jump bar"): a 28-point row `topPadding` below
/// its top and 8 points in from each side of its safe area — the close button and a separator
/// first while the tab bar is hidden and there is another pane, then the path control at its own
/// width, which it gives up as the row narrows — and a 1-point border along the bottom. The pane
/// sets the bar's height and `topPadding` (`EditorPaneBarMetrics`), which put the row midway between
/// the top and the border unless the tab bar is right above it.
///
/// From macOS 26 on its background is a scroll edge effect of its own, as the tab bar's is: the
/// content under the bar blurred under a near-opaque replay of the background. Before macOS 26 it
/// is opaque.
private final class EditorPaneJumpBarView: LayerBackedView {
    /// Xcode's close-pane button, the tab bar's twin: the jump bar holds it while the tab bar is
    /// hidden.
    let closeButton = NSButton().then {
        $0.isBordered = false
        $0.bezelStyle = .accessoryBar
        $0.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Editor Pane")
        $0.imagePosition = .imageOnly
        $0.toolTip = "Close this Editor Pane"
        $0.setAccessibilityLabel("Close Editor Pane")
    }

    /// Small, as Xcode's: its font is the small system font, which the control sets itself.
    let pathControl = NSPopUpPathControl().then {
        $0.controlSize = .small
        $0.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// The space above the row: none under the tab bar, half of what the row leaves above the
    /// border otherwise (`EditorPaneBarMetrics.jumpBarTopPadding`).
    var topPadding: CGFloat = EditorPaneBarMetrics.padding {
        didSet {
            guard topPadding != oldValue else { return }
            rowStackView.snp.updateConstraints { make in
                make.top.equalToSuperview().offset(topPadding)
            }
        }
    }

    var showsCloseButton = false {
        didSet {
            closeButton.isHidden = !showsCloseButton
            separatorView.isHidden = !showsCloseButton
        }
    }

    private static let rowHorizontalInset: CGFloat = 8

    private static let closeButtonWidth: CGFloat = 23

    /// Black or white at 10 % (55.7 % and 49.8 % with Increase Contrast), Xcode's
    /// `vibrantDividerColor`.
    private static let borderColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua?:
            NSColor.white.withAlphaComponent(0.10)
        case .accessibilityHighContrastAqua?:
            NSColor.black.withAlphaComponent(0.557)
        case .accessibilityHighContrastDarkAqua?:
            NSColor.white.withAlphaComponent(0.498)
        default:
            NSColor.black.withAlphaComponent(0.10)
        }
    }

    private let separatorView = SeparatorView()

    private let borderView = LayerBackedView()

    /// A stack, so that the path control moves to the row's start while the close button is
    /// hidden: a stack view detaches a hidden arranged view.
    private lazy var rowStackView = HStackView(spacing: 0) {
        closeButton
        separatorView
        pathControl
    }

    /// The edge effect behind the bar from macOS 26 on, the same as the tab bar's.
    private let scrollPocketView: ScrollPocketView? = {
        if #available(macOS 26.0, *) { ScrollPocketView(edge: .top) } else { nil }
    }()

    /// The capture view of the edge effect behind the bar, which the pane puts behind its content, over
    /// the bar: the effect replays the background from it. `nil` before macOS 26.
    var scrollPocketCaptureView: NSView? {
        scrollPocketView?.captureView
    }

    override func setup() {
        super.setup()

        if #unavailable(macOS 26.0) {
            backgroundColor = .windowBackgroundColor
        }

        if let scrollPocketView {
            addSubview(scrollPocketView)
            scrollPocketView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        hierarchy {
            rowStackView
            borderView
        }

        rowStackView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(topPadding)
            make.height.equalTo(EditorPaneBarMetrics.rowHeight)
            make.leading.equalTo(safeAreaLayoutGuide).inset(Self.rowHorizontalInset)
            make.trailing.lessThanOrEqualTo(safeAreaLayoutGuide).inset(Self.rowHorizontalInset)
        }

        closeButton.snp.makeConstraints { make in
            make.width.equalTo(Self.closeButtonWidth)
            make.height.equalTo(EditorPaneBarMetrics.rowHeight)
        }

        pathControl.snp.makeConstraints { make in
            make.height.equalTo(EditorPaneBarMetrics.rowHeight)
        }

        borderView.snp.makeConstraints { make in
            make.bottom.equalToSuperview()
            make.height.equalTo(EditorPaneBarMetrics.jumpBarBorderWidth)
            make.leading.trailing.equalTo(safeAreaLayoutGuide)
        }

        borderView.backgroundColor = Self.borderColor
        closeButton.isHidden = true
        separatorView.isHidden = true
    }

    /// The separator after the close button: a 1 × 12 line with rounded ends, centred in a slot 9
    /// points wide — 4 points of margin on each side — and 21 high, as Xcode's
    /// `DVTBarSeparatorView` is. The line's colour approximates Xcode's `contentDividerColor`, whose
    /// value the RE notes do not give.
    private final class SeparatorView: LayerBackedView {
        private let lineView = LayerBackedView()

        override var intrinsicContentSize: NSSize {
            NSSize(width: 9, height: 21)
        }

        override func setup() {
            super.setup()

            hierarchy {
                lineView
            }

            lineView.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalTo(1)
                make.height.equalTo(12)
            }

            lineView.cornerRadius = 0.5
            lineView.backgroundColor = .separatorColor
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

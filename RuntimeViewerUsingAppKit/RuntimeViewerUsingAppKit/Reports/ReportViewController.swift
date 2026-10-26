import AppKit
import AppKitPlus
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SFSymbols
import SnapKit

/// The Report navigator page, laid out after Xcode 26's — proposal `0030-report-navigator`.
/// Like Xcode's: one source-list outline of 24-point rows, the kinds of work as first-level rows,
/// each piece of work under its kind with a spinner while it runs; and the filter bar at the
/// bottom with an actions menu and a filter field whose clock toggle keeps only the work in
/// progress. Unlike Xcode's, selecting a row opens nothing: the reports have no page of their own.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both bind the
/// document's coordinators through their own `ReportViewModel`.
final class ReportViewController<Route: Routable>: BaseEffectViewController<ReportViewModel<Route>>, NSMenuDelegate {
    // MARK: - Relays

    /// The actions menu and the context menu are built on demand, so their items report here.
    private let cancelRelay = PublishRelay<ReportNode>()

    private let cancelAllRelay = PublishRelay<Void>()

    private let clearHistoryRelay = PublishRelay<Void>()

    private let openSettingsRelay = PublishRelay<Void>()

    // MARK: - Outline

    private let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    private let emptyLabel = Label("No Reports")

    // MARK: - Filter Bar

    /// The line between the list and the filter bar; `nil` from macOS 26, where the rows fade out under the bar instead.
    private let bottomSeparatorView = HorizontalSeparatorView.makeForStackedNavigatorLayout()

    /// Built once; its items are enabled from the view model's output, since the bar shows the menu as it is.
    private let actionsMenu = NSMenu()

    private let cancelAllMenuItem = NSMenuItem(title: "Cancel All", action: nil, keyEquivalent: "")

    private let clearHistoryMenuItem = NSMenuItem(title: "Clear History", action: nil, keyEquivalent: "")

    private lazy var actionsItem = NSFilterControlBarItem(image: SFSymbols(systemName: .ellipsisCircle).nsuiImgae, menu: actionsMenu)

    private let filterSearchField = NSFilterSearchField()

    private var showsOnlyInProgressButton: NSButton!

    private let filterControlBar = NavigatorFilterControlBar()

    /// Runs the list under the tab switcher's bar and the filter bar from macOS 26 on. Made in
    /// `viewDidLoad`.
    private var navigatorScrollViewLayout: NavigatorScrollViewLayout?

    /// The tab switcher's bar while this page is on screen under it (`NavigatorTabPage`).
    var tabSwitcherOverlayViews: [NSView] = [] {
        didSet {
            navigatorScrollViewLayout?.inheritedTopOverlayViews = tabSwitcherOverlayViews
        }
    }

    /// From macOS 26 the list reaches the top of the page, under the toolbar and the tab switcher's
    /// bar; its content inset keeps the rows clear of them instead.
    override var containerViewUsingSafeArea: Bool {
        if #available(macOS 26.0, *) {
            false
        } else {
            true
        }
    }

    /// The outline takes keyboard focus when the sidebar shows this page, like the other sidebar
    /// lists — see `SidebarRootViewController.preferredFirstResponder`.
    override var preferredFirstResponder: NSResponder? {
        outlineView.window != nil ? outlineView : nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        showsOnlyInProgressButton = filterSearchField.addFilterButton(
            with: .symbol(systemName: .clock),
            alternateImage: .symbol(systemName: .clockFill),
            toolTip: "Show only reports in progress",
            accessibilityLabel: "Reports in Progress"
        )

        containerView.hierarchy {
            scrollView
            emptyLabel
            if let bottomSeparatorView {
                bottomSeparatorView
            }
            filterControlBar
        }

        scrollView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            if let bottomSeparatorView {
                make.bottom.equalTo(bottomSeparatorView.snp.top)
            } else {
                // Under the filter bar as well, which floats over the list's bottom edge.
                make.bottom.equalToSuperview()
            }
        }

        // Centred in what the bars leave of the list, which is all of it before macOS 26.
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView.safeAreaLayoutGuide)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }

        bottomSeparatorView?.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
            make.bottom.equalTo(filterControlBar.snp.top)
        }

        // The bar's intrinsic height carries the margins around the field.
        filterControlBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }

        navigatorScrollViewLayout = NavigatorScrollViewLayout(scrollView: scrollView, bottomOverlayViews: [filterControlBar])
        navigatorScrollViewLayout?.inheritedTopOverlayViews = tabSwitcherOverlayViews

        emptyLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .center
            $0.isHidden = true
        }

        scrollView.do {
            $0.borderType = .noBorder
            $0.drawsBackground = false
            $0.hasVerticalScroller = true
            $0.hasHorizontalScroller = false
            $0.autohidesScrollers = true
            $0.hidesVisualEffectView = true
        }

        outlineView.do {
            $0.style = .sourceList
            $0.indentationPerLevel = 14
            $0.indentationMarkerFollowsCell = true
            $0.intercellSpacing = NSSize(width: 3, height: 0)
            $0.rowHeight = 24
            $0.usesAutomaticRowHeights = false
            $0.floatsGroupRows = true
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.allowsTypeSelect = true
            // The newest work is inserted at the top; the highlight stays on the row it was on.
            $0.preservesSelectedItemAcrossReloads = true
            $0.headerView = nil
            $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            $0.menu = NSMenu().then {
                $0.delegate = self
            }
        }

        cancelAllMenuItem.do {
            $0.target = self
            $0.action = #selector(cancelAllMenuItemAction(_:))
            $0.image = SFSymbols(systemName: .xmarkCircle).nsImage
            $0.isEnabled = false
        }

        clearHistoryMenuItem.do {
            $0.target = self
            $0.action = #selector(clearHistoryMenuItemAction(_:))
            $0.image = SFSymbols(systemName: .trash).nsImage
            $0.isEnabled = false
        }

        actionsMenu.do { menu in
            menu.autoenablesItems = false
            // Item 0 is the face of the pull-down the bar pops the menu up as; the open menu lists the items after it.
            menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
            menu.addItem(cancelAllMenuItem)
            menu.addItem(clearHistoryMenuItem)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Open Settings…", action: #selector(openSettingsMenuItemAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.image = SFSymbols(systemName: .gearshape).nsImage
            }
        }

        actionsItem.do {
            $0.title = "Report Actions"
            $0.toolTip = "Report Actions"
        }

        filterSearchField.toolTip = "Show reports with matching name"

        // The bar sizes the field and the item together; it sets the field's control size, so the size goes here.
        filterControlBar.do {
            $0.filterField = filterSearchField
            $0.leadingItems = [actionsItem]
            $0.controlSize = .large
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ReportViewModel<Route>) {
        super.setupBindings(for: viewModel)

        let input = ReportViewModel<Route>.Input(
            // Before the page is drawn, so the tree it shows is already current.
            isVisible: Observable.merge(rx.viewWillAppear.map { true }, rx.viewWillDisappear.map { false })
                .asDriver(onErrorJustReturn: false)
                .startWith(false),
            cancel: cancelRelay.asSignal(),
            cancelAll: cancelAllRelay.asSignal(),
            clearHistory: clearHistoryRelay.asSignal(),
            openSettings: openSettingsRelay.asSignal(),
            doubleClickedNode: outlineView.rx.modelDoubleClicked().asSignal(),
            filter: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: "").map { NavigatorTextFilter(typedText: $0) },
            showsOnlyInProgress: showsOnlyInProgressButton.rx.state.asDriver().map { $0 == .on }.startWith(false)
        )
        let output = viewModel.transform(input)

        output.nodes.drive(outlineView.rx.nodes(options: []))({ (outlineView: NSOutlineView, _: NSTableColumn?, node: ReportNode) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: ReportCellView.self)
            cellView.bind(to: node.cellViewModel)
            return cellView
        }, { outlineView, _ -> NSTableRowView? in
            if #available(macOS 26.0, *) {
                return outlineView.box.makeView(ofClass: SidebarTableRowView.self)
            } else {
                return nil
            }
        })
        .disposed(by: rx.disposeBag)

        // Subscribed after the nodes binding, so the adapter has reloaded by the time this runs.
        // Each row is opened at most once, the first time it appears, as Xcode opens its newest
        // builds; what the user collapses stays collapsed.
        output.nodesToExpand.driveOnNext { [weak self] nodes in
            guard let self else { return }
            for node in nodes {
                outlineView.expandItem(node)
            }
        }
        .disposed(by: rx.disposeBag)

        // Every row opens while the filter bar narrows the outline, and the user's own expansion
        // and selection come back when it stops — the sidebar's behaviour.
        output.filteringChanged.emitOnNext { [weak self] isFiltering in
            guard let self else { return }
            if isFiltering {
                outlineView.beginFiltering()
            } else {
                outlineView.endFiltering()
            }
        }
        .disposed(by: rx.disposeBag)

        output.isEmpty.driveOnNext { [weak self] isEmpty in
            guard let self else { return }
            emptyLabel.isHidden = !isEmpty
            scrollView.isHidden = isEmpty
        }
        .disposed(by: rx.disposeBag)

        output.hasCancellableWork.driveOnNext { [weak self] hasCancellableWork in
            guard let self else { return }
            cancelAllMenuItem.isEnabled = hasCancellableWork
        }
        .disposed(by: rx.disposeBag)

        output.hasHistory.driveOnNext { [weak self] hasHistory in
            guard let self else { return }
            clearHistoryMenuItem.isEnabled = hasHistory
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Actions

    @objc private func cancelAllMenuItemAction(_ sender: NSMenuItem) {
        cancelAllRelay.accept(())
    }

    @objc private func clearHistoryMenuItemAction(_ sender: NSMenuItem) {
        clearHistoryRelay.accept(())
    }

    @objc private func openSettingsMenuItemAction(_ sender: NSMenuItem) {
        openSettingsRelay.accept(())
    }

    @objc private func cancelMenuItemAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode else { return }
        cancelRelay.accept(node)
    }

    // MARK: - Context Menu

    /// Built when it opens, for the clicked row: Cancel while that work can still be withdrawn,
    /// Open Settings on a feature's "turned off" row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outlineView.clickedRow >= 0, let node = outlineView.item(atRow: outlineView.clickedRow) as? ReportNode else { return }
        if node.cellViewModel.isCancellable {
            menu.addItem(withTitle: "Cancel", action: #selector(cancelMenuItemAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.representedObject = node
                $0.image = SFSymbols(systemName: .xmarkCircle).nsImage
            }
        }
        if case .turnedOff = node.identifier {
            menu.addItem(withTitle: "Open Settings…", action: #selector(openSettingsMenuItemAction(_:)), keyEquivalent: "").then {
                $0.target = self
                $0.image = SFSymbols(systemName: .gearshape).nsImage
            }
        }
    }
}

extension ReportViewController: NavigatorTabPage {}

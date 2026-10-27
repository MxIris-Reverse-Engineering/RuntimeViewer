import AppKit
import AppKitPlus
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SFSymbols
import SnapKit

/// The Find navigator page, laid out to the measurements of Xcode 26's — proposal
/// `0029-find-navigator` §4.1. Four blocks, top to bottom: the query parameters (three
/// 24-point rows: the mode path and the case toggle, the search field, the scope — and in
/// Members mode the member kinds), the summary bar (22 points, only while there are results), the
/// results outline, and the 44-point filter bar at the bottom.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both bind
/// the document's one `FindSession` through their own `FindViewModel`, and the scope chooser is
/// presented by whichever level the page is on.
final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewController<FindViewModel<Route>>, NSOutlineViewDelegate {
    
    // MARK: - Relays

    /// What the outline shows. Its data source subscribes to this relay, so the presentation's
    /// subscriber hands the nodes over synchronously and can expand and select rows right after.
    private let displayedNodesRelay = PublishRelay<[FindResultNode]>()

    // MARK: - Query Parameters

    /// Taken for a bar by the results' top scroll pocket, as Xcode's query parameters view is
    /// (`DVTStackViewWithScrollPocketElementStyleBar` in `IDEFindNavigatorQueryParametersController.nib`).
    private let queryParametersView = ScrollPocketBarView()

    private let modePathControl = NSPopUpPathControl()

    /// Puts the view model's mode path on `modePathControl` and reports the choices made in it.
    private lazy var modePathControlAdapter = FindModePathControlAdapter(pathControl: modePathControl)

    private let caseSensitiveButton = NSButton()

    /// Xcode's find field: text with find patterns among it, which a search sends as a regular
    /// expression. Read with `findPatternComponents`; `stringValue` holds U+FFFC for each token.
    private let searchField = NSFindPatternSearchField()

    /// Builds the search field's menu — Insert Pattern and the recent queries — each time it opens.
    private lazy var searchFieldMenuAdapter = FindQueryFieldMenuAdapter(queryField: searchField)

    private let scopeButton = FindScopeButton()

    private let memberKindPopUpButton = PopUpButton()

    // MARK: - Summary Bar

    /// Taken for a bar by the results' top scroll pocket, as Xcode's summary row is
    /// (`NSViewWithScrollPocketElementStyleBar` in `IDEFindNavigator.nib`).
    private let summaryView = ScrollPocketBarView()

    private let summaryLabel = Label()

    /// The line below the summary; `nil` from macOS 26, where the results fade out under the summary instead.
    private let summarySeparatorView = HorizontalSeparatorView.makeForStackedNavigatorLayout()

    private var summaryHeightConstraint: Constraint?

    // MARK: - Results

    private let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    /// The line above the results; `nil` from macOS 26, where they run under the views above them instead.
    private let resultsTopSeparatorView = HorizontalSeparatorView.makeForStackedNavigatorLayout()

    /// The rows' context menu, rebuilt from the clicked row each time it opens. A click on empty
    /// space, or on a row that goes nowhere, gets no items, so AppKit shows no menu at all.
    private let contextMenu = NSMenu()

    // MARK: - Filter Bar

    /// The line between the results and the filter bar; `nil` from macOS 26, where the results fade out under the bar
    /// instead.
    private let filterSeparatorView = HorizontalSeparatorView.makeForStackedNavigatorLayout()

    private let filterField = NSFilterTokenField()

    /// Configures `filterField` and reports its filter, with recent filters of its own. The results are lines of code,
    /// so a comma stays in the text instead of ending a token.
    private lazy var filterFieldAdapter = NavigatorTextFilterFieldAdapter(filterField: filterField, recentFiltersGroup: .findResults, endsTokensAtCommas: false)

    private let filterControlBar = NavigatorFilterControlBar()

    /// Show Runtime Calls, on the bar's trailing side while the mode is Callees. An item has no
    /// state of its own: it shows on in the accent colour.
    private let runtimeHelperCallsToggle = FindFilterBarToggle(
        image: SFSymbols(systemName: .memorychip).nsuiImgae,
        activeImage: SFSymbols(systemName: .memorychip).paletteColors([.controlAccentColor]).nsuiImgae,
        toolTip: "Show Runtime Calls"
    )

    /// Runs the results under the query area, the tab switcher's bar and the filter bar from macOS 26
    /// on. Made in `viewDidLoad`.
    private var navigatorScrollViewLayout: NavigatorScrollViewLayout?

    /// The tab switcher's bar while this page is on screen under it (`NavigatorTabPage`).
    var tabSwitcherOverlayViews: [NSView] = [] {
        didSet {
            navigatorScrollViewLayout?.inheritedTopOverlayViews = tabSwitcherOverlayViews
        }
    }

    /// From macOS 26 the results reach the top of the page, under the toolbar, the tab switcher's bar
    /// and the query area, which float over them as Xcode's do (`-[IDEFindNavigator viewDidLoad]`
    /// registers the query parameters and the summary row with the results' top scroll pocket); the
    /// results' content inset keeps the rows clear of them instead.
    override var containerViewUsingSafeArea: Bool {
        if #available(macOS 26.0, *) {
            false
        } else {
            true
        }
    }

    /// The outline takes keyboard focus when the sidebar shows this page, like the other
    /// sidebar lists — see `SidebarRootViewController.preferredFirstResponder`.
    override var preferredFirstResponder: NSResponder? {
        outlineView.window != nil ? outlineView : nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // The results first: from macOS 26 everything else floats over them, so it has to be drawn and
        // hit-tested above them.
        containerView.hierarchy {
            scrollView
            queryParametersView.hierarchy {
                modePathControl
                caseSensitiveButton
                searchField
                scopeButton
                memberKindPopUpButton
            }
            summaryView.hierarchy {
                summaryLabel
                if let summarySeparatorView {
                    summarySeparatorView
                }
            }
            if let resultsTopSeparatorView {
                resultsTopSeparatorView
            }
            if let filterSeparatorView {
                filterSeparatorView
            }
            filterControlBar
        }

        queryParametersView.snp.makeConstraints { make in
            if #available(macOS 26.0, *) {
                // Below the toolbar and the tab switcher's bar by the gap every page starts below its
                // switcher. Before macOS 26 the switcher leaves that gap above the page itself.
                make.top.equalTo(containerView.safeAreaLayoutGuide).offset(TabViewController.pageTopSpacing)
            } else {
                make.top.equalToSuperview()
            }
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(72)
        }

        // Row 1 (y 0–24): the mode path at (3, 0), W − 39 wide, and the case toggle, 21×16, at the
        // trailing edge, level with the path. Xcode puts both 3 points lower; here the gap above them
        // is the one every page starts below its switcher (`TabViewController.pageTopSpacing`).
        modePathControl.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.equalToSuperview().offset(3)
            make.trailing.equalTo(caseSensitiveButton.snp.leading).offset(-7)
            make.height.equalTo(17)
        }

        caseSensitiveButton.snp.makeConstraints { make in
            make.top.equalTo(modePathControl)
            make.trailing.equalToSuperview().inset(8)
            make.width.equalTo(21)
            make.height.equalTo(16)
        }

        // Row 2 (y 24–48): the search field at (7, 1) inside its row, 22 points tall.
        searchField.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(25)
            make.leading.trailing.equalToSuperview().inset(8)
            make.height.equalTo(22)
        }

        scopeButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(53)
            make.leading.equalToSuperview().offset(8)
            make.height.equalTo(15)
            make.trailing.lessThanOrEqualTo(memberKindPopUpButton.snp.leading).offset(-8)
        }

        memberKindPopUpButton.snp.makeConstraints { make in
            make.centerY.equalTo(scopeButton)
            make.trailing.equalToSuperview().inset(8)
            make.height.equalTo(15)
        }

        summaryView.snp.makeConstraints { make in
            make.top.equalTo(queryParametersView.snp.bottom)
            make.leading.trailing.equalToSuperview()
            summaryHeightConstraint = make.height.equalTo(0).constraint
        }

        summaryLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(10)
            make.top.equalToSuperview().offset(4)
            make.height.equalTo(14)
        }

        summarySeparatorView?.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1)
        }

        resultsTopSeparatorView?.snp.makeConstraints { make in
            make.top.equalTo(summaryView.snp.bottom)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }

        // The separators exist in the stacked layout only, before macOS 26.
        scrollView.snp.makeConstraints { make in
            if let resultsTopSeparatorView, let filterSeparatorView {
                make.top.equalTo(resultsTopSeparatorView.snp.bottom)
                make.leading.trailing.equalToSuperview()
                make.bottom.equalTo(filterSeparatorView.snp.top)
            } else {
                make.edges.equalToSuperview()
            }
        }

        filterSeparatorView?.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(filterControlBar.snp.top)
            make.height.equalTo(1)
        }

        // The filter bar: under the macOS 26 design, 44 points with its large field 28 points tall, as Xcode's.
        filterControlBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }

        // Its horizontal compression resistance is already low: the path is what gives way.
        modePathControl.controlSize = .small

        caseSensitiveButton.do {
            $0.title = "Aa"
            $0.toolTip = "Case Sensitive"
            $0.setButtonType(.pushOnPushOff)
            $0.bezelStyle = .smallSquare
            $0.isBordered = false
            $0.font = .systemFont(ofSize: 11)
            $0.alignment = .center
        }

        searchField.do {
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            // Xcode's field here, `IDEProgressSearchField`, is a `DVTSearchField` showing the
            // magnifying glass rather than the filter icon; its spinner is the field's `progress`.
            $0.usesFilterAppearance = false
            // Return searches; typing does not, and neither does inserting a pattern, as in Xcode.
            $0.sendsWholeSearchString = true
            $0.sendsSearchStringImmediately = false
            $0.searchesImmediatelyAfterInsertingPattern = false
            // AppKit's recent searches keep `stringValue` and lose the patterns; the field's menu
            // lists the document's own.
            $0.maximumRecents = 0
        }

        scopeButton.do {
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            $0.bezelStyle = .regularSquare
            $0.isBordered = false
            $0.menu?.font = .systemFont(ofSize: 11)
            $0.setScopeTitle(FindScope.allIndexedImages.title, isAccented: false)
            // A long scope title gives way to the member kinds.
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        memberKindPopUpButton.do {
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            $0.bezelStyle = .regularSquare
            $0.isBordered = false
            $0.pullsDown = false
            $0.addItems(withTitles: FindMemberKindFilter.allCases.map(\.title))
            $0.menu?.font = .systemFont(ofSize: 11)
            $0.toolTip = "Member Kind"
            $0.isHidden = true
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .parameterTextColor
            $0.alignment = .center
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        navigatorScrollViewLayout = NavigatorScrollViewLayout(
            scrollView: scrollView,
            topOverlayViews: [queryParametersView, summaryView],
            bottomOverlayViews: [filterControlBar]
        )
        navigatorScrollViewLayout?.inheritedTopOverlayViews = tabSwitcherOverlayViews

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
            $0.rowHeight = 17
            $0.usesAutomaticRowHeights = true
            $0.floatsGroupRows = true
            $0.allowsMultipleSelection = true
            $0.allowsEmptySelection = true
            $0.allowsTypeSelect = true
            $0.headerView = nil
            $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            $0.menu = contextMenu
        }

        // The bar sets the field's control size, which sets its font, so the field's own settings come after it.
        filterControlBar.do {
            $0.filterField = filterField
            $0.controlSize = .large
        }

        filterField.do {
            $0.placeholderString = "Filter"
            $0.toolTip = "Show results with matching text"
        }

        setSummary(nil)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: FindViewModel<Route>) {
        super.setupBindings(for: viewModel)

        // What the user chose: one row, by click, arrow key or type-select — never a reload, the
        // selection the page puts back after one, or a selection of several rows. Type-select
        // reports every keystroke, so that path waits for the typing to settle, as the sidebar's
        // does; ⌥ opens the row in a new tab.
        let userActivation = outlineView.rx.userActivatedItem(FindResultNode.self)
        let activation: Signal<OutlineViewUserActivation<FindResultNode>> = .merge(
            userActivation
                .filter { !FindResultActivation.isTypeSelect($0.triggeringEvent) }
                .asSignal(onErrorSignalWith: .empty()),
            userActivation
                .filter { FindResultActivation.isTypeSelect($0.triggeringEvent) }
                .debounce(.milliseconds(800), scheduler: MainScheduler.instance)
                .asSignal(onErrorSignalWith: .empty())
        )
        let resultClicked: Signal<FindResultNode> = activation
            .filter { !FindResultActivation.opensInNewTab(for: $0.triggeringEvent) }
            .map(\.item)
        let resultOpenedWithOption: Signal<FindResultNode> = activation
            .filter { FindResultActivation.opensInNewTab(for: $0.triggeringEvent) }
            .map(\.item)

        // Xcode's result rows offer Find Call Hierarchy first (`NavigatorContextualMenu` in
        // IDEKit's plug-in data); the commands of the other cross-reference modes follow it.
        let contextMenuItems: Observable<[FindResultMenuItem]> = contextMenu.rx.needsUpdate
            .asObservable()
            .map { [weak outlineView] _ -> [FindResultMenuItem] in
                guard let outlineView,
                      outlineView.clickedRow >= 0,
                      let node = outlineView.item(atRow: outlineView.clickedRow) as? FindResultNode
                else { return [] }
                var items = node.crossReferenceModes.map { mode in
                    FindResultMenuItem(title: "Find \(mode.title)", image: nil, node: node, action: .crossReference(mode))
                }
                if node.canOpenInNewTab {
                    items.append(FindResultMenuItem(title: "Open in New Tab", image: SFSymbols(systemName: .plusSquareOnSquare).nsImage, node: node, action: .openInNewTab))
                }
                return items
            }
        contextMenu.rx.items(source: contextMenuItems)({ menuItem, entry in
            menuItem.image = entry.image
        })
        .disposed(by: rx.disposeBag)
        let contextMenuItemSelected = contextMenu.rx.itemSelected(FindResultMenuItem.self)
            .map(\.item)
            .asSignal(onErrorSignalWith: .empty())
        let resultOpenedFromMenu: Signal<FindResultNode> = contextMenuItemSelected
            .filter { $0.action == .openInNewTab }
            .map(\.node)
        let crossReferenceCommandSelected: Signal<FindCrossReferenceCommand> = contextMenuItemSelected
            .compactMap { menuItem in
                guard case .crossReference(let mode) = menuItem.action else { return nil }
                return FindCrossReferenceCommand(node: menuItem.node, mode: mode)
            }

        let resultsSelected: Signal<[FindResultNode]> = outlineView.rx.proposedSelection()
            .asSignal()
            .map { [weak outlineView] proposedSelection in
                guard let outlineView else { return [] }
                return proposedSelection.indexes.compactMap { row in outlineView.item(atRow: row) as? FindResultNode }
            }
        let resultCollapsed: Signal<FindResultNode> = NotificationCenter.default.rx
            .notification(NSOutlineView.itemDidCollapseNotification, object: outlineView)
            .compactMap { notification in notification.userInfo?["NSObject"] as? FindResultNode }
            .asSignal(onErrorSignalWith: .empty())
        let resultExpanded: Signal<FindResultNode> = NotificationCenter.default.rx
            .notification(NSOutlineView.itemDidExpandNotification, object: outlineView)
            .compactMap { notification in notification.userInfo?["NSObject"] as? FindResultNode }
            .asSignal(onErrorSignalWith: .empty())

        // Only what the user picks: the pop-up's own selection when it is bound would overwrite
        // a kind chosen on the other sidebar level's page.
        let memberKindFilterSelected: Signal<FindMemberKindFilter> = memberKindPopUpButton.rx
            .click(with: \.indexOfSelectedItem)
            .asSignal()
            .compactMap { index in
                FindMemberKindFilter.allCases.indices.contains(index) ? FindMemberKindFilter.allCases[index] : nil
            }

        let scopeMenuChoiceSelected: Signal<FindScopeMenuChoice> = scopeButton.rx
            .click(with: \.selectedItem)
            .asSignal()
            .compactMap { $0?.representedObject as? FindScopeMenuChoice }

        let input = FindViewModel<Route>.Input(
            modePathChoiceSelected: modePathControlAdapter.choiceSelected,
            memberKindFilterSelected: memberKindFilterSelected,
            // A click, read when it happens. `rx.state` carries an initial value under some
            // overloads, and the page bound second would write its default into the session
            // both pages share.
            caseSensitiveToggled: caseSensitiveButton.rx.click(with: \.state).asSignal().map { $0 == .on },
            scopeMenuChoiceSelected: scopeMenuChoiceSelected,
            searchCommitted: searchField.rx.controlEvent.asSignal().map { [searchField] in FindQueryTerm(components: searchField.findPatternComponents) },
            recentQuerySelected: searchFieldMenuAdapter.recentQuerySelected,
            clearRecentQueriesSelected: searchFieldMenuAdapter.clearRecentQueriesSelected,
            filter: filterFieldAdapter.filter.asDriver(onErrorDriveWith: .empty()),
            resultClicked: resultClicked,
            resultOpenedInNewTab: .merge(resultOpenedFromMenu, resultOpenedWithOption),
            resultCollapsed: resultCollapsed,
            resultExpanded: resultExpanded,
            resultsSelected: resultsSelected,
            crossReferenceCommandSelected: crossReferenceCommandSelected,
            runtimeHelperCallsToggled: runtimeHelperCallsToggle.clicked
                .map { [weak runtimeHelperCallsToggle] in !(runtimeHelperCallsToggle?.isActive ?? false) }
                .asSignal(onErrorSignalWith: .empty())
        )
        let output = viewModel.transform(input)

        output.modePath.driveOnNext { [weak self] modePath in
            guard let self else { return }
            modePathControlAdapter.show(modePath)
        }
        .disposed(by: rx.disposeBag)

        output.query.driveOnNext { [weak self] query in
            guard let self else { return }
            let caseState: NSControl.StateValue = query.isCaseSensitive ? .on : .off
            if caseSensitiveButton.state != caseState {
                caseSensitiveButton.state = caseState
            }
            // `-[IDEFindNavigatorQueryParametersController refreshUserInterface:]`: on, the title
            // turns bold and takes the accent colour; off, it is regular and untinted.
            caseSensitiveButton.font = query.isCaseSensitive ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
            caseSensitiveButton.contentTintColor = query.isCaseSensitive ? .controlAccentColor : nil
            if searchField.findPatternComponents != query.term.components, searchField.currentEditor() == nil {
                searchField.findPatternComponents = query.term.components
            }
            memberKindPopUpButton.isHidden = !query.mode.hasMemberKinds
            if let kindIndex = FindMemberKindFilter.allCases.firstIndex(of: query.memberKindFilter), memberKindPopUpButton.indexOfSelectedItem != kindIndex {
                memberKindPopUpButton.selectItem(at: kindIndex)
            }
        }
        .disposed(by: rx.disposeBag)

        Driver.combineLatest(output.scopeTitle, output.isScopeAccented).driveOnNext { [weak self] title, isAccented in
            guard let self else { return }
            scopeButton.setScopeTitle(title, isAccented: isAccented)
        }
        .disposed(by: rx.disposeBag)

        output.scopeToolTip.drive(scopeButton.rx.toolTip).disposed(by: rx.disposeBag)

        output.searchFieldPlaceholder
            .distinctUntilChanged()
            .map { Optional($0) }
            .drive(searchField.rx.placeholderString)
            .disposed(by: rx.disposeBag)

        output.allowsPatternInsertion.driveOnNext { [weak self] allowsPatternInsertion in
            guard let self else { return }
            searchField.allowsPatternInsertion = allowsPatternInsertion
        }
        .disposed(by: rx.disposeBag)

        output.recentQueries.driveOnNext { [weak self] recentQueries in
            guard let self else { return }
            searchFieldMenuAdapter.recentQueries = recentQueries
        }
        .disposed(by: rx.disposeBag)

        output.scopeMenuItems.driveOnNext { [weak self] menuItems in
            guard let self else { return }
            scopeButton.menuItems = menuItems
        }
        .disposed(by: rx.disposeBag)

        outlineView.rx.nodes(source: displayedNodesRelay, options: .diffable)({ (outlineView: NSOutlineView, _: NSTableColumn?, node: FindResultNode) -> NSView? in
            let cellView = outlineView.box.makeView(ofClass: FindResultCellView.self)
            cellView.configure(with: node.appearance)
            return cellView
        }, { outlineView, _ -> NSTableRowView? in
            if #available(macOS 26.0, *) {
                return outlineView.box.makeView(ofClass: SidebarTableRowView.self)
            } else {
                return nil
            }
        })
        .disposed(by: rx.disposeBag)

        // One pass per update, in this order: the data source takes the nodes — synchronously,
        // through the relay — then the rows are expanded and the user's selection is put back.
        // Nodes compare by identifier, so a batch that only appends types is inserted without
        // touching the rows on screen, and a reload keeps every row the user left expanded.
        output.presentation.driveOnNext { [weak self] presentation in
            guard let self else { return }
            displayedNodesRelay.accept(presentation.nodes)
            presentation.apply(to: outlineView)
        }
        .disposed(by: rx.disposeBag)

        outlineView.rx.setDelegate(self).disposed(by: rx.disposeBag)

        output.summary.driveOnNext { [weak self] summary in
            guard let self else { return }
            setSummary(summary)
        }
        .disposed(by: rx.disposeBag)

        output.isSearching.driveOnNext { [weak self] isSearching in
            guard let self else { return }
            searchField.progress = isSearching ? NSFilterFieldProgressIndeterminate : NSFilterFieldProgressNone
        }
        .disposed(by: rx.disposeBag)

        output.focusSearchField.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(searchField)
        }
        .disposed(by: rx.disposeBag)

        // Off for a tree that loads its rows as they are expanded, as Xcode's is; the filter
        // stays, and applies again to the next search that can be filtered.
        output.isFilterEnabled.driveOnNext { [weak self] isFilterEnabled in
            guard let self else { return }
            filterField.isEnabled = isFilterEnabled
        }
        .disposed(by: rx.disposeBag)

        output.isScopeEnabled.drive(scopeButton.rx.isEnabled).disposed(by: rx.disposeBag)

        output.isRuntimeHelperCallsToggleShown.driveOnNext { [weak self] isShown in
            guard let self else { return }
            filterControlBar.trailingItems = isShown ? [runtimeHelperCallsToggle.item] : []
        }
        .disposed(by: rx.disposeBag)

        output.showsRuntimeHelperCalls.driveOnNext { [weak self] showsRuntimeHelperCalls in
            guard let self else { return }
            runtimeHelperCallsToggle.isActive = showsRuntimeHelperCalls
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Type Select

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FindResultNode)?.typeSelectString
    }

    // MARK: - Summary

    private func setSummary(_ summary: String?) {
        summaryLabel.stringValue = summary ?? ""
        summaryView.isHidden = summary == nil
        summaryHeightConstraint?.update(offset: summary == nil ? 0 : 22)
    }
}

extension FindViewController: NavigatorTabPage {}

// MARK: - Context Menu Item

/// One entry of the results' context menu, carrying the row it acts on.
///
/// Declared outside the generic view controller: a type nested in a generic class is generic
/// itself.
private struct FindResultMenuItem: RxMenuItemRepresentable {
    enum Action: Equatable {
        case openInNewTab
        /// Find Call Hierarchy, Find Callees or Find Type References.
        case crossReference(FindMode)
    }

    let title: String
    let image: NSImage?
    let node: FindResultNode
    let action: Action
}

// MARK: - Filter Bar Toggle

/// An item of the filter bar that switches something on and off, showing on in the accent
/// colour: a bar item has no state of its own, and no `rx` accessor either, so it reports its
/// presses through `clicked`.
///
/// Declared outside the generic view controller, which an `@objc` target cannot be nested in.
private final class FindFilterBarToggle: NSObject {
    private(set) var item: NSFilterControlBarItem!

    private let image: NSImage

    private let activeImage: NSImage

    let clicked = PublishRelay<Void>()

    var isActive = false {
        didSet {
            item.image = isActive ? activeImage : image
        }
    }

    init(image: NSImage, activeImage: NSImage, toolTip: String) {
        self.image = image
        self.activeImage = activeImage
        super.init()
        item = NSFilterControlBarItem(image: image, target: self, action: #selector(itemPressed(_:)))
        item.toolTip = toolTip
        item.title = toolTip
    }

    @objc private func itemPressed(_ sender: Any?) {
        clicked.accept(())
    }
}

// MARK: - Scope Button

/// The scope row's button: Xcode's borderless pop-up, to the measurements of §4.1, set up as
/// `-[IDEFindNavigatorQueryParametersController viewDidLoad]` sets up its own. The cell shows an
/// item of its own instead of the checked one (`usesItemFromMenu` off), so the title is always the
/// scope, `In Foundation`, whichever item the menu checks. The menu is rebuilt from `menuItems`
/// each time it opens, as `scopePopUpWillPopUp` rebuilds Xcode's — a menu rebuilt while open would
/// change under the pointer as results arrive. A choice sends the button's action, with the chosen
/// item selected.
///
/// Declared outside the generic view controller: a view nested in a generic class is generic
/// itself.
private final class FindScopeButton: PopUpButton {
    /// The menu to show the next time it opens.
    var menuItems: [FindScopeMenuItem] = []

    /// Initialised before `super.init`, so `setup()` — which the superclass's initialisers
    /// call — can hand it to the cell.
    private let titleItem = NSMenuItem()

    override func setup() {
        super.setup()
        (cell as? NSPopUpButtonCell)?.do {
            $0.usesItemFromMenu = false
            $0.menuItem = titleItem
        }
        // The enabled state is the item's own: Current Find Results needs results, the current
        // image an image in the sidebar.
        menu?.autoenablesItems = false
        NotificationCenter.default.addObserver(self, selector: #selector(willPopUp(_:)), name: NSPopUpButton.willPopUpNotification, object: self)
    }

    /// `In Foundation`, in the button's font, and in the accent colour for a scope other than the
    /// default — `-[IDEFindNavigatorQueryParametersController attributedStringForTitle:control:accented:]`.
    func setScopeTitle(_ title: String, isAccented: Bool) {
        titleItem.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 11),
            .foregroundColor: isAccented ? NSColor.controlAccentColor : NSColor.controlTextColor,
        ])
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    @objc private func willPopUp(_ notification: Notification) {
        removeAllItems()
        var checkedItem: NSMenuItem?
        for menuItem in menuItems {
            if menuItem.isPrecededBySeparator {
                menu?.addItem(.separator())
            }
            // Added through the button, so a choice sends its action.
            addItem(withTitle: menuItem.title)
            guard let item = lastItem else { continue }
            item.representedObject = menuItem.choice
            item.isEnabled = menuItem.isEnabled
            if menuItem.isChecked {
                checkedItem = item
            }
        }
        // A scope picked in the chooser has no item: nothing is checked then.
        select(checkedItem)
    }
}

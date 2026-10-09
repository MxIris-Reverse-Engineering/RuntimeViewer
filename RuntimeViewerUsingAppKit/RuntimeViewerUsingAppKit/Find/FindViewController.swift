import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SFSymbols
import SnapKit

/// The Find navigator page, laid out to the measurements of Xcode 26's — proposal
/// `draft-find-navigator` §4.1. Four blocks, top to bottom: the query parameters (three
/// 24-point rows: the mode path and the case toggle, the search field, the scope — and in
/// Members mode the member kinds), the summary bar (22 points, only while there are results), the
/// results outline, and the 44-point filter bar at the bottom.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both bind
/// the document's one `FindSession` through their own `FindViewModel`, and the scope chooser is
/// presented by whichever level the page is on.
final class FindViewController<Route: FindNavigatorRoutable>: BaseEffectViewController<FindViewModel<Route>>, NSOutlineViewDelegate {
    // MARK: - Relays

    private let openInNewTabRelay = PublishRelay<FindResultNode>()

    /// What the outline shows. Its data source subscribes to this relay, so the presentation's
    /// subscriber hands the nodes over synchronously and can expand and select rows right after.
    private let displayedNodesRelay = PublishRelay<[FindResultNode]>()

    // MARK: - Query Parameters

    private let queryParametersView = NSView()

    private let modePathControl = PopUpPathControl()

    private let caseSensitiveButton = NSButton()

    private let searchField = NSSearchField()

    private let searchProgressIndicator = NSProgressIndicator()

    private let scopeButton = FindScopeButton()

    private let memberKindPopUpButton = NSPopUpButton()

    // MARK: - Summary Bar

    private let summaryView = NSView()

    private let summaryLabel = Label()

    private let summarySeparatorView = NSBox()

    private var summaryHeightConstraint: Constraint?

    // MARK: - Results

    private let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    private let resultsTopSeparatorView = NSBox()

    // MARK: - Filter Bar

    private let filterSeparatorView = NSBox()

    private let filterSearchField = FilterSearchField()

    override var containerViewUsingSafeArea: Bool { true }

    /// The outline takes keyboard focus when the sidebar shows this page, like the other
    /// sidebar lists — see `SidebarRootViewController.preferredFirstResponder`.
    override var preferredFirstResponder: NSResponder? {
        outlineView.window != nil ? outlineView : nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            queryParametersView.hierarchy {
                modePathControl
                caseSensitiveButton
                searchField
                searchProgressIndicator
                scopeButton
                memberKindPopUpButton
            }
            summaryView.hierarchy {
                summaryLabel
                summarySeparatorView
            }
            resultsTopSeparatorView
            scrollView
            filterSeparatorView
            filterSearchField
        }

        queryParametersView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(72)
        }

        // Row 1 (y 0–24): the mode path at (3, 3), W − 39 wide, the case toggle 21×16 at the
        // trailing edge.
        modePathControl.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(3)
            make.leading.equalToSuperview().offset(3)
            make.trailing.equalTo(caseSensitiveButton.snp.leading).offset(-7)
            make.height.equalTo(17)
        }

        caseSensitiveButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(3)
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

        searchProgressIndicator.snp.makeConstraints { make in
            make.centerY.equalTo(searchField)
            make.trailing.equalTo(searchField).inset(24)
            make.size.equalTo(14)
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

        summarySeparatorView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1)
        }

        resultsTopSeparatorView.snp.makeConstraints { make in
            make.top.equalTo(summaryView.snp.bottom)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(resultsTopSeparatorView.snp.bottom)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(filterSeparatorView.snp.top)
        }

        // The filter bar: 44 points, its field 28 points tall with 8-point margins.
        filterSeparatorView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(filterSearchField.snp.top).offset(-8)
            make.height.equalTo(1)
        }

        filterSearchField.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalToSuperview().inset(8)
            make.height.equalTo(28)
        }

        modePathControl.do {
            $0.controlSize = .small
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

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
            // Return searches; typing does not, as in Xcode.
            $0.sendsWholeSearchString = true
            $0.sendsSearchStringImmediately = false
            $0.maximumRecents = 0
        }

        searchProgressIndicator.do {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isDisplayedWhenStopped = false
            $0.isIndeterminate = true
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

        for separatorView in [summarySeparatorView, resultsTopSeparatorView, filterSeparatorView] {
            separatorView.boxType = .separator
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
            $0.rowHeight = 17
            $0.usesAutomaticRowHeights = true
            $0.floatsGroupRows = true
            $0.allowsMultipleSelection = true
            $0.allowsEmptySelection = true
            $0.allowsTypeSelect = true
            $0.headerView = nil
            $0.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            $0.menu = NSMenu().then {
                $0.addItem(withTitle: "Open in New Tab", action: #selector(openInNewTabMenuItemAction(_:)), keyEquivalent: "").then {
                    $0.image = SFSymbols(systemName: .plusSquareOnSquare).nsImage
                    $0.target = self
                }
            }
        }

        filterSearchField.do {
            $0.controlSize = .large
            $0.font = .systemFont(ofSize: 13)
            $0.placeholderString = "Filter"
            $0.toolTip = "Show results with matching text"
            $0.sendsWholeSearchString = false
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

        let modePathChoiceSelected: Signal<FindModePathChoice> = modePathControl.rx
            .click(with: \.lastSelection)
            .asSignal()
            .compactMap { $0?.value as? FindModePathChoice }

        let scopeMenuChoiceSelected: Signal<FindScopeMenuChoice> = scopeButton.rx
            .click(with: \.selectedItem)
            .asSignal()
            .compactMap { $0?.representedObject as? FindScopeMenuChoice }

        let input = FindViewModel<Route>.Input(
            modePathChoiceSelected: modePathChoiceSelected,
            memberKindFilterSelected: memberKindFilterSelected,
            caseSensitiveToggled: caseSensitiveButton.rx.state.asSignal().map { $0 == .on },
            scopeMenuChoiceSelected: scopeMenuChoiceSelected,
            searchCommitted: searchField.rx.controlEvent.asSignal().map { [searchField] in searchField.stringValue },
            filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
            resultClicked: resultClicked,
            resultOpenedInNewTab: .merge(openInNewTabRelay.asSignal(), resultOpenedWithOption),
            resultCollapsed: resultCollapsed,
            resultExpanded: resultExpanded,
            resultsSelected: resultsSelected
        )
        let output = viewModel.transform(input)

        output.modePath.driveOnNext { [weak self] modePath in
            guard let self else { return }
            modePathControl.components = modePath.map(\.pathControlComponent)
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
            if searchField.stringValue != query.text, searchField.currentEditor() == nil {
                searchField.stringValue = query.text
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
            self?.setSummary(summary)
        }
        .disposed(by: rx.disposeBag)

        output.isSearching.driveOnNext { [weak self] isSearching in
            guard let self else { return }
            if isSearching {
                searchProgressIndicator.startAnimation(nil)
            } else {
                searchProgressIndicator.stopAnimation(nil)
            }
        }
        .disposed(by: rx.disposeBag)

        output.focusSearchField.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(searchField)
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

    // MARK: - Context Menu

    @objc private func openInNewTabMenuItemAction(_ sender: NSMenuItem) {
        guard outlineView.hasValidClickedRow, let node = outlineView.itemAtClickedRow as? FindResultNode else { return }
        openInNewTabRelay.accept(node)
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
private final class FindScopeButton: NSPopUpButton {
    /// The menu to show the next time it opens.
    var menuItems: [FindScopeMenuItem] = []

    private let titleItem = NSMenuItem()

    convenience init() {
        self.init(frame: .zero, pullsDown: false)
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
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

// MARK: - Mode Path

extension FindModePathComponent {
    /// The component as the mode path control draws it: an accented choice takes the accent
    /// colour, and each menu item carries the choice it makes.
    fileprivate var pathControlComponent: PopUpPathControl.Component {
        PopUpPathControl.Component(
            title: title,
            titleColor: isAccented ? .controlAccentColor : nil,
            value: choice.map(AnyHashable.init),
            menuItems: menuChoices.map { menuChoice in
                PopUpPathControl.MenuItem(title: menuChoice.title, value: menuChoice, isPrecededBySeparator: menuChoice.isPrecededBySeparator)
            }
        )
    }
}

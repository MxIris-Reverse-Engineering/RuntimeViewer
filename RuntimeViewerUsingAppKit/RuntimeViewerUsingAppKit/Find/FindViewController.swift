import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SFSymbols
import SnapKit

/// The Find navigator page, laid out to the measurements of Xcode 26's — proposal
/// `draft-find-navigator` §4.1. Four blocks, top to bottom: the query parameters (three
/// 24-point rows: the mode path and the case toggle, the search field, the scope), the summary
/// bar (22 points, only while there are results), the results outline, and the 44-point filter
/// bar at the bottom.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both bind
/// the document's one `FindSession` through their own `FindViewModel`.
final class FindViewController<Route: Routable>: BaseEffectViewController<FindViewModel<Route>> {
    // MARK: - Relays

    /// The mode path control is not an `NSControl` RxAppKit wraps, and each of its components
    /// opens its own menu, so its clicks are aggregated here.
    private let modeSelectedRelay = PublishRelay<FindMode>()

    private let textMatchStyleSelectedRelay = PublishRelay<FindTextMatchStyle>()

    private let memberKindFilterSelectedRelay = PublishRelay<FindMemberKindFilter>()

    private let openInNewTabRelay = PublishRelay<FindResultNode>()

    // MARK: - Query Parameters

    private let queryParametersView = NSView()

    private let modePathControl = NSPathControl()

    private let caseSensitiveButton = NSButton()

    private let searchField = NSSearchField()

    private let searchProgressIndicator = NSProgressIndicator()

    private let scopePopUpButton = NSPopUpButton()

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

    private var currentQuery = FindQuery()

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
                scopePopUpButton
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

        // Row 1 (y 0–24): the mode path at (3, 3), the case toggle 21×16 at the trailing edge.
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
            make.leading.trailing.equalToSuperview().inset(7)
            make.height.equalTo(22)
        }

        searchProgressIndicator.snp.makeConstraints { make in
            make.centerY.equalTo(searchField)
            make.trailing.equalTo(searchField).inset(24)
            make.size.equalTo(14)
        }

        // Row 3 (y 48–72): the scope pop-up at (2, 5) inside its row, 15 points tall.
        scopePopUpButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(53)
            make.leading.equalToSuperview().offset(2)
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
            $0.pathStyle = .standard
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            $0.isEditable = false
            $0.backgroundColor = .clear
            $0.focusRingType = .none
            $0.target = self
            $0.action = #selector(modePathControlClicked(_:))
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
            $0.contentTintColor = .secondaryLabelColor
        }

        searchField.do {
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            // Return searches; typing does not, as in Xcode.
            $0.sendsWholeSearchString = true
            $0.sendsSearchStringImmediately = false
            $0.maximumRecents = 0
            $0.placeholderString = FindMode.text.searchFieldPlaceholder
        }

        searchProgressIndicator.do {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isDisplayedWhenStopped = false
            $0.isIndeterminate = true
        }

        scopePopUpButton.do {
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
            $0.bezelStyle = .regularSquare
            $0.isBordered = false
            $0.pullsDown = false
            $0.addItem(withTitle: "In Indexed Images")
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .left
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
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
            $0.selectionHighlightStyle = .sourceList
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

        updateModePathItems(for: currentQuery)
        setSummary(nil)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: FindViewModel<Route>) {
        super.setupBindings(for: viewModel)

        let resultClicked: Signal<FindResultNode> = outlineView.rx.modelSelected().asSignal()

        let input = FindViewModel<Route>.Input(
            modeSelected: modeSelectedRelay.asSignal(),
            textMatchStyleSelected: textMatchStyleSelectedRelay.asSignal(),
            memberKindFilterSelected: memberKindFilterSelectedRelay.asSignal(),
            caseSensitiveToggled: caseSensitiveButton.rx.state.asSignal().map { $0 == .on },
            searchCommitted: searchField.rx.controlEvent.asSignal().map { [searchField] in searchField.stringValue },
            filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
            resultClicked: resultClicked,
            resultOpenedInNewTab: openInNewTabRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.query.driveOnNext { [weak self] query in
            guard let self else { return }
            currentQuery = query
            updateModePathItems(for: query)
            if searchField.placeholderString != query.mode.searchFieldPlaceholder {
                searchField.placeholderString = query.mode.searchFieldPlaceholder
            }
            let caseState: NSControl.StateValue = query.isCaseSensitive ? .on : .off
            if caseSensitiveButton.state != caseState {
                caseSensitiveButton.state = caseState
            }
            caseSensitiveButton.contentTintColor = query.isCaseSensitive ? .controlAccentColor : .secondaryLabelColor
            if searchField.stringValue != query.text, searchField.currentEditor() == nil {
                searchField.stringValue = query.text
            }
        }
        .disposed(by: rx.disposeBag)

        output.nodes.drive(outlineView.rx.nodes(options: []))({ (outlineView: NSOutlineView, _: NSTableColumn?, node: FindResultNode) -> NSView? in
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

        // Subscribed after the nodes binding, so the adapter has reloaded by the time this
        // runs: hits are only useful with their type expanded, as Xcode shows them.
        output.nodes.driveOnNext { [weak self] nodes in
            guard let self, !nodes.isEmpty else { return }
            outlineView.expandItem(nil, expandChildren: true)
        }
        .disposed(by: rx.disposeBag)

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

    // MARK: - Summary

    private func setSummary(_ summary: String?) {
        summaryLabel.stringValue = summary ?? ""
        summaryView.isHidden = summary == nil
        summaryHeightConstraint?.update(offset: summary == nil ? 0 : 22)
    }

    // MARK: - Mode Path

    /// `Find ▸ <mode> ▸ <option>`: the third component only in the modes that have one.
    private func updateModePathItems(for query: FindQuery) {
        var titles = ["Find", query.mode.title]
        if query.mode.hasTextMatchStyles {
            titles.append(query.textMatchStyle.title)
        } else if query.mode.hasMemberKinds {
            titles.append(query.memberKindFilter.title)
        }
        guard modePathControl.pathItems.map(\.title) != titles else { return }
        modePathControl.pathItems = titles.map { title in
            NSPathControlItem().then { $0.title = title }
        }
    }

    @objc private func modePathControlClicked(_ sender: NSPathControl) {
        guard let clickedItem = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(where: { $0 === clickedItem })
        else { return }
        let menu: NSMenu
        switch index {
        case 1:
            menu = NSMenu().then { menu in
                for mode in FindMode.allCases {
                    menu.addItem(withTitle: mode.title, action: #selector(modeMenuItemAction(_:)), keyEquivalent: "").then {
                        $0.target = self
                        $0.representedObject = mode
                        $0.state = mode == currentQuery.mode ? .on : .off
                    }
                }
            }
        case 2 where currentQuery.mode.hasTextMatchStyles:
            menu = NSMenu().then { menu in
                for style in FindTextMatchStyle.allCases {
                    menu.addItem(withTitle: style.title, action: #selector(textMatchStyleMenuItemAction(_:)), keyEquivalent: "").then {
                        $0.target = self
                        $0.representedObject = style
                        $0.state = style == currentQuery.textMatchStyle ? .on : .off
                    }
                }
            }
        case 2 where currentQuery.mode.hasMemberKinds:
            menu = NSMenu().then { menu in
                for filter in FindMemberKindFilter.allCases {
                    menu.addItem(withTitle: filter.title, action: #selector(memberKindFilterMenuItemAction(_:)), keyEquivalent: "").then {
                        $0.target = self
                        $0.representedObject = filter
                        $0.state = filter == currentQuery.memberKindFilter ? .on : .off
                    }
                }
            }
        default:
            return
        }
        menu.font = .systemFont(ofSize: 11)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func modeMenuItemAction(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? FindMode else { return }
        modeSelectedRelay.accept(mode)
    }

    @objc private func textMatchStyleMenuItemAction(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? FindTextMatchStyle else { return }
        textMatchStyleSelectedRelay.accept(style)
    }

    @objc private func memberKindFilterMenuItemAction(_ sender: NSMenuItem) {
        guard let filter = sender.representedObject as? FindMemberKindFilter else { return }
        memberKindFilterSelectedRelay.accept(filter)
    }

    // MARK: - Context Menu

    @objc private func openInNewTabMenuItemAction(_ sender: NSMenuItem) {
        guard outlineView.hasValidClickedRow, let node = outlineView.itemAtClickedRow as? FindResultNode else { return }
        openInNewTabRelay.accept(node)
    }
}

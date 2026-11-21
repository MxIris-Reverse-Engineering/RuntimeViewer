import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// An editor pane with nothing open: the start page — Xcode 27.2's initial editor, an Open Quickly
/// field over the engine's recent objects (proposal `editor-start-page`) — or, while the window's
/// file is still being read, a spinner that says so.
final class ContentPlaceholderViewController: BaseViewController<ContentPlaceholderViewModel> {
    // MARK: - Relays

    private let recentItemOpenedRelay = PublishRelay<ContentStartPageItemOpening>()

    /// The Open Quickly field's text and commands, which reach the controller as the text field's
    /// delegate: no control accessor reports an arrow key or Escape in a field.
    private let searchTextRelay = PublishRelay<String>()

    private let searchSelectionMovedRelay = PublishRelay<Int>()

    private let searchCommittedRelay = PublishRelay<SelectionRoute.Destination>()

    private let searchCancelledRelay = PublishRelay<Void>()

    private let searchResultOpenedRelay = PublishRelay<ContentStartPageItemOpening>()

    // MARK: - Start Page

    private let startPageView = StartPageView()

    private let searchField = OpenQuicklyField().then {
        $0.placeholderString = "Open Quickly"
    }

    private let recentItemsTitleLabel = Label("Recent Objects").then {
        $0.font = .preferredFont(forTextStyle: .title1)
        $0.textColor = .labelColor
    }

    private let showAllButton = NSButton(title: "", target: nil, action: nil).then {
        $0.isBordered = false
        $0.setButtonType(.momentaryChange)
        $0.isHidden = true
    }

    private let (recentItemsScrollView, recentItemsTableView): (ScrollView, RecentItemsTableView) = RecentItemsTableView.scrollableTableView()

    // MARK: - Search Results

    /// The results of the Open Quickly field, floating over the recent objects just under the
    /// field, on glass as Xcode's are.
    private let searchResultsPlatterView = FloatingPlatterView(cornerRadius: OpenQuicklyFieldMetrics.cornerRadius)

    private let (searchResultsScrollView, searchResultsTableView): (ScrollView, SearchResultsTableView) = SearchResultsTableView.scrollableTableView()

    private var searchResultsHeightConstraint: Constraint?

    /// What the search shows now; the results show only while the field is typed in in the key
    /// window, as Xcode's do.
    private var search: ContentPlaceholderViewModel.Search = .inactive

    /// The recent objects the list shows, as last applied: what each row stands for, which the
    /// table itself forgets — it keeps a selection by row, and a list reordered by another window
    /// would otherwise leave it on whatever object moved into that row.
    private var shownRecentItems: [ContentStartPageItemCellViewModel] = []

    // MARK: - Reading a File

    private let readingIndicator = NSProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .regular
        $0.isDisplayedWhenStopped = false
    }

    private let readingLabel = Label().then {
        $0.font = .systemFont(ofSize: 20, weight: .regular)
        $0.textColor = .secondaryLabelColor
    }

    private lazy var readingStackView = VStackView(alignment: .center, spacing: 12) {
        readingIndicator
        readingLabel
    }

    override var containerViewUsingSafeArea: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            startPageView
            readingStackView
        }

        startPageView.hierarchy {
            searchField
            recentItemsTitleLabel
            showAllButton
            recentItemsScrollView
            searchResultsPlatterView
        }
        searchResultsPlatterView.contentView = searchResultsScrollView

        startPageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        readingStackView.snp.makeConstraints { make in
            make.center.equalTo(containerView)
        }

        // One centred column, 200 to 700 points wide, 32 points from either side of the page.
        searchField.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(Metrics.pageTopInset)
            make.centerX.equalToSuperview()
            make.width.equalToSuperview().offset(-2 * Metrics.pageHorizontalInset).priority(.high)
            make.width.lessThanOrEqualTo(Metrics.maximumColumnWidth)
            make.width.greaterThanOrEqualTo(Metrics.minimumColumnWidth)
        }

        recentItemsTitleLabel.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(Metrics.sectionTopSpacing)
            make.leading.equalTo(searchField).inset(Metrics.sectionHorizontalInset)
        }

        showAllButton.snp.makeConstraints { make in
            make.firstBaseline.equalTo(recentItemsTitleLabel)
            make.leading.greaterThanOrEqualTo(recentItemsTitleLabel.snp.trailing).offset(Metrics.sectionHorizontalInset)
            make.trailing.equalTo(searchField).inset(Metrics.sectionHorizontalInset)
        }

        recentItemsScrollView.snp.makeConstraints { make in
            make.top.equalTo(recentItemsTitleLabel.snp.bottom).offset(Metrics.listTopSpacing)
            make.leading.equalTo(searchField).inset(Metrics.sectionHorizontalInset + Metrics.listLeadingInset)
            make.trailing.equalTo(searchField).inset(Metrics.sectionHorizontalInset)
            make.bottom.equalToSuperview()
        }

        recentItemsScrollView.do {
            $0.drawsBackground = false
            $0.hasVerticalScroller = true
            $0.autohidesScrollers = true
        }

        recentItemsTableView.do {
            $0.headerView = nil
            $0.backgroundColor = .clear
            $0.style = .plain
            $0.rowHeight = Metrics.rowHeight
            $0.intercellSpacing = .zero
            $0.gridStyleMask = []
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = false
        }
        recentItemsTableView.returnKeyPressed = { [weak self] row, modifierFlags in
            guard let self else { return }
            openRecentItem(atRow: row, modifierFlags: modifierFlags)
        }

        searchResultsPlatterView.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(Metrics.searchResultsTopSpacing)
            make.leading.trailing.equalTo(searchField)
            searchResultsHeightConstraint = make.height.equalTo(0).constraint
        }
        searchResultsPlatterView.isHidden = true

        searchResultsScrollView.do {
            $0.drawsBackground = false
            $0.hasVerticalScroller = true
            $0.autohidesScrollers = true
            $0.automaticallyAdjustsContentInsets = false
            $0.contentInsets = NSEdgeInsets(top: Metrics.searchResultsVerticalPadding, left: 0, bottom: Metrics.searchResultsVerticalPadding, right: 0)
        }

        searchResultsTableView.do {
            $0.headerView = nil
            $0.backgroundColor = .clear
            $0.style = .plain
            $0.rowHeight = Metrics.searchResultRowHeight
            $0.intercellSpacing = .zero
            $0.gridStyleMask = []
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = false
            // The field keeps the focus while the arrow keys move through the results.
            $0.refusesFirstResponder = true
        }

        searchField.textField.delegate = self
        searchField.isLitDidChange = { [weak self] _ in
            guard let self else { return }
            updateSearchResultsVisibility()
        }

        // Text typed on the page's background goes to the field, as it would have before the
        // click that took the focus from it.
        startPageView.keyTyped = { [weak self] event in
            // Text only: the arrows, Page Up and Down, Home, End and the function keys are special
            // keys whose characters lie outside the control characters.
            guard let self,
                  event.modifierFlags.intersection([.command, .control]).isEmpty,
                  event.specialKey == nil,
                  let characters = event.characters, characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }),
                  view.window?.makeFirstResponder(searchField.textField) == true,
                  let fieldEditor = searchField.textField.currentEditor()
            else { return false }
            // The field selects all of its text when it takes the focus; typing goes after it.
            fieldEditor.selectedRange = NSRange(location: (fieldEditor.string as NSString).length, length: 0)
            fieldEditor.keyDown(with: event)
            return true
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ContentPlaceholderViewModel) {
        super.setupBindings(for: viewModel)

        recentItemsTableView.rx.itemDoubleClicked()
            .asSignal()
            .emitOnNext { [weak self] index in
                guard let self else { return }
                openRecentItem(atRow: index.row, modifierFlags: NSApp.currentEvent?.modifierFlags ?? [])
            }
            .disposed(by: rx.disposeBag)

        searchResultsTableView.rx.itemClicked()
            .asSignal()
            .emitOnNext { [weak self] index in
                guard let self else { return }
                openSearchResult(atRow: index.row, modifierFlags: NSApp.currentEvent?.modifierFlags ?? [])
            }
            .disposed(by: rx.disposeBag)

        searchResultsTableView.rx.setDelegate(self).disposed(by: rx.disposeBag)

        let input = ContentPlaceholderViewModel.Input(
            pageWillAppear: rx.viewWillAppear.asSignal(),
            showAllClicked: showAllButton.rx.click.asSignal(),
            recentItemOpened: recentItemOpenedRelay.asSignal(),
            searchText: searchTextRelay.asSignal(),
            searchSelectionMoved: searchSelectionMovedRelay.asSignal(),
            searchCommitted: searchCommittedRelay.asSignal(),
            searchResultOpened: searchResultOpenedRelay.asSignal(),
            searchCancelled: searchCancelledRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.placeholder.driveOnNext { [weak self] placeholder in
            guard let self else { return }
            switch placeholder {
            case .noSelection:
                startPageView.isHidden = false
                readingStackView.isHidden = true
                readingIndicator.stopAnimation(nil)
            case .readingFile(let name):
                resignFocus(within: startPageView)
                startPageView.isHidden = true
                readingStackView.isHidden = false
                readingLabel.stringValue = "Reading “\(name)”…"
                readingIndicator.startAnimation(nil)
            }
        }
        .disposed(by: rx.disposeBag)

        // Three subscriptions to one driver, in this order on purpose: a driver delivers to its
        // subscribers in the order they subscribed, and `rx.items` applies each list to the table
        // there and then. So the first sees the table still showing the previous list, and the
        // last sees it showing the new one.
        var recentItemSelectedBeforeUpdate: ContentStartPageItemCellViewModel.Item?
        output.recentItems.driveOnNext { [weak self] _ in
            guard let self else { return }
            let selectedRow = recentItemsTableView.selectedRow
            recentItemSelectedBeforeUpdate = shownRecentItems.indices.contains(selectedRow) ? shownRecentItems[selectedRow].item : nil
        }
        .disposed(by: rx.disposeBag)

        output.recentItems
            .drive(recentItemsTableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: ContentStartPageItemCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: ContentStartPageItemCellView.self)
                cellView.configure(with: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.recentItems.driveOnNext { [weak self] recentItems in
            guard let self else { return }
            shownRecentItems = recentItems
            recentItemsTitleLabel.isHidden = recentItems.isEmpty
            recentItemsScrollView.isHidden = recentItems.isEmpty
            // The selection follows its object, wherever the new list puts it; an object the list
            // let go of — Show Less hides it — leaves the focused list on its first row, so that
            // Return still has something to open.
            if let selectedItem = recentItemSelectedBeforeUpdate, let row = recentItems.firstIndex(where: { $0.item == selectedItem }) {
                if row != recentItemsTableView.selectedRow {
                    recentItemsTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else {
                recentItemsTableView.deselectAll(nil)
                recentItemsTableView.selectFirstRowIfFocusedWithoutSelection()
            }
        }
        .disposed(by: rx.disposeBag)

        output.startedOver.emitOnNext { [weak self] in
            guard let self else { return }
            recentItemsTableView.deselectAll(nil)
        }
        .disposed(by: rx.disposeBag)

        output.search
            .map { search -> [ContentStartPageItemCellViewModel] in
                guard case .results(let rows, _) = search else { return [] }
                return rows
            }
            .distinctUntilChanged()
            .drive(searchResultsTableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: ContentStartPageItemCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: ContentStartPageItemCellView.self)
                cellView.configure(with: cellViewModel)
                cellView.showsSeparator = false
                cellView.contentHorizontalInset = Metrics.searchResultHorizontalInset
                return cellView
            }
            .disposed(by: rx.disposeBag)

        // After the rows above: the selected index addresses the rows just applied.
        output.search.driveOnNext { [weak self] search in
            guard let self else { return }
            self.search = search
            searchField.isSearching = search == .loading
            if case .results(let rows, let selectedIndex) = search {
                if let selectedIndex, rows.indices.contains(selectedIndex) {
                    searchResultsTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                    searchResultsTableView.scrollRowToVisible(selectedIndex)
                } else {
                    searchResultsTableView.deselectAll(nil)
                }
            }
            updateSearchResultsVisibility()
        }
        .disposed(by: rx.disposeBag)

        output.clearSearchField.emitOnNext { [weak self] in
            guard let self else { return }
            searchField.textField.stringValue = ""
        }
        .disposed(by: rx.disposeBag)

        output.showAllButton.driveOnNext { [weak self] button in
            guard let self else { return }
            showAllButton.isHidden = button.title == nil
            showAllButton.attributedTitle = NSAttributedString(
                string: button.title ?? "",
                attributes: [
                    .font: NSFont.systemFont(ofSize: Metrics.showAllFontSize),
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Actions

    /// Opens the recent object in `row` where the modifier keys say: a list's double-click or
    /// Return opens in the pane's tab, with ⌥ in the next pane, with ⇧⌥ in a new tab.
    private func openRecentItem(atRow row: Int, modifierFlags: NSEvent.ModifierFlags) {
        guard (0 ..< recentItemsTableView.numberOfRows).contains(row),
              let item: ContentStartPageItemCellViewModel = try? recentItemsTableView.rx.model(at: row)
        else { return }
        recentItemOpenedRelay.accept(.init(item: item, destination: SelectionRoute.Destination(listClickModifierFlags: modifierFlags)))
    }

    /// Opens the search result in `row` where the modifier keys say, as a list click does.
    private func openSearchResult(atRow row: Int, modifierFlags: NSEvent.ModifierFlags) {
        guard (0 ..< searchResultsTableView.numberOfRows).contains(row),
              let item: ContentStartPageItemCellViewModel = try? searchResultsTableView.rx.model(at: row)
        else { return }
        searchResultOpenedRelay.accept(.init(item: item, destination: SelectionRoute.Destination(listClickModifierFlags: modifierFlags)))
    }

    /// Shows the results under the field while there are any and the field is typed in in the key
    /// window, at the height of their rows: seven and a half at most, then the list scrolls.
    private func updateSearchResultsVisibility() {
        guard case .results(let rows, _) = search, !rows.isEmpty, searchField.isLit else {
            searchResultsPlatterView.isHidden = true
            searchResultsHeightConstraint?.update(offset: 0)
            return
        }
        let rowsHeight = min(CGFloat(rows.count) * Metrics.searchResultRowHeight, Metrics.maximumSearchResultsRowsHeight)
        let height = rowsHeight + 2 * Metrics.searchResultsVerticalPadding
        let wasHidden = searchResultsPlatterView.isHidden
        searchResultsPlatterView.isHidden = false
        guard let heightConstraint = searchResultsHeightConstraint?.layoutConstraints.first else { return }
        if wasHidden {
            heightConstraint.constant = height
        } else if heightConstraint.constant != height {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Metrics.searchResultsResizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                heightConstraint.animator().constant = height
            }
        }
    }

    /// Takes the keyboard focus away from `containerView` when a view inside it — the field's field
    /// editor included — has it, so that keys typed after it is hidden go nowhere unseen.
    private func resignFocus(within containerView: NSView) {
        guard let window = view.window,
              let firstResponder = window.firstResponder as? NSView,
              firstResponder.isDescendant(of: containerView)
        else { return }
        window.makeFirstResponder(nil)
    }
}

// MARK: - Metrics

extension ContentPlaceholderViewController {
    /// The start page's measurements: Xcode 27.2's initial editor (`InitialEditorView`,
    /// `RecentItemsSection`, `RecentItemView` in IDEKit; the proposal lists the addresses).
    fileprivate enum Metrics {
        static let pageTopInset: CGFloat = 80
        static let pageHorizontalInset: CGFloat = 32
        static let minimumColumnWidth: CGFloat = 200
        static let maximumColumnWidth: CGFloat = 700
        static let sectionTopSpacing: CGFloat = 65
        static let sectionHorizontalInset: CGFloat = 4
        static let listLeadingInset: CGFloat = 4
        static let listTopSpacing: CGFloat = 12
        static let showAllFontSize: CGFloat = 11
        /// SwiftUI's `List` row around a 32-point icon slot beside two lines of text, as Xcode draws
        /// it (`ContentStartPageItemCellView`).
        static let rowHeight: CGFloat = 38
        static let searchResultsTopSpacing: CGFloat = 5
        static let searchResultRowHeight: CGFloat = 56
        /// Seven and a half rows.
        static let maximumSearchResultsRowsHeight: CGFloat = 420
        static let searchResultsVerticalPadding: CGFloat = 10
        static let searchResultHorizontalInset: CGFloat = 12
        static let searchResultsResizeDuration: TimeInterval = 0.25
    }
}

// MARK: - Recent Items Table

extension ContentPlaceholderViewController {
    /// The recent objects' list. As in Xcode's, a click only selects; Return opens the selected row,
    /// as a double-click does, and taking the focus from the keyboard with nothing selected selects
    /// the first row.
    fileprivate final class RecentItemsTableView: SingleColumnTableView {
        /// Return on the selected row, with the modifier keys held.
        var returnKeyPressed: ((_ row: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Void)?

        /// Keeps AppKit from installing its table gesture recognizers, so that a click takes the
        /// keyboard focus as it did before macOS 27: there a click on a row only selects it, the
        /// focus stays in the Open Quickly field, the row shows in the unfocused grey and Return
        /// goes to the field instead of opening the row. `StatefulOutlineView` keeps the same
        /// override for the same reason (`RuntimeViewerUsingAppKit/AGENTS.md`, *Diagnosing UI
        /// Flicker*); AppKit logs that gesture recognizer support is disabled for this class.
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let modifierFlags = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if Self.returnKeyCodes.contains(event.keyCode), modifierFlags.isSubset(of: [.option, .shift]), selectedRow >= 0 {
                returnKeyPressed?(selectedRow, modifierFlags)
                return
            }
            super.keyDown(with: event)
        }

        /// Only a focus taken from the keyboard selects the first row: a click takes the focus
        /// before it selects the clicked row, and selecting the first row in between would show it
        /// for a frame.
        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder, NSApp.currentEvent?.type == .keyDown {
                selectFirstRowIfFocusedWithoutSelection()
            }
            return didBecomeFirstResponder
        }

        /// Selects the first row while the list has the keyboard focus and nothing selected.
        func selectFirstRowIfFocusedWithoutSelection() {
            guard window?.firstResponder === self, selectedRow < 0, numberOfRows > 0 else { return }
            selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        /// Return (36) and the keypad's Enter (76).
        private static let returnKeyCodes: Set<UInt16> = [36, 76]
    }
}

// MARK: - Open Quickly Field

extension ContentPlaceholderViewController {
    /// The large rounded query field at the top of the start page: Xcode 27.2's initial editor shows
    /// Open Quickly's query field there (`OpenQuicklyQueryUI` and `IDESearchWindowQueryView` in
    /// IDEKit; the proposal lists the numbers). A 47-point capsule with continuous corners, a
    /// magnifying glass in a 32-point box 16 points in, the text from 62 points in, 20-point medium.
    /// While the field is typed in in the key window the capsule's fill goes and a 3-point ring in the
    /// accent colour takes its place, half of it outside the capsule; otherwise the faint fill shows
    /// and no ring.
    ///
    /// The view only draws the field. The controller reads and clears `textField`, and takes its
    /// commands — the arrow keys, Return, Escape — as the text field's delegate.
    private final class OpenQuicklyField: NSView {
        /// The text typed into the field.
        var textField: NSTextField { focusReportingTextField }

        /// What the field says while it is empty.
        var placeholderString: String = "" {
            didSet { updatePlaceholder() }
        }

        /// Whether the catalog of the first search is being read: a small spinner at the trailing
        /// end says so.
        var isSearching = false {
            didSet {
                guard isSearching != oldValue else { return }
                if isSearching {
                    searchingIndicator.startAnimation(nil)
                } else {
                    searchingIndicator.stopAnimation(nil)
                }
            }
        }

        /// Whether the field is typed in in the key window: the ring shows, and so may the results.
        private(set) var isLit = false {
            didSet {
                guard isLit != oldValue else { return }
                updateAppearance()
                isLitDidChange?(isLit)
            }
        }

        var isLitDidChange: ((Bool) -> Void)?

        private let capsuleView = CapsuleView()

        private let ringView = CapsuleView()

        private let magnifyingGlassView = ImageView()

        private let focusReportingTextField = FocusReportingTextField()

        private let searchingIndicator = NSProgressIndicator().then {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isDisplayedWhenStopped = false
        }

        /// Whether the field is being typed in.
        private var isEditing = false {
            didSet { updateIsLit() }
        }

        /// Follows whether the field's window is key; replaced when the field moves to another
        /// window, and gone with the field.
        private var windowKeyObservation: WindowKeyObservation?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            capsuleView.do {
                $0.cornerRadius = OpenQuicklyFieldMetrics.cornerRadius
                $0.backgroundColor = OpenQuicklyFieldMetrics.fillColor
            }

            ringView.do {
                $0.cornerRadius = OpenQuicklyFieldMetrics.cornerRadius + OpenQuicklyFieldMetrics.ringWidth / 2
                $0.borderWidth = OpenQuicklyFieldMetrics.ringWidth
                $0.borderPositions = .all
                $0.borderColor = NSColor.controlAccentColor.withAlphaComponent(OpenQuicklyFieldMetrics.ringOpacity)
                $0.isHidden = true
            }

            magnifyingGlassView.do {
                $0.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                $0.symbolConfiguration = .init(pointSize: OpenQuicklyFieldMetrics.magnifyingGlassPointSize, weight: .regular)
                $0.contentTintColor = .secondaryLabelColor
                $0.imageAlignment = .alignCenter
                $0.imageScaling = .scaleNone
                $0.setAccessibilityElement(false)
            }

            focusReportingTextField.focusDidChange = { [weak self] isEditing in
                guard let self else { return }
                self.isEditing = isEditing
            }

            hierarchy {
                capsuleView
                ringView
                magnifyingGlassView
                focusReportingTextField
                searchingIndicator
            }

            capsuleView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            // Centred on the capsule's edge, as Xcode strokes it: half the ring lies outside.
            ringView.snp.makeConstraints { make in
                make.edges.equalToSuperview().inset(-OpenQuicklyFieldMetrics.ringWidth / 2)
            }

            magnifyingGlassView.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(OpenQuicklyFieldMetrics.magnifyingGlassBoxLeadingInset)
                make.centerY.equalToSuperview()
                make.size.equalTo(OpenQuicklyFieldMetrics.magnifyingGlassBoxSide)
            }

            focusReportingTextField.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(OpenQuicklyFieldMetrics.textLeadingInset)
                make.trailing.equalTo(searchingIndicator.snp.leading).offset(-OpenQuicklyFieldMetrics.searchingIndicatorSpacing)
                make.centerY.equalToSuperview()
            }

            searchingIndicator.snp.makeConstraints { make in
                make.trailing.equalToSuperview().inset(OpenQuicklyFieldMetrics.textTrailingInset)
                make.centerY.equalToSuperview()
            }

            snp.makeConstraints { make in
                make.height.equalTo(OpenQuicklyFieldMetrics.height)
            }

            updatePlaceholder()
            updateAppearance()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// A click anywhere on the capsule types into the field; a click while it is being typed in
        /// leaves the text and the insertion point alone.
        override func mouseDown(with event: NSEvent) {
            guard focusReportingTextField.currentEditor() == nil else { return }
            window?.makeFirstResponder(focusReportingTextField)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowKeyObservation = window.map { window in
                WindowKeyObservation(window: window) { [weak self] in
                    guard let self else { return }
                    updateIsLit()
                }
            }
            updateIsLit()
        }

        private func updateIsLit() {
            isLit = isEditing && window?.isKeyWindow == true
        }

        private func updateAppearance() {
            capsuleView.backgroundColor = isLit ? .clear : OpenQuicklyFieldMetrics.fillColor
            ringView.isHidden = !isLit
        }

        private func updatePlaceholder() {
            focusReportingTextField.placeholderAttributedString = NSAttributedString(
                string: placeholderString,
                attributes: [
                    .font: OpenQuicklyFieldMetrics.font,
                    .foregroundColor: NSColor.placeholderTextColor,
                ]
            )
        }
    }

    /// A rounded layer with continuous corners: the field's capsule and its ring.
    private final class CapsuleView: LayerBackedView {
        override func setup() {
            super.setup()
            layer?.cornerCurve = .continuous
        }

        /// Takes no clicks: they go to the field.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    /// Calls `keyStateDidChange` on the main actor whenever `window` becomes or stops being the key
    /// window, for as long as the observation lives: the observers go when it does, whichever way
    /// its owner goes.
    private final class WindowKeyObservation {
        private let observers: [NSObjectProtocol]

        init(window: NSWindow, keyStateDidChange: @escaping @MainActor () -> Void) {
            observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { notificationName in
                NotificationCenter.default.addObserver(forName: notificationName, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        keyStateDidChange()
                    }
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// The query field's measurements, after Xcode 27.2's initial editor.
    fileprivate enum OpenQuicklyFieldMetrics {
        static let height: CGFloat = 47
        static let cornerRadius: CGFloat = 24
        static let ringWidth: CGFloat = 3
        static let ringOpacity: CGFloat = 0.6
        /// `WelcomeListCellBackground` in IDEKit's asset catalog.
        static let fillColor = NSColor(
            light: NSColor(srgbRed: 0.373, green: 0.373, blue: 0.373, alpha: 0.12),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.04)
        )
        static let font = NSFont.systemFont(ofSize: 20, weight: .medium)
        static let magnifyingGlassBoxLeadingInset: CGFloat = 16
        static let magnifyingGlassBoxSide: CGFloat = 32
        /// Draws SF Symbols' magnifying glass about as large as Xcode's 23-point glyph.
        static let magnifyingGlassPointSize: CGFloat = 21
        static let textLeadingInset: CGFloat = 62
        static let textTrailingInset: CGFloat = 20
        static let searchingIndicatorSpacing: CGFloat = 8
    }

    /// A borderless text field that says when typing in it starts and ends: the field editor takes
    /// the first responder over as soon as the field gets it, so the field itself only hears both
    /// ends. It neither hugs nor resists its width, so the capsule's width alone decides it.
    private final class FocusReportingTextField: TextField {
        var focusDidChange: ((Bool) -> Void)?

        override func setup() {
            super.setup()
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            isEditable = true
            isSelectable = true
            usesSingleLineMode = true
            lineBreakMode = .byTruncatingTail
            cell?.isScrollable = true
            cell?.wraps = false
            font = OpenQuicklyFieldMetrics.font
            textColor = .labelColor
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        override func becomeFirstResponder() -> Bool {
            let didBecomeFirstResponder = super.becomeFirstResponder()
            if didBecomeFirstResponder {
                focusDidChange?(true)
            }
            return didBecomeFirstResponder
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            focusDidChange?(false)
        }
    }
}

// MARK: - Start Page View

extension ContentPlaceholderViewController {
    /// The start page's own view: a click on it, outside the field and the list, takes the focus
    /// from the field, as a click inside Xcode's initial editor does — onto the page itself, so the
    /// focus stays in this pane and the pane becomes the focused one. It is no stop of the Tab key,
    /// and typing on it types into the field.
    private final class StartPageView: NSView {
        /// Takes a key typed while the page has the focus, and says whether it did.
        var keyTyped: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override var canBecomeKeyView: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if keyTyped?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}

// MARK: - Search Results Table

extension ContentPlaceholderViewController {
    /// The Open Quickly field's results. It never takes the focus — the field keeps it while the
    /// arrow keys move the selection — so its rows draw their selection as a focused list's would.
    fileprivate final class SearchResultsTableView: SingleColumnTableView {}

    /// A results row that draws its selection in the accent colour although its list never has
    /// the focus.
    private final class EmphasizedTableRowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set {}
        }
    }
}

extension ContentPlaceholderViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === searchResultsTableView else { return nil }
        return EmphasizedTableRowView()
    }
}

// MARK: - Open Quickly Field Delegate

extension ContentPlaceholderViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        searchTextRelay.accept(searchField.textField.stringValue)
    }

    /// The keys Xcode's field takes: the arrows move through the results while there are any (and
    /// move the insertion point otherwise), Return opens the selected one (⌥↩ too, which goes to
    /// the next pane here as ⌥ always does), Escape clears the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let hasResults: Bool
        if case .results(let rows, _) = search {
            hasResults = !rows.isEmpty
        } else {
            hasResults = false
        }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)) where hasResults:
            searchSelectionMovedRelay.accept(-1)
        case #selector(NSResponder.moveDown(_:)) where hasResults:
            searchSelectionMovedRelay.accept(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            searchCommittedRelay.accept(SelectionRoute.Destination(listClickModifierFlags: NSApp.currentEvent?.modifierFlags ?? []))
        case #selector(NSResponder.cancelOperation(_:)):
            searchCancelledRelay.accept(())
        default:
            return false
        }
        return true
    }
}

// MARK: - Editor Pane Content

extension ContentPlaceholderViewController: EditorPaneContent {
    /// The Open Quickly field, as Xcode's initial editor takes the focus into its field; nothing
    /// while a file is being read.
    var focusableView: NSView? {
        startPageView.isHidden ? nil : searchField.textField
    }
}

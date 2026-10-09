import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

/// The Find navigator's scope chooser, the sheet the scope menu's Custom Scopes… opens — proposal
/// `draft-find-navigator` §9, after Xcode's `IDEFindNavigatorScopeChooserController`: a prompt, a
/// filter field, the indexed images — any number of which can be selected, each with where its
/// corpus stands — and Cancel and OK. OK, or a double-clicked row, makes the selection the scope.
///
/// Generic over the sidebar level's route, like the Find page that opens it.
final class FindScopeChooserViewController<Route: FindNavigatorRoutable>: BaseViewController<FindScopeChooserViewModel<Route>> {
    // MARK: - Views

    private let promptLabel = Label("Choose a search scope:")

    private let filterSearchField = SearchField()

    private let (scrollView, tableView): (ScrollView, FindScopeImageTableView) = FindScopeImageTableView.scrollableTableView()

    private let emptyLabel = Label("No Images")

    private let cancelButton = PushButton(title: "Cancel", titleFont: .systemFont(ofSize: 13))

    private let okButton = PushButton(title: "OK", titleFont: .systemFont(ofSize: 13))

    override var contentInsets: NSDirectionalEdgeInsets { .init(top: 20, leading: 20, bottom: 20, trailing: 20) }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            promptLabel
            filterSearchField
            scrollView
            emptyLabel
            cancelButton
            okButton
        }

        promptLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }

        filterSearchField.snp.makeConstraints { make in
            make.top.equalTo(promptLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview()
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(filterSearchField.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(okButton.snp.top).offset(-20)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        okButton.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview()
            make.width.greaterThanOrEqualTo(75)
        }

        cancelButton.snp.makeConstraints { make in
            make.centerY.equalTo(okButton)
            make.trailing.equalTo(okButton.snp.leading).offset(-12)
            make.width.equalTo(okButton)
        }

        // Xcode's sheet is never smaller than this: `+[IDEFindNavigatorScopeChooserController
        // beginSheetForWorkspaceTabController:initialScope:completionHandler:]` sets it as the
        // window's `contentMinSize`.
        view.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(360)
            make.height.greaterThanOrEqualTo(480)
        }

        promptLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .labelColor
        }

        filterSearchField.do {
            $0.placeholderString = "Filter"
            $0.sendsWholeSearchString = false
        }

        scrollView.do {
            $0.borderType = .bezelBorder
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.rowHeight = 22
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = true
            $0.allowsTypeSelect = true
        }

        emptyLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        // Return and Escape, as in any sheet.
        okButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        preferredContentSize = NSSize(width: 360, height: 480)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Typing narrows the list straight away, as in Xcode's chooser, whose window starts with
        // its filter field as the first responder.
        view.window?.makeFirstResponder(filterSearchField)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: FindScopeChooserViewModel<Route>) {
        super.setupBindings(for: viewModel)

        let tableView = tableView

        // The user's own selection changes only: the selection the list puts back after its rows
        // change is the ViewModel's already.
        let selectionChanged: Signal<Set<String>> = tableView.rx.proposedSelection().asSignal().map { [weak tableView] proposedSelection in
            guard let tableView else { return [] }
            return Set(proposedSelection.indexes.compactMap { row in
                (try? tableView.rx.model(at: row) as FindScopeImageCellViewModel)?.imagePath
            })
        }

        let rowDoubleClicked: Signal<Void> = tableView.rx.itemDoubleClicked().asSignal()
            .filter { $0.row >= 0 }
            .map { _ in () }

        let input = FindScopeChooserViewModel<Route>.Input(
            filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
            selectionChanged: selectionChanged,
            okClicked: okButton.rx.click.asSignal(),
            cancelClicked: cancelButton.rx.click.asSignal(),
            rowDoubleClicked: rowDoubleClicked
        )
        let output = viewModel.transform(input)

        output.rows
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: FindScopeImageCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: FindScopeImageCellView.self)
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        // Subscribed after the rows binding, so the list has reloaded by the time this runs. A
        // reload keeps the selection by row number, which a row inserted above — an image indexed
        // while the sheet is open — would move onto another image.
        Driver.combineLatest(output.rows, output.selectedImagePaths).driveOnNext { rows, selectedImagePaths in
            let selectedRowIndexes = IndexSet(rows.indices.filter { selectedImagePaths.contains(rows[$0].imagePath) })
            if tableView.selectedRowIndexes != selectedRowIndexes {
                tableView.selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
            }
        }
        .disposed(by: rx.disposeBag)

        // Once, when the list is first complete: the scope's first image scrolled into view, as
        // Xcode's chooser reveals the scope's items when it opens. Not on every change of the
        // rows, which would pull the list back while the user scrolls it during corpus builds.
        // The layout is forced so the row view exists before anything selects it again.
        output.revealedImagePath.emitOnNext { imagePath in
            let row = (0 ..< tableView.numberOfRows).first { row in
                (try? tableView.rx.model(at: row) as FindScopeImageCellViewModel)?.imagePath == imagePath
            }
            guard let row else { return }
            tableView.scrollRowToVisible(row)
            tableView.layoutSubtreeIfNeeded()
        }
        .disposed(by: rx.disposeBag)

        output.rows.map { !$0.isEmpty }.drive(emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)

        output.isOKEnabled.drive(okButton.rx.isEnabled).disposed(by: rx.disposeBag)
    }
}

// MARK: - Image List

/// The chooser's list. It overrides `mouseDown(with:)` only to keep AppKit's tracking loop, which
/// makes the list first responder on every click. Under macOS 27's gesture recognizers a click
/// leaves the focus in the filter field, and the rows it selects stay in the inactive grey — the
/// same trade `StatefulOutlineView.mouseDown(with:)` makes, and AppKit logs the same expected error
/// for it, "Gesture recognizer support has been disabled because NSTableView subclass … overrides
/// either mouseDown: or mouseDragged:".
///
/// Declared outside the generic view controller: a view nested in a generic class is generic
/// itself.
private final class FindScopeImageTableView: SingleColumnTableView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

// MARK: - Image Cell

/// One image of the scope chooser: its name and, at the trailing edge, where its corpus stands.
/// The full path is the tool tip.
///
/// Declared outside the generic view controller, as the Find page's own cells are.
private final class FindScopeImageCellView: TableCellView {
    private let nameLabel = Label()

    private let statusLabel = Label()

    override func setup() {
        super.setup()

        hierarchy {
            nameLabel
            statusLabel
        }

        nameLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(4)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(statusLabel.snp.leading).offset(-6)
        }

        statusLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
        }

        nameLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            // The name gives way before the status does.
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        statusLabel.do {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
    }

    func bind(to cellViewModel: FindScopeImageCellViewModel) {
        rx.disposeBag = DisposeBag()

        nameLabel.stringValue = cellViewModel.name
        toolTip = cellViewModel.imagePath

        cellViewModel.$status.asDriver().drive(statusLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

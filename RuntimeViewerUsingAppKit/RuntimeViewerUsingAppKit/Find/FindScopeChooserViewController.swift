import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

/// The Find navigator's scope chooser, a popover from the scope button — proposal
/// `draft-find-navigator` §7. A filter field; the two scopes that pick no image, every indexed
/// image and the image the sidebar lists; then a checkbox per indexed image, with where its corpus
/// stands. A choice applies as it is made, so the popover closes like any transient one.
///
/// Generic over the sidebar level's route, like the Find page that opens it.
final class FindScopeChooserViewController<Route: Routable>: BaseViewController<FindScopeChooserViewModel<Route>> {
    // MARK: - Relays

    /// The rows are rebuilt as the list changes, so their checkbox clicks are aggregated here.
    private let imageToggledRelay = PublishRelay<String>()

    // MARK: - Views

    private let filterSearchField = SearchField()

    private let allIndexedImagesButton = RadioButton()

    private let currentImageButton = RadioButton()

    private let separatorView = NSBox()

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private let emptyLabel = Label("No Images")

    override var contentInsets: NSDirectionalEdgeInsets { .init(top: 12, leading: 12, bottom: 12, trailing: 12) }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            filterSearchField
            allIndexedImagesButton
            currentImageButton
            separatorView
            scrollView
            emptyLabel
        }

        filterSearchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }

        allIndexedImagesButton.snp.makeConstraints { make in
            make.top.equalTo(filterSearchField.snp.bottom).offset(10)
            make.leading.equalToSuperview().offset(2)
            make.trailing.lessThanOrEqualToSuperview()
        }

        currentImageButton.snp.makeConstraints { make in
            make.top.equalTo(allIndexedImagesButton.snp.bottom).offset(6)
            make.leading.equalTo(allIndexedImagesButton)
            make.trailing.lessThanOrEqualToSuperview()
        }

        separatorView.snp.makeConstraints { make in
            make.top.equalTo(currentImageButton.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(separatorView.snp.bottom).offset(4)
            make.leading.trailing.bottom.equalToSuperview()
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        filterSearchField.do {
            $0.placeholderString = "Filter"
            $0.focusRingType = .none
        }

        allIndexedImagesButton.do {
            $0.title = "All Indexed Images"
            $0.font = .systemFont(ofSize: 13)
        }

        currentImageButton.do {
            $0.title = "Current Image"
            $0.font = .systemFont(ofSize: 13)
        }

        separatorView.boxType = .separator

        scrollView.do {
            $0.borderType = .noBorder
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.backgroundColor = .clear
            $0.rowHeight = 22
            $0.intercellSpacing = NSSize(width: 0, height: 2)
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = false
            // A checklist: the checkboxes say what is picked, rows are never selected.
            $0.selectionHighlightStyle = .none
        }

        emptyLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        preferredContentSize = NSSize(width: 320, height: 380)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Typing narrows the list straight away, as in Xcode's own choosers.
        view.window?.makeFirstResponder(filterSearchField)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: FindScopeChooserViewModel<Route>) {
        super.setupBindings(for: viewModel)

        let input = FindScopeChooserViewModel<Route>.Input(
            filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
            allIndexedImagesClicked: allIndexedImagesButton.rx.click.asSignal(),
            currentImageClicked: currentImageButton.rx.click.asSignal(),
            imageToggled: imageToggledRelay.asSignal()
        )
        let output = viewModel.transform(input)

        let imageToggledRelay = imageToggledRelay

        output.rows
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: FindScopeImageCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: FindScopeImageCellView.self)
                cellView.bind(to: cellViewModel) { imagePath in
                    imageToggledRelay.accept(imagePath)
                }
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.rows.map { !$0.isEmpty }.drive(emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)

        output.scope.map { $0 == .allIndexedImages ? NSControl.StateValue.on : .off }.drive(allIndexedImagesButton.rx.state).disposed(by: rx.disposeBag)

        output.scope.map { $0 == .currentImage ? NSControl.StateValue.on : .off }.drive(currentImageButton.rx.state).disposed(by: rx.disposeBag)

        output.currentImageTitle.drive(currentImageButton.rx.title).disposed(by: rx.disposeBag)

        output.isCurrentImageAvailable.drive(currentImageButton.rx.isEnabled).disposed(by: rx.disposeBag)
    }
}

// MARK: - Presentation

extension NSView {
    /// The view's bottom edge in its own coordinates — `maxY` when they are flipped, `minY`
    /// otherwise — for a popover meant to open below it, as the scope chooser does below the scope
    /// button.
    var bottomEdge: NSRectEdge {
        isFlipped ? .maxY : .minY
    }
}

// MARK: - Image Cell

/// One image of the scope chooser: a checkbox titled with the image's name — the name toggles it
/// too — and, at the trailing edge, where its corpus stands. The full path is the tool tip.
///
/// Declared outside the generic view controller, as the Find page's own cells are: a view nested in
/// a generic class is generic itself.
private final class FindScopeImageCellView: TableCellView {
    private let checkbox = CheckboxButton()

    private let statusLabel = Label()

    override func setup() {
        super.setup()

        hierarchy {
            checkbox
            statusLabel
        }

        checkbox.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(2)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(statusLabel.snp.leading).offset(-6)
        }

        statusLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(2)
            make.centerY.equalToSuperview()
        }

        checkbox.do {
            $0.font = .systemFont(ofSize: 13)
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

    func bind(to cellViewModel: FindScopeImageCellViewModel, onToggle: @escaping (String) -> Void) {
        rx.disposeBag = DisposeBag()

        checkbox.title = cellViewModel.name
        checkbox.toolTip = cellViewModel.imagePath

        cellViewModel.$isPicked.asDriver()
            .map { $0 ? NSControl.StateValue.on : .off }
            .drive(checkbox.rx.state)
            .disposed(by: rx.disposeBag)

        cellViewModel.$status.asDriver().drive(statusLabel.rx.stringValue).disposed(by: rx.disposeBag)

        let imagePath = cellViewModel.imagePath
        checkbox.rx.click.asSignal()
            .emitOnNext {
                onToggle(imagePath)
            }
            .disposed(by: rx.disposeBag)
    }
}

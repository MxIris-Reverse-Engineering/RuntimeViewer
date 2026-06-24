import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

final class BatchExportingImageSelectionViewController: UXKitViewController<BatchExportingImageSelectionViewModel>, ExportingStepViewController {
    private let searchField = SearchField()

    private let selectAllButton = PushButton(title: "Select All", titleFont: .systemFont(ofSize: 13))

    private let deselectAllButton = PushButton(title: "Deselect All", titleFont: .systemFont(ofSize: 13))

    private let summaryLabel = Label()

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private let toggleImageRelay = PublishRelay<BatchExportingImageSelectionCellViewModel>()

    override var contentInsets: NSDirectionalEdgeInsets { .init(top: 16, leading: 16, bottom: 16, trailing: 16) }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            searchField
            selectAllButton
            deselectAllButton
            summaryLabel
            scrollView
        }

        searchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }

        selectAllButton.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(8)
            make.leading.equalToSuperview()
        }

        deselectAllButton.snp.makeConstraints { make in
            make.centerY.equalTo(selectAllButton)
            make.leading.equalTo(selectAllButton.snp.trailing).offset(8)
        }

        summaryLabel.snp.makeConstraints { make in
            make.centerY.equalTo(selectAllButton)
            make.trailing.equalToSuperview()
            make.leading.greaterThanOrEqualTo(deselectAllButton.snp.trailing).offset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(selectAllButton.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview()
        }

        searchField.do {
            $0.focusRingType = .none
        }

        scrollView.do {
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.usesAutomaticRowHeights = true
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.selectionHighlightStyle = .none
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
        }
    }

    override func setupBindings(for viewModel: BatchExportingImageSelectionViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingImageSelectionViewModel.Input(
            searchString: searchField.rx.stringValue.asSignal(onErrorJustReturn: ""),
            selectAllClicked: selectAllButton.rx.click.asSignal(),
            deselectAllClicked: deselectAllButton.rx.click.asSignal(),
            toggleImage: toggleImageRelay.asSignal(),
        )

        let output = viewModel.transform(input)

        let toggleImageRelay = self.toggleImageRelay

        output.cellViewModels
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: BatchExportingImageSelectionCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CellView.self)
                cellView.bind(to: cellViewModel) { cellViewModel in
                    toggleImageRelay.accept(cellViewModel)
                }
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.selectionSummary.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

extension BatchExportingImageSelectionViewController {
    private final class CellView: TableCellView {
        private let checkbox = CheckboxButton(title: "").then {
            $0.font = .systemFont(ofSize: 13)
        }

        private let nameLabel = Label().then {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        private let pathLabel = Label().then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingMiddle
        }

        private let groupLabel = Label().then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
            $0.alignment = .right
        }

        private lazy var textStack = VStackView(alignment: .leading, spacing: 2) {
            nameLabel
                .box
                .contentHugging(h: .defaultLow)
                .box
                .contentCompressionResistance(h: .defaultLow)
            pathLabel
                .box
                .contentHugging(h: .defaultLow)
                .box
                .contentCompressionResistance(h: .defaultLow)
        }

        private lazy var contentStack = HStackView(spacing: 6) {
            checkbox
            textStack
            MaxSpacer()
            groupLabel
        }

        private var cellViewModel: BatchExportingImageSelectionCellViewModel?

        private var onToggle: ((BatchExportingImageSelectionCellViewModel) -> Void)?

        override func setup() {
            super.setup()

            checkbox.target = self
            checkbox.action = #selector(checkboxClicked)

            hierarchy {
                contentStack
            }

            contentStack.snp.makeConstraints { make in
                make.edges.equalToSuperview().inset(4)
            }
        }

        func bind(to cellViewModel: BatchExportingImageSelectionCellViewModel, onToggle: @escaping (BatchExportingImageSelectionCellViewModel) -> Void) {
            rx.disposeBag = DisposeBag()
            self.cellViewModel = cellViewModel
            self.onToggle = onToggle
            nameLabel.stringValue = cellViewModel.image.name
            pathLabel.stringValue = cellViewModel.image.path
            groupLabel.stringValue = cellViewModel.image.group

            cellViewModel.$isSelected
                .map { $0 ? NSControl.StateValue.on : .off }
                .bind(to: checkbox.rx.state)
                .disposed(by: rx.disposeBag)
        }

        @objc private func checkboxClicked() {
            guard let cellViewModel else { return }
            onToggle?(cellViewModel)
        }
    }
}

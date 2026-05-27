import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

final class BatchExportingImageSelectionViewController: AppKitViewController<BatchExportingImageSelectionViewModel>, ExportingStepViewController {
    private let filterSearchField = FilterSearchField()

    private let selectAllButton = PushButton(title: "Select All", titleFont: .systemFont(ofSize: 13))

    private let deselectAllButton = PushButton(title: "Deselect All", titleFont: .systemFont(ofSize: 13))

    private let summaryLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .right
    }

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private let toggleImageRelay = PublishRelay<BatchExportingImage>()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            filterSearchField
            selectAllButton
            deselectAllButton
            summaryLabel
            scrollView
        }

        filterSearchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }

        selectAllButton.snp.makeConstraints { make in
            make.top.equalTo(filterSearchField.snp.bottom).offset(8)
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

        scrollView.do {
            $0.hasVerticalScroller = true
            $0.borderType = .lineBorder
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.rowHeight = 22
            $0.gridStyleMask = []
            $0.intercellSpacing = NSSize(width: 0, height: 0)
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
        }
    }

    override func setupBindings(for viewModel: BatchExportingImageSelectionViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingImageSelectionViewModel.Input(
            searchString: filterSearchField.rx.stringValue.asSignal(onErrorJustReturn: ""),
            selectAllClicked: selectAllButton.rx.click.asSignal(),
            deselectAllClicked: deselectAllButton.rx.click.asSignal(),
            toggleImage: toggleImageRelay.asSignal()
        )

        let output = viewModel.transform(input)

        let toggleImageRelay = self.toggleImageRelay

        output.cellViewModels
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: BatchExportingImageSelectionCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CellView.self)
                cellView.configure(with: cellViewModel) { image in
                    toggleImageRelay.accept(image)
                }
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.selectionSummary.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

extension BatchExportingImageSelectionViewController {
    fileprivate final class CellView: TableCellView {
        private let checkbox = NSButton().then {
            $0.setButtonType(.switch)
            $0.title = ""
            $0.font = .systemFont(ofSize: 13)
        }

        private let nameLabel = Label().then {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        private let groupLabel = Label().then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
            $0.alignment = .right
        }

        private var image: BatchExportingImage?

        private var onToggle: ((BatchExportingImage) -> Void)?

        override func setup() {
            super.setup()

            checkbox.target = self
            checkbox.action = #selector(checkboxClicked)

            hierarchy {
                checkbox
                nameLabel
                groupLabel
            }

            checkbox.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(8)
                make.centerY.equalToSuperview()
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.equalTo(checkbox.snp.trailing).offset(6)
                make.centerY.equalToSuperview()
            }

            groupLabel.snp.makeConstraints { make in
                make.leading.greaterThanOrEqualTo(nameLabel.snp.trailing).offset(12)
                make.trailing.equalToSuperview().inset(8)
                make.centerY.equalToSuperview()
            }

            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            groupLabel.setContentHuggingPriority(.required, for: .horizontal)
        }

        func configure(with cellViewModel: BatchExportingImageSelectionCellViewModel, onToggle: @escaping (BatchExportingImage) -> Void) {
            image = cellViewModel.image
            self.onToggle = onToggle
            checkbox.state = cellViewModel.isSelected ? .on : .off
            nameLabel.stringValue = cellViewModel.image.name
            groupLabel.stringValue = cellViewModel.image.group
        }

        @objc private func checkboxClicked() {
            guard let image else { return }
            onToggle?(image)
        }
    }
}

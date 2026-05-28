import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerUI

final class BatchExportingCompletionViewController: UXKitViewController<BatchExportingCompletionViewModel>, ExportingStepViewController {
    private let checkmarkImageView = NSImageView().then {
        $0.image = .symbol(systemName: .checkmarkCircleFill)
        $0.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        $0.contentTintColor = .systemGreen
    }

    private let titleLabel = Label("Export Complete").then {
        $0.font = .systemFont(ofSize: 18, weight: .bold)
        $0.alignment = .center
    }

    private let summaryLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
        $0.maximumNumberOfLines = 0
        $0.preferredMaxLayoutWidth = 600
    }

    private let showInFinderButton = PushButton(title: "Show in Finder", titleFont: .systemFont(ofSize: 13))

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private lazy var headerStack = VStackView(alignment: .centerX, spacing: 6) {
        checkmarkImageView
        titleLabel
        summaryLabel
            .customSpacing(8)
        showInFinderButton
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            headerStack
            scrollView
        }

        headerStack.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(16)
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(16)
            make.leading.trailing.bottom.equalToSuperview().inset(20)
        }

        scrollView.do {
            $0.hasVerticalScroller = true
            $0.borderType = .lineBorder
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.rowHeight = 36
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
        }
    }

    override func setupBindings(for viewModel: BatchExportingCompletionViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingCompletionViewModel.Input(
            refresh: rx.viewDidAppear.asSignal(),
            showInFinderClick: showInFinderButton.rx.click.asSignal()
        )

        let output = viewModel.transform(input)

        output.summaryText.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.rows
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, rowVM: BatchExportingCompletionRowViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CellView.self)
                cellView.configure(with: rowVM)
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }
}

extension BatchExportingCompletionViewController {
    private final class CellView: TableCellView {
        private let nameLabel = Label().then {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        private let detailLabel = Label().then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        override func setup() {
            super.setup()

            hierarchy {
                nameLabel
                detailLabel
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(8)
                make.top.equalToSuperview().inset(4)
                make.trailing.lessThanOrEqualToSuperview().inset(8)
            }

            detailLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(8)
                make.top.equalTo(nameLabel.snp.bottom).offset(2)
                make.trailing.lessThanOrEqualToSuperview().inset(8)
                make.bottom.lessThanOrEqualToSuperview().inset(4)
            }
        }

        func configure(with rowVM: BatchExportingCompletionRowViewModel) {
            let outcome = rowVM.outcome
            nameLabel.stringValue = outcome.image.name
            switch outcome.outcome {
            case .success(let result):
                let parts: [String] = [
                    "\(result.succeeded) succeeded",
                    result.failed > 0 ? "\(result.failed) failed" : nil,
                    String(format: "%.1fs", result.totalDuration),
                ].compactMap { $0 }
                detailLabel.stringValue = parts.joined(separator: " · ")
                detailLabel.textColor = .secondaryLabelColor
            case .failure(let description):
                detailLabel.stringValue = "Failed: \(description)"
                detailLabel.textColor = .systemRed
            }
        }
    }
}

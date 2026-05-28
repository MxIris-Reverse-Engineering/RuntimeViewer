import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

final class BatchExportingProgressViewController: UXKitViewController<BatchExportingProgressViewModel>, ExportingStepViewController {
    private let titleLabel = Label().then {
        $0.font = .systemFont(ofSize: 14, weight: .semibold)
        $0.textColor = .controlTextColor
        $0.lineBreakMode = .byTruncatingMiddle
    }

    private let overallProgressBar = NSProgressIndicator().then {
        $0.style = .bar
        $0.isIndeterminate = false
        $0.minValue = 0
        $0.maxValue = 1
    }

    private let progressLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .secondaryLabelColor
    }

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            titleLabel
            progressLabel
            overallProgressBar
            scrollView
        }

        titleLabel.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(20)
            make.trailing.lessThanOrEqualTo(progressLabel.snp.leading).offset(-12)
        }

        progressLabel.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().inset(20)
        }

        overallProgressBar.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.equalTo(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(overallProgressBar.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalToSuperview().inset(20)
        }

        scrollView.do {
            $0.hasVerticalScroller = true
            $0.borderType = .lineBorder
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.rowHeight = 40
            $0.gridStyleMask = []
            $0.intercellSpacing = NSSize(width: 0, height: 0)
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
        }
    }

    override func setupBindings(for viewModel: BatchExportingProgressViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingProgressViewModel.Input(
            startExport: rx.viewDidAppear.asSignal()
        )

        let output = viewModel.transform(input)

        output.titleText.drive(titleLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.progressText.drive(progressLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.overallProgress.drive(overallProgressBar.rx.doubleValue).disposed(by: rx.disposeBag)

        output.rows
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, rowViewModel: BatchExportingProgressRowViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CellView.self)
                cellView.bind(to: rowViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }
}

extension BatchExportingProgressViewController {
    private final class CellView: TableCellView {
        private let statusIcon = ImageView().then {
            $0.imageScaling = .scaleProportionallyUpOrDown
        }

        private let nameLabel = Label().then {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingTail
        }

        private let detailLabel = Label().then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingMiddle
        }

        private let progressBar = NSProgressIndicator().then {
            $0.style = .bar
            $0.isIndeterminate = false
            $0.minValue = 0
            $0.maxValue = 1
            $0.controlSize = .small
        }

        override func setup() {
            super.setup()

            hierarchy {
                statusIcon
                nameLabel
                detailLabel
                progressBar
            }

            statusIcon.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(8)
                make.centerY.equalToSuperview()
                make.size.equalTo(18)
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.equalTo(statusIcon.snp.trailing).offset(8)
                make.top.equalToSuperview().inset(6)
                make.trailing.lessThanOrEqualToSuperview().inset(8)
            }

            detailLabel.snp.makeConstraints { make in
                make.leading.equalTo(nameLabel)
                make.trailing.equalToSuperview().inset(8)
                make.top.equalTo(nameLabel.snp.bottom).offset(2)
            }

            progressBar.snp.makeConstraints { make in
                make.leading.equalTo(nameLabel)
                make.trailing.equalToSuperview().inset(8)
                make.centerY.equalTo(detailLabel)
                make.height.equalTo(6)
            }
        }

        func bind(to rowViewModel: BatchExportingProgressRowViewModel) {
            rx.disposeBag = DisposeBag()

            nameLabel.stringValue = rowViewModel.image.name

            Driver.combineLatest(
                rowViewModel.$status.asDriver(),
                rowViewModel.$progress.asDriver(),
                rowViewModel.$currentObjectText.asDriver()
            )
            .driveOnNext { [weak self] status, progress, currentObject in
                guard let self else { return }
                applyState(status: status, progress: progress, currentObject: currentObject)
            }
            .disposed(by: rx.disposeBag)
        }

        private func applyState(
            status: BatchExportingProgressRowViewModel.Status,
            progress: Double,
            currentObject: String
        ) {
            switch status {
            case .queued:
                statusIcon.image = .symbol(systemName: .circle)
                statusIcon.contentTintColor = .tertiaryLabelColor
                detailLabel.stringValue = "Queued"
                detailLabel.textColor = .tertiaryLabelColor
                detailLabel.isHidden = false
                progressBar.isHidden = true
            case .running:
                statusIcon.image = .symbol(systemName: .arrowtriangleRightFill)
                statusIcon.contentTintColor = .systemBlue
                progressBar.doubleValue = progress
                progressBar.isHidden = false
                detailLabel.isHidden = true
            case .succeeded(let result):
                statusIcon.image = .symbol(systemName: .checkmarkCircleFill)
                statusIcon.contentTintColor = .systemGreen
                let parts: [String] = [
                    "\(result.succeeded) succeeded",
                    result.failed > 0 ? "\(result.failed) failed" : nil,
                    String(format: "%.1fs", result.totalDuration),
                ].compactMap { $0 }
                detailLabel.stringValue = parts.joined(separator: " · ")
                detailLabel.textColor = .secondaryLabelColor
                detailLabel.isHidden = false
                progressBar.isHidden = true
            case .failed(let description):
                statusIcon.image = .symbol(systemName: .xmarkCircleFill)
                statusIcon.contentTintColor = .systemRed
                detailLabel.stringValue = "Failed: \(description)"
                detailLabel.textColor = .systemRed
                detailLabel.isHidden = false
                progressBar.isHidden = true
            }
        }
    }
}

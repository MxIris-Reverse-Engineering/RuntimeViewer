import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

final class BatchExportingProgressViewController: BaseViewController<BatchExportingProgressViewModel>, ExportingStepViewController {
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
            startExport: rx.viewDidAppear.asSignal(),
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
        private static let progressBarWidth: CGFloat = 160

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

        /// Hosts the row's `NSProgressIndicator`, which is replaced on every
        /// `bind(to:)` — see `installFreshProgressBar()`. The container keeps
        /// the layout stable while the bar underneath it changes.
        private let progressBarContainer = NSView()

        private var progressBar: NSProgressIndicator?

        private lazy var detailStack = HStackView(alignment: .center, spacing: 8) {
            detailLabel
            progressBarContainer
        }

        private var isSymbolEffectRunning = false

        override func setup() {
            super.setup()

            hierarchy {
                statusIcon
                nameLabel
                detailStack
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

            detailStack.snp.makeConstraints { make in
                make.leading.equalTo(nameLabel)
                make.trailing.equalToSuperview().inset(8)
                make.top.equalTo(nameLabel.snp.bottom).offset(2)
            }

            progressBarContainer.snp.makeConstraints { make in
                make.width.equalTo(Self.progressBarWidth)
                make.height.equalTo(6)
            }

            // The label yields to the bar: it stretches into whatever width
            // is left and truncates before the bar gives up a point.
            detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            progressBarContainer.setContentHuggingPriority(.required, for: .horizontal)
            progressBarContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        func bind(to rowViewModel: BatchExportingProgressRowViewModel) {
            rx.disposeBag = DisposeBag()

            installFreshProgressBar()
            nameLabel.stringValue = rowViewModel.image.name

            Driver.combineLatest(
                rowViewModel.$status.asDriver(),
                rowViewModel.$progress.asDriver(),
                rowViewModel.$progressText.asDriver(),
                rowViewModel.$objectFailures.asDriver(),
            )
            .driveOnNext { [weak self] status, progress, progressText, objectFailures in
                guard let self else { return }
                applyState(status: status, progress: progress, progressText: progressText, objectFailures: objectFailures)
            }
            .disposed(by: rx.disposeBag)
        }

        /// Replaces the progress bar with a new instance so the first value
        /// the new row writes is applied without animation.
        ///
        /// `NSProgressIndicator` animates every `doubleValue` change and
        /// offers no way to opt out: on macOS 26 the value goes to a private
        /// `ProgressIndicatorLayer`, which adds an explicit `CAAnimation` from
        /// its previous progress to the new one — `CATransaction` and
        /// `NSAnimationContext` do not reach it, AppKit already disables
        /// implicit actions around the update itself. The only path that
        /// applies the value directly is a layer with no previous progress,
        /// which is what a fresh indicator has. Reusing one bar across rows
        /// therefore animates the previous row's value into the next row's
        /// on every scroll. Evidence and addresses:
        /// `Documentations/ResolvedIssues/2026-09-18-batch-export-row-stays-queued-while-indexing.md`.
        private func installFreshProgressBar() {
            progressBar?.removeFromSuperview()
            let freshProgressBar = NSProgressIndicator().then {
                $0.style = .bar
                $0.isIndeterminate = false
                $0.minValue = 0
                $0.maxValue = 1
                $0.controlSize = .small
            }
            progressBarContainer.hierarchy {
                freshProgressBar
            }
            freshProgressBar.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            progressBar = freshProgressBar
        }

        private func applyState(
            status: BatchExportingProgressRowViewModel.Status,
            progress: Double,
            progressText: String,
            objectFailures: [BatchExportingObjectFailure],
        ) {
            toolTip = objectFailures.exportFailureTooltip
            switch status {
            case .queued:
                statusIcon.image = .symbol(systemName: .circle)
                statusIcon.contentTintColor = .tertiaryLabelColor
                detailLabel.stringValue = "Queued"
                detailLabel.textColor = .tertiaryLabelColor
                progressBarContainer.isHidden = true
            case .running:
                progressBar?.doubleValue = progress
                progressBarContainer.isHidden = false
                detailLabel.stringValue = progressText
                detailLabel.textColor = .secondaryLabelColor
                if !isSymbolEffectRunning {
                    statusIcon.image = .symbol(systemName: .arrowTriangle2Circlepath)
                    statusIcon.contentTintColor = .systemBlue
                    statusIcon.addSymbolEffect(.rotate, options: .repeat(.periodic))
                    isSymbolEffectRunning = true
                }
                return
            case .succeeded(let result):
                if result.failed > 0 {
                    statusIcon.image = .symbol(systemName: .exclamationmarkTriangleFill)
                    statusIcon.contentTintColor = .systemOrange
                } else {
                    statusIcon.image = .symbol(systemName: .checkmarkCircleFill)
                    statusIcon.contentTintColor = .systemGreen
                }
                let parts: [String?] = [
                    "\(result.succeeded) succeeded",
                    result.failed > 0 ? "\(result.failed) failed" : nil,
                    String(format: "%.1fs", result.totalDuration),
                ]
                detailLabel.stringValue = parts.compactMap(\.self).joined(separator: " · ")
                detailLabel.textColor = result.failed > 0 ? .systemOrange : .secondaryLabelColor
                progressBarContainer.isHidden = true
            case .failed(let description):
                statusIcon.image = .symbol(systemName: .xmarkCircleFill)
                statusIcon.contentTintColor = .systemRed
                detailLabel.stringValue = "Failed: \(description)"
                detailLabel.textColor = .systemRed
                progressBarContainer.isHidden = true
            }
            if isSymbolEffectRunning {
                statusIcon.removeAllSymbolEffects()
                isSymbolEffectRunning = false
            }
        }
    }
}

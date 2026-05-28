import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerUI

final class BatchExportingCompletionViewController: UXKitViewController<BatchExportingCompletionViewModel>, ExportingStepViewController {
    private let headerIconImageView = ImageView().then {
        $0.image = .symbol(systemName: .checkmarkCircleFill)
        $0.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        $0.contentTintColor = .systemGreen
    }

    private let headerTitleLabel = Label("Export Complete").then {
        $0.font = .systemFont(ofSize: 16, weight: .semibold)
        $0.textColor = .labelColor
    }

    private let headerSubtitleLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .secondaryLabelColor
        $0.lineBreakMode = .byTruncatingMiddle
        $0.maximumNumberOfLines = 1
    }

    private let showInFinderButton = NSButton(title: "Show in Finder", target: nil, action: nil).then {
        $0.bezelStyle = .accessoryBarAction
        $0.controlSize = .small
    }

    private let interfacesCard = StatCardView(label: "Interfaces")
    private let imagesCard = StatCardView(label: "Images")
    private let objcSwiftCard = StatCardView(label: "ObjC · Swift")
    private let durationCard = StatCardView(label: "Duration")

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private lazy var headerTextStack = VStackView(alignment: .leading, spacing: 2) {
        headerTitleLabel
        headerSubtitleLabel
    }

    private lazy var headerStack = HStackView(spacing: 10) {
        headerIconImageView
        headerTextStack
        NSView()
        showInFinderButton
    }

    private lazy var statsStack = HStackView(distribution: .fillEqually, spacing: 8) {
        interfacesCard
        imagesCard
        objcSwiftCard
        durationCard
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            headerStack
            statsStack
            scrollView
        }

        headerStack.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        headerIconImageView.snp.makeConstraints { make in
            make.size.equalTo(26)
        }

        statsStack.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.equalTo(64)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(statsStack.snp.bottom).offset(14)
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
            $0.gridStyleMask = []
            $0.intercellSpacing = NSSize(width: 0, height: 0)
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.selectionHighlightStyle = .none
        }
    }

    override func setupBindings(for viewModel: BatchExportingCompletionViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingCompletionViewModel.Input(
            refresh: rx.viewDidAppear.asSignal(),
            showInFinderClick: showInFinderButton.rx.click.asSignal()
        )

        let output = viewModel.transform(input)

        output.summary
            .driveOnNext { [weak self] summary in
                guard let self else { return }
                applySummary(summary)
            }
            .disposed(by: rx.disposeBag)

        output.rows
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, rowViewModel: BatchExportingCompletionRowViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CellView.self)
                cellView.configure(with: rowViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }

    private func applySummary(_ summary: BatchExportingCompletionViewModel.Summary) {
        headerTitleLabel.stringValue = summary.headerTitle
        headerSubtitleLabel.stringValue = summary.headerSubtitle
        headerSubtitleLabel.isHidden = summary.headerSubtitle.isEmpty
        interfacesCard.setValue(summary.interfacesValue)
        imagesCard.setValue(summary.imagesValue)
        objcSwiftCard.setValue(summary.objcSwiftValue)
        durationCard.setValue(summary.durationValue)

        if summary.hasFailures {
            headerIconImageView.image = .symbol(systemName: .exclamationmarkTriangleFill)
            headerIconImageView.contentTintColor = .systemOrange
        } else {
            headerIconImageView.image = .symbol(systemName: .checkmarkCircleFill)
            headerIconImageView.contentTintColor = .systemGreen
        }
    }
}

extension BatchExportingCompletionViewController {
    private final class StatCardView: LayerBackedView {
        private let valueLabel = Label().then {
            $0.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
            $0.textColor = .labelColor
            $0.alignment = .center
            $0.lineBreakMode = .byTruncatingMiddle
            $0.maximumNumberOfLines = 1
        }

        private let labelLabel: Label

        init(label: String) {
            self.labelLabel = Label(label).then {
                $0.font = .systemFont(ofSize: 11, weight: .regular)
                $0.textColor = .secondaryLabelColor
                $0.alignment = .center
                $0.lineBreakMode = .byTruncatingTail
                $0.maximumNumberOfLines = 1
            }
            super.init(frame: .zero)

            cornerRadius = 8
            borderWidth = 1
            borderPositions = .all

            updateLayerColors()

            hierarchy {
                valueLabel
                labelLabel
            }

            valueLabel.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(6)
                make.top.equalToSuperview().inset(10)
            }

            labelLabel.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(6)
                make.top.equalTo(valueLabel.snp.bottom).offset(2)
                make.bottom.lessThanOrEqualToSuperview().inset(10)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateLayerColors()
        }

        private func updateLayerColors() {
            borderColor = NSColor(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10))
            backgroundColor = NSColor(light: .black.withAlphaComponent(0.025), dark: .white.withAlphaComponent(0.04))
        }

        func setValue(_ value: String) {
            valueLabel.stringValue = value
        }
    }
}

extension BatchExportingCompletionViewController {
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
            $0.lineBreakMode = .byTruncatingTail
            $0.alignment = .right
        }

        override func setup() {
            super.setup()

            wantsLayer = true

            hierarchy {
                statusIcon
                nameLabel
                detailLabel
            }

            statusIcon.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(10)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.equalTo(statusIcon.snp.trailing).offset(8)
                make.centerY.equalToSuperview()
                make.trailing.lessThanOrEqualTo(detailLabel.snp.leading).offset(-12)
            }

            detailLabel.snp.makeConstraints { make in
                make.trailing.equalToSuperview().inset(12)
                make.centerY.equalToSuperview()
            }
            detailLabel.setContentHuggingPriority(.required, for: .horizontal)
            detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        func configure(with rowViewModel: BatchExportingCompletionRowViewModel) {
            let outcome = rowViewModel.outcome
            nameLabel.stringValue = outcome.image.name
            switch outcome.outcome {
            case .success(let result):
                statusIcon.image = .symbol(systemName: .checkmarkCircleFill)
                statusIcon.contentTintColor = .systemGreen
                var parts: [String] = ["\(result.succeeded) interfaces"]
                if result.failed > 0 {
                    parts.append("\(result.failed) failed")
                }
                parts.append(String(format: "%.1fs", result.totalDuration))
                detailLabel.stringValue = parts.joined(separator: " · ")
                detailLabel.textColor = .secondaryLabelColor
                toolTip = nil
                layer?.backgroundColor = NSColor.clear.cgColor
            case .failure(let description):
                statusIcon.image = .symbol(systemName: .xmarkCircleFill)
                statusIcon.contentTintColor = .systemRed
                detailLabel.stringValue = "Failed"
                detailLabel.textColor = .systemRed
                toolTip = description
                layer?.backgroundColor = NSColor(light: .systemRed.withAlphaComponent(0.08), dark: .systemRed.withAlphaComponent(0.16)).cgColor
            }
        }
    }
}

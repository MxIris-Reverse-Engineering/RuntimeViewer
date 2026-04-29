import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettingsUI
import RuntimeViewerUI
import RxCocoa
import RxSwift
import SnapKit

final class BackgroundIndexingPopoverViewController: UXKitViewController<BackgroundIndexingPopoverViewModel> {
    // MARK: - Relays

    private let cancelBatchRelay = PublishRelay<RuntimeIndexingBatchID>()

    private let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableSingleColumnOutlineView()
    
    // MARK: - Views

    private let titleLabel = Label("Background Indexing").then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    private let subtitleLabel = Label("").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
    }

    private let headerSeparator = NSBox().then {
        $0.boxType = .separator
    }

    private let footerSeparator = NSBox().then {
        $0.boxType = .separator
    }

    private let emptyDisabledView = Label("Background indexing is disabled").then {
        $0.alignment = .center
        $0.textColor = .secondaryLabelColor
    }

    private let openSettingsButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Open Settings"
    }

    private let emptyIdleView = Label("No active indexing tasks").then {
        $0.alignment = .center
        $0.textColor = .secondaryLabelColor
    }

    private let cancelAllButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Cancel All"
    }

    private let clearHistoryButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Clear History"
        $0.isHidden = true
    }

    private let closeButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Close"
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        setupOutlineView()
        preferredContentSize = NSSize(width: 380, height: 320)
    }

    private func setupLayout() {
        let headerStack = VStackView(alignment: .leading, spacing: 2) {
            titleLabel
            subtitleLabel
        }

        let buttonStack = HStackView(spacing: 8) {
            cancelAllButton
            clearHistoryButton
            closeButton
        }
        buttonStack.alignment = .centerY

        let emptyDisabledStack = VStackView(alignment: .centerX, spacing: 8) {
            emptyDisabledView
            openSettingsButton
        }

        scrollView.documentView = outlineView

        contentView.hierarchy {
            headerStack
            headerSeparator
            scrollView
            emptyDisabledStack
            emptyIdleView
            footerSeparator
            buttonStack
        }

        headerStack.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(12)
            make.leading.trailing.equalToSuperview().inset(16)
        }

        headerSeparator.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerSeparator.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(12)
            make.bottom.equalTo(footerSeparator.snp.top).offset(-10)
        }

        emptyDisabledStack.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.width.lessThanOrEqualTo(scrollView).offset(-32)
        }

        emptyIdleView.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        footerSeparator.snp.makeConstraints { make in
            make.bottom.equalTo(buttonStack.snp.top).offset(-10)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(12)
        }
    }

    private func setupOutlineView() {
        outlineView.headerView = nil
        outlineView.usesAutomaticRowHeights = true
        outlineView.backgroundColor = .clear
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: BackgroundIndexingPopoverViewModel) {
        super.setupBindings(for: viewModel)

        let input = BackgroundIndexingPopoverViewModel.Input(
            cancelBatch: cancelBatchRelay.asSignal(),
            cancelAll: cancelAllButton.rx.click.asSignal(),
            clearHistory: clearHistoryButton.rx.click.asSignal(),
            openSettings: openSettingsButton.rx.click.asSignal()
        )
        let output = viewModel.transform(input)

        closeButton.rx.click.asSignal()
            .emitOnNext { [weak self] in
                guard let self else { return }
                dismiss(nil)
            }
            .disposed(by: rx.disposeBag)

        output.subtitle
            .drive(subtitleLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.isEnabled
            .drive(emptyDisabledView.rx.isHidden)
            .disposed(by: rx.disposeBag)

        output.isEnabled
            .drive(openSettingsButton.rx.isHidden)
            .disposed(by: rx.disposeBag)

        output.hasAnyHistory.not()
            .drive(clearHistoryButton.rx.isHidden)
            .disposed(by: rx.disposeBag)

        // Direct-call into the Settings window. There is no `MainRoute.openSettings`
        // case — see MCPStatusPopoverViewController for the same pattern.
        output.openSettings
            .emitOnNext {
                SettingsWindowController.shared.showWindow(nil)
            }
            .disposed(by: rx.disposeBag)

        let hasAnyContent = Driver.combineLatest(output.hasAnyBatch, output.hasAnyHistory) {
            $0 || $1
        }

        Driver.combineLatest(output.isEnabled, hasAnyContent) { enabled, hasContent in
            !enabled || hasContent
        }
        .drive(emptyIdleView.rx.isHidden)
        .disposed(by: rx.disposeBag)

        Driver.combineLatest(output.isEnabled, hasAnyContent) { enabled, hasContent in
            !enabled || !hasContent
        }
        .drive(scrollView.rx.isHidden)
        .disposed(by: rx.disposeBag)

        // Cell provider only handles cell creation + binding. Live updates
        // happen through per-cell driver subscriptions because RxAppKit's
        // staged-changeset path calls `reloadItem(_:)` (redraw only, no
        // `viewFor:item:` re-invocation) for content updates.
        output.nodes.drive(outlineView.rx.nodes) { [weak self] (outlineView: NSOutlineView, _: NSTableColumn?, node: BackgroundIndexingNode) -> NSView? in
            switch node {
            case .section(let kind, let batches):
                let cell = outlineView.box.makeView(ofClass: SectionHeaderCellView.self)
                cell.configure(kind: kind, count: batches.count)
                return cell
            case .batch(let batch, _):
                let cell = outlineView.box.makeView(ofClass: BatchCellView.self)
                cell.bind(
                    batch: viewModel.batch(for: batch.id),
                    onCancel: { [weak self] in
                        guard let self else { return }
                        cancelBatchRelay.accept(batch.id)
                    }
                )
                return cell
            case .item(let batchID, let item):
                let cell = outlineView.box.makeView(ofClass: ItemCellView.self)
                cell.bind(item: viewModel.item(for: batchID, itemID: item.id))
                return cell
            }
        }
        .disposed(by: rx.disposeBag)

        output.nodes.driveOnNext { [weak self] nodes in
            guard let self else { return }
            // Auto-expand only the ACTIVE section and its batches. HISTORY stays
            // collapsed by default; once the user expands it, NSOutlineView
            // preserves that state across diffs (the section identifier is
            // kind-only, see BackgroundIndexingNode.differenceIdentifier).
            for node in nodes {
                if case .section(.active, _) = node {
                    outlineView.expandItem(node, expandChildren: true)
                }
            }
        }
        .disposed(by: rx.disposeBag)
    }
}

extension BackgroundIndexingPopoverViewController {
    private final class SectionHeaderCellView: NSTableCellView {
        private let titleLabel = Label("").then {
            $0.font = .systemFont(ofSize: 11, weight: .semibold)
            $0.textColor = .secondaryLabelColor
        }
        private let countLabel = Label("").then {
            $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            $0.textColor = .tertiaryLabelColor
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let stack = HStackView(alignment: .centerY, spacing: 6) {
                titleLabel
                countLabel
            }

            addSubview(stack)
            stack.snp.makeConstraints { make in
                make.top.equalToSuperview().offset(4)
                make.bottom.equalToSuperview().offset(-4)
                make.leading.trailing.equalToSuperview()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(kind: BackgroundIndexingNode.SectionKind, count: Int) {
            switch kind {
            case .active:  titleLabel.stringValue = "ACTIVE"
            case .history: titleLabel.stringValue = "HISTORY"
            }
            countLabel.stringValue = "\(count)"
        }
    }

    private final class BatchCellView: NSTableCellView {
        private let titleLabel = Label("").then {
            $0.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        private let countLabel = Label("").then {
            $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
        private let progressIndicator = NSProgressIndicator().then {
            $0.style = .bar
            $0.isIndeterminate = false
            $0.controlSize = .small
            $0.minValue = 0
        }
        private let cancelButton = NSButton().then {
            $0.bezelStyle = .accessoryBar
            $0.isBordered = false
            $0.image = NSImage(
                systemSymbolName: "xmark.circle",
                accessibilityDescription: "Cancel batch")
            $0.imagePosition = .imageOnly
            $0.toolTip = "Cancel this batch"
            $0.contentTintColor = .secondaryLabelColor
        }
        private var disposeBag = DisposeBag()
        private var onCancel: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            cancelButton.target = self
            cancelButton.action = #selector(cancelButtonClicked)

            // Title takes remaining space; count + cancel hug their intrinsic size.
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            cancelButton.setContentHuggingPriority(.required, for: .horizontal)
            cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

            let topRow = HStackView(alignment: .centerY, spacing: 6) {
                titleLabel
                countLabel
                cancelButton
            }

            let stack = VStackView(spacing: 4) {
                topRow
                progressIndicator
            }

            addSubview(stack)
            stack.snp.makeConstraints { make in
                make.top.equalToSuperview().offset(4)
                make.bottom.equalToSuperview().offset(-4)
                make.leading.trailing.equalToSuperview()
            }

            // VStackView's default alignment is .centerX, which leaves children
            // sized by their horizontal intrinsicContentSize. NSProgressIndicator
            // and HStackView return noIntrinsicMetric horizontally, so without
            // these explicit width pins Auto Layout reports an ambiguous width
            // for the cell. Pin both rows to the stack's leading/trailing.
            topRow.snp.makeConstraints { make in
                make.leading.trailing.equalTo(stack)
            }
            progressIndicator.snp.makeConstraints { make in
                make.leading.trailing.equalTo(stack)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func bind(batch: Driver<RuntimeIndexingBatch>,
                  onCancel: @escaping () -> Void)
        {
            // Reset on every bind so cell reuse drops the prior subscription.
            disposeBag = DisposeBag()
            self.onCancel = onCancel

            batch.driveOnNext { [weak self] batch in
                guard let self else { return }
                update(with: batch)
            }
            .disposed(by: disposeBag)
        }

        private func update(with batch: RuntimeIndexingBatch) {
            cancelButton.isHidden = batch.isFinished
            titleLabel.stringValue = Self.title(for: batch.reason)
            countLabel.stringValue = "\(batch.completedCount)/\(batch.totalCount)"

            progressIndicator.maxValue = max(Double(batch.totalCount), 1)
            progressIndicator.doubleValue = Double(batch.completedCount)
            // Only meaningful while the batch is active; finished batches drop
            // the bar so the row collapses to the title row alone.
            progressIndicator.isHidden = batch.isFinished
        }

        @objc private func cancelButtonClicked() {
            onCancel?()
        }

        private static func title(for reason: RuntimeIndexingBatchReason) -> String {
            switch reason {
            case .appLaunch:
                return "App launch indexing"
            case .imageLoaded(let path):
                return "\((path as NSString).lastPathComponent) deps"
            case .settingsEnabled:
                return "Settings enabled"
            case .manual:
                return "Manual indexing"
            }
        }
    }

    private final class ItemCellView: NSTableCellView {
        // Raw NSImageView (not the project's ImageView wrapper): the wrapper
        // sets `wantsUpdateLayer = true`, which flattens the image into
        // `layer.contents` and destroys the per-part sublayer hierarchy that
        // SF Symbol effects (`.rotate`, `.bounce`, etc.) depend on.
        private let iconImageView = NSImageView().then {
            $0.imageScaling = .scaleProportionallyDown
        }
        private let titleLabel = Label("")
        private var disposeBag = DisposeBag()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            iconImageView.setContentHuggingPriority(.required, for: .horizontal)
            iconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let stack = HStackView(alignment: .centerY, spacing: 6) {
                iconImageView
                titleLabel
            }

            addSubview(stack)
            stack.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            iconImageView.snp.makeConstraints { make in
                make.size.equalTo(12)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func bind(item: Driver<RuntimeIndexingTaskItem>) {
            disposeBag = DisposeBag()
            item.driveOnNext { [weak self] item in
                guard let self else { return }
                update(with: item)
            }
            .disposed(by: disposeBag)
        }

        private func update(with item: RuntimeIndexingTaskItem) {
            iconImageView.image = Self.iconImage(for: item.state)
            iconImageView.contentTintColor = Self.iconTint(for: item.state)

            // Cell can be reused or transition between states; clear any prior
            // effect before deciding whether to attach a fresh one.
            iconImageView.removeAllSymbolEffects()
            if case .running = item.state {
                iconImageView.addSymbolEffect(.rotate, options: .repeating)
            }

            let nameSource = item.resolvedPath ?? item.id
            let name = (nameSource as NSString).lastPathComponent
            var text = name
            if case .failed(let message) = item.state {
                text = "\(item.id)  —  \(message)"
            }
            if item.hasPriorityBoost, case .pending = item.state {
                text += "   (priority)"
            }
            titleLabel.stringValue = text
        }

        private static func iconImage(for state: RuntimeIndexingTaskState) -> NSImage? {
            let symbolName: String
            switch state {
            case .pending: symbolName = "circle"
            case .running: symbolName = "arrow.triangle.2.circlepath"
            case .completed: symbolName = "checkmark.circle.fill"
            case .failed: symbolName = "xmark.circle.fill"
            case .cancelled: symbolName = "minus.circle.fill"
            }
            return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }

        private static func iconTint(for state: RuntimeIndexingTaskState) -> NSColor {
            switch state {
            case .pending: return .tertiaryLabelColor
            case .running: return .systemBlue
            case .completed: return .systemGreen
            case .failed: return .systemRed
            case .cancelled: return .systemOrange
            }
        }
    }
}

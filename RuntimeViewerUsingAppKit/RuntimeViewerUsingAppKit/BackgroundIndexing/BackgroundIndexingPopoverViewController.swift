import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettingsUI
import RuntimeViewerUI
import RxCocoa
import RxSwift
import SnapKit

final class BackgroundIndexingPopoverViewController: UXKitViewController<BackgroundIndexingPopoverViewModel> {
    // MARK: - Views

    private let titleLabel = Label("Background Indexing").then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    private let subtitleLabel = Label("").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .secondaryLabelColor
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

    private let outlineView = NSOutlineView().then {
        $0.headerView = nil
        $0.rowSizeStyle = .small
        $0.selectionHighlightStyle = .regular
        $0.indentationPerLevel = 16
    }

    private let scrollView = ScrollView()

    private let cancelAllButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Cancel All"
    }

    private let clearFailedButton = NSButton().then {
        $0.bezelStyle = .accessoryBarAction
        $0.title = "Clear Failed"
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
        preferredContentSize = NSSize(width: 380, height: 300)
    }

    private func setupLayout() {
        let headerStack = VStackView(alignment: .leading, spacing: 2) {
            titleLabel
            subtitleLabel
        }

        let buttonStack = HStackView(spacing: 8) {
            cancelAllButton
            clearFailedButton
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
            emptyDisabledStack
            emptyIdleView
            scrollView
            buttonStack
        }

        headerStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(12)
        }

        emptyDisabledStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualToSuperview().offset(-32)
        }

        emptyIdleView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalTo(buttonStack.snp.top).offset(-8)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(12)
        }
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: BackgroundIndexingPopoverViewModel) {
        super.setupBindings(for: viewModel)

        let input = BackgroundIndexingPopoverViewModel.Input(
            cancelBatch: .never(),
            cancelAll: cancelAllButton.rx.click.asSignal(),
            clearFailed: clearFailedButton.rx.click.asSignal(),
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

        output.hasAnyFailure.not()
            .drive(clearFailedButton.rx.isHidden)
            .disposed(by: rx.disposeBag)

        // Direct-call into the Settings window. There is no `MainRoute.openSettings`
        // case — see MCPStatusPopoverViewController for the same pattern.
        output.openSettings
            .emitOnNext {
                SettingsWindowController.shared.showWindow(nil)
            }
            .disposed(by: rx.disposeBag)

        Driver.combineLatest(output.isEnabled, output.hasAnyBatch) { enabled, hasBatches in
            !enabled || hasBatches
        }
        .drive(emptyIdleView.rx.isHidden)
        .disposed(by: rx.disposeBag)

        Driver.combineLatest(output.isEnabled, output.hasAnyBatch) { enabled, hasBatches in
            !enabled || !hasBatches
        }
        .drive(scrollView.rx.isHidden)
        .disposed(by: rx.disposeBag)

        output.nodes.drive(outlineView.rx.nodes) { (outlineView: NSOutlineView, _: NSTableColumn?, node: BackgroundIndexingNode) -> NSView? in
            switch node {
            case .batch(let batch, _):
                let cell = outlineView.box.makeView(ofClass: BatchCellView.self)
                cell.configure(
                    reason: batch.reason,
                    completedCount: batch.completedCount,
                    totalCount: batch.totalCount
                )
                return cell
            case .item(_, let item):
                let cell = outlineView.box.makeView(ofClass: ItemCellView.self)
                cell.configure(item: item)
                return cell
            }
        }
        .disposed(by: rx.disposeBag)

        output.nodes.driveOnNext { [weak self] _ in
            guard let self else { return }
            outlineView.expandItem(nil, expandChildren: true)
        }
        .disposed(by: rx.disposeBag)
    }
}

extension BackgroundIndexingPopoverViewController {
    private final class BatchCellView: NSTableCellView {
        let titleLabel = Label("")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(titleLabel)
            titleLabel.snp.makeConstraints { make in
                make.leading.trailing.centerY.equalToSuperview()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(
            reason: RuntimeIndexingBatchReason,
            completedCount: Int,
            totalCount: Int
        ) {
            titleLabel.stringValue = "\(Self.title(for: reason))   \(completedCount)/\(totalCount)"
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
        let titleLabel = Label("")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(titleLabel)
            titleLabel.snp.makeConstraints { make in
                make.leading.trailing.centerY.equalToSuperview()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(item: RuntimeIndexingTaskItem) {
            let nameSource = item.resolvedPath ?? item.id
            let name = (nameSource as NSString).lastPathComponent
            let prefix: String = {
                switch item.state {
                case .pending: return "·"
                case .running: return "↻"
                case .completed: return "✓"
                case .failed: return "✗"
                case .cancelled: return "⊘"
                }
            }()
            var text = "\(prefix) \(name)"
            if case .failed(let message) = item.state {
                text = "\(prefix) \(item.id)  —  \(message)"
            }
            if item.hasPriorityBoost, case .pending = item.state {
                text += "   (priority)"
            }
            titleLabel.stringValue = text
        }
    }
}

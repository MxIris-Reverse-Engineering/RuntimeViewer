import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettingsUI
import RuntimeViewerUI
import RxCocoa
import RxSwift
import SnapKit

final class BackgroundIndexingPopoverViewController:
    UXKitViewController<BackgroundIndexingPopoverViewModel>
{
    // MARK: - Relays

    private let cancelBatchRelay = PublishRelay<RuntimeIndexingBatchID>()
    private let cancelAllRelay = PublishRelay<Void>()
    private let clearFailedRelay = PublishRelay<Void>()
    private let openSettingsRelay = PublishRelay<Void>()

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

    // MARK: - Outline data

    private var renderedNodes: [BackgroundIndexingNode] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        setupOutlineView()
        setupActions()
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
        outlineView.dataSource = self
        outlineView.delegate = self
    }

    private func setupActions() {
        cancelAllButton.target = self
        cancelAllButton.action = #selector(cancelAllClicked)
        clearFailedButton.target = self
        clearFailedButton.action = #selector(clearFailedClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsClicked)
    }

    // MARK: - Actions

    @objc private func cancelAllClicked() {
        cancelAllRelay.accept(())
    }

    @objc private func clearFailedClicked() {
        clearFailedRelay.accept(())
    }

    @objc private func closeClicked() {
        dismiss(nil)
    }

    @objc private func openSettingsClicked() {
        openSettingsRelay.accept(())
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: BackgroundIndexingPopoverViewModel) {
        super.setupBindings(for: viewModel)

        let input = BackgroundIndexingPopoverViewModel.Input(
            cancelBatch: cancelBatchRelay.asSignal(),
            cancelAll: cancelAllRelay.asSignal(),
            clearFailed: clearFailedRelay.asSignal(),
            openSettings: openSettingsRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.subtitle
            .drive(subtitleLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.isEnabled
            .driveOnNext { [weak self] enabled in
                guard let self else { return }
                emptyDisabledView.isHidden = enabled
                openSettingsButton.isHidden = enabled
            }
            .disposed(by: rx.disposeBag)

        output.hasAnyFailure
            .driveOnNext { [weak self] hasFailure in
                guard let self else { return }
                clearFailedButton.isHidden = !hasFailure
            }
            .disposed(by: rx.disposeBag)

        // Direct-call into the Settings window. There is no `MainRoute.openSettings`
        // case — see MCPStatusPopoverViewController for the same pattern.
        output.openSettings
            .emitOnNext {
                SettingsWindowController.shared.showWindow(nil)
            }
            .disposed(by: rx.disposeBag)

        Observable
            .combineLatest(
                output.isEnabled.asObservable(),
                output.hasAnyBatch.asObservable()
            )
            .subscribeOnNext { [weak self] enabled, hasBatches in
                guard let self else { return }
                emptyIdleView.isHidden = !enabled || hasBatches
                scrollView.isHidden = !enabled || !hasBatches
            }
            .disposed(by: rx.disposeBag)

        output.nodes
            .driveOnNext { [weak self] nodes in
                guard let self else { return }
                renderedNodes = nodes
                outlineView.reloadData()
                outlineView.expandItem(nil, expandChildren: true)
            }
            .disposed(by: rx.disposeBag)
    }
}

// MARK: - NSOutlineViewDataSource & Delegate

extension BackgroundIndexingPopoverViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int
    {
        if item == nil {
            return renderedNodes.filter {
                if case .batch = $0 { return true } else { return false }
            }.count
        }
        guard let node = item as? BackgroundIndexingNode,
              case .batch(let batch) = node
        else { return 0 }
        return batch.items.count
    }

    func outlineView(_ outlineView: NSOutlineView,
                     child index: Int,
                     ofItem item: Any?) -> Any
    {
        if item == nil {
            let batches = renderedNodes.compactMap { node -> RuntimeIndexingBatch? in
                if case .batch(let batch) = node { return batch } else { return nil }
            }
            return BackgroundIndexingNode.batch(batches[index])
        }
        guard let node = item as? BackgroundIndexingNode,
              case .batch(let batch) = node
        else {
            preconditionFailure("unexpected outline item type: \(type(of: item))")
        }
        return BackgroundIndexingNode.item(batchID: batch.id,
                                           item: batch.items[index])
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool
    {
        if let node = item as? BackgroundIndexingNode,
           case .batch = node { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView?
    {
        guard let node = item as? BackgroundIndexingNode else { return nil }

        let cell = NSTableCellView()
        let label = Label("")
        cell.hierarchy { label }
        label.snp.makeConstraints { make in
            make.leading.trailing.centerY.equalToSuperview()
        }

        switch node {
        case .batch(let batch):
            let title = Self.title(for: batch.reason)
            label.stringValue = "\(title)   \(batch.completedCount)/\(batch.totalCount)"
        case .item(_, let item):
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
            label.stringValue = text
        }

        return cell
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

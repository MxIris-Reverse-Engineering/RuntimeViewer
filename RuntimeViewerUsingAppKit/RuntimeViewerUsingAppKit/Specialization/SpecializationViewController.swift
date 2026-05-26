import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

final class SpecializationViewController: UXKitViewController<SpecializationViewModel> {
    // MARK: - Subviews

    private let headerLabel = Label()
    private let statusLabel = Label()
    private let (scrollView, outlineView): (ScrollView, OutlineView) = OutlineView.scrollableSingleColumnOutlineView()
    private let cancelButton = PushButton(title: "Cancel", titleFont: .systemFont(ofSize: 13))
    private let specializeButton = PushButton(title: "Specialize", titleFont: .systemFont(ofSize: 13))

    /// Forwarded "Choose Type" clicks from every recycled `ParameterRowCellView`.
    /// Each cell forwards its row's `parameterPath` here via the signal
    /// returned from `bind(to:)`; the controller re-emits the stream through
    /// `Input.requestTypePickerClicked` so the VM/coordinator can resolve the
    /// matching row, even when the outline reuses cells across diffs.
    private let chooseClickRelay = PublishRelay<[ParameterPathSegment]>()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.hierarchy {
            headerLabel
            statusLabel
            scrollView
            cancelButton
            specializeButton
        }

        headerLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalTo(specializeButton.snp.top).offset(-20)
        }

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        specializeButton.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
            make.width.equalTo(100)
        }

        cancelButton.snp.makeConstraints { make in
            make.centerY.equalTo(specializeButton)
            make.trailing.equalTo(specializeButton.snp.leading).offset(-12)
            make.width.equalTo(100)
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
            $0.textColor = .controlTextColor
        }

        statusLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
        }

        specializeButton.do {
            $0.role = .primary
            $0.isEnabled = false
        }

        cancelButton.do {
            $0.role = .cancel
        }

        scrollView.do {
            $0.autohidesScrollers = true
            $0.hasHorizontalScroller = false
            $0.borderType = .noBorder
            $0.drawsBackground = false
        }

        outlineView.do {
            $0.headerView = nil
            $0.indentationPerLevel = 16
            $0.style = .sourceList
            $0.backgroundColor = .clear
            $0.rowHeight = 28
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = false
        }

        preferredContentSize = NSSize(width: 520, height: 360)
    }

    // MARK: - Anchor lookup (for coordinator-driven popover positioning)

    func anchorView(forPath parameterPath: [ParameterPathSegment]) -> NSView? {
        guard let row = locateRow(forPath: parameterPath) else { return nil }
        let rowIndex = outlineView.row(forItem: row)
        guard rowIndex >= 0,
              let cellView = outlineView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? ParameterRowCellView
        else { return nil }
        return cellView.anchorView
    }

    private func locateRow(forPath parameterPath: [ParameterPathSegment]) -> SpecializationCellViewModel? {
        guard let viewModel else { return nil }
        var rows = viewModel.topLevelRows
        var matchedRow: SpecializationCellViewModel?
        for segment in parameterPath {
            // Loading placeholders never serve as an anchor target — the
            // anchor is always a real parameter row whose Choose Type button
            // can host the popover.
            guard case .parameter(let name) = segment else { return nil }
            guard let next = rows.first(where: { $0.parameter.name == name }) else { return nil }
            matchedRow = next
            rows = next.children
        }
        return matchedRow
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: SpecializationViewModel) {
        super.setupBindings(for: viewModel)

        let input = SpecializationViewModel.Input(
            specializeClicked: specializeButton.rx.click.asSignal(),
            cancelClicked: cancelButton.rx.click.asSignal(),
            requestTypePickerClicked: chooseClickRelay.asSignal()
        )
        let output = viewModel.transform(input)

        output.runtimeObjectDisplayName
            .map { "Specialize \($0)" }
            .drive(headerLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.canSpecialize.drive(specializeButton.rx.isEnabled).disposed(by: rx.disposeBag)

        let loadState = output.loadState
        loadState.map(Self.statusText).drive(statusLabel.rx.stringValue).disposed(by: rx.disposeBag)
        loadState.map(Self.isStatusHidden).drive(statusLabel.rx.isHidden).disposed(by: rx.disposeBag)
        loadState.map(Self.isFormHidden).drive(scrollView.rx.isHidden).disposed(by: rx.disposeBag)
        loadState.map(Self.isSpecializeHidden).drive(specializeButton.rx.isHidden).disposed(by: rx.disposeBag)

        output.rows
            .drive(outlineView.rx.nodes) { [chooseClickRelay] (outlineView: NSOutlineView, _: NSTableColumn?, row: SpecializationCellViewModel) -> NSView? in
                let cellView = outlineView.box.makeView(ofClass: ParameterRowCellView.self)
                cellView.bind(to: row)
                    .emit(to: chooseClickRelay)
                    .disposed(by: cellView.rx.disposeBag)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.reloadRow.emitOnNext { [weak self] row in
            guard let self else { return }
            // `outlineView.rx.nodes` uses DifferenceKit, which can not detect
            // reference-row mutation (the same row instance lives in both the
            // pre/post snapshots and `isContentEqual` compares an object to
            // itself). Drive child visibility off this explicit signal so the
            // outline view re-queries `numberOfChildrenOfItem` whenever a
            // row's children change.
            outlineView.reloadItem(row, reloadChildren: true)
        }
        .disposed(by: rx.disposeBag)

        output.expandRow.emitOnNext { [weak self] row in
            guard let self else { return }
            outlineView.expandItem(row, expandChildren: false)
        }
        .disposed(by: rx.disposeBag)
        
        outlineView.rx.setDelegate(self).disposed(by: rx.disposeBag)
    }

    // MARK: - Load state helpers

    private static func statusText(_ state: SpecializationViewModel.LoadState) -> String {
        switch state {
        case .idle,
             .loading: return "Loading…"
        case .loaded: return ""
        case .unsupported(let reason): return reason
        case .failed(let message): return message
        }
    }

    private static func isStatusHidden(_ state: SpecializationViewModel.LoadState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    private static func isFormHidden(_ state: SpecializationViewModel.LoadState) -> Bool {
        if case .loaded = state { return false }
        return true
    }

    private static func isSpecializeHidden(_ state: SpecializationViewModel.LoadState) -> Bool {
        switch state {
        case .idle,
             .loading,
             .loaded: return false
        case .unsupported,
             .failed: return true
        }
    }
}

extension SpecializationViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        false
    }
}

// MARK: - ParameterRowCellView

extension SpecializationViewController {
    private final class ParameterRowCellView: TableCellView {
        private let descriptionLabel = Label()
        private let chooseButton = LoadingButton(title: "Choose Type…", titleFont: .systemFont(ofSize: 13))
        private let loadingIndicator = NSProgressIndicator()
        var anchorView: NSView { chooseButton }
        override func setup() {
            super.setup()

            let stack = HStackView(spacing: 8) {
                loadingIndicator
                descriptionLabel
                MaxSpacer()
                chooseButton
            }
            hierarchy { stack }
            stack.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }

            descriptionLabel.do {
                $0.maximumNumberOfLines = 1
                $0.lineBreakMode = .byTruncatingTail
            }

            loadingIndicator.do {
                $0.style = .spinning
                $0.controlSize = .small
                $0.isIndeterminate = true
                $0.isDisplayedWhenStopped = false
            }

            chooseButton.setContentHuggingPriority(.required, for: .horizontal)
            chooseButton.snp.makeConstraints { make in
                make.width.greaterThanOrEqualTo(160)
            }
        }

        /// Bind the cell to a row and return that row's "Choose Type" click
        /// signal already tagged with the row's `parameterPath`. The caller
        /// is expected to `emit(to:)` the controller's relay and dispose via
        /// `cellView.rx.disposeBag`; the disposeBag is reset at the top of
        /// `bind(to:)` so the prior row's subscriptions are dropped before
        /// the new ones are wired up.
        func bind(to row: SpecializationCellViewModel) -> Signal<[ParameterPathSegment]> {
            rx.disposeBag = DisposeBag()

            row.$descriptionText.asDriver()
                .drive(descriptionLabel.rx.attributedStringValue)
                .disposed(by: rx.disposeBag)

            row.$buttonTitle.asDriver()
                .drive(chooseButton.rx.title)
                .disposed(by: rx.disposeBag)

            row.$isPreparingPicker.asDriver()
                .driveOnNext { [chooseButton] preparing in
                    chooseButton.isLoading = preparing
                }
                .disposed(by: rx.disposeBag)

            // The placeholder row has no candidate to pick — swap the
            // "Choose Type…" button for a spinning indicator so the user
            // sees that work is in flight while the inner specialization
            // request resolves.
            chooseButton.isHidden = row.isPlaceholder
            loadingIndicator.isHidden = !row.isPlaceholder
            if row.isPlaceholder {
                loadingIndicator.startAnimation(nil)
            } else {
                loadingIndicator.stopAnimation(nil)
            }

            return chooseButton.rx.click
                .asSignal()
                .map { row.parameterPath }
        }
    }
}

import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

final class BatchExportingImageSelectionViewController: BaseViewController<BatchExportingImageSelectionViewModel>, ExportingStepViewController, NSOutlineViewDelegate {
    // MARK: - Search

    private let matchModePopUpButton = PopUpButton()

    private let matchTargetPopUpButton = PopUpButton()

    private let searchField = FilterSearchField()

    private lazy var matchCaseButton = searchField.addFilterButton(systemSymbolName: "textformat", toolTip: "Match Case")

    // MARK: - Selection

    private let selectAllButton = PushButton(title: "Select All", titleFont: .systemFont(ofSize: 13))

    private let deselectAllButton = PushButton(title: "Deselect All", titleFont: .systemFont(ofSize: 13))

    private let summaryLabel = Label()

    private let (scrollView, outlineView): (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()

    // MARK: - Relays

    private let toggleNodeRelay = PublishRelay<BatchExportingImageTreeNode>()

    override var contentInsets: NSDirectionalEdgeInsets { .init(top: 16, leading: 16, bottom: 16, trailing: 16) }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            matchModePopUpButton
            matchTargetPopUpButton
            searchField
            selectAllButton
            deselectAllButton
            summaryLabel
            scrollView
        }

        searchField.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview()
            make.leading.equalTo(matchTargetPopUpButton.snp.trailing).offset(8)
        }

        matchModePopUpButton.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalTo(searchField)
        }

        matchTargetPopUpButton.snp.makeConstraints { make in
            make.leading.equalTo(matchModePopUpButton.snp.trailing).offset(8)
            make.centerY.equalTo(searchField)
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

        matchModePopUpButton.do {
            $0.addItems(withTitles: BatchExportingImageQuery.MatchMode.allCases.map(\.description))
            $0.selectItem(at: BatchExportingImageQuery.MatchMode.contains.rawValue)
            $0.toolTip = "How the search text is matched"
        }

        matchTargetPopUpButton.do {
            $0.addItems(withTitles: BatchExportingImageQuery.MatchTarget.allCases.map(\.description))
            $0.selectItem(at: BatchExportingImageQuery.MatchTarget.name.rawValue)
            $0.toolTip = "What the search text is matched against"
        }

        searchField.do {
            $0.focusRingType = .none
        }

        scrollView.do {
            $0.autohidesScrollers = true
        }

        outlineView.do {
            $0.rowHeight = 22
            $0.allowsEmptySelection = true
            $0.allowsMultipleSelection = false
            $0.selectionHighlightStyle = .none
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: BatchExportingImageSelectionViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingImageSelectionViewModel.Input(
            searchString: searchField.rx.stringValue.asSignal(onErrorJustReturn: ""),
            matchMode: matchModePopUpButton.rx.selectedItemIndex().asSignal().compactMap {
                BatchExportingImageQuery.MatchMode(rawValue: $0)
            },
            matchTarget: matchTargetPopUpButton.rx.selectedItemIndex().asSignal().compactMap {
                BatchExportingImageQuery.MatchTarget(rawValue: $0)
            },
            isCaseSensitive: matchCaseButton.rx.state.asSignal(onErrorJustReturn: .off).map { $0 == .on },
            selectAllClicked: selectAllButton.rx.click.asSignal(),
            deselectAllClicked: deselectAllButton.rx.click.asSignal(),
            toggleNode: toggleNodeRelay.asSignal(),
        )

        let output = viewModel.transform(input)

        let toggleNodeRelay = self.toggleNodeRelay

        output.nodes
            .drive(outlineView.rx.nodes) { (outlineView: NSOutlineView, _: NSTableColumn?, node: BatchExportingImageTreeNode) -> NSView? in
                let cellView = outlineView.box.makeView(ofClass: CellView.self)
                cellView.bind(to: node, toggleNodeRelay: toggleNodeRelay)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        // The two roots open as soon as the tree first arrives; everything beneath them starts
        // collapsed.
        output.nodes
            .filter { !$0.isEmpty }
            .asObservable()
            .take(1)
            .subscribeOnNext { [weak self] rootNodes in
                guard let self else { return }
                for rootNode in rootNodes {
                    outlineView.expandItem(rootNode)
                }
            }
            .disposed(by: rx.disposeBag)

        output.didBeginFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            outlineView.beginFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.didApplyQuery.emitOnNext { [weak self] in
            guard let self else { return }
            outlineView.reloadData()
        }
        .disposed(by: rx.disposeBag)

        output.didEndFiltering.emitOnNext { [weak self] in
            guard let self else { return }
            outlineView.endFiltering()
        }
        .disposed(by: rx.disposeBag)

        output.summary.driveOnNext { [weak self] summary in
            guard let self else { return }
            summaryLabel.stringValue = summary.text
            summaryLabel.textColor = summary.isError ? .systemRed : .secondaryLabelColor
        }
        .disposed(by: rx.disposeBag)

        outlineView.rx.setDelegate(self).disposed(by: rx.disposeBag)
    }

    // MARK: - NSOutlineViewDelegate

    /// Rows are never selected: only the checkboxes act. A selection nobody can see would still
    /// be restored, and scrolled to, when a search is cleared.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        false
    }
}

// MARK: - Cell

extension BatchExportingImageSelectionViewController {
    private final class CellView: TableCellView {
        private let checkbox = CheckboxButton(title: "")

        private let iconImageView = ImageView()

        private let nameLabel = Label()

        private let countLabel = Label()

        override func setup() {
            super.setup()

            hierarchy {
                checkbox
                iconImageView
                nameLabel
                countLabel
            }

            checkbox.snp.makeConstraints { make in
                make.leading.equalToSuperview()
                make.centerY.equalToSuperview()
            }

            iconImageView.snp.makeConstraints { make in
                make.leading.equalTo(checkbox.snp.trailing).offset(4)
                make.centerY.equalToSuperview()
                make.size.equalTo(16)
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.equalTo(iconImageView.snp.trailing).offset(6)
                make.centerY.equalToSuperview()
            }

            countLabel.snp.makeConstraints { make in
                make.leading.greaterThanOrEqualTo(nameLabel.snp.trailing).offset(8)
                make.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }

            // Mixed is only ever set from the tree; a click goes through the tree as well.
            checkbox.allowsMixedState = true

            iconImageView.contentTintColor = .controlAccentColor

            nameLabel.do {
                $0.font = .systemFont(ofSize: 13)
                $0.textColor = .labelColor
                $0.maximumNumberOfLines = 1
                $0.lineBreakMode = .byTruncatingTail
                $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }

            countLabel.do {
                $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                $0.textColor = .secondaryLabelColor
                $0.alignment = .right
                $0.maximumNumberOfLines = 1
                $0.syncStringValueToolTip = false
                $0.setContentCompressionResistancePriority(.required, for: .horizontal)
                $0.setContentHuggingPriority(.required, for: .horizontal)
            }
        }

        func bind(to node: BatchExportingImageTreeNode, toggleNodeRelay: PublishRelay<BatchExportingImageTreeNode>) {
            rx.disposeBag = DisposeBag()

            iconImageView.image = node.imageNode.icon
            nameLabel.stringValue = node.name
            // After `stringValue`, which sets the tooltip to the name.
            nameLabel.toolTip = node.imagePath ?? node.name
            countLabel.isHidden = node.isImage
            checkbox.setAccessibilityLabel(node.name)

            node.$selection.asDriver().driveOnNext { [weak self] selection in
                guard let self else { return }
                checkbox.state = selection.state.controlStateValue
                countLabel.stringValue = "\(selection.selectedImageCount) / \(selection.matchingImageCount)"
                countLabel.toolTip = "\(selection.selectedImageCount) of \(selection.matchingImageCount) images selected"
            }
            .disposed(by: rx.disposeBag)

            checkbox.rx.click.asSignal().emitOnNext { [weak self] in
                guard let self else { return }
                // AppKit has already stepped the box to its next state. The tree decides what it
                // shows, so put the current state back until the new selection arrives.
                checkbox.state = node.selection.state.controlStateValue
                toggleNodeRelay.accept(node)
            }
            .disposed(by: rx.disposeBag)
        }
    }
}

extension BatchExportingImageTreeNode.SelectionState {
    fileprivate var controlStateValue: NSControl.StateValue {
        switch self {
        case .unselected:
            .off
        case .partiallySelected:
            .mixed
        case .selected:
            .on
        }
    }
}

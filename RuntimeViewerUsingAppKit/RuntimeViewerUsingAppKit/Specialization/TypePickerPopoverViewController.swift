import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

/// Popover content for choosing a concrete type for a generic parameter.
///
/// Uses a raw `NSViewController` (rather than `AppKitViewController<VM>`)
/// because the backing `TypePickerPopoverViewModel` is intentionally not a
/// `ViewModelProtocol` conformer — popovers are short-lived UI primitives
/// that don't need the standard error/loading/router infrastructure.
final class TypePickerPopoverViewController: NSViewController {

    private(set) var viewModel: TypePickerPopoverViewModel?

    // MARK: - Subviews

    private let searchField = NSSearchField()
    private let scrollView = ScrollView()
    private let tableView = NSTableView()

    // MARK: - State

    private var candidates: [RuntimeSpecializationRequest.Candidate] = []

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("CandidateCell")

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.hierarchy {
            searchField
            scrollView
        }

        searchField.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(searchField.snp.bottom).offset(8)
            make.leading.trailing.bottom.equalToSuperview().inset(8)
        }

        scrollView.do {
            $0.documentView = tableView
            $0.hasVerticalScroller = true
            $0.borderType = .lineBorder
            $0.autohidesScrollers = true
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        column.title = "Type"
        column.minWidth = 200
        tableView.addTableColumn(column)

        tableView.do {
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.target = self
            $0.action = #selector(tableViewClicked)
            $0.dataSource = self
            $0.delegate = self
            $0.rowHeight = 36
            $0.style = .plain
        }

        searchField.do {
            $0.target = self
            $0.action = #selector(searchTextChanged)
            $0.sendsWholeSearchString = false
            $0.sendsSearchStringImmediately = true
            $0.placeholderString = "Search types…"
        }
    }

    // MARK: - Actions

    @objc private func tableViewClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < candidates.count else { return }
        viewModel?.selectCandidate(candidates[row])
    }

    @objc private func searchTextChanged() {
        viewModel?.updateSearchText(searchField.stringValue)
    }

    // MARK: - Bindings

    func setupBindings(for viewModel: TypePickerPopoverViewModel) {
        loadViewIfNeeded()
        rx.disposeBag = DisposeBag()
        self.viewModel = viewModel

        viewModel.filteredCandidatesRelay
            .asDriver()
            .driveOnNext { [weak self] candidates in
                guard let self else { return }
                self.candidates = candidates
                tableView.reloadData()
            }
            .disposed(by: rx.disposeBag)
    }
}

// MARK: - NSTableViewDataSource

extension TypePickerPopoverViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }
}

// MARK: - NSTableViewDelegate

extension TypePickerPopoverViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < candidates.count else { return nil }
        let cellView: CandidateCellView
        if let recycled = tableView.makeView(
            withIdentifier: TypePickerPopoverViewController.cellIdentifier,
            owner: nil
        ) as? CandidateCellView {
            cellView = recycled
        } else {
            cellView = CandidateCellView()
            cellView.identifier = TypePickerPopoverViewController.cellIdentifier
        }
        cellView.configure(with: candidates[row])
        return cellView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < candidates.count else { return false }
        return !candidates[row].isGeneric
    }
}

// MARK: - CandidateCellView

extension TypePickerPopoverViewController {
    fileprivate final class CandidateCellView: NSTableCellView {
        private let nameLabel = Label()
        private let imageLabel = Label()
        private let genericBadge = Label()

        override init(frame: NSRect) {
            super.init(frame: frame)
            setupViews()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupViews()
        }

        private func setupViews() {
            hierarchy {
                nameLabel
                imageLabel
                genericBadge
            }

            nameLabel.snp.makeConstraints { make in
                make.top.leading.equalToSuperview().inset(4)
                make.trailing.lessThanOrEqualTo(genericBadge.snp.leading).offset(-8)
            }

            imageLabel.snp.makeConstraints { make in
                make.leading.equalTo(nameLabel)
                make.bottom.equalToSuperview().inset(4)
                make.top.equalTo(nameLabel.snp.bottom).offset(2)
                make.trailing.lessThanOrEqualToSuperview().inset(8)
            }

            genericBadge.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                make.trailing.equalToSuperview().inset(8)
            }

            nameLabel.do {
                $0.font = .systemFont(ofSize: 13)
                $0.textColor = .controlTextColor
                $0.lineBreakMode = .byTruncatingTail
            }

            imageLabel.do {
                $0.font = .systemFont(ofSize: 11)
                $0.textColor = .secondaryLabelColor
                $0.lineBreakMode = .byTruncatingMiddle
            }

            genericBadge.do {
                $0.font = .systemFont(ofSize: 10, weight: .medium)
                $0.textColor = .systemRed
                $0.stringValue = "GENERIC"
            }
        }

        func configure(with candidate: RuntimeSpecializationRequest.Candidate) {
            nameLabel.stringValue = candidate.displayName
            imageLabel.stringValue = (candidate.imagePath as NSString).lastPathComponent
            genericBadge.isHidden = !candidate.isGeneric
            let alpha: CGFloat = candidate.isGeneric ? 0.5 : 1.0
            nameLabel.alphaValue = alpha
            imageLabel.alphaValue = alpha
            toolTip = candidate.isGeneric
                ? "Generic candidates require nested specialization, which is not supported in v1."
                : nil
        }
    }
}

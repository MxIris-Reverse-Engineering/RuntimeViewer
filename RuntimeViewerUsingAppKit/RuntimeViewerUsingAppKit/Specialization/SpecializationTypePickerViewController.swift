import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

/// Popover content for choosing a concrete type for a generic parameter.
final class SpecializationTypePickerViewController: UXKitViewController<SpecializationTypePickerViewModel> {
    // MARK: - Subviews

    private let searchField = NSSearchField()

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
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
            $0.autohidesScrollers = true
        }

        tableView.do {
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.usesAutomaticRowHeights = true
            $0.style = .plain
        }

        searchField.do {
            $0.sendsWholeSearchString = false
            $0.sendsSearchStringImmediately = true
            $0.placeholderString = "Search types…"
        }

        preferredContentSize = NSSize(width: 320, height: 320)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: SpecializationTypePickerViewModel) {
        super.setupBindings(for: viewModel)

        let candidateClicked: Signal<RuntimeSpecializationRequest.Candidate> = tableView.rx
            .itemClicked()
            .compactMap { [weak tableView] index -> RuntimeSpecializationRequest.Candidate? in
                guard let tableView,
                      index.row >= 0,
                      index.row < tableView.numberOfRows
                else { return nil }
                return try? tableView.rx.model(at: index.row)
            }
            .asSignal(onErrorSignalWith: .empty())

        let input = SpecializationTypePickerViewModel.Input(
            searchString: searchField.rx.stringValue.asSignal(onErrorJustReturn: ""),
            candidateClicked: candidateClicked
        )
        let output = viewModel.transform(input)

        output.filteredCandidates
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, candidate: RuntimeSpecializationRequest.Candidate) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CandidateCellView.self)
                cellView.configure(with: candidate)
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }
}

// `Candidate` is `Hashable`; DifferenceKit synthesizes default identifier and
// content-equality implementations from `Hashable` + `Equatable`.
extension RuntimeSpecializationRequest.Candidate: @retroactive Differentiable {}

// MARK: - CandidateCellView

extension SpecializationTypePickerViewController {
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
                $0.textColor = .systemBlue
                $0.stringValue = "NESTED"
            }
        }

        func configure(with candidate: RuntimeSpecializationRequest.Candidate) {
            nameLabel.stringValue = candidate.displayName
            imageLabel.stringValue = (candidate.imagePath as NSString).lastPathComponent
            genericBadge.isHidden = !candidate.isGeneric
            nameLabel.alphaValue = 1.0
            imageLabel.alphaValue = 1.0
            toolTip = candidate.isGeneric
                ? "Selecting this opens a nested specialization for the type's own generic parameters."
                : nil
        }
    }
}

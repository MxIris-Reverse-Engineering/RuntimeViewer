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
            $0.hasHorizontalScroller = false
        }

        tableView.do {
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.usesAutomaticRowHeights = true
            $0.style = .inset
            $0.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            $0.tableColumns.first?.resizingMask = [.autoresizingMask]
        }

        // Force tableView width to match the scroll view's content area,
        // otherwise cell intrinsic (driven by long title labels) would
        // grow the column and cause horizontal overflow instead of
        // truncation.
        tableView.snp.makeConstraints { make in
            make.width.equalTo(scrollView.contentView)
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

        let cellViewModelClicked: Signal<SpecializationTypePickerCellViewModel> = tableView.rx
            .itemClicked()
            .compactMap { [weak tableView] index -> SpecializationTypePickerCellViewModel? in
                guard let tableView,
                      index.row >= 0,
                      index.row < tableView.numberOfRows
                else { return nil }
                return try? tableView.rx.model(at: index.row)
            }
            .asSignal(onErrorSignalWith: .empty())

        let input = SpecializationTypePickerViewModel.Input(
            searchString: searchField.rx.stringValue.asSignal(onErrorJustReturn: ""),
            cellViewModelClicked: cellViewModelClicked
        )
        let output = viewModel.transform(input)

        output.filteredCellViewModels
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: SpecializationTypePickerCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<SpecializationTypePickerCellViewModel>.self) { .init(contentInsets: .init(top: 4, left: 4, bottom: 4, right: 4)) }
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)
    }
}

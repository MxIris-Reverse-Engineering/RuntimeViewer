import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

final class InspectorSwiftSpecializationViewController: UXEffectViewController<InspectorSwiftSpecializationViewModel> {
    // MARK: - Subviews

    private let headerLabel = Label()
    private let emptyLabel = Label()
    private let (scrollView, tableView): (SelfSizingScrollView, SelfSizingTableView) = SelfSizingTableView.scrollableTableView()
    private let addSpecializationButton = PushButton(
        title: "+ Add Specialization",
        titleFont: .systemFont(ofSize: 13)
    )

    override var contentViewUsingSafeArea: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            headerLabel
            scrollView
            emptyLabel
            addSpecializationButton
        }

        headerLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
//            make.bottom.lessThanOrEqualTo(addSpecializationButton.snp.top).offset(-8)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        addSpecializationButton.snp.makeConstraints { make in
            make.top.equalTo(scrollView.snp.bottom).offset(8)
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
            make.leading.greaterThanOrEqualToSuperview()
            make.bottom.lessThanOrEqualToSuperview()
        }

        tableView.do {
            $0.backgroundColor = .clear
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.usesAutomaticRowHeights = true
            $0.style = .sourceList
        }

        scrollView.do {
            $0.isHiddenVisualEffectView = true
            $0.autohidesScrollers = true
            $0.backgroundColor = .clear
            $0.minimumContentSize = NSSize(width: NSView.noIntrinsicMetric, height: 80)
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
            $0.stringValue = "Specializations"
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        emptyLabel.do {
            $0.textColor = .secondaryLabelColor
            $0.stringValue = "No specializations yet."
            $0.isHidden = true
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: InspectorSwiftSpecializationViewModel) {
        super.setupBindings(for: viewModel)

        let selectSpecialization: Signal<InspectorSwiftSpecializationCellViewModel> = tableView.rx
            .itemClicked()
            .compactMap { [weak tableView] index -> InspectorSwiftSpecializationCellViewModel? in
                guard let tableView,
                      index.row >= 0,
                      index.row < tableView.numberOfRows
                else { return nil }
                return try? tableView.rx.model(at: index.row)
            }
            .asSignal(onErrorSignalWith: .empty())

        let input = InspectorSwiftSpecializationViewModel.Input(
            addSpecializationClicked: addSpecializationButton.rx.click.asSignal(),
            selectSpecializationClicked: selectSpecialization
        )

        let output = viewModel.transform(input)

        let specializedChildren = output.specializedChildren

        specializedChildren
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorSwiftSpecializationCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<InspectorSwiftSpecializationCellViewModel>.self) {
                    .init(contentInsets: .init(top: 0, left: 4, bottom: 0, right: 4))
                }
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        specializedChildren
            .map(\.isEmpty)
            .not()
            .drive(emptyLabel.rx.isHidden)
            .disposed(by: rx.disposeBag)
    }
}

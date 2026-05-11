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
    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()
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
            make.top.leading.trailing.equalToSuperview().inset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
            make.bottom.equalTo(addSpecializationButton.snp.top).offset(-8)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        addSpecializationButton.snp.makeConstraints { make in
            make.bottom.trailing.equalToSuperview().inset(8)
        }

        tableView.do {
            $0.backgroundColor = .clear
            $0.headerView = nil
            $0.allowsMultipleSelection = false
            $0.allowsEmptySelection = true
            $0.rowHeight = 28
            $0.style = .inset
        }

        scrollView.do {
            $0.autohidesScrollers = true
            $0.backgroundColor = .clear
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .controlTextColor
        }

        emptyLabel.do {
            $0.font = .systemFont(ofSize: 13)
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

        let displayName = viewModel.runtimeObjectDisplayName
        headerLabel.stringValue = displayName.isEmpty
            ? "Specializations"
            : "Specializations of \(displayName)"

        let specializedChildren = output.specializedChildren

        specializedChildren
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorSwiftSpecializationCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: SpecializedChildCellView.self)
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

// MARK: - SpecializedChildCellView

extension InspectorSwiftSpecializationViewController {
    private final class SpecializedChildCellView: TableCellView {
        private let nameLabel = Label()

        override func setup() {
            super.setup()

            hierarchy {
                nameLabel
            }

            nameLabel.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }

            nameLabel.do {
                $0.maximumNumberOfLines = 1
            }
        }

        func bind(to viewModel: InspectorSwiftSpecializationCellViewModel) {
            rx.disposeBag = DisposeBag()

            viewModel.$name.asDriver().drive(nameLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
        }
    }
}

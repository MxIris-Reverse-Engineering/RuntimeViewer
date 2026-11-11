import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

final class InspectorSwiftSpecializationViewController: BaseEffectViewController<InspectorSwiftSpecializationViewModel> {
    // MARK: - Relays

    /// Commands chosen in a row's context menu.
    private let runtimeObjectActionRequestedRelay = PublishRelay<RuntimeObjectActionRequest>()

    // MARK: - Subviews

    private let headerLabel = Label()
    private let emptyLabel = Label()
    private let (scrollView, tableView) = SelfSizingTableView.scrollableNavigationListTableView()
    private let addSpecializationButton = PushButton(
        title: "+ Add Specialization",
        titleFont: .systemFont(ofSize: 13)
    )

    override var containerViewUsingSafeArea: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            headerLabel
            scrollView
            emptyLabel
            addSpecializationButton
        }

        // At the page's top edge: the tab switcher leaves the gap above the page (`TabViewController.pageTopSpacing`).
        headerLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
        }

        addSpecializationButton.snp.makeConstraints { make in
            make.top.equalTo(scrollView.snp.bottom).offset(8)
            make.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
            make.leading.greaterThanOrEqualToSuperview()
            make.bottom.lessThanOrEqualToSuperview().offset(-8)
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

        // A plain click opens the row in place; ⌥ and ⇧⌥ open it elsewhere, as
        // in the sidebar.
        let rowClicks = tableView.rx.rowClicks(of: InspectorSwiftSpecializationCellViewModel.self)

        tableView.installContextMenu { [weak tableView, runtimeObjectActionRequestedRelay] clickedRow in
            guard let tableView, let cellViewModel: InspectorSwiftSpecializationCellViewModel = try? tableView.rx.model(at: clickedRow) else { return [] }
            return RuntimeObjectAction.contextMenuItems(for: cellViewModel.runtimeObject, reportingTo: runtimeObjectActionRequestedRelay)
        }
        .disposed(by: rx.disposeBag)

        let input = InspectorSwiftSpecializationViewModel.Input(
            addSpecializationClicked: addSpecializationButton.rx.click.asSignal(),
            selectSpecializationClicked: rowClicks.filter { $0.destination == .focusedTab }.map(\.model),
            runtimeObjectActionRequested: .merge(
                rowClicks.compactMap { RuntimeObjectAction.request(for: $0.model.runtimeObject, clickedTowards: $0.destination) },
                runtimeObjectActionRequestedRelay.asSignal()
            )
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

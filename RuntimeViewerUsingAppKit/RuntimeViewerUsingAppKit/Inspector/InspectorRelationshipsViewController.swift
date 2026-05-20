import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

final class InspectorRelationshipsViewController: UXEffectViewController<InspectorRelationshipsViewModel> {
    private let headerLabel = Label()
    private let emptyLabel = Label()
    private let (scrollView, tableView): (SelfSizingScrollView, SelfSizingTableView) = SelfSizingTableView.scrollableTableView()

    override var contentViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            headerLabel
            scrollView
            emptyLabel
        }

        headerLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide)
        }

        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(scrollView)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
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
            // The inspector container chain (NSTabView -> navigation controller
            // -> split item) sizes itself to content, so an external
            // `lessThanOrEqualTo` constraint cannot cap the scroll view -- its
            // anchor moves down with the content. `maximumContentSize` is the
            // only reliable cap: it clamps `intrinsicContentSize` at the source,
            // after which the table scrolls internally beyond this height.
            $0.minimumContentSize = NSSize(width: NSView.noIntrinsicMetric, height: 80)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        emptyLabel.do {
            $0.textColor = .secondaryLabelColor
            $0.alignment = .center
            $0.isHidden = true
        }
    }

    override func setupBindings(for viewModel: InspectorRelationshipsViewModel) {
        super.setupBindings(for: viewModel)

        let selectRelationship: Signal<InspectorRelationshipsCellViewModel> = tableView.rx
            .itemClicked()
            .compactMap { [weak tableView] index -> InspectorRelationshipsCellViewModel? in
                guard let tableView,
                      index.row >= 0,
                      index.row < tableView.numberOfRows
                else { return nil }
                return try? tableView.rx.model(at: index.row)
            }
            .asSignal(onErrorSignalWith: .empty())

        let input = InspectorRelationshipsViewModel.Input(
            selectRelationshipClicked: selectRelationship
        )
        let output = viewModel.transform(input)

        output.rows
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorRelationshipsCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<InspectorRelationshipsCellViewModel>.self) {
                    .init(contentInsets: .init(top: 0, left: 4, bottom: 0, right: 4))
                }
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.sectionTitle.drive(headerLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.emptyMessage.drive(emptyLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.isEmpty.map { !$0 }.drive(emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)
        output.isEmpty.drive(scrollView.rx.isHidden).disposed(by: rx.disposeBag)
    }
}

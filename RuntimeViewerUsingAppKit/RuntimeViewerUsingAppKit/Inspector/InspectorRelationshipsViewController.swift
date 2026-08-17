import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SnapKit

final class InspectorRelationshipsViewController: EffectViewController<InspectorRelationshipsViewModel> {
    private let headerLabel = Label()
    
    private let emptyLabel = Label(wrappingLabelWithString: "")
    
    private let (scrollView, tableView) = SelfSizingTableView.scrollableNavigationListTableView()

    private let skeletonPlaceholderView = SkeletonPlaceholderView.runtimeObjectList()

    override var contentViewUsingSafeArea: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            headerLabel
            scrollView
            emptyLabel
            skeletonPlaceholderView
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

        skeletonPlaceholderView.snp.makeConstraints { make in
            make.top.equalTo(headerLabel.snp.bottom).offset(12)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
            // Preference, not requirement: in a pane too short for the whole
            // placeholder it is better to let it run past the bottom edge than
            // to break a required constraint.
            make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).priority(.high)
        }

        tableView.do {
            $0.intercellSpacing = .init(width: 0, height: 10)
            // Clicking a row navigates away immediately, so keyboard focus
            // here has nothing to act on. Taking first responder would only
            // make the sidebar draw its selection unemphasized for the ~50ms
            // until the new selection lands — a grey blink on the row the
            // user is looking at, for focus the app hands straight back.
            $0.refusesFirstResponder = true
        }

        headerLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        emptyLabel.do {
            $0.textColor = .secondaryLabelColor
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
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

        // Bound before the visibility binding below so that when a query
        // finishes, the table already holds the new rows by the time the
        // placeholder is taken down. `compactMap` drops the `.loading` state
        // entirely: the stale rows stay in the (hidden) table rather than
        // being reloaded away and reloaded back.
        output.state
            .compactMap { state -> [InspectorRelationshipsCellViewModel]? in
                guard case .loaded(let rows) = state else { return nil }
                return rows
            }
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorRelationshipsCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<InspectorRelationshipsCellViewModel>.self) {
                    .init(contentInsets: .init(top: 0, left: 4, bottom: 0, right: 4))
                }
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.state.driveOnNext { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading:
                skeletonPlaceholderView.isPresentingPlaceholder = true
                scrollView.isHidden = true
                emptyLabel.isHidden = true
            case .loaded(let rows):
                skeletonPlaceholderView.isPresentingPlaceholder = false
                scrollView.isHidden = rows.isEmpty
                emptyLabel.isHidden = !rows.isEmpty
            }
        }
        .disposed(by: rx.disposeBag)

        output.sectionTitle.drive(headerLabel.rx.stringValue).disposed(by: rx.disposeBag)
        output.emptyMessage.drive(emptyLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

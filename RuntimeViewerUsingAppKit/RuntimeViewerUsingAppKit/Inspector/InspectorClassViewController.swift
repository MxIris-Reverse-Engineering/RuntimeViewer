import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class InspectorClassViewController: BaseEffectViewController<InspectorClassViewModel> {
    private let classHierarchyView = InspectorClassHierarchyView()

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            classHierarchyView
        }

        // As tall as its levels, and no taller than the pane: past that the
        // list scrolls.
        classHierarchyView.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(containerView.safeAreaLayoutGuide)
            make.bottom.lessThanOrEqualTo(containerView.safeAreaLayoutGuide)
        }
    }

    override func setupBindings(for viewModel: InspectorClassViewModel) {
        super.setupBindings(for: viewModel)

        let tableView = classHierarchyView.tableView

        let selectHierarchyLevel: Signal<InspectorClassHierarchyCellViewModel> = tableView.rx
            .itemClicked()
            .compactMap { [weak tableView] index -> InspectorClassHierarchyCellViewModel? in
                guard let tableView,
                      index.row >= 0,
                      index.row < tableView.numberOfRows
                else { return nil }
                return try? tableView.rx.model(at: index.row)
            }
            .asSignal(onErrorSignalWith: .empty())

        let input = InspectorClassViewModel.Input(
            selectHierarchyLevelClicked: selectHierarchyLevel
        )
        let output = viewModel.transform(input)

        // Bound before the visibility binding below so that when a fetch
        // finishes, the table already holds the new levels by the time the
        // placeholder is taken down. `compactMap` drops the `.loading` state
        // entirely: the stale levels stay in the (hidden) table rather than
        // being reloaded away and reloaded back.
        output.hierarchyState
            .compactMap { hierarchyState -> [InspectorClassHierarchyCellViewModel]? in
                guard case .loaded(let levels) = hierarchyState else { return nil }
                return levels
            }
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, cellViewModel: InspectorClassHierarchyCellViewModel) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: RuntimeObjectCellView<InspectorClassHierarchyCellViewModel>.self) {
                    .init(contentInsets: .init(top: 0, left: 4, bottom: 0, right: 4))
                }
                cellView.bind(to: cellViewModel)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.hierarchyState.driveOnNext { [weak self] hierarchyState in
            guard let self else { return }
            classHierarchyView.apply(hierarchyState)
        }
        .disposed(by: rx.disposeBag)
    }
}

import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class InspectorClassViewController: BaseEffectViewController<InspectorClassViewModel> {
    private let classHierarchyView = InspectorClassHierarchyView()

    private lazy var contentStackView = VStackView {
        classHierarchyView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.edges.equalTo(contentView.safeAreaLayoutGuide)
        }
    }

    override func setupBindings(for viewModel: InspectorClassViewModel) {
        super.setupBindings(for: viewModel)

        let input = InspectorClassViewModel.Input()
        let output = viewModel.transform(input)

        output.hierarchyState.driveOnNext { [weak self] hierarchyState in
            guard let self else { return }
            classHierarchyView.apply(hierarchyState)
        }
        .disposed(by: rx.disposeBag)
    }
}

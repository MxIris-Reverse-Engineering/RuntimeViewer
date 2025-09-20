import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class InspectorClassViewController: UXEffectViewController<InspectorClassViewModel> {
    let classHierarchyView = InspectorClassHierarchyView()

    lazy var contentStackView = VStackView {
        classHierarchyView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
    }

    override func setupBindings(for viewModel: InspectorClassViewModel) {
        super.setupBindings(for: viewModel)

        let input = InspectorClassViewModel.Input()
        let output = viewModel.transform(input)
        output.classHierarchy.drive(classHierarchyView.contentView.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

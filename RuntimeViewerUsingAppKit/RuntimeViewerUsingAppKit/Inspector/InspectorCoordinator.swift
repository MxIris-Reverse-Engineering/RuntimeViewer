import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorNavigationController>

final class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    let documentState: DocumentState

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController], animated: true)
        case .root(let inspectableObject):
            return .set([makeTransition(for: inspectableObject)], animated: true)
        case .next(let inspectableObject):
            return .push(makeTransition(for: inspectableObject), animated: true)
        case .back:
            return .pop(animated: true)
        }
    }

    func makeTransition(for inspectableObject: InspectableObject) -> UXViewController {
        switch inspectableObject {
        case .node:
            let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return viewController
        case .object(let runtimeObject):
            switch runtimeObject.kind {
            case .objc(.type(.class)), .swift(.type(.class)):
                let viewModel = InspectorClassViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
                let viewController = InspectorClassViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
            default:
                let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
                let viewController = InspectorPlaceholderViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
            }
        }
    }
}

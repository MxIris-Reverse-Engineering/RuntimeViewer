import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorNavigationController>

class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    let appServices: AppServices

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController], animated: false)
        case .root(let inspectableObject):
            return .set([makeTransition(for: inspectableObject)], animated: false)
        case .next(let inspectableObject):
            return .push(makeTransition(for: inspectableObject), animated: false)
        case .back:
            return .pop(animated: false)
        }
    }

    func makeTransition(for inspectableObject: InspectableObject) -> UXViewController {
        switch inspectableObject {
        case .node:
            let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return viewController
        case .object(let runtimeObjectName):
            switch runtimeObjectName.kind {
            case .objc(.class):
                let viewModel = InspectorClassViewModel(runtimeClassName: runtimeObjectName.name, appServices: appServices, router: self)
                let viewController = InspectorClassViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
//            case .protocol:
            default:
                let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
                let viewController = InspectorPlaceholderViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
            }
        }
    }
}

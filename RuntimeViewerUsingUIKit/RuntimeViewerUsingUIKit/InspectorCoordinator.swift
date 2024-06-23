#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<InspectorViewController>

class InspectorCoordinator: BaseCoordinator<InspectorRoute, InspectorTransition> {
    let appServices: AppServices
    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .root)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .root:
            let viewModel = InspectorViewModel(appServices: appServices, router: self)
            rootViewController.setupBindings(for: viewModel)
            return .none()
        case let .select(inspectableType):
            return .none()
        }
    }
}

#endif

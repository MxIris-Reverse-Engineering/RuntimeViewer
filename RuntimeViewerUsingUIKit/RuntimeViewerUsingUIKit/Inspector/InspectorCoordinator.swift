#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<InspectorViewController>

class InspectorCoordinator: BaseCoordinator<InspectorRoute, InspectorTransition> {
    let appState: AppState
    init(appState: AppState) {
        self.appState = appState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            let viewModel = InspectorPlaceholderViewModel(appState: appState, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController])
        default:
            return .none()
        }
    }
}

#endif

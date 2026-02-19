#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<InspectorViewController>

class InspectorCoordinator: BaseCoordinator<InspectorRoute, InspectorTransition> {
    let documentState: DocumentState
    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController])
        default:
            return .none()
        }
    }
}

#endif

#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

protocol SidebarCoordinatorDelegate: AnyObject {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition: SidebarRoute)
}

typealias SidebarTransition = NavigationTransition

class SidebarCoordinator: NavigationCoordinator<SidebarRoute> {
    let appState: AppState

    weak var coordinatorDelegate: SidebarCoordinatorDelegate?

    init(appState: AppState, delegate: SidebarCoordinatorDelegate? = nil) {
        self.appState = appState
        self.coordinatorDelegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .root)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            let viewController = SidebarRootViewController()
            let viewModel = SidebarRootDirectoryViewModel(appState: appState, router: self)
            viewController.setupBindings(for: viewModel)
            return .set([viewController], animation: nil)
        case let .clickedNode(clickedNode):
            let viewController = SidebarRuntimeObjectViewController()
            let viewModel = SidebarRuntimeObjectListViewModel(imageNode: clickedNode, appState: appState, router: self)
            viewController.setupBindings(for: viewModel)
            return .push(viewController, animation: .default)
        case .back:
            return .pop(animation: .default)
        default:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRoute) {
        coordinatorDelegate?.sidebarCoordinator(self, completeTransition: route)
    }
}

#endif

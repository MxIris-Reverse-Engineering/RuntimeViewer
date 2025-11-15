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
    let appServices: AppServices

    weak var coordinatorDelegate: SidebarCoordinatorDelegate?

    init(appServices: AppServices, delegate: SidebarCoordinatorDelegate? = nil) {
        self.appServices = appServices
        self.coordinatorDelegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .root)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            let viewController = SidebarRootViewController()
            let viewModel = SidebarRootViewModel(appServices: appServices, router: self)
            viewController.setupBindings(for: viewModel)
            return .set([viewController], animation: nil)
        case let .clickedNode(clickedNode):
            let imageViewController = SidebarImageViewController()
            let imageViewModel = SidebarImageViewModel(node: clickedNode, appServices: appServices, router: self)
            imageViewController.setupBindings(for: imageViewModel)
            return .push(imageViewController, animation: .default)
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

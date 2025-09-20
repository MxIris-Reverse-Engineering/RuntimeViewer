import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SidebarTransition = Transition<Void, SidebarNavigationController>

class SidebarCoordinator: ViewCoordinator<SidebarRoute, SidebarTransition> {
    protocol Delegate: AnyObject {
        func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition: SidebarRoute)
    }

    let appServices: AppServices

    weak var delegate: Delegate?

    init(appServices: AppServices, delegate: Delegate? = nil) {
        self.appServices = appServices
        self.delegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            let viewController = SidebarRootViewController()
            let viewModel = SidebarRootViewModel(appServices: appServices, router: self)
            viewController.setupBindings(for: viewModel)
            return .push(viewController, animated: false)
        case .clickedNode(let clickedNode):
            let imageViewController = SidebarImageViewController()
            let imageViewModel = SidebarImageViewModel(node: clickedNode, appServices: appServices, router: self)
            imageViewController.setupBindings(for: imageViewModel)
            return .push(imageViewController, animated: true)
        case .back:
            return .pop(animated: true)
        default:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRoute) {
        super.completeTransition(for: route)
        delegate?.sidebarCoordinator(self, completeTransition: route)
    }
}


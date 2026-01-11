import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SidebarTransition = Transition<Void, SidebarNavigationController>

final class SidebarCoordinator: ViewCoordinator<SidebarRoute, SidebarTransition> {
    protocol Delegate: AnyObject {
        func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute)
    }

    let appServices: AppServices

    weak var delegate: Delegate?

    private var rootCoordinator: SidebarRootCoordinator?

    private var runtimeObjectCoordinator: SidebarRuntimeObjectCoordinator?

    init(appServices: AppServices, delegate: Delegate? = nil) {
        self.appServices = appServices
        self.delegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            rootCoordinator?.removeFromParent()
            let rootCoordinator = SidebarRootCoordinator(appServices: appServices)
            rootCoordinator.delegate = self
            self.rootCoordinator = rootCoordinator
            return .set([rootCoordinator], animated: false)
        case .clickedNode(let imageNode):
            runtimeObjectCoordinator?.removeFromParent()
            let runtimeObjectCoordinator = SidebarRuntimeObjectCoordinator(appServices: appServices, delegate: self, imageNode: imageNode)
            self.runtimeObjectCoordinator = runtimeObjectCoordinator
            return .push(runtimeObjectCoordinator, animated: true)
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

extension SidebarCoordinator: SidebarRootCoordinator.Delegate {
    func sidebarRootCoordinator(_ sidebarCoordinator: SidebarRootCoordinator, completeTransition route: SidebarRootRoute) {
        switch route {
        case .image(let imageNode):
            trigger(.clickedNode(imageNode))
        default:
            break
        }
    }
}

extension SidebarCoordinator: SidebarRuntimeObjectCoordinator.Delegate {
    func sidebarRuntimeObjectCoordinator(_ sidebarCoordinator: SidebarRuntimeObjectCoordinator, completeTransition route: SidebarRuntimeObjectRoute) {
        switch route {
        case .selectedObject(let runtimeObjectName):
            trigger(.selectedObject(runtimeObjectName))
        default:
            break
        }
    }
}

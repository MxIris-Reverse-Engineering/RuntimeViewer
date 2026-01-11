import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRuntimeObjectTransition = Transition<Void, SidebarRuntimeObjectTabViewController>

final class SidebarRuntimeObjectCoordinator: ViewCoordinator<SidebarRuntimeObjectRoute, SidebarRuntimeObjectTransition> {
    protocol Delegate: AnyObject {
        func sidebarRuntimeObjectCoordinator(_ sidebarCoordinator: SidebarRuntimeObjectCoordinator, completeTransition route: SidebarRuntimeObjectRoute)
    }

    let appServices: AppServices

    weak var delegate: Delegate?

    let imageNode: RuntimeImageNode

    init(appServices: AppServices, delegate: Delegate? = nil, imageNode: RuntimeImageNode) {
        self.appServices = appServices
        self.delegate = delegate
        self.imageNode = imageNode
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .initial)
    }

    override func prepareTransition(for route: SidebarRuntimeObjectRoute) -> SidebarRuntimeObjectTransition {
        switch route {
        case .initial:
            let listViewController = SidebarRuntimeObjectListViewController()
            let listViewModel = SidebarRuntimeObjectListViewModel(imageNode: imageNode, appServices: appServices, router: self)
            listViewController.setupBindings(for: listViewModel)

            let bookmarkViewController = SidebarRuntimeObjectBookmarkViewController()
            let bookmarkViewModel = SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, appServices: appServices, router: self)
            bookmarkViewController.setupBindings(for: bookmarkViewModel)
            return .set([(SFSymbols(systemName: .folder), listViewController), (SFSymbols(systemName: .bookmark), bookmarkViewController)])
        case .objects:
            return .select(index: 0)
        case .bookmarks:
            return .select(index: 1)
        default:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRuntimeObjectRoute) {
        super.completeTransition(for: route)

        delegate?.sidebarRuntimeObjectCoordinator(self, completeTransition: route)
    }
}

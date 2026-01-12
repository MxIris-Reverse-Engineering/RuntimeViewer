import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRootTransition = Transition<Void, SidebarRootTabViewController>

final class SidebarRootCoordinator: ViewCoordinator<SidebarRootRoute, SidebarRootTransition> {
    protocol Delegate: AnyObject {
        func sidebarRootCoordinator(_ sidebarCoordinator: SidebarRootCoordinator, completeTransition: SidebarRootRoute)
    }

    let appServices: AppServices

    weak var delegate: Delegate?

    init(appServices: AppServices, delegate: Delegate? = nil) {
        self.appServices = appServices
        self.delegate = delegate
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: SidebarRootRoute) -> SidebarRootTransition {
        switch route {
        case .initial:
            let directoryViewController = SidebarRootDirectoryViewController()
            let directoryViewModel = SidebarRootDirectoryViewModel(appServices: appServices, router: self)
            directoryViewController.setupBindings(for: directoryViewModel)

            let bookmarkViewController = SidebarRootBookmarkViewController()
            let bookmarkViewModel = SidebarRootBookmarkViewModel(appServices: appServices, router: self)
            bookmarkViewController.setupBindings(for: bookmarkViewModel)
            return .set([
                TabViewItem(normalSymbol: .init(systemName: .folder), selectedSymbol: .init(systemName: .folderFill), viewController: directoryViewController),
                TabViewItem(normalSymbol: .init(systemName: .bookmark), selectedSymbol: .init(systemName: .bookmarkFill), viewController: bookmarkViewController),
            ])
        case .directory:
            return .select(index: 0)
        case .bookmarks:
            return .select(index: 1)
        default:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRootRoute) {
        super.completeTransition(for: route)

        delegate?.sidebarRootCoordinator(self, completeTransition: route)
    }
}



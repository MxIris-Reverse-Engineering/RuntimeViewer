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

    let documentState: DocumentState

    weak var delegate: Delegate?

    let imageNode: RuntimeImageNode

    init(documentState: DocumentState, delegate: Delegate? = nil, imageNode: RuntimeImageNode) {
        self.documentState = documentState
        self.delegate = delegate
        self.imageNode = imageNode
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: SidebarRuntimeObjectRoute) -> SidebarRuntimeObjectTransition {
        switch route {
        case .initial:
            let listViewController = SidebarRuntimeObjectListViewController()
            let listViewModel = SidebarRuntimeObjectListViewModel(imageNode: imageNode, documentState: documentState, router: self)
            listViewController.setupBindings(for: listViewModel)

            let bookmarkViewController = SidebarRuntimeObjectBookmarkViewController()
            let bookmarkViewModel = SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, documentState: documentState, router: self)
            bookmarkViewController.setupBindings(for: bookmarkViewModel)
            
            return .set([
                TabViewItem(normalSymbol: .init(systemName: .folder), selectedSymbol: .init(systemName: .folderFill), viewController: listViewController),
                TabViewItem(normalSymbol: .init(systemName: .bookmark), selectedSymbol: .init(systemName: .bookmarkFill), viewController: bookmarkViewController),
            ])
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

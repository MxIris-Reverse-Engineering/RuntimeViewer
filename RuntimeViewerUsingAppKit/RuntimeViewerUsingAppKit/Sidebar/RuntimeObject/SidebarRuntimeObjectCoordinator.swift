import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRuntimeObjectTransition = Transition<Void, SidebarRuntimeObjectTabViewController>

final class SidebarRuntimeObjectCoordinator: ViewCoordinator<SidebarRuntimeObjectRoute, SidebarRuntimeObjectTransition> {
    let documentState: DocumentState

    let imageNode: RuntimeImageNode

    private weak var listViewModel: SidebarRuntimeObjectListViewModel?

    init(documentState: DocumentState, imageNode: RuntimeImageNode) {
        self.documentState = documentState
        self.imageNode = imageNode
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    /// Drives the visual selection in the underlying list — independent of
    /// `DocumentState.selectionStack`, which is the data-level source of
    /// truth. Called by `SidebarCoordinator.programmaticallySelect(_:)`
    /// during the `.selectAtRoot` intent fan-out (sidebar row click is
    /// idempotent; specialization completion uses it to scroll-to-and-
    /// highlight the newly produced object).
    func programmaticallySelect(_ object: RuntimeObject) {
        listViewModel?.selectRuntimeObject(object)
    }

    override func prepareTransition(for route: SidebarRuntimeObjectRoute) -> SidebarRuntimeObjectTransition {
        switch route {
        case .initial:
            let listViewController = SidebarRuntimeObjectListViewController()
            let listViewModel = SidebarRuntimeObjectListViewModel(imageNode: imageNode, documentState: documentState, router: self)
            listViewController.setupBindings(for: listViewModel)
            self.listViewModel = listViewModel

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
        }
    }
}

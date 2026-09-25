import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRuntimeObjectTransition = Transition<Void, SidebarRuntimeObjectTabViewController>

final class SidebarRuntimeObjectCoordinator: ViewCoordinator<SidebarRuntimeObjectRoute, SidebarRuntimeObjectTransition> {
    let documentState: DocumentState

    let imageNode: RuntimeImageNode

    /// Kept for `.revealSelectedRuntimeObject`, which the list answers itself.
    private var listViewModel: SidebarRuntimeObjectListViewModel?

    init(documentState: DocumentState, imageNode: RuntimeImageNode) {
        self.documentState = documentState
        self.imageNode = imageNode
        super.init(rootViewController: .init(), initialRoute: .initial)
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
        case .revealSelectedRuntimeObject:
            // Revealing always happens in the object list, never among the
            // bookmarks, so its tab comes first. The request itself is sent
            // when the transition is performed, not while it is prepared:
            // `.route(on:to:)` prepares a child's transition as soon as the
            // parent's is built, which can be before the steps ahead of it —
            // expanding a collapsed sidebar — have run.
            return .multiple(
                .select(index: 0),
                SidebarRuntimeObjectTransition(presentables: []) { [weak self] _, _, _, completion in
                    self?.listViewModel?.revealSelectedRuntimeObject()
                    completion?()
                }
            )
        case .scope(let sender, let relay, let availableKinds, let availableProperties):
            let viewController = SidebarRuntimeObjectScopeViewController()
            let viewModel = SidebarRuntimeObjectScopeViewModel<SidebarRuntimeObjectRoute>(
                relay: relay,
                availableKinds: availableKinds,
                availableProperties: availableProperties,
                documentState: documentState,
                router: self
            )
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        }
    }
}

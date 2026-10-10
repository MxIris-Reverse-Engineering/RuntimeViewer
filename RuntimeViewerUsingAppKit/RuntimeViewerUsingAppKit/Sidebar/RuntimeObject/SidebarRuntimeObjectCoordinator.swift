import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRuntimeObjectTransition = Transition<Void, SidebarRuntimeObjectTabViewController>

final class SidebarRuntimeObjectCoordinator: ViewCoordinator<SidebarRuntimeObjectRoute, SidebarRuntimeObjectTransition> {
    let documentState: DocumentState

    let imageNode: RuntimeImageNode

    /// Kept for `.revealSelectedRuntimeObject`, which the list answers itself,
    /// and for `.privateDeclaration`, whose popover recovers source files
    /// from the objects the list holds.
    private var listViewModel: SidebarRuntimeObjectListViewModel?

    /// The two lists whose rows carry tags, asked for the tag a popover
    /// anchors at. The tab view controller owns them.
    private weak var listViewController: SidebarRuntimeObjectListViewController?

    private weak var bookmarkViewController: SidebarRuntimeObjectBookmarkViewController?

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
            self.listViewController = listViewController

            let bookmarkViewController = SidebarRuntimeObjectBookmarkViewController()
            let bookmarkViewModel = SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, documentState: documentState, router: self)
            bookmarkViewController.setupBindings(for: bookmarkViewModel)
            self.bookmarkViewController = bookmarkViewController

            let findViewController = FindViewController<SidebarRuntimeObjectRoute>()
            let findViewModel = FindViewModel<SidebarRuntimeObjectRoute>(documentState: documentState, router: self)
            findViewController.setupBindings(for: findViewModel)

            let reportViewController = ReportViewController<SidebarRuntimeObjectRoute>()
            let reportViewModel = ReportViewModel<SidebarRuntimeObjectRoute>(documentState: documentState, router: self)
            reportViewController.setupBindings(for: reportViewModel)

            return .set([
                TabViewItem(normalSymbol: .init(systemName: .folder), selectedSymbol: .init(systemName: .folderFill), viewController: listViewController),
                TabViewItem(normalSymbol: .init(systemName: .bookmark), selectedSymbol: .init(systemName: .bookmarkFill), viewController: bookmarkViewController),
                TabViewItem(normalSymbol: .init(systemName: .magnifyingglass), selectedSymbol: .init(systemName: .magnifyingglass), viewController: findViewController),
                // Marked while work is in progress.
                TabViewItem(normalSymbol: .reportNavigator, selectedSymbol: .reportNavigator, viewController: reportViewController, activity: documentState.reportActivity),
            ])
        case .objects:
            return .select(index: 0)
        case .bookmarks:
            return .select(index: 1)
        case .find:
            return .multiple(
                .select(index: 2),
                SidebarRuntimeObjectTransition(presentables: []) { [documentState] _, _, _, completion in
                    documentState.findSession.focusSearchFieldRelay.accept(())
                    completion?()
                }
            )
        case .findScopeChooser:
            let viewController = FindScopeChooserViewController<SidebarRuntimeObjectRoute>()
            let viewModel = FindScopeChooserViewModel<SidebarRuntimeObjectRoute>(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asSheet)
        case .dismissFindScopeChooser:
            return .dismiss()
        case .reports:
            return .select(index: 3)
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
        case .privateDeclaration(let cellViewModel):
            // The row's own list answers; the other one does not hold it.
            guard let anchorView = listViewController?.anchorView(forTag: .privateDeclaration, of: cellViewModel)
                ?? bookmarkViewController?.anchorView(forTag: .privateDeclaration, of: cellViewModel)
            else { return .none() }
            let viewController = PrivateDeclarationViewController()
            let viewModel = PrivateDeclarationViewModel(
                runtimeObject: cellViewModel.runtimeObject,
                imageRuntimeObjects: listViewModel?.nodes.map(\.runtimeObject) ?? [],
                documentState: documentState,
                router: self
            )
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: anchorView.bounds, ofView: anchorView, preferredEdge: .maxX, behavior: .transient))
        }
    }
}

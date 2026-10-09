import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias SidebarRootTransition = Transition<Void, SidebarRootTabViewController>

final class SidebarRootCoordinator: ViewCoordinator<SidebarRootRoute, SidebarRootTransition> {
    let documentState: DocumentState

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: SidebarRootRoute) -> SidebarRootTransition {
        switch route {
        case .initial:
            let directoryViewController = SidebarRootDirectoryViewController()
            let directoryViewModel = SidebarRootDirectoryViewModel(documentState: documentState, router: self)
            directoryViewController.setupBindings(for: directoryViewModel)

            let bookmarkViewController = SidebarRootBookmarkViewController()
            let bookmarkViewModel = SidebarRootBookmarkViewModel(documentState: documentState, router: self)
            bookmarkViewController.setupBindings(for: bookmarkViewModel)

            let findViewController = FindViewController<SidebarRootRoute>()
            let findViewModel = FindViewModel<SidebarRootRoute>(documentState: documentState, router: self)
            findViewController.setupBindings(for: findViewModel)

            let reportViewController = ReportViewController<SidebarRootRoute>()
            let reportViewModel = ReportViewModel<SidebarRootRoute>(documentState: documentState, router: self)
            reportViewController.setupBindings(for: reportViewModel)
            return .set([
                TabViewItem(normalSymbol: .init(systemName: .folder), selectedSymbol: .init(systemName: .folderFill), viewController: directoryViewController),
                TabViewItem(normalSymbol: .init(systemName: .bookmark), selectedSymbol: .init(systemName: .bookmarkFill), viewController: bookmarkViewController),
                TabViewItem(normalSymbol: .init(systemName: .magnifyingglass), selectedSymbol: .init(systemName: .magnifyingglass), viewController: findViewController),
                // Marked while work is in progress.
                TabViewItem(normalSymbol: .reportNavigator, selectedSymbol: .reportNavigator, viewController: reportViewController, activity: documentState.reportActivity),
            ])
        case .directory:
            return .select(index: 0)
        case .bookmarks:
            return .select(index: 1)
        case .find:
            // The focus request is sent when the transition performs, after
            // the tab is on screen; see `.revealSelectedRuntimeObject` in
            // `SidebarRuntimeObjectCoordinator` for why not during preparation.
            return .multiple(
                .select(index: 2),
                SidebarRootTransition(presentables: []) { [documentState] _, _, _, completion in
                    documentState.findSession.focusSearchFieldRelay.accept(())
                    completion?()
                }
            )
        case .findScopeChooser:
            let viewController = FindScopeChooserViewController<SidebarRootRoute>()
            let viewModel = FindScopeChooserViewModel<SidebarRootRoute>(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asSheet)
        case .dismissFindScopeChooser:
            return .dismiss()
        case .reports:
            return .select(index: 3)
        }
    }
}

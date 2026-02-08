#if canImport(UIKit)

import UIKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias ContentTransition = NavigationTransition

class ContentCoordinator: NavigationCoordinator<ContentRoute> {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(appState: appState, router: self)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            return .set([contentPlaceholderViewController], animation: nil)
        case .root(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appState: appState, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .set([contentTextViewController], animation: .default)
        case .next(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appState: appState, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .push(contentTextViewController, animation: .default)
        case .back:
            return .pop(animation: .default)
        }
    }
}

#endif

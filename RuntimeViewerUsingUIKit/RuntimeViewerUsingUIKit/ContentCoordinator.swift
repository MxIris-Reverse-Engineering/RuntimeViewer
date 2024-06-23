#if canImport(UIKit)

import UIKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias ContentTransition = NavigationTransition

class ContentCoordinator: NavigationCoordinator<ContentRoute> {
    let appServices: AppServices
    
    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(appServices: appServices, router: self)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            return .set([contentPlaceholderViewController], animation: nil)
        case let .root(runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appServices: appServices, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .set([contentTextViewController], animation: nil)
        case let .next(runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appServices: appServices, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .push(contentTextViewController, animation: .default)
        case .back:
            return .pop(animation: .default)
        }
    }
}

#endif

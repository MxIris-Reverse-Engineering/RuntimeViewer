import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias ContentTransition = Transition<Void, ContentNavigationController>

final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition> {
    protocol Delegate: AnyObject {
        func contentCoordinator(_ contentCoordinator: ContentCoordinator, completeTransition: ContentRoute)
    }

    let appServices: AppServices

    weak var delegate: Delegate?

    init(appServices: AppServices, delegate: Delegate) {
        self.delegate = delegate
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(appServices: appServices, router: self)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            contentPlaceholderViewController.loadViewIfNeeded()
            return .set([contentPlaceholderViewController], animated: false)
        case .root(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appServices: appServices, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            contentTextViewController.loadViewIfNeeded()
            return .set([contentTextViewController], animated: false)
        case .next(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appServices: appServices, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            contentTextViewController.loadViewIfNeeded()
            return .push(contentTextViewController, animated: true)
        case .back:
            return .pop(animated: true)
        }
    }

    override func completeTransition(for route: ContentRoute) {
        delegate?.contentCoordinator(self, completeTransition: route)
    }
}

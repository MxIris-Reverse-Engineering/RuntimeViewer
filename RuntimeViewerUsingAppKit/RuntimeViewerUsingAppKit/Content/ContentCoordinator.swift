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

    let documentState: DocumentState

    weak var delegate: Delegate?

    init(documentState: DocumentState, delegate: Delegate) {
        self.delegate = delegate
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(documentState: documentState, router: self)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            contentPlaceholderViewController.loadViewIfNeeded()
            return .set([contentPlaceholderViewController], animated: true)
        case .root(let runtimeObject):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            contentTextViewController.loadViewIfNeeded()
            return .set([contentTextViewController], animated: true)
        case .next(let runtimeObject):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
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

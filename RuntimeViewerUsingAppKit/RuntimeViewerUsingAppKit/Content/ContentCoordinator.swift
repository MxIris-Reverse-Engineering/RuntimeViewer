import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias ContentTransition = Transition<Void, ContentNavigationController>

final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition> {
    protocol Delegate: AnyObject {
        func contentCoordinatorDidShowPlaceholder(_ coordinator: ContentCoordinator)
        func contentCoordinator(
            _ coordinator: ContentCoordinator,
            didShowRoot runtimeObject: RuntimeObject
        )
        func contentCoordinator(
            _ coordinator: ContentCoordinator,
            didShowNext runtimeObject: RuntimeObject
        )
        func contentCoordinatorDidGoBack(_ coordinator: ContentCoordinator)
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    init(documentState: DocumentState) {
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
        super.completeTransition(for: route)
        switch route {
        case .placeholder:
            delegate?.contentCoordinatorDidShowPlaceholder(self)
        case .root(let runtimeObject):
            delegate?.contentCoordinator(self, didShowRoot: runtimeObject)
        case .next(let runtimeObject):
            delegate?.contentCoordinator(self, didShowNext: runtimeObject)
        case .back:
            delegate?.contentCoordinatorDidGoBack(self)
        }
    }
}

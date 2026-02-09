#if canImport(UIKit)

import UIKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias ContentTransition = NavigationTransition

class ContentCoordinator: NavigationCoordinator<ContentRoute> {
    let documentState: DocumentState

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(documentState: documentState, router: self)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            return .set([contentPlaceholderViewController], animation: nil)
        case .root(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, documentState: documentState, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .set([contentTextViewController], animation: .default)
        case .next(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, documentState: documentState, router: self)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .push(contentTextViewController, animation: .default)
        case .back:
            return .pop(animation: .default)
        }
    }
}

#endif

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias ContentTransition = Transition<Void, ContentNavigationController>

final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition> {
    let documentState: DocumentState

    private let disposeBag = DisposeBag()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)

        documentState.$selectionStack
            .asObservable()
            .scan((previous: nil as [RuntimeObject]?, current: documentState.selectionStack)) { state, next in
                (previous: state.current, current: next)
            }
            .subscribeOnNext { [weak self] state in
                guard let self else { return }
                applyStackChange(previous: state.previous, current: state.current)
            }
            .disposed(by: disposeBag)
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
            return .set([makeTextViewController(for: runtimeObject)], animated: true)
        case .next(let runtimeObject):
            return .push(makeTextViewController(for: runtimeObject), animated: true)
        case .back:
            return .pop(animated: true)
        }
    }

    private func makeTextViewController(for runtimeObject: RuntimeObject) -> ContentTextViewController {
        let viewController = ContentTextViewController()
        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
        viewController.setupBindings(for: viewModel)
        viewController.loadViewIfNeeded()
        return viewController
    }

    private func applyStackChange(previous: [RuntimeObject]?, current: [RuntimeObject]) {
        guard let previous else {
            installStack(current)
            return
        }
        if previous == current { return }

        if current.isEmpty {
            trigger(.placeholder)
            return
        }
        if previous.isEmpty {
            installStack(current)
            return
        }
        if current.count == previous.count + 1, Array(current.prefix(previous.count)) == previous {
            trigger(.next(current.last!))
            return
        }
        if previous.count == current.count + 1, Array(previous.prefix(current.count)) == current {
            trigger(.back)
            return
        }
        installStack(current)
    }

    private func installStack(_ stack: [RuntimeObject]) {
        if stack.isEmpty {
            trigger(.placeholder)
            return
        }
        trigger(.root(stack[0]))
        for runtimeObject in stack.dropFirst() {
            trigger(.next(runtimeObject))
        }
    }
}

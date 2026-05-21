import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorNavigationController>

final class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    /// Only request that genuinely escapes Inspector scope (opens a sheet owned by
    /// MainCoordinator). All other inter-pane synchronization flows through
    /// `documentState.selectionStack`.
    protocol Delegate: AnyObject {
        func inspectorCoordinator(
            _ coordinator: InspectorCoordinator,
            requestSpecializationSheetFor object: RuntimeObject
        )
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    private let disposeBag = DisposeBag()

    private var runtimeObjectCoordinators: [InspectorRuntimeObjectCoordinator?] = []

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

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            return .set([makePlaceholder()], animated: true)
        case .root(let inspectableObject):
            return .set([makePresentable(for: inspectableObject)], animated: true)
        case .next(let inspectableObject):
            return .push(makePresentable(for: inspectableObject), animated: true)
        case .back:
            return .pop(animated: true)
        }
    }

    private func applyStackChange(previous: [RuntimeObject]?, current: [RuntimeObject]) {
        guard let previous else {
            installStack(current)
            return
        }
        if previous == current { return }

        if current.isEmpty {
            resetRuntimeObjectStack()
            trigger(.placeholder)
            return
        }
        if previous.isEmpty {
            installStack(current)
            return
        }
        if current.count == previous.count + 1, Array(current.prefix(previous.count)) == previous {
            trigger(.next(.object(current.last!)))
            return
        }
        if previous.count == current.count + 1, Array(previous.prefix(current.count)) == current {
            if let popped = runtimeObjectCoordinators.popLast() {
                popped?.removeFromParent()
            }
            trigger(.back)
            return
        }
        installStack(current)
    }

    private func installStack(_ stack: [RuntimeObject]) {
        resetRuntimeObjectStack()
        if stack.isEmpty {
            trigger(.placeholder)
            return
        }
        trigger(.root(.object(stack[0])))
        for runtimeObject in stack.dropFirst() {
            trigger(.next(.object(runtimeObject)))
        }
    }

    private func makePresentable(for inspectableObject: InspectableObject) -> Presentable {
        switch inspectableObject {
        case .node:
            runtimeObjectCoordinators.append(nil)
            return makePlaceholder()
        case .object(let runtimeObject):
            guard InspectorRuntimeObjectCoordinator.canInspect(runtimeObject) else {
                runtimeObjectCoordinators.append(nil)
                return makePlaceholder()
            }
            let runtimeObjectCoordinator = InspectorRuntimeObjectCoordinator(
                documentState: documentState,
                runtimeObject: runtimeObject
            )
            runtimeObjectCoordinator.delegate = self
            runtimeObjectCoordinators.append(runtimeObjectCoordinator)
            return runtimeObjectCoordinator
        }
    }

    private func resetRuntimeObjectStack() {
        for runtimeObjectCoordinator in runtimeObjectCoordinators {
            runtimeObjectCoordinator?.removeFromParent()
        }
        runtimeObjectCoordinators.removeAll()
    }

    private func makePlaceholder() -> UXViewController {
        let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
        let viewController = InspectorPlaceholderViewController()
        viewController.setupBindings(for: viewModel)
        return viewController
    }
}

extension InspectorCoordinator: InspectorRuntimeObjectCoordinator.Delegate {
    func inspectorRuntimeObjectCoordinator(
        _ coordinator: InspectorRuntimeObjectCoordinator,
        didRequestSpecializationSheetFor object: RuntimeObject
    ) {
        delegate?.inspectorCoordinator(self, requestSpecializationSheetFor: object)
    }
}

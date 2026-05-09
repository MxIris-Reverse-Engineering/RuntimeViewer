import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorNavigationController>

final class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    protocol Delegate: AnyObject {
        func inspectorCoordinator(
            _ coordinator: InspectorCoordinator,
            requestSpecializationSheetFor object: RuntimeObject
        )
        func inspectorCoordinator(
            _ coordinator: InspectorCoordinator,
            selectRuntimeObject object: RuntimeObject
        )
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    private var runtimeObjectCoordinators: [InspectorRuntimeObjectCoordinator] = []

    private var childEventDisposeBag = DisposeBag()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            resetRuntimeObjectStack()
            return .set([makePlaceholder()], animated: true)
        case .root(let inspectableObject):
            resetRuntimeObjectStack()
            return .set([makePresentable(for: inspectableObject)], animated: true)
        case .next(let inspectableObject):
            return .push(makePresentable(for: inspectableObject), animated: true)
        case .back:
            runtimeObjectCoordinators.popLast()?.removeFromParent()
            return .pop(animated: true)
        case .requestSpecializationSheet(let object):
            delegate?.inspectorCoordinator(self, requestSpecializationSheetFor: object)
            return .none()
        case .selectRuntimeObject(let object):
            delegate?.inspectorCoordinator(self, selectRuntimeObject: object)
            return .none()
        }
    }

    private func makePresentable(for inspectableObject: InspectableObject) -> Presentable {
        switch inspectableObject {
        case .node:
            return makePlaceholder()
        case .object(let runtimeObject):
            guard InspectorRuntimeObjectCoordinator.canInspect(runtimeObject) else {
                return makePlaceholder()
            }
            let runtimeObjectCoordinator = InspectorRuntimeObjectCoordinator(
                documentState: documentState,
                runtimeObject: runtimeObject
            )
            bind(runtimeObjectCoordinator: runtimeObjectCoordinator)
            runtimeObjectCoordinators.append(runtimeObjectCoordinator)
            return runtimeObjectCoordinator
        }
    }

    private func bind(runtimeObjectCoordinator: InspectorRuntimeObjectCoordinator) {
        runtimeObjectCoordinator.rx.didCompleteTransition()
            .subscribeOnNext { [weak self] route in
                guard let self else { return }
                switch route {
                case .requestSpecializationSheet(let object):
                    trigger(.requestSpecializationSheet(object))
                case .selectRuntimeObject(let object):
                    trigger(.selectRuntimeObject(object))
                default:
                    break
                }
            }
            .disposed(by: childEventDisposeBag)
    }

    private func resetRuntimeObjectStack() {
        runtimeObjectCoordinators.forEach { $0.removeFromParent() }
        runtimeObjectCoordinators.removeAll()
        childEventDisposeBag = DisposeBag()
    }

    private func makePlaceholder() -> UXViewController {
        let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
        let viewController = InspectorPlaceholderViewController()
        viewController.setupBindings(for: viewModel)
        return viewController
    }
}

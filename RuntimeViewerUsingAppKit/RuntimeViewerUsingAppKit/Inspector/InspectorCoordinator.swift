import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorNavigationController>

final class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    /// Only request that genuinely escapes Inspector scope (opens a sheet
    /// owned by MainCoordinator). All other inter-pane navigation flows
    /// through `documentState.selectionRouter`.
    protocol Delegate: AnyObject {
        func inspectorCoordinator(
            _ coordinator: InspectorCoordinator,
            requestSpecializationSheetFor object: RuntimeObject
        )
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    /// Parallel array to the inspector navigation stack. `nil` entries
    /// correspond to placeholder pages (non-inspectable rows). Maintained
    /// directly by `prepareTransition` — there is no longer a separate
    /// selection-state subscription doing diff inference.
    private var runtimeObjectCoordinators: [InspectorRuntimeObjectCoordinator?] = []

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
            if let popped = runtimeObjectCoordinators.popLast() {
                popped?.removeFromParent()
            }
            return .pop(animated: true)
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

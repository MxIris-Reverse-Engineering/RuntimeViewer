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

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController], animated: true)
        case .root(let inspectableObject):
            return .set([makeTransition(for: inspectableObject)], animated: true)
        case .next(let inspectableObject):
            return .push(makeTransition(for: inspectableObject), animated: true)
        case .back:
            return .pop(animated: true)
        case .requestSpecializationSheet(let object):
            delegate?.inspectorCoordinator(self, requestSpecializationSheetFor: object)
            return .none()
        case .selectRuntimeObject(let object):
            delegate?.inspectorCoordinator(self, selectRuntimeObject: object)
            return .none()
        }
    }

    func makeTransition(for inspectableObject: InspectableObject) -> UXViewController {
        switch inspectableObject {
        case .node:
            return makePlaceholder()
        case .object(let runtimeObject):
            switch runtimeObject.kind {
            case .objc(.type(.class)):
                let viewModel = InspectorClassViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
                let viewController = InspectorClassViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
            case .swift(.type):
                let isClass: Bool
                if case .swift(.type(.class)) = runtimeObject.kind {
                    isClass = true
                } else {
                    isClass = false
                }
                let isGeneric = runtimeObject.properties.contains(.isGeneric)
                let isSpecialized = runtimeObject.properties.contains(.isSpecialized)
                // Show the Swift-type inspector when there is something
                // meaningful to display: any class type (Hierarchy panel) or a
                // not-yet-specialized generic value type (Specialization tab).
                if isClass || (isGeneric && !isSpecialized) {
                    let viewModel = InspectorSwiftTypeViewModel(
                        runtimeObject: runtimeObject,
                        documentState: documentState,
                        router: self
                    )
                    let viewController = InspectorSwiftTypeViewController()
                    viewController.setupBindings(for: viewModel)
                    return viewController
                }
                return makePlaceholder()
            default:
                return makePlaceholder()
            }
        }
    }

    private func makePlaceholder() -> UXViewController {
        let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
        let viewController = InspectorPlaceholderViewController()
        viewController.setupBindings(for: viewModel)
        return viewController
    }
}

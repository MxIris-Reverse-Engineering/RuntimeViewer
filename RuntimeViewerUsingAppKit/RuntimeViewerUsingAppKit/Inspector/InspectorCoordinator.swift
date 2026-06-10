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

    /// Which child VC the navigation is currently showing. We only `set` the
    /// navigation stack when this changes; switching the active
    /// `RuntimeObject` within the `.runtimeObject` scene reuses the existing
    /// `InspectorRuntimeObjectCoordinator` and just rebuilds its tab items.
    /// This avoids the UXKit push transition flash on every selection.
    private enum Scene {
        case initial
        case placeholder
        case runtimeObject
    }

    private var currentScene: Scene = .initial

    /// Last tab the user explicitly selected in any inspector page during
    /// this document's lifetime. Reused as the preferred tab on the next
    /// `update(for:preferredTabKind:)` so the inspector keeps the user's
    /// choice across RuntimeObject switches; falls back to the first
    /// available tab when the new object's `TabConfiguration` does not
    /// expose this kind.
    private var lastSelectedTabKind: InspectorRuntimeObjectCoordinator.TabKind?

    private lazy var placeholderViewController: InspectorPlaceholderViewController = {
        let viewController = InspectorPlaceholderViewController()
        let viewModel = InspectorPlaceholderViewModel(documentState: documentState, router: self)
        viewController.setupBindings(for: viewModel)
        viewController.loadViewIfNeeded()
        return viewController
    }()

    private lazy var runtimeObjectCoordinator: InspectorRuntimeObjectCoordinator = {
        let coordinator = InspectorRuntimeObjectCoordinator(documentState: documentState)
        coordinator.delegate = self
        addChild(coordinator)
        return coordinator
    }()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            return enterPlaceholderScene()
        case .root(let inspectableObject), .next(let inspectableObject):
            return enter(for: inspectableObject)
        case .back:
            if let selected = documentState.selectedRuntimeObject {
                return enter(for: .object(selected))
            } else {
                return enterPlaceholderScene()
            }
        }
    }

    private func enter(for inspectableObject: InspectableObject) -> InspectorTransition {
        switch inspectableObject {
        case .node:
            return enterPlaceholderScene()
        case .object(let runtimeObject):
            guard InspectorRuntimeObjectCoordinator.canInspect(runtimeObject) else {
                return enterPlaceholderScene()
            }
            return enterRuntimeObjectScene(for: runtimeObject)
        }
    }

    private func enterPlaceholderScene() -> InspectorTransition {
        guard currentScene != .placeholder else { return .none() }
        currentScene = .placeholder
        return .set([placeholderViewController], animated: false)
    }

    private func enterRuntimeObjectScene(for runtimeObject: RuntimeObject) -> InspectorTransition {
        runtimeObjectCoordinator.update(for: runtimeObject, preferredTabKind: lastSelectedTabKind)
        guard currentScene != .runtimeObject else { return .none() }
        currentScene = .runtimeObject
        return .set([runtimeObjectCoordinator], animated: false)
    }
}

extension InspectorCoordinator: InspectorRuntimeObjectCoordinator.Delegate {
    func inspectorRuntimeObjectCoordinator(
        _ coordinator: InspectorRuntimeObjectCoordinator,
        didRequestSpecializationSheetFor object: RuntimeObject
    ) {
        delegate?.inspectorCoordinator(self, requestSpecializationSheetFor: object)
    }

    func inspectorRuntimeObjectCoordinator(
        _ coordinator: InspectorRuntimeObjectCoordinator,
        didSelectTab tabKind: InspectorRuntimeObjectCoordinator.TabKind
    ) {
        lastSelectedTabKind = tabKind
    }
}

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SidebarTransition = Transition<Void, SidebarNavigationController>

final class SidebarCoordinator: ViewCoordinator<SidebarRoute, SidebarTransition> {
    let documentState: DocumentState

    private var rootCoordinator: SidebarRootCoordinator?

    private var runtimeObjectCoordinator: SidebarRuntimeObjectCoordinator?

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    /// Drives the visual selection in the underlying runtime object list.
    /// Idempotent if the sidebar is at the root level (no list mounted).
    /// Called by `MainCoordinator` while fanning out a `.selectAtRoot`
    /// intent so root selection changes originating outside the sidebar
    /// (specialization completion, future deep-link, etc.) still
    /// scroll-and-highlight the matching row.
    func programmaticallySelect(_ object: RuntimeObject) {
        runtimeObjectCoordinator?.programmaticallySelect(object)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            rootCoordinator?.removeFromParent()
            let rootCoordinator = SidebarRootCoordinator(documentState: documentState)
            self.rootCoordinator = rootCoordinator
            return .set([rootCoordinator], animated: false)
        case .clickedNode(let imageNode):
            runtimeObjectCoordinator?.removeFromParent()
            let runtimeObjectCoordinator = SidebarRuntimeObjectCoordinator(
                documentState: documentState,
                imageNode: imageNode
            )
            self.runtimeObjectCoordinator = runtimeObjectCoordinator
            return .push(runtimeObjectCoordinator, animated: true)
        case .back:
            runtimeObjectCoordinator?.removeFromParent()
            runtimeObjectCoordinator = nil
            return .pop(animated: true)
        case .selectedObject, .selectedNode:
            // macOS uses `SelectionRoute.selectAtRoot` / `.switchImage`
            // directly; the cross-platform `SidebarRoute` carries these
            // cases for iOS only.
            return .none()
        }
    }
}

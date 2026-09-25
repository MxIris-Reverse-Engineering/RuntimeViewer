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
        case .revealSelectedRuntimeObject:
            // Only the page of the image on screen can hold the object's row;
            // the command is disabled whenever the object belongs to another
            // image, which also means a page is always open here.
            guard let runtimeObjectCoordinator else { return .none() }
            return .route(on: runtimeObjectCoordinator, to: .revealSelectedRuntimeObject)
        case .selectedObject, .selectedNode:
            // iOS-only cases; on macOS the runtime-object list scrolls to
            // and highlights the root selection by observing
            // `documentState.$selectedRuntimeObject` directly, and image
            // switches flow through `SelectionRoute.switchImage`.
            return .none()
        }
    }
}

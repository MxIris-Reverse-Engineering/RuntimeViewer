import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SidebarTransition = Transition<Void, SidebarNavigationController>

final class SidebarCoordinator: ViewCoordinator<SidebarRoute, SidebarTransition> {
    protocol Delegate: AnyObject {
        func sidebarCoordinator(
            _ coordinator: SidebarCoordinator,
            didSelectObject object: RuntimeObject
        )
        func sidebarCoordinator(
            _ coordinator: SidebarCoordinator,
            didClickImageNode imageNode: RuntimeImageNode
        )
        func sidebarCoordinatorDidGoBack(_ coordinator: SidebarCoordinator)
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    private var rootCoordinator: SidebarRootCoordinator?

    private var runtimeObjectCoordinator: SidebarRuntimeObjectCoordinator?

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    func programmaticallySelectObject(_ object: RuntimeObject) {
        runtimeObjectCoordinator?.programmaticallySelectObject(object)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            rootCoordinator?.removeFromParent()
            let rootCoordinator = SidebarRootCoordinator(documentState: documentState)
            rootCoordinator.delegate = self
            self.rootCoordinator = rootCoordinator
            return .set([rootCoordinator], animated: false)
        case .clickedNode(let imageNode):
            runtimeObjectCoordinator?.removeFromParent()
            let runtimeObjectCoordinator = SidebarRuntimeObjectCoordinator(documentState: documentState, imageNode: imageNode)
            runtimeObjectCoordinator.delegate = self
            self.runtimeObjectCoordinator = runtimeObjectCoordinator
            return .push(runtimeObjectCoordinator, animated: true)
        case .back:
            return .pop(animated: true)
        case .selectedObject:
            // Programmatic selection enters via `programmaticallySelectObject(_)` which
            // routes through the sub-coordinator directly. Forwarding here would create
            // a feedback loop (sub-coord delegate → SidebarCoord.trigger(.selectedObject)
            // → forward to sub-coord → delegate again …). The trigger is preserved only
            // to keep `MainViewModel.completeTransition` (Sidebar didCompleteTransition)
            // emitting `.selectedObject`.
            return .none()
        case .selectedNode:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRoute) {
        super.completeTransition(for: route)
        switch route {
        case .back:
            delegate?.sidebarCoordinatorDidGoBack(self)
        case .root, .clickedNode, .selectedObject, .selectedNode:
            break
        }
    }
}

extension SidebarCoordinator: SidebarRootCoordinator.Delegate {
    func rootCoordinator(
        _ coordinator: SidebarRootCoordinator,
        didClickImageNode imageNode: RuntimeImageNode
    ) {
        delegate?.sidebarCoordinator(self, didClickImageNode: imageNode)
        trigger(.clickedNode(imageNode))
    }
}

extension SidebarCoordinator: SidebarRuntimeObjectCoordinator.Delegate {
    func runtimeObjectCoordinator(
        _ coordinator: SidebarRuntimeObjectCoordinator,
        didSelectObject object: RuntimeObject
    ) {
        delegate?.sidebarCoordinator(self, didSelectObject: object)
        trigger(.selectedObject(object))
    }
}

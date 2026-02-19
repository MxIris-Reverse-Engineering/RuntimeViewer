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

    private var childEventDisposeBag = DisposeBag()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            rootCoordinator?.removeFromParent()
            childEventDisposeBag = DisposeBag()
            let rootCoordinator = SidebarRootCoordinator(documentState: documentState)
            rootCoordinator.rx.didCompleteTransition()
                .subscribeOnNext { [weak self] route in
                    guard let self else { return }
                    switch route {
                    case .image(let imageNode):
                        trigger(.clickedNode(imageNode))
                    default:
                        break
                    }
                }
                .disposed(by: childEventDisposeBag)
            self.rootCoordinator = rootCoordinator
            return .set([rootCoordinator], animated: false)
        case .clickedNode(let imageNode):
            runtimeObjectCoordinator?.removeFromParent()
            let runtimeObjectCoordinator = SidebarRuntimeObjectCoordinator(documentState: documentState, imageNode: imageNode)
            runtimeObjectCoordinator.rx.didCompleteTransition()
                .subscribeOnNext { [weak self] route in
                    guard let self else { return }
                    switch route {
                    case .selectedObject(let runtimeObjectName):
                        trigger(.selectedObject(runtimeObjectName))
                    case .exportInterface:
                        trigger(.exportInterface)
                    default:
                        break
                    }
                }
                .disposed(by: childEventDisposeBag)
            self.runtimeObjectCoordinator = runtimeObjectCoordinator
            return .push(runtimeObjectCoordinator, animated: true)
        case .back:
            return .pop(animated: true)
        default:
            return .none()
        }
    }
}

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SidebarTransition = Transition<Void, SidebarNavigationController>

final class SidebarCoordinator: ViewCoordinator<SidebarRoute, SidebarTransition> {
    let documentState: DocumentState

    private let disposeBag = DisposeBag()

    private var rootCoordinator: SidebarRootCoordinator?

    private var runtimeObjectCoordinator: SidebarRuntimeObjectCoordinator?

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)

        documentState.$currentImageNode
            .asObservable()
            .scan((previous: nil as RuntimeImageNode??, current: documentState.currentImageNode)) { state, next in
                (previous: state.current, current: next)
            }
            .subscribeOnNext { [weak self] state in
                guard let self else { return }
                applyImageNodeChange(previousLayer: state.previous, current: state.current)
            }
            .disposed(by: disposeBag)

        documentState.$selectionStack
            .asObservable()
            .map { $0.first }
            .distinctUntilChanged()
            .subscribeOnNext { [weak self] rootSelection in
                guard let self, let rootSelection else { return }
                runtimeObjectCoordinator?.programmaticallySelectObject(rootSelection)
            }
            .disposed(by: disposeBag)
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
            let runtimeObjectCoordinator = SidebarRuntimeObjectCoordinator(documentState: documentState, imageNode: imageNode)
            self.runtimeObjectCoordinator = runtimeObjectCoordinator
            return .push(runtimeObjectCoordinator, animated: true)
        case .back:
            return .pop(animated: true)
        case .selectedObject, .selectedNode:
            // macOS uses `documentState.selectionStack` and `currentImageNode`
            // directly; the cross-platform `SidebarRoute` carries these cases
            // for iOS only.
            return .none()
        }
    }

    private func applyImageNodeChange(previousLayer: RuntimeImageNode??, current: RuntimeImageNode?) {
        guard let previous = previousLayer else {
            if let current {
                trigger(.clickedNode(current))
            }
            return
        }
        if previous == current { return }
        if previous == nil, let current {
            trigger(.clickedNode(current))
        } else if previous != nil, current == nil {
            trigger(.back)
        } else if let next = current {
            trigger(.back)
            trigger(.clickedNode(next))
        }
    }
}

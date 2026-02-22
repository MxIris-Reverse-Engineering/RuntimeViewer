#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

public enum MainRoute: Routable {
    case initial
    case select(RuntimeObject)
    case inspect(InspectableObject)
}

typealias MainTransition = Transition<MainSplitViewController>

class MainCoordinator: BaseCoordinator<MainRoute, MainTransition> {
    let documentState: DocumentState

    let completeTransition: PublishRelay<SidebarRoute> = .init()

    lazy var sidebarCoordinator = SidebarCoordinator(documentState: documentState, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(documentState: documentState)

    lazy var compactSidebarCoordinator = SidebarCoordinator(documentState: documentState, delegate: self)

    lazy var inspectorCoordinator = InspectorCoordinator(documentState: documentState)

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(style: .doubleColumn), initialRoute: nil)
        rootViewController.delegate = self
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .initial:
            let viewModel = MainViewModel(documentState: documentState, router: self)
            rootViewController.setupBindings(for: viewModel)
            return .multiple(.set(sidebarCoordinator, for: .primary), .set(contentCoordinator, for: .secondary))
        case .select(let runtimeObject):
            return .multiple(.route(.root(runtimeObject), on: contentCoordinator), .show(column: .secondary))
        case .inspect(let inspectableType):
            return .route(.root(inspectableType), on: inspectorCoordinator)
        }
    }

    override func completeTransition(for route: MainRoute) {}
}

extension MainCoordinator: UISplitViewControllerDelegate {
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        return .primary
    }

    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {}
}

extension MainCoordinator: SidebarCoordinatorDelegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case .selectedNode(let runtimeNamedNode):
            inspectorCoordinator.trigger(.root(.node(runtimeNamedNode)))
        case .clickedNode /* (let runtimeNamedNode) */:
            break
        case .selectedObject(let runtimeObjectType):
            trigger(.select(runtimeObjectType), with: .init(animated: false))
        case .back:
            contentCoordinator.trigger(.placeholder)
        default:
            break
        }
        completeTransition.accept(route)
    }
}

@MainActor
extension Transition where RootViewController: UISplitViewController {
    @available(iOS 14, tvOS 14, *)
    public static func show(column: UISplitViewController.Column) -> Transition {
        Transition {
            SplitShowColumn(column)
        }
    }
}

@MainActor
@available(iOS 14, tvOS 14, *)
public struct SplitShowColumn<RootViewController> {
    // MARK: Stored Properties

    private let column: UISplitViewController.Column

    // MARK: Initialization

    public init(_ column: UISplitViewController.Column) {
        self.column = column
    }
}

@available(iOS 14, tvOS 14, *)
extension SplitShowColumn: TransitionComponent where RootViewController: UISplitViewController {
    public func build() -> Transition<RootViewController> {
        return Transition(presentables: [], animationInUse: nil) { rootViewController, _, completion in
            rootViewController.show(column)
            completion?()
        }
    }
}

#endif

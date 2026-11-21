#if canImport(UIKit)

import UIKit
import Dependencies
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerSettingsUI

public enum MainRoute: Routable {
    case initial
    case select(RuntimeObject)
    case inspect(InspectableObject)
    /// Opens the settings, over the whole split view.
    case settings
}

typealias MainTransition = Transition<MainSplitViewController>

/// Whoever holds a window opened for a file, and closes it.
protocol MainCoordinatorDelegate: AnyObject {
    /// The window's close button was pressed.
    func mainCoordinatorDidRequestClose(_ mainCoordinator: MainCoordinator)
}

class MainCoordinator: BaseCoordinator<MainRoute, MainTransition> {
    let documentState: DocumentState

    /// Whether the window was opened for a file: its sidebar has a close
    /// button.
    let isFileWindow: Bool

    weak var delegate: MainCoordinatorDelegate?

    let completeTransition: PublishRelay<SidebarRoute> = .init()

    @Dependency(\.fileController) private var fileController

    lazy var sidebarCoordinator = SidebarCoordinator(documentState: documentState, showsCloseButton: isFileWindow, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(documentState: documentState)

    lazy var compactSidebarCoordinator = SidebarCoordinator(documentState: documentState, showsCloseButton: isFileWindow, delegate: self)

    lazy var inspectorCoordinator = InspectorCoordinator(documentState: documentState)

    init(documentState: DocumentState, isFileWindow: Bool = false) {
        self.documentState = documentState
        self.isFileWindow = isFileWindow
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
        case .settings:
            // A form sheet: a centred card on iPad, a sheet from the bottom on iPhone.
            let settingsViewController = SettingsViewController()
            settingsViewController.modalPresentationStyle = .formSheet
            return .present(settingsViewController)
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

    func sidebarCoordinatorDidRequestSettings(_ sidebarCoordinator: SidebarCoordinator) {
        trigger(.settings)
    }

    func sidebarCoordinatorDidRequestFileChoice(_ sidebarCoordinator: SidebarCoordinator) {
        fileController.chooseFile(presentingFrom: rootViewController)
    }

    func sidebarCoordinatorDidRequestPathEntry(_ sidebarCoordinator: SidebarCoordinator) {
        fileController.enterPath(presentingFrom: rootViewController)
    }

    func sidebarCoordinatorDidRequestClose(_ sidebarCoordinator: SidebarCoordinator) {
        delegate?.mainCoordinatorDidRequestClose(self)
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

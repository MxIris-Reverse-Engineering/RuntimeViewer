#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

protocol SidebarCoordinatorDelegate: AnyObject {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition: SidebarRoute)
    /// The settings button on the sidebar's root page was pressed.
    func sidebarCoordinatorDidRequestSettings(_ sidebarCoordinator: SidebarCoordinator)
}

typealias SidebarTransition = NavigationTransition

class SidebarCoordinator: NavigationCoordinator<SidebarRoute> {
    let documentState: DocumentState

    weak var coordinatorDelegate: SidebarCoordinatorDelegate?

    init(documentState: DocumentState, delegate: SidebarCoordinatorDelegate? = nil) {
        self.documentState = documentState
        self.coordinatorDelegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .root)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            let viewController = SidebarRootViewController()
            let viewModel = SidebarRootDirectoryViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            viewController.navigationItem.rightBarButtonItem = makeSettingsButton()
            return .set([viewController], animation: nil)
        case let .clickedNode(clickedNode):
            let viewController = SidebarRuntimeObjectViewController()
            let viewModel = SidebarRuntimeObjectListViewModel(imageNode: clickedNode, documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .push(viewController, animation: .default)
        case .back:
            return .pop(animation: .default)
        default:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRoute) {
        coordinatorDelegate?.sidebarCoordinator(self, completeTransition: route)
    }

    /// The gear at the top of the sidebar's root page, where iOS apps keep
    /// their settings; opening them is the main coordinator's business.
    private func makeSettingsButton() -> UIBarButtonItem {
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                coordinatorDelegate?.sidebarCoordinatorDidRequestSettings(self)
            }
        )
        settingsButton.accessibilityLabel = "Settings"
        return settingsButton
    }
}

#endif

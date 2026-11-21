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
    /// The open button's document picker was asked for.
    func sidebarCoordinatorDidRequestFileChoice(_ sidebarCoordinator: SidebarCoordinator)
    /// Open Path… was chosen (the jailbroken app only).
    func sidebarCoordinatorDidRequestPathEntry(_ sidebarCoordinator: SidebarCoordinator)
    /// A file window's close button was pressed.
    func sidebarCoordinatorDidRequestClose(_ sidebarCoordinator: SidebarCoordinator)
}

typealias SidebarTransition = NavigationTransition

class SidebarCoordinator: NavigationCoordinator<SidebarRoute> {
    let documentState: DocumentState

    weak var coordinatorDelegate: SidebarCoordinatorDelegate?

    /// Whether the root page carries a close button: in a window opened for
    /// a file.
    private let showsCloseButton: Bool

    init(documentState: DocumentState, showsCloseButton: Bool = false, delegate: SidebarCoordinatorDelegate? = nil) {
        self.documentState = documentState
        self.showsCloseButton = showsCloseButton
        self.coordinatorDelegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .root)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            let viewController = SidebarRootViewController()
            let viewModel = SidebarRootDirectoryViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            // The gear outermost, the open button beside it.
            viewController.navigationItem.rightBarButtonItems = [makeSettingsButton(), makeOpenButton()]
            if showsCloseButton {
                viewController.navigationItem.leftBarButtonItem = makeCloseButton()
            }
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

    /// Opens a file from disk: the document picker, or on the jailbroken app,
    /// which reads any path, a menu that also offers Open Path….
    private func makeOpenButton() -> UIBarButtonItem {
        let image = UIImage(systemName: "folder")
        let chooseFileAction = UIAction(title: "Choose File…", image: UIImage(systemName: "doc")) { [weak self] _ in
            guard let self else { return }
            coordinatorDelegate?.sidebarCoordinatorDidRequestFileChoice(self)
        }
        let openButton: UIBarButtonItem
        if FileController.opensAbsolutePaths {
            let enterPathAction = UIAction(title: "Open Path…", image: UIImage(systemName: "text.cursor")) { [weak self] _ in
                guard let self else { return }
                coordinatorDelegate?.sidebarCoordinatorDidRequestPathEntry(self)
            }
            openButton = UIBarButtonItem(image: image, menu: UIMenu(children: [chooseFileAction, enterPathAction]))
        } else {
            openButton = UIBarButtonItem(image: image, primaryAction: chooseFileAction)
        }
        openButton.accessibilityLabel = "Open"
        return openButton
    }

    /// Closes the window opened for a file; on an iPhone, back to the window
    /// under it.
    private func makeCloseButton() -> UIBarButtonItem {
        let closeButton = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                coordinatorDelegate?.sidebarCoordinatorDidRequestClose(self)
            }
        )
        closeButton.accessibilityLabel = "Close"
        return closeButton
    }
}

#endif

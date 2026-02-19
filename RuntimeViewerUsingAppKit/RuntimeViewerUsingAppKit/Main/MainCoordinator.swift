import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import LateResponders

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>, LateResponderRegistering {
    let documentState: DocumentState

    private lazy var sidebarCoordinator = SidebarCoordinator(documentState: documentState)

    private lazy var contentCoordinator = ContentCoordinator(documentState: documentState)

    private lazy var inspectorCoordinator = InspectorCoordinator(documentState: documentState)

    private lazy var viewModel = MainViewModel(documentState: documentState, router: self)

    private(set) lazy var lateResponderRegistry = LateResponderRegistry()

    private var childEventDisposeBag = DisposeBag()
    
    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(windowController: .init(documentState: documentState), initialRoute: .main(.local))
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .main(let runtimeEngine):
            documentState.runtimeEngine = runtimeEngine
            documentState.currentImageName = nil
            sidebarCoordinator.removeFromParent()
            contentCoordinator.removeFromParent()
            inspectorCoordinator.removeFromParent()
            sidebarCoordinator = SidebarCoordinator(documentState: documentState)
            contentCoordinator = ContentCoordinator(documentState: documentState)
            inspectorCoordinator = InspectorCoordinator(documentState: documentState)
            bindChildEvents()
            viewModel.completeTransition = sidebarCoordinator.rx.didCompleteTransition()
            windowController.setupBindings(for: viewModel)
            return .multiple(
                .show(windowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root),
                .route(on: contentCoordinator, to: .placeholder),
                .route(on: inspectorCoordinator, to: .placeholder)
            )
        case .select(let runtimeObject):
            return .route(on: contentCoordinator, to: .root(runtimeObject))
        case .sidebarBack:
            return .route(on: sidebarCoordinator, to: .back)
        case .contentBack:
            return .route(on: contentCoordinator, to: .back)
        case .generationOptions(let sender):
            let viewController = GenerationOptionsViewController()
            let viewModel = GenerationOptionsViewModel(documentState: documentState, router: self)
            viewController.loadViewIfNeeded()
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .loadFramework:
            return .none()
        case .attachToProcess:
            let viewController = AttachToProcessViewController()
            let viewModel = AttachToProcessViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            viewController.preferredContentSize = .init(width: 800, height: 600)
            return .presentOnRoot(viewController, mode: .asSheet)
        case .dismiss:
            return .dismiss()
        case .exportInterfaces:
            guard let exportingCoordinator = ExportingCoordinator(documentState: documentState) else { return .none() }
            addChild(exportingCoordinator)
            return .beginSheet(exportingCoordinator)
        }
    }

    override func completeTransition(for route: MainRoute) {
        switch route {
        case .main:
            windowController.splitViewController.setupSplitViewItems()
        default:
            break
        }
    }

    override var nextResponder: NSResponder? {
        set {
            lateResponderRegistry.lastResponder.nextResponder = newValue
        }
        get {
            lateResponderRegistry.initialResponder
        }
    }

    private func bindChildEvents() {
        childEventDisposeBag = DisposeBag()
        
        sidebarCoordinator.rx.didCompleteTransition()
            .subscribeOnNext { [weak self] route in
                guard let self else { return }
                switch route {
                case .clickedNode(let imageNode):
                    documentState.currentImageName = imageNode.name
                    documentState.currentImagePath = imageNode.path
                case .selectedObject(let runtimeObject):
                    documentState.selectedRuntimeObject = runtimeObject
                    contentCoordinator.trigger(.root(runtimeObject))
                case .back:
                    documentState.currentImageName = nil
                    documentState.currentImagePath = nil
                    documentState.selectedRuntimeObject = nil
                    contentCoordinator.trigger(.placeholder)
                case .exportInterface:
                    trigger(.exportInterfaces)
                default:
                    break
                }
            }
            .disposed(by: childEventDisposeBag)
        
        contentCoordinator.rx.didCompleteTransition()
            .subscribeOnNext { [weak self] route in
                guard let self else { return }
                let hasBackStack = contentCoordinator.rootViewController.viewControllers.count >= 2
                viewModel.isContentStackDepthGreaterThanOne.accept(hasBackStack)
                switch route {
                case .placeholder:
                    documentState.selectedRuntimeObject = nil
                    inspectorCoordinator.trigger(.placeholder)
                case .root(let runtimeObject):
                    documentState.selectedRuntimeObject = runtimeObject
                    inspectorCoordinator.trigger(.root(.object(runtimeObject)))
                case .next(let runtimeObject):
                    documentState.selectedRuntimeObject = runtimeObject
                    inspectorCoordinator.trigger(.next(.object(runtimeObject)))
                case .back:
                    inspectorCoordinator.trigger(.back)
                }
            }
            .disposed(by: childEventDisposeBag)
    }
}

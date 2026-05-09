import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SpecializationTransition = Transition<SpecializationSheetWindowController, NSViewController>

@Loggable(.private)
final class SpecializationCoordinator: SceneCoordinator<SpecializationRoute, SpecializationTransition> {
    protocol Delegate: AnyObject {
        func specializationCoordinator(
            _ coordinator: SpecializationCoordinator,
            didProduce specialized: RuntimeObject
        )
    }

    weak var delegate: Delegate?

    let documentState: DocumentState

    let runtimeObject: RuntimeObject

    private weak var sheetViewModel: SpecializationSheetViewModel?

    private weak var sheetViewController: SpecializationSheetViewController?

    private let popoverDisposeBag = DisposeBag()

    init(documentState: DocumentState, runtimeObject: RuntimeObject) {
        self.documentState = documentState
        self.runtimeObject = runtimeObject
        super.init(windowController: SpecializationSheetWindowController(), initialRoute: nil)

        let viewModel = SpecializationSheetViewModel(
            runtimeObject: runtimeObject,
            documentState: documentState,
            router: self
        )
        let viewController = SpecializationSheetViewController()
        viewController.setupBindings(for: viewModel)
        windowController.contentViewController = viewController
        self.sheetViewModel = viewModel
        self.sheetViewController = viewController
    }

    override func prepareTransition(for route: SpecializationRoute) -> SpecializationTransition {
        switch route {
        case .cancel:
            removeFromParent()
            return .endSheetOnTop()
        case .specializeCompleted(let specialized):
            delegate?.specializationCoordinator(self, didProduce: specialized)
            removeFromParent()
            return .endSheetOnTop()
        case .requestTypePicker(let parameterName):
            showTypePicker(for: parameterName)
            return .none()
        }
    }

    private func showTypePicker(for parameterName: String) {
        guard let sheetViewController,
              let sheetViewModel,
              let request = sheetViewModel.request,
              let parameter = request.parameters.first(where: { $0.name == parameterName }),
              let anchor = sheetViewController.anchorView(forParameter: parameterName)
        else {
            #log(.error, "Cannot resolve type picker anchor for parameter \(parameterName, privacy: .public)")
            return
        }

        let popoverViewModel = TypePickerPopoverViewModel(candidates: parameter.candidates)
        let popoverViewController = TypePickerPopoverViewController()
        popoverViewController.setupBindings(for: popoverViewModel)

        let popover = NSPopover()
        popover.contentViewController = popoverViewController
        popover.behavior = .transient

        popoverViewModel.didSelectRelay
            .asSignal()
            .emitOnNextMainActor { [weak sheetViewModel, weak popover] (candidate: RuntimeSpecializationRequest.Candidate) in
                sheetViewModel?.parameterArgumentChangedRelay.accept(
                    (parameterName: parameterName, candidate: candidate)
                )
                popover?.performClose(nil)
            }
            .disposed(by: popoverDisposeBag)

        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

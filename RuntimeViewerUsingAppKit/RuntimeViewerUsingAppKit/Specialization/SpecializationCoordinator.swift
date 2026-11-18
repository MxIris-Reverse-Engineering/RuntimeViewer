import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SpecializationTransition = Transition<SpecializationWindowController, SpecializationViewController>

@Loggable(.private)
final class SpecializationCoordinator: SceneCoordinator<SpecializationRoute, SpecializationTransition> {

    // MARK: - Delegate

    protocol Delegate: AnyObject {
        func specializationCoordinator(
            _ coordinator: SpecializationCoordinator,
            didProduce specialized: RuntimeObject
        )
    }

    // MARK: - Properties

    weak var delegate: Delegate?

    private let documentState: DocumentState

    private let runtimeObject: RuntimeObject

    private weak var specializationViewModel: SpecializationViewModel?

    private weak var specializationViewController: SpecializationViewController?

    // MARK: - Lifecycle

    init(documentState: DocumentState, runtimeObject: RuntimeObject) {
        self.documentState = documentState
        self.runtimeObject = runtimeObject
        super.init(windowController: SpecializationWindowController(), initialRoute: nil)
        installRootContent()
    }

    // MARK: - Transitions

    override func prepareTransition(for route: SpecializationRoute) -> SpecializationTransition {
        switch route {
        case .cancel:
            return finishSheet()
        case .dismiss:
            return .dismiss()
        case .specializeCompleted(let specialized):
            delegate?.specializationCoordinator(self, didProduce: specialized)
            return finishSheet()
        case .showTypePicker(let parameterPath, let rows):
            return showTypePicker(for: parameterPath, rows: rows)
        case .didSelectCandidate(let parameterPath, let candidate):
            specializationViewModel?.applyArgumentChange(path: parameterPath, candidate: candidate)
            return .closePopover()
        }
    }

    // MARK: - Helpers

    private func installRootContent() {
        let viewModel = SpecializationViewModel(
            runtimeObject: runtimeObject,
            documentState: documentState,
            router: self
        )
        let viewController = SpecializationViewController()
        viewController.setupBindings(for: viewModel)
        windowController.contentViewController = viewController
        self.specializationViewModel = viewModel
        self.specializationViewController = viewController
    }

    private func finishSheet() -> SpecializationTransition {
        removeFromParent()
        return .endSheetOnTop()
    }

    private func showTypePicker(
        for parameterPath: [ParameterPathSegment],
        rows: [CandidateBox]
    ) -> SpecializationTransition {
        guard let anchor = specializationViewController?.anchorView(forPath: parameterPath) else {
            #log(.error, "Cannot resolve type picker anchor for path \(String(describing: parameterPath), privacy: .public)")
            return .none()
        }
        let pickerViewController = makeTypePicker(parameterPath: parameterPath, rows: rows)
        return .popover(
            pickerViewController,
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .minY,
            behavior: .transient
        )
    }

    private func makeTypePicker(
        parameterPath: [ParameterPathSegment],
        rows: [CandidateBox]
    ) -> SpecializationTypePickerViewController {
        let viewModel = SpecializationTypePickerViewModel(
            parameterPath: parameterPath,
            rows: rows,
            documentState: documentState,
            router: self
        )
        let viewController = SpecializationTypePickerViewController()
        viewController.setupBindings(for: viewModel)
        return viewController
    }
}

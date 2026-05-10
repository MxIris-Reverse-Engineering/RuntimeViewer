import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// Routes emitted by the specialization sheet. The route stays
/// platform-neutral: anchor information for the type-picker popover is
/// expressed as a `parameterName` string rather than an `NSView`, and the
/// view layer is responsible for resolving the matching row anchor.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SpecializationRoute: Routable {
    case cancel
    case dismiss
    case requestTypePicker(parameterName: String)
    case didSelectCandidate(parameterName: String, candidate: RuntimeSpecializationRequest.Candidate)
    case specializeCompleted(RuntimeObject)
}


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
        case .requestTypePicker(let parameterName):
            return showTypePicker(for: parameterName)
        case .didSelectCandidate(let parameterName, let candidate):
            specializationViewModel?.applyArgumentChange(parameterName: parameterName, candidate: candidate)
            return .dismiss()
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

    private func showTypePicker(for parameterName: String) -> SpecializationTransition {
        guard let parameter = parameter(named: parameterName),
              let anchor = specializationViewController?.anchorView(forParameter: parameterName)
        else {
            #log(.error, "Cannot resolve type picker anchor for parameter \(parameterName, privacy: .public)")
            return .none()
        }
        let pickerViewController = makeTypePicker(for: parameter)
        return .present(
            pickerViewController,
            mode: .asPopover(
                relativeToRect: anchor.bounds,
                ofView: anchor,
                preferredEdge: .minY,
                behavior: .transient
            )
        )
    }

    private func parameter(named parameterName: String) -> RuntimeSpecializationRequest.Parameter? {
        specializationViewModel?.request?.parameters.first { $0.name == parameterName }
    }

    private func makeTypePicker(for parameter: RuntimeSpecializationRequest.Parameter) -> SpecializationTypePickerViewController {
        let viewModel = SpecializationTypePickerViewModel(
            parameterName: parameter.name,
            candidates: parameter.candidates,
            documentState: documentState,
            router: self
        )
        let viewController = SpecializationTypePickerViewController()
        viewController.setupBindings(for: viewModel)
        return viewController
    }
}

import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// Routes emitted by the specialization sheet. The route stays
/// platform-neutral: anchor information for the type-picker popover is
/// expressed as a `parameterPath: [ParameterPathSegment]` (the dotted
/// parameter chain from the outermost row, e.g.
/// `[.parameter("A")]` / `[.parameter("A"), .parameter("B")]`) rather than
/// an `NSView`, and the view layer is responsible for resolving the
/// matching row anchor.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SpecializationRoute: Routable {
    case cancel
    case dismiss
    /// Triggered by `SpecializationViewModel` after the type-picker payload
    /// (sorted + boxed candidates) has been prepared on a background queue,
    /// so the popover-open path on the main thread is constant-time.
    case showTypePicker(parameterPath: [ParameterPathSegment], rows: [CandidateBox])
    case didSelectCandidate(parameterPath: [ParameterPathSegment], candidate: RuntimeSpecializationRequest.Candidate)
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
        case .showTypePicker(let parameterPath, let rows):
            return showTypePicker(for: parameterPath, rows: rows)
        case .didSelectCandidate(let parameterPath, let candidate):
            specializationViewModel?.applyArgumentChange(path: parameterPath, candidate: candidate)
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

    private func showTypePicker(
        for parameterPath: [ParameterPathSegment],
        rows: [CandidateBox]
    ) -> SpecializationTransition {
        guard let anchor = specializationViewController?.anchorView(forPath: parameterPath) else {
            #log(.error, "Cannot resolve type picker anchor for path \(String(describing: parameterPath), privacy: .public)")
            return .none()
        }
        let pickerViewController = makeTypePicker(parameterPath: parameterPath, rows: rows)
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

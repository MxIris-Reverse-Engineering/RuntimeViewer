import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// Routes emitted by the specialization sheet. The route stays
/// platform-neutral: anchor information for the type-picker popover is
/// expressed as a `parameterPath: [String]` (the dotted parameter chain
/// from the outermost row, e.g. `["A"]` / `["A", "B"]`) rather than an
/// `NSView`, and the view layer is responsible for resolving the matching
/// row anchor.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SpecializationRoute: Routable {
    case cancel
    case dismiss
    case requestTypePicker(parameterPath: [String])
    case didSelectCandidate(parameterPath: [String], candidate: RuntimeSpecializationRequest.Candidate)
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
        case .requestTypePicker(let parameterPath):
            return showTypePicker(for: parameterPath)
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

    private func showTypePicker(for parameterPath: [String]) -> SpecializationTransition {
        guard let parameter = parameter(forPath: parameterPath),
              let anchor = specializationViewController?.anchorView(forPath: parameterPath)
        else {
            #log(.error, "Cannot resolve type picker anchor for path \(parameterPath, privacy: .public)")
            return .none()
        }
        let pickerViewController = makeTypePicker(parameterPath: parameterPath, parameter: parameter)
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

    private func parameter(forPath path: [String]) -> RuntimeSpecializationRequest.Parameter? {
        guard let viewModel = specializationViewModel else { return nil }
        var rows = viewModel.topLevelRows
        var matchedRow: SpecializationCellViewModel?
        for name in path {
            guard let next = rows.first(where: { $0.parameter.name == name }) else { return nil }
            matchedRow = next
            rows = next.children
        }
        return matchedRow?.parameter
    }

    private func makeTypePicker(
        parameterPath: [String],
        parameter: RuntimeSpecializationRequest.Parameter
    ) -> SpecializationTypePickerViewController {
        let viewModel = SpecializationTypePickerViewModel(
            parameterPath: parameterPath,
            candidates: parameter.candidates,
            documentState: documentState,
            router: self
        )
        let viewController = SpecializationTypePickerViewController()
        viewController.setupBindings(for: viewModel)
        return viewController
    }
}

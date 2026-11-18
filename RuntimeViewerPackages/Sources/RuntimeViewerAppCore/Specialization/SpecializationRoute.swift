#if os(macOS)

import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

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

#endif

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Backing model for the per-row "Choose Type" popover.
///
/// Kept deliberately small — no `ViewModel<Route>` base class because the
/// popover is a transient UI primitive that doesn't need the standard
/// document/error/router infrastructure. The parent `SpecializationCoordinator`
/// subscribes to `didSelectRelay` and pipes selections back to the
/// `SpecializationSheetViewModel.parameterArgumentChangedRelay`.
@MainActor
public final class TypePickerPopoverViewModel {
    private let allCandidates: [RuntimeSpecializationRequest.Candidate]

    public let filteredCandidatesRelay: BehaviorRelay<[RuntimeSpecializationRequest.Candidate]>

    public let didSelectRelay = PublishRelay<RuntimeSpecializationRequest.Candidate>()

    public init(candidates: [RuntimeSpecializationRequest.Candidate]) {
        self.allCandidates = candidates
        self.filteredCandidatesRelay = BehaviorRelay(value: candidates)
    }

    public func updateSearchText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filteredCandidatesRelay.accept(allCandidates)
            return
        }
        let lowered = trimmed.lowercased()
        let filtered = allCandidates.filter { candidate in
            candidate.displayName.lowercased().contains(lowered)
        }
        filteredCandidatesRelay.accept(filtered)
    }

    public func selectCandidate(_ candidate: RuntimeSpecializationRequest.Candidate) {
        // Generic candidates require nested specialization (not supported in
        // v1); the picker UI shows them disabled so the click should be a
        // no-op rather than an error.
        guard !candidate.isGeneric else { return }
        didSelectRelay.accept(candidate)
    }
}

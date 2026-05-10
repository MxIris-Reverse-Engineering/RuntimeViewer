#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// Backing model for the per-row "Choose Type" popover. Selecting a
/// candidate triggers `SpecializationRoute.didSelectCandidate(...)` so the
/// parent coordinator can apply the change to `SpecializationViewModel`
/// without the popover knowing about its lifecycle.
public final class SpecializationTypePickerViewModel: ViewModel<SpecializationRoute> {
    private let parameterName: String

    private let allCandidates: [RuntimeSpecializationRequest.Candidate]

    @Observed
    public private(set) var filteredCandidates: [RuntimeSpecializationRequest.Candidate] = []

    public struct Input {
        public let searchString: Signal<String>
        public let candidateClicked: Signal<RuntimeSpecializationRequest.Candidate>

        public init(
            searchString: Signal<String>,
            candidateClicked: Signal<RuntimeSpecializationRequest.Candidate>
        ) {
            self.searchString = searchString
            self.candidateClicked = candidateClicked
        }
    }

    public struct Output {
        public let filteredCandidates: Driver<[RuntimeSpecializationRequest.Candidate]>
    }

    public init(
        parameterName: String,
        candidates: [RuntimeSpecializationRequest.Candidate],
        documentState: DocumentState,
        router: any Router<SpecializationRoute>
    ) {
        self.parameterName = parameterName
        self.allCandidates = candidates
        super.init(documentState: documentState, router: router)
        self.filteredCandidates = candidates
    }

    public func transform(_ input: Input) -> Output {
        input.searchString.emitOnNext { [weak self] text in
            guard let self else { return }
            applySearch(text)
        }
        .disposed(by: rx.disposeBag)

        input.candidateClicked.emitOnNext { [weak self] candidate in
            guard let self else { return }
            // Generic candidates require nested specialization (not supported
            // in v1); the picker UI shows them disabled so the click should
            // be a no-op rather than an error.
            guard !candidate.isGeneric else { return }
            router.trigger(.didSelectCandidate(parameterName: parameterName, candidate: candidate))
        }
        .disposed(by: rx.disposeBag)

        return Output(
            filteredCandidates: $filteredCandidates.asDriver()
        )
    }

    private func applySearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filteredCandidates = allCandidates
            return
        }
        let lowered = trimmed.lowercased()
        filteredCandidates = allCandidates.filter { candidate in
            candidate.displayName.lowercased().contains(lowered)
        }
    }
}

#endif

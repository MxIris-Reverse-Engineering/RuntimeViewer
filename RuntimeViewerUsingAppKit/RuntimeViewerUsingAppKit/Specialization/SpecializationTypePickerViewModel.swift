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
    private let parameterPath: [ParameterPathSegment]

    private let allCellViewModels: [SpecializationTypePickerCellViewModel]

    @Observed
    public private(set) var filteredCellViewModels: [SpecializationTypePickerCellViewModel] = []

    public struct Input {
        public let searchString: Signal<String>
        public let cellViewModelClicked: Signal<SpecializationTypePickerCellViewModel>
    }

    public struct Output {
        public let filteredCellViewModels: Driver<[SpecializationTypePickerCellViewModel]>
    }

    public init(
        parameterPath: [ParameterPathSegment],
        candidates: [RuntimeSpecializationRequest.Candidate],
        documentState: DocumentState,
        router: any Router<SpecializationRoute>
    ) {
        self.parameterPath = parameterPath
        self.allCellViewModels = candidates.sorted().map { SpecializationTypePickerCellViewModel(candidate: $0) }
        super.init(documentState: documentState, router: router)
        self.filteredCellViewModels = allCellViewModels
    }

    public func transform(_ input: Input) -> Output {
        input.searchString.emitOnNext { [weak self] text in
            guard let self else { return }
            applySearch(text)
        }
        .disposed(by: rx.disposeBag)

        input.cellViewModelClicked.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            // Both leaf and generic candidates emit `didSelectCandidate` now;
            // generic candidates open the nested specialization flow.
            router.trigger(.didSelectCandidate(parameterPath: parameterPath, candidate: cellViewModel.candidate))
        }
        .disposed(by: rx.disposeBag)

        return Output(
            filteredCellViewModels: $filteredCellViewModels.asDriver()
        )
    }

    private func applySearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            filteredCellViewModels = allCellViewModels
            return
        }
        let lowered = trimmed.lowercased()
        filteredCellViewModels = allCellViewModels.filter { cellViewModel in
            cellViewModel.candidate.displayName.localizedCaseInsensitiveContains(lowered)
        }
    }
}

#endif

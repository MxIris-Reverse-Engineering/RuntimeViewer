#if os(macOS)

import Foundation
import os
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// Identity-only row element for the type-picker table. Letting the
/// driver carry `CandidateBox` instead of `SpecializationTypePickerCellViewModel`
/// defers per-row cellViewModel construction to the `rx.items` builder
/// closure, so the popover open path no longer allocates 10k cellViewModels
/// up front when an unconstrained generic parameter pulls in the full
/// type universe of an image.
///
/// Identity contract: two `CandidateBox` values are the same row iff their
/// underlying `RuntimeSpecializationRequest.Candidate` values are
/// `==`-equal. `Candidate.Equatable` is synthesized from its five stored
/// fields (`id`, `displayName`, `imagePath`, `isGeneric`, `kind`) — all
/// domain primary-key data, so DifferenceKit's diff stays stable and
/// noise-free.
public typealias CandidateBox = DifferentiableBox<RuntimeSpecializationRequest.Candidate>

/// Backing model for the per-row "Choose Type" popover. Selecting a
/// candidate triggers `SpecializationRoute.didSelectCandidate(...)` so the
/// parent coordinator can apply the change to `SpecializationViewModel`
/// without the popover knowing about its lifecycle.
public final class SpecializationTypePickerViewModel: ViewModel<SpecializationRoute> {
    private static let signposter = OSSignposter(
        subsystem: "com.RuntimeViewer.RuntimeViewerUsingAppKit",
        category: "Specialization.TypePicker"
    )

    private let parameterPath: [ParameterPathSegment]

    private let allRows: [CandidateBox]

    @Observed
    public private(set) var filteredRows: [CandidateBox] = []

    public struct Input {
        public let searchString: Signal<String>
        public let rowClicked: Signal<CandidateBox>

        public init(searchString: Signal<String>, rowClicked: Signal<CandidateBox>) {
            self.searchString = searchString
            self.rowClicked = rowClicked
        }
    }

    public struct Output {
        public let filteredRows: Driver<[CandidateBox]>
    }

    public init(
        parameterPath: [ParameterPathSegment],
        candidates: [RuntimeSpecializationRequest.Candidate],
        documentState: DocumentState,
        router: any Router<SpecializationRoute>
    ) {
        let openInterval = Self.signposter.beginInterval(
            "typePicker.viewModelInit",
            id: Self.signposter.makeSignpostID(),
            "candidates: \(candidates.count, privacy: .public)"
        )
        defer { Self.signposter.endInterval("typePicker.viewModelInit", openInterval) }

        self.parameterPath = parameterPath
        self.allRows = candidates.sorted().map(CandidateBox.init)
        super.init(documentState: documentState, router: router)
        self.filteredRows = allRows
    }

    public func transform(_ input: Input) -> Output {
        // Debounce coalesces keystroke bursts (500 ms aligns with Sidebar's
        // three existing search debouncers); `flatMapLatest` cancels any
        // inflight stale filter when a newer query arrives so the result
        // emitted to `$filteredRows` always matches the most recent query.
        input.searchString
            .debounce(.milliseconds(500))
            .asObservable()
            .flatMapLatest { [weak self] query -> Observable<[CandidateBox]> in
                guard let self else { return .empty() }
                return Observable.just(query)
                    .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
                    .map { query in
                        self.computeFilter(query)
                    }
            }
            .observe(on: MainScheduler.instance)
            .asSignal(onErrorJustReturn: [])
            .emit(to: $filteredRows)
            .disposed(by: rx.disposeBag)

        input.rowClicked.emitOnNext { [weak self] row in
            guard let self else { return }
            // Both leaf and generic candidates emit `didSelectCandidate`;
            // generic candidates open the nested specialization flow.
            router.trigger(.didSelectCandidate(parameterPath: parameterPath, candidate: row.model))
        }
        .disposed(by: rx.disposeBag)

        return Output(filteredRows: $filteredRows.asDriver())
    }

    private func computeFilter(_ text: String) -> [CandidateBox] {
        let searchInterval = Self.signposter.beginInterval(
            "typePicker.applySearch",
            id: Self.signposter.makeSignpostID(),
            "query: \(text, privacy: .public)"
        )
        defer { Self.signposter.endInterval("typePicker.applySearch", searchInterval) }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return allRows
        }
        return allRows.filter { row in
            row.model.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

#endif

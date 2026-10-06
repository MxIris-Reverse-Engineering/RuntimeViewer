import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore

final class BatchExportingImageSelectionViewModel: ViewModel<ExportingRoute> {
    struct Input {
        let searchString: Signal<String>
        let matchMode: Signal<BatchExportingImageQuery.MatchMode>
        let matchTarget: Signal<BatchExportingImageQuery.MatchTarget>
        let isCaseSensitive: Signal<Bool>
        let selectAllClicked: Signal<Void>
        let deselectAllClicked: Signal<Void>
        let toggleNode: Signal<BatchExportingImageTreeNode>
    }

    struct Output {
        let nodes: Driver<[BatchExportingImageTreeNode]>
        let didBeginFiltering: Signal<Void>
        let didApplyQuery: Signal<Void>
        let didEndFiltering: Signal<Void>
        let summary: Driver<Summary>
    }

    struct Summary: Equatable {
        let text: String
        let isError: Bool
    }

    let exportingState: BatchExportingState

    /// The root rows the outline shows.
    @RxObserved
    private(set) var nodes: [BatchExportingImageTreeNode] = []

    /// Whether a non-blank query is installed, which is when the outline shows every row expanded.
    @RxObserved
    private(set) var isFiltering: Bool = false

    @RxObserved
    private(set) var summary: Summary = Summary(text: "", isError: false)

    /// Fires after every installed query, blank ones included. A query changes the children of
    /// rows the outline already holds, often without changing the roots, which is all the data
    /// source compares — so the view reloads on this instead.
    private let didApplyQueryRelay = PublishRelay<Void>()

    /// The latest query from the search controls, kept for a tree that arrives after it.
    private var currentQuery = BatchExportingImageQuery()

    private var currentQueryTask: Task<Void, Never>?

    init(exportingState: BatchExportingState, documentState: DocumentState, router: any Router<ExportingRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)

        exportingState.$imageTree.asDriver()
            .compactMap { $0 }
            .driveOnNext { [weak self] imageTree in
                guard let self else { return }
                imageTree.updateSelection(exportingState.selectedImagePaths)
                nodes = imageTree.matchingRootNodes
                updateSummary()
                if !currentQuery.isEmpty {
                    schedule(currentQuery)
                }
            }
            .disposed(by: rx.disposeBag)

        exportingState.$selectedImagePaths.asDriver()
            .driveOnNext { [weak self] selectedImagePaths in
                guard let self else { return }
                exportingState.imageTree?.updateSelection(selectedImagePaths)
                updateSummary()
            }
            .disposed(by: rx.disposeBag)
    }

    func transform(_ input: Input) -> Output {
        // Typing waits 150 ms before matching, as the sidebar's search does; clearing the field
        // and the other controls apply at once. This must be `delay`, not `debounce`: on a
        // single-element `.just`, `debounce` flushes the element the moment the source completes.
        let searchString = input.searchString
            .flatMapLatest { searchString -> Signal<String> in
                if searchString.isEmpty {
                    return .just(searchString)
                } else {
                    return .just(searchString).delay(.milliseconds(150))
                }
            }

        Signal
            .combineLatest(
                searchString.startWith(""),
                input.matchMode.startWith(.contains),
                input.matchTarget.startWith(.name),
                input.isCaseSensitive.startWith(false)
            ) { searchString, matchMode, matchTarget, isCaseSensitive in
                BatchExportingImageQuery(
                    text: searchString,
                    matchMode: matchMode,
                    matchTarget: matchTarget,
                    isCaseSensitive: isCaseSensitive
                )
            }
            .distinctUntilChanged()
            .emitOnNext { [weak self] query in
                guard let self else { return }
                schedule(query)
            }
            .disposed(by: rx.disposeBag)

        input.toggleNode.emitOnNext { [weak self] node in
            guard let self, let imageTree = exportingState.imageTree else { return }
            exportingState.selectedImagePaths = imageTree.selection(afterToggling: node, in: exportingState.selectedImagePaths)
        }
        .disposed(by: rx.disposeBag)

        input.selectAllClicked.emitOnNext { [weak self] in
            guard let self, let imageTree = exportingState.imageTree else { return }
            exportingState.selectedImagePaths = imageTree.selection(afterSelectingAllMatchingImagesIn: exportingState.selectedImagePaths)
        }
        .disposed(by: rx.disposeBag)

        input.deselectAllClicked.emitOnNext { [weak self] in
            guard let self, let imageTree = exportingState.imageTree else { return }
            exportingState.selectedImagePaths = imageTree.selection(afterDeselectingAllMatchingImagesIn: exportingState.selectedImagePaths)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            nodes: $nodes.asDriver(),
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didApplyQuery: didApplyQueryRelay.asSignal(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid(),
            summary: $summary.asDriver()
        )
    }

    private func schedule(_ query: BatchExportingImageQuery) {
        currentQuery = query
        guard let imageTree = exportingState.imageTree else { return }
        currentQueryTask?.cancel()
        currentQueryTask = Task { [weak self] in
            guard await imageTree.apply(query) else { return }
            guard let self else { return }
            didApply(query, to: imageTree)
        }
    }

    private func didApply(_ query: BatchExportingImageQuery, to imageTree: BatchExportingImageTree) {
        // Ahead of `nodes`: the outline saves its expansion state when filtering begins and puts
        // it back when filtering ends, and both have to happen around the reload, not after it.
        let isQueryActive = !query.isEmpty
        if isFiltering != isQueryActive {
            isFiltering = isQueryActive
        }
        nodes = imageTree.matchingRootNodes
        didApplyQueryRelay.accept(())
        updateSummary()
    }

    private func updateSummary() {
        guard let imageTree = exportingState.imageTree else {
            summary = Summary(text: "", isError: false)
            return
        }
        if let invalidQueryReason = imageTree.invalidQueryReason {
            summary = Summary(text: "Invalid regular expression: \(invalidQueryReason)", isError: true)
            return
        }
        var text = "\(exportingState.selectedImagePaths.count) of \(imageTree.imageNodes.count) selected"
        if !imageTree.query.isEmpty {
            text += ", \(imageTree.matchingImagePaths.count) matching"
        }
        summary = Summary(text: text, isError: false)
    }
}

extension BatchExportingImageSelectionViewModel: ExportingStepViewModel {
    var title: Driver<String> {
        "Select Images:"
    }

    var previousTitle: Driver<String> {
        "Previous"
    }

    var nextTitle: Driver<String> {
        "Next"
    }

    var isPreviousEnabled: Driver<Bool> {
        false
    }

    var isNextEnabled: Driver<Bool> {
        exportingState.$selectedImagePaths.asDriver().map { !$0.isEmpty }
    }
}

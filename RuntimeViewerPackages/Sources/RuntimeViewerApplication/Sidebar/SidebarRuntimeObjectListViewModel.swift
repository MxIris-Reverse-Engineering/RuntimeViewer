import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRuntimeObjectListViewModel: SidebarRuntimeObjectViewModel {
    public typealias CellLookup = (cell: SidebarRuntimeObjectCellViewModel, ancestors: [SidebarRuntimeObjectCellViewModel])

    @Observed public private(set) var searchStringForOpenQuickly: String = ""
    @Observed public private(set) var nodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var filteredNodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFilteringForOpenQuickly: Bool = false

    /// Latest non-nil root object the document is inspecting, waiting to
    /// be resolved to a concrete cell once it appears in `nodes`. Driven
    /// by `documentState.$selectionStack` (see `transform`) — never by an
    /// external imperative call.
    private let pendingSelectRelay = PublishRelay<RuntimeObject>()

    /// In-flight Open Quickly fuzzy match. Cancelled and superseded by
    /// every new (debounced) query so two searches never mutate the same
    /// cell view models concurrently, and a slow older match can never
    /// overwrite a newer query's results.
    private var currentOpenQuicklyFilterTask: Task<Void, Never>?

    /// Generation guard for `currentOpenQuicklyFilterTask` — also bumped
    /// when `nodesForOpenQuickly` is rebuilt, so a match computed against
    /// a discarded node array is never applied.
    private var currentOpenQuicklyFilterGeneration: Int = 0

    override var isSorted: Bool { true }

    public override init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    public static func findCell(
        for object: RuntimeObject,
        in nodes: [SidebarRuntimeObjectCellViewModel]
    ) -> CellLookup? {
        for node in nodes {
            if node.runtimeObject == object { return (node, []) }
            if let inner = findCell(for: object, in: node.children) {
                return (inner.cell, [node] + inner.ancestors)
            }
        }
        return nil
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClickedForOpenQuickly: Signal<SidebarRuntimeObjectCellViewModel>
        public let searchStringForOpenQuickly: Signal<String>
        public let addBookmark: Signal<SidebarRuntimeObjectCellViewModel>
    }

    public struct Output {
        public let runtimeObjectsForOpenQuickly: Driver<[SidebarRuntimeObjectCellViewModel]>
        public let selectRuntimeObject: Signal<SidebarRuntimeObjectCellViewModel>
        public let selectCell: Signal<CellLookup>
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        try await runtimeEngine.objects(in: imagePath)
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let stream = await runtimeEngine.objectsWithProgress(in: imagePath)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    override func reloadData() async throws {
        try await super.reloadData()
        try Task.checkCancellation()

        await MainActor.run {
            self.currentOpenQuicklyFilterTask?.cancel()
            self.currentOpenQuicklyFilterTask = nil
            self.currentOpenQuicklyFilterGeneration &+= 1
            self.searchStringForOpenQuickly = ""
            self.nodesForOpenQuickly = nodes.map { $0.runtimeObject }.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: true) }
            self.filteredNodesForOpenQuickly = []
        }
    }

    /// Open Quickly filter pass: fuzzy-match off-main, apply on main iff
    /// still current. Mirrors the sidebar's `scheduleRefilter()` but over
    /// the flat `nodesForOpenQuickly` array with the fixed Open Quickly
    /// configuration. Only the displayed top-level rows receive highlight
    /// updates — the legacy path also cascaded highlights into never-shown
    /// child cells, which was pure waste.
    @MainActor
    private func scheduleOpenQuicklyRefilter(query: String) {
        currentOpenQuicklyFilterTask?.cancel()
        currentOpenQuicklyFilterGeneration &+= 1
        let generation = currentOpenQuicklyFilterGeneration

        if query.isEmpty {
            currentOpenQuicklyFilterTask = nil
            if isFilteringForOpenQuickly {
                isFilteringForOpenQuickly = false
            }
            // Clear stale highlights so the next search starts clean;
            // the guarded didSet makes rows without a highlight free.
            for cellViewModel in nodesForOpenQuickly {
                cellViewModel.filterResult = nil
            }
            filteredNodesForOpenQuickly = []
            return
        }

        if !isFilteringForOpenQuickly {
            isFilteringForOpenQuickly = true
        }

        let context = FilterContext(query: query, isCaseInsensitive: false, mode: .fuzzySearch)
        let cellViewModels = nodesForOpenQuickly
        let haystacks = cellViewModels.map(\.filterableString)
        currentOpenQuicklyFilterTask = Task { @MainActor [weak self] in
            let verdicts = await Self.matchOffMain(context: context, haystacks: haystacks)
            guard !Task.isCancelled, let self else { return }
            guard self.currentOpenQuicklyFilterGeneration == generation else { return }

            var isMatchedByIndex = [Bool](repeating: false, count: cellViewModels.count)
            var filteredCellViewModels: [SidebarRuntimeObjectCellViewModel] = []
            filteredCellViewModels.reserveCapacity(verdicts.count)
            for verdict in verdicts {
                isMatchedByIndex[verdict.haystackIndex] = true
                let cellViewModel = cellViewModels[verdict.haystackIndex]
                cellViewModel.filterResult = verdict.result
                filteredCellViewModels.append(cellViewModel)
            }
            for (cellViewModelIndex, cellViewModel) in cellViewModels.enumerated() where !isMatchedByIndex[cellViewModelIndex] {
                cellViewModel.filterResult = nil
            }
            self.filteredNodesForOpenQuickly = filteredCellViewModels
            self.currentOpenQuicklyFilterTask = nil
        }
    }

    /// Hop for the fuzzy matcher: `nonisolated async` runs on the global
    /// concurrent executor, keeping the scoring off the main thread.
    private nonisolated static func matchOffMain(context: FilterContext, haystacks: [String]) async -> [FilterMatchVerdict] {
        FilterEngine.match(context, haystacks: haystacks)
    }

    public func transform(_ input: Input) -> Output {
        input.addBookmark.emitOnNext { [weak self] viewModel in
            guard let self else { return }
            let runtimeSource = documentState.runtimeEngine.source
            appDefaults.objectBookmarksBySourceAndImagePath[runtimeSource, default: [:]][imagePath, default: []].append(.init(source: runtimeSource, object: viewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        // A live-stream debounce (unlike the sidebar's per-element delay):
        // 150 ms of typing silence triggers one match. Short window on
        // purpose — the match runs off-main and stale passes are cancelled
        // by `scheduleOpenQuicklyRefilter`.
        input.searchStringForOpenQuickly
            .skip(1)
            .debounce(.milliseconds(150))
            .emitOnNextMainActor { [weak self] query in
                guard let self else { return }
                scheduleOpenQuicklyRefilter(query: query)
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectClickedForOpenQuickly
            .emitOnNextMainActor { [weak self] viewModel in
                guard let self else { return }
                #if os(macOS)
                documentState.selectionRouter.trigger(.push(viewModel.runtimeObject))
                #else
                self.router.trigger(.selectedObject(viewModel.runtimeObject))
                #endif
            }
            .disposed(by: rx.disposeBag)

        // Visual selection follows whatever the document is currently
        // showing. `selectedRuntimeObject` is the display layer's single
        // source of truth — sidebar clicks, toolbar previous/next, history
        // menu jumps, specialization completion, and tab switches all land
        // as a new value here, so one subscription covers them all.
        documentState.$selectedRuntimeObject
            .asObservable()
            .compactMap { $0 }
            .distinctUntilChanged()
            .bind(to: pendingSelectRelay)
            .disposed(by: rx.disposeBag)

        let pendingResolved: Signal<CellLookup> = pendingSelectRelay
            .asObservable()
            .flatMapLatest { [weak self] object -> Observable<CellLookup> in
                guard let self else { return .empty() }
                return self.$nodes
                    .asObservable()
                    .compactMap { Self.findCell(for: object, in: $0) }
                    .take(1)
            }
            .asSignal(onErrorSignalWith: .empty())

        return Output(
            runtimeObjectsForOpenQuickly: $filteredNodesForOpenQuickly.asDriver().skip(1),
            selectRuntimeObject: input.runtimeObjectClickedForOpenQuickly,
            selectCell: pendingResolved
        )
    }
}

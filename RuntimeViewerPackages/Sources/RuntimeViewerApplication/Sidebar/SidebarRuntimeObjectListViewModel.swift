import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

// Not `final`: tests subclass this to seed a canned object list through
// the real `reloadData` path (mirroring `SidebarRuntimeObjectViewModel`,
// which is subclassable for the same reason).
public class SidebarRuntimeObjectListViewModel: SidebarRuntimeObjectViewModel {
    public typealias CellLookup = (cell: SidebarRuntimeObjectCellViewModel, ancestors: [SidebarRuntimeObjectCellViewModel])

    @Observed public private(set) var searchStringForOpenQuickly: String = ""
    @Observed public private(set) var filteredNodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFilteringForOpenQuickly: Bool = false

    /// Sorted top-level objects backing Open Quickly. Rows materialize
    /// into cell view models lazily (see `openQuicklyCellViewModel(at:)`),
    /// so a reload no longer eagerly constructs a second full copy of the
    /// sidebar's cell view models on the main thread — the legacy path
    /// paid N cell constructions (icons, attributed titles, child trees)
    /// per image load for a list most sessions never open.
    private var openQuicklyRuntimeObjects: [RuntimeObject] = []

    /// Bumped every time `openQuicklyRuntimeObjects` is replaced. A
    /// completed haystack build is keyed to the object list it was built
    /// from, which the filter generation alone cannot express — that
    /// counter also moves on every keystroke.
    private var openQuicklyRuntimeObjectsVersion: Int = 0

    /// Haystack strings aligned index-for-index with
    /// `openQuicklyRuntimeObjects`. Computed off-main by the first query
    /// after a reload, then reused for every subsequent keystroke.
    /// Internal (not private) so tests can pin that a superseded pass
    /// still installs the build it completed.
    private(set) var openQuicklyHaystacksCache: [String]?

    /// Cell view models materialized so far, keyed by row index into
    /// `openQuicklyRuntimeObjects`. Only rows some query has actually
    /// matched exist here; repeat matches across keystrokes reuse the
    /// same instance so DifferenceKit sees stable row identities.
    /// Internal (not private) so tests can pin the lazy contract.
    private(set) var openQuicklyCellViewModelsByRowIndex: [Int: SidebarRuntimeObjectCellViewModel] = [:]

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

    /// Builds the Open Quickly haystacks for an object list. Injectable so
    /// tests can gate the build and drive supersession deterministically;
    /// the default is pure value work with no reference to the view model.
    typealias HaystackBuilder = @Sendable ([RuntimeObject]) async -> [String]

    private let haystackBuilder: HaystackBuilder

    override var isSorted: Bool { true }

    public override init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        self.haystackBuilder = Self.defaultHaystackBuilder
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    init(
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>,
        haystackBuilder: @escaping HaystackBuilder
    ) {
        self.haystackBuilder = haystackBuilder
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    /// Off-main haystack computation — building 10k+ tree haystacks is
    /// the other expensive half of the legacy eager reload. Pure value
    /// work over the captured `RuntimeObject` array.
    private static let defaultHaystackBuilder: HaystackBuilder = { runtimeObjects in
        runtimeObjects.map { SidebarRuntimeObjectCellViewModel.haystack(for: $0) }
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
            // `nodes` is already name-sorted (`isSorted == true`), so the
            // Open Quickly row order comes for free. Everything derived
            // from the previous object list is invalidated together.
            self.openQuicklyRuntimeObjects = self.nodes.map(\.runtimeObject)
            self.openQuicklyRuntimeObjectsVersion &+= 1
            self.openQuicklyHaystacksCache = nil
            self.openQuicklyCellViewModelsByRowIndex = [:]
            self.filteredNodesForOpenQuickly = []
        }
    }

    /// Returns the row's cell view model, materializing it on first use.
    /// Construction is the expensive part of the legacy reload (icons +
    /// attributed title + child tree), so it is deferred to rows a query
    /// actually surfaces and amortized across keystrokes by the cache.
    @MainActor
    private func openQuicklyCellViewModel(at rowIndex: Int) -> SidebarRuntimeObjectCellViewModel {
        if let materializedCellViewModel = openQuicklyCellViewModelsByRowIndex[rowIndex] {
            return materializedCellViewModel
        }
        let cellViewModel = SidebarRuntimeObjectCellViewModel(
            runtimeObject: openQuicklyRuntimeObjects[rowIndex],
            forOpenQuickly: true
        )
        openQuicklyCellViewModelsByRowIndex[rowIndex] = cellViewModel
        return cellViewModel
    }

    /// Open Quickly filter pass: fuzzy-match off-main, apply on main iff
    /// still current. Mirrors the sidebar's `scheduleRefilter()` but over
    /// the flat value-array of top-level objects with the fixed Open
    /// Quickly configuration. Matching runs against pure haystack strings
    /// (computed off-main and cached per reload); only matched rows are
    /// materialized into cell view models, so a keystroke costs
    /// O(matches) main-thread work instead of O(all rows).
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
            // Clear stale highlights so the next search starts clean.
            // Only materialized rows can carry one, and the guarded
            // didSet makes already-clean rows free.
            for cellViewModel in openQuicklyCellViewModelsByRowIndex.values {
                cellViewModel.filterResult = nil
            }
            filteredNodesForOpenQuickly = []
            return
        }

        if !isFilteringForOpenQuickly {
            isFilteringForOpenQuickly = true
        }

        let context = FilterContext(query: query, isCaseInsensitive: false, mode: .fuzzySearch)
        let runtimeObjects = openQuicklyRuntimeObjects
        let runtimeObjectsVersion = openQuicklyRuntimeObjectsVersion
        let cachedHaystacks = openQuicklyHaystacksCache
        let haystackBuilder = haystackBuilder
        currentOpenQuicklyFilterTask = Task { @MainActor [weak self] in
            let haystacks: [String]
            if let cachedHaystacks {
                haystacks = cachedHaystacks
            } else {
                let computedHaystacks = await haystackBuilder(runtimeObjects)
                guard let self else { return }
                // Install before the generation guard: the haystacks depend
                // only on the object list, never on the query, so a pass
                // superseded by the next keystroke still produced the
                // artifact every later pass needs. Discarding it meant that
                // whenever the build outran the 150 ms debounce, continuous
                // typing threw away a complete build per query and the cache
                // was never populated at all.
                //
                // The version check is what the generation counter cannot
                // do: that one also moves on every keystroke, while these
                // haystacks are only valid for the object list they were
                // built from — installing them after a reload swapped the
                // list would misalign every index.
                if self.openQuicklyRuntimeObjectsVersion == runtimeObjectsVersion {
                    self.openQuicklyHaystacksCache = computedHaystacks
                }
                guard !Task.isCancelled, self.currentOpenQuicklyFilterGeneration == generation else { return }
                haystacks = computedHaystacks
            }
            let verdicts = await Self.matchOffMain(context: context, haystacks: haystacks)
            guard !Task.isCancelled, let self else { return }
            guard self.currentOpenQuicklyFilterGeneration == generation else { return }

            var matchedRowIndices = Set<Int>(minimumCapacity: verdicts.count)
            var filteredCellViewModels: [SidebarRuntimeObjectCellViewModel] = []
            filteredCellViewModels.reserveCapacity(verdicts.count)
            for verdict in verdicts {
                matchedRowIndices.insert(verdict.haystackIndex)
                let cellViewModel = self.openQuicklyCellViewModel(at: verdict.haystackIndex)
                cellViewModel.filterResult = verdict.result
                filteredCellViewModels.append(cellViewModel)
            }
            // Un-highlight previously materialized rows that missed this
            // query; rows never materialized never had a highlight.
            for (rowIndex, cellViewModel) in self.openQuicklyCellViewModelsByRowIndex where !matchedRowIndices.contains(rowIndex) {
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

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

    /// Rows the previous pass highlighted. Clearing stale highlights only
    /// has to touch these — the materialized-cell map is deliberately kept
    /// warm across searches, so it accumulates every row any query has ever
    /// surfaced and sweeping it whole made per-keystroke main-actor cost
    /// grow with session length.
    private var highlightedOpenQuicklyRowIndices: Set<Int> = []

    /// Haystack build shared by every pass over the same object list, so
    /// overlapping keystrokes join one build instead of each starting an
    /// identical full one. Cleared once the build installs.
    private var inFlightOpenQuicklyHaystackBuild: (objectListVersion: Int, task: Task<[String], Never>)?

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

    /// Upper bound on rows materialized for one query.
    ///
    /// `.fuzzySearch` keeps every haystack with a non-zero score, and a
    /// haystack is the object's name plus every descendant's, so a one- or
    /// two-character query matches essentially the whole image. Without a
    /// bound the apply loop constructed a cell view model — and, through
    /// `rebuildChildren()`, one per descendant, each with icon lookups and
    /// an attributed title — for every row in a single main-actor turn,
    /// which is the O(N) main-thread cost lazy materialization exists to
    /// remove. `FuzzySearchable.fuzzyMatch` returns matches sorted by
    /// descending weight, so the cap keeps the best ones; the rows it drops
    /// are the near-zero-score tail nobody scrolls to.
    static let openQuicklyMaximumMaterializedRows = 500

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

    override func invalidateNodeDerivedState() {
        super.invalidateNodeDerivedState()
        currentOpenQuicklyFilterTask?.cancel()
        currentOpenQuicklyFilterTask = nil
        currentOpenQuicklyFilterGeneration &+= 1
        searchStringForOpenQuickly = ""
        // `nodes` is already name-sorted (`isSorted == true`), so the
        // Open Quickly row order comes for free. Everything derived
        // from the previous object list is invalidated together.
        openQuicklyRuntimeObjects = nodes.map(\.runtimeObject)
        openQuicklyRuntimeObjectsVersion &+= 1
        openQuicklyHaystacksCache = nil
        // The version bump already makes this build unusable (its indices
        // address the previous list); drop the reference so it is not held
        // for the rest of the document's life.
        inFlightOpenQuicklyHaystackBuild = nil
        openQuicklyCellViewModelsByRowIndex = [:]
        highlightedOpenQuicklyRowIndices = []
        filteredNodesForOpenQuickly = []
    }

    /// Returns the row's cell view model, materializing it on first use.
    /// Construction is the expensive part of the legacy reload (icons +
    /// attributed title + child tree), so it is deferred to rows a query
    /// actually surfaces and amortized across keystrokes by the cache.
    @MainActor
    private func openQuicklyCellViewModel(at rowIndex: Int, haystack: String) -> SidebarRuntimeObjectCellViewModel {
        if let materializedCellViewModel = openQuicklyCellViewModelsByRowIndex[rowIndex] {
            return materializedCellViewModel
        }
        let cellViewModel = SidebarRuntimeObjectCellViewModel(
            runtimeObject: openQuicklyRuntimeObjects[rowIndex],
            forOpenQuickly: true
        )
        // Hand over the haystack the off-main pass already built for this
        // exact object. Stamping `filterResult` on a fresh cell otherwise
        // triggers `composedTitle()`, whose cold `currentAndChildrenNames`
        // rebuilds the entire subtree name string on the main actor — the
        // byte-identical twin of the string one line up, per the parity
        // contract on `haystack(for:)`.
        cellViewModel.seedCurrentAndChildrenNames(haystack)
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
            // Only the previous pass's matches can carry one.
            for rowIndex in highlightedOpenQuicklyRowIndices {
                openQuicklyCellViewModelsByRowIndex[rowIndex]?.filterResult = nil
            }
            highlightedOpenQuicklyRowIndices = []
            filteredNodesForOpenQuickly = []
            return
        }

        if !isFilteringForOpenQuickly {
            isFilteringForOpenQuickly = true
        }

        let context = FilterContext(query: query, isCaseInsensitive: false, mode: .fuzzySearch)
        let runtimeObjects = openQuicklyRuntimeObjects
        let runtimeObjectsVersion = openQuicklyRuntimeObjectsVersion
        currentOpenQuicklyFilterTask = Task { @MainActor [weak self] in
            guard let haystacks = await self?.openQuicklyHaystacks(
                forObjectListVersion: runtimeObjectsVersion,
                runtimeObjects: runtimeObjects
            ) else { return }
            guard !Task.isCancelled, let self, self.currentOpenQuicklyFilterGeneration == generation else { return }
            let verdicts = await Self.matchOffMain(context: context, haystacks: haystacks)
            guard !Task.isCancelled else { return }
            guard self.currentOpenQuicklyFilterGeneration == generation else { return }

            // Verdicts arrive sorted by descending fuzzy weight, so the
            // prefix is the best-scoring window (see
            // `openQuicklyMaximumMaterializedRows`).
            let displayedVerdicts = verdicts.prefix(Self.openQuicklyMaximumMaterializedRows)
            var matchedRowIndices = Set<Int>(minimumCapacity: displayedVerdicts.count)
            var filteredCellViewModels: [SidebarRuntimeObjectCellViewModel] = []
            filteredCellViewModels.reserveCapacity(displayedVerdicts.count)
            for verdict in displayedVerdicts {
                matchedRowIndices.insert(verdict.haystackIndex)
                let cellViewModel = self.openQuicklyCellViewModel(
                    at: verdict.haystackIndex,
                    haystack: haystacks[verdict.haystackIndex]
                )
                cellViewModel.filterResult = verdict.result
                filteredCellViewModels.append(cellViewModel)
            }
            // Un-highlight the rows the previous pass lit up that this one
            // missed. Rows that were never highlighted never had one, so
            // the warm materialized-cell map does not need sweeping.
            for rowIndex in self.highlightedOpenQuicklyRowIndices.subtracting(matchedRowIndices) {
                self.openQuicklyCellViewModelsByRowIndex[rowIndex]?.filterResult = nil
            }
            self.highlightedOpenQuicklyRowIndices = matchedRowIndices
            self.filteredNodesForOpenQuickly = filteredCellViewModels
            self.currentOpenQuicklyFilterTask = nil
        }
    }

    /// Returns the haystacks for `runtimeObjects`, joining a build already
    /// running for the same object list instead of starting a second one.
    ///
    /// Sampling `openQuicklyHaystacksCache` at schedule time and never
    /// re-reading it meant every keystroke landing during the first build
    /// began its own full O(N) build of the identical array —
    /// `defaultHaystackBuilder` has no cancellation points, so cancelling
    /// the superseded pass freed nothing and the builds ran concurrently.
    /// Sharing one task is the shape `RuntimeInterfaceCache` already uses
    /// for the same problem.
    ///
    /// The task is deliberately unstructured: it must outlive the pass that
    /// happened to start it, since the artifact belongs to the object list
    /// rather than to any one query.
    @MainActor
    private func openQuicklyHaystacks(
        forObjectListVersion objectListVersion: Int,
        runtimeObjects: [RuntimeObject]
    ) async -> [String] {
        if let cachedHaystacks = openQuicklyHaystacksCache,
           openQuicklyRuntimeObjectsVersion == objectListVersion {
            return cachedHaystacks
        }
        if let inFlightBuild = inFlightOpenQuicklyHaystackBuild,
           inFlightBuild.objectListVersion == objectListVersion {
            return await inFlightBuild.task.value
        }

        let haystackBuilder = haystackBuilder
        let buildTask = Task { await haystackBuilder(runtimeObjects) }
        inFlightOpenQuicklyHaystackBuild = (objectListVersion, buildTask)
        let builtHaystacks = await buildTask.value

        // Install even when the pass that started this build was superseded:
        // the haystacks depend only on the object list, so a later pass would
        // otherwise rebuild what this one already finished. The version check
        // is what the generation counter cannot do — that one moves on every
        // keystroke, while these haystacks stay valid until a reload swaps
        // the list, and installing them against a swapped list would misalign
        // every index.
        if openQuicklyRuntimeObjectsVersion == objectListVersion {
            openQuicklyHaystacksCache = builtHaystacks
            inFlightOpenQuicklyHaystackBuild = nil
        }
        return builtHaystacks
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

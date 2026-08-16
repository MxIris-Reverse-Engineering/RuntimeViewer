import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public class SidebarRootViewModel: ViewModel<SidebarRootRoute> {
    private let nodesSource: Observable<[RuntimeImageNode]>

    private var nodesIndexed: Signal<Void> = .empty()

    var isFilterEmptyNodes: Bool { true }

    @Observed
    public private(set) var nodes: [SidebarRootCellViewModel] = []

    @Observed
    public private(set) var filteredNodes: [SidebarRootCellViewModel] = []

    @Observed
    public private(set) var allNodes: [String: SidebarRootCellViewModel] = [:]

    @Observed
    public private(set) var isFiltering: Bool = false

    /// In-flight root filter pass. Cancelled and superseded by every new
    /// (coalesced) query so a slow older match can never overwrite a
    /// newer query's results.
    private var currentRootFilterTask: Task<Void, Never>?

    /// Generation guard for `currentRootFilterTask` — also bumped when
    /// `$nodes` is rebuilt, so verdicts computed against a discarded cell
    /// tree are never applied.
    ///
    /// `package` rather than `private` so `SidebarRootFilterInvalidationTests`
    /// can pin that the rebuild bumps it *synchronously*; deferring the bump
    /// is exactly the defect the guard exists to prevent.
    package private(set) var currentRootFilterGeneration: Int = 0

    public init(documentState: DocumentState, router: any Router<SidebarRootRoute>, nodesSource: Observable<[RuntimeImageNode]>) {
        self.nodesSource = nodesSource

        super.init(documentState: documentState, router: router)

        nodesSource
            .observe(on: MainScheduler.instance)
            .map { $0.map { SidebarRootCellViewModel(node: $0) } }
            .bind(to: $nodes)
            .disposed(by: rx.disposeBag)

        let indexedNodes = $nodes
            .filter { [weak self] in
                guard let self else { return false }
                return isFilterEmptyNodes ? !$0.isEmpty : true
            }
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            // `map` (not `flatMapLatest`) — a sync body fed to RxConcurrency's
            // `flatMapLatest(_:async)` overload is silently wrapped in
            // `Observable.async { Task { ... } }`, and `Task` inherits the
            // surrounding `@MainActor` isolation from `ViewModel`. That hop
            // overrides `.observe(on: ConcurrentDispatchQueueScheduler(...))`
            // and lands the iterator (which lazy-builds every cell view model
            // and its NSAttributedString) on the main thread — visible at
            // ~386ms in time profiles. `map` keeps the work on the background
            // scheduler we asked for.
            .map { nodes -> [String: SidebarRootCellViewModel] in
                #log(.info, "\(Self.self, privacy: .public) Indexing sidebar nodes...")
                var allNodes: [String: SidebarRootCellViewModel] = [:]
                for rootNode in nodes {
                    allNodes[rootNode.node.name] = rootNode
                    let rootNodeSequence = AnySequence<SidebarRootCellViewModel> {
                        SidebarRootCellViewModel.Iterator(node: rootNode)
                    }
                    for node in rootNodeSequence {
                        allNodes[node.node.absolutePath] = node
                    }
                }
                return allNodes
            }
            .observe(on: MainScheduler.instance)
            .asSignal(onErrorJustReturn: [:])

        indexedNodes.emit(to: $allNodes).disposed(by: rx.disposeBag)

        self.nodesIndexed = indexedNodes.trackActivity(_commonLoading).asSignal().mapToVoid()
        
        
        // `$nodes` is fed by the `observe(on: MainScheduler.instance)`
        // chain above and replayed on this main-actor `init`, so every
        // delivery is already on the main actor.
        $nodes
            .asObservable()
            .subscribeOnNext { [weak self] rebuiltNodes in
                MainActor.assumeIsolated {
                    self?.installRebuiltNodes(rebuiltNodes)
                }
            }
            .disposed(by: rx.disposeBag)
    }

    /// Installs a rebuilt image tree: drops the visual filter (matching the
    /// legacy behavior of clearing it on an image-list rebuild) and
    /// invalidates any in-flight filter pass, whose verdicts belong to
    /// cells that are no longer on screen.
    ///
    /// Both halves must land in the same main-actor turn, which is why this
    /// is one synchronous step rather than a `bind(to: $filteredNodes)`
    /// alongside a `subscribeOnNextMainActor` invalidation. The latter
    /// expands to `Task { @MainActor in … }`, so the cancellation and the
    /// generation bump were merely *enqueued* while the list swap ran
    /// synchronously — and a verdict continuation resuming in that window
    /// passed both guards (`Task.isCancelled` still false, the generation
    /// still its captured value) and republished the discarded cell tree
    /// over the fresh one. Nothing reschedules a filter afterwards, so the
    /// stale rows stayed on screen until the user typed again.
    @MainActor
    private func installRebuiltNodes(_ rebuiltNodes: [SidebarRootCellViewModel]) {
        currentRootFilterTask?.cancel()
        currentRootFilterTask = nil
        currentRootFilterGeneration &+= 1
        // Before the `filteredNodes` assignment, never after.
        // `didEndFiltering` fires off this flag and takes the outline out of
        // `.filtering`, while `didChangeFiltering` fires off `filteredNodes`
        // but only while the flag is still set. Clearing first therefore
        // skips the `expandItem(nil, expandChildren: true)` that a
        // `.filtering` `reloadData()` runs over the whole image tree;
        // clearing second runs it, against a tree the filter no longer
        // applies to. Leaving it set at all wedges the sidebar: nothing else
        // lowers it, so every later rebuild re-expands the tree and
        // `scheduleExpansionPersist`'s `filteringState == .idle` guard keeps
        // expansion autosave off for the rest of the session.
        if isFiltering {
            isFiltering = false
        }
        filteredNodes = rebuiltNodes
    }

    /// Root filter pass: snapshot the cell tree on the main actor,
    /// compute verdicts (aggregate-name construction + matching) on the
    /// global executor, then apply on the main actor iff still current.
    /// The legacy path ran the whole cascade synchronously on the main
    /// thread per (never actually delayed) keystroke.
    @MainActor
    private func scheduleRootRefilter(query: String) {
        currentRootFilterTask?.cancel()
        currentRootFilterGeneration &+= 1
        let generation = currentRootFilterGeneration

        if query.isEmpty {
            currentRootFilterTask = nil
            if isFiltering {
                isFiltering = false
            }
            SidebarRootFilterPipeline.resetToUnfiltered(nodes)
            filteredNodes = nodes
            return
        }

        if !isFiltering {
            isFiltering = true
        }

        let cells = nodes
        let snapshotForest = SidebarRootFilterPipeline.snapshot(of: cells)
        currentRootFilterTask = Task { @MainActor [weak self] in
            let forestVerdict = await Self.computeVerdictsOffMain(for: snapshotForest, query: query)
            guard !Task.isCancelled, let self else { return }
            guard self.currentRootFilterGeneration == generation else { return }
            guard let filteredCells = SidebarRootFilterPipeline.apply(forestVerdict, to: cells) else { return }
            self.filteredNodes = filteredCells
            self.currentRootFilterTask = nil
        }
    }

    /// Hop for the verdict computation: `nonisolated async` runs on the
    /// global concurrent executor, keeping the recursive aggregate-name
    /// construction and ICU `contains` matching off the main thread.
    private nonisolated static func computeVerdictsOffMain(
        for forest: [SidebarRootFilterPipeline.SnapshotNode],
        query: String
    ) async -> SidebarRootFilterPipeline.ForestVerdict {
        SidebarRootFilterPipeline.verdicts(for: forest, query: query)
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let clickedNode: Signal<SidebarRootCellViewModel>
        public let selectedNode: Signal<SidebarRootCellViewModel>
        public let searchString: Signal<String>
    }

    @MemberwiseInit(.public)
    public struct Output {
        public let nodes: Driver<[SidebarRootCellViewModel]>
        public let nodesIndexed: Signal<Void>
        public let didBeginFiltering: Signal<Void>
        public let didChangeFiltering: Signal<Void>
        public let didEndFiltering: Signal<Void>
        public let toggleExpansion: Signal<(item: SidebarRootCellViewModel, maxDepth: Int)>
    }

    public func transform(_ input: Input) -> Output {
        input.clickedNode.emitOnNextMainActor { [weak self] viewModel in
            guard let self else { return }

            if viewModel.node.isLeaf {
                #if os(macOS)
                documentState.selectionRouter.trigger(.switchImage(viewModel.node))
                #else
                self.router.trigger(.clickedNode(viewModel.node))
                #endif
            }
        }
        .disposed(by: rx.disposeBag)

        // Selecting a leaf node (i.e. an image, not a path-segment folder)
        // hints the background indexer to prioritize that image's pending
        // tasks. Non-leaf rows correspond to filesystem path segments and
        // have no associated image path, so they are filtered out.
        // Note: `node.path` strips the synthetic root component (e.g.
        // "Dyld Shared Cache") that prefixes `absolutePath`, yielding the
        // real dyld image path expected by the indexing manager.
        input.selectedNode.emitOnNextMainActor { [weak self] viewModel in
            guard let self else { return }
            guard viewModel.node.isLeaf else { return }
            documentState.backgroundIndexingCoordinator.prioritize(imagePath: viewModel.node.path)
        }
        .disposed(by: rx.disposeBag)

        // Keystroke coalescing: non-empty queries wait 150 ms (cancelled by
        // the next keystroke via `flatMapLatest`), clearing applies
        // immediately. NOTE: this must be `delay`, not `debounce` — on a
        // single-element `.just` sequence, `debounce` flushes the pending
        // element the moment the source completes, so the previous
        // `.just(...).debounce(500ms)` never delayed anything.
        input.searchString
            .flatMapLatest { filter -> Signal<String> in
                if filter.isEmpty {
                    return .just(filter)
                } else {
                    return .just(filter)
                        .delay(.milliseconds(150))
                }
            }
            .emitOnNextMainActor { [weak self] query in
                guard let self else { return }
                scheduleRootRefilter(query: query)
            }.disposed(by: rx.disposeBag)

        return Output(
            nodes: $filteredNodes.asDriver(),
            nodesIndexed: nodesIndexed,
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: $filteredNodes.asSignal(onErrorJustReturn: []).withLatestFrom($isFiltering.asSignal(onErrorJustReturn: false)).filter { $0 }.mapToVoid(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid(),
            toggleExpansion: input.clickedNode
                .filter { !$0.isLeaf }
                .compactMap { [weak self] item -> (item: SidebarRootCellViewModel, maxDepth: Int)? in
                    guard let self else { return nil }
                    return (item, settings.general.sidebarMaxExpansionDepth)
                }
                .asSignal(onErrorSignalWith: .empty()),
        )
    }
}

extension Collection {
    fileprivate var isNotEmpty: Bool { !isEmpty }
}

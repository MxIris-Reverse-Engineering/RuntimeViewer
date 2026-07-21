import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public class SidebarRuntimeObjectViewModel: ViewModel<SidebarRuntimeObjectRoute> {
    public let imageNode: RuntimeImageNode
    public let imagePath: String
    public let imageName: String
    public let runtimeEngine: RuntimeEngine

    var isSorted: Bool {
        false
    }

    @Observed public private(set) var loadState: RuntimeImageLoadState = .unknown
    @Observed public private(set) var searchString: String = ""
    @Observed public private(set) var nodes: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var filteredNodes: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFiltering: Bool = false
    @Observed public private(set) var isSearchCaseInsensitive: Bool = false
    @Observed public private(set) var loadingProgress: Double = 0
    @Observed public private(set) var loadingDescription: String = ""
    @Observed public private(set) var loadingItemCount: String = ""
    @Observed public private(set) var scope: RuntimeObjectScope = .init()

    /// Distinct kinds that actually appear in the current image (top-level
    /// nodes and every descendant). The scope popover uses this to skip
    /// drawing checkboxes for kinds nothing in the image carries, so the UI
    /// adapts per image rather than always listing the full universe of
    /// `RuntimeObjectKind`s. Recomputed on demand — cheap because nodes are
    /// only walked at popover-open time and the tree is shallow.
    @MainActor
    public var availableKinds: Set<RuntimeObjectKind> {
        var collected: Set<RuntimeObjectKind> = []
        func visit(_ runtimeObject: RuntimeObject) {
            collected.insert(runtimeObject.kind)
            for child in runtimeObject.children {
                visit(child)
            }
        }
        for cellViewModel in nodes {
            // `materializedRuntimeObject()` rebuilds the runtime object
            // tree from the cell viewmodel's `_children`, picking up
            // specialized descendants that were spliced in after the
            // initial reload (when the parent's stored `runtimeObject`
            // might be stale relative to the cell tree).
            visit(cellViewModel.materializedRuntimeObject())
        }
        return collected
    }

    /// Union of `RuntimeObject.Properties` bits observed across every node
    /// in the current image. The popover hides property rows for bits that
    /// never occur, since toggling them would only further restrict an
    /// already-empty result.
    @MainActor
    public var availableProperties: RuntimeObject.Properties {
        var collected: RuntimeObject.Properties = []
        func visit(_ runtimeObject: RuntimeObject) {
            collected.formUnion(runtimeObject.properties)
            for child in runtimeObject.children {
                visit(child)
            }
        }
        for cellViewModel in nodes {
            visit(cellViewModel.materializedRuntimeObject())
        }
        return collected
    }

    /// Fires after a specialized child is spliced into a parent cell
    /// viewmodel so the outline view re-queries its children. `outlineView.rx.nodes`
    /// uses DifferenceKit, which can not detect mutation of a reference-typed
    /// `SidebarRuntimeObjectCellViewModel` (the same instance lives in both the
    /// pre/post array snapshots, so `isContentEqual` always returns true and the
    /// inserted child stays invisible). Mirrors the equivalent
    /// `reloadRow` signal in `SpecializationViewModel`.
    private let reloadRowRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()

    /// Currently-running reload task. `scheduleReload` cancels this before
    /// starting a new one, so trigger sources that fire concurrently (init,
    /// `.fullReload` broadcasts, bookmark mutations) never end up with two
    /// `reloadData()` invocations racing to write `loadState` / `nodes` /
    /// `filteredNodes`. `nil` whenever no reload is in flight.
    private var currentReloadTask: Task<Void, Never>?

    /// Monotonic token so each scheduled reload can recognize whether it is
    /// still the most recent one when it finishes (to decide whether to
    /// clear `currentReloadTask` or leave the successor in place).
    private var currentReloadGeneration: Int = 0

    public init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        let imagePath = imageNode.path
        self.runtimeEngine = documentState.runtimeEngine
        self.imageNode = imageNode
        self.imagePath = imagePath
        self.imageName = imageNode.name
        super.init(documentState: documentState, router: router)

        runtimeEngine.dataChangePublisher
            .asObservable()
            .subscribeOnNext { [weak self] change in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch change {
                    case .fullReload:
                        // Skip if a reload is already in-flight on this
                        // image. Concrete scenario: the user double-clicks
                        // into an image that the background indexer was
                        // already processing. The init reload (kicked off
                        // synchronously below) and the batch-completion
                        // broadcast (delivered when the background batch
                        // wraps up) would otherwise both run `reloadData`,
                        // and whichever finished second would clobber the
                        // first one's `nodes` / `filteredNodes` / `loadState`
                        // with a freshly-allocated batch of cell viewmodels,
                        // wiping the user's selection and flashing the
                        // loading UI. The in-flight reload already reads
                        // from the same section factory cache the
                        // background pass populated, so dropping this
                        // broadcast is information-preserving.
                        guard self.currentReloadTask == nil else { return }
                        self.scheduleReload()
                    case .specializationAdded(let parent, let child):
                        guard parent.imagePath == self.imagePath else { return }
                        self.applySpecializationAdded(parent: parent, child: child)
                    }
                }
            }
            .disposed(by: rx.disposeBag)

        scheduleReload()
    }

    /// Single entry point for kicking off a reload. Cancels the currently
    /// running task before launching a new one, then bumps the generation
    /// counter so cancelled tasks can detect that they have been superseded
    /// and bail out before publishing partial results to the UI.
    func scheduleReload() {
        currentReloadTask?.cancel()
        currentReloadGeneration &+= 1
        let myGeneration = currentReloadGeneration
        currentReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reloadData()
            } catch is CancellationError {
                // Superseded by a newer reload — leave UI publishing to
                // the winner.
            } catch {
                self.loadState = .loadError(error)
                #log(.error, "\(error)")
            }
            if self.currentReloadGeneration == myGeneration {
                self.currentReloadTask = nil
            }
        }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<SidebarRuntimeObjectCellViewModel>
        /// Row context menu "Open in New Tab" (macOS only — UIKit callers
        /// pass `.empty()`).
        public let runtimeObjectOpenedInNewTab: Signal<SidebarRuntimeObjectCellViewModel>
        public let loadImageClicked: Signal<Void>
        public let searchString: Driver<String>
        public let isSearchCaseInsensitive: Driver<Bool>
    }

    public struct Output {
        public let runtimeObjects: Driver<[SidebarRuntimeObjectCellViewModel]>
        /// Same objects as `runtimeObjects`, grouped into kind sections. The
        /// sectioned sidebar (AppKit outline / UIKit collection view) binds this
        /// instead of the flat `runtimeObjects`; the flat form is still used by
        /// platforms / views that present a single layer (Open Quickly, iOS).
        public let runtimeObjectSections: Driver<[SidebarRuntimeObjectSection]>
        public let loadState: Driver<RuntimeImageLoadState>
        public let notLoadedText: Driver<String>
        public let errorText: Driver<String>
        public let emptyText: Driver<String>
        public let isEmpty: Driver<Bool>
        public let loadingProgress: Driver<Double>
        public let loadingDescription: Driver<String>
        public let loadingItemCount: Driver<String>
        public let didBeginFiltering: Signal<Void>
        public let didChangeFiltering: Signal<Void>
        public let didEndFiltering: Signal<Void>
        public let reloadRow: Signal<SidebarRuntimeObjectCellViewModel>
    }

    @MainActor
    public func transform(_ input: Input) -> Output {
//        input.isSearchCaseInsensitive.drive($isSearchCaseInsensitive).disposed(by: rx.disposeBag)

        Driver.combineLatest(input.searchString, input.isSearchCaseInsensitive)
            .flatMapLatest { searchString, isSearchCaseInsensitive -> Driver<(String, Bool)> in
                if searchString.isEmpty {
                    return .just((searchString, isSearchCaseInsensitive))
                } else {
                    return .just((searchString, isSearchCaseInsensitive))
                        .debounce(.milliseconds(500))
                }
            }
            .driveOnNextMainActor { [weak self] searchString, isSearchCaseInsensitive in
                guard let self else { return }
                guard (self.searchString != searchString) || (self.isSearchCaseInsensitive != isSearchCaseInsensitive) else { return }

                self.searchString = searchString
                self.isSearchCaseInsensitive = isSearchCaseInsensitive
                rebuildFilteredNodes()
            }
            .disposed(by: rx.disposeBag)

        $scope
            .asDriver()
            .skip(1) // initial value already covered by `nodes` reload
            .driveOnNextMainActor { [weak self] _ in
                guard let self else { return }
                rebuildFilteredNodes()
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectClicked
            .emitOnNextMainActor { [weak self] viewModel in
                guard let self else { return }
                #if os(macOS)
                documentState.selectionRouter.trigger(.push(viewModel.runtimeObject))
                #else
                self.router.trigger(.selectedObject(viewModel.runtimeObject))
                #endif
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectOpenedInNewTab
            .emitOnNextMainActor { [weak self] viewModel in
                guard let self else { return }
                #if os(macOS)
                documentState.selectionRouter.trigger(.openInNewTab(viewModel.runtimeObject))
                #endif
            }
            .disposed(by: rx.disposeBag)

        input.loadImageClicked.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            tryLoadImage()
        }
        .disposed(by: rx.disposeBag)

        let errorText = $loadState
            .capture(case: RuntimeImageLoadState.loadError).map { [weak self] error in
                guard let self else { return "" }
                if let dyldOpenError = error as? DyldOpenError, let message = dyldOpenError.message {
                    return message
                } else {
                    return "An unknown error occured trying to load '\(imagePath)'"
                }
            }
            .asDriver(onErrorJustReturn: "")

        let distinctLoadState = $loadState.asObservable()
            .distinctUntilChanged()
            .flatMapLatest { state -> Observable<RuntimeImageLoadState> in
                switch state {
                case .loading:
                    return Observable.just(state)
                        .delay(.milliseconds(500), scheduler: MainScheduler.instance)
                default:
                    return Observable.just(state)
                }
            }
            .asDriver(onErrorDriveWith: .empty())

        return Output(
            runtimeObjects: $filteredNodes.asDriver(),
            runtimeObjectSections: $filteredNodes.asDriver().map { Self.makeSections(from: $0) },
            loadState: distinctLoadState,
            notLoadedText: .just("\(imageName) is not yet loaded"),
            errorText: errorText,
            emptyText: .just("\(imageName) is loaded however does not appear to contain any classes or protocols"),
            isEmpty: $nodes.asDriver().map { $0.isEmpty },
            loadingProgress: $loadingProgress.asDriver(),
            loadingDescription: $loadingDescription.asDriver(),
            loadingItemCount: $loadingItemCount.asDriver(),
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: $filteredNodes.asSignal(onErrorJustReturn: []).withLatestFrom($isFiltering.asSignal(onErrorJustReturn: false)).filter { $0 }.mapToVoid(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid(),
            reloadRow: reloadRowRelay.asSignal()
        )
    }

    /// Groups a flat list of cell viewmodels into kind sections, sorted by
    /// `RuntimeObjectKind` (which is `Comparable`). Encounter order is preserved
    /// within each section, so when the input is already sorted (the runtime
    /// object list sets `isSorted`), each section's objects stay name-sorted.
    /// Only kinds that actually occur produce a section, so empty sections never
    /// appear.
    static func makeSections(from nodes: [SidebarRuntimeObjectCellViewModel]) -> [SidebarRuntimeObjectSection] {
        var orderedKinds: [RuntimeObjectKind] = []
        var objectsByKind: [RuntimeObjectKind: [SidebarRuntimeObjectCellViewModel]] = [:]
        for node in nodes {
            let kind = node.runtimeObject.kind
            if objectsByKind[kind] == nil {
                orderedKinds.append(kind)
            }
            objectsByKind[kind, default: []].append(node)
        }
        return orderedKinds
            .sorted()
            .map { SidebarRuntimeObjectSection(kind: $0, objects: objectsByKind[$0] ?? []) }
    }

    func reloadData() async throws {
        // `MainActor.run` blocks are not natural cancellation points (they
        // run synchronously once they reach the main actor), so explicit
        // checks fence each UI write — a task that has been cancelled by
        // `scheduleReload` must throw before publishing partial results
        // that the successor task would otherwise re-publish on top of.
        try Task.checkCancellation()
        let imageLoadState: RuntimeImageLoadState = try await runtimeEngine.isImageLoaded(path: imagePath) ? .loaded : .notLoaded

        if case .notLoaded = imageLoadState {
            try Task.checkCancellation()
            await MainActor.run {
                self.loadState = .notLoaded
            }
            return
        }

        try Task.checkCancellation()
        await MainActor.run {
            self.loadState = .loading
            self.loadingProgress = 0
            self.loadingDescription = "Preparing..."
            self.loadingItemCount = ""
        }

        var runtimeObjects: [RuntimeObject] = []
        for try await event in buildRuntimeObjectsStream() {
            try Task.checkCancellation()
            switch event {
            case .progress(let progress):
                await MainActor.run {
                    self.loadingProgress = progress.overallFraction
                    self.loadingDescription = progress.phase.displayDescription
                    if progress.totalCount > 0 {
                        self.loadingItemCount = "\(progress.currentCount)/\(progress.totalCount)"
                    } else {
                        self.loadingItemCount = ""
                    }
                }
            case .completed(let result):
                runtimeObjects = result
            }
        }

        try Task.checkCancellation()
        await MainActor.run {
            self.loadingProgress = 0.95
            self.loadingDescription = "Building list..."
            self.loadingItemCount = "\(runtimeObjects.count) objects"
        }

        try Task.checkCancellation()
        await MainActor.run {
            self.loadState = .loaded
            self.loadingProgress = 1.0
            self.searchString = ""
            if isSorted {
                self.nodes = runtimeObjects.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
            } else {
                self.nodes = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
            }
            rebuildFilteredNodes()
        }
    }

    /// Apply the scope pre-filter and then the text filter, publishing the
    /// result to `filteredNodes`. Centralized so every call site (initial
    /// load, search-string change, scope change, specialization splice) hits
    /// the same ordering.
    ///
    /// Three passes:
    /// 1. Push the active scope into every cell in the tree so each cell's
    ///    `_filteredChildren` excludes children that fail the scope. The
    ///    cell-level scope filter is what keeps a node's expansion clean —
    ///    without it, a parent that passes via `matchesScopeRecursively`
    ///    would still show every sibling under it, including those that
    ///    fail the scope.
    /// 2. Filter the top-level `nodes` array by `matchesScopeRecursively`
    ///    so parents whose hits live only in descendants are still
    ///    surfaced.
    /// 3. Run the text filter via `FilterEngine.filter`. Always invoked —
    ///    even with an empty search string — because it cascades the
    ///    `filter` value through child cells and clears stale
    ///    `filterResult` highlighting from a previous search.
    @MainActor
    private func rebuildFilteredNodes() {
        let scope = scope

        // Drive `isFiltering` off the union of text + scope. This flag
        // controls the outline view's beginFiltering / endFiltering
        // auto-expand path, so scoping (without a text query) still
        // surfaces matching descendants automatically. Must be set
        // *before* `filteredNodes` is reassigned so `didChangeFiltering`
        // (`withLatestFrom($isFiltering)`) sees the new value.
        let shouldFilter = !searchString.isEmpty || scope.isActive
        if shouldFilter != isFiltering {
            isFiltering = shouldFilter
        }

        // Pass 1: cascade scope into every cell so deeper levels rebuild
        // their `_filteredChildren` before the top-level filter reads them.
        for cell in nodes {
            cell.applyScopeRecursively(scope)
        }

        // Pass 2: prune top-level by matchesScopeRecursively (a parent
        // survives if itself or any descendant passes the scope).
        let scoped: [SidebarRuntimeObjectCellViewModel]
        if scope.isActive {
            scoped = nodes.filter { $0.matchesScopeRecursively(scope) }
        } else {
            scoped = nodes
        }

        // Pass 3: text filter — FilterEngine handles an empty search by
        // clearing every item's `filterResult` and cascading the empty
        // filter through child cells.
        filteredNodes = FilterEngine.filter(
            searchString,
            items: scoped,
            mode: appDefaults.filterMode,
            isCaseInsensitive: isSearchCaseInsensitive
        )
    }

    /// Splice a newly specialized child into the existing sidebar tree without
    /// rebuilding it from scratch. Locates `parent`'s cell viewmodel under
    /// `nodes`, swaps its `runtimeObject` for a copy carrying the new child,
    /// and re-emits `nodes` / `filteredNodes` so subscribers (the outline
    /// view's `rx.nodes` adapter) pick up the structural change via nested
    /// diff.
    @MainActor
    private func applySpecializationAdded(parent: RuntimeObject, child: RuntimeObject) {
        guard let parentViewModel = locate(parent, in: nodes) else { return }

        // Append onto a materialized copy of the cell's *current* subtree, not
        // the event payload or the parent RuntimeObject's stale `children`
        // snapshot. A descendant may already have received a specialization
        // through its own cell viewmodel; rebuilding this parent from the stale
        // snapshot would drop that descendant child.
        guard parentViewModel.appendRuntimeObjectChildPreservingCurrentDescendants(child) else {
            return
        }
        nodes = nodes
        rebuildFilteredNodes()
        // `nodes`/`filteredNodes` re-emissions above are no-ops for the
        // outline view (same `SidebarRuntimeObjectCellViewModel` instance in
        // both snapshots → DifferenceKit's `isContentEqual` always true →
        // adapter skips). Drive the visual update off this explicit signal so
        // the VC can call `reloadItem(_:reloadChildren:)` on the mutated
        // parent and surface the new child.
        reloadRowRelay.accept(parentViewModel)
    }

    /// Depth-first search through the cell viewmodel tree for the cell
    /// wrapping `object`. Walks `viewModel.children` (i.e. the filtered
    /// view); the `parent` of a successful specialize is always currently
    /// visible in the sidebar so the lookup is safe even when a filter is
    /// active.
    private func locate(
        _ object: RuntimeObject,
        in viewModels: [SidebarRuntimeObjectCellViewModel]
    ) -> SidebarRuntimeObjectCellViewModel? {
        for viewModel in viewModels {
            if viewModel.runtimeObject.key == object.key { return viewModel }
            if let matchedViewModel = locate(object, in: viewModel.children) {
                return matchedViewModel
            }
        }
        return nil
    }

    func buildRuntimeObjects() async throws -> [RuntimeObject] {
        []
    }

    func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let objects = try await self.buildRuntimeObjects()
                    continuation.yield(.completed(objects))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func tryLoadImage() {
        Task { @MainActor in
            do {
                loadState = .loading
                try await runtimeEngine.loadImage(at: imagePath)
                loadState = .loaded

            } catch {
                loadState = .loadError(error)
            }
        }
    }
}

extension RuntimeImageLoadState: @retroactive Equatable {
    public static func == (lhs: RuntimeViewerCore.RuntimeImageLoadState, rhs: RuntimeViewerCore.RuntimeImageLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown): return true
        case (.loaded, .loaded): return true
        case (.loading, .loading): return true
        case (.notLoaded, .notLoaded): return true
        case (.loadError, .loadError): return true
        default: return false
        }
    }
}

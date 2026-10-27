import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerArchitectures
import RuntimeViewerUI
import MemberwiseInit
#if canImport(RuntimeViewerSettings)
import RuntimeViewerSettings
#endif

/// The Report navigator page: the background indexer's batches, the Find navigator's corpus
/// builds and the cross references prepared ahead of its queries, as Xcode's Report navigator
/// lists builds and runs — one outline, each kind of work a first-level row, the newest work
/// first, a spinner on whatever is still running.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both read the
/// `RuntimeBackgroundIndexingCoordinator`, `FindCorpusCoordinator` and
/// `CrossReferencePreparationCoordinator` of the engine the document is on, so the two pages
/// always agree — and so does every window on that engine, since the engine's documents share them
/// (`RuntimeEngineBackgroundWork`). Only windows on different engines show different Reports.
public final class ReportViewModel<Route: Routable>: ViewModel<Route> {
    @MemberwiseInit(.public)
    public struct Input {
        /// Whether the page is on screen. A page nobody sees builds no tree; coming on screen
        /// builds it from the latest of every input and asks for the corpus states again — the
        /// store evicts without telling anyone. Off until it reports otherwise.
        public let isVisible: Driver<Bool>
        public let cancel: Signal<ReportNode>
        public let cancelAll: Signal<Void>
        public let clearHistory: Signal<Void>
        public let openSettings: Signal<Void>
        /// A row double-clicked. A feature's "Turned off in Settings" row opens Settings, where it
        /// is turned back on; the other rows open nothing.
        public let doubleClickedNode: Signal<ReportNode>
        /// The filter bar's content: rows whose title satisfies every term of it, with their
        /// ancestors. Need not start with a value — until it reports one the outline is unfiltered.
        public let filter: Driver<NavigatorTextFilter>
        /// The filter bar's clock toggle: only the work in progress. Off until it reports otherwise.
        public let showsOnlyInProgress: Driver<Bool>
    }

    public struct Output {
        public let nodes: Driver<[ReportNode]>
        /// Rows to open once the outline shows `nodes`: each kind of work, and each batch still
        /// running with images under it, the first time it appears. Nothing is opened or closed
        /// after that, and nothing while the filter bar narrows the outline.
        public let nodesToExpand: Driver<[ReportNode]>
        /// The filter bar starts (`true`) or stops narrowing the outline. Sent before the narrowed
        /// tree, so the outline knows which reload opens every row and which puts the user's own
        /// expansion back.
        public let filteringChanged: Signal<Bool>
        /// Nothing at all to report — no batch, no build, no feature turned off.
        public let isEmpty: Driver<Bool>
        /// Some row can be withdrawn from this page, so Cancel All has something to cancel. A
        /// corpus build another connection to the engine's process asked for is in progress, but
        /// not this page's to cancel.
        public let hasCancellableWork: Driver<Bool>
        public let hasHistory: Driver<Bool>
    }

    /// Builds the tree one kind of work at a time, keeping cell ViewModels and finished rows.
    private let treeBuilder = ReportTreeBuilder()

    @RxObserved
    private var allNodes: [ReportNode] = []

    @RxObserved
    private var isIndexingEnabled: Bool = true

    @RxObserved
    private var isCorpusEnabled: Bool = true

    @RxObserved
    private var isCrossReferencePreparationEnabled: Bool = true

    /// The filter bar's content and clock toggle as last reported, kept here instead of being
    /// combined straight from the input: the filter field reports only what the user does with it,
    /// so an untouched field says nothing at all, and an outline waiting on it stays empty.
    @RxObserved
    private var filter: NavigatorTextFilter = .empty

    @RxObserved
    private var showsOnlyInProgress: Bool = false

    /// Every row `ReportOutline.nodesToExpand(in:seenIdentifiers:)` has seen on this page.
    private var seenNodeIdentifiers: Set<ReportNodeIdentifier> = []

    private let filteringChangedRelay = PublishRelay<Bool>()

    public override init(documentState: DocumentState, router: any Router<Route>) {
        super.init(documentState: documentState, router: router)
        bootstrapSettingsObservation()
    }

    public func transform(_ input: Input) -> Output {
        let documentState = documentState
        let treeBuilder = treeBuilder
        let isIndexingEnabled = $isIndexingEnabled.asObservable()
        let isCorpusEnabled = $isCorpusEnabled.asObservable()
        let isCrossReferencePreparationEnabled = $isCrossReferencePreparationEnabled.asObservable()
        let isVisible = input.isVisible.asObservable().distinctUntilChanged()
        // The coordinators of the engine's work the document holds, again with every session it
        // puts in place — starting its background work, moving to another engine — and `nil`
        // while it holds none: the page then shows an empty Report.
        let coordinators = documentState.$runtimeEngineSession.asObservable()
            .map { runtimeEngineSession in
                MainActor.assumeIsolated {
                    runtimeEngineSession.backgroundWork.map { backgroundWork in
                        (
                            indexing: backgroundWork.indexingCoordinator,
                            corpus: backgroundWork.corpusCoordinator,
                            crossReferences: backgroundWork.crossReferencePreparationCoordinator
                        )
                    }
                }
            }
            .share(replay: 1)

        Observable.combineLatest(isVisible, coordinators)
            .flatMapLatest { isVisible, coordinators -> Observable<[ReportNode]> in
                // A page nobody sees builds nothing. Coming on screen replays the latest of every
                // input, so the tree is current before the page is drawn.
                guard isVisible else { return .empty() }
                guard let coordinators else { return .just([]) }
                let indexingCoordinator = coordinators.indexing
                let corpusCoordinator = coordinators.corpus
                // Each kind is rebuilt from its own inputs only: a corpus build's progress leaves
                // the indexing rows alone.
                let indexingCategory = Observable.combineLatest(
                    indexingCoordinator.batchesObservable,
                    indexingCoordinator.historyObservable,
                    isIndexingEnabled
                )
                .observe(on: MainScheduler.instance)
                .map { batches, history, isIndexingEnabled in
                    MainActor.assumeIsolated {
                        treeBuilder.indexingCategory(batches: batches, history: history, isEnabled: isIndexingEnabled)
                    }
                }
                let corpusCategory = Observable.combineLatest(
                    corpusCoordinator.$buildStatesByImagePath.asObservable(),
                    corpusCoordinator.$followedImagePaths.asObservable(),
                    corpusCoordinator.$finishedBuilds.asObservable(),
                    corpusCoordinator.$restoredImagesByImagePath.asObservable(),
                    corpusCoordinator.$isCorpusUnsupportedByEngine.asObservable(),
                    isCorpusEnabled
                )
                .observe(on: MainScheduler.instance)
                .map { states, followedImagePaths, finishedBuilds, restoredImages, isCorpusUnsupportedByEngine, isCorpusEnabled in
                    MainActor.assumeIsolated {
                        treeBuilder.corpusCategory(
                            states: states,
                            followedImagePaths: followedImagePaths,
                            finishedBuilds: finishedBuilds,
                            restoredImages: restoredImages,
                            isUnsupportedByEngine: isCorpusUnsupportedByEngine,
                            isEnabled: isCorpusEnabled
                        )
                    }
                }
                let crossReferencePreparationCoordinator = coordinators.crossReferences
                let crossReferenceCategory = Observable.combineLatest(
                    crossReferencePreparationCoordinator.$preparationStatesByImagePath.asObservable(),
                    crossReferencePreparationCoordinator.$followedImagePaths.asObservable(),
                    crossReferencePreparationCoordinator.$finishedPreparations.asObservable(),
                    crossReferencePreparationCoordinator.$isUnsupportedByEngine.asObservable(),
                    isCrossReferencePreparationEnabled
                )
                .observe(on: MainScheduler.instance)
                .map { states, followedImagePaths, finishedPreparations, isUnsupportedByEngine, isEnabled in
                    MainActor.assumeIsolated {
                        treeBuilder.crossReferenceCategory(
                            states: states,
                            followedImagePaths: followedImagePaths,
                            finishedPreparations: finishedPreparations,
                            isUnsupportedByEngine: isUnsupportedByEngine,
                            isEnabled: isEnabled
                        )
                    }
                }
                return Observable.combineLatest(indexingCategory, corpusCategory, crossReferenceCategory) { indexingCategory, corpusCategory, crossReferenceCategory in
                    [indexingCategory, corpusCategory, crossReferenceCategory].compactMap { $0 }
                }
            }
            .bind(to: $allNodes)
            .disposed(by: rx.disposeBag)

        Observable.combineLatest(isVisible, coordinators)
            .filter { isVisible, _ in isVisible }
            .subscribeOnNext { _, coordinators in
                MainActor.assumeIsolated {
                    coordinators?.corpus.refreshCoverage()
                }
            }
            .disposed(by: rx.disposeBag)

        // The commands go to the coordinators of the engine's work, so every window on the engine
        // sees them; a document holding none has nothing to command.
        input.cancel.emitOnNext { node in
            guard let backgroundWork = documentState.runtimeEngineSession.backgroundWork else { return }
            switch node.identifier {
            case .indexingBatch(let batchID):
                backgroundWork.indexingCoordinator.cancelBatch(batchID)
            case .corpusBuild(let imagePath):
                backgroundWork.corpusCoordinator.cancelBuild(of: imagePath)
            case .crossReferencePreparation(let imagePath):
                backgroundWork.crossReferencePreparationCoordinator.cancelPreparation(of: imagePath)
            case .category, .turnedOff, .unsupportedByEngine, .indexingItem, .finishedCorpusBuild, .restoredCorpora, .restoredCorpus, .finishedCrossReferencePreparation:
                break
            }
        }
        .disposed(by: rx.disposeBag)

        input.cancelAll.emitOnNext {
            guard let backgroundWork = documentState.runtimeEngineSession.backgroundWork else { return }
            backgroundWork.indexingCoordinator.cancelAllBatches()
            // What the engine's documents asked for; a build another connection asked for is not
            // this page's to stop.
            let corpusCoordinator = backgroundWork.corpusCoordinator
            for imagePath in corpusCoordinator.followedImagePaths {
                corpusCoordinator.cancelBuild(of: imagePath)
            }
            let crossReferencePreparationCoordinator = backgroundWork.crossReferencePreparationCoordinator
            for imagePath in crossReferencePreparationCoordinator.followedImagePaths {
                crossReferencePreparationCoordinator.cancelPreparation(of: imagePath)
            }
        }
        .disposed(by: rx.disposeBag)

        input.clearHistory.emitOnNext {
            guard let backgroundWork = documentState.runtimeEngineSession.backgroundWork else { return }
            backgroundWork.indexingCoordinator.clearHistory()
            backgroundWork.corpusCoordinator.clearFinishedBuilds()
            backgroundWork.crossReferencePreparationCoordinator.clearFinishedPreparations()
        }
        .disposed(by: rx.disposeBag)

        // `appRouter` and the Settings window it opens exist on macOS only; elsewhere nothing
        // sends `openSettings`.
        #if os(macOS)
        // Resolved when the item is chosen, not while the page is bound.
        input.openSettings.emitOnNext { [weak self] in
            guard let self else { return }
            appRouter.trigger(.settings)
        }
        .disposed(by: rx.disposeBag)

        input.doubleClickedNode.emitOnNext { [weak self] node in
            guard let self, case .turnedOff = node.identifier else { return }
            appRouter.trigger(.settings)
        }
        .disposed(by: rx.disposeBag)
        #endif

        input.filter.driveOnNext { [weak self] filter in
            guard let self else { return }
            announceFilteringChange(filter: filter, showsOnlyInProgress: showsOnlyInProgress)
            self.filter = filter
        }
        .disposed(by: rx.disposeBag)

        input.showsOnlyInProgress.driveOnNext { [weak self] showsOnlyInProgress in
            guard let self else { return }
            announceFilteringChange(filter: filter, showsOnlyInProgress: showsOnlyInProgress)
            self.showsOnlyInProgress = showsOnlyInProgress
        }
        .disposed(by: rx.disposeBag)

        let filteredOutline = Driver.combineLatest($allNodes.asDriver(), $filter.asDriver(), $showsOnlyInProgress.asDriver()) { nodes, filter, showsOnlyInProgress in
            (
                nodes: ReportOutline.filtered(nodes, by: filter, showsOnlyInProgress: showsOnlyInProgress),
                isFiltering: ReportOutline.isFiltering(filter: filter, showsOnlyInProgress: showsOnlyInProgress)
            )
        }
        let nodes = filteredOutline.map(\.nodes)
        // While the filter bar narrows the outline every row is open, and the rows seen meanwhile
        // get their first sight once it stops, against the user's own expansion.
        let nodesToExpand = filteredOutline.map { [weak self] filteredOutline -> [ReportNode] in
            guard let self, !filteredOutline.isFiltering else { return [] }
            return ReportOutline.nodesToExpand(in: filteredOutline.nodes, seenIdentifiers: &seenNodeIdentifiers)
        }

        return Output(
            nodes: nodes,
            nodesToExpand: nodesToExpand,
            filteringChanged: filteringChangedRelay.asSignal(),
            isEmpty: $allNodes.asDriver().map(\.isEmpty).distinctUntilChanged(),
            hasCancellableWork: $allNodes.asDriver().map { nodes in nodes.contains(where: ReportOutline.isCancellable) }.distinctUntilChanged(),
            hasHistory: coordinators
                .flatMapLatest { coordinators -> Observable<Bool> in
                    guard let coordinators else { return .just(false) }
                    return Observable.combineLatest(
                        coordinators.indexing.historyObservable,
                        coordinators.corpus.$finishedBuilds.asObservable(),
                        coordinators.corpus.$restoredImagesByImagePath.asObservable(),
                        coordinators.crossReferences.$finishedPreparations.asObservable()
                    ) { history, finishedBuilds, restoredImages, finishedPreparations in
                        !history.isEmpty || !finishedBuilds.isEmpty || !restoredImages.isEmpty || !finishedPreparations.isEmpty
                    }
                }
                .asDriver(onErrorJustReturn: false)
                .distinctUntilChanged()
        )
    }

    /// Tells the page the filter bar starts or stops narrowing the outline, before the narrowed
    /// tree reaches it.
    private func announceFilteringChange(filter newFilter: NavigatorTextFilter, showsOnlyInProgress newShowsOnlyInProgress: Bool) {
        let wasFiltering = ReportOutline.isFiltering(filter: filter, showsOnlyInProgress: showsOnlyInProgress)
        let isFiltering = ReportOutline.isFiltering(filter: newFilter, showsOnlyInProgress: newShowsOnlyInProgress)
        if isFiltering != wasFiltering {
            filteringChangedRelay.accept(isFiltering)
        }
    }

    // MARK: - Settings

    /// The switches the outline shows a "Turned off in Settings" row for.
    private struct FeatureSwitches: Equatable {
        let isIndexingEnabled: Bool
        let isCorpusEnabled: Bool
        let isCrossReferencePreparationEnabled: Bool
    }

    /// Follows the switches for as long as the page lives: the first value arrives while
    /// subscribing, every change after it on the main queue.
    private func bootstrapSettingsObservation() {
        #if canImport(RuntimeViewerSettings)
        // Resolved once: `Observable.tracking` re-arms on a main-queue hop where the dependency
        // context is gone. This is `ViewModel`'s own `settings`, resolved by `super.init`.
        let trackedSettings = settings
        Observable<FeatureSwitches>
            .tracking {
                // Main-actor state read from `tracking`'s synchronous first access, as
                // `ContentTextViewModel` reads the transformer.
                MainActor.assumeIsolated {
                    FeatureSwitches(
                        isIndexingEnabled: trackedSettings.indexing.isEnabled,
                        isCorpusEnabled: trackedSettings.search.isCorpusEnabled,
                        isCrossReferencePreparationEnabled: trackedSettings.search.isCrossReferencePreparationEnabled
                    )
                }
            }
            .distinctUntilChanged()
            .subscribeOnNext { [weak self] featureSwitches in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if self.isIndexingEnabled != featureSwitches.isIndexingEnabled {
                        self.isIndexingEnabled = featureSwitches.isIndexingEnabled
                    }
                    if self.isCorpusEnabled != featureSwitches.isCorpusEnabled {
                        self.isCorpusEnabled = featureSwitches.isCorpusEnabled
                    }
                    if self.isCrossReferencePreparationEnabled != featureSwitches.isCrossReferencePreparationEnabled {
                        self.isCrossReferencePreparationEnabled = featureSwitches.isCrossReferencePreparationEnabled
                    }
                }
            }
            .disposed(by: rx.disposeBag)
        #endif
    }
}

/// How the Report navigator's rows read and how its filter bar narrows them — kept apart from the
/// generic `ReportViewModel`, which can hold no static stored values, and tested on its own.
enum ReportOutline {
    /// Whether a batch shows a row per image. An Always Index entry names one image, so a batch of
    /// one shows none: the batch's own row stands for the image.
    static func showsItems(of batch: RuntimeIndexingBatch) -> Bool {
        !(batch.reason.category == .alwaysIndex && batch.items.count <= 1)
    }

    static func configure(_ cellViewModel: ReportCellViewModel, for batch: RuntimeIndexingBatch) {
        // The batch's row stands for its only image, which has no row of its own to say why it
        // failed — what the toolbar popover showed as `path — message`.
        if !showsItems(of: batch), batch.isFinished, let item = batch.items.first, case .failed(let message) = item.state {
            cellViewModel.update(icon: indexingIcon, title: title(for: batch.reason), detail: "Failed", status: .failed(message: message), toolTip: "\(item.id)\n\(message)")
            return
        }
        let isRunning = !batch.isFinished
        var detail: String
        if isRunning {
            detail = "\(batch.finishedCount) of \(batch.totalCount)"
        } else if batch.isCancelled {
            detail = "Cancelled"
        } else {
            detail = "\(batch.totalCount) \(batch.totalCount == 1 ? "image" : "images")"
        }
        if batch.failedCount > 0 {
            detail += " · \(batch.failedCount) failed"
        }
        let status: ReportRowStatus = if isRunning {
            .running
        } else if batch.failedCount > 0 {
            .failed(message: "\(batch.failedCount) of \(batch.totalCount) images failed to index")
        } else {
            .none
        }
        cellViewModel.update(
            icon: indexingIcon,
            title: title(for: batch.reason),
            detail: detail,
            status: status,
            toolTip: batch.rootImagePath,
            isCancellable: isRunning,
            isInProgress: isRunning
        )
    }

    static func configure(_ cellViewModel: ReportCellViewModel, for item: RuntimeIndexingTaskItem) {
        let detail: String
        let status: ReportRowStatus
        switch item.state {
        case .pending:
            detail = item.hasPriorityBoost ? "Next" : "Waiting"
            status = .none
        case .running:
            detail = ""
            status = .running
        case .completed:
            detail = ""
            status = .none
        case .failed(let message):
            detail = "Failed"
            status = .failed(message: message)
        case .cancelled:
            detail = "Cancelled"
            status = .none
        }
        cellViewModel.update(icon: icon(forImagePath: item.id), title: FindScope.imageName(of: item.id), detail: detail, status: status, toolTip: item.id, isInProgress: !item.state.isTerminal)
    }

    /// `isFollowed`: the engine's corpus coordinator asked for the build — for whichever window on
    /// the engine — so its progress reaches the row and Cancel withdraws it. Any other build is the
    /// engine's last snapshot of it, for another connection to the engine's process that this page
    /// cannot speak for: its numbers would sit still, and Cancel would do nothing.
    static func configure(_ cellViewModel: ReportCellViewModel, forCorpusOf imagePath: String, state: RuntimeInterfaceCorpusBuildState, isFollowed: Bool) {
        let detail: String
        let status: ReportRowStatus
        switch state {
        case .building(let progress):
            if isFollowed {
                detail = progress.total > 0 ? "\(progress.built * 100 / progress.total)% · \(progress.built) of \(progress.total)" : "Starting"
            } else {
                detail = "Building"
            }
            status = .running
        case .pending, .built, .failed:
            detail = "Waiting"
            status = .none
        }
        let toolTip = isFollowed ? imagePath : "\(imagePath)\nRequested by another connection"
        cellViewModel.update(icon: icon(forImagePath: imagePath), title: FindScope.imageName(of: imagePath), detail: detail, status: status, toolTip: toolTip, isCancellable: isFollowed, isInProgress: true)
    }

    /// The Searchable Interfaces category's one row while the engine's process does not know the
    /// corpus commands — a RuntimeViewer older than them on the other end — instead of a failed
    /// build per image (PR121.37).
    static func configureUnsupportedCorpusRow(_ cellViewModel: ReportCellViewModel) {
        cellViewModel.update(
            icon: unsupportedIcon,
            title: "Not supported by this source",
            toolTip: "The RuntimeViewer this source runs is older than searchable interfaces. Update it there to search this source's images."
        )
    }

    static func configure(_ cellViewModel: ReportCellViewModel, for finishedBuild: FindCorpusFinishedBuild) {
        let time = finishedBuild.finishedAt.map(timeText) ?? ""
        let detail: String
        let status: ReportRowStatus
        var toolTip = finishedBuild.imagePath
        switch finishedBuild.outcome {
        case .built(let summary):
            detail = time
            status = .none
            toolTip += "\n\(summary.objectCount) objects, \(ByteCountFormatter.string(fromByteCount: Int64(summary.byteCount), countStyle: .memory))"
            if summary.skippedCount > 0 {
                toolTip += ", \(summary.skippedCount) skipped"
            }
        case .failed(let message):
            detail = time.isEmpty ? "Failed" : "Failed · \(time)"
            status = .failed(message: message)
        case .cancelled:
            detail = time.isEmpty ? "Cancelled" : "Cancelled · \(time)"
            status = .none
        }
        cellViewModel.update(icon: icon(forImagePath: finishedBuild.imagePath), title: FindScope.imageName(of: finishedBuild.imagePath), detail: detail, status: status, toolTip: toolTip)
    }

    /// The group of the corpora read from derived data instead of printed — at launch, the Always
    /// Index images, searchable before their batches index them.
    static func configureRestoredCorporaRow(_ cellViewModel: ReportCellViewModel, imageCount: Int) {
        cellViewModel.update(
            icon: restoredCorporaIcon,
            title: "Restored from Derived Data",
            detail: "\(imageCount) \(imageCount == 1 ? "image" : "images")",
            toolTip: "Read from the derived data kept for this system and this build of RuntimeViewer, instead of printed again"
        )
    }

    /// An image whose corpus was read from derived data: its size and what reading it took.
    static func configure(_ cellViewModel: ReportCellViewModel, forCorpusOf imagePath: String, restoredAs restoredImage: RuntimeInterfaceCorpusRestoredImage) {
        let byteCount = ByteCountFormatter.string(fromByteCount: Int64(restoredImage.summary.byteCount), countStyle: .memory)
        let duration = String(format: "%.2f s", restoredImage.duration)
        var toolTip = "\(imagePath)\n\(restoredImage.summary.objectCount) objects, \(byteCount), read in \(duration)"
        if restoredImage.summary.skippedCount > 0 {
            toolTip += "\n\(restoredImage.summary.skippedCount) skipped when it was printed"
        }
        cellViewModel.update(icon: icon(forImagePath: imagePath), title: FindScope.imageName(of: imagePath), detail: "\(byteCount) · \(duration)", toolTip: toolTip)
    }

    /// An image whose cross references are queued or being prepared. `isFollowed`: the engine's
    /// preparation coordinator asked for it, so Cancel withdraws it.
    static func configure(_ cellViewModel: ReportCellViewModel, forCrossReferencesOf imagePath: String, state: CrossReferencePreparationState, isFollowed: Bool) {
        let detail: String
        let status: ReportRowStatus
        switch state {
        case .preparing(let progress):
            if progress.isReadingNames {
                detail = "Reading names"
            } else if progress.functionCount > 0 {
                detail = "\(progress.scannedFunctionCount * 100 / progress.functionCount)% · \(progress.scannedFunctionCount) of \(progress.functionCount) functions"
            } else {
                detail = "Starting"
            }
            status = .running
        case .pending, .prepared, .failed:
            detail = "Waiting"
            status = .none
        }
        cellViewModel.update(icon: icon(forImagePath: imagePath), title: FindScope.imageName(of: imagePath), detail: detail, status: status, toolTip: imagePath, isCancellable: isFollowed, isInProgress: true)
    }

    /// The Cross References category's one row while the engine's process cannot prepare cross
    /// references — a RuntimeViewer older than the preparation on the other end. Queries still
    /// scan there.
    static func configureUnsupportedCrossReferenceRow(_ cellViewModel: ReportCellViewModel) {
        cellViewModel.update(
            icon: unsupportedIcon,
            title: "Not supported by this source",
            toolTip: "The RuntimeViewer this source runs is older than prepared cross references. Call Hierarchy and Type References scan its images on each query instead."
        )
    }

    static func configure(_ cellViewModel: ReportCellViewModel, for finishedPreparation: CrossReferenceFinishedPreparation) {
        let time = timeText(finishedPreparation.finishedAt)
        let detail: String
        let status: ReportRowStatus
        var toolTip = finishedPreparation.imagePath
        switch finishedPreparation.outcome {
        case .prepared(let preparation):
            detail = time
            status = .none
            toolTip += "\n\(preparation.referenceCount) references, \(ByteCountFormatter.string(fromByteCount: Int64(preparation.byteCount), countStyle: .memory))"
        case .failed(let message):
            detail = "Failed · \(time)"
            status = .failed(message: message)
        case .cancelled:
            detail = "Cancelled · \(time)"
            status = .none
        }
        cellViewModel.update(icon: icon(forImagePath: finishedPreparation.imagePath), title: FindScope.imageName(of: finishedPreparation.imagePath), detail: detail, status: status, toolTip: toolTip)
    }

    // MARK: - Filtering

    /// The filter bar: a row stays when its title satisfies every term of the filter
    /// (`NavigatorTextFilter`), or when one of its descendants does; the clock toggle keeps only
    /// the work in progress the same way.
    static func filtered(_ nodes: [ReportNode], by filter: NavigatorTextFilter, showsOnlyInProgress: Bool) -> [ReportNode] {
        guard isFiltering(filter: filter, showsOnlyInProgress: showsOnlyInProgress) else { return nodes }
        let matcher = filter.makeMatcher()
        func keep(_ node: ReportNode) -> ReportNode? {
            let children = node.children.compactMap(keep)
            let matchesText = matcher.matches(node.cellViewModel.appearance.title)
            let matchesProgress = !showsOnlyInProgress || node.cellViewModel.isInProgress
            if !children.isEmpty || (matchesText && matchesProgress && !isCategory(node)) {
                return ReportNode(identifier: node.identifier, cellViewModel: node.cellViewModel, children: children)
            }
            return nil
        }
        return nodes.compactMap(keep)
    }

    /// Whether the filter bar narrows the outline at all.
    static func isFiltering(filter: NavigatorTextFilter, showsOnlyInProgress: Bool) -> Bool {
        !filter.isEmpty || showsOnlyInProgress
    }

    // MARK: - Expansion

    /// The rows to open: each kind of work, and each batch still running with images under it, the
    /// first time it appears — as Xcode opens its newest builds. A row seen once is never opened
    /// or closed again, so what the user collapses stays collapsed. `seenIdentifiers` carries what
    /// has been seen from one call to the next.
    static func nodesToExpand(in nodes: [ReportNode], seenIdentifiers: inout Set<ReportNodeIdentifier>) -> [ReportNode] {
        var nodesToExpand: [ReportNode] = []
        for categoryNode in nodes {
            if seenIdentifiers.insert(categoryNode.identifier).inserted {
                nodesToExpand.append(categoryNode)
            }
            for node in categoryNode.children {
                guard seenIdentifiers.insert(node.identifier).inserted else { continue }
                if node.cellViewModel.isInProgress, !node.children.isEmpty {
                    nodesToExpand.append(node)
                }
            }
        }
        return nodesToExpand
    }

    static func isCategory(_ node: ReportNode) -> Bool {
        if case .category = node.identifier { return true }
        return false
    }

    static func isInProgress(_ node: ReportNode) -> Bool {
        node.cellViewModel.isInProgress || node.children.contains(where: isInProgress)
    }

    static func isCancellable(_ node: ReportNode) -> Bool {
        node.cellViewModel.isCancellable || node.children.contains(where: isCancellable)
    }

    static func isBuilding(_ state: RuntimeInterfaceCorpusBuildState) -> Bool {
        if case .building = state { return true }
        return false
    }

    static func isPreparing(_ state: CrossReferencePreparationState) -> Bool {
        if case .preparing = state { return true }
        return false
    }

    // MARK: - Text and icons

    static let indexingIcon: NSUIImage = SFSymbols(systemName: .squareStack3dDownRight).nsuiImgae

    static let corpusIcon: NSUIImage = SFSymbols(systemName: .magnifyingglass).nsuiImgae

    static let crossReferenceIcon: NSUIImage = SFSymbols(systemName: .arrowTriangleBranch).nsuiImgae

    static let turnedOffIcon: NSUIImage = SFSymbols(systemName: .powerCircle).nsuiImgae

    static let unsupportedIcon: NSUIImage = SFSymbols(systemName: .exclamationmarkCircle).nsuiImgae

    static let restoredCorporaIcon: NSUIImage = SFSymbols(systemName: .archivebox).nsuiImgae

    static func icon(forImagePath imagePath: String) -> NSUIImage {
        imagePath.contains(".framework/") ? RuntimeImageNode.frameworkIcon : RuntimeImageNode.imageIcon
    }

    static func title(for reason: RuntimeIndexingBatchReason) -> String {
        switch reason {
        case .appLaunch:
            "App Launch Indexing"
        case .settingsEnabled:
            "Indexing Turned On"
        case .manual:
            "Manual Indexing"
        case .alwaysIndex(let identifier):
            identifier
        }
    }

    static let dayFormatter = DateFormatter().then {
        $0.dateStyle = .medium
        $0.timeStyle = .none
        $0.doesRelativeDateFormatting = true
    }

    static let clockFormatter = DateFormatter().then {
        $0.dateStyle = .none
        $0.timeStyle = .short
    }

    /// `Today, 10:23`, as Xcode's Report navigator dates its entries.
    static func timeText(_ date: Date) -> String {
        "\(dayFormatter.string(from: date)), \(clockFormatter.string(from: date))"
    }
}

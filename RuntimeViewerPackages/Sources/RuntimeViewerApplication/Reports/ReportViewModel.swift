import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerUI
import MemberwiseInit
#if canImport(RuntimeViewerSettings)
import RuntimeViewerSettings
#endif

/// The Report navigator page: the background indexer's batches and the Find navigator's corpus
/// builds, as Xcode's Report navigator lists builds and runs — one outline, each kind of work a
/// first-level row, the newest work first, a spinner on whatever is still running.
///
/// Generic over the sidebar level's route because the page is a tab of both levels; both read the
/// document's `RuntimeBackgroundIndexingCoordinator` and `FindCorpusCoordinator`, so the two pages
/// always agree.
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
        /// The filter bar, as typed: rows whose title contains it, with their ancestors. Need not
        /// start with a value — until it reports one the outline is unfiltered.
        public let filterString: Driver<String>
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
        /// corpus build another window asked for is in progress, but not this page's to cancel.
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

    /// The filter bar's text and clock toggle as last reported, kept here instead of being combined
    /// straight from the input: the filter field's `rx.stringValue` reports only what is typed into
    /// it, so an untouched field says nothing at all, and an outline waiting on it stays empty.
    @RxObserved
    private var filterString: String = ""

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
        let indexingCoordinator = documentState.backgroundIndexingCoordinator
        let corpusCoordinator = documentState.findCorpusCoordinator

        let treeBuilder = treeBuilder
        let isIndexingEnabled = $isIndexingEnabled.asObservable()
        let isCorpusEnabled = $isCorpusEnabled.asObservable()
        let isVisible = input.isVisible.asObservable().distinctUntilChanged()

        isVisible
            .flatMapLatest { isVisible -> Observable<[ReportNode]> in
                // A page nobody sees builds nothing. Coming on screen replays the latest of every
                // input, so the tree is current before the page is drawn.
                guard isVisible else { return .empty() }
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
                    corpusCoordinator.$isCorpusUnsupportedByEngine.asObservable(),
                    isCorpusEnabled
                )
                .observe(on: MainScheduler.instance)
                .map { states, followedImagePaths, finishedBuilds, isCorpusUnsupportedByEngine, isCorpusEnabled in
                    MainActor.assumeIsolated {
                        treeBuilder.corpusCategory(
                            states: states,
                            followedImagePaths: followedImagePaths,
                            finishedBuilds: finishedBuilds,
                            isUnsupportedByEngine: isCorpusUnsupportedByEngine,
                            isEnabled: isCorpusEnabled
                        )
                    }
                }
                return Observable.combineLatest(indexingCategory, corpusCategory) { indexingCategory, corpusCategory in
                    [indexingCategory, corpusCategory].compactMap { $0 }
                }
            }
            .bind(to: $allNodes)
            .disposed(by: rx.disposeBag)

        isVisible
            .filter { $0 }
            .subscribeOnNext { _ in
                corpusCoordinator.refreshCoverage()
            }
            .disposed(by: rx.disposeBag)

        input.cancel.emitOnNext { node in
            switch node.identifier {
            case .indexingBatch(let batchID):
                indexingCoordinator.cancelBatch(batchID)
            case .corpusBuild(let imagePath):
                corpusCoordinator.cancelBuild(of: imagePath)
            case .category, .turnedOff, .unsupportedByEngine, .indexingItem, .finishedCorpusBuild:
                break
            }
        }
        .disposed(by: rx.disposeBag)

        input.cancelAll.emitOnNext {
            indexingCoordinator.cancelAllBatches()
            // Only what this document asked for; another window's build is not this page's to stop.
            for imagePath in corpusCoordinator.followedImagePaths {
                corpusCoordinator.cancelBuild(of: imagePath)
            }
        }
        .disposed(by: rx.disposeBag)

        input.clearHistory.emitOnNext {
            indexingCoordinator.clearHistory()
            corpusCoordinator.clearFinishedBuilds()
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

        input.filterString.driveOnNext { [weak self] filterString in
            guard let self else { return }
            announceFilteringChange(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
            self.filterString = filterString
        }
        .disposed(by: rx.disposeBag)

        input.showsOnlyInProgress.driveOnNext { [weak self] showsOnlyInProgress in
            guard let self else { return }
            announceFilteringChange(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
            self.showsOnlyInProgress = showsOnlyInProgress
        }
        .disposed(by: rx.disposeBag)

        let filteredOutline = Driver.combineLatest($allNodes.asDriver(), $filterString.asDriver(), $showsOnlyInProgress.asDriver()) { nodes, filterString, showsOnlyInProgress in
            (
                nodes: ReportOutline.filtered(nodes, by: filterString, showsOnlyInProgress: showsOnlyInProgress),
                isFiltering: ReportOutline.isFiltering(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
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
            hasHistory: Driver.combineLatest(indexingCoordinator.historyObservable.asDriver(onErrorJustReturn: []), corpusCoordinator.$finishedBuilds.asDriver()) { history, finishedBuilds in
                !history.isEmpty || !finishedBuilds.isEmpty
            }
            .distinctUntilChanged()
        )
    }

    /// Tells the page the filter bar starts or stops narrowing the outline, before the narrowed
    /// tree reaches it.
    private func announceFilteringChange(filterString newFilterString: String, showsOnlyInProgress newShowsOnlyInProgress: Bool) {
        let wasFiltering = ReportOutline.isFiltering(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress)
        let isFiltering = ReportOutline.isFiltering(filterString: newFilterString, showsOnlyInProgress: newShowsOnlyInProgress)
        if isFiltering != wasFiltering {
            filteringChangedRelay.accept(isFiltering)
        }
    }

    // MARK: - Settings

    /// The two switches the outline shows a "Turned off in Settings" row for.
    private struct FeatureSwitches: Equatable {
        let isIndexingEnabled: Bool
        let isCorpusEnabled: Bool
    }

    /// Follows the two switches for as long as the page lives: the first value arrives while
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
                    FeatureSwitches(isIndexingEnabled: trackedSettings.indexing.isEnabled, isCorpusEnabled: trackedSettings.search.isCorpusEnabled)
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

    /// `isFollowed`: this document asked for the build, so its progress reaches the row and Cancel
    /// withdraws it. Any other build is the engine's last snapshot of it, for a window or a peer
    /// this page cannot speak for: its numbers would sit still, and Cancel would do nothing.
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
        let toolTip = isFollowed ? imagePath : "\(imagePath)\nRequested by another window"
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

    // MARK: - Filtering

    /// The filter bar: a row stays when its title contains the filter string, or when one of its
    /// descendants does; the clock toggle keeps only the work in progress the same way.
    static func filtered(_ nodes: [ReportNode], by filterString: String, showsOnlyInProgress: Bool) -> [ReportNode] {
        guard isFiltering(filterString: filterString, showsOnlyInProgress: showsOnlyInProgress) else { return nodes }
        let needle = filterString.trimmingCharacters(in: .whitespaces)
        func keep(_ node: ReportNode) -> ReportNode? {
            let children = node.children.compactMap(keep)
            let matchesText = needle.isEmpty || node.cellViewModel.appearance.title.range(of: needle, options: .caseInsensitive) != nil
            let matchesProgress = !showsOnlyInProgress || node.cellViewModel.isInProgress
            if !children.isEmpty || (matchesText && matchesProgress && !isCategory(node)) {
                return ReportNode(identifier: node.identifier, cellViewModel: node.cellViewModel, children: children)
            }
            return nil
        }
        return nodes.compactMap(keep)
    }

    /// Whether the filter bar narrows the outline at all.
    static func isFiltering(filterString: String, showsOnlyInProgress: Bool) -> Bool {
        !filterString.trimmingCharacters(in: .whitespaces).isEmpty || showsOnlyInProgress
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

    // MARK: - Text and icons

    static let indexingIcon: NSUIImage = SFSymbols(systemName: .squareStack3dDownRight).nsuiImgae

    static let corpusIcon: NSUIImage = SFSymbols(systemName: .magnifyingglass).nsuiImgae

    static let turnedOffIcon: NSUIImage = SFSymbols(systemName: .powerCircle).nsuiImgae

    static let unsupportedIcon: NSUIImage = SFSymbols(systemName: .exclamationmarkCircle).nsuiImgae

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

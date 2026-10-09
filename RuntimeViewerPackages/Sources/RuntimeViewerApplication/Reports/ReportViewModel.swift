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
        /// The page came on screen. The corpus store evicts without telling anyone, so the corpus
        /// states are asked for again.
        public let appeared: Signal<Void>
        public let cancel: Signal<ReportNode>
        public let cancelAll: Signal<Void>
        public let clearHistory: Signal<Void>
        public let openSettings: Signal<Void>
        /// The filter bar, as typed: rows whose title contains it, with their ancestors. Need not
        /// start with a value — until it reports one the outline is unfiltered.
        public let filterString: Driver<String>
        /// The filter bar's clock toggle: only the work in progress. Off until it reports otherwise.
        public let showsOnlyInProgress: Driver<Bool>
    }

    public struct Output {
        public let nodes: Driver<[ReportNode]>
        /// Nothing at all to report — no batch, no build, no feature turned off.
        public let isEmpty: Driver<Bool>
        /// Some work has not ended yet, so Cancel All has something to cancel.
        public let hasWorkInProgress: Driver<Bool>
        public let hasHistory: Driver<Bool>
    }

    /// The rows' cell ViewModels by what they stand for, kept across rebuilds so a row on screen
    /// keeps its cell and updates in place. Rows that disappear are dropped on the next rebuild.
    private var cellViewModelsByIdentifier: [ReportNodeIdentifier: ReportCellViewModel] = [:]

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

    public override init(documentState: DocumentState, router: any Router<Route>) {
        super.init(documentState: documentState, router: router)
        bootstrapSettingsObservation()
    }

    public func transform(_ input: Input) -> Output {
        let indexingCoordinator = documentState.backgroundIndexingCoordinator
        let corpusCoordinator = documentState.findCorpusCoordinator

        Observable.combineLatest(
            indexingCoordinator.batchesObservable,
            indexingCoordinator.historyObservable,
            corpusCoordinator.$buildStatesByImagePath.asObservable(),
            corpusCoordinator.$finishedBuilds.asObservable(),
            $isIndexingEnabled.asObservable(),
            $isCorpusEnabled.asObservable()
        )
        .observe(on: MainScheduler.instance)
        .subscribeOnNext { [weak self] batches, history, corpusStates, finishedBuilds, isIndexingEnabled, isCorpusEnabled in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.allNodes = self.makeNodes(
                    batches: batches,
                    history: history,
                    corpusStates: corpusStates,
                    finishedBuilds: finishedBuilds,
                    isIndexingEnabled: isIndexingEnabled,
                    isCorpusEnabled: isCorpusEnabled
                )
            }
        }
        .disposed(by: rx.disposeBag)

        input.appeared.emitOnNext {
            corpusCoordinator.refreshCoverage()
        }
        .disposed(by: rx.disposeBag)

        input.cancel.emitOnNext { node in
            switch node.identifier {
            case .indexingBatch(let batchID):
                indexingCoordinator.cancelBatch(batchID)
            case .corpusBuild(let imagePath):
                corpusCoordinator.cancelBuild(of: imagePath)
            case .category, .turnedOff, .indexingItem, .finishedCorpusBuild:
                break
            }
        }
        .disposed(by: rx.disposeBag)

        input.cancelAll.emitOnNext {
            indexingCoordinator.cancelAllBatches()
            for (imagePath, state) in corpusCoordinator.buildStatesByImagePath where state.isActive {
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
        #endif

        input.filterString.driveOnNext { [weak self] filterString in
            guard let self else { return }
            self.filterString = filterString
        }
        .disposed(by: rx.disposeBag)

        input.showsOnlyInProgress.driveOnNext { [weak self] showsOnlyInProgress in
            guard let self else { return }
            self.showsOnlyInProgress = showsOnlyInProgress
        }
        .disposed(by: rx.disposeBag)

        let nodes = Driver.combineLatest($allNodes.asDriver(), $filterString.asDriver(), $showsOnlyInProgress.asDriver()) { nodes, filterString, showsOnlyInProgress in
            ReportOutline.filtered(nodes, by: filterString, showsOnlyInProgress: showsOnlyInProgress)
        }

        return Output(
            nodes: nodes,
            isEmpty: $allNodes.asDriver().map(\.isEmpty).distinctUntilChanged(),
            hasWorkInProgress: $allNodes.asDriver().map { nodes in nodes.contains(where: ReportOutline.isInProgress) }.distinctUntilChanged(),
            hasHistory: Driver.combineLatest(indexingCoordinator.historyObservable.asDriver(onErrorJustReturn: []), corpusCoordinator.$finishedBuilds.asDriver()) { history, finishedBuilds in
                !history.isEmpty || !finishedBuilds.isEmpty
            }
            .distinctUntilChanged()
        )
    }

    // MARK: - Building the outline

    private func makeNodes(
        batches: [RuntimeIndexingBatch],
        history: [RuntimeIndexingBatch],
        corpusStates: [String: RuntimeInterfaceCorpusBuildState],
        finishedBuilds: [FindCorpusFinishedBuild],
        isIndexingEnabled: Bool,
        isCorpusEnabled: Bool
    ) -> [ReportNode] {
        var usedIdentifiers: Set<ReportNodeIdentifier> = []
        func node(_ identifier: ReportNodeIdentifier, children: [ReportNode] = [], configure: (ReportCellViewModel) -> Void) -> ReportNode {
            let cellViewModel = cellViewModelsByIdentifier[identifier] ?? ReportCellViewModel(identifier: identifier)
            cellViewModelsByIdentifier[identifier] = cellViewModel
            usedIdentifiers.insert(identifier)
            configure(cellViewModel)
            return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
        }

        var indexingChildren: [ReportNode] = []
        if !isIndexingEnabled {
            indexingChildren.append(node(.turnedOff(.backgroundIndexing)) { $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings") })
        }
        // The manager appends batches as they start, and history is newest first already.
        for batch in batches.reversed() + history {
            let showsItems = !(batch.reason.category == .alwaysIndex && batch.items.count <= 1)
            let items = showsItems ? batch.items.map { item in
                node(.indexingItem(batchID: batch.id, imagePath: item.id)) { ReportOutline.configure($0, for: item) }
            } : []
            indexingChildren.append(node(.indexingBatch(batch.id), children: items) { ReportOutline.configure($0, for: batch) })
        }

        var corpusChildren: [ReportNode] = []
        if !isCorpusEnabled {
            corpusChildren.append(node(.turnedOff(.searchableInterfaces)) { $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings") })
        }
        // The image being printed first, then the waiting ones by name.
        let activeBuilds = corpusStates.filter(\.value.isActive).sorted { leftEntry, rightEntry in
            let leftIsBuilding = ReportOutline.isBuilding(leftEntry.value)
            let rightIsBuilding = ReportOutline.isBuilding(rightEntry.value)
            if leftIsBuilding != rightIsBuilding {
                return leftIsBuilding
            }
            return FindScope.imageName(of: leftEntry.key) < FindScope.imageName(of: rightEntry.key)
        }
        for (imagePath, state) in activeBuilds {
            corpusChildren.append(node(.corpusBuild(imagePath: imagePath)) { ReportOutline.configure($0, forCorpusOf: imagePath, state: state) })
        }
        for finishedBuild in finishedBuilds {
            corpusChildren.append(node(.finishedCorpusBuild(finishedBuild.id)) { ReportOutline.configure($0, for: finishedBuild) })
        }

        var nodes: [ReportNode] = []
        if !indexingChildren.isEmpty {
            nodes.append(node(.category(.backgroundIndexing), children: indexingChildren) { $0.update(icon: ReportOutline.indexingIcon, title: "Background Indexing") })
        }
        if !corpusChildren.isEmpty {
            nodes.append(node(.category(.searchableInterfaces), children: corpusChildren) { $0.update(icon: ReportOutline.corpusIcon, title: "Searchable Interfaces") })
        }
        cellViewModelsByIdentifier = cellViewModelsByIdentifier.filter { usedIdentifiers.contains($0.key) }
        return nodes
    }

    // MARK: - Settings

    private func bootstrapSettingsObservation() {
        #if canImport(RuntimeViewerSettings)
        isIndexingEnabled = settings.indexing.isEnabled
        isCorpusEnabled = settings.search.isCorpusEnabled
        registerSettingsObservation()
        #endif
    }

    #if canImport(RuntimeViewerSettings)
    /// `withObservationTracking` fires once, so the observation registers itself again on every
    /// change.
    private func registerSettingsObservation() {
        withObservationTracking {
            _ = settings.indexing.isEnabled
            _ = settings.search.isCorpusEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isIndexingEnabled = self.settings.indexing.isEnabled
                self.isCorpusEnabled = self.settings.search.isCorpusEnabled
                self.registerSettingsObservation()
            }
        }
    }
    #endif
}

/// How the Report navigator's rows read and how its filter bar narrows them — kept apart from the
/// generic `ReportViewModel`, which can hold no static stored values, and tested on its own.
enum ReportOutline {
    static func configure(_ cellViewModel: ReportCellViewModel, for batch: RuntimeIndexingBatch) {
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

    static func configure(_ cellViewModel: ReportCellViewModel, forCorpusOf imagePath: String, state: RuntimeInterfaceCorpusBuildState) {
        let detail: String
        let status: ReportRowStatus
        switch state {
        case .building(let progress):
            detail = progress.total > 0 ? "\(progress.built * 100 / progress.total)% · \(progress.built) of \(progress.total)" : "Starting"
            status = .running
        case .pending, .built, .failed:
            detail = "Waiting"
            status = .none
        }
        cellViewModel.update(icon: icon(forImagePath: imagePath), title: FindScope.imageName(of: imagePath), detail: detail, status: status, toolTip: imagePath, isCancellable: true, isInProgress: true)
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
        let needle = filterString.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty || showsOnlyInProgress else { return nodes }
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

    static func isCategory(_ node: ReportNode) -> Bool {
        if case .category = node.identifier { return true }
        return false
    }

    static func isInProgress(_ node: ReportNode) -> Bool {
        node.cellViewModel.isInProgress || node.children.contains(where: isInProgress)
    }

    static func isBuilding(_ state: RuntimeInterfaceCorpusBuildState) -> Bool {
        if case .building = state { return true }
        return false
    }

    // MARK: - Text and icons

    static let indexingIcon: NSUIImage = SFSymbols(systemName: .squareStack3dDownRight).nsuiImgae

    static let corpusIcon: NSUIImage = SFSymbols(systemName: .magnifyingglass).nsuiImgae

    static let turnedOffIcon: NSUIImage = SFSymbols(systemName: .powerCircle).nsuiImgae

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

import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
#if canImport(RuntimeViewerSettings)
import RuntimeViewerSettings
#endif

/// Keeps the engine's interface corpus in step with what the document has
/// indexed, so a text or member search finds every indexed image already
/// built.
///
/// The counterpart of `RuntimeBackgroundIndexingCoordinator`, and kept apart
/// from it on purpose: that one makes images *indexed*, this one makes
/// indexed images *searchable*, and the two have different queues and
/// cancellation rules (proposal `draft-find-navigator` §4). The building
/// itself — one image at a time, at utility priority, deduplicated across
/// documents, cancelled only when its last subscriber leaves — is the
/// engine's `RuntimeInterfaceCorpusStore`; this coordinator decides *which*
/// images to ask for and *when*:
///
/// 1. every image the engine's API indexed — the background indexer's loads,
///    an export's, an image the sidebar opened — the one the sidebar shows
///    moved to the front of the queue (`RuntimeEngine.imageDidIndexPublisher`);
/// 2. every image indexed before the coordinator started listening, once;
/// 3. the corpus switch turning on, for every indexed image;
/// 4. the transformer settings changing, after a two-second lull: every
///    corpus is printed with them, so all are dropped and rebuilt.
///
/// Turning the switch off drops every corpus. A source switch rewires onto
/// the new engine and starts over.
///
/// It also says how its requests are going: `buildStatesByImagePath` takes
/// every image it asked for from queued to built or failed, progress
/// published at most once a frame, and `finishedBuilds` keeps the builds
/// that ended. The Report navigator lists both; the Find navigator's summary
/// reads the first, and widens the search in force to each corpus
/// `corpusBuilt` reports.
@MainActor
@Loggable(.private)
public final class FindCorpusCoordinator {
    /// Most finished builds kept, newest first — the cap of the indexing
    /// coordinator's history.
    static let maximumFinishedBuildCount = 100

    /// One frame at 60 Hz. Progress arrives every few objects printed, from
    /// whichever thread the engine reports on; the reports of one frame are
    /// published together.
    static let progressCoalescingWindowNanoseconds: UInt64 = 16_000_000

    /// How long transformer edits are left to settle before every corpus is
    /// rebuilt.
    static let transformerRebuildDelayNanoseconds: UInt64 = 2_000_000_000

    /// A build request this document holds open — one subscription on the
    /// store's build of the image. The identifier tells a request apart from
    /// the one that replaced it after a withdrawal.
    private struct BuildRequest {
        let identifier: UInt64
        let task: Task<Void, Never>
    }

    private var engine: RuntimeEngine

    /// The engine's "image indexed" reports, each of which asks for the
    /// image's corpus.
    private var imageIndexedSubscription: AnyCancellable?

    /// The path of the image the sidebar lists, as the sidebar spells it. An
    /// image that becomes indexed while it is on screen goes to the front of
    /// the queue.
    private var currentImagePath: String?

    /// The build requests this document holds open, by image path.
    /// Cancelling one withdraws only this document's interest.
    private var buildRequests: [String: BuildRequest] = [:]

    private var nextBuildRequestIdentifier: UInt64 = 0

    private var transformerRebuildTask: Task<Void, Never>?

    /// Images this document asked to build under the current engine, so a
    /// transformer change knows what to rebuild.
    private var requestedImagePaths: Set<String> = []

    private let progressStaging = ProgressStaging()

    private let corpusBuiltRelay = PublishRelay<String>()

    /// Replaced when the document closes, which ends every subscription.
    private var disposeBag = DisposeBag()

    /// The document closed; see `documentWillClose()`.
    private var isClosed = false

    #if canImport(RuntimeViewerSettings)
    @Dependency(\.settings)
    private var settings

    private var lastKnownIsEnabled = true

    private var lastKnownTransformer = Transformer.Configuration.default

    private var lastKnownResidentByteLimit = 0
    #endif

    /// Where each image's corpus stands as this document follows it: the
    /// images it asked for, from `.pending` to `.built` or `.failed`, and the
    /// rest as the engine last reported them. An absent image is unbuilt.
    @RxObserved
    public private(set) var buildStatesByImagePath: [String: RuntimeInterfaceCorpusBuildState] = [:]

    /// Builds that ended, newest first, at most `maximumFinishedBuildCount`
    /// of them. Corpora other documents built come after the ones this
    /// document saw end: the engine does not say when they were built.
    @RxObserved
    public private(set) var finishedBuilds: [FindCorpusFinishedBuild] = []

    /// Every image that has had a place in `finishedBuilds`, kept through
    /// `clearFinishedBuilds()`: a coverage snapshot lists only corpora this
    /// document has never listed, or a cleared entry would come back with the
    /// next refresh. An image leaves once its corpus is gone from the engine,
    /// so a corpus rebuilt after an eviction is listed again.
    private var imagePathsListedInHistory: Set<String> = []

    /// An image's path, each time a request of this document ends with the
    /// image's corpus built.
    public var corpusBuilt: Signal<String> {
        corpusBuiltRelay.asSignal()
    }

    /// Whether an image is waiting for its corpus or being printed.
    public var hasActiveBuild: Driver<Bool> {
        $buildStatesByImagePath.asDriver()
            .map { states in states.values.contains(where: \.isActive) }
            .distinctUntilChanged()
    }

    /// Reads `documentState` here and keeps nothing of it but subscriptions:
    /// the coordinator can outlive the document.
    public init(documentState: DocumentState) {
        self.engine = documentState.runtimeEngine
        #if canImport(RuntimeViewerSettings)
        bootstrapSettingsObservation()
        #endif
        bootstrapEngineObservation(of: documentState)
        bootstrapCurrentImageObservation(of: documentState)
        documentState.findSession.follow(self)
        startPumps()
    }

    deinit {
        transformerRebuildTask?.cancel()
        for request in buildRequests.values {
            request.task.cancel()
        }
    }

    // MARK: - Enablement

    private var isEnabled: Bool {
        #if canImport(RuntimeViewerSettings)
        settings.search.isCorpusEnabled
        #else
        true
        #endif
    }

    private var currentTransformer: Transformer.Configuration {
        #if canImport(RuntimeViewerSettings)
        settings.transformer
        #else
        .default
        #endif
    }

    // MARK: - Paths

    /// `imagePath` as the engine keys it. Every path this coordinator stores
    /// or reports is in this form: on an iOS Simulator engine the sidebar, the
    /// background indexer and a search scope spell paths without the
    /// simulator's root, while coverage and search summaries spell them with
    /// it.
    public func canonicalImagePath(_ imagePath: String) -> String {
        engine.canonicalImagePath(imagePath)
    }

    /// `imagePath`'s state, however the caller spells the path.
    public func buildState(forImagePath imagePath: String) -> RuntimeInterfaceCorpusBuildState? {
        buildStatesByImagePath[canonicalImagePath(imagePath)]
    }

    // MARK: - Triggers

    /// Asks the engine to build `requestedImagePath`'s corpus. A request
    /// already open for the image is not repeated; with `isPrioritized` it is
    /// moved to the front of the engine's queue instead. The path may be
    /// spelled either way; see `canonicalImagePath(_:)`.
    public func requestBuild(of requestedImagePath: String, isPrioritized: Bool = false) {
        guard isEnabled, !isClosed else { return }
        let imagePath = canonicalImagePath(requestedImagePath)
        if buildRequests[imagePath] != nil {
            if isPrioritized {
                let engine = engine
                Task {
                    try? await engine.prioritizeInterfaceCorpus(for: imagePath)
                }
            }
            return
        }
        requestedImagePaths.insert(imagePath)
        nextBuildRequestIdentifier += 1
        let identifier = nextBuildRequestIdentifier
        let engine = engine
        let transformer = currentTransformer
        if buildStatesByImagePath[imagePath]?.isBuilt != true {
            buildStatesByImagePath[imagePath] = .pending
        }
        let task = Task { [weak self] in
            let result: Result<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>
            do {
                let summary = try await engine.buildInterfaceCorpus(for: imagePath, transformer: transformer, isPrioritized: isPrioritized) { [weak self] progress in
                    self?.stageProgress(progress, for: imagePath, requestIdentifier: identifier)
                }
                result = .success(summary)
            } catch {
                result = .failure(error)
            }
            self?.finishBuildRequest(identifier, of: imagePath, with: result)
        }
        buildRequests[imagePath] = BuildRequest(identifier: identifier, task: task)
    }

    /// Every image the engine has indexed, queued in one go — the switch
    /// turning on, or a fresh engine.
    public func requestBuildOfIndexedImages() {
        guard isEnabled, !isClosed else { return }
        let engine = engine
        Task { [weak self] in
            guard let imagePaths = try? await engine.indexedImagePathList() else { return }
            guard let self, self.engine === engine else { return }
            for imagePath in imagePaths {
                self.requestBuild(of: imagePath)
            }
        }
    }

    /// Withdraws this document's request for `imagePath` — the Report
    /// navigator's Cancel. Another document asking for the image keeps its
    /// build going, and the withdrawal is not sticky: the next trigger for the
    /// image asks again.
    public func cancelBuild(of requestedImagePath: String) {
        let imagePath = canonicalImagePath(requestedImagePath)
        guard let request = buildRequests.removeValue(forKey: imagePath) else { return }
        request.task.cancel()
        buildStatesByImagePath[imagePath] = nil
        recordFinishedBuild(FindCorpusFinishedBuild(imagePath: imagePath, outcome: .cancelled, finishedAt: Date()))
    }

    /// The document is closing: every request it holds is withdrawn — over a
    /// connection each withdrawal reaches the serving process as a
    /// `cancelRequest` — and nothing asks for a corpus again, not an image the
    /// engine indexes, not a settings change made in another window, not an
    /// engine swap. `DocumentState` holds this coordinator and can outlive
    /// the window, so `deinit` is too late to count on.
    public func documentWillClose() {
        isClosed = true
        stopPumps()
        withdrawEveryBuild()
        disposeBag = DisposeBag()
    }

    /// Empties `finishedBuilds`. The corpora listed so far stay off it: a
    /// later coverage snapshot does not bring them back.
    public func clearFinishedBuilds() {
        finishedBuilds = []
    }

    /// Asks the engine where every corpus stands and folds the answer in —
    /// see `mergeCoverage(_:)`. Runs on start and after every build; the
    /// Report navigator calls it when it appears, because the store evicts
    /// without telling anyone.
    public func refreshCoverage() {
        let engine = engine
        Task { [weak self] in
            guard let coverage = try? await engine.interfaceCorpusCoverage() else { return }
            guard let self, self.engine === engine else { return }
            self.mergeCoverage(coverage)
        }
    }

    /// Withdraws every request this document holds, leaving the images they
    /// were following unbuilt as far as it is concerned.
    private func withdrawEveryBuild() {
        for request in buildRequests.values {
            request.task.cancel()
        }
        var states = buildStatesByImagePath
        for imagePath in buildRequests.keys where states[imagePath]?.isActive == true {
            states[imagePath] = nil
        }
        buildRequests.removeAll()
        buildStatesByImagePath = states
    }

    private func dropEveryCorpus(on engine: RuntimeEngine) {
        withdrawEveryBuild()
        buildStatesByImagePath = [:]
        Task {
            try? await engine.evictInterfaceCorpus(for: nil)
        }
    }

    // MARK: - Build state

    /// Called from the engine's thread with each progress report; publishes
    /// at most once per `progressCoalescingWindowNanoseconds`.
    nonisolated private func stageProgress(_ progress: RuntimeInterfaceCorpusBuildProgress, for imagePath: String, requestIdentifier: UInt64) {
        guard progressStaging.record(progress, for: imagePath, requestIdentifier: requestIdentifier) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.progressCoalescingWindowNanoseconds)
            self?.flushProgress()
        }
    }

    private func flushProgress() {
        var states = buildStatesByImagePath
        for (imagePath, report) in progressStaging.drain() where buildRequests[imagePath]?.identifier == report.requestIdentifier {
            states[imagePath] = .building(report.progress)
        }
        if states != buildStatesByImagePath {
            buildStatesByImagePath = states
        }
    }

    private func finishBuildRequest(_ identifier: UInt64, of imagePath: String, with result: Result<RuntimeInterfaceCorpusBuildSummary, any Swift.Error>) {
        let hasReportedProgress = progressStaging.takeHasReported(identifier)
        // A request withdrawn — by the user, a source switch, the switch going
        // off, a transformer change — has nothing left to report here.
        guard buildRequests[imagePath]?.identifier == identifier else { return }
        buildRequests[imagePath] = nil
        switch result {
        case .success(let summary):
            buildStatesByImagePath[imagePath] = .built(summary)
            // A corpus that was already there comes back without a single
            // progress report; it is not a build this document saw.
            if hasReportedProgress {
                recordFinishedBuild(FindCorpusFinishedBuild(imagePath: imagePath, outcome: .built(summary), finishedAt: Date()))
            }
            corpusBuiltRelay.accept(imagePath)
            refreshCoverage()
        case .failure(is CancellationError):
            // The store cancelled the build for everyone: another document
            // asked for it under a different transformer, or evicted it.
            buildStatesByImagePath[imagePath] = nil
        case .failure(is RuntimeInterfaceCorpusBuildError):
            // Not indexed yet: nothing to print, and nothing went wrong. The
            // image is asked for again once the engine reports it indexed.
            buildStatesByImagePath[imagePath] = nil
        case .failure(let error):
            #log(.error, "Corpus build of \(imagePath, privacy: .public) failed: \(error, privacy: .public)")
            let message = "\(error)"
            buildStatesByImagePath[imagePath] = .failed(message: message)
            recordFinishedBuild(FindCorpusFinishedBuild(imagePath: imagePath, outcome: .failed(message: message), finishedAt: Date()))
        }
    }

    private func recordFinishedBuild(_ finishedBuild: FindCorpusFinishedBuild) {
        imagePathsListedInHistory.insert(finishedBuild.imagePath)
        var builds = finishedBuilds
        builds.insert(finishedBuild, at: 0)
        if builds.count > Self.maximumFinishedBuildCount {
            builds.removeLast(builds.count - Self.maximumFinishedBuildCount)
        }
        finishedBuilds = builds
    }

    /// Folds the engine's coverage into what this document shows. An image
    /// this document holds a request for keeps the state its request
    /// reports; every other image takes the engine's word — a corpus another
    /// document built, one being built for another document, or one evicted
    /// since, which would otherwise stay built here forever. Corpora that
    /// ended without this document seeing them go to the end of the history,
    /// in path order.
    func mergeCoverage(_ coverage: RuntimeInterfaceCorpusCoverage) {
        var states = buildStatesByImagePath
        for imagePath in Set(states.keys).union(coverage.statesByImagePath.keys) where buildRequests[imagePath] == nil {
            states[imagePath] = coverage.statesByImagePath[imagePath]
        }
        if states != buildStatesByImagePath {
            buildStatesByImagePath = states
        }

        imagePathsListedInHistory.formIntersection(coverage.statesByImagePath.keys)
        let recordedImagePaths = Set(finishedBuilds.map(\.imagePath))
        let learnedBuilds = coverage.statesByImagePath
            .filter { imagePath, _ in
                buildRequests[imagePath] == nil
                    && !recordedImagePaths.contains(imagePath)
                    && !imagePathsListedInHistory.contains(imagePath)
            }
            .sorted { $0.key < $1.key }
            .compactMap { imagePath, state -> FindCorpusFinishedBuild? in
                switch state {
                case .built(let summary):
                    FindCorpusFinishedBuild(imagePath: imagePath, outcome: .built(summary), finishedAt: nil)
                case .failed(let message):
                    FindCorpusFinishedBuild(imagePath: imagePath, outcome: .failed(message: message), finishedAt: nil)
                case .pending, .building:
                    nil
                }
            }
        guard !learnedBuilds.isEmpty, finishedBuilds.count < Self.maximumFinishedBuildCount else { return }
        imagePathsListedInHistory.formUnion(learnedBuilds.map(\.imagePath))
        finishedBuilds = Array((finishedBuilds + learnedBuilds).prefix(Self.maximumFinishedBuildCount))
    }

    // MARK: - Pumps

    private func startPumps() {
        let engine = engine
        // Subscribed before asking, so no image slips through in between: one
        // indexed from here on arrives below, one indexed earlier is in the
        // engine's indexed list. The engine reports every image its own API
        // indexed — the background indexer's loads, an export's, an image the
        // sidebar opened — so only images another process indexed are left to
        // the catch-up a finished search runs.
        imageIndexedSubscription = engine.imageDidIndexPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] imagePath in
                MainActor.assumeIsolated {
                    guard let self, self.engine === engine else { return }
                    self.imageDidIndex(at: imagePath)
                }
            }
        requestBuildOfIndexedImages()
        // What other documents sharing the engine have built or are building.
        refreshCoverage()
        #if canImport(RuntimeViewerSettings)
        applyResidentByteLimit()
        #endif
    }

    private func stopPumps() {
        imageIndexedSubscription = nil
        transformerRebuildTask?.cancel()
        transformerRebuildTask = nil
    }

    /// An image the engine reports indexed. One with a request open is left
    /// to it, one already built needs nothing; the image the sidebar shows
    /// goes to the front of the queue, every other one — an export's, the
    /// background indexer's — waits its turn.
    private func imageDidIndex(at reportedImagePath: String) {
        let imagePath = canonicalImagePath(reportedImagePath)
        let isOnScreen = currentImagePath.map(canonicalImagePath) == imagePath
        if buildRequests[imagePath] == nil, buildStatesByImagePath[imagePath]?.isBuilt == true {
            return
        }
        requestBuild(of: imagePath, isPrioritized: isOnScreen)
    }

    private func bootstrapCurrentImageObservation(of documentState: DocumentState) {
        documentState.$currentImageNode
            .subscribeOnNext { [weak self] imageNode in
                guard let self else { return }
                self.currentImagePath = imageNode?.path
            }
            .disposed(by: disposeBag)
    }

    // MARK: - Engine swap

    private func bootstrapEngineObservation(of documentState: DocumentState) {
        documentState.$runtimeEngine
            .skip(1)
            .subscribeOnNext { [weak self] newEngine in
                guard let self else { return }
                self.handleEngineSwap(to: newEngine)
            }
            .disposed(by: disposeBag)
    }

    /// The new engine has corpora of its own, so the states start over; the
    /// history stays — it reads as what this document built this session,
    /// like the indexing history.
    private func handleEngineSwap(to newEngine: RuntimeEngine) {
        stopPumps()
        withdrawEveryBuild()
        _ = progressStaging.drain()
        buildStatesByImagePath = [:]
        requestedImagePaths.removeAll()
        engine = newEngine
        startPumps()
    }

    // MARK: - Settings

    #if canImport(RuntimeViewerSettings)
    private func bootstrapSettingsObservation() {
        lastKnownIsEnabled = settings.search.isCorpusEnabled
        lastKnownTransformer = settings.transformer
        lastKnownResidentByteLimit = settings.search.residentByteLimit
        subscribeToSettings()
    }

    private func subscribeToSettings() {
        withObservationTracking {
            _ = settings.search.isCorpusEnabled
            _ = settings.search.residentByteLimitMegabytes
            _ = settings.transformer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // A closed document stops listening.
                guard let self, !self.isClosed else { return }
                self.handleSettingsChange()
                self.subscribeToSettings()
            }
        }
    }

    private func handleSettingsChange() {
        let isEnabledNow = settings.search.isCorpusEnabled
        if isEnabledNow != lastKnownIsEnabled {
            lastKnownIsEnabled = isEnabledNow
            if isEnabledNow {
                requestBuildOfIndexedImages()
            } else {
                dropEveryCorpus(on: engine)
            }
        }

        let residentByteLimit = settings.search.residentByteLimit
        if residentByteLimit != lastKnownResidentByteLimit {
            lastKnownResidentByteLimit = residentByteLimit
            applyResidentByteLimit()
        }

        let transformer = settings.transformer
        if transformer != lastKnownTransformer {
            lastKnownTransformer = transformer
            scheduleTransformerRebuild()
        }
    }

    private func applyResidentByteLimit() {
        let engine = engine
        let byteLimit = settings.search.residentByteLimit
        Task {
            try? await engine.setInterfaceCorpusResidentByteLimit(byteLimit)
        }
    }

    /// Every corpus was printed with the old transformer; after the edits
    /// settle, drop them all and rebuild the ones this document asked for.
    private func scheduleTransformerRebuild() {
        transformerRebuildTask?.cancel()
        let engine = engine
        transformerRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.transformerRebuildDelayNanoseconds)
            guard !Task.isCancelled, let self, self.engine === engine else { return }
            let imagePaths = self.requestedImagePaths
            self.withdrawEveryBuild()
            try? await engine.evictInterfaceCorpus(for: nil)
            guard self.engine === engine else { return }
            self.buildStatesByImagePath = [:]
            for imagePath in imagePaths {
                self.requestBuild(of: imagePath)
            }
        }
    }
    #endif
}

// MARK: - Progress staging

extension FindCorpusCoordinator {
    /// Progress reports waiting for the next flush. Written from whichever
    /// thread the engine reports on, drained on the main actor, so the main
    /// thread wakes once a frame rather than once per report. `@unchecked
    /// Sendable` because an `NSLock` guards it.
    fileprivate final class ProgressStaging: @unchecked Sendable {
        struct Report {
            let requestIdentifier: UInt64
            let progress: RuntimeInterfaceCorpusBuildProgress
        }

        private let lock = NSLock()

        private var reportsByImagePath: [String: Report] = [:]

        private var reportedRequestIdentifiers: Set<UInt64> = []

        private var hasScheduledFlush = false

        /// Keeps the latest report for the image. `true` when the caller has
        /// to schedule the flush; one already scheduled will take this report.
        func record(_ progress: RuntimeInterfaceCorpusBuildProgress, for imagePath: String, requestIdentifier: UInt64) -> Bool {
            lock.withLock {
                reportsByImagePath[imagePath] = Report(requestIdentifier: requestIdentifier, progress: progress)
                reportedRequestIdentifiers.insert(requestIdentifier)
                guard !hasScheduledFlush else { return false }
                hasScheduledFlush = true
                return true
            }
        }

        func drain() -> [String: Report] {
            lock.withLock {
                let reports = reportsByImagePath
                reportsByImagePath.removeAll()
                hasScheduledFlush = false
                return reports
            }
        }

        /// Whether the request ever reported progress, forgetting it.
        func takeHasReported(_ requestIdentifier: UInt64) -> Bool {
            lock.withLock {
                reportedRequestIdentifiers.remove(requestIdentifier) != nil
            }
        }
    }
}

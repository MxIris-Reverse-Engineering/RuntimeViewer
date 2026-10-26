import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures
#if canImport(RuntimeViewerSettings)
import RuntimeViewerSettings
#endif

/// Keeps the engine's interface corpus in step with what the engine has
/// indexed, so a text or member search finds every indexed image already
/// built.
///
/// The counterpart of `RuntimeBackgroundIndexingCoordinator`, and kept apart
/// from it on purpose: that one makes images *indexed*, this one makes
/// indexed images *searchable*, and the two have different queues and
/// cancellation rules (proposal `0029-find-navigator` §4). Like it, one per
/// engine, shared by every document on the engine (see
/// `RuntimeEngineBackgroundWork`): there used to be one per document, each
/// asking for every corpus again and keeping builds of its own, so a second
/// window showed the first one's builds frozen, could not cancel them, and
/// listed their ends as corpora built elsewhere. The building itself — one
/// image at a time, at utility priority, deduplicated across requests,
/// cancelled only when its last subscriber leaves — is the engine's
/// `RuntimeInterfaceCorpusStore`; this coordinator decides *which* images to
/// ask for and *when*:
///
/// 1. every image the engine's API indexed — the background indexer's loads,
///    an export's, an image the sidebar opened — an image any document's
///    sidebar shows moved to the front of the queue
///    (`RuntimeEngine.imageDidIndexPublisher`);
/// 2. every image indexed before the coordinator started listening, once;
/// 3. the corpus switch turning on, for every indexed image;
/// 4. the transformer settings changing, after a two-second lull: every
///    corpus is printed with them, so all are dropped and rebuilt, and the
///    search on screen runs again (`corporaRebuilt`).
///
/// Turning the switch off drops every corpus. The engine coming back with a
/// new process behind it starts the coordinator over; a build the lost
/// connection interrupted is not recorded as failed. A document moving to
/// another engine moves to that engine's coordinator.
///
/// It also says how its requests are going: `buildStatesByImagePath` takes
/// every image it asked for from queued to built or failed, progress
/// published at most once a frame, and `finishedBuilds` keeps the builds
/// that ended. The Report navigator lists both; the Find navigator's summary
/// reads the first, and widens the search in force to each corpus
/// `corpusBuilt` reports.
///
/// With derived data in the engine's process (proposal `draft-derived-data`),
/// the Always Index images are read from it as their batches are dispatched
/// — `restoreCorpora(of:)`, before any of them is indexed — and every other
/// request reads first and prints only what it does not find, which the
/// engine's store decides on its own. What was read is listed apart from the
/// builds, in `restoredImagesByImagePath`.
@MainActor
@Loggable(.private)
@Signpostable(.private)
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

    /// How often the engine is asked again while a build the coordinator did
    /// not ask for — another connection to the engine's process did — is under
    /// way: nothing else tells the coordinator how it goes, or that it ended.
    static let unfollowedBuildCoverageRefreshIntervalNanoseconds: UInt64 = 2_000_000_000

    /// A build request the coordinator holds open — one subscription on the
    /// store's build of the image. The identifier tells a request apart from
    /// the one that replaced it after a withdrawal.
    private struct BuildRequest {
        let identifier: UInt64
        let task: Task<Void, Never>
    }

    /// A read of stored corpora the coordinator holds open, and the images
    /// it reads.
    private struct RestoreRequest {
        let task: Task<Void, Never>
        let imagePaths: Set<String>
    }

    private let engine: RuntimeEngine

    /// The engine's "image indexed" reports, each of which asks for the
    /// image's corpus.
    private var imageIndexedSubscription: AnyCancellable?

    /// The image each document's sidebar lists, as the sidebar spells it, by
    /// document. An image that becomes indexed while a sidebar on the engine
    /// shows it goes to the front of the queue.
    private var onScreenImagePathsByDocument: [ObjectIdentifier: String] = [:]

    /// Whether the engine was ready when last heard from, so a `false → true`
    /// edge — a new process behind the engine — can be told from the state
    /// replayed on subscribing.
    private var engineWasReady = false

    private var engineReadinessSubscription: AnyCancellable?

    /// The build requests the coordinator holds open, by image path, for every
    /// document on the engine. Cancelling one withdraws the coordinator's
    /// interest, which a build another connection asked for outlives.
    private var buildRequests: [String: BuildRequest] = [:] {
        didSet {
            let imagePaths = Set(buildRequests.keys)
            if imagePaths != followedImagePaths {
                followedImagePaths = imagePaths
            }
        }
    }

    private var nextBuildRequestIdentifier: UInt64 = 0

    /// The reads of stored corpora under way, by identifier.
    private var restoreRequests: [UInt64: RestoreRequest] = [:]

    private var nextRestoreRequestIdentifier: UInt64 = 0

    /// The engine's indexing events, followed for the Always Index batches
    /// that start: their images still to index are read first.
    private var alwaysIndexBatchSubscriptionTask: Task<Void, Never>?

    private var transformerRebuildTask: Task<Void, Never>?

    /// Images the coordinator asked to build of the engine's process, so a
    /// transformer change knows what to rebuild.
    private var requestedImagePaths: Set<String> = []

    /// Images the coordinator was asked to read from the derived data of the
    /// engine's process (`restoreCorpora(of:)`), so the switch going back on
    /// and a transformer change know what to read again: a build request
    /// cannot bring back one that is not indexed, which the engine refuses
    /// before it reads anything.
    private var requestedRestoreImagePaths: Set<String> = []

    /// The coverage refresh in flight, if any. One at a time: a call made
    /// while it runs only sets `isCoverageRefreshPending`.
    private var coverageRefreshTask: Task<Void, Never>?

    /// A refresh was asked for while one ran; it runs once that one is done.
    private var isCoverageRefreshPending = false

    /// The refresh `scheduleCoverageRefreshWhileOthersBuild()` has waiting.
    private var unfollowedBuildRefreshTask: Task<Void, Never>?

    /// Round trips `refreshCoverage()` has made. Test seam.
    private(set) var coverageFetchCount = 0

    /// Fetches of the engine's indexed images that
    /// `requestBuildOfIndexedImages()` started and that have not answered.
    private var indexedImageFetchesUnderWay = 0

    /// Whether the coordinator still has anything of its own in flight: a
    /// build request, a fetch of the indexed images about to turn into build
    /// requests, a coverage refresh or one queued behind it. Test seam: a
    /// test that sets states itself waits for this to be `false` first, or
    /// the coordinator's own work, landing later, writes over them.
    var hasWorkUnderWay: Bool {
        !buildRequests.isEmpty || !restoreRequests.isEmpty || indexedImageFetchesUnderWay > 0 || coverageRefreshTask != nil || isCoverageRefreshPending
    }

    private let progressStaging = ProgressStaging()

    private let corpusBuiltRelay = PublishRelay<String>()

    private let corporaRebuiltRelay = PublishRelay<Void>()

    /// The last document on the engine left; see `close()`.
    private var isClosed = false

    #if canImport(RuntimeViewerSettings)
    @Dependency(\.settings)
    private var settings

    private var lastKnownIsEnabled = true

    private var lastKnownTransformer = Transformer.Configuration.default

    private var lastKnownResidentByteLimit = 0
    #endif

    /// Where each image's corpus stands as the coordinator follows it: the
    /// images it asked for, from `.pending` to `.built` or `.failed`, and the
    /// rest as the engine last reported them. An absent image is unbuilt.
    @RxObserved
    public private(set) var buildStatesByImagePath: [String: RuntimeInterfaceCorpusBuildState] = [:]

    /// The engine's process does not know the corpus commands: a peer older
    /// than the Find navigator, or one a relay forwards to. Nothing is asked
    /// of it until the engine is swapped, and the Report navigator and the
    /// Find summary can say why instead of listing one failure per image.
    @RxObserved
    public private(set) var isCorpusUnsupportedByEngine: Bool = false

    /// Builds that ended, newest first, at most `maximumFinishedBuildCount`
    /// of them — what every window on the engine lists. Corpora built for
    /// another connection, or before the coordinator started, come after the
    /// ones it saw end: the engine does not say when they were built.
    @RxObserved
    public private(set) var finishedBuilds: [FindCorpusFinishedBuild] = []

    /// The images the coordinator holds a build request for, for every
    /// document on the engine: the corpus rows the Report navigator can
    /// cancel. Every other active state came from a coverage snapshot — a
    /// build another connection to the engine's process asked for — and the
    /// coordinator can neither follow its progress nor withdraw it.
    @RxObserved
    public private(set) var followedImagePaths: Set<String> = []

    /// Every image that has had a place in `finishedBuilds`, kept through
    /// `clearFinishedBuilds()`: a coverage snapshot lists only corpora the
    /// coordinator has never listed, or a cleared entry would come back with
    /// the next refresh. An image leaves once its corpus is gone from the
    /// engine, so a corpus rebuilt after an eviction is listed again.
    private var imagePathsListedInHistory: Set<String> = []

    /// The images whose corpus the engine's process read from derived data
    /// rather than printed, each with what reading it took — the Report
    /// navigator's Restored from Derived Data group. Read by the coordinator's
    /// own restores, or learned from the engine's coverage, which also says
    /// when a corpus read that way is gone: evicted, or printed again. Clear
    /// History empties it; the engine starting over, the switch going off and
    /// a transformer change too, as their corpora go.
    @RxObserved
    public private(set) var restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage] = [:]

    /// Every image that has had a place in `restoredImagesByImagePath`, kept
    /// through `clearFinishedBuilds()` for the reason `imagePathsListedInHistory`
    /// is. An image leaves once the engine no longer counts its corpus as
    /// read from derived data.
    private var imagePathsListedAsRestored: Set<String> = []

    /// The images a restore is reading. A restore under way is work in
    /// progress, like a build: the app waits on the engine's process for it.
    @RxObserved
    private(set) var restoringImagePaths: Set<String> = []

    /// An image's path, each time a request of the coordinator ends with the
    /// image's corpus built.
    public var corpusBuilt: Signal<String> {
        corpusBuiltRelay.asSignal()
    }

    /// Every corpus was dropped to be printed again under a new transformer,
    /// and the rebuilds are requested. A search on screen read the old
    /// prints, and the images being rebuilt are ones it has already read, so
    /// it has to run again rather than widen.
    var corporaRebuilt: Signal<Void> {
        corporaRebuiltRelay.asSignal()
    }

    /// Whether an image is waiting for its corpus, being printed, or being
    /// read from derived data.
    public var hasActiveBuild: Driver<Bool> {
        Driver.combineLatest($buildStatesByImagePath.asDriver(), $restoringImagePaths.asDriver()) { states, restoringImagePaths in
            states.values.contains(where: \.isActive) || !restoringImagePaths.isEmpty
        }
        .distinctUntilChanged()
    }

    /// Brought into being by `RuntimeEngineBackgroundWork` for its engine. A
    /// document's Find session follows it through the document's
    /// `RuntimeEngineSession`, and `DocumentState` tells it which image the
    /// document's sidebar shows.
    init(engine: RuntimeEngine) {
        self.engine = engine
        #if canImport(RuntimeViewerSettings)
        bootstrapSettingsObservation()
        #endif
        observeEngineReadiness()
        startPumps()
    }

    deinit {
        transformerRebuildTask?.cancel()
        coverageRefreshTask?.cancel()
        unfollowedBuildRefreshTask?.cancel()
        alwaysIndexBatchSubscriptionTask?.cancel()
        for request in buildRequests.values {
            request.task.cancel()
        }
        for request in restoreRequests.values {
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
        guard isEnabled, !isClosed, !isCorpusUnsupportedByEngine else { return }
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
                    guard let self else { return }
                    stageProgress(progress, for: imagePath, requestIdentifier: identifier)
                }
                result = .success(summary)
            } catch {
                result = .failure(error)
            }
            // After the await: the coordinator is not kept alive while the corpus builds.
            guard let self else { return }
            finishBuildRequest(identifier, of: imagePath, with: result)
        }
        buildRequests[imagePath] = BuildRequest(identifier: identifier, task: task)
    }

    /// Every image the engine has indexed, queued in one go — the switch
    /// turning on, or a fresh engine.
    public func requestBuildOfIndexedImages() {
        guard isEnabled, !isClosed, !isCorpusUnsupportedByEngine else { return }
        let engine = engine
        indexedImageFetchesUnderWay += 1
        Task { [weak self] in
            let imagePaths = try? await engine.indexedImagePathList()
            guard let self else { return }
            self.indexedImageFetchesUnderWay -= 1
            guard let imagePaths, !self.isClosed else { return }
            for imagePath in imagePaths {
                self.requestBuild(of: imagePath)
            }
        }
    }

    /// Reads, from the derived data of the engine's process, the corpora of
    /// those of `requestedImagePaths` not built or being read — the Always
    /// Index images, as their batches are dispatched — so a search finds them
    /// before they are indexed. An image read is handled as a build that
    /// finished: built, reported through `corpusBuilt`; it is listed in
    /// `restoredImagesByImagePath` rather than among the builds. Every image
    /// asked for, while the switch was off too, is read again when the switch
    /// goes back on, and when a transformer change asks for its build and the
    /// engine refuses it as not indexed. An engine whose process keeps no
    /// derived data, or predates the command, reads nothing, and an image
    /// nothing is stored for is left to the build its indexing will ask for.
    /// Paths may be spelled either way; see `canonicalImagePath(_:)`.
    func restoreCorpora(of requestedImagePaths: [String]) {
        guard !isClosed else { return }
        let canonicalImagePaths = Set(requestedImagePaths.map(canonicalImagePath))
        requestedRestoreImagePaths.formUnion(canonicalImagePaths)
        guard isEnabled, !isCorpusUnsupportedByEngine else { return }
        let imagePaths = canonicalImagePaths.filter { imagePath in
            buildStatesByImagePath[imagePath]?.isBuilt != true && !restoringImagePaths.contains(imagePath)
        }
        guard !imagePaths.isEmpty else { return }
        nextRestoreRequestIdentifier += 1
        let identifier = nextRestoreRequestIdentifier
        let engine = engine
        let transformer = currentTransformer
        restoringImagePaths.formUnion(imagePaths)
        let task = Task { [weak self] in
            let start = Date()
            let result = await Self.restoreInterfaceCorpora(of: imagePaths.sorted(), transformer: transformer, on: engine)
            // After the await: the coordinator is not kept alive while the corpora are read.
            guard let self else { return }
            finishRestoreRequest(identifier, result: result, duration: Date().timeIntervalSince(start))
        }
        restoreRequests[identifier] = RestoreRequest(task: task, imagePaths: imagePaths)
    }

    /// The engine's restore, measured from the request to its answer —
    /// every image of the request in the store or found missing.
    private nonisolated static func restoreInterfaceCorpora(
        of imagePaths: [String],
        transformer: Transformer.Configuration,
        on engine: RuntimeEngine
    ) async -> RuntimeInterfaceCorpusRestoreResult? {
        await #signpostInterval("Restore corpora from derived data") {
            try? await engine.restoreInterfaceCorpora(for: imagePaths, transformer: transformer)
        }
    }

    private func finishRestoreRequest(_ identifier: UInt64, result: RuntimeInterfaceCorpusRestoreResult?, duration: TimeInterval) {
        // A restore withdrawn — the coordinator closing, the engine coming
        // back, the switch going off, a transformer change — has nothing left
        // to report here.
        guard let request = restoreRequests.removeValue(forKey: identifier) else { return }
        restoringImagePaths.subtract(request.imagePaths)
        let restoredImages = result?.restoredImagesByImagePath ?? [:]
        var states = buildStatesByImagePath
        for (imagePath, restoredImage) in restoredImages {
            requestedImagePaths.insert(imagePath)
            if buildRequests[imagePath] == nil {
                states[imagePath] = .built(restoredImage.summary)
            }
        }
        if states != buildStatesByImagePath {
            buildStatesByImagePath = states
        }
        recordRestoredImages(restoredImages)
        for imagePath in restoredImages.keys.sorted() {
            corpusBuiltRelay.accept(imagePath)
        }
        let readings = restoredImages
            .sorted { $0.key < $1.key }
            .map { "\(FindScope.imageName(of: $0.key)) \(String(format: "%.3f", $0.value.duration)) s" }
            .joined(separator: ", ")
        #log(.info, "Read \(restoredImages.count, privacy: .public) of \(request.imagePaths.count, privacy: .public) corpora from derived data in \(String(format: "%.3f", duration), privacy: .public) s: \(readings, privacy: .public)")
        if !restoredImages.isEmpty {
            refreshCoverage()
        }
    }

    private func recordRestoredImages(_ restoredImages: [String: RuntimeInterfaceCorpusRestoredImage]) {
        guard !restoredImages.isEmpty else { return }
        var listedImages = restoredImagesByImagePath
        for (imagePath, restoredImage) in restoredImages {
            listedImages[imagePath] = restoredImage
            imagePathsListedAsRestored.insert(imagePath)
        }
        restoredImagesByImagePath = listedImages
    }

    /// Withdraws every restore under way; what each was reading is left to
    /// the builds.
    private func withdrawEveryRestore() {
        for request in restoreRequests.values {
            request.task.cancel()
        }
        restoreRequests.removeAll()
        if !restoringImagePaths.isEmpty {
            restoringImagePaths = []
        }
    }

    /// Forgets every corpus read from derived data: they went with the
    /// engine's process, the switch, or the transformer.
    private func forgetRestoredImages() {
        imagePathsListedAsRestored.removeAll()
        if !restoredImagesByImagePath.isEmpty {
            restoredImagesByImagePath = [:]
        }
    }

    /// Withdraws the request for `imagePath` — the Report navigator's Cancel,
    /// in whichever window on the engine. A build another connection asked
    /// for goes on for it, and the withdrawal is not sticky: the next trigger
    /// for the image asks again.
    public func cancelBuild(of requestedImagePath: String) {
        let imagePath = canonicalImagePath(requestedImagePath)
        guard let request = buildRequests.removeValue(forKey: imagePath) else { return }
        request.task.cancel()
        buildStatesByImagePath[imagePath] = nil
        recordFinishedBuild(FindCorpusFinishedBuild(imagePath: imagePath, outcome: .cancelled, finishedAt: Date()))
    }

    /// The last document on the engine left — closed, or moved to another
    /// engine: every request is withdrawn — over a connection each withdrawal
    /// reaches the serving process as a `cancelRequest` — and nothing asks for
    /// a corpus again, not an image the engine indexes, not a settings change,
    /// not the engine coming back. Its builds go with it; the next document on
    /// the engine gets a coordinator of its own. A `DocumentState` that held
    /// this coordinator can outlive its window, so `deinit` is too late to
    /// count on. `RuntimeEngineBackgroundWork` calls this.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        stopPumps()
        engineReadinessSubscription = nil
        withdrawEveryBuild()
        withdrawEveryRestore()
    }

    /// The image the sidebar of `document` lists, as the sidebar spells it,
    /// or `nil` once it lists none — the document went to the image list, to
    /// another engine, or closed.
    func setOnScreenImagePath(_ imagePath: String?, ofDocument document: ObjectIdentifier) {
        onScreenImagePathsByDocument[document] = imagePath
    }

    /// The image the sidebar of `document` lists, as the last
    /// `setOnScreenImagePath(_:ofDocument:)` left it. Test seam.
    func onScreenImagePath(ofDocument document: ObjectIdentifier) -> String? {
        onScreenImagePathsByDocument[document]
    }

    /// Empties `finishedBuilds` and `restoredImagesByImagePath`. The corpora
    /// listed so far stay off them: a later coverage snapshot does not bring
    /// them back.
    public func clearFinishedBuilds() {
        finishedBuilds = []
        if !restoredImagesByImagePath.isEmpty {
            restoredImagesByImagePath = [:]
        }
    }

    /// Asks the engine where every corpus stands and folds the answer in —
    /// see `mergeCoverage(_:)`. Runs on start and after every build; the
    /// Report navigator calls it when it appears, because the store evicts
    /// without telling anyone.
    ///
    /// One round trip at a time: calls made while one is in flight coalesce
    /// into a single one after it, which still answers for the latest call.
    /// Requests that end together — every corpus already built when the
    /// coordinator starts — cost two round trips, not one each.
    public func refreshCoverage() {
        guard coverageRefreshTask == nil else {
            isCoverageRefreshPending = true
            return
        }
        let engine = engine
        coverageFetchCount += 1
        coverageRefreshTask = Task { [weak self] in
            let coverage = try? await engine.interfaceCorpusCoverage()
            // Cancelled by the engine coming back or the coordinator closing:
            // the answer is about a process that is gone, and a refresh of the
            // new one may be under way already. An identity check would not
            // do: the engine is the same.
            guard let self, !Task.isCancelled else { return }
            self.coverageRefreshTask = nil
            if let coverage {
                self.mergeCoverage(coverage)
            }
            if self.isCoverageRefreshPending {
                self.isCoverageRefreshPending = false
                self.refreshCoverage()
            }
        }
    }

    private func cancelCoverageRefresh() {
        coverageRefreshTask?.cancel()
        coverageRefreshTask = nil
        isCoverageRefreshPending = false
        unfollowedBuildRefreshTask?.cancel()
        unfollowedBuildRefreshTask = nil
    }

    /// While a build the coordinator does not follow is under way, its row and
    /// the Report navigator's activity mark show the engine's last word on it,
    /// which nothing else refreshes. Asks again every two seconds until no such
    /// build is left; the engine coming back or the coordinator closing stops
    /// it.
    private func scheduleCoverageRefreshWhileOthersBuild() {
        let hasUnfollowedActiveBuild = buildStatesByImagePath.contains { imagePath, state in
            state.isActive && buildRequests[imagePath] == nil
        }
        guard hasUnfollowedActiveBuild, isEnabled, !isClosed else {
            unfollowedBuildRefreshTask?.cancel()
            unfollowedBuildRefreshTask = nil
            return
        }
        guard unfollowedBuildRefreshTask == nil else { return }
        unfollowedBuildRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.unfollowedBuildCoverageRefreshIntervalNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.unfollowedBuildRefreshTask = nil
            self.refreshCoverage()
        }
    }

    /// Squares the coordinator's states with what a finished search could not
    /// read. The store evicts without telling anyone, so an image the
    /// coordinator still believes built may be gone: its state goes. The
    /// images of the search's scope are asked for first. With every indexed
    /// image in scope, only images the coordinator never asked for are: those
    /// are the ones it was never told about — indexed in the serving process
    /// without this engine's API — while asking again for every evicted one would,
    /// with a budget too small for them all, rebuild on each search what the
    /// budget just evicted. Paths may be spelled either way; see
    /// `canonicalImagePath(_:)`.
    func reconcile(unbuiltIndexedImagePaths: [String], scopeImagePaths: Set<String>?) {
        guard isEnabled, !isClosed, !isCorpusUnsupportedByEngine else { return }
        let unbuiltImagePaths = unbuiltIndexedImagePaths
            .map(canonicalImagePath)
            .filter { buildRequests[$0] == nil }
        var states = buildStatesByImagePath
        for imagePath in unbuiltImagePaths where states[imagePath]?.isBuilt == true {
            states[imagePath] = nil
        }
        if states != buildStatesByImagePath {
            buildStatesByImagePath = states
        }
        let canonicalScopeImagePaths = scopeImagePaths.map { Set($0.map(canonicalImagePath)) }
        for imagePath in unbuiltImagePaths {
            if let canonicalScopeImagePaths {
                if canonicalScopeImagePaths.contains(imagePath) {
                    requestBuild(of: imagePath, isPrioritized: true)
                }
            } else if !requestedImagePaths.contains(imagePath) {
                requestBuild(of: imagePath)
            }
        }
    }

    /// Withdraws every request the coordinator holds, leaving the images they
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
        withdrawEveryRestore()
        forgetRestoredImages()
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
            guard let self else { return }
            flushProgress()
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
            // A corpus that was already there — or that the engine read from
            // derived data — comes back without a single progress report; it
            // is not a build the coordinator saw.
            if hasReportedProgress {
                recordFinishedBuild(FindCorpusFinishedBuild(imagePath: imagePath, outcome: .built(summary), finishedAt: Date()))
                if restoredImagesByImagePath[imagePath] != nil {
                    restoredImagesByImagePath[imagePath] = nil
                }
                imagePathsListedAsRestored.remove(imagePath)
            }
            corpusBuiltRelay.accept(imagePath)
            refreshCoverage()
        case .failure(is CancellationError):
            // The store cancelled the build for everyone: another connection
            // asked for it under a different transformer, or evicted it.
            buildStatesByImagePath[imagePath] = nil
        case .failure(is RuntimeInterfaceCorpusBuildError):
            // Not indexed yet: nothing to print, and nothing went wrong. The
            // image is asked for again once the engine reports it indexed —
            // and, if it is one to read from derived data, read now: the
            // engine refuses the build before it reads anything, and a
            // transformer change asks for a build of every image, the ones
            // read included.
            buildStatesByImagePath[imagePath] = nil
            if requestedRestoreImagePaths.contains(imagePath) {
                restoreCorpora(of: [imagePath])
            }
        case .failure(let error) where RuntimeConnectionError.isLostConnection(error):
            // Not a failed build: the connection went away under it — the
            // service exited, the peer closed its socket. Once the engine is
            // back, the coordinator starts over on it and asks again for every
            // image its process has indexed.
            #log(.info, "Corpus build of \(imagePath, privacy: .public) was interrupted: the connection went away (\(error, privacy: .public))")
            buildStatesByImagePath[imagePath] = nil
        case .failure(let error as RuntimeNetworkRequestError) where error.isUnknownCommand:
            // Not a failed build: the peer predates corpora. Every request
            // would fail the same way, so none is kept and none is made again
            // until the engine is swapped.
            #log(.info, "The engine's process does not know the corpus commands; corpora are off for it")
            withdrawEveryBuild()
            buildStatesByImagePath = [:]
            isCorpusUnsupportedByEngine = true
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

    /// Folds the engine's coverage into what the coordinator shows. An image
    /// it holds a request for keeps the state its request reports, and so
    /// does an image it is reading from derived data, which the engine counts
    /// as a build waiting for the printer; every other image takes the
    /// engine's word — a corpus built before the coordinator started or for
    /// another connection, one being built for another connection, or one
    /// evicted since, which would otherwise stay built here forever. Corpora
    /// that ended without the coordinator seeing them go to the end of the
    /// history, in path order.
    func mergeCoverage(_ coverage: RuntimeInterfaceCorpusCoverage) {
        var states = buildStatesByImagePath
        for imagePath in Set(states.keys).union(coverage.statesByImagePath.keys) where buildRequests[imagePath] == nil && !restoringImagePaths.contains(imagePath) {
            states[imagePath] = coverage.statesByImagePath[imagePath]
        }
        if states != buildStatesByImagePath {
            buildStatesByImagePath = states
        }
        scheduleCoverageRefreshWhileOthersBuild()

        mergeRestoredImages(of: coverage)

        imagePathsListedInHistory.formIntersection(coverage.statesByImagePath.keys)
        let recordedImagePaths = Set(finishedBuilds.map(\.imagePath))
        let learnedBuilds = coverage.statesByImagePath
            .filter { imagePath, _ in
                buildRequests[imagePath] == nil
                    && coverage.restoredImagesByImagePath[imagePath] == nil
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
        // Remembered whether or not they fit: one that does not is older than
        // everything listed, so it is the one a full history drops — and one
        // never remembered would come back after Clear History.
        imagePathsListedInHistory.formUnion(learnedBuilds.map(\.imagePath))
        guard !learnedBuilds.isEmpty, finishedBuilds.count < Self.maximumFinishedBuildCount else { return }
        finishedBuilds = Array((finishedBuilds + learnedBuilds).prefix(Self.maximumFinishedBuildCount))
    }

    /// The corpora the engine says it read from derived data: one it no
    /// longer counts so — evicted, printed again — leaves the group, and one
    /// the coordinator never listed joins it. A corpus read that way is no
    /// build learned from elsewhere.
    private func mergeRestoredImages(of coverage: RuntimeInterfaceCorpusCoverage) {
        let coverageRestoredImages = coverage.restoredImagesByImagePath
        imagePathsListedAsRestored.formIntersection(coverageRestoredImages.keys)
        var listedImages = restoredImagesByImagePath.filter { coverageRestoredImages[$0.key] != nil }
        for (imagePath, restoredImage) in coverageRestoredImages where !imagePathsListedAsRestored.contains(imagePath) {
            listedImages[imagePath] = restoredImage
            imagePathsListedAsRestored.insert(imagePath)
        }
        if listedImages != restoredImagesByImagePath {
            restoredImagesByImagePath = listedImages
        }
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
                    guard let self, !self.isClosed else { return }
                    self.imageDidIndex(at: imagePath)
                }
            }
        followAlwaysIndexBatches()
        requestBuildOfIndexedImages()
        // What the engine's process has built or is building already: before
        // the coordinator started, or for another connection.
        refreshCoverage()
        #if canImport(RuntimeViewerSettings)
        applyResidentByteLimit()
        #endif
    }

    private func stopPumps() {
        imageIndexedSubscription = nil
        alwaysIndexBatchSubscriptionTask?.cancel()
        alwaysIndexBatchSubscriptionTask = nil
        transformerRebuildTask?.cancel()
        transformerRebuildTask = nil
        cancelCoverageRefresh()
    }

    /// Every Always Index batch that starts has its images still waiting to
    /// be indexed read from derived data first: the dependencies of a row that
    /// follows them, which the rows' own paths, handed over as they are
    /// dispatched, do not include. The events are read off the main actor —
    /// the indexer sends one per image started and finished — and only an
    /// Always Index batch's start comes back to it.
    private func followAlwaysIndexBatches() {
        let engine = engine
        alwaysIndexBatchSubscriptionTask = Task.detached { [weak self] in
            for await event in await engine.backgroundIndexingManager.events {
                guard case .batchStarted(let batch) = event, batch.reason.category == .alwaysIndex else { continue }
                let imagePaths = batch.items.compactMap { item -> String? in
                    guard case .pending = item.state else { return nil }
                    return item.resolvedPath
                }
                guard !imagePaths.isEmpty else { continue }
                await MainActor.run { [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.restoreCorpora(of: imagePaths)
                }
            }
        }
    }

    /// An image the engine reports indexed. One with a request open is left
    /// to it, one already built needs nothing; an image a sidebar on the
    /// engine shows goes to the front of the queue, every other one — an
    /// export's, the background indexer's — waits its turn.
    private func imageDidIndex(at reportedImagePath: String) {
        let imagePath = canonicalImagePath(reportedImagePath)
        let isOnScreen = onScreenImagePathsByDocument.values.contains { canonicalImagePath($0) == imagePath }
        if buildRequests[imagePath] == nil, buildStatesByImagePath[imagePath]?.isBuilt == true {
            return
        }
        requestBuild(of: imagePath, isPrioritized: isOnScreen)
    }

    // MARK: - The engine coming back

    /// Follows the engine's readiness. A `false → true` edge is a new process
    /// behind the engine — the local runtime service relaunched, a peer
    /// reconnected, the engine's first connection — heard from the engine
    /// itself, whatever its documents have open, so a search run again on the
    /// new process finds the coordinator on it already.
    private func observeEngineReadiness() {
        engineWasReady = engine.state.isReady
        engineReadinessSubscription = engine.statePublisher
            .map(\.isReady)
            .sink { [weak self] isReady in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleEngineReadinessChange(isReady)
                }
            }
    }

    private func handleEngineReadinessChange(_ isReady: Bool) {
        guard !isClosed else { return }
        let becameReadyAgain = isReady && !engineWasReady
        engineWasReady = isReady
        guard becameReadyAgain else { return }
        engineDidReset()
    }

    /// The process behind the engine has corpora of its own, so the states
    /// start over and every image it has indexed is asked for again — an
    /// image whose build a lost connection interrupted among them, while the
    /// process still has it. The history stays: it reads as what was built on
    /// the engine, like the indexing history.
    private func engineDidReset() {
        stopPumps()
        withdrawEveryBuild()
        withdrawEveryRestore()
        forgetRestoredImages()
        isCorpusUnsupportedByEngine = false
        _ = progressStaging.drain()
        buildStatesByImagePath = [:]
        requestedImagePaths.removeAll()
        requestedRestoreImagePaths.removeAll()
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
                // A closed coordinator stops listening.
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
                // The images read before are not all indexed, and those that
                // are not have nothing to print from.
                restoreCorpora(of: Array(requestedRestoreImagePaths))
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
    /// settle, drop them all and rebuild the ones the coordinator asked for.
    /// The ones read from derived data are among them: those not indexed are
    /// refused and read again instead (`finishBuildRequest`), which finds
    /// nothing after an edit — derived data keeps one variant per image —
    /// but the old variant once the edit is taken back.
    private func scheduleTransformerRebuild() {
        transformerRebuildTask?.cancel()
        let engine = engine
        transformerRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.transformerRebuildDelayNanoseconds)
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            let imagePaths = self.requestedImagePaths
            self.withdrawEveryBuild()
            self.withdrawEveryRestore()
            self.forgetRestoredImages()
            try? await engine.evictInterfaceCorpus(for: nil)
            guard !Task.isCancelled, !self.isClosed else { return }
            self.buildStatesByImagePath = [:]
            for imagePath in imagePaths {
                self.requestBuild(of: imagePath)
            }
            // After the requests, so a search run again at once finds its
            // images queued.
            self.corporaRebuiltRelay.accept(())
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

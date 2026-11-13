import Combine
import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerCrossReferences
import RuntimeViewerArchitectures
import RuntimeViewerSettings

/// Keeps the engine's prepared cross references in step with what the engine
/// has indexed, so Call Hierarchy and Type References — in the Find navigator
/// and the Inspector — answer from what was read ahead instead of scanning.
///
/// The counterpart of `FindCorpusCoordinator` for cross references, and built
/// the same way: one per engine, shared by every document on the engine (see
/// `RuntimeEngineBackgroundWork`). The preparing itself — at most Max
/// Concurrent Scans images at a time, behind the queries, at utility
/// priority, one preparation per image whoever asks — is the engine's process
/// (`prepareCrossReferences(forImageAt:options:reportProgress:)`); this
/// coordinator decides *which* images to ask for and *when*:
///
/// 1. every image the engine's API indexed (`RuntimeEngine.imageDidIndexPublisher`);
/// 2. every image indexed before the coordinator started listening, once;
/// 3. Keep Cross References Ready turning on, for every indexed image.
///
/// The preparations fill the resident limit and evict nothing for it
/// (proposal `on-demand-corpora-and-cross-references`): the images indexed
/// at once are asked for in the order of the Always Index rows, the others
/// after them, and the first image that comes back not kept — it did not
/// fit in the room left — stops them. The requests still open are withdrawn,
/// and none is made until something makes room: the limit changing, Eject,
/// the switch going back on, a new process behind the engine. Every image
/// not prepared, and one dropped past the limit, is prepared by the first
/// query that needs it.
///
/// Turning it off withdraws every request and drops every prepared image; a
/// query then scans as it did before. The engine coming back with a new
/// process behind it starts the coordinator over.
///
/// A shared cache image the engine borrows is not this coordinator's: its
/// owner prepares it, and a query that needs it is answered there, so none of
/// the triggers above asks for it.
///
/// `preparationStatesByImagePath` takes every image it asked for from queued
/// to prepared or failed, progress published at most once a frame, and
/// `finishedPreparations` keeps the preparations that ended. The Report
/// navigator lists both.
@MainActor
@Loggable(.private)
public final class CrossReferencePreparationCoordinator {
    /// Most finished preparations kept, newest first — the cap of the other
    /// histories.
    static let maximumFinishedPreparationCount = 100

    /// One frame at 60 Hz: the reports of one frame are published together.
    static let progressCoalescingWindowNanoseconds: UInt64 = 16_000_000

    /// A preparation request the coordinator holds open. The identifier tells
    /// a request apart from the one that replaced it after a withdrawal.
    private struct PreparationRequest {
        let identifier: UInt64
        let task: Task<Void, Never>
    }

    private let engine: RuntimeEngine

    private var imageIndexedSubscription: AnyCancellable?

    /// Whether the engine was ready when last heard from, so a `false → true`
    /// edge — a new process behind the engine — can be told from the state
    /// replayed on subscribing.
    private var engineWasReady = false

    private var engineReadinessSubscription: AnyCancellable?

    /// The engine's shared cache owners changing; see
    /// `sharedCacheOwnersDidChange()`.
    private var sharedCacheOwnersSubscription: AnyCancellable?

    private var preparationRequests: [String: PreparationRequest] = [:] {
        didSet {
            let imagePaths = Set(preparationRequests.keys)
            if imagePaths != followedImagePaths {
                followedImagePaths = imagePaths
            }
        }
    }

    private var nextRequestIdentifier: UInt64 = 0

    /// Fetches of the engine's indexed images that have not answered.
    private var indexedImageFetchesUnderWay = 0

    /// Whether the coordinator still has anything of its own in flight. Test
    /// seam.
    var hasWorkUnderWay: Bool {
        !preparationRequests.isEmpty || indexedImageFetchesUnderWay > 0
    }

    private let progressStaging = ProgressStaging()

    /// The last document on the engine left; see `close()`.
    private var isClosed = false

    @Dependency(\.settings)
    private var settings

    private var lastKnownIsEnabled = true

    private var lastKnownResidentByteLimit = 0

    /// A preparation came back not kept: the resident limit is full, and no
    /// image is asked for until something makes room.
    private(set) var isResidentLimitFull = false

    /// Where each Always Index image comes among the rows, as the indexing
    /// coordinator resolves them: the images indexed at once are asked for in
    /// this order, ahead of the others.
    private var alwaysIndexPositions: [String: Int] = [:]

    /// The images the coordinator asked for, from `.pending` to `.prepared`
    /// or `.failed`. An absent image is not prepared, or not followed.
    @RxObserved
    public private(set) var preparationStatesByImagePath: [String: CrossReferencePreparationState] = [:]

    /// The engine's process does not know the preparation command: a peer
    /// older than it. Nothing is asked of it until the engine is swapped.
    @RxObserved
    public private(set) var isUnsupportedByEngine: Bool = false

    /// Preparations that ended, newest first, at most
    /// `maximumFinishedPreparationCount` of them.
    @RxObserved
    public private(set) var finishedPreparations: [CrossReferenceFinishedPreparation] = []

    /// The images the coordinator holds a request for: the rows the Report
    /// navigator can cancel.
    @RxObserved
    public private(set) var followedImagePaths: Set<String> = []

    /// What the engine's process keeps of prepared cross references, as their
    /// preparations estimated them — every image prepared, whoever asked: the
    /// size the Report navigator shows beside Cross References, and what
    /// `ejectPreparations()` frees. Asked of the engine as the coordinator
    /// starts, after each preparation and each eject, and whenever the Report
    /// navigator appears; `nil` before the first answer, and for a peer older
    /// than the question.
    @RxObserved
    public private(set) var preparedByteCount: Int?

    private var preparedByteCountRefreshTask: Task<Void, Never>?

    private var isPreparedByteCountRefreshPending = false

    /// Whether an image is waiting or being prepared.
    public var hasActivePreparation: Driver<Bool> {
        $preparationStatesByImagePath.asDriver()
            .map { states in states.values.contains(where: \.isActive) }
            .distinctUntilChanged()
    }

    /// Brought into being by `RuntimeEngineBackgroundWork` for its engine.
    init(engine: RuntimeEngine) {
        self.engine = engine
        bootstrapSettingsObservation()
        observeEngineReadiness()
        observeSharedCacheOwners()
        startPumps()
    }

    deinit {
        for request in preparationRequests.values {
            request.task.cancel()
        }
    }

    // MARK: - Settings read

    private var isEnabled: Bool {
        settings.search.isCrossReferencePreparationEnabled
    }

    private var preparationOptions: RuntimeCrossReferencePreparationOptions {
        RuntimeCrossReferencePreparationOptions(
            residentByteLimit: settings.search.crossReferenceResidentByteLimit,
            maximumConcurrentScans: settings.search.maximumConcurrentCrossReferenceScans,
            evictsNothing: true
        )
    }

    // MARK: - Paths

    /// `imagePath` as the engine keys it; every path the coordinator stores
    /// or reports is in this form.
    public func canonicalImagePath(_ imagePath: String) -> String {
        engine.canonicalImagePath(imagePath)
    }

    // MARK: - Triggers

    /// Asks the engine to prepare `requestedImagePath`'s cross references. An
    /// image with a request open, or prepared already, is not asked for again,
    /// and nothing is while the resident limit is full.
    public func requestPreparation(of requestedImagePath: String) {
        guard isEnabled, !isClosed, !isUnsupportedByEngine, !isResidentLimitFull else { return }
        let imagePath = canonicalImagePath(requestedImagePath)
        guard !engine.borrowsSharedCacheImage(at: imagePath) else { return }
        guard preparationRequests[imagePath] == nil, preparationStatesByImagePath[imagePath]?.isPrepared != true else { return }
        nextRequestIdentifier += 1
        let identifier = nextRequestIdentifier
        let engine = engine
        let options = preparationOptions
        preparationStatesByImagePath[imagePath] = .pending
        let task = Task { [weak self] in
            let result: Result<RuntimeCrossReferencePreparation, any Swift.Error>
            do {
                let preparation = try await engine.prepareCrossReferences(forImageAt: imagePath, options: options) { [weak self] progress in
                    guard let self else { return }
                    stageProgress(progress, for: imagePath, requestIdentifier: identifier)
                }
                result = .success(preparation)
            } catch {
                result = .failure(error)
            }
            // After the await: the coordinator is not kept alive while the image is prepared.
            guard let self else { return }
            finishPreparationRequest(identifier, of: imagePath, with: result)
        }
        preparationRequests[imagePath] = PreparationRequest(identifier: identifier, task: task)
    }

    /// Every image the engine has indexed, asked for in one go — the switch
    /// turning on, a fresh engine, room made — the Always Index ones first,
    /// in the order of their rows.
    public func requestPreparationOfIndexedImages() {
        guard isEnabled, !isClosed, !isUnsupportedByEngine, !isResidentLimitFull else { return }
        let engine = engine
        indexedImageFetchesUnderWay += 1
        Task { [weak self] in
            let imagePaths = try? await engine.indexedImagePathList()
            guard let self else { return }
            indexedImageFetchesUnderWay -= 1
            guard let imagePaths, !isClosed else { return }
            for imagePath in preparationOrder(of: imagePaths) {
                requestPreparation(of: imagePath)
            }
        }
    }

    /// Records the images the Always Index rows resolve to, as a pass
    /// dispatches them; an image already placed keeps its place.
    func noteAlwaysIndexImagePaths(_ imagePaths: [String]) {
        for imagePath in imagePaths.map(canonicalImagePath) where alwaysIndexPositions[imagePath] == nil {
            alwaysIndexPositions[imagePath] = alwaysIndexPositions.count
        }
    }

    /// `imagePaths`, canonical, the Always Index images first in the order
    /// of their rows, then the others by path.
    func preparationOrder(of imagePaths: [String]) -> [String] {
        imagePaths.map(canonicalImagePath).sorted { lhs, rhs in
            switch (alwaysIndexPositions[lhs], alwaysIndexPositions[rhs]) {
            case (let lhsPosition?, let rhsPosition?):
                lhsPosition < rhsPosition
            case (.some, .none):
                true
            case (.none, .some):
                false
            case (.none, .none):
                lhs < rhs
            }
        }
    }

    /// Withdraws the request for `imagePath` — the Report navigator's Cancel.
    /// A query waiting for the image keeps its preparation going, and the
    /// withdrawal is not sticky: the next trigger for the image asks again.
    public func cancelPreparation(of requestedImagePath: String) {
        let imagePath = canonicalImagePath(requestedImagePath)
        guard let request = preparationRequests.removeValue(forKey: imagePath) else { return }
        request.task.cancel()
        preparationStatesByImagePath[imagePath] = nil
        recordFinishedPreparation(CrossReferenceFinishedPreparation(imagePath: imagePath, outcome: .cancelled, finishedAt: Date()))
    }

    /// Empties `finishedPreparations`.
    public func clearFinishedPreparations() {
        finishedPreparations = []
    }

    /// The Report navigator's Eject on Cross References: the engine's process
    /// drops every prepared image, with the names read for it, and its limit
    /// goes back to what Settings say, so what a query prepares from then on
    /// is kept again. Requests under way are withdrawn, and nothing is asked
    /// for again until something asks — a query, an image indexed from now
    /// on. The history stays. Nothing ejects on its own (proposal
    /// `engine-resident-memory`).
    public func ejectPreparations() {
        guard !isClosed else { return }
        withdrawEveryPreparation()
        preparationStatesByImagePath = [:]
        preparedByteCount = 0
        isResidentLimitFull = false
        let engine = engine
        let byteLimit = isEnabled ? settings.search.crossReferenceResidentByteLimit : 0
        Task { [weak self] in
            try? await engine.setPreparedCrossReferenceByteLimit(0)
            try? await engine.setPreparedCrossReferenceByteLimit(byteLimit)
            guard let self else { return }
            refreshPreparedByteCount()
        }
    }

    /// Asks the engine's process what it keeps of prepared cross references
    /// (`preparedByteCount`). One round trip at a time: calls made while one
    /// is in flight coalesce into a single one after it.
    public func refreshPreparedByteCount() {
        guard !isClosed else { return }
        guard preparedByteCountRefreshTask == nil else {
            isPreparedByteCountRefreshPending = true
            return
        }
        let engine = engine
        preparedByteCountRefreshTask = Task { [weak self] in
            let byteCount = try? await engine.preparedCrossReferenceByteCount()
            guard let self, !Task.isCancelled else { return }
            preparedByteCountRefreshTask = nil
            if preparedByteCount != byteCount {
                preparedByteCount = byteCount
            }
            if isPreparedByteCountRefreshPending {
                isPreparedByteCountRefreshPending = false
                refreshPreparedByteCount()
            }
        }
    }

    /// The last document on the engine left — closed, or moved to another
    /// engine: every request is withdrawn and nothing asks for a preparation
    /// again. `RuntimeEngineBackgroundWork` calls this.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        stopPumps()
        engineReadinessSubscription = nil
        withdrawEveryPreparation()
        cancelPreparedByteCountRefresh()
    }

    private func cancelPreparedByteCountRefresh() {
        preparedByteCountRefreshTask?.cancel()
        preparedByteCountRefreshTask = nil
        isPreparedByteCountRefreshPending = false
    }

    private func withdrawEveryPreparation() {
        for request in preparationRequests.values {
            request.task.cancel()
        }
        preparationRequests = [:]
        _ = progressStaging.drain()
        preparationStatesByImagePath = preparationStatesByImagePath.filter { !$0.value.isActive }
    }

    // MARK: - Shared cache owners

    /// Follows the engine manager giving the engine other owners, as the
    /// engine's corpus coordinator does.
    private func observeSharedCacheOwners() {
        sharedCacheOwnersSubscription = engine.sharedCacheOwnersPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    self.sharedCacheOwnersDidChange()
                }
            }
    }

    /// The requests for the images the engine borrows now are withdrawn — the
    /// owners prepare them — and every indexed image is asked for again,
    /// which brings back the images the engine no longer borrows.
    private func sharedCacheOwnersDidChange() {
        let borrowedImagePaths = preparationRequests.keys.filter { engine.borrowsSharedCacheImage(at: $0) }
        var states = preparationStatesByImagePath
        for imagePath in borrowedImagePaths {
            preparationRequests.removeValue(forKey: imagePath)?.task.cancel()
            if states[imagePath]?.isActive == true {
                states[imagePath] = nil
            }
        }
        if states != preparationStatesByImagePath {
            preparationStatesByImagePath = states
        }
        requestPreparationOfIndexedImages()
    }

    // MARK: - Preparation state

    /// Called from the engine's thread with each progress report; publishes
    /// at most once per `progressCoalescingWindowNanoseconds`.
    nonisolated private func stageProgress(_ progress: RuntimeCrossReferencePreparationProgress, for imagePath: String, requestIdentifier: UInt64) {
        guard progressStaging.record(progress, for: imagePath, requestIdentifier: requestIdentifier) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.progressCoalescingWindowNanoseconds)
            guard let self else { return }
            flushProgress()
        }
    }

    private func flushProgress() {
        var states = preparationStatesByImagePath
        for (imagePath, report) in progressStaging.drain() where preparationRequests[imagePath]?.identifier == report.requestIdentifier {
            states[imagePath] = .preparing(report.progress)
        }
        if states != preparationStatesByImagePath {
            preparationStatesByImagePath = states
        }
    }

    private func finishPreparationRequest(_ identifier: UInt64, of imagePath: String, with result: Result<RuntimeCrossReferencePreparation, any Swift.Error>) {
        // A request withdrawn — by the user, the switch going off, the engine
        // going away — has nothing left to report here.
        guard preparationRequests[imagePath]?.identifier == identifier else { return }
        preparationRequests[imagePath] = nil
        switch result {
        case .success(let preparation) where !preparation.isKept:
            preparationStatesByImagePath[imagePath] = nil
            recordFinishedPreparation(CrossReferenceFinishedPreparation(imagePath: imagePath, outcome: .notKept(preparation), finishedAt: Date()))
            residentLimitDidFill()
            refreshPreparedByteCount()
        case .success(let preparation):
            preparationStatesByImagePath[imagePath] = .prepared(preparation)
            recordFinishedPreparation(CrossReferenceFinishedPreparation(imagePath: imagePath, outcome: .prepared(preparation), finishedAt: Date()))
            refreshPreparedByteCount()
        case .failure(is CancellationError):
            preparationStatesByImagePath[imagePath] = nil
        case .failure(RuntimeCrossReferenceError.imageNotIndexed):
            // Nothing to read yet, and nothing went wrong: the image is asked
            // for again once the engine reports it indexed.
            preparationStatesByImagePath[imagePath] = nil
        case .failure(let error) where RuntimeConnectionError.isLostConnection(error):
            // The connection went away under it; once the engine is back, the
            // coordinator starts over and asks for every indexed image again.
            #log(.info, "Preparing the cross references of \(imagePath, privacy: .public) was interrupted: the connection went away (\(error, privacy: .public))")
            preparationStatesByImagePath[imagePath] = nil
        case .failure(let error as RuntimeNetworkRequestError) where error.isUnknownCommand:
            #log(.info, "The engine's process does not know the cross-reference preparation; it is off for it")
            withdrawEveryPreparation()
            preparationStatesByImagePath = [:]
            isUnsupportedByEngine = true
        case .failure(let error):
            #log(.error, "Preparing the cross references of \(imagePath, privacy: .public) failed: \(error, privacy: .public)")
            let message = error.localizedDescription
            preparationStatesByImagePath[imagePath] = .failed(message: message)
            recordFinishedPreparation(CrossReferenceFinishedPreparation(imagePath: imagePath, outcome: .failed(message: message), finishedAt: Date()))
        }
    }

    /// The first image that did not fit: the requests still open are
    /// withdrawn — what they read would not be kept either — and none is made
    /// until something makes room.
    private func residentLimitDidFill() {
        guard !isResidentLimitFull else { return }
        isResidentLimitFull = true
        #log(.info, "The resident limit of prepared cross references is full; the images not prepared are left to the queries that need them")
        withdrawEveryPreparation()
    }

    private func recordFinishedPreparation(_ finishedPreparation: CrossReferenceFinishedPreparation) {
        var preparations = finishedPreparations
        preparations.insert(finishedPreparation, at: 0)
        if preparations.count > Self.maximumFinishedPreparationCount {
            preparations.removeLast(preparations.count - Self.maximumFinishedPreparationCount)
        }
        finishedPreparations = preparations
    }

    // MARK: - Pumps

    private func startPumps() {
        // Subscribed before asking, so no image slips through in between.
        imageIndexedSubscription = engine.imageDidIndexPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] imagePath in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    self.requestPreparation(of: imagePath)
                }
            }
        applyResidentByteLimit()
        requestPreparationOfIndexedImages()
    }

    private func stopPumps() {
        imageIndexedSubscription = nil
    }

    // MARK: - The engine coming back

    private func observeEngineReadiness() {
        engineWasReady = engine.state.isReady
        engineReadinessSubscription = engine.statePublisher
            .map(\.isReady)
            .sink { [weak self] isReady in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    handleEngineReadinessChange(isReady)
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

    /// The process behind the engine has prepared nothing yet, so the states
    /// start over and every image it has indexed is asked for again. The
    /// history stays.
    private func engineDidReset() {
        stopPumps()
        withdrawEveryPreparation()
        cancelPreparedByteCountRefresh()
        isUnsupportedByEngine = false
        isResidentLimitFull = false
        preparationStatesByImagePath = [:]
        preparedByteCount = nil
        startPumps()
    }

    // MARK: - Settings

    private func bootstrapSettingsObservation() {
        lastKnownIsEnabled = settings.search.isCrossReferencePreparationEnabled
        lastKnownResidentByteLimit = settings.search.crossReferenceResidentByteLimit
        subscribeToSettings()
    }

    private func subscribeToSettings() {
        withObservationTracking {
            _ = settings.search.isCrossReferencePreparationEnabled
            _ = settings.search.crossReferenceResidentByteLimitMegabytes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // A closed coordinator stops listening.
                guard let self, !isClosed else { return }
                handleSettingsChange()
                subscribeToSettings()
            }
        }
    }

    private func handleSettingsChange() {
        let isEnabledNow = settings.search.isCrossReferencePreparationEnabled
        let residentByteLimit = settings.search.crossReferenceResidentByteLimit
        if isEnabledNow != lastKnownIsEnabled {
            lastKnownIsEnabled = isEnabledNow
            lastKnownResidentByteLimit = residentByteLimit
            isResidentLimitFull = false
            if isEnabledNow {
                applyResidentByteLimit()
                requestPreparationOfIndexedImages()
            } else {
                withdrawEveryPreparation()
                preparationStatesByImagePath = [:]
                applyResidentByteLimit()
            }
            return
        }
        if residentByteLimit != lastKnownResidentByteLimit {
            lastKnownResidentByteLimit = residentByteLimit
            applyResidentByteLimit()
            // Another limit may leave room: the images not prepared are asked
            // for again, and the first that does not fit stops them again.
            if isResidentLimitFull {
                isResidentLimitFull = false
                requestPreparationOfIndexedImages()
            }
        }
    }

    /// The engine's process keeps the limit while preparation is on, and
    /// nothing while it is off. A lower limit drops images, so the size is
    /// asked for again once the engine has the limit.
    private func applyResidentByteLimit() {
        let engine = engine
        let byteLimit = isEnabled ? settings.search.crossReferenceResidentByteLimit : 0
        Task { [weak self] in
            try? await engine.setPreparedCrossReferenceByteLimit(byteLimit)
            guard let self else { return }
            refreshPreparedByteCount()
        }
    }
}

// MARK: - Progress staging

extension CrossReferencePreparationCoordinator {
    /// Progress reports waiting for the next flush. Written from whichever
    /// thread the engine reports on, drained on the main actor, so the main
    /// thread wakes once a frame rather than once per report. Reports travel
    /// on their own and may arrive out of order, so a report behind one kept
    /// already is dropped. `@unchecked Sendable` because an `NSLock` guards it.
    fileprivate final class ProgressStaging: @unchecked Sendable {
        struct Report {
            let requestIdentifier: UInt64
            let progress: RuntimeCrossReferencePreparationProgress
        }

        private let lock = NSLock()

        private var reportsByImagePath: [String: Report] = [:]

        /// The furthest each request has reported, kept across flushes.
        private var furthestProgressByRequest: [UInt64: RuntimeCrossReferencePreparationProgress] = [:]

        private var hasScheduledFlush = false

        /// Keeps the furthest report for the image. `true` when the caller has
        /// to schedule the flush; one already scheduled will take this report.
        func record(_ progress: RuntimeCrossReferencePreparationProgress, for imagePath: String, requestIdentifier: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let furthest = furthestProgressByRequest[requestIdentifier], furthest.isAhead(of: progress) {
                return false
            }
            furthestProgressByRequest[requestIdentifier] = progress
            reportsByImagePath[imagePath] = Report(requestIdentifier: requestIdentifier, progress: progress)
            guard !hasScheduledFlush else { return false }
            hasScheduledFlush = true
            return true
        }

        func drain() -> [String: Report] {
            lock.lock()
            defer { lock.unlock() }
            let reports = reportsByImagePath
            reportsByImagePath.removeAll()
            hasScheduledFlush = false
            return reports
        }
    }
}

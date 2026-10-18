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
/// Turning it off withdraws every request and drops every prepared image; a
/// query then scans as it did before. The engine coming back with a new
/// process behind it starts the coordinator over. An image dropped past the
/// resident limit is not asked for again: the next query that needs it
/// prepares it.
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
            maximumConcurrentScans: settings.search.maximumConcurrentCrossReferenceScans
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
    /// image with a request open, or prepared already, is not asked for again.
    public func requestPreparation(of requestedImagePath: String) {
        guard isEnabled, !isClosed, !isUnsupportedByEngine else { return }
        let imagePath = canonicalImagePath(requestedImagePath)
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
    /// turning on, or a fresh engine.
    public func requestPreparationOfIndexedImages() {
        guard isEnabled, !isClosed, !isUnsupportedByEngine else { return }
        let engine = engine
        indexedImageFetchesUnderWay += 1
        Task { [weak self] in
            let imagePaths = try? await engine.indexedImagePathList()
            guard let self else { return }
            indexedImageFetchesUnderWay -= 1
            guard let imagePaths, !isClosed else { return }
            for imagePath in imagePaths {
                requestPreparation(of: imagePath)
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

    /// The last document on the engine left — closed, or moved to another
    /// engine: every request is withdrawn and nothing asks for a preparation
    /// again. `RuntimeEngineBackgroundWork` calls this.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        stopPumps()
        engineReadinessSubscription = nil
        withdrawEveryPreparation()
    }

    private func withdrawEveryPreparation() {
        for request in preparationRequests.values {
            request.task.cancel()
        }
        preparationRequests = [:]
        _ = progressStaging.drain()
        preparationStatesByImagePath = preparationStatesByImagePath.filter { !$0.value.isActive }
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
        case .success(let preparation):
            preparationStatesByImagePath[imagePath] = .prepared(preparation)
            recordFinishedPreparation(CrossReferenceFinishedPreparation(imagePath: imagePath, outcome: .prepared(preparation), finishedAt: Date()))
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
        isUnsupportedByEngine = false
        preparationStatesByImagePath = [:]
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
        }
    }

    /// The engine's process keeps the limit while preparation is on, and
    /// nothing while it is off.
    private func applyResidentByteLimit() {
        let engine = engine
        let byteLimit = isEnabled ? settings.search.crossReferenceResidentByteLimit : 0
        Task {
            try? await engine.setPreparedCrossReferenceByteLimit(byteLimit)
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

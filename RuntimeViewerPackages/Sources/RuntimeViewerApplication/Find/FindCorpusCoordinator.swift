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
/// 1. an image the background indexer finished;
/// 2. an image the user opened, ahead of the queue;
/// 3. the corpus switch turning on, for every indexed image;
/// 4. the transformer settings changing, after a two-second lull: every
///    corpus is printed with them, so all are dropped and rebuilt.
///
/// Turning the switch off drops every corpus. A source switch rewires onto
/// the new engine and starts over.
@MainActor
@Loggable(.private)
public final class FindCorpusCoordinator {
    private unowned let documentState: DocumentState

    private var engine: RuntimeEngine

    private var eventPumpTask: Task<Void, Never>?

    private var imageDidLoadSubscription: AnyCancellable?

    /// The build requests this document holds open, by image path. Each is
    /// one subscription on the store's build; cancelling it withdraws only
    /// this document's interest.
    private var buildTasks: [String: Task<Void, Never>] = [:]

    private var transformerRebuildTask: Task<Void, Never>?

    /// Images this document asked to build under the current engine, so a
    /// transformer change knows what to rebuild.
    private var requestedImagePaths: Set<String> = []

    private let disposeBag = DisposeBag()

    #if canImport(RuntimeViewerSettings)
    @Dependency(\.settings)
    private var settings

    private var lastKnownIsEnabled = true

    private var lastKnownTransformer = Transformer.Configuration.default

    private var lastKnownResidentByteLimit = 0
    #endif

    /// How long transformer edits are left to settle before every corpus is
    /// rebuilt.
    static let transformerRebuildDelayNanoseconds: UInt64 = 2_000_000_000

    public init(documentState: DocumentState) {
        self.documentState = documentState
        self.engine = documentState.runtimeEngine
        #if canImport(RuntimeViewerSettings)
        bootstrapSettingsObservation()
        #endif
        bootstrapEngineObservation()
        startPumps()
    }

    deinit {
        eventPumpTask?.cancel()
        transformerRebuildTask?.cancel()
        for task in buildTasks.values {
            task.cancel()
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

    // MARK: - Triggers

    /// Asks the engine to build `imagePath`'s corpus; a request already open
    /// for it is left alone.
    public func requestBuild(of imagePath: String) {
        guard isEnabled, buildTasks[imagePath] == nil else { return }
        requestedImagePaths.insert(imagePath)
        let engine = engine
        let transformer = currentTransformer
        buildTasks[imagePath] = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.engine === engine else { return }
                    self.buildTasks[imagePath] = nil
                }
            }
            do {
                _ = try await engine.buildInterfaceCorpus(for: imagePath, transformer: transformer)
            } catch is CancellationError {
                // Withdrawn: the switch went off, the engine changed, or the
                // transformer moved on. Nothing to report.
            } catch {
                #log(.error, "Corpus build of \(imagePath, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }

    /// Every image the engine has indexed, queued in one go — the switch
    /// turning on, or a fresh engine.
    public func requestBuildOfIndexedImages() {
        guard isEnabled else { return }
        let engine = engine
        Task { [weak self] in
            guard let imagePaths = try? await engine.indexedImagePathList() else { return }
            guard let self, self.engine === engine else { return }
            for imagePath in imagePaths {
                self.requestBuild(of: imagePath)
            }
        }
    }

    private func withdrawEveryBuild() {
        for task in buildTasks.values {
            task.cancel()
        }
        buildTasks.removeAll()
    }

    private func dropEveryCorpus(on engine: RuntimeEngine) {
        withdrawEveryBuild()
        Task {
            try? await engine.evictInterfaceCorpus(for: nil)
        }
    }

    // MARK: - Pumps

    private func startPumps() {
        let engine = engine
        eventPumpTask = Task { [weak self] in
            let stream = await engine.backgroundIndexingManager.events
            for await event in stream {
                guard let self, self.engine === engine else { return }
                if case .taskFinished(_, let path, let result) = event, case .completed = result {
                    self.requestBuild(of: path)
                }
            }
        }
        imageDidLoadSubscription = engine.imageDidLoadPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] imagePath in
                MainActor.assumeIsolated {
                    guard let self, self.engine === engine else { return }
                    self.requestBuild(of: imagePath)
                }
            }
        #if canImport(RuntimeViewerSettings)
        applyResidentByteLimit()
        #endif
        requestBuildOfIndexedImages()
    }

    private func stopPumps() {
        eventPumpTask?.cancel()
        eventPumpTask = nil
        imageDidLoadSubscription = nil
        transformerRebuildTask?.cancel()
        transformerRebuildTask = nil
    }

    // MARK: - Engine swap

    private func bootstrapEngineObservation() {
        documentState.$runtimeEngine
            .skip(1)
            .subscribeOnNext { [weak self] newEngine in
                guard let self else { return }
                self.handleEngineSwap(to: newEngine)
            }
            .disposed(by: disposeBag)
    }

    private func handleEngineSwap(to newEngine: RuntimeEngine) {
        stopPumps()
        withdrawEveryBuild()
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
                guard let self else { return }
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
            for imagePath in imagePaths {
                self.requestBuild(of: imagePath)
            }
        }
    }
    #endif
}

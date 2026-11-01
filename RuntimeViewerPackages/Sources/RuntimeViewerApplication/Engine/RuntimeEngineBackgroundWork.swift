import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies
import DependenciesMacros

/// One engine's background work — its background indexing, its interface corpus and its prepared
/// cross references — shared by every document on the engine.
///
/// The documents on an engine always shared its indexing manager and its corpus store, but each
/// kept coordinators of its own: each dispatched the Always Index rows and asked for every corpus
/// again, and each kept a history of its own, begun when it opened, so two windows on one engine
/// showed two different Reports, and Cancel or Clear History in one of them left the other as it
/// was. With one indexing coordinator and one corpus coordinator per engine, the windows on it
/// show the same Report and what one of them does reaches all of them; only windows on different
/// engines show different Reports. What is in progress is worked out once here, for all of them,
/// and so is the activity that keeps the app out of App Nap meanwhile.
///
/// Brought into being when the first document on the engine starts its background work
/// (`DocumentState.startBackgroundWork()`), and closed when the last one leaves it — closing, or
/// moving to another engine: its running work is cancelled and its history goes with it, as when
/// a single window closes, and the engine's process drops the corpora and the prepared cross
/// references it kept for the documents. The next document on the engine starts afresh, and asks
/// for them again. A document holds it through its `RuntimeEngineSession`; see
/// `RuntimeEngineBackgroundWorkRegistry`.
@MainActor
final class RuntimeEngineBackgroundWork {
    let engine: RuntimeEngine

    /// The engine's background indexing, kept with its feature turned off too, so it can start
    /// once the feature is turned on.
    let indexingCoordinator: RuntimeBackgroundIndexingCoordinator

    /// The engine's interface corpus, kept like `indexingCoordinator`.
    let corpusCoordinator: FindCorpusCoordinator

    /// The engine's prepared cross references, kept like `indexingCoordinator`.
    let crossReferencePreparationCoordinator: CrossReferencePreparationCoordinator

    /// Whether any of the work is in progress — an indexing batch, a corpus queued or being
    /// printed, cross references queued or being prepared — for every document on the engine: what
    /// their Report navigator tabs mark, and what `processActivity` follows.
    let isWorkInProgress: Driver<Bool>

    /// Keeps the app out of App Nap while `isWorkInProgress` says so.
    let processActivity: BackgroundWorkProcessActivity

    private let disposeBag = DisposeBag()

    /// The documents that hold the work, by identity.
    fileprivate var memberIdentifiers: Set<ObjectIdentifier> = []

    /// The last document left; see `close()`.
    private(set) var isClosed = false

    /// Work for the first document joining `engine`: its three coordinators come into being with
    /// it, the engine's background indexing starts, as a document opening on the engine starts it,
    /// and the activity that keeps the app out of App Nap begins following the work. The documents
    /// joining later find it all under way. `processActivityScheduler` is what the activity begins
    /// and ends activities with.
    fileprivate init(engine: RuntimeEngine, processActivityScheduler: any ProcessActivityScheduling) {
        let indexingCoordinator = RuntimeBackgroundIndexingCoordinator(engine: engine)
        let corpusCoordinator = FindCorpusCoordinator(engine: engine)
        let crossReferencePreparationCoordinator = CrossReferencePreparationCoordinator(engine: engine)
        let isWorkInProgress = Driver.combineLatest(
            indexingCoordinator.hasActiveBatchObservable.asDriver(onErrorJustReturn: false),
            corpusCoordinator.hasActiveBuild,
            crossReferencePreparationCoordinator.hasActivePreparation
        ) { hasActiveBatch, hasActiveBuild, hasActivePreparation in
            hasActiveBatch || hasActiveBuild || hasActivePreparation
        }
        .distinctUntilChanged()
        self.engine = engine
        self.indexingCoordinator = indexingCoordinator
        self.corpusCoordinator = corpusCoordinator
        self.crossReferencePreparationCoordinator = crossReferencePreparationCoordinator
        self.isWorkInProgress = isWorkInProgress
        processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress, scheduler: processActivityScheduler)
        // The Always Index images are read from derived data as their rows
        // are dispatched, searchable before the batches index them — so the
        // corpus coordinator listens before the indexing starts.
        indexingCoordinator.alwaysIndexImagePathsResolved
            .subscribeOnNextMainActor { [weak corpusCoordinator] imagePaths in
                guard let corpusCoordinator else { return }
                corpusCoordinator.restoreCorpora(of: imagePaths)
            }
            .disposed(by: disposeBag)
        indexingCoordinator.documentDidOpen()
    }

    /// The last document left: every coordinator stops, cancelling what it still has running,
    /// and asks the engine for nothing again; the activity is let go. The engine's process is
    /// asked to drop every corpus and every prepared cross reference it kept for the work —
    /// several hundred megabytes for an engine with a few large frameworks indexed, which used to
    /// stay until the app quit (proposal `engine-resident-memory`). Its sections stay, so the next
    /// document finds the images indexed. Returns that release, `nil` for work closed already.
    fileprivate func close() -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        isClosed = true
        indexingCoordinator.close()
        corpusCoordinator.close()
        crossReferencePreparationCoordinator.close()
        processActivity.close()
        let corpusRelease = corpusCoordinator.releaseEngineCorpora()
        let preparationRelease = crossReferencePreparationCoordinator.releaseEnginePreparations()
        return Task {
            await corpusRelease.value
            await preparationRelease.value
        }
    }

    /// The release of the work closed before it on the engine was under way as this work came
    /// into being, and is done: what the work asked for meanwhile may have gone with it — a build
    /// the eviction cancelled, the limit it set before the zero one arrived — so the corpus and
    /// cross-reference coordinators start over, as when a new process comes up behind the engine.
    fileprivate func engineDataReleaseDidFinish() {
        guard !isClosed else { return }
        corpusCoordinator.startOver()
        crossReferencePreparationCoordinator.startOver()
    }
}

/// Hands each document the background work of the engine it is on: the same work to every
/// document on one engine, for as long as any of them stays.
@MainActor
final class RuntimeEngineBackgroundWorkRegistry {
    fileprivate static let shared = RuntimeEngineBackgroundWorkRegistry()

    /// By engine identity. An entry goes as its last document leaves, so an identifier is never
    /// read after its engine could have been freed.
    private var backgroundWorkByEngine: [ObjectIdentifier: RuntimeEngineBackgroundWork] = [:]

    /// The releases still under way, by engine identity: what the engine's process drops as the
    /// last document leaves (`RuntimeEngineBackgroundWork.close()`). Work brought into being on the
    /// engine meanwhile starts at once and starts over once the release is done, since a late
    /// eviction or a late zero limit undoes what it asked for. A release holds its engine until it
    /// is done, and its entry goes then, so an identifier here never outlives its engine either.
    private var engineDataReleaseByEngine: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// What the activity of each work brought into being from now on begins and ends its
    /// activities with. Test seam: every test has a registry of its own.
    var processActivityScheduler: any ProcessActivityScheduling = ProcessInfo.processInfo

    fileprivate init() {}

    /// `member` holds `engine`'s background work from now on, brought into being — and started —
    /// if no document on the engine holds it.
    func join(_ engine: RuntimeEngine, as member: ObjectIdentifier) -> RuntimeEngineBackgroundWork {
        let engineIdentifier = ObjectIdentifier(engine)
        let backgroundWork: RuntimeEngineBackgroundWork
        if let joinedBackgroundWork = backgroundWorkByEngine[engineIdentifier] {
            backgroundWork = joinedBackgroundWork
        } else {
            backgroundWork = RuntimeEngineBackgroundWork(engine: engine, processActivityScheduler: processActivityScheduler)
            backgroundWorkByEngine[engineIdentifier] = backgroundWork
            if let engineDataRelease = engineDataReleaseByEngine[engineIdentifier] {
                Task { [weak backgroundWork] in
                    await engineDataRelease.value
                    backgroundWork?.engineDataReleaseDidFinish()
                }
            }
        }
        backgroundWork.memberIdentifiers.insert(member)
        return backgroundWork
    }

    /// `member` lets go of `backgroundWork`. The last one letting go closes it — the engine's
    /// process drops what it kept for the work — and the next document on the engine gets work of
    /// its own.
    func leave(_ backgroundWork: RuntimeEngineBackgroundWork, as member: ObjectIdentifier) {
        guard backgroundWork.memberIdentifiers.remove(member) != nil, backgroundWork.memberIdentifiers.isEmpty else { return }
        let engineIdentifier = ObjectIdentifier(backgroundWork.engine)
        if let engineDataRelease = backgroundWork.close() {
            followEngineDataRelease(engineDataRelease, on: engineIdentifier)
        }
        if backgroundWorkByEngine[engineIdentifier] === backgroundWork {
            backgroundWorkByEngine[engineIdentifier] = nil
        }
    }

    /// Keeps `engineDataRelease` for the work the engine gets next, until it is done.
    private func followEngineDataRelease(_ engineDataRelease: Task<Void, Never>, on engineIdentifier: ObjectIdentifier) {
        engineDataReleaseByEngine[engineIdentifier] = engineDataRelease
        Task { [weak self] in
            await engineDataRelease.value
            guard let self, engineDataReleaseByEngine[engineIdentifier] == engineDataRelease else { return }
            engineDataReleaseByEngine[engineIdentifier] = nil
        }
    }

    /// The work some document holds on `engine`, if any. Test seam.
    func backgroundWork(on engine: RuntimeEngine) -> RuntimeEngineBackgroundWork? {
        backgroundWorkByEngine[ObjectIdentifier(engine)]
    }
}

// MARK: - Dependencies

extension DependencyValues {
    /// Every test gets a registry of its own: the dependency's test value is cached per test, so
    /// tests sharing an engine — `TestRuntimeEngine.shared()` — never share its coordinators.
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeEngineBackgroundWorkRegistry.shared })
    var runtimeEngineBackgroundWorkRegistry: RuntimeEngineBackgroundWorkRegistry = MainActor.assumeIsolated { RuntimeEngineBackgroundWorkRegistry() }
}

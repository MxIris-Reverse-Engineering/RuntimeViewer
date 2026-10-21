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
/// a single window closes. The next document on the engine starts afresh. See
/// `RuntimeEngineBackgroundWorkRegistry`.
@MainActor
final class RuntimeEngineBackgroundWork {
    let engine: RuntimeEngine

    /// The documents that hold the work, by identity.
    fileprivate var memberIdentifiers: Set<ObjectIdentifier> = []

    /// The last document left, or the work was never anyone's; see `close()`.
    private(set) var isClosed = false

    private var indexingCoordinatorStorage: RuntimeBackgroundIndexingCoordinator?

    private var corpusCoordinatorStorage: FindCorpusCoordinator?

    private var crossReferencePreparationCoordinatorStorage: CrossReferencePreparationCoordinator?

    /// Whether any of the work is in progress — an indexing batch, a corpus queued or being
    /// printed, cross references queued or being prepared — for every document on the engine: what
    /// their Report navigator tabs mark, and what `processActivity` follows. Never, for work
    /// handed out closed.
    private(set) var isWorkInProgress: Driver<Bool> = .just(false)

    /// Keeps the app out of App Nap while `isWorkInProgress` says so; `nil` for work handed out
    /// closed.
    private(set) var processActivity: BackgroundWorkProcessActivity?

    fileprivate init(engine: RuntimeEngine) {
        self.engine = engine
    }

    /// Work for the first document joining `engine`: its three coordinators come into being with
    /// it — with their features turned off too, so each can start once its feature is turned on —
    /// the engine's background indexing starts, as a document opening on the engine starts it, and
    /// the activity that keeps the app out of App Nap begins following the work. The documents
    /// joining later find it all under way. `processActivityScheduler` is what the activity begins
    /// and ends activities with.
    fileprivate convenience init(startingOn engine: RuntimeEngine, processActivityScheduler: any ProcessActivityScheduling) {
        self.init(engine: engine)
        let indexingCoordinator = indexingCoordinator
        indexingCoordinator.documentDidOpen()
        let corpusCoordinator = corpusCoordinator
        let crossReferencePreparationCoordinator = crossReferencePreparationCoordinator
        let isWorkInProgress = Driver.combineLatest(
            indexingCoordinator.hasActiveBatchObservable.asDriver(onErrorJustReturn: false),
            corpusCoordinator.hasActiveBuild,
            crossReferencePreparationCoordinator.hasActivePreparation
        ) { hasActiveBatch, hasActiveBuild, hasActivePreparation in
            hasActiveBatch || hasActiveBuild || hasActivePreparation
        }
        .distinctUntilChanged()
        self.isWorkInProgress = isWorkInProgress
        processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress, scheduler: processActivityScheduler)
    }

    /// Work nobody joined, for a document that has not started its background work: whatever it
    /// hands out is closed from the start, so it dispatches, builds and prepares nothing.
    static func closed(on engine: RuntimeEngine) -> RuntimeEngineBackgroundWork {
        let backgroundWork = RuntimeEngineBackgroundWork(engine: engine)
        backgroundWork.close()
        return backgroundWork
    }

    /// The engine's background indexing. Brought into being with work a document joins; work
    /// handed out closed makes it, closed, when it is first read.
    var indexingCoordinator: RuntimeBackgroundIndexingCoordinator {
        if let indexingCoordinatorStorage {
            return indexingCoordinatorStorage
        }
        let indexingCoordinator = RuntimeBackgroundIndexingCoordinator(engine: engine)
        if isClosed {
            indexingCoordinator.close()
        }
        indexingCoordinatorStorage = indexingCoordinator
        return indexingCoordinator
    }

    /// The engine's interface corpus. Brought into being like `indexingCoordinator`.
    var corpusCoordinator: FindCorpusCoordinator {
        if let corpusCoordinatorStorage {
            return corpusCoordinatorStorage
        }
        let corpusCoordinator = FindCorpusCoordinator(engine: engine)
        if isClosed {
            corpusCoordinator.close()
        }
        corpusCoordinatorStorage = corpusCoordinator
        return corpusCoordinator
    }

    /// The engine's prepared cross references. Brought into being like `indexingCoordinator`.
    var crossReferencePreparationCoordinator: CrossReferencePreparationCoordinator {
        if let crossReferencePreparationCoordinatorStorage {
            return crossReferencePreparationCoordinatorStorage
        }
        let crossReferencePreparationCoordinator = CrossReferencePreparationCoordinator(engine: engine)
        if isClosed {
            crossReferencePreparationCoordinator.close()
        }
        crossReferencePreparationCoordinatorStorage = crossReferencePreparationCoordinator
        return crossReferencePreparationCoordinator
    }

    /// The last document left: every coordinator stops, cancelling what it still has running,
    /// and asks the engine for nothing again; the activity is let go.
    fileprivate func close() {
        guard !isClosed else { return }
        isClosed = true
        indexingCoordinatorStorage?.close()
        corpusCoordinatorStorage?.close()
        crossReferencePreparationCoordinatorStorage?.close()
        processActivity?.close()
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

    /// What the activity of each work brought into being from now on begins and ends its
    /// activities with. Test seam: every test has a registry of its own.
    var processActivityScheduler: any ProcessActivityScheduling = ProcessInfo.processInfo

    fileprivate init() {}

    /// `member` holds `engine`'s background work from now on, brought into being — and started —
    /// if no document on the engine holds it.
    func join(_ engine: RuntimeEngine, as member: ObjectIdentifier) -> RuntimeEngineBackgroundWork {
        let engineIdentifier = ObjectIdentifier(engine)
        let backgroundWork = backgroundWorkByEngine[engineIdentifier] ?? RuntimeEngineBackgroundWork(startingOn: engine, processActivityScheduler: processActivityScheduler)
        backgroundWorkByEngine[engineIdentifier] = backgroundWork
        backgroundWork.memberIdentifiers.insert(member)
        return backgroundWork
    }

    /// `member` lets go of `backgroundWork`. The last one letting go closes it, and the next
    /// document on the engine gets work of its own.
    func leave(_ backgroundWork: RuntimeEngineBackgroundWork, as member: ObjectIdentifier) {
        guard backgroundWork.memberIdentifiers.remove(member) != nil, backgroundWork.memberIdentifiers.isEmpty else { return }
        backgroundWork.close()
        let engineIdentifier = ObjectIdentifier(backgroundWork.engine)
        if backgroundWorkByEngine[engineIdentifier] === backgroundWork {
            backgroundWorkByEngine[engineIdentifier] = nil
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

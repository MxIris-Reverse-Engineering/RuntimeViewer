import Foundation
import Combine
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
/// a single window closes. The next document on the engine starts afresh. A document on another
/// engine that borrows this engine's shared cache images holds it too, as a borrower: for My Mac
/// and Mac Catalyst the documents of the processes attached on this Mac, and each other's. A
/// document holds it through its `RuntimeEngineSession`; see `RuntimeEngineBackgroundWorkRegistry`.
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

    /// The images the engine's documents loaded at the user's request, for the Report's Manual
    /// Loading (proposal `editor-jump-bar`).
    let manualImageLoadCoordinator: ManualImageLoadCoordinator

    /// Whether any of the work is in progress — an indexing batch, a corpus queued or being
    /// printed, cross references queued or being prepared, an image the user is loading — for every
    /// document on the engine: what their Report navigator tabs mark, and what `processActivity`
    /// follows.
    let isWorkInProgress: Driver<Bool>

    /// Keeps the app out of App Nap while `isWorkInProgress` says so.
    let processActivity: BackgroundWorkProcessActivity

    /// The work's runs as activity reports, for the toolbar's activity display of every window on
    /// the engine.
    let activityReporter: RuntimeEngineActivityReporter

    private let disposeBag = DisposeBag()

    /// The documents that hold the work as documents on the engine, by identity, each with how
    /// many of its sessions do: a document puts its next session in place before it lets the last
    /// one go.
    fileprivate var memberCounts: [ObjectIdentifier: Int] = [:]

    /// The documents that hold the work because they borrow the engine's shared cache images —
    /// documents on another engine — counted the same way. They keep the work running; they never
    /// start the engine's own indexing.
    fileprivate var borrowerCounts: [ObjectIdentifier: Int] = [:]

    /// Whether no document holds the work any longer, in either way.
    fileprivate var hasNoHolders: Bool {
        memberCounts.isEmpty && borrowerCounts.isEmpty
    }

    /// The last document left; see `close()`.
    private(set) var isClosed = false

    /// Work for the first document joining or borrowing from `engine`: its three coordinators come
    /// into being with it, and the activity that keeps the app out of App Nap begins following the
    /// work. The engine's background indexing starts with the first document *on* the engine
    /// (`RuntimeEngineBackgroundWorkRegistry.join(_:as:)`), not with one that only borrows from it:
    /// a borrower hands the shared cache images it needs to the engine's indexing itself. The
    /// documents coming later find it all under way. `processActivityScheduler` is what the
    /// activity begins and ends activities with.
    fileprivate init(engine: RuntimeEngine, processActivityScheduler: any ProcessActivityScheduling) {
        let indexingCoordinator = RuntimeBackgroundIndexingCoordinator(engine: engine)
        let corpusCoordinator = FindCorpusCoordinator(engine: engine)
        let crossReferencePreparationCoordinator = CrossReferencePreparationCoordinator(engine: engine)
        let manualImageLoadCoordinator = ManualImageLoadCoordinator()
        let isWorkInProgress = Driver.combineLatest(
            indexingCoordinator.hasActiveBatchObservable.asDriver(onErrorJustReturn: false),
            corpusCoordinator.hasActiveBuild,
            crossReferencePreparationCoordinator.hasActivePreparation,
            manualImageLoadCoordinator.hasActiveLoad
        ) { hasActiveBatch, hasActiveBuild, hasActivePreparation, hasActiveLoad in
            hasActiveBatch || hasActiveBuild || hasActivePreparation || hasActiveLoad
        }
        .distinctUntilChanged()
        self.engine = engine
        self.indexingCoordinator = indexingCoordinator
        self.corpusCoordinator = corpusCoordinator
        self.crossReferencePreparationCoordinator = crossReferencePreparationCoordinator
        self.manualImageLoadCoordinator = manualImageLoadCoordinator
        self.isWorkInProgress = isWorkInProgress
        processActivity = BackgroundWorkProcessActivity(isWorkInProgress: isWorkInProgress, scheduler: processActivityScheduler)
        activityReporter = RuntimeEngineActivityReporter(
            indexingCoordinator: indexingCoordinator,
            corpusCoordinator: corpusCoordinator,
            crossReferencePreparationCoordinator: crossReferencePreparationCoordinator
        )
        // The Always Index images are read from derived data as their rows
        // are dispatched, searchable before the batches index them — so the
        // corpus coordinator listens before the indexing starts. Their order
        // is the order cross references are prepared in. A shared cache image
        // the engine borrows is its owner's to read and prepare: the owner's
        // corpus coordinator reads it as the batch it was handed starts.
        indexingCoordinator.alwaysIndexImagePathsResolved
            .subscribeOnNextMainActor { [weak corpusCoordinator, weak crossReferencePreparationCoordinator, engine] imagePaths in
                let ownImagePaths = imagePaths.filter { !engine.borrowsSharedCacheImage(at: $0) }
                guard !ownImagePaths.isEmpty else { return }
                corpusCoordinator?.restoreCorpora(of: ownImagePaths)
                crossReferencePreparationCoordinator?.noteAlwaysIndexImagePaths(ownImagePaths)
            }
            .disposed(by: disposeBag)
    }

    /// The last document left: every coordinator stops, cancelling what it still has running,
    /// and asks the engine for nothing again; the activity is let go.
    fileprivate func close() {
        guard !isClosed else { return }
        isClosed = true
        indexingCoordinator.close()
        corpusCoordinator.close()
        crossReferencePreparationCoordinator.close()
        manualImageLoadCoordinator.close()
        processActivity.close()
    }
}

/// Hands each document the background work of the engine it is on, and the work of the engines it
/// borrows shared cache images from: the same work to every document on one engine, and to every
/// document borrowing from it, for as long as any of them stays.
@MainActor
final class RuntimeEngineBackgroundWorkRegistry {
    fileprivate static let shared = RuntimeEngineBackgroundWorkRegistry()

    /// By engine identity. An entry goes as its last document leaves, so an identifier is never
    /// read after its engine could have been freed.
    private var backgroundWorkByEngine: [ObjectIdentifier: RuntimeEngineBackgroundWork] = [:]

    /// What the activity of each work brought into being from now on begins and ends its
    /// activities with. Test seam: every test has a registry of its own.
    var processActivityScheduler: any ProcessActivityScheduling = ProcessInfo.processInfo

    /// An engine's work coming into being for its first document, or closing as its last one
    /// leaves — what lets an offline engine's process go while nobody is on it
    /// (`RuntimeOfflineEngineParking`). A document that borrows from the engine counts too; no
    /// document borrows from an offline engine.
    let occupancyChanges = PassthroughSubject<RuntimeEngineOccupancyChange, Never>()

    fileprivate init() {}

    /// `member` holds `engine`'s background work from now on as a document on the engine, brought
    /// into being if nobody holds it. The first member starts the engine's indexing; a document
    /// that only borrowed from the engine before did not.
    func join(_ engine: RuntimeEngine, as member: ObjectIdentifier) -> RuntimeEngineBackgroundWork {
        let backgroundWork = backgroundWorkBroughtIntoBeing(on: engine)
        let isFirstMember = backgroundWork.memberCounts.isEmpty
        backgroundWork.memberCounts[member, default: 0] += 1
        if isFirstMember {
            backgroundWork.indexingCoordinator.documentDidOpen()
        }
        return backgroundWork
    }

    /// `borrower` — a document on another engine, which borrows `engine`'s shared cache images —
    /// holds `engine`'s background work from now on, brought into being if nobody holds it. The
    /// work runs for it as for a document on the engine, but borrowing starts none of the engine's
    /// own indexing: the borrower hands the images it needs to it.
    func borrow(_ engine: RuntimeEngine, as borrower: ObjectIdentifier) -> RuntimeEngineBackgroundWork {
        let backgroundWork = backgroundWorkBroughtIntoBeing(on: engine)
        backgroundWork.borrowerCounts[borrower, default: 0] += 1
        return backgroundWork
    }

    /// `member` lets go of `backgroundWork` once. The last one letting go, member or borrower,
    /// closes it, and the next document gets work of its own.
    func leave(_ backgroundWork: RuntimeEngineBackgroundWork, as member: ObjectIdentifier) {
        guard Self.releaseHold(of: member, in: &backgroundWork.memberCounts) else { return }
        closeIfNobodyHolds(backgroundWork)
    }

    /// `borrower` lets go of `backgroundWork` once, as `leave(_:as:)` does for a member.
    func stopBorrowing(_ backgroundWork: RuntimeEngineBackgroundWork, as borrower: ObjectIdentifier) {
        guard Self.releaseHold(of: borrower, in: &backgroundWork.borrowerCounts) else { return }
        closeIfNobodyHolds(backgroundWork)
    }

    /// `engine`'s work, the one in place or a new one.
    private func backgroundWorkBroughtIntoBeing(on engine: RuntimeEngine) -> RuntimeEngineBackgroundWork {
        let engineIdentifier = ObjectIdentifier(engine)
        if let backgroundWork = backgroundWorkByEngine[engineIdentifier] {
            return backgroundWork
        }
        let backgroundWork = RuntimeEngineBackgroundWork(engine: engine, processActivityScheduler: processActivityScheduler)
        backgroundWorkByEngine[engineIdentifier] = backgroundWork
        occupancyChanges.send(.occupied(engine))
        return backgroundWork
    }

    /// Takes one of `holder`'s holds out of `counts`; whether it had one.
    private static func releaseHold(of holder: ObjectIdentifier, in counts: inout [ObjectIdentifier: Int]) -> Bool {
        guard let count = counts[holder] else { return false }
        counts[holder] = count > 1 ? count - 1 : nil
        return true
    }

    private func closeIfNobodyHolds(_ backgroundWork: RuntimeEngineBackgroundWork) {
        guard backgroundWork.hasNoHolders else { return }
        backgroundWork.close()
        let engineIdentifier = ObjectIdentifier(backgroundWork.engine)
        if backgroundWorkByEngine[engineIdentifier] === backgroundWork {
            backgroundWorkByEngine[engineIdentifier] = nil
            occupancyChanges.send(.vacated(backgroundWork.engine))
        }
    }

    /// The work some document holds on `engine`, if any. Test seam.
    func backgroundWork(on engine: RuntimeEngine) -> RuntimeEngineBackgroundWork? {
        backgroundWorkByEngine[ObjectIdentifier(engine)]
    }
}

/// See `RuntimeEngineBackgroundWorkRegistry.occupancyChanges`.
enum RuntimeEngineOccupancyChange {
    /// The first document joined the engine.
    case occupied(RuntimeEngine)
    /// The last document on the engine left it.
    case vacated(RuntimeEngine)
}

// MARK: - Dependencies

extension DependencyValues {
    /// Every test gets a registry of its own: the dependency's test value is cached per test, so
    /// tests sharing an engine — `TestRuntimeEngine.shared()` — never share its coordinators.
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeEngineBackgroundWorkRegistry.shared })
    var runtimeEngineBackgroundWorkRegistry: RuntimeEngineBackgroundWorkRegistry = MainActor.assumeIsolated { RuntimeEngineBackgroundWorkRegistry() }
}

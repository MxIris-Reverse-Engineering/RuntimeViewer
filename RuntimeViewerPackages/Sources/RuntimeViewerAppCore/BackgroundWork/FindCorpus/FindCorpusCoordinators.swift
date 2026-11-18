import RuntimeViewerCore
import RuntimeViewerArchitectures

/// The corpus coordinators a document's session reaches, as the Find navigator uses them: the
/// coordinator of the engine's own work, then the coordinator of each owner's work the session
/// borrows.
///
/// A shared cache image the engine borrows has its corpus built, kept and searched by its owner,
/// so each image belongs to exactly one of the coordinators: a request about an image goes to that
/// one alone, and what they report is merged — each owner's narrowed to the images it keeps for
/// the engine, since an owner also lists images of its own process the engine never sees. A
/// session that borrows nothing has one coordinator, and this is it.
@MainActor
struct FindCorpusCoordinators {
    private let session: RuntimeEngineSession

    /// The coordinators of `session`'s work; `nil` while it holds none.
    init?(session: RuntimeEngineSession) {
        guard session.backgroundWork != nil else { return nil }
        self.session = session
    }

    /// Every coordinator, the engine's own first.
    var coordinators: [FindCorpusCoordinator] {
        session.backgroundWorks.map(\.corpusCoordinator)
    }

    /// Whether `other` reaches the same coordinators, in the same order.
    func reachesSameCoordinators(as other: FindCorpusCoordinators?) -> Bool {
        guard let other else { return false }
        return coordinators.elementsEqual(other.coordinators, by: ===)
    }

    /// The coordinator of the work that keeps `imagePath`'s data.
    func coordinator(forImageAt imagePath: String) -> FindCorpusCoordinator? {
        session.backgroundWork(forImageAt: imagePath)?.corpusCoordinator
    }

    /// Every image's build state, from the coordinator that keeps it. The engine's own coordinator
    /// keeps no borrowed image, so its states are taken whole; an owner's are narrowed to the
    /// images the session borrows from it, and win over a state the engine's own process still
    /// reports for one of them.
    var buildStatesByImagePath: Observable<[String: RuntimeInterfaceCorpusBuildState]> {
        guard let ownWork = session.backgroundWork else { return .just([:]) }
        let session = session
        let ownStates = ownWork.corpusCoordinator.$buildStatesByImagePath.asObservable()
        let borrowedStates = session.borrowedBackgroundWorks.map { borrowedWork in
            borrowedWork.corpusCoordinator.$buildStatesByImagePath.asObservable()
                .map { states in
                    states.filter { imagePath, _ in session.keepsData(ofImageAt: imagePath, in: borrowedWork) }
                }
        }
        guard !borrowedStates.isEmpty else { return ownStates }
        return Observable.combineLatest([ownStates] + borrowedStates) { statesOfEachCoordinator in
            statesOfEachCoordinator.dropFirst().reduce(into: statesOfEachCoordinator[0]) { mergedStates, states in
                mergedStates.merge(states) { _, ownerState in ownerState }
            }
        }
    }

    /// An image's path each time a coordinator reports its corpus built, from the coordinator that
    /// keeps it.
    var corpusBuilt: Signal<String> {
        let session = session
        return Signal.merge(session.backgroundWorks.map { backgroundWork in
            backgroundWork.corpusCoordinator.corpusBuilt.filter { imagePath in
                session.keepsData(ofImageAt: imagePath, in: backgroundWork)
            }
        })
    }

    /// A coordinator dropped every corpus to print it again under a new transformer.
    var corporaRebuilt: Signal<Void> {
        Signal.merge(coordinators.map(\.corporaRebuilt))
    }

    /// `imagePath`'s state, from the coordinator that keeps it.
    func buildState(forImagePath imagePath: String) -> RuntimeInterfaceCorpusBuildState? {
        coordinator(forImageAt: imagePath)?.buildState(forImagePath: imagePath)
    }

    /// Asks the coordinator that keeps `imagePath` to build its corpus.
    func requestBuild(of imagePath: String, isPrioritized: Bool) {
        coordinator(forImageAt: imagePath)?.requestBuild(of: imagePath, isPrioritized: isPrioritized)
    }

    /// Hands each coordinator the images of a finished search it keeps; see
    /// `FindCorpusCoordinator.reconcile(unbuiltIndexedImagePaths:scopeImagePaths:)`.
    func reconcile(unbuiltIndexedImagePaths: [String], scopeImagePaths: Set<String>?) {
        for backgroundWork in session.backgroundWorks {
            let keptImagePaths = unbuiltIndexedImagePaths.filter { session.keepsData(ofImageAt: $0, in: backgroundWork) }
            let keptScopeImagePaths = scopeImagePaths.map { scope in
                scope.filter { session.keepsData(ofImageAt: $0, in: backgroundWork) }
            }
            backgroundWork.corpusCoordinator.reconcile(unbuiltIndexedImagePaths: keptImagePaths, scopeImagePaths: keptScopeImagePaths)
        }
    }
}

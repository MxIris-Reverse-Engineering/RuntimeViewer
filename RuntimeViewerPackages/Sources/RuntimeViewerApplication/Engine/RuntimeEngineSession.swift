import RuntimeViewerCore

/// The engine a document is on, and the document's hold on that engine's background work, as one
/// value: whatever follows it finds the engine and the work that goes with the engine together, so
/// no consumer can see one of them change without the other.
///
/// Its engine, the owners the engine borrowed shared cache images from when the session was made
/// and the work it holds never change; all it keeps track of is whether it has let go (`leave()`).
/// The document puts a new session in place (`DocumentState.runtimeEngineSession`) whenever the
/// engine, its owners or the hold changes — it starts its background work, it moves to another
/// engine, the engine manager gives the engine other owners — and puts the same session in place
/// again when its engine starts over on a new process, which is why a session is an object and
/// not a value. Closing only lets go: a reader that comes late finds the work it left, closed or
/// still running for the other documents on the engine.
///
/// The work itself is the engine's, shared by every document on it (`RuntimeEngineBackgroundWork`);
/// outside this module a session is only its engine.
@MainActor
public final class RuntimeEngineSession {
    public nonisolated let engine: RuntimeEngine

    /// The engines `engine` borrowed shared cache images from when the session was made; `nil`
    /// while it served every image itself. Requests about a borrowed image go to its owner, and
    /// so do the session's commands about one: its corpus, its indexing.
    let sharedCacheOwners: RuntimeSharedCacheOwners?

    /// The engine's background work the document joined; `nil` while it has not started its own.
    let backgroundWork: RuntimeEngineBackgroundWork?

    /// The background work of each engine the document borrows from, My Mac first, held while it
    /// holds `backgroundWork`: the corpora, the cross references and the indexing of the shared
    /// cache images the owners keep for it. Empty while the engine borrows nothing.
    let borrowedBackgroundWorks: [RuntimeEngineBackgroundWork]

    /// Where the work came from and who the document is to it, to let go of it.
    private let registry: RuntimeEngineBackgroundWorkRegistry?

    private let member: ObjectIdentifier?

    /// `leave()` has run: it lets go once.
    private var hasLeft = false

    /// A session on `engine` holding none of its background work, for a document that has not
    /// started its own.
    init(engine: RuntimeEngine) {
        self.engine = engine
        sharedCacheOwners = engine.sharedCacheOwners
        backgroundWork = nil
        borrowedBackgroundWorks = []
        registry = nil
        member = nil
    }

    /// `member` joins `engine`'s background work, which `registry` brings into being if no
    /// document is on the engine, and borrows the work of every engine `engine` borrows shared
    /// cache images from now.
    init(joining engine: RuntimeEngine, as member: ObjectIdentifier, through registry: RuntimeEngineBackgroundWorkRegistry) {
        let sharedCacheOwners = engine.sharedCacheOwners
        self.engine = engine
        self.sharedCacheOwners = sharedCacheOwners
        backgroundWork = registry.join(engine, as: member)
        borrowedBackgroundWorks = Self.ownerEngines(of: engine, in: sharedCacheOwners).map { ownerEngine in
            registry.borrow(ownerEngine, as: member)
        }
        self.registry = registry
        self.member = member
    }

    /// The session that takes this one's place on `engine` for the same document: holding
    /// `engine`'s work, through the registry this one came from, when this one holds work, and
    /// none otherwise. The registry is the one the document started with, not one looked up again
    /// wherever the replacement happens — an engine's owners change on a callback of their own.
    func successor(on engine: RuntimeEngine) -> RuntimeEngineSession {
        guard let registry, let member else { return RuntimeEngineSession(engine: engine) }
        return RuntimeEngineSession(joining: engine, as: member, through: registry)
    }

    /// The engine's own work, then the work of each engine it borrows from.
    var backgroundWorks: [RuntimeEngineBackgroundWork] {
        (backgroundWork.map { [$0] } ?? []) + borrowedBackgroundWorks
    }

    /// The work that keeps the data of the image at `imagePath`: the owner's for a shared cache
    /// image the engine borrowed when the session was made, the engine's own for any other. `nil`
    /// while the document holds no work.
    func backgroundWork(forImageAt imagePath: String) -> RuntimeEngineBackgroundWork? {
        guard let ownerEngine = ownerEngine(ofImageAt: imagePath) else { return backgroundWork }
        return borrowedBackgroundWorks.first { $0.engine === ownerEngine } ?? backgroundWork
    }

    /// Whether the data of the image at `imagePath` is kept by `backgroundWork`'s engine: the
    /// images an owner keeps go to the owner's work, everything else to the engine's own.
    func keepsData(ofImageAt imagePath: String, in backgroundWork: RuntimeEngineBackgroundWork) -> Bool {
        if let ownerEngine = ownerEngine(ofImageAt: imagePath) {
            return backgroundWork.engine === ownerEngine
        }
        return backgroundWork.engine === engine
    }

    /// Whether the engine borrowed any shared cache image when the session was made.
    var borrowsSharedCacheImages: Bool {
        !Self.ownerEngines(of: engine, in: sharedCacheOwners).isEmpty
    }

    /// The engines the engine borrows from, as `sharedCacheOwners` names them.
    var ownerEngines: [RuntimeEngine] {
        Self.ownerEngines(of: engine, in: sharedCacheOwners)
    }

    /// The owner of `imagePath` other than the engine itself, as the owners stood when the
    /// session was made.
    private func ownerEngine(ofImageAt imagePath: String) -> RuntimeEngine? {
        guard let sharedCacheOwners,
              let ownerEngine = sharedCacheOwners.owner(ofImageAt: engine.canonicalImagePath(imagePath)),
              ownerEngine !== engine
        else { return nil }
        return ownerEngine
    }

    private static func ownerEngines(of engine: RuntimeEngine, in sharedCacheOwners: RuntimeSharedCacheOwners?) -> [RuntimeEngine] {
        sharedCacheOwners?.engines.filter { $0 !== engine } ?? []
    }

    /// Lets go of the work: the image the document's sidebar showed there is withdrawn first, so
    /// the engine stops favouring an image nobody looks at, and the last document on an engine
    /// letting go closes its work, cancelling what it still runs. Only the first call does
    /// anything.
    func leave() {
        guard !hasLeft, let backgroundWork, let registry, let member else { return }
        hasLeft = true
        for heldWork in backgroundWorks {
            heldWork.corpusCoordinator.setOnScreenImagePath(nil, ofDocument: member)
        }
        registry.leave(backgroundWork, as: member)
        for borrowedBackgroundWork in borrowedBackgroundWorks {
            registry.stopBorrowing(borrowedBackgroundWork, as: member)
        }
    }
}

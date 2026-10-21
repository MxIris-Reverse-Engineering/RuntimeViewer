import RuntimeViewerCore

/// The engine a document is on, and the document's hold on that engine's background work, as one
/// value: whatever follows it finds the engine and the work that goes with the engine together, so
/// no consumer can see one of them change without the other.
///
/// Its engine and the work it holds never change; all it keeps track of is whether it has let go
/// (`leave()`). The document puts a new session in place (`DocumentState.runtimeEngineSession`)
/// whenever the engine or the hold changes — it starts its background work, it moves to another
/// engine — and puts the same session in place again when its engine starts over on a new
/// process, which is why a session is an object and not a value. Closing only lets go: a reader
/// that comes late finds the work it left, closed or still running for the other documents on
/// the engine.
///
/// The work itself is the engine's, shared by every document on it (`RuntimeEngineBackgroundWork`);
/// outside this module a session is only its engine.
@MainActor
public final class RuntimeEngineSession {
    public nonisolated let engine: RuntimeEngine

    /// The engine's background work the document joined; `nil` while it has not started its own.
    let backgroundWork: RuntimeEngineBackgroundWork?

    /// Where the work came from and who the document is to it, to let go of it.
    private let registry: RuntimeEngineBackgroundWorkRegistry?

    private let member: ObjectIdentifier?

    /// `leave()` has run: it lets go once.
    private var hasLeft = false

    /// A session on `engine` holding none of its background work, for a document that has not
    /// started its own.
    init(engine: RuntimeEngine) {
        self.engine = engine
        backgroundWork = nil
        registry = nil
        member = nil
    }

    /// `member` joins `engine`'s background work, which `registry` brings into being if no
    /// document is on the engine.
    init(joining engine: RuntimeEngine, as member: ObjectIdentifier, through registry: RuntimeEngineBackgroundWorkRegistry) {
        self.engine = engine
        backgroundWork = registry.join(engine, as: member)
        self.registry = registry
        self.member = member
    }

    /// Lets go of the work: the image the document's sidebar showed there is withdrawn first, so
    /// the engine stops favouring an image nobody looks at, and the last document on the engine
    /// letting go closes the work, cancelling what it still runs. Only the first call does
    /// anything.
    func leave() {
        guard !hasLeft, let backgroundWork, let registry, let member else { return }
        hasLeft = true
        backgroundWork.corpusCoordinator.setOnScreenImagePath(nil, ofDocument: member)
        registry.leave(backgroundWork, as: member)
    }
}

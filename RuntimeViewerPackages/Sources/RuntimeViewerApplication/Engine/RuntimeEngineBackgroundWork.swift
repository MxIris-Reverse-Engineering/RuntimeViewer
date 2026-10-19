import Foundation
import RuntimeViewerCore
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
/// engines show different Reports.
///
/// Brought into being when the first document needs either coordinator on the engine, and closed
/// when the last one leaves it — closing, or moving to another engine: its running work is
/// cancelled and its history goes with it, as when a single window closes. The next document on
/// the engine starts afresh. See `RuntimeEngineBackgroundWorkRegistry`.
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

    fileprivate init(engine: RuntimeEngine) {
        self.engine = engine
    }

    /// Work for a document that closed without ever holding its engine's: whatever it hands out is
    /// closed from the start, so reading it asks the engine for nothing.
    static func closed(on engine: RuntimeEngine) -> RuntimeEngineBackgroundWork {
        let backgroundWork = RuntimeEngineBackgroundWork(engine: engine)
        backgroundWork.close()
        return backgroundWork
    }

    /// The engine's background indexing. Brought into being on first use, so a document that
    /// never needs it — a test's — starts none.
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

    /// The engine's interface corpus. Brought into being on first use, like `indexingCoordinator`.
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

    /// The engine's prepared cross references. Brought into being on first use, like
    /// `indexingCoordinator`.
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
    /// and asks the engine for nothing again.
    fileprivate func close() {
        guard !isClosed else { return }
        isClosed = true
        indexingCoordinatorStorage?.close()
        corpusCoordinatorStorage?.close()
        crossReferencePreparationCoordinatorStorage?.close()
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

    fileprivate init() {}

    /// `member` holds `engine`'s background work from now on, brought into being if no document
    /// on the engine holds it.
    func join(_ engine: RuntimeEngine, as member: ObjectIdentifier) -> RuntimeEngineBackgroundWork {
        let engineIdentifier = ObjectIdentifier(engine)
        let backgroundWork = backgroundWorkByEngine[engineIdentifier] ?? RuntimeEngineBackgroundWork(engine: engine)
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

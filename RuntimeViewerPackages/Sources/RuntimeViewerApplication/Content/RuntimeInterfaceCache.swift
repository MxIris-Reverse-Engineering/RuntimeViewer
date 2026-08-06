import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Per-document LRU cache of generated runtime-object interfaces.
///
/// Navigation constantly rebinds `ContentTextViewModel` (every push, tab
/// switch, back/forward step), and every rebind used to re-fetch the
/// interface over XPC even when the object was viewed seconds earlier.
/// This cache sits between the content pipeline and the engine so a
/// revisit renders from memory — the only remaining cost is the off-main
/// attributed-string build.
///
/// Scope and invalidation:
/// - One instance per `DocumentState`, keyed by `(object, options)` — the
///   same pair the fetch half of the content pipeline hands the engine.
/// - Any `dataChangePublisher` event and any engine swap flushes the whole
///   cache. Both are rare, and a conservative full flush can never serve a
///   stale interface after the runtime data set changed (image loads and
///   reloads broadcast `.fullReload`; injection lands as either a reload
///   or an engine swap).
/// - `nil` results and errors are never cached: a "not found" can become
///   found once another image loads, and dead-link re-fetches are cheap.
/// - Bulk consumers (interface export, MCP) deliberately bypass this cache
///   and talk to the engine directly — a bulk sweep would evict exactly
///   the entries navigation is about to revisit.
///
/// Concurrency: `@MainActor`, like every other document-scoped service.
/// Concurrent requests for the same key share one in-flight fetch task, so
/// a link click's resolution fetch and the destination view model's display
/// fetch cost one engine round-trip between them. A fetch that outlives an
/// invalidation still returns its value to the caller but is not stored
/// (generation token), so a flush can never be undone by a straggler.
@MainActor
public final class RuntimeInterfaceCache {
    /// Fetches an interface from the engine. Injectable so tests can count
    /// fetches, simulate failures, and control timing. The default reads
    /// `documentState.runtimeEngine` at call time because the engine can be
    /// swapped mid-document.
    typealias Fetcher = @Sendable (RuntimeObject, RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface?

    private struct Key: Hashable {
        let object: RuntimeObject
        let options: RuntimeObjectInterface.GenerationOptions
    }

    private enum Entry {
        case inFlight(Task<RuntimeObjectInterface?, Swift.Error>)
        case ready(RuntimeObjectInterface)
    }

    /// Maximum number of `.ready` entries. 16 covers the tab strip plus a
    /// realistic back/forward window; a typical interface is tens of
    /// kilobytes of `SemanticString`, so the worst case stays bounded even
    /// with a few `UIView.h`-scale outliers in the mix.
    private let capacity: Int

    private let fetcher: Fetcher

    private var entries: [Key: Entry] = [:]

    /// Keys of `.ready` entries, least recently used first. In-flight
    /// entries are not tracked here — they either graduate to `.ready`
    /// (and enter this list) or are removed.
    private var readyKeysByRecency: [Key] = []

    /// Bumped by `invalidateAll()`. A fetch only stores its result when the
    /// generation it started under is still current.
    private var generation = 0

    private let disposeBag = DisposeBag()

    init(documentState: DocumentState, capacity: Int = 16, fetcher: Fetcher? = nil) {
        self.capacity = capacity
        // `weak`: DocumentState owns this cache, and the fetch task can
        // outlive a closing document — a strong capture would cycle, an
        // unowned one would crash a straggler fetch.
        self.fetcher = fetcher ?? { [weak documentState] object, options in
            guard let documentState else { throw CancellationError() }
            return try await documentState.runtimeEngine.interface(for: object, options: options)
        }

        // Engine swap → flush; every data-change event on the current
        // engine → flush. `flatMapLatest` unsubscribes from the previous
        // engine's publisher the moment a swap lands.
        let engineSwapped = documentState.$runtimeEngine
            .asObservable()
            .skip(1)
            .map { _ in () }
        let engineDataChanged = documentState.$runtimeEngine
            .asObservable()
            .flatMapLatest { engine in
                engine.dataChangePublisher.asObservable().map { _ in () }
            }
        Observable.merge(engineSwapped, engineDataChanged)
            .subscribeOnNextMainActor { [weak self] in
                guard let self else { return }
                invalidateAll()
            }
            .disposed(by: disposeBag)
    }

    /// Returns the cached interface for `(object, options)`, fetching and
    /// caching it on a miss. Concurrent calls for the same key await one
    /// shared fetch.
    public func interface(
        for object: RuntimeObject,
        options: RuntimeObjectInterface.GenerationOptions
    ) async throws -> RuntimeObjectInterface? {
        let key = Key(object: object, options: options)

        if let entry = entries[key] {
            switch entry {
            case .ready(let interface):
                markRecentlyUsed(key)
                return interface
            case .inFlight(let task):
                return try await task.value
            }
        }

        let fetchGeneration = generation
        let fetcher = fetcher
        let task = Task { try await fetcher(object, options) }
        entries[key] = .inFlight(task)

        // Only this creator path mutates the entry below: callers that
        // arrived while the fetch was in flight are awaiting `task.value`
        // in the branch above and never touch storage, and after a flush
        // the generation guard keeps this path's hands off whatever a
        // newer fetch may have stored under the same key.
        do {
            let interface = try await task.value
            if generation == fetchGeneration {
                if let interface {
                    entries[key] = .ready(interface)
                    markRecentlyUsed(key)
                    evictBeyondCapacity()
                } else {
                    entries[key] = nil
                }
            }
            return interface
        } catch {
            if generation == fetchGeneration {
                entries[key] = nil
            }
            throw error
        }
    }

    /// Drops every entry and revokes in-flight fetches' right to store
    /// their results. Callers already awaiting a shared fetch still receive
    /// its value — they asked before the flush.
    func invalidateAll() {
        generation &+= 1
        entries.removeAll()
        readyKeysByRecency.removeAll()
    }

    private func markRecentlyUsed(_ key: Key) {
        if let existingIndex = readyKeysByRecency.firstIndex(of: key) {
            readyKeysByRecency.remove(at: existingIndex)
        }
        readyKeysByRecency.append(key)
    }

    private func evictBeyondCapacity() {
        while readyKeysByRecency.count > capacity {
            let evictedKey = readyKeysByRecency.removeFirst()
            entries[evictedKey] = nil
        }
    }
}

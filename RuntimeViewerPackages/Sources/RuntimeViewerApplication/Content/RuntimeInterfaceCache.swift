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
/// - One instance per `DocumentState`, keyed by `(object, options)`. The
///   object is the one the *returned interface* names, which is not always
///   the one that was asked about: a link click resolves a synthetic target
///   into the defining section's authoritative `RuntimeObject`, and it is
///   that object the navigation and the destination view model then use.
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

    /// Cache identity for one generated interface.
    ///
    /// The object half is `RuntimeObjectKey` — `(imagePath, name, kind)` —
    /// not the whole `RuntimeObject`. It is the identity
    /// `RuntimeSwiftSection.interfaceByObject` already uses for the very
    /// interfaces this cache stores, so a finer key here can only produce
    /// misses the engine itself does not have. `RuntimeObject` additionally
    /// folds in `children` (recursive), `displayName` and `properties`, so
    /// the old key walked a whole subtree on every lookup, and a synthetic
    /// link target carrying the displaying object's `children` could never
    /// match the authoritative object it resolved to.
    private struct Key: Hashable {
        let objectKey: RuntimeObjectKey
        let options: RuntimeObjectInterface.GenerationOptions

        init(object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) {
            self.objectKey = object.key
            self.options = options
        }
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

    /// Learned redirects from a request key to the key its answer was filed
    /// under. Filing by `interface.object` is what makes the post-push
    /// display fetch hit, but it leaves the *request* key holding nothing —
    /// so without this table a second click on the same type token misses
    /// forever while its answer sits one key over, and regenerates the whole
    /// interface with every detail flag the content pane is using.
    ///
    /// Only cross-image links reach this table: `RuntimeObjectKey` folds
    /// identity to `(imagePath, name, kind)`, and the click site can only
    /// stamp the *displaying* object's `imagePath` onto its synthetic
    /// target, so a same-image link resolves to its own key and records no
    /// redirect at all.
    ///
    /// Redirects outlive their target's eviction. A stale one costs one
    /// extra dictionary lookup and then misses exactly as it would have
    /// anyway. The store rewrites it — *including erasing it* when a request
    /// starts answering to itself, which is the one case where leaving it
    /// would hide a correct entry instead of merely costing a miss.
    private var storageKeysByRequestKey: [Key: Key] = [:]

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
        // A previous fetch under this request key may have filed its answer
        // elsewhere (see `storageKeysByRequestKey`); follow the redirect
        // before declaring a miss.
        let lookupKey = storageKeysByRequestKey[key] ?? key

        if let entry = entries[lookupKey] {
            switch entry {
            case .ready(let interface):
                markRecentlyUsed(lookupKey)
                return interface
            case .inFlight(let task):
                return try await task.value
            }
        }

        let fetchGeneration = generation
        let fetcher = fetcher
        let task = Task { try await fetcher(object, options) }
        // Parked under the redirect target so concurrent callers for the
        // same object join this fetch instead of starting a second one.
        // Resolution is deterministic for a given request, so an existing
        // redirect names the key this fetch is about to store under anyway;
        // a data change would have flushed the table along with the entries.
        entries[lookupKey] = .inFlight(task)

        // Storage below is guarded two ways: the generation token keeps a
        // straggler from resurrecting an entry a flush dropped, and
        // `clearInFlight(_:ifStillOwnedBy:)` keeps this path from deleting
        // an entry a *different* request key's fetch legitimately installed
        // under the same storage key.
        do {
            let interface = try await task.value
            if generation == fetchGeneration {
                clearInFlight(lookupKey, ifStillOwnedBy: task)
                if let interface {
                    // Indexed by the interface's own object, not the
                    // requested one. A link click asks about a *synthetic*
                    // target built at the click site from the clicked token,
                    // stamped with the currently displayed object's
                    // `imagePath` because that is all the click site knows,
                    // and the engine answers with the defining section's
                    // authoritative `RuntimeObject`. That resolved object is
                    // what the push navigates to and what the destination
                    // view model fetches under, so indexing by the request
                    // would make the display fetch a guaranteed miss for
                    // every cross-image link and burn a slot on an entry it
                    // can never match.
                    let storageKey = Key(object: interface.object, options: options)
                    entries[storageKey] = .ready(interface)
                    markRecentlyUsed(storageKey)
                    if storageKey != key {
                        storageKeysByRequestKey[key] = storageKey
                    } else {
                        // This request now answers to itself. A redirect
                        // learned earlier would route the lookup above past
                        // the entry just stored under `key`, leaving a
                        // correct, freshly stored interface permanently
                        // unreachable — every later request for it would
                        // follow the redirect to a key that no longer
                        // describes it.
                        storageKeysByRequestKey[key] = nil
                    }
                    evictBeyondCapacity()
                }
            }
            return interface
        } catch {
            if generation == fetchGeneration {
                clearInFlight(lookupKey, ifStillOwnedBy: task)
            }
            throw error
        }
    }

    /// Removes the in-flight entry only while it is still *this* fetch's.
    ///
    /// Two fetches with different request keys can converge on one storage
    /// key — a link click resolving a synthetic object into O while another
    /// tab is already fetching O directly. Whichever finishes first stores
    /// `.ready` under that shared key; an unconditional delete by the other
    /// would destroy a live entry and strand its key in
    /// `readyKeysByRecency`, where the phantom permanently consumes an LRU
    /// slot and can later evict a healthy neighbour.
    private func clearInFlight(
        _ key: Key,
        ifStillOwnedBy task: Task<RuntimeObjectInterface?, Swift.Error>
    ) {
        guard case .inFlight(let storedTask) = entries[key], storedTask == task else { return }
        entries[key] = nil
    }

    /// Drops every entry and revokes in-flight fetches' right to store
    /// their results. Callers already awaiting a shared fetch still receive
    /// its value — they asked before the flush.
    func invalidateAll() {
        generation &+= 1
        entries.removeAll()
        readyKeysByRecency.removeAll()
        // Redirects describe resolutions made against the old data set; a
        // reload can move a type to a different image.
        storageKeysByRequestKey.removeAll()
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

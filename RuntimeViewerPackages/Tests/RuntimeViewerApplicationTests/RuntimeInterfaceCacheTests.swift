import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Regression suite for `RuntimeInterfaceCache` — the per-document LRU that
/// lets content navigation revisits render without an engine round-trip.
///
/// The assertions pin the cache contract: repeat lookups cost one fetch,
/// concurrent lookups share one in-flight fetch, errors and `nil` results
/// are never cached, `invalidateAll` (and the `dataChangePublisher` wiring
/// that drives it) forces a refetch, eviction is least-recently-used, and a
/// fetch that started before a flush can never repopulate the cache after
/// it.
@Suite("RuntimeInterfaceCache", .serialized)
@MainActor
struct RuntimeInterfaceCacheTests {
    /// Every cache in this suite subscribes to the shared local engine's
    /// data-change channel; its one-shot startup `.fullReload` broadcast
    /// would flush whichever test's cache it happens to land in. The
    /// per-test async init waits that traffic out (see
    /// SharedLocalEngineTestLock.swift).
    init() async {
        await ensureSharedLocalEngineSettled()
    }

    // MARK: - Hit / miss basics

    @Test("a repeated lookup for the same key costs one fetch")
    func repeatedFetchHitsCache() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let interfaceCache = makeCache(documentState: documentState, fetchRecorder: fetchRecorder)
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        let firstResult = try await interfaceCache.interface(for: fixtureObject, options: .init())
        let secondResult = try await interfaceCache.interface(for: fixtureObject, options: .init())

        #expect(firstResult?.object == fixtureObject)
        #expect(secondResult?.object == fixtureObject)
        #expect(fetchRecorder.totalFetchCount == 1)
    }

    @Test("distinct generation options are distinct cache keys")
    func distinctOptionsFetchSeparately() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let interfaceCache = makeCache(documentState: documentState, fetchRecorder: fetchRecorder)
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        var alternativeOptions = RuntimeObjectInterface.GenerationOptions()
        alternativeOptions.swiftInterfaceOptions.printFieldOffset.toggle()

        _ = try await interfaceCache.interface(for: fixtureObject, options: .init())
        _ = try await interfaceCache.interface(for: fixtureObject, options: alternativeOptions)
        _ = try await interfaceCache.interface(for: fixtureObject, options: .init())

        #expect(fetchRecorder.totalFetchCount == 2)
    }

    // MARK: - In-flight coalescing

    @Test("concurrent lookups for the same key share one in-flight fetch")
    func concurrentRequestsShareOneFetch() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchRecorder.recordFetch(of: object.name)
            try? await Task.sleep(for: .milliseconds(50))
            return RuntimeObjectInterface(object: object, interfaceString: "class CacheFixture {}")
        }
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        async let firstResult = interfaceCache.interface(for: fixtureObject, options: .init())
        async let secondResult = interfaceCache.interface(for: fixtureObject, options: .init())

        let resolvedFirst = try await firstResult
        let resolvedSecond = try await secondResult
        #expect(resolvedFirst?.object == fixtureObject)
        #expect(resolvedSecond?.object == fixtureObject)
        #expect(fetchRecorder.totalFetchCount == 1)
    }

    // MARK: - Link resolution

    /// A link click resolves a *synthetic* target — built at the click site
    /// from the clicked token, carrying the currently displayed object's
    /// `imagePath` (and, on the ObjC arm, its `children`) — and the engine
    /// answers with the defining section's authoritative `RuntimeObject`.
    /// The push navigates to that resolved object and the destination
    /// content view model fetches under it, so the entry must be indexed by
    /// the interface's own object. `RuntimeObject`'s `Hashable` folds in
    /// `imagePath` and `children`, so storing under the requested object
    /// instead left the display fetch a guaranteed miss: two full
    /// generations per link click, plus a dead entry occupying one of the
    /// sixteen slots — the opposite of the one-round-trip design the link
    /// flow documents.
    @Test("a fetch that resolves to a different object caches under the resolved object")
    func resolvedObjectIsTheCacheKey() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let clickedToken = makeRuntimeObject(named: "CacheFixtureClickedToken")
        let resolvedType = makeRuntimeObject(named: "CacheFixtureResolvedType")
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchRecorder.recordFetch(of: object.name)
            return RuntimeObjectInterface(object: resolvedType, interfaceString: "class CacheFixture {}")
        }

        let resolution = try await interfaceCache.interface(for: clickedToken, options: .init())
        #expect(resolution?.object == resolvedType)
        #expect(fetchRecorder.totalFetchCount == 1)

        let display = try await interfaceCache.interface(for: resolvedType, options: .init())
        #expect(display?.object == resolvedType)
        #expect(
            fetchRecorder.totalFetchCount == 1,
            "the resolution fetch must warm the entry the post-push display fetch hits"
        )
    }

    /// Filing the answer under the resolved object is only half the link
    /// flow. The *request* key — the synthetic object built at the click
    /// site — was cleared and never written back, so every later click on
    /// the same token missed and regenerated the whole interface with
    /// whatever detail flags the content pane is carrying, while the
    /// byte-identical answer sat one key over. Back / Forward and "Open in
    /// New Tab" over one token repeat that forever.
    @Test("clicking the same type token twice costs one fetch")
    func repeatedResolutionOfTheSameTokenHitsCache() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let clickedToken = makeRuntimeObject(named: "CacheFixtureRepeatToken")
        let resolvedType = makeRuntimeObject(named: "CacheFixtureRepeatType")
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchRecorder.recordFetch(of: object.name)
            return RuntimeObjectInterface(object: resolvedType, interfaceString: "class CacheFixture {}")
        }

        let firstResolution = try await interfaceCache.interface(for: clickedToken, options: .init())
        #expect(firstResolution?.object == resolvedType)
        #expect(fetchRecorder.totalFetchCount == 1)

        let secondResolution = try await interfaceCache.interface(for: clickedToken, options: .init())
        #expect(secondResolution?.object == resolvedType)
        #expect(
            fetchRecorder.totalFetchCount == 1,
            "a second click on the same token must follow the learned redirect to the resolved object"
        )
    }

    /// Two fetches with different request keys can converge on one storage
    /// key: a link click resolving a synthetic token into O while another
    /// tab is already fetching O directly. Whichever finishes first stores
    /// `.ready` there; the other's cleanup must not delete it. An
    /// unconditional `entries[key] = nil` destroyed the live entry *and*
    /// stranded its key in `readyKeysByRecency`, where the phantom
    /// permanently consumed one of the sixteen slots.
    @Test("a failing fetch does not delete an entry another fetch stored under the same key")
    func failingFetchLeavesAConvergedEntryIntact() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let clickedToken = makeRuntimeObject(named: "CacheFixtureConvergedToken")
        let resolvedType = makeRuntimeObject(named: "CacheFixtureConvergedType")
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchRecorder.recordFetch(of: object.name)
            if object == resolvedType {
                // The display fetch: outlives the resolution fetch, then fails.
                try? await Task.sleep(for: .milliseconds(150))
                throw StubInterfaceFetchError()
            }
            // The resolution fetch: converges on the resolved type's key and
            // finishes first.
            try? await Task.sleep(for: .milliseconds(30))
            return RuntimeObjectInterface(object: resolvedType, interfaceString: "class CacheFixture {}")
        }

        async let displayResult: RuntimeObjectInterface? = interfaceCache.interface(for: resolvedType, options: .init())
        try await Task.sleep(for: .milliseconds(10))
        let resolution = try await interfaceCache.interface(for: clickedToken, options: .init())
        #expect(resolution?.object == resolvedType)

        // `async let` bindings cannot be captured by the `#expect(throws:)`
        // closure, so the failure is observed directly.
        var displayFetchThrew = false
        do {
            _ = try await displayResult
        } catch is StubInterfaceFetchError {
            displayFetchThrew = true
        }
        #expect(displayFetchThrew, "the display fetch was set up to fail")

        let fetchCountBeforeReadback = fetchRecorder.totalFetchCount
        let readback = try await interfaceCache.interface(for: resolvedType, options: .init())
        #expect(readback?.object == resolvedType)
        #expect(
            fetchRecorder.totalFetchCount == fetchCountBeforeReadback,
            "the entry the resolution fetch stored must survive the other fetch's failure"
        )
    }

    // MARK: - Errors and nil results are never cached

    @Test("a failed fetch is not cached — the next lookup retries")
    func failedFetchIsNotCached() async throws {
        let fetchRecorder = FetchRecorder(failingFirstFetches: 1)
        let documentState = DocumentState()
        let interfaceCache = makeCache(documentState: documentState, fetchRecorder: fetchRecorder)
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        await #expect(throws: StubInterfaceFetchError.self) {
            _ = try await interfaceCache.interface(for: fixtureObject, options: .init())
        }
        let recoveredResult = try await interfaceCache.interface(for: fixtureObject, options: .init())

        #expect(recoveredResult?.object == fixtureObject)
        #expect(fetchRecorder.totalFetchCount == 2)
    }

    @Test("a nil result is not cached — the next lookup retries")
    func nilResultIsNotCached() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchRecorder.recordFetch(of: object.name)
            return nil
        }
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        let firstResult = try await interfaceCache.interface(for: fixtureObject, options: .init())
        let secondResult = try await interfaceCache.interface(for: fixtureObject, options: .init())

        #expect(firstResult == nil)
        #expect(secondResult == nil)
        #expect(fetchRecorder.totalFetchCount == 2)
    }

    // MARK: - Invalidation

    @Test("invalidateAll forces the next lookup to refetch")
    func invalidateAllForcesRefetch() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let interfaceCache = makeCache(documentState: documentState, fetchRecorder: fetchRecorder)
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        _ = try await interfaceCache.interface(for: fixtureObject, options: .init())
        interfaceCache.invalidateAll()
        _ = try await interfaceCache.interface(for: fixtureObject, options: .init())

        #expect(fetchRecorder.totalFetchCount == 2)
    }

    @Test("a dataChangePublisher event flushes the cache")
    func dataChangeEventFlushesCache() async throws {
        // This test broadcasts on the process-shared engine — every other
        // live subscriber in the test process hears the `.fullReload` —
        // so it must hold the cross-suite lock (see
        // SharedLocalEngineTestLock.swift).
        try await withSharedLocalEngineLock {
            let fetchRecorder = FetchRecorder()
            let documentState = DocumentState()
            let interfaceCache = makeCache(documentState: documentState, fetchRecorder: fetchRecorder)
            let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

            _ = try await interfaceCache.interface(for: fixtureObject, options: .init())
            #expect(fetchRecorder.totalFetchCount == 1)

            // Broadcasts `.fullReload` through the real engine → RxCombine →
            // main-actor invalidation wiring the cache installs in its init.
            await documentState.runtimeEngine.reloadData(isReloadImageNodes: false)

            // The broadcast hops engine Task → Combine subject → main-actor
            // task, so poll: a lookup stays a cache hit until the flush lands,
            // then refetches exactly once.
            let refetchedAfterFlush = try await pollUntil(timeout: .seconds(10)) {
                _ = try await interfaceCache.interface(for: fixtureObject, options: .init())
                return fetchRecorder.totalFetchCount == 2
            }
            #expect(refetchedAfterFlush, "the data-change broadcast never flushed the cache")
        }
    }

    @Test("a fetch that started before a flush cannot repopulate the cache")
    func staleInFlightFetchDoesNotRepopulateAfterInvalidation() async throws {
        let fetchRecorder = FetchRecorder()
        let fetchLatch = AsyncLatch()
        let documentState = DocumentState()
        let interfaceCache = RuntimeInterfaceCache(documentState: documentState) { object, _ in
            fetchRecorder.recordFetch(of: object.name)
            await fetchLatch.wait()
            return RuntimeObjectInterface(object: object, interfaceString: "class CacheFixture {}")
        }
        let fixtureObject = makeRuntimeObject(named: "CacheFixtureAlpha")

        async let inFlightResult = interfaceCache.interface(for: fixtureObject, options: .init())
        let fetchStarted = try await pollUntil(timeout: .seconds(10)) {
            fetchRecorder.totalFetchCount == 1
        }
        #expect(fetchStarted, "the gated fetch never started")

        interfaceCache.invalidateAll()
        fetchLatch.open()

        // The straggler still delivers its value to the caller that asked…
        let resolvedInFlight = try await inFlightResult
        #expect(resolvedInFlight?.object == fixtureObject)

        // …but must not have been stored: the next lookup refetches.
        _ = try await interfaceCache.interface(for: fixtureObject, options: .init())
        #expect(fetchRecorder.totalFetchCount == 2)
    }

    // MARK: - Eviction

    @Test("eviction removes the least recently used entry")
    func leastRecentlyUsedEntryIsEvicted() async throws {
        let fetchRecorder = FetchRecorder()
        let documentState = DocumentState()
        let interfaceCache = makeCache(documentState: documentState, capacity: 2, fetchRecorder: fetchRecorder)
        let objectAlpha = makeRuntimeObject(named: "CacheFixtureAlpha")
        let objectBravo = makeRuntimeObject(named: "CacheFixtureBravo")
        let objectCharlie = makeRuntimeObject(named: "CacheFixtureCharlie")

        _ = try await interfaceCache.interface(for: objectAlpha, options: .init())
        _ = try await interfaceCache.interface(for: objectBravo, options: .init())
        // Touch Alpha so Bravo becomes the least recently used entry…
        _ = try await interfaceCache.interface(for: objectAlpha, options: .init())
        // …and let Charlie push the cache past its capacity of 2.
        _ = try await interfaceCache.interface(for: objectCharlie, options: .init())

        _ = try await interfaceCache.interface(for: objectAlpha, options: .init())
        #expect(fetchRecorder.fetchCount(for: objectAlpha.name) == 1, "Alpha was refreshed and must have survived the eviction")

        _ = try await interfaceCache.interface(for: objectBravo, options: .init())
        #expect(fetchRecorder.fetchCount(for: objectBravo.name) == 2, "Bravo was the least recently used entry and must have been evicted")

        #expect(fetchRecorder.totalFetchCount == 4)
    }

    // MARK: - Fixtures

    private func makeCache(
        documentState: DocumentState,
        capacity: Int = 16,
        fetchRecorder: FetchRecorder
    ) -> RuntimeInterfaceCache {
        RuntimeInterfaceCache(documentState: documentState, capacity: capacity) { object, _ in
            if fetchRecorder.recordFetch(of: object.name) {
                throw StubInterfaceFetchError()
            }
            return RuntimeObjectInterface(object: object, interfaceString: "class CacheFixture {}")
        }
    }

    private func makeRuntimeObject(named name: String) -> RuntimeObject {
        RuntimeObject(
            name: "TestFramework.\(name)",
            displayName: "TestFramework.\(name)",
            kind: .swift(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
            children: [],
            properties: []
        )
    }

    /// Thread-safe fetch recorder, counted per object name so eviction
    /// tests can distinguish which key refetched.
    private final class FetchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedTotalFetchCount = 0
        private var storedFetchCountsByObjectName: [String: Int] = [:]
        private var storedFailuresRemaining: Int

        init(failingFirstFetches failureCount: Int = 0) {
            storedFailuresRemaining = failureCount
        }

        var totalFetchCount: Int {
            lock.withLock { storedTotalFetchCount }
        }

        func fetchCount(for objectName: String) -> Int {
            lock.withLock { storedFetchCountsByObjectName[objectName, default: 0] }
        }

        /// Records one fetch; returns whether this fetch should fail.
        @discardableResult
        func recordFetch(of objectName: String) -> Bool {
            lock.withLock {
                storedTotalFetchCount += 1
                storedFetchCountsByObjectName[objectName, default: 0] += 1
                guard storedFailuresRemaining > 0 else { return false }
                storedFailuresRemaining -= 1
                return true
            }
        }
    }

    /// One-shot gate: `wait()` suspends until `open()`; once open, every
    /// current and future waiter resumes immediately.
    private final class AsyncLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = lock.withLock {
                    if isOpen { return true }
                    pendingContinuations.append(continuation)
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }

        func open() {
            let continuationsToResume = lock.withLock {
                isOpen = true
                let pending = pendingContinuations
                pendingContinuations = []
                return pending
            }
            continuationsToResume.forEach { $0.resume() }
        }
    }

    // `Swift.Error` spelled out: an imported module also exports a type
    // named `Error`, which otherwise shadows the standard library protocol.
    private struct StubInterfaceFetchError: Swift.Error {}

    // MARK: - Polling helper

    private func pollUntil(
        timeout: Duration,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

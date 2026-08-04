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

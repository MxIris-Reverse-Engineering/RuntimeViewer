import Foundation
import RuntimeViewerCore

/// Cross-suite mutual exclusion for tests coupled to the process-shared
/// `RuntimeEngine.local`.
///
/// swift-testing runs tests concurrently ACROSS suites (`.serialized`
/// only orders tests within one suite), and every `DocumentState()` in
/// this target shares the `RuntimeEngine.local` singleton. A test that
/// broadcasts on it — `dataChangeEventFlushesCache` calls the real
/// `reloadData`, fanning `.fullReload` out to every live subscriber —
/// can therefore fire mid-flight into another suite's test and invalidate
/// exactly the state it is asserting on (interface caches flush, seeded
/// sidebar view models reload and drop their materialized rows).
///
/// Wrap both kinds of test in `withSharedLocalEngineLock`:
/// - tests that BROADCAST on the shared engine, and
/// - tests whose assertions a broadcast would invalidate.
///
/// Tests that never depend on broadcast-quiet windows (pure value tests,
/// injected-provider pipelines) must not take the lock — it serializes.
func withSharedLocalEngineLock<Result>(_ body: () async throws -> Result) async rethrows -> Result {
    await ensureSharedLocalEngineSettled()
    await SharedLocalEngineTestLock.shared.acquire()
    defer {
        Task {
            await SharedLocalEngineTestLock.shared.release()
        }
    }
    return try await body()
}

/// One-shot process-wide barrier against the shared engine's bring-up
/// traffic.
///
/// The first touch of `RuntimeEngine.local` spawns `connect()`, whose
/// `observeRuntime()` ends by broadcasting a `.fullReload` — from yet
/// another unstructured `Task`, so the send lands at an arbitrary moment
/// early in the test run. Any interface cache or seeded view model alive
/// at that moment gets flushed/reloaded mid-assertion. Every test that
/// subscribes (directly or via `RuntimeInterfaceCache` / sidebar view
/// models) to the shared engine's data-change channel must await this
/// barrier first.
func ensureSharedLocalEngineSettled() async {
    await SharedLocalEngineStartupBarrier.shared.settle()
}

private actor SharedLocalEngineStartupBarrier {
    static let shared = SharedLocalEngineStartupBarrier()

    private var hasSettled = false

    func settle() async {
        guard !hasSettled else { return }
        let localRuntimeEngine = RuntimeEngine.local
        // `observeRuntime()` assigns the image list, builds the image
        // nodes, and only then spawns the startup broadcast Task — so
        // non-empty image nodes prove the spawn happened, and the grace
        // period lets the spawned send fan out to current subscribers.
        while localRuntimeEngine.imageNodes.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(250))
        hasSettled = true
    }
}

private actor SharedLocalEngineTestLock {
    static let shared = SharedLocalEngineTestLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // Ownership was handed over by `release()` without clearing
        // `isLocked`, so nothing more to do here.
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

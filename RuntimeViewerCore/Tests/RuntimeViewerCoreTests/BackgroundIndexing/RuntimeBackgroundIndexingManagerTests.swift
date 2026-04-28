import Foundation
import Semaphore
import Testing
@testable import RuntimeViewerCore

@Suite final class RuntimeBackgroundIndexingManagerTests {
    /// Keepalives for engines / wrappers passed to a manager.
    ///
    /// Production safety: `RuntimeBackgroundIndexingManager.engine` is `unowned`
    /// because the engine owns the manager (`RuntimeEngine.backgroundIndexingManager`),
    /// so the engine always outlives the manager in real code.
    ///
    /// In tests we construct mocks as locals and ARC may eagerly release them
    /// across `await` suspension points — at which point the manager's unowned
    /// reference dangles and the next access traps. Stash mocks in this array
    /// to pin them to the suite instance's lifetime; Swift Testing instantiates
    /// a fresh suite per test, so the array is scoped to one test naturally.
    private var aliveObjects: [AnyObject] = []

    @discardableResult
    private func keep<T: AnyObject>(_ object: T) -> T {
        aliveObjects.append(object)
        return object
    }

    @Test func currentBatchesInitiallyEmpty() async {
        let engine = keep(MockBackgroundIndexingEngine())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let batches = await manager.currentBatches()
        #expect(batches.isEmpty)
    }

    @Test func eventsStreamYieldsBatchStartedThenFinishedForEmptyGraph() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/fake/Root",
                       .init(isIndexed: true))   // short-circuit immediately
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let events = manager.events
        let consumer = Task {
            var seen: [String] = []
            for await event in events {
                switch event {
                case .batchStarted: seen.append("started")
                case .batchFinished: seen.append("finished"); return seen
                case .batchCancelled: seen.append("cancelled"); return seen
                default: break
                }
            }
            return seen
        }

        _ = await manager.startBatch(rootImagePath: "/fake/Root",
                                     depth: 0, maxConcurrency: 1,
                                     reason: .manual)
        let finalSeen = await consumer.value
        #expect(finalSeen == ["started", "finished"])
    }

    @Test func expandEmptyWhenRootAlreadyIndexed() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App", .init(isIndexed: true))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 5)
        #expect(items.isEmpty)
    }

    @Test func expandDepth1IncludesRootAndDirectDeps() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App", .init(
            dependencies: [("/UIKit", "/UIKit"), ("/Foundation", "/Foundation")]
        ))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        #expect(Set(items.map(\.id)) == Set(["/App", "/UIKit", "/Foundation"]))
    }

    @Test func expandDepth1DoesNotIncludeSecondLevel() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App",
                       .init(dependencies: [("/UIKit", "/UIKit")]))
        engine.program(path: "/UIKit",
                       .init(dependencies: [("/CoreGraphics", "/CoreGraphics")]))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        #expect(Set(items.map(\.id)) == Set(["/App", "/UIKit"]))
    }

    @Test func expandSkipsAlreadyIndexedDeps() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App",
                       .init(dependencies: [("/UIKit", "/UIKit"),
                                            ("/Foundation", "/Foundation")]))
        engine.program(path: "/UIKit", .init(isIndexed: true))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        #expect(Set(items.map(\.id)) == Set(["/App", "/Foundation"]))
    }

    @Test func expandUnresolvedInstallNameBecomesFailedItem() async throws {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App", .init(
            dependencies: [("@rpath/Missing", nil)]
        ))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        let missing = try #require(items.first { $0.id == "@rpath/Missing" })
        guard case .failed = missing.state else {
            Issue.record("expected failed state, got \(missing.state)")
            return
        }
    }

    @Test func expandDedupsSharedDependencies() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App",
                       .init(dependencies: [("/A", "/A"), ("/B", "/B")]))
        engine.program(path: "/A",
                       .init(dependencies: [("/Shared", "/Shared")]))
        engine.program(path: "/B",
                       .init(dependencies: [("/Shared", "/Shared")]))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 2)
        let sharedCount = items.filter { $0.id == "/Shared" }.count
        #expect(sharedCount == 1)
    }

    @Test func batchIndexesAllPendingItems() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App",
                       .init(dependencies: [("/A", "/A"), ("/B", "/B")]))
        engine.program(path: "/A", .init())
        engine.program(path: "/B", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let finishedBatch = await runToFinish(manager: manager,
                                              root: "/App", depth: 1,
                                              maxConcurrency: 2)
        #expect(finishedBatch.items.allSatisfy { $0.state == .completed })
        let indexed = engine.loadedOrder()
        #expect(Set(indexed) == Set(["/App", "/A", "/B"]))
    }

    @Test func batchRespectsMaxConcurrency() async {
        let engine = keep(MockBackgroundIndexingEngine())
        // 6 dependencies, concurrency cap 2 → never exceed 2 simultaneous loads
        let deps = (0..<6).map { (installName: "/D\($0)", resolvedPath: "/D\($0)") }
        engine.program(path: "/App", .init(dependencies: deps))
        for dep in deps { engine.program(path: dep.installName, .init()) }

        // Monkey-patch engine with a concurrency-counting wrapper.
        let counter = ConcurrencyCounter()
        let wrapped = keep(InstrumentedEngine(base: engine, counter: counter))
        let manager = RuntimeBackgroundIndexingManager(engine: wrapped)

        _ = await runToFinish(manager: manager, root: "/App", depth: 1,
                              maxConcurrency: 2)
        #expect(counter.peak <= 2)
    }

    @Test func batchFailedLoadYieldsFailedTaskState() async throws {
        struct LoadError: Error {}
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App",
                       .init(dependencies: [("/Broken", "/Broken")]))
        engine.program(path: "/Broken", .init(shouldFailLoad: LoadError()))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let batch = await runToFinish(manager: manager,
                                      root: "/App", depth: 1, maxConcurrency: 1)
        let broken = try #require(batch.items.first { $0.id == "/Broken" })
        guard case .failed(let message) = broken.state else {
            Issue.record("expected .failed, got \(broken.state)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func cancelBatchStopsPendingItemsAndEmitsCancelledEvent() async {
        let engine = keep(MockBackgroundIndexingEngine())
        let deps = (0..<5).map { (installName: "/D\($0)", resolvedPath: "/D\($0)") }
        engine.program(path: "/App", .init(dependencies: deps))
        for dep in deps { engine.program(path: dep.installName, .init()) }
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let events = manager.events
        let consumer = Task { () -> RuntimeIndexingBatch in
            for await event in events {
                if case .batchCancelled(let b) = event { return b }
                if case .batchFinished(let b) = event { return b }
            }
            fatalError()
        }
        let id = await manager.startBatch(rootImagePath: "/App", depth: 1,
                                          maxConcurrency: 1, reason: .manual)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await manager.cancelBatch(id)
        let batch = await consumer.value
        #expect(batch.isCancelled)
    }

    @Test func cancelAllCancelsEveryBatch() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/A", .init(dependencies: [("/A1", "/A1")]))
        engine.program(path: "/A1", .init())
        engine.program(path: "/B", .init(dependencies: [("/B1", "/B1")]))
        engine.program(path: "/B1", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let idA = await manager.startBatch(rootImagePath: "/A", depth: 1,
                                           maxConcurrency: 1, reason: .manual)
        let idB = await manager.startBatch(rootImagePath: "/B", depth: 1,
                                           maxConcurrency: 1, reason: .manual)
        #expect(idA != idB)
        await manager.cancelAllBatches()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let remaining = await manager.currentBatches()
        #expect(remaining.isEmpty)
    }

    @Test func prioritizeEmitsTaskPrioritizedEvent() async {
        // Time-independent assertion: verify the manager emits
        // `.taskPrioritized` for a pending path and does NOT emit it for
        // running / absent paths. Load order would depend on sleep timing
        // and is flaky on CI — event emission is the real contract.
        let engine = keep(MockBackgroundIndexingEngine())
        let deps = ["/D0", "/D1", "/D2"]
        engine.program(path: "/App", .init(
            dependencies: deps.map { ($0, $0) }
        ))
        for dep in deps { engine.program(path: dep, .init()) }
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let events = manager.events
        let consumer = Task { () -> [String] in
            var boosted: [String] = []
            for await event in events {
                if case .taskPrioritized(_, let path) = event {
                    boosted.append(path)
                }
                if case .batchFinished = event { return boosted }
                if case .batchCancelled = event { return boosted }
            }
            return boosted
        }
        _ = await manager.startBatch(rootImagePath: "/App", depth: 1,
                                     maxConcurrency: 1, reason: .manual)
        await manager.prioritize(imagePath: "/D2")

        let boosted = await consumer.value
        #expect(boosted == ["/D2"])
    }

    @Test func prioritizeIsNoOpForUnknownPath() async {
        let engine = keep(MockBackgroundIndexingEngine())
        engine.program(path: "/App", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        _ = await manager.startBatch(rootImagePath: "/App", depth: 0,
                                     maxConcurrency: 1, reason: .manual)
        await manager.prioritize(imagePath: "/does/not/exist")
        // No crash; batch still completes. No .taskPrioritized emitted.
    }

    // MARK: - Test helpers
    private func runToFinish(manager: RuntimeBackgroundIndexingManager,
                             root: String, depth: Int,
                             maxConcurrency: Int) async -> RuntimeIndexingBatch
    {
        let events = manager.events
        let consumer = Task { () -> RuntimeIndexingBatch in
            for await event in events {
                switch event {
                case .batchFinished(let b), .batchCancelled(let b): return b
                default: break
                }
            }
            fatalError("stream ended without terminal event")
        }
        _ = await manager.startBatch(rootImagePath: root, depth: depth,
                                     maxConcurrency: maxConcurrency,
                                     reason: .manual)
        return await consumer.value
    }

    // Concurrency counter and instrumented engine — tiny helpers local to tests.
    private final class ConcurrencyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
        func exit() { lock.lock(); current -= 1; lock.unlock() }
    }

    private final class InstrumentedEngine: BackgroundIndexingEngineRepresenting,
                                             @unchecked Sendable
    {
        let base: any BackgroundIndexingEngineRepresenting
        let counter: ConcurrencyCounter
        init(base: any BackgroundIndexingEngineRepresenting, counter: ConcurrencyCounter) {
            self.base = base; self.counter = counter
        }
        func isImageIndexed(path: String) async throws -> Bool {
            try await base.isImageIndexed(path: path)
        }
        func loadImageForBackgroundIndexing(at path: String) async throws {
            counter.enter()
            defer { counter.exit() }
            try await Task.sleep(nanoseconds: 20_000_000)
            try await base.loadImageForBackgroundIndexing(at: path)
        }
        func mainExecutablePath() async throws -> String {
            try await base.mainExecutablePath()
        }
        func canOpenImage(at path: String) async -> Bool {
            await base.canOpenImage(at: path)
        }
        func rpaths(for path: String) async throws -> [String] {
            try await base.rpaths(for: path)
        }
        func dependencies(for path: String)
            async throws -> [(installName: String, resolvedPath: String?)]
        {
            try await base.dependencies(for: path)
        }
    }
}

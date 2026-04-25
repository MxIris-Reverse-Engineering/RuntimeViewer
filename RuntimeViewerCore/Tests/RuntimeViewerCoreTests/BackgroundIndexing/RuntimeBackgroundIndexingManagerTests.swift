import XCTest
import Semaphore
@testable import RuntimeViewerCore

final class RuntimeBackgroundIndexingManagerTests: XCTestCase {
    func test_currentBatches_initiallyEmpty() async {
        let engine = MockBackgroundIndexingEngine()
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let batches = await manager.currentBatches()
        XCTAssertTrue(batches.isEmpty)
    }

    func test_events_streamYieldsBatchStarted_thenFinished_forEmptyGraph() async {
        let engine = MockBackgroundIndexingEngine()
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

        let id = await manager.startBatch(rootImagePath: "/fake/Root",
                                          depth: 0, maxConcurrency: 1,
                                          reason: .manual)
        XCTAssertNotNil(id)
        let finalSeen = await consumer.value
        XCTAssertEqual(finalSeen, ["started", "finished"])
    }

    func test_expand_emptyWhenRootAlreadyIndexed() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init(isIndexed: true))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 5)
        XCTAssertTrue(items.isEmpty)
    }

    func test_expand_depth1_includesRootAndDirectDeps() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init(
            dependencies: [("/UIKit", "/UIKit"), ("/Foundation", "/Foundation")]
        ))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        XCTAssertEqual(Set(items.map(\.id)),
                       Set(["/App", "/UIKit", "/Foundation"]))
    }

    func test_expand_depth1_doesNotIncludeSecondLevel() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/UIKit", "/UIKit")]))
        engine.program(path: "/UIKit",
                       .init(dependencies: [("/CoreGraphics", "/CoreGraphics")]))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        XCTAssertEqual(Set(items.map(\.id)), Set(["/App", "/UIKit"]))
    }

    func test_expand_skipsAlreadyIndexedDeps() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/UIKit", "/UIKit"),
                                            ("/Foundation", "/Foundation")]))
        engine.program(path: "/UIKit", .init(isIndexed: true))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        XCTAssertEqual(Set(items.map(\.id)), Set(["/App", "/Foundation"]))
    }

    func test_expand_unresolvedInstallNameBecomesFailedItem() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App", .init(
            dependencies: [("@rpath/Missing", nil)]
        ))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 1)
        let missing = items.first { $0.id == "@rpath/Missing" }
        XCTAssertNotNil(missing)
        if case .failed = missing?.state {} else { XCTFail("expected failed state") }
    }

    func test_expand_dedupsSharedDependencies() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/A", "/A"), ("/B", "/B")]))
        engine.program(path: "/A",
                       .init(dependencies: [("/Shared", "/Shared")]))
        engine.program(path: "/B",
                       .init(dependencies: [("/Shared", "/Shared")]))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)
        let items = await manager.expandDependencyGraph(rootPath: "/App", depth: 2)
        let sharedCount = items.filter { $0.id == "/Shared" }.count
        XCTAssertEqual(sharedCount, 1)
    }

    func test_batch_indexesAllPendingItems() async {
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/A", "/A"), ("/B", "/B")]))
        engine.program(path: "/A", .init())
        engine.program(path: "/B", .init())
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let finishedBatch = await runToFinish(manager: manager,
                                              root: "/App", depth: 1,
                                              maxConcurrency: 2)
        XCTAssertTrue(finishedBatch.items.allSatisfy { $0.state == .completed })
        let indexed = engine.loadedOrder()
        XCTAssertEqual(Set(indexed), Set(["/App", "/A", "/B"]))
    }

    func test_batch_respectsMaxConcurrency() async {
        let engine = MockBackgroundIndexingEngine()
        // 6 dependencies, concurrency cap 2 → never exceed 2 simultaneous loads
        let deps = (0..<6).map { (installName: "/D\($0)", resolvedPath: "/D\($0)") }
        engine.program(path: "/App", .init(dependencies: deps))
        for dep in deps { engine.program(path: dep.installName, .init()) }

        // Monkey-patch engine with a concurrency-counting wrapper.
        let counter = ConcurrencyCounter()
        let wrapped = InstrumentedEngine(base: engine, counter: counter)
        let manager = RuntimeBackgroundIndexingManager(engine: wrapped)

        _ = await runToFinish(manager: manager, root: "/App", depth: 1,
                              maxConcurrency: 2)
        XCTAssertLessThanOrEqual(counter.peak, 2)
    }

    func test_batch_failedLoad_yieldsFailedTaskState() async {
        struct LoadError: Error {}
        let engine = MockBackgroundIndexingEngine()
        engine.program(path: "/App",
                       .init(dependencies: [("/Broken", "/Broken")]))
        engine.program(path: "/Broken", .init(shouldFailLoad: LoadError()))
        let manager = RuntimeBackgroundIndexingManager(engine: engine)

        let batch = await runToFinish(manager: manager,
                                      root: "/App", depth: 1, maxConcurrency: 1)
        let broken = batch.items.first { $0.id == "/Broken" }
        XCTAssertNotNil(broken)
        guard case .failed(let message) = broken?.state else {
            XCTFail("expected .failed"); return
        }
        XCTAssertFalse(message.isEmpty)
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

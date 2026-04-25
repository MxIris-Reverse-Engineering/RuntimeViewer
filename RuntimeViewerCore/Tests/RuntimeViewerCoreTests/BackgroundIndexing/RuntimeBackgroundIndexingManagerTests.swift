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
}

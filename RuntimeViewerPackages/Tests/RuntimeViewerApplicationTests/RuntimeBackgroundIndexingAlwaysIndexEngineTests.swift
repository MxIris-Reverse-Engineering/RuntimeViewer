import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// Always Index rows reach only the engines they apply to. Before rows could name engines, every
/// document dispatched the whole list to whatever engine it was on, so each image was indexed once
/// per engine — My Mac, Mac Catalyst, every attached process and every device.
///
/// The engines are in-process ones filed under device scopes of their own, so each test can tell
/// engines apart without a device. Where a test proves that something was *not* dispatched, it
/// waits for a batch dispatched later from the same pass instead of waiting out a delay: the
/// coordinator starts a pass's batches in list order, so the later batch landing means the earlier
/// one would already have started.
@Suite("Always Index per engine", .serialized)
@MainActor
struct RuntimeBackgroundIndexingAlwaysIndexEngineTests {
    private static let libobjc = "libobjc.A.dylib"
    private static let libdispatch = "libdispatch.dylib"
    private static let foundation = "Foundation"

    @Test("a document dispatches only the rows that apply to its engine")
    func dispatchesOnlyRowsForItsEngine() async throws {
        let engine = try await Self.makeEngine(deviceID: "DEVICE-A")
        let otherEngine = Self.otherEngineReference(deviceID: "DEVICE-B")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableAlwaysIndex(in: environment, entries: [
            Self.entry(Self.libdispatch, limitedTo: [otherEngine]),
            Self.entry(Self.libobjc, limitedTo: [Settings.Indexing.EngineReference(engine: engine)]),
        ])
        environment.startBackgroundWork()
        let coordinator = try environment.documentState.joinedIndexingCoordinator()
        defer { withExtendedLifetime((environment, coordinator)) {} }

        try await Self.waitForAlwaysIndexBatch(Self.libobjc, in: coordinator)
        #expect(try await Self.alwaysIndexBatches(Self.libdispatch, in: coordinator).isEmpty)
        await engine.stop()
    }

    @Test("a row for all engines is dispatched on every engine")
    func rowForAllEnginesDispatchesEverywhere() async throws {
        let firstEngine = try await Self.makeEngine(deviceID: "DEVICE-A")
        let secondEngine = try await Self.makeEngine(deviceID: "DEVICE-B")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: firstEngine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: secondEngine)
        // A row as persisted before rows could name engines.
        Self.enableAlwaysIndex(in: firstEnvironment, entries: [Settings.Indexing.AlwaysIndexEntry(identifier: Self.libobjc)])
        Self.enableAlwaysIndex(in: secondEnvironment, entries: [Settings.Indexing.AlwaysIndexEntry(identifier: Self.libobjc)])
        firstEnvironment.startBackgroundWork()
        let firstCoordinator = try firstEnvironment.documentState.joinedIndexingCoordinator()
        secondEnvironment.startBackgroundWork()
        let secondCoordinator = try secondEnvironment.documentState.joinedIndexingCoordinator()
        defer { withExtendedLifetime((firstEnvironment, secondEnvironment, firstCoordinator, secondCoordinator)) {} }

        try await Self.waitForAlwaysIndexBatch(Self.libobjc, in: firstCoordinator)
        try await Self.waitForAlwaysIndexBatch(Self.libobjc, in: secondCoordinator)
        await firstEngine.stop()
        await secondEngine.stop()
    }

    @Test("changing another engine's choice on a row does not dispatch it again here")
    func otherEnginesChoiceDoesNotRedispatch() async throws {
        let engine = try await Self.makeEngine(deviceID: "DEVICE-A")
        let thisEngine = Settings.Indexing.EngineReference(engine: engine)
        let otherEngine = Self.otherEngineReference(deviceID: "DEVICE-B")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableAlwaysIndex(in: environment, entries: [Self.entry(Self.libobjc, limitedTo: [thisEngine])])
        environment.startBackgroundWork()
        let coordinator = try environment.documentState.joinedIndexingCoordinator()
        defer { withExtendedLifetime((environment, coordinator)) {} }
        try await Self.waitForAlwaysIndexBatch(Self.libobjc, in: coordinator)

        // The libobjc row gains the other engine; the new libdispatch row marks the end of the
        // pass this edit triggers.
        environment.make {
            environment.settings.indexing.custom.entries = [
                Self.entry(Self.libobjc, limitedTo: [thisEngine, otherEngine]),
                Self.entry(Self.libdispatch, limitedTo: [thisEngine]),
            ]
        }

        try await Self.waitForAlwaysIndexBatch(Self.libdispatch, in: coordinator)
        #expect(try await Self.alwaysIndexBatches(Self.libobjc, in: coordinator).count == 1)
        await engine.stop()
    }

    @Test("taking its engine off a row stops dispatching it there and lets a running batch finish")
    func removingEngineStopsFutureDispatchesOnly() async throws {
        let engine = try await Self.makeEngine(deviceID: "DEVICE-A")
        let thisEngine = Settings.Indexing.EngineReference(engine: engine)
        let otherEngine = Self.otherEngineReference(deviceID: "DEVICE-B")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Foundation takes seconds to index on a fresh engine, so its batch is still running when
        // the row changes.
        Self.enableAlwaysIndex(in: environment, entries: [Self.entry(Self.foundation, limitedTo: [thisEngine])])
        environment.startBackgroundWork()
        let coordinator = try environment.documentState.joinedIndexingCoordinator()
        defer { withExtendedLifetime((environment, coordinator)) {} }
        let runningBatch = try #require(
            try await nextValue(from: coordinator.batchesObservable, timeout: 60) { batches in
                batches.contains { $0.reason == .alwaysIndex(identifier: Self.foundation) }
            }
            .first { $0.reason == .alwaysIndex(identifier: Self.foundation) }
        )

        environment.make {
            environment.settings.indexing.custom.entries = [Self.entry(Self.foundation, limitedTo: [otherEngine])]
        }

        let history = try await nextValue(from: coordinator.historyObservable, timeout: 120) { history in
            history.contains { $0.id == runningBatch.id }
        }
        let finishedBatch = try #require(history.first { $0.id == runningBatch.id })
        #expect(!finishedBatch.isCancelled)

        // The manager hands a running batch's id back to a second dispatch of its image, so only
        // a pass after the batch ended can show whether the row is still dispatched here. The new
        // libobjc row marks the end of that pass.
        environment.make {
            environment.settings.indexing.custom.entries = [
                Self.entry(Self.foundation, limitedTo: [otherEngine]),
                Self.entry(Self.libobjc, limitedTo: [thisEngine]),
            ]
        }

        try await Self.waitForAlwaysIndexBatch(Self.libobjc, in: coordinator)
        #expect(try await Self.alwaysIndexBatches(Self.foundation, in: coordinator).count == 1)
        await engine.stop()
    }

    @Test("after an engine swap the rows are matched against the new engine")
    func engineSwapMatchesRowsAgainstNewEngine() async throws {
        let firstEngine = try await Self.makeEngine(deviceID: "DEVICE-A")
        let secondEngine = try await Self.makeEngine(deviceID: "DEVICE-B")
        let environment = ViewModelTestEnvironment(runtimeEngine: firstEngine)
        Self.enableAlwaysIndex(in: environment, entries: [
            Self.entry(Self.libdispatch, limitedTo: [Settings.Indexing.EngineReference(engine: firstEngine)]),
            Self.entry(Self.libobjc, limitedTo: [Settings.Indexing.EngineReference(engine: secondEngine)]),
        ])
        environment.startBackgroundWork()
        let coordinator = try environment.documentState.joinedIndexingCoordinator()
        defer { withExtendedLifetime((environment, coordinator)) {} }
        try await Self.waitForAlwaysIndexBatch(Self.libdispatch, in: coordinator)
        #expect(try await Self.alwaysIndexBatches(Self.libobjc, in: coordinator).isEmpty)

        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(secondEngine)) }
        // The second engine's own coordinator: what the document shows follows its engine.
        let secondCoordinator = try environment.documentState.joinedIndexingCoordinator()
        defer { withExtendedLifetime(secondCoordinator) {} }

        try await Self.waitForAlwaysIndexBatch(Self.libobjc, in: secondCoordinator)
        #expect(try await Self.alwaysIndexBatches(Self.libdispatch, in: secondCoordinator).isEmpty)
        await firstEngine.stop()
        await secondEngine.stop()
    }

    // MARK: - Support

    /// A connected in-process engine filed under a device scope of its own.
    private static func makeEngine(deviceID: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(
            source: .local,
            engineID: "RuntimeBackgroundIndexingAlwaysIndexEngineTests.\(deviceID)",
            bookmarkScope: .identified(.bonjour(deviceID: deviceID, processName: "TestProcess", role: .client))
        )
        try await engine.connect()
        return engine
    }

    /// A reference to an engine no test connects.
    private static func otherEngineReference(deviceID: String) -> Settings.Indexing.EngineReference {
        Settings.Indexing.EngineReference(
            engine: RuntimeEngine(
                source: .local,
                bookmarkScope: .identified(.bonjour(deviceID: deviceID, processName: "TestProcess", role: .client))
            )
        )
    }

    /// Turns on Always Index alone, with `entries`. Heuristic discovery stays off so the only
    /// batches are the rows'.
    private static func enableAlwaysIndex(in environment: ViewModelTestEnvironment, entries: [Settings.Indexing.AlwaysIndexEntry]) {
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = entries
    }

    private static func entry(_ identifier: String, limitedTo engines: [Settings.Indexing.EngineReference]) -> Settings.Indexing.AlwaysIndexEntry {
        Settings.Indexing.AlwaysIndexEntry(identifier: identifier, appliesToAllEngines: false, engines: engines)
    }

    /// Waits until a batch for the row `identifier` has finished.
    private static func waitForAlwaysIndexBatch(_ identifier: String, in coordinator: RuntimeBackgroundIndexingCoordinator) async throws {
        _ = try await nextValue(from: coordinator.historyObservable, timeout: 60) { history in
            history.contains { $0.reason == .alwaysIndex(identifier: identifier) }
        }
    }

    /// Every batch the coordinator has seen for the row `identifier`, running or finished.
    private static func alwaysIndexBatches(_ identifier: String, in coordinator: RuntimeBackgroundIndexingCoordinator) async throws -> [RuntimeIndexingBatch] {
        let runningBatches = try await nextValue(from: coordinator.batchesObservable)
        let finishedBatches = try await nextValue(from: coordinator.historyObservable)
        return (runningBatches + finishedBatches).filter { $0.reason == .alwaysIndex(identifier: identifier) }
    }
}

import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The engine's background work as the first document on the engine starts it: its three
/// coordinators come into being with it, and the engine's indexing starts. Opening a document used
/// to start the indexing with a call of its own, `documentDidOpen()`, which every place that put a
/// document on an engine had to remember. The coordinators exist with their features turned off
/// too, so each starts once its feature is turned on.
@Suite("Engine background work as a document starts it", .serialized)
@MainActor
struct RuntimeEngineBackgroundWorkTests {
    private static let libobjc = "libobjc.A.dylib"

    @Test("starting a document's background work starts its engine's indexing")
    func startingStartsTheEnginesIndexing() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineBackgroundWorkTests.starting")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableAlwaysIndex(in: environment, rows: [Self.libobjc])

        environment.startBackgroundWork()

        let coordinator = try environment.documentState.joinedIndexingCoordinator()
        _ = try await nextValue(from: coordinator.historyObservable, timeout: 60) { history in
            history.contains { $0.reason == .alwaysIndex(identifier: Self.libobjc) }
        }
        environment.make { environment.documentState.documentWillClose() }
        await engine.stop()
    }

    /// The coordinator is read only once the switch is on: one brought into being then would find
    /// indexing on already, see no change to act on, and never start.
    @Test("indexing turned off as the document starts begins once it is turned on")
    func indexingTurnedOnLaterBegins() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeEngineBackgroundWorkTests.turnedOnLater")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableAlwaysIndex(in: environment, rows: [Self.libobjc])
        environment.settings.indexing.isEnabled = false
        environment.startBackgroundWork()

        environment.settings.indexing.isEnabled = true

        let coordinator = try environment.documentState.joinedIndexingCoordinator()
        _ = try await nextValue(from: coordinator.historyObservable, timeout: 60) { history in
            history.contains { $0.reason == .alwaysIndex(identifier: Self.libobjc) }
        }
        environment.make { environment.documentState.documentWillClose() }
        await engine.stop()
    }

    // MARK: - Support

    /// Turns on Always Index alone, with `rows` for every engine: heuristic discovery stays off,
    /// so the only batches are the rows'.
    private static func enableAlwaysIndex(in environment: ViewModelTestEnvironment, rows: [String]) {
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = rows.map { Settings.Indexing.AlwaysIndexEntry(identifier: $0) }
    }
}

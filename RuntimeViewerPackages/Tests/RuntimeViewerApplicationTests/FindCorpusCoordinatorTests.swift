import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The corpus coordinator against a private engine: a requested image gets
/// its corpus built, the switch going off drops every corpus, and a loaded
/// image is picked up from the engine's own notification.
@Suite("FindCorpusCoordinator", .serialized)
@MainActor
struct FindCorpusCoordinatorTests {
    private func waitForCoverage(
        of engine: RuntimeEngine,
        timeout: TimeInterval = 60,
        where predicate: @escaping (RuntimeInterfaceCorpusCoverage) -> Bool
    ) async throws -> RuntimeInterfaceCorpusCoverage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let coverage = try await engine.interfaceCorpusCoverage()
            if predicate(coverage) { return coverage }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await engine.interfaceCorpusCoverage()
    }

    @Test("a requested image gets its corpus built")
    func requestBuildsCorpus() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.request", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestBuild(of: TestImages.libobjc)

        let coverage = try await waitForCoverage(of: engine) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }
        #expect(coverage.statesByImagePath[TestImages.libobjc]?.isBuilt == true)
        #expect(coverage.residentByteCount > 0)
        await engine.stop()
    }

    @Test("turning the switch off drops every corpus; turning it on rebuilds the indexed images")
    func switchOffDropsCorpora() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.switch", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        // The coordinator queues every indexed image on creation.
        _ = try await waitForCoverage(of: engine) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }

        environment.settings.search.isCorpusEnabled = false
        let dropped = try await waitForCoverage(of: engine) { $0.statesByImagePath.isEmpty }
        #expect(dropped.statesByImagePath.isEmpty)

        environment.settings.search.isCorpusEnabled = true
        let rebuilt = try await waitForCoverage(of: engine) { $0.statesByImagePath[TestImages.libobjc]?.isBuilt == true }
        #expect(rebuilt.statesByImagePath[TestImages.libobjc]?.isBuilt == true)
        await engine.stop()
    }

    @Test("the resident limit from Settings reaches the engine")
    func residentLimitReachesEngine() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindCorpusCoordinatorTests.limit", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.residentByteLimitMegabytes = 96
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        let coverage = try await waitForCoverage(of: engine) { $0.residentByteLimit == 96 * 1024 * 1024 }
        #expect(coverage.residentByteLimit == 96 * 1024 * 1024)
        await engine.stop()
    }
}

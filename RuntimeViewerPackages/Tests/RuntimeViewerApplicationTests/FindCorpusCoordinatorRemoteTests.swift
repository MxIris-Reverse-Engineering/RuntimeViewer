#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The corpus coordinator on the engine the app actually runs "My Mac" on: a
/// `.local` engine forwarding to the local-runtime service, here an anonymous
/// listener in this process. The in-process engine the other coordinator
/// suites use takes none of the paths a connection takes.
@Suite("FindCorpusCoordinator over the local runtime service", .serialized)
@MainActor
struct FindCorpusCoordinatorRemoteTests {
    private static func isBuilding(_ state: RuntimeInterfaceCorpusBuildState?) -> Bool {
        if case .building = state { return true }
        return false
    }

    /// Polls the serving engine's own coverage, not the coordinator's view of it.
    private static func waitForServingCoverage(
        of engine: RuntimeEngine,
        timeout: TimeInterval,
        where predicate: @escaping (RuntimeInterfaceCorpusCoverage) -> Bool
    ) async throws -> RuntimeInterfaceCorpusCoverage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let coverage = try await engine.interfaceCorpusCoverage()
            if predicate(coverage) { return coverage }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await engine.interfaceCorpusCoverage()
    }

    @Test("cancelling a build over the local runtime service stops it there, and the row stays gone")
    func cancelReachesTheServingProcess() async throws {
        let fixture = try await LocalRuntimeServiceFixture.make(label: "FindCorpusCoordinatorRemoteTests.cancel")
        defer { Task { await fixture.stop() } }
        try await fixture.serving.loadImage(at: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: fixture.client)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestBuild(of: TestImages.foundation)
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { Self.isBuilding($0[TestImages.foundation]) }

        coordinator.cancelBuild(of: TestImages.foundation)

        // This document was the build's only subscriber, so the service gives
        // the build up.
        let coverage = try await Self.waitForServingCoverage(of: fixture.serving, timeout: 5) { $0.statesByImagePath[TestImages.foundation] == nil }
        #expect(coverage.statesByImagePath[TestImages.foundation] == nil, "the local runtime service kept building: \(String(describing: coverage.statesByImagePath[TestImages.foundation]))")

        // And a refresh does not bring the row back.
        coordinator.refreshCoverage()
        let states = try await values(from: coordinator.$buildStatesByImagePath.asDriver(), during: 1)
        #expect(states.allSatisfy { $0[TestImages.foundation] == nil }, "the cancelled row came back from the coverage")
    }

    @Test("a build the service gives up leaves no failed entry in the history")
    func storeCancellationIsNotAFailure() async throws {
        let fixture = try await LocalRuntimeServiceFixture.make(label: "FindCorpusCoordinatorRemoteTests.storeCancellation")
        defer { Task { await fixture.stop() } }
        try await fixture.serving.loadImage(at: TestImages.foundation)
        let environment = ViewModelTestEnvironment(runtimeEngine: fixture.client)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestBuild(of: TestImages.foundation)
        _ = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 60) { Self.isBuilding($0[TestImages.foundation]) }

        // What a transformer change in another window does: the service's
        // store gives the build up for every subscriber.
        try await fixture.serving.evictInterfaceCorpus(for: nil)

        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 20) { $0[TestImages.foundation]?.isActive != true }
        #expect(states[TestImages.foundation] == nil, "the given-up build left \(String(describing: states[TestImages.foundation]))")
        let recordedFailure = coordinator.finishedBuilds.first { finishedBuild in
            guard finishedBuild.imagePath == TestImages.foundation else { return false }
            if case .failed = finishedBuild.outcome { return true }
            return false
        }
        #expect(recordedFailure == nil, "a build the service gave up was recorded as \(String(describing: recordedFailure?.outcome))")
    }
}

#endif

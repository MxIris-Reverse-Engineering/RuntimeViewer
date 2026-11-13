#if os(macOS)

import Foundation
import Testing
import Dependencies
import RuntimeViewerCore
@testable import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Letting an offline engine's process go while no document is on it. The
/// documents coming and going are the background-work registry's occupancy
/// changes, sent here directly; the engine reads its file from a
/// `RuntimeOfflineServiceHost` over an anonymous listener, as in the manager's
/// own suite.
@Suite("RuntimeOfflineEngineParking", .serialized)
@MainActor
struct RuntimeOfflineEngineParkingTests {
    private struct Fixture {
        let manager: RuntimeEngineManager
        let parking: RuntimeOfflineEngineParking
        let registry: RuntimeEngineBackgroundWorkRegistry
        let host: RuntimeOfflineServiceHost
    }

    private static func makeFixture() throws -> Fixture {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeOfflineServiceHost(connection: listener)
        host.activate()
        manager.offlineEngineCredential = { file in
            .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeOfflineService.launchPayload(for: file))))
        }
        return try withDependencies {
            $0.runtimeEngineManager = manager
        } operation: {
            @Dependency(\.runtimeEngineBackgroundWorkRegistry) var registry
            let parking = RuntimeOfflineEngineParking()
            parking.gracePeriod = .milliseconds(100)
            parking.start()
            return Fixture(manager: manager, parking: parking, registry: registry, host: host)
        }
    }

    private static func file() throws -> RuntimeOfflineFile {
        try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
    }

    @Test("An offline engine nobody is on is suspended once the grace period is over")
    func vacatedEngineIsSuspended() async throws {
        let fixture = try Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let engine = try await fixture.manager.runtimeEngine(reading: try Self.file())

        fixture.registry.occupancyChanges.send(.vacated(engine))

        #expect(fixture.parking.isSuspensionPending(for: engine))
        let suspended = await pollUntil { fixture.manager.isOfflineEngineSuspended(engine) }
        #expect(suspended, "the engine was not suspended after the grace period")
        #expect(!fixture.parking.isSuspensionPending(for: engine))
        #expect(fixture.manager.offlineRuntimeEngines.contains { $0 === engine })
    }

    @Test("A document coming back within the grace period keeps the engine running")
    func occupiedAgainInTimeKeepsTheEngine() async throws {
        let fixture = try Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let engine = try await fixture.manager.runtimeEngine(reading: try Self.file())

        fixture.registry.occupancyChanges.send(.vacated(engine))
        fixture.registry.occupancyChanges.send(.occupied(engine))
        try await Task.sleep(for: .milliseconds(300))

        #expect(!fixture.manager.isOfflineEngineSuspended(engine))
        #expect(!fixture.parking.isSuspensionPending(for: engine))
        #expect(engine.state == .connected)
    }

    @Test("An engine that is not an offline one is left alone")
    func otherEnginesAreLeftAlone() async throws {
        let fixture = try Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let engine = RuntimeEngine(source: .local, engineID: "offline-engine-parking-test.local")

        fixture.registry.occupancyChanges.send(.vacated(engine))

        #expect(!fixture.parking.isSuspensionPending(for: engine))
    }
}

private func pollUntil(
    timeout: Duration = .seconds(10),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

#endif

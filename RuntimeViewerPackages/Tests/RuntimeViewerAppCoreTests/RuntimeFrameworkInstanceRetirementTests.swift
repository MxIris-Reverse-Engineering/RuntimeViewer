#if os(macOS)

import Foundation
import Testing
import Dependencies
import RuntimeViewerCore
@testable import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Ending a framework instance once no document is on its engine. The
/// documents coming and going are the background-work registry's occupancy
/// changes, sent here directly; the instance is a `RuntimeFrameworkServiceHost`
/// over an anonymous listener.
@Suite("RuntimeFrameworkInstanceRetirement", .serialized)
@MainActor
struct RuntimeFrameworkInstanceRetirementTests {
    private struct Fixture {
        let manager: RuntimeEngineManager
        let registry: RuntimeEngineBackgroundWorkRegistry
        let retirement: RuntimeFrameworkInstanceRetirement
        let host: RuntimeFrameworkServiceHost
    }

    private static func makeFixture() throws -> Fixture {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeFrameworkServiceHost(connection: listener)
        host.activate()
        manager.frameworkInstanceLaunching = .init { instance in
            .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeFrameworkService.launchPayload(for: instance))))
        }
        return try withDependencies {
            $0.runtimeEngineManager = manager
        } operation: {
            @Dependency(\.runtimeEngineBackgroundWorkRegistry) var registry
            let retirement = RuntimeFrameworkInstanceRetirement()
            retirement.start()
            return Fixture(manager: manager, registry: registry, retirement: retirement, host: host)
        }
    }

    @Test("a framework instance nobody is on ends at once")
    func retirementTerminatesAFrameworkInstanceWhenVacated() async throws {
        let fixture = try Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let engine = try fixture.manager.startFrameworkInstance(RuntimeFrameworkInstance(loading: [URL(fileURLWithPath: "/A/Foo.framework")]))
        try await fixture.manager.waitUntilFrameworkInstanceIsReady(engine)

        fixture.registry.occupancyChanges.send(.vacated(engine))

        #expect(fixture.manager.frameworkInstanceEngines.isEmpty)
        let stopped = await pollUntil(timeout: .seconds(10)) { !engine.state.isReady }
        #expect(stopped)
    }

    @Test("a document coming to a framework instance keeps it")
    func occupiedInstanceIsKept() async throws {
        let fixture = try Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let engine = try fixture.manager.startFrameworkInstance(RuntimeFrameworkInstance(loading: [URL(fileURLWithPath: "/A/Foo.framework")]))
        defer { fixture.manager.terminateFrameworkInstance(engine) }
        try await fixture.manager.waitUntilFrameworkInstanceIsReady(engine)

        fixture.registry.occupancyChanges.send(.occupied(engine))

        #expect(fixture.manager.frameworkInstanceEngines.contains { $0 === engine })
    }

    @Test("other engines going unoccupied are left alone")
    func retirementLeavesOtherEnginesAlone() async throws {
        let fixture = try Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let engine = try fixture.manager.startFrameworkInstance(RuntimeFrameworkInstance(loading: [URL(fileURLWithPath: "/A/Foo.framework")]))
        defer { fixture.manager.terminateFrameworkInstance(engine) }
        let otherEngine = RuntimeEngine(source: .local, engineID: "RuntimeFrameworkInstanceRetirementTests.other")

        fixture.registry.occupancyChanges.send(.vacated(otherEngine))

        #expect(fixture.manager.frameworkInstanceEngines.contains { $0 === engine })
    }
}

#endif

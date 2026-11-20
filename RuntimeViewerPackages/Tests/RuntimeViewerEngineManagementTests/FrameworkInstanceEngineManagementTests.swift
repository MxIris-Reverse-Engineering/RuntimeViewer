#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// The manager's framework instances, each served the way the app's framework
/// service serves one — a `RuntimeFrameworkServiceHost` over an anonymous
/// listener in this process stands in for an instance — and a manager that
/// brings up nothing else.
@Suite("RuntimeEngineManager framework instances", .serialized)
@MainActor
struct FrameworkInstanceEngineManagementTests {
    private static func makeManager(serving instances: FrameworkServiceInstances) -> RuntimeEngineManager {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.frameworkInstanceLaunching = .init { instance in try instances.credential(for: instance) }
        return manager
    }

    private static func instance(named name: String) -> RuntimeFrameworkInstance {
        RuntimeFrameworkInstance(name: "\(name).framework (Isolated)", frameworkURL: URL(fileURLWithPath: "/A/\(name).framework"))
    }

    @Test("A framework instance forwards to an instance of its own and is listed under Isolated Frameworks")
    func startedInstanceIsListedUnderIsolatedFrameworks() async throws {
        let instances = FrameworkServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }

        let engine = try manager.startFrameworkInstance(Self.instance(named: "Foo"))
        try await manager.waitUntilFrameworkInstanceIsReady(engine)

        #expect(manager.frameworkInstanceEngines.map(\.engineID) == [engine.engineID])
        #expect(manager.runtimeEngines.contains { $0 === engine })
        #expect(engine.hostInfo.hostID == RuntimeHostInfo.frameworkInstances.hostID)
        let section = try #require(manager.runtimeEngineSections.first { $0.hostID == RuntimeHostInfo.frameworkInstances.hostID })
        #expect(section.hostName == "Isolated Frameworks")
        #expect(section.engines.map(\.engineID) == [engine.engineID])
        #expect(await engine.forwardsRequests)
        #expect(engine.state == .connected)
        #expect(instances.count == 1)
    }

    @Test("Each framework instance gets an instance of its own, the same frameworks included")
    func everyInstanceIsItsOwn() async throws {
        let instances = FrameworkServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }

        let first = try manager.startFrameworkInstance(Self.instance(named: "Foo"))
        let second = try manager.startFrameworkInstance(Self.instance(named: "Foo"))
        try await manager.waitUntilFrameworkInstanceIsReady(first)
        try await manager.waitUntilFrameworkInstanceIsReady(second)

        #expect(first !== second)
        #expect(first.source != second.source)
        #expect(manager.frameworkInstanceEngines.count == 2)
        #expect(instances.count == 2)
    }

    @Test("Ending a framework instance takes it off the list and stops its engine")
    func terminatedInstanceIsUnlisted() async throws {
        let instances = FrameworkServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let engine = try manager.startFrameworkInstance(Self.instance(named: "Foo"))
        try await manager.waitUntilFrameworkInstanceIsReady(engine)

        manager.terminateFrameworkInstance(engine)

        #expect(manager.frameworkInstanceEngines.isEmpty)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.frameworkInstances.hostID })
        let stopped = await pollUntil { engine.state != .connected }
        #expect(stopped)
    }

    @Test("An instance that never answers is taken off the list again, and waiting for it throws")
    func instanceThatNeverAnswersIsUnlisted() async throws {
        let instances = FrameworkServiceInstances(sendsUnreadablePayload: true)
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }

        let engine = try manager.startFrameworkInstance(Self.instance(named: "Foo"))

        await #expect(throws: (any Error).self) {
            try await manager.waitUntilFrameworkInstanceIsReady(engine)
        }
        let unlisted = await pollUntil { manager.frameworkInstanceEngines.isEmpty }
        #expect(unlisted)
    }

    @Test("A process that embeds no framework service cannot start one")
    func startFailsWhenTheServiceIsNotEmbedded() {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.frameworkInstanceLaunching = .unavailable

        #expect(throws: RuntimeFrameworkInstanceError.serviceUnavailable) {
            _ = try manager.startFrameworkInstance(Self.instance(named: "Foo"))
        }
        #expect(manager.frameworkInstanceEngines.isEmpty)
    }
}

extension LocalEngineManagerSuites {
    /// A framework instance borrows the shared cache's images from My Mac, as
    /// a process attached on this Mac does. My Mac is `RuntimeEngine.local`,
    /// in process here; the Mac Catalyst launch is stood in for.
    @Suite("Framework instance shared cache owners")
    @MainActor
    struct FrameworkInstanceSharedCacheOwnersTests {
        @Test("A framework instance borrows from My Mac")
        func frameworkInstanceBorrowsSharedCacheImagesFromMyMac() async throws {
            let macCatalystEngine = RuntimeEngine(source: .macCatalystClient, engineID: "framework-instance-owners.catalyst.\(UUID().uuidString)")
            let manager = RuntimeEngineManager(
                configuration: .application,
                startupHandler: { _ in },
                macCatalystLaunching: .init(makeConnectedEngine: { macCatalystEngine }, helperApplication: nil)
            )
            let instances = FrameworkServiceInstances()
            defer { Task { await instances.stopAll() } }
            manager.frameworkInstanceLaunching = .init { instance in try instances.credential(for: instance) }
            await manager.launchSystemRuntimeEngines()
            await manager.waitForMacCatalystLaunch()

            let engine = try manager.startFrameworkInstance(
                RuntimeFrameworkInstance(name: "Foo", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"))
            )
            defer { manager.terminateFrameworkInstance(engine) }
            try await manager.waitUntilFrameworkInstanceIsReady(engine)
            await manager.waitForSharedCacheOwnersUpdate()

            let owners = try #require(engine.sharedCacheOwners)
            #expect(owners.macOS === RuntimeEngine.local)
        }
    }
}

/// Stands in for the framework service: every credential asked for starts an
/// instance of its own, a host over an anonymous listener.
@MainActor
private final class FrameworkServiceInstances {
    private var hosts: [RuntimeFrameworkServiceHost] = []

    private let sendsUnreadablePayload: Bool

    init(sendsUnreadablePayload: Bool = false) {
        self.sendsUnreadablePayload = sendsUnreadablePayload
    }

    var count: Int { hosts.count }

    func credential(for instance: RuntimeFrameworkInstance) throws -> RuntimeConnectionCredential? {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeFrameworkServiceHost(connection: listener)
        host.activate()
        hosts.append(host)
        let payload = sendsUnreadablePayload ? Data("not an instance".utf8) : try RuntimeFrameworkService.launchPayload(for: instance)
        return .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(payload)))
    }

    func stopAll() async {
        for host in hosts {
            await host.stop()
        }
    }
}

private func pollUntil(
    timeout: Duration = .seconds(30),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

#endif

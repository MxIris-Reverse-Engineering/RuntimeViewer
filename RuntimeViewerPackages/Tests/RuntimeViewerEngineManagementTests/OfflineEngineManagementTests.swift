#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// The manager's offline group, with each file served the way the app's
/// offline service serves it — a `RuntimeOfflineServiceHost` over an
/// anonymous listener in this process stands in for an instance, one per
/// connection — and a manager that brings up nothing else.
@Suite("RuntimeEngineManager offline files", .serialized)
@MainActor
struct OfflineEngineManagementTests {
    /// Small, fat, and read alone unless a test pairs it.
    private static let filePath = "/usr/bin/true"

    private static func makeManager(serving instances: OfflineServiceInstances) -> RuntimeEngineManager {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.offlineEngineCredential = { file in try instances.credential(for: file) }
        return manager
    }

    private static func file() throws -> RuntimeOfflineFile {
        try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: filePath))
    }

    @Test("An offline engine forwards to an instance of its own and is listed under Offline Files, in a section of its own")
    func offlineEngineIsListedInItsOwnSection() async throws {
        let instances = OfflineServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()

        let engine = try await manager.runtimeEngine(reading: file)

        #expect(manager.offlineRuntimeEngines.map(\.engineID) == [engine.engineID])
        #expect(manager.runtimeEngines.contains { $0 === engine })
        #expect(engine.hostInfo.hostID == RuntimeHostInfo.offlineFiles.hostID)
        let section = try #require(manager.runtimeEngineSections.first { $0.hostID == RuntimeHostInfo.offlineFiles.hostID })
        #expect(section.hostName == RuntimeHostInfo.offlineFiles.hostName)
        #expect(section.engines.map(\.engineID) == [engine.engineID])
        #expect(manager.offlineFile(of: engine) == file)
        #expect(await engine.forwardsRequests)
        #expect(engine.state == .connected)
        #expect(instances.count == 1)
    }

    @Test("Asking for a listed file again returns its engine, without another instance")
    func sameFileReturnsTheListedEngine() async throws {
        let instances = OfflineServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)

        let again = try await manager.runtimeEngine(reading: file)

        #expect(again === engine)
        #expect(manager.offlineRuntimeEngines.count == 1)
        #expect(instances.count == 1)
    }

    @Test("A suspended engine stays listed; asking for its file again starts the same engine in a new instance")
    func suspendedEngineResumesAsTheSameObject() async throws {
        let instances = OfflineServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)

        await manager.suspendOfflineEngine(engine)

        #expect(manager.isOfflineEngineSuspended(engine))
        #expect(engine.state == .disconnected(error: nil))
        #expect(manager.offlineRuntimeEngines.contains { $0 === engine })
        #expect(manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.offlineFiles.hostID })

        let resumed = try await manager.runtimeEngine(reading: file)

        #expect(resumed === engine)
        #expect(!manager.isOfflineEngineSuspended(engine))
        #expect(engine.state == .connected)
        #expect(instances.count == 2, "a new instance should have read the file again")
        #expect(await pollUntil { await !engine.imageList.isEmpty })
    }

    @Test("Pairing a listed file with a dependency cache starts its engine over with the cache's images")
    func newPairingStartsTheEngineOver() async throws {
        let instances = OfflineServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)
        #expect(await pollUntil { await engine.imageList == [Self.filePath] })

        var pairedFile = file
        pairedFile.dependencyCache = .systemDyldSharedCache
        let restarted = try await manager.runtimeEngine(reading: pairedFile)

        #expect(restarted === engine)
        #expect(manager.offlineFile(of: engine) == pairedFile)
        #expect(instances.count == 2)
        #expect(await pollUntil { await engine.imageList.count > 1 }, "the paired cache's images did not arrive")
    }

    @Test("A process without an offline service cannot read files offline, and lists nothing")
    func withoutAServiceNothingIsListed() async throws {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.offlineEngineCredential = { _ in nil }

        await #expect(throws: RuntimeOfflineEngineError.self) {
            _ = try await manager.runtimeEngine(reading: try Self.file())
        }
        #expect(manager.offlineRuntimeEngines.isEmpty)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.offlineFiles.hostID })
    }

    @Test("Terminating an offline engine forgets it and its file")
    func terminatingForgetsTheEngine() async throws {
        let instances = OfflineServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)

        manager.terminateRuntimeEngine(for: file.source)

        #expect(manager.offlineRuntimeEngines.isEmpty)
        #expect(manager.offlineFile(of: engine) == nil)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.offlineFiles.hostID })
    }
}

/// Stands in for the offline service: every credential it hands out leads to
/// a new instance, a `RuntimeOfflineServiceHost` of its own.
@MainActor
private final class OfflineServiceInstances {
    private var hosts: [RuntimeOfflineServiceHost] = []

    var count: Int { hosts.count }

    func credential(for file: RuntimeOfflineFile) throws -> RuntimeConnectionCredential? {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeOfflineServiceHost(connection: listener)
        host.activate()
        hosts.append(host)
        return .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeOfflineService.launchPayload(for: file))))
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

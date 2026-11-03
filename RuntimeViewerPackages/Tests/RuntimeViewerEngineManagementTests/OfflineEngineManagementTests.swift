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

    @Test("A file's engine is listed at once, forwarding, before its instance has read the file")
    func engineIsListedBeforeItsFileIsRead() async throws {
        let instances = OfflineServiceInstances(startsHosts: false)
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()

        let engine = try await manager.startReading(file)

        #expect(manager.offlineRuntimeEngines.map(\.engineID) == [engine.engineID])
        #expect(manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.offlineFiles.hostID })
        #expect(manager.offlineFile(of: engine) == file)
        #expect(!engine.state.isReady)
        #expect(await engine.forwardsRequests)
        #expect(try await manager.startReading(file) === engine, "a second open should wait for the same read")

        instances.startHosts()
        try await manager.waitUntilFileIsRead(by: engine)

        #expect(engine.state == .connected)
        #expect(instances.count == 1)
        #expect(await pollUntil { await engine.imageList == [Self.filePath] })
    }

    @Test("A new engine whose file cannot be read is taken off the list again, and waiting for it says why")
    func unreadableFileIsTakenOffTheList() async throws {
        let instances = OfflineServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let missingFile = RuntimeOfflineFile(
            url: URL(fileURLWithPath: "/nonexistent/OfflineEngineManagementTests"),
            content: .machO(slice: nil),
            platform: nil,
            displayName: "OfflineEngineManagementTests"
        )

        let engine = try await manager.startReading(missingFile)
        #expect(manager.offlineRuntimeEngines.contains { $0 === engine })

        await #expect(throws: (any Error).self) {
            try await manager.waitUntilFileIsRead(by: engine)
        }
        #expect(manager.offlineRuntimeEngines.isEmpty)
        #expect(manager.offlineFile(of: engine) == nil)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.offlineFiles.hostID })
        #expect(engine.state == .disconnected(error: nil))
    }

    @Test("Suspending an engine whose file is still being read waits for the read, and leaves it stopped")
    func suspendingWaitsForTheReadUnderWay() async throws {
        let instances = OfflineServiceInstances(startsHosts: false)
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let engine = try await manager.startReading(try Self.file())

        let suspension = Task { await manager.suspendOfflineEngine(engine) }
        instances.startHosts()
        await suspension.value

        #expect(manager.isOfflineEngineSuspended(engine))
        #expect(engine.state == .disconnected(error: nil))
        #expect(manager.offlineRuntimeEngines.contains { $0 === engine })
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
/// a new instance, a `RuntimeOfflineServiceHost` of its own. Made with
/// `startsHosts: false`, an instance accepts nothing — and so reads nothing —
/// until `startHosts()`, which holds a read under way for as long as a test
/// needs it.
@MainActor
private final class OfflineServiceInstances {
    private var hosts: [RuntimeOfflineServiceHost] = []

    private var waitingHosts: [RuntimeOfflineServiceHost] = []

    private let startsHosts: Bool

    init(startsHosts: Bool = true) {
        self.startsHosts = startsHosts
    }

    var count: Int { hosts.count }

    func credential(for file: RuntimeOfflineFile) throws -> RuntimeConnectionCredential? {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeOfflineServiceHost(connection: listener)
        if startsHosts {
            host.activate()
        } else {
            waitingHosts.append(host)
        }
        hosts.append(host)
        return .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeOfflineService.launchPayload(for: file))))
    }

    func startHosts() {
        for host in waitingHosts {
            host.activate()
        }
        waitingHosts.removeAll()
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

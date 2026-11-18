#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// The manager's file group, with each file served the way the app's
/// file service serves it — a `RuntimeFileServiceHost` over an
/// anonymous listener in this process stands in for an instance, one per
/// connection — and a manager that brings up nothing else.
@Suite("RuntimeEngineManager files", .serialized)
@MainActor
struct FileEngineManagementTests {
    /// Small, fat, and read alone unless a test pairs it.
    private static let filePath = "/usr/bin/true"

    private static func makeManager(serving instances: FileServiceInstances) -> RuntimeEngineManager {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.fileReading = .inFileService { file in try instances.credential(for: file) }
        return manager
    }

    private static func file() throws -> RuntimeFile {
        try RuntimeFile(contentsOf: URL(fileURLWithPath: filePath))
    }

    @Test("A file engine forwards to an instance of its own and is listed under Files, in a section of its own")
    func fileEngineIsListedInItsOwnSection() async throws {
        let instances = FileServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()

        let engine = try await manager.runtimeEngine(reading: file)

        #expect(manager.fileRuntimeEngines.map(\.engineID) == [engine.engineID])
        #expect(manager.runtimeEngines.contains { $0 === engine })
        #expect(engine.hostInfo.hostID == RuntimeHostInfo.files.hostID)
        let section = try #require(manager.runtimeEngineSections.first { $0.hostID == RuntimeHostInfo.files.hostID })
        #expect(section.hostName == RuntimeHostInfo.files.hostName)
        #expect(section.engines.map(\.engineID) == [engine.engineID])
        #expect(manager.file(of: engine) == file)
        #expect(await engine.forwardsRequests)
        #expect(engine.state == .connected)
        #expect(instances.count == 1)
    }

    @Test("Asking for a listed file again returns its engine, without another instance")
    func sameFileReturnsTheListedEngine() async throws {
        let instances = FileServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)

        let again = try await manager.runtimeEngine(reading: file)

        #expect(again === engine)
        #expect(manager.fileRuntimeEngines.count == 1)
        #expect(instances.count == 1)
    }

    @Test("A suspended engine stays listed; asking for its file again starts the same engine in a new instance")
    func suspendedEngineResumesAsTheSameObject() async throws {
        let instances = FileServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)

        await manager.suspendFileEngine(engine)

        #expect(manager.isFileEngineSuspended(engine))
        #expect(engine.state == .disconnected(error: nil))
        #expect(manager.fileRuntimeEngines.contains { $0 === engine })
        #expect(manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })

        let resumed = try await manager.runtimeEngine(reading: file)

        #expect(resumed === engine)
        #expect(!manager.isFileEngineSuspended(engine))
        #expect(engine.state == .connected)
        #expect(instances.count == 2, "a new instance should have read the file again")
        #expect(await pollUntil { await !engine.imageList.isEmpty })
    }

    @Test("Pairing a listed file with a dependency cache starts its engine over with the cache's images")
    func newPairingStartsTheEngineOver() async throws {
        let instances = FileServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)
        #expect(await pollUntil { await engine.imageList == [Self.filePath] })

        var pairedFile = file
        pairedFile.dependencyCache = .systemDyldSharedCache
        let restarted = try await manager.runtimeEngine(reading: pairedFile)

        #expect(restarted === engine)
        #expect(manager.file(of: engine) == pairedFile)
        #expect(instances.count == 2)
        #expect(await pollUntil { await engine.imageList.count > 1 }, "the paired cache's images did not arrive")
    }

    @Test("A file's engine is listed at once, forwarding, before its instance has read the file")
    func engineIsListedBeforeItsFileIsRead() async throws {
        let instances = FileServiceInstances(startsHosts: false)
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()

        let engine = try await manager.startReading(file)

        #expect(manager.fileRuntimeEngines.map(\.engineID) == [engine.engineID])
        #expect(manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })
        #expect(manager.file(of: engine) == file)
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
        let instances = FileServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let missingFile = RuntimeFile(
            url: URL(fileURLWithPath: "/nonexistent/FileEngineManagementTests"),
            content: .machO(slice: nil),
            platform: nil,
            displayName: "FileEngineManagementTests"
        )

        let engine = try await manager.startReading(missingFile)
        #expect(manager.fileRuntimeEngines.contains { $0 === engine })

        await #expect(throws: (any Error).self) {
            try await manager.waitUntilFileIsRead(by: engine)
        }
        #expect(manager.fileRuntimeEngines.isEmpty)
        #expect(manager.file(of: engine) == nil)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })
        #expect(engine.state == .disconnected(error: nil))
    }

    @Test("Suspending an engine whose file is still being read waits for the read, and leaves it stopped")
    func suspendingWaitsForTheReadUnderWay() async throws {
        let instances = FileServiceInstances(startsHosts: false)
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let engine = try await manager.startReading(try Self.file())

        let suspension = Task { await manager.suspendFileEngine(engine) }
        instances.startHosts()
        await suspension.value

        #expect(manager.isFileEngineSuspended(engine))
        #expect(engine.state == .disconnected(error: nil))
        #expect(manager.fileRuntimeEngines.contains { $0 === engine })
    }

    @Test("A process without a file service cannot read files, and lists nothing")
    func withoutAServiceNothingIsListed() async throws {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.fileReading = .inFileService { _ in nil }

        await #expect(throws: RuntimeFileEngineError.self) {
            _ = try await manager.runtimeEngine(reading: try Self.file())
        }
        #expect(manager.fileRuntimeEngines.isEmpty)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })
    }

    @Test("Terminating a file engine forgets it and its file")
    func terminatingForgetsTheEngine() async throws {
        let instances = FileServiceInstances()
        let manager = Self.makeManager(serving: instances)
        defer { Task { await instances.stopAll() } }
        let file = try Self.file()
        let engine = try await manager.runtimeEngine(reading: file)

        manager.terminateRuntimeEngine(for: file.source)

        #expect(manager.fileRuntimeEngines.isEmpty)
        #expect(manager.file(of: engine) == nil)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })
    }

    // MARK: - Read in this process

    /// What every platform but the Mac does: no file service to read in, so
    /// the file is read by an engine of this process's own.
    private static func makeInProcessManager() -> RuntimeEngineManager {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.fileReading = .inThisProcess
        return manager
    }

    @Test("A file read in this process is read before startReading returns, by an engine that answers here")
    func fileReadInThisProcessIsReadBeforeStartReadingReturns() async throws {
        let manager = Self.makeInProcessManager()
        let file = try Self.file()

        let engine = try await manager.startReading(file)

        #expect(engine.state == .localOnly)
        #expect(!(await engine.forwardsRequests))
        #expect(await engine.imageList == [Self.filePath])
        #expect(manager.fileRuntimeEngines.map(\.engineID) == [engine.engineID])
        #expect(engine.hostInfo.hostID == RuntimeHostInfo.files.hostID)
        #expect(manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })
        #expect(manager.file(of: engine) == file)
        try await manager.waitUntilFileIsRead(by: engine)
        #expect(try await manager.runtimeEngine(reading: file) === engine)
    }

    @Test("Asking for a file while it is being read in this process waits for the same read")
    func fileBeingReadInThisProcessIsReadOnce() async throws {
        let manager = Self.makeInProcessManager()
        let file = try Self.file()

        async let first = manager.startReading(file)
        async let second = manager.startReading(file)
        let (firstEngine, secondEngine) = try await (first, second)

        #expect(firstEngine === secondEngine)
        #expect(manager.fileRuntimeEngines.count == 1)
    }

    @Test("A file that cannot be read in this process throws, and nothing is listed")
    func fileThatCannotBeReadInThisProcessIsNotListed() async throws {
        let manager = Self.makeInProcessManager()
        let missingFile = RuntimeFile(
            url: URL(fileURLWithPath: "/nonexistent/FileEngineManagementTests"),
            content: .machO(slice: nil),
            platform: nil,
            displayName: "FileEngineManagementTests"
        )

        await #expect(throws: (any Error).self) {
            _ = try await manager.startReading(missingFile)
        }
        #expect(manager.fileRuntimeEngines.isEmpty)
        #expect(!manager.runtimeEngineSections.contains { $0.hostID == RuntimeHostInfo.files.hostID })
    }

    /// There is no process to let go of: the parsed file lives in this one.
    @Test("A file engine read in this process is never suspended")
    func fileEngineReadInThisProcessIsNeverSuspended() async throws {
        let manager = Self.makeInProcessManager()
        let engine = try await manager.startReading(try Self.file())

        await manager.suspendFileEngine(engine)

        #expect(!manager.isFileEngineSuspended(engine))
        #expect(engine.state == .localOnly)
        try await manager.resumeFileEngine(engine)
        #expect(engine.state == .localOnly)
    }

    /// A Mac starts the engine over in a new instance with the other cache;
    /// here the engine was made with its images, and there is no instance to
    /// start over in.
    @Test("Pairing a file read in this process with another dependency cache throws, and leaves it as it was")
    func changingTheDependencyCacheOfAFileReadInThisProcessThrows() async throws {
        let manager = Self.makeInProcessManager()
        let file = try Self.file()
        let engine = try await manager.startReading(file)

        var pairedFile = file
        pairedFile.dependencyCache = .systemDyldSharedCache
        await #expect(throws: RuntimeFileEngineError.self) {
            _ = try await manager.startReading(pairedFile)
        }

        #expect(manager.file(of: engine) == file)
        #expect(manager.fileRuntimeEngines.count == 1)
        #expect(engine.state == .localOnly)
    }
}

/// Stands in for the file service: every credential it hands out leads to
/// a new instance, a `RuntimeFileServiceHost` of its own. Made with
/// `startsHosts: false`, an instance accepts nothing — and so reads nothing —
/// until `startHosts()`, which holds a read under way for as long as a test
/// needs it.
@MainActor
private final class FileServiceInstances {
    private var hosts: [RuntimeFileServiceHost] = []

    private var waitingHosts: [RuntimeFileServiceHost] = []

    private let startsHosts: Bool

    init(startsHosts: Bool = true) {
        self.startsHosts = startsHosts
    }

    var count: Int { hosts.count }

    func credential(for file: RuntimeFile) throws -> RuntimeConnectionCredential? {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeFileServiceHost(connection: listener)
        if startsHosts {
            host.activate()
        } else {
            waitingHosts.append(host)
        }
        hosts.append(host)
        return .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeFileService.launchPayload(for: file))))
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

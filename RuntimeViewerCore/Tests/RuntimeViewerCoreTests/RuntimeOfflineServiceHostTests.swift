#if os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// An offline file read out of process, with both processes played by this
/// one: a `RuntimeOfflineServiceHost` over an anonymous listener stands in for
/// an instance of the offline service, and a `.file` engine connected through
/// an endpoint carrying the file's launch payload stands in for the app's.
@Suite("RuntimeOfflineServiceHost", .serialized)
struct RuntimeOfflineServiceHostTests {
    /// Fat and tiny, so the engine reading it spends its time on the dyld
    /// shared cache it is paired with rather than on the file.
    private static let filePath = "/usr/bin/true"

    /// `/usr/bin/true`, paired with this Mac's dyld shared cache as the app
    /// pairs a macOS file.
    private static func pairedFile() throws -> RuntimeOfflineFile {
        var file = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: filePath))
        file.dependencyCache = .systemDyldSharedCache
        return file
    }

    private static func makeHost() throws -> (host: RuntimeOfflineServiceHost, endpoint: RuntimeXPCServiceEndpoint) {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeOfflineServiceHost(connection: listener)
        host.activate()
        return (host, endpoint)
    }

    private static func credential(for file: RuntimeOfflineFile, at endpoint: RuntimeXPCServiceEndpoint) throws -> RuntimeConnectionCredential {
        .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(try RuntimeOfflineService.launchPayload(for: file))))
    }

    @Test("A launch payload round-trips the file it names")
    func launchPayloadRoundTrips() throws {
        let file = try Self.pairedFile()

        let decoded = try RuntimeOfflineService.file(fromLaunchPayload: try RuntimeOfflineService.launchPayload(for: file))

        #expect(decoded == file)
    }

    @Test("A .file engine connected with the file's payload forwards, and lists what the service's engine reads")
    func connectingReceivesTheFilesImages() async throws {
        let file = try Self.pairedFile()
        let (host, endpoint) = try Self.makeHost()
        let client = RuntimeEngine(source: file.source, engineID: "offline-service-test.client")
        defer { Task { await client.stop(); await host.stop() } }

        try await client.connect(credential: Self.credential(for: file, at: endpoint))

        let serviceEngine = try #require(host.engine)
        let serviceImageList = await serviceEngine.imageList
        let received = await pollUntil {
            await client.imageList == serviceImageList && client.imageNodes.count == serviceEngine.imageNodes.count
        }
        #expect(received, "the client did not receive the service's image list and image nodes")
        #expect(await client.forwardsRequests)
        #expect(client.source == file.source)
        #expect(serviceImageList.first == Self.filePath)
        #expect(serviceImageList.count > 1, "the paired dyld shared cache's images are missing")
    }

    @Test("Requests reach the engine reading the file")
    func requestsReachTheServiceEngine() async throws {
        let file = try Self.pairedFile()
        let (host, endpoint) = try Self.makeHost()
        let client = RuntimeEngine(source: file.source, engineID: "offline-service-test.requests")
        defer { Task { await client.stop(); await host.stop() } }
        try await client.connect(credential: Self.credential(for: file, at: endpoint))

        let libobjcPath = "/usr/lib/libobjc.A.dylib"
        try await client.loadImage(at: libobjcPath)
        let objects = try await client.objects(in: libobjcPath)

        #expect(objects.contains { $0.displayName == "NSObject" }, "NSObject is missing from libobjc's objects")
        let serviceEngine = try #require(host.engine)
        #expect(try await serviceEngine.isImageLoaded(path: libobjcPath))
    }

    @Test("A payload naming a file that cannot be read fails the connect, carrying the reason")
    func unreadableFileFailsTheConnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeOfflineServiceHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copyURL = directory.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.filePath), to: copyURL)
        let file = try RuntimeOfflineFile(contentsOf: copyURL)
        try FileManager.default.removeItem(at: copyURL)
        let (host, endpoint) = try Self.makeHost()
        defer { Task { await host.stop() } }
        let client = RuntimeEngine(source: file.source, engineID: "offline-service-test.unreadable")

        await #expect(throws: RuntimeXPCServiceConnectionError.self) {
            try await client.connect(credential: Self.credential(for: file, at: endpoint))
        }
        #expect(host.engine == nil)
    }

    @Test("A stopped .file engine connects again and receives the file's images once more")
    func stoppedEngineConnectsAgain() async throws {
        let file = try Self.pairedFile()
        let (host, endpoint) = try Self.makeHost()
        let client = RuntimeEngine(source: file.source, engineID: "offline-service-test.reconnect")
        defer { Task { await client.stop(); await host.stop() } }
        let credential = try Self.credential(for: file, at: endpoint)
        try await client.connect(credential: credential)
        let serviceEngine = try #require(host.engine)
        let serviceImageList = await serviceEngine.imageList
        #expect(await pollUntil { await client.imageList == serviceImageList })

        await client.stop()
        #expect(client.state == .disconnected(error: nil))
        try await client.connect(credential: credential)

        #expect(client.state == .connected)
        let receivedAgain = await pollUntil {
            await client.imageList == serviceImageList && client.imageNodes.count == serviceEngine.imageNodes.count
        }
        #expect(receivedAgain, "the reconnected client did not receive the image list again")
        let objects = try await client.objects(in: Self.filePath)
        #expect(objects.isEmpty, "/usr/bin/true defines no Objective-C or Swift types")
    }

    /// launchd starts an XPC service with room for 256 descriptors, and
    /// reading a dyld shared cache whole takes several hundred: every reader
    /// of it maps each of its eighty-odd files.
    @Test("A launch makes room for a whole dyld shared cache's descriptors before reading the file")
    func launchRaisesTheDescriptorLimit() async {
        await #expect(processExitsWith: .success) {
            let isRaised = await RuntimeOfflineServiceHostTests.launchFromTheServiceDescriptorLimitRaisesIt()
            exit(isRaised ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    /// Starts from the soft limit launchd gives a service, launches a host on
    /// a paired file, and says whether the soft limit then stands at the most
    /// `setrlimit(2)` advises asking for, `min(OPEN_MAX, rlim_max)`.
    static func launchFromTheServiceDescriptorLimitRaisesIt() async -> Bool {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        limit.rlim_cur = 256
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        do {
            let file = try pairedFile()
            let (host, endpoint) = try makeHost()
            let client = RuntimeEngine(source: file.source, engineID: "offline-service-test.descriptor-limit")
            try await client.connect(credential: credential(for: file, at: endpoint))
            withExtendedLifetime(host) {}
        } catch {
            return false
        }
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        return limit.rlim_cur >= min(rlim_t(OPEN_MAX), limit.rlim_max)
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

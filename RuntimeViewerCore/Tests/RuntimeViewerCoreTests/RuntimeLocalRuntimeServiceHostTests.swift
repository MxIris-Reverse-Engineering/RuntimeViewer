#if os(macOS)

import Testing
import Foundation
import Combine
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// The local engine running out of process, with both processes played by
/// this one: a `RuntimeLocalRuntimeServiceHost` over an anonymous listener
/// stands in for the embedded service, and a `.local` engine connected with
/// `.xpcService(.anonymousListener(…))` stands in for the app's.
///
/// What the engine does when the service goes away is not exercised here —
/// the engine only reacts to its connection's state, and the connection's
/// reattach has its own suite in `RuntimeViewerCommunicationTests`.
@Suite("RuntimeLocalRuntimeServiceHost", .serialized)
struct RuntimeLocalRuntimeServiceHostTests {
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    private static func makeHost() async throws -> (host: RuntimeLocalRuntimeServiceHost, endpoint: RuntimeXPCServiceEndpoint) {
        let serviceEngine = RuntimeEngine(source: .local, engineID: "local-runtime-service-test.host")
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeLocalRuntimeServiceHost(engine: serviceEngine, connection: listener)
        try await host.start()
        host.activate()
        return (host, endpoint)
    }

    private static func makeClient(for endpoint: RuntimeXPCServiceEndpoint, engineID: String) async throws -> RuntimeEngine {
        let client = RuntimeEngine(source: .local, engineID: engineID)
        try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
        return client
    }

    @Test("A .local engine connected with the service credential forwards, and receives the service's data")
    func connectingReceivesTheServiceData() async throws {
        let (host, endpoint) = try await Self.makeHost()
        let client = try await Self.makeClient(for: endpoint, engineID: "local-runtime-service-test.client")
        defer { Task { await client.stop(); await host.stop() } }

        let hostImageList = await host.engine.imageList
        let received = await pollUntil {
            let clientImageList = await client.imageList
            return clientImageList == hostImageList && client.imageNodes.count == host.engine.imageNodes.count
        }
        let forwardsRequests = await client.forwardsRequests

        #expect(received, "the client did not receive the service's image list and image nodes")
        #expect(client.state == .connected)
        #expect(forwardsRequests)
        #expect(client.source == .local)
        #expect(!client.imageNodes.isEmpty)
    }

    @Test("Requests are forwarded to the service and its pushes come back")
    func requestsForwardAndPushesReturn() async throws {
        let (host, endpoint) = try await Self.makeHost()
        let client = try await Self.makeClient(for: endpoint, engineID: "local-runtime-service-test.client-loading")
        defer { Task { await client.stop(); await host.stop() } }

        var subscriptions: Set<AnyCancellable> = []
        let loadedPaths = PathRecorder()
        client.imageDidLoadPublisher
            .sink { path in Task { await loadedPaths.record(path) } }
            .store(in: &subscriptions)

        try await client.loadImage(at: Self.libobjcPath)

        let isLoaded = try await client.isImageLoaded(path: Self.libobjcPath)
        let hostLoadedPaths = await host.engine.loadedImagePaths
        let clientLoadedPaths = await client.loadedImagePaths
        let objects = try await client.objects(in: Self.libobjcPath)
        let relayedImageDidLoad = await pollUntil { await loadedPaths.paths.contains(Self.libobjcPath) }

        #expect(isLoaded)
        // The dlopen and the index live in the host engine, not in the client.
        #expect(hostLoadedPaths.contains(Self.libobjcPath))
        #expect(clientLoadedPaths.isEmpty)
        #expect(objects.contains { $0.name == "NSObject" })
        #expect(relayedImageDidLoad, "imageDidLoad was not relayed to the client")
    }

    @Test("Every client that attaches gets the current data, not only the first")
    func everyAttachGetsTheCurrentData() async throws {
        let (host, endpoint) = try await Self.makeHost()
        let firstClient = try await Self.makeClient(for: endpoint, engineID: "local-runtime-service-test.first")
        defer { Task { await firstClient.stop(); await host.stop() } }
        let hostImageList = await host.engine.imageList
        let firstReceived = await pollUntil { await firstClient.imageList == hostImageList }
        #expect(firstReceived)

        // The app reattaching after the service came back looks, to the
        // listener, like a new peer replacing the old one.
        let secondClient = try await Self.makeClient(for: endpoint, engineID: "local-runtime-service-test.second")
        defer { Task { await secondClient.stop() } }

        let secondReceived = await pollUntil { await secondClient.imageList == hostImageList }
        #expect(secondReceived, "the second client did not receive the service's data")
    }

    @Test("Without a credential a .local engine stays in process")
    func withoutCredentialStaysInProcess() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "local-runtime-service-test.in-process")
        defer { Task { await engine.stop() } }

        try await engine.connect()
        let forwardsRequests = await engine.forwardsRequests

        #expect(engine.state == .localOnly)
        #expect(!forwardsRequests)
    }
}

// MARK: - Support

private actor PathRecorder {
    private(set) var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }
}

private func pollUntil(
    timeout: Duration = .seconds(5),
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

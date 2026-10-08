#if os(macOS) && canImport(Network)

import Foundation
import RuntimeViewerCommunication
@testable import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The corpus coordinator when the connection under a build goes away: the
/// local-runtime service exits, a device or an injected app drops its
/// socket. Every build in flight failed then, and each was recorded as a
/// Failed build in the Report navigator's history, although nothing failed
/// to print (PR121.30, the part left to batch S3b).
@Suite("FindCorpusCoordinator when the connection goes", .serialized)
@MainActor
struct FindCorpusCoordinatorLostConnectionTests {
    enum Transport: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// "My Mac": a `.local` engine forwarding to the local-runtime
        /// service, here an anonymous listener in this process.
        case xpcService
        /// A device, a mirrored Mac or an injected app.
        case socket

        var testDescription: String { rawValue }
    }

    /// A client engine whose peer holds every corpus build it is asked for,
    /// and a way to take the connection away from under it.
    private struct HoldingPeer {
        let client: RuntimeEngine
        let dropConnection: @Sendable () -> Void
        let stop: @Sendable () async -> Void
    }

    private struct IgnoredRequest: Codable {}

    private static func makeHoldingPeer(_ transport: Transport, label: String, heldBuilds: HeldRequests) async throws -> HoldingPeer {
        let holdBuild: @Sendable () async throws -> Bool = {
            await heldBuilds.hold()
            throw CancellationError()
        }
        switch transport {
        case .xpcService:
            let serving = RuntimeEngine(source: .local, engineID: "\(label).serving")
            let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
            let host = RuntimeLocalRuntimeServiceHost(engine: serving, connection: listener)
            try await host.start()
            // SwiftyXPC copies a listener's handlers onto each connection it
            // accepts, so the replacement has to precede the activation.
            listener.setMessageHandler(name: RuntimeEngine.CommandName.buildInterfaceCorpus.commandName) { (_: IgnoredRequest) async throws -> Bool in
                try await holdBuild()
            }
            host.activate()
            let client = RuntimeEngine(source: .local, engineID: "\(label).client")
            try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
            // Kept for the peer's life: it holds the serving side.
            nonisolated(unsafe) let retainedHost = host
            return HoldingPeer(
                client: client,
                dropConnection: { listener.stop() },
                stop: {
                    await client.stop()
                    await retainedHost.stop()
                }
            )
        case .socket:
            let peer = try await ScriptedPeer.make(label: label)
            peer.serve(.buildInterfaceCorpus, with: holdBuild)
            let connection = peer.connection
            return HoldingPeer(
                client: peer.client,
                dropConnection: { connection.stop() },
                stop: { await peer.stop() }
            )
        }
    }

    @Test("a build the connection drops under is not a failed build", arguments: Transport.allCases)
    func lostConnectionIsNotAFailedBuild(transport: Transport) async throws {
        let heldBuilds = HeldRequests()
        let peer = try await Self.makeHoldingPeer(transport, label: "FindCorpusCoordinatorLostConnectionTests.\(transport.rawValue)", heldBuilds: heldBuilds)
        let environment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(documentState: environment.documentState) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.requestBuild(of: TestImages.libobjc)
        let buildArrived = await pollUntil(timeout: .seconds(10)) { await heldBuilds.arrivedCount == 1 }
        #expect(buildArrived, "the build never reached the peer")

        peer.dropConnection()

        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 20) { states in
            states[TestImages.libobjc]?.isActive != true
        }
        let failedBuilds = coordinator.finishedBuilds.filter { finishedBuild in
            if case .failed = finishedBuild.outcome { return true }
            return false
        }
        #expect(failedBuilds.isEmpty, "a lost connection was recorded as \(failedBuilds.map(\.outcome))")
        #expect(states[TestImages.libobjc] == nil, "a lost connection left \(String(describing: states[TestImages.libobjc]))")
        await heldBuilds.release()
        await peer.stop()
    }
}

#endif

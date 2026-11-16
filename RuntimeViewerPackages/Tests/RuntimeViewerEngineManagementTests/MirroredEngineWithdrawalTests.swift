import Testing
import Foundation
import Network
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// What the manager does when a peer stops forwarding one of the engines it
/// mirrors to us: that mirror goes, and the peer's other mirrors stay. A
/// withdrawn mirror is stopped, and the disconnect its `stop()` reports must
/// not be taken for the whole peer going away.
@Suite("Mirrored engines a peer stops forwarding", .serialized)
@MainActor
struct MirroredEngineWithdrawalTests {
    private static let inertConfiguration = RuntimeEngineManagerConfiguration(
        advertisesOverBonjour: false,
        sharesEnginesWithPeers: false,
        launchesSystemEngines: false,
        reconnectsInjectedEngines: false,
    )

    private static let peerHostID = "5B0F6A2E-3C1D-4E8F-9A7B-2D6C8E1F0A93"

    private static func descriptor(localIdentifier: String, port: UInt16) -> RuntimeRemoteEngineDescriptor {
        RuntimeRemoteEngineDescriptor(
            engineID: "\(peerHostID)/\(localIdentifier)",
            source: .directTCP(name: localIdentifier, host: "127.0.0.1", port: port, role: .server),
            hostID: peerHostID,
            hostName: "peer",
            originChain: [peerHostID],
            directTCPHost: "127.0.0.1",
            directTCPPort: port
        )
    }

    /// Waits until `condition` holds, checking on the main actor so the
    /// manager's state hops have run in between.
    private static func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("a peer that stops forwarding one engine leaves its other engines mirrored")
    func withdrawingOneMirrorKeepsThePeersOthers() async throws {
        let listener = SilentTCPListener()
        let port = try await listener.start()
        defer { listener.cancel() }

        let manager = RuntimeEngineManager(configuration: Self.inertConfiguration, startupHandler: { _ in })
        let forwarder = RuntimeEngine(
            source: .bonjour(name: "Peer", identifier: .init(rawValue: Self.peerHostID), role: .client),
            hostInfo: RuntimeHostInfo(hostID: Self.peerHostID, hostName: "peer")
        )
        let kept = Self.descriptor(localIdentifier: "kept", port: port)
        let withdrawn = Self.descriptor(localIdentifier: "withdrawn", port: port)

        manager.handleEngineListChanged([kept, withdrawn], from: forwarder)
        let keptEngine = try #require(manager.mirroredEngines[kept.engineID])
        let withdrawnEngine = try #require(manager.mirroredEngines[withdrawn.engineID])
        try await Self.waitUntil { keptEngine.state == .connected && withdrawnEngine.state == .connected }

        manager.handleEngineListChanged([kept], from: forwarder)

        try await Self.waitUntil {
            if case .disconnected = withdrawnEngine.state { return true }
            return false
        }
        // The state the withdrawn engine reported reaches the manager through a
        // hop to the main actor; let it land before looking.
        try await Task.sleep(for: .milliseconds(500))

        #expect(manager.mirroredEngines[withdrawn.engineID] == nil)
        #expect(manager.mirroredEngines[kept.engineID] === keptEngine)
        #expect(keptEngine.state == .connected)
    }
}

/// A TCP listener on the loopback address that accepts every connection and
/// never says anything, so a mirrored engine pointed at it connects and stays
/// connected.
private final class SilentTCPListener: @unchecked Sendable {
    private struct ListenerFailed: Error {}

    private let queue = DispatchQueue(label: "SilentTCPListener")

    private var listener: NWListener?

    /// Touched on `queue` only.
    private var connections: [NWConnection] = []

    /// Touched on `queue` only.
    private var hasReportedStart = false

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !hasReportedStart else { return }
                switch state {
                case .ready:
                    hasReportedStart = true
                    if let port = listener?.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: ListenerFailed())
                    }
                case .failed,
                     .cancelled:
                    hasReportedStart = true
                    continuation.resume(throwing: ListenerFailed())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connections.append(connection)
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
        }
    }

    func cancel() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
        listener?.cancel()
    }
}

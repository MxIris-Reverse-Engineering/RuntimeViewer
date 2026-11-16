import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// What the engine list discovery of a Bonjour peer does once the peer is no
/// longer one of the manager's engines — it disconnected, and was terminated,
/// during the seconds the discovery waits and asks (KnownIssues UR.5): it
/// marks nothing and starts no heartbeat for an engine nobody will clean up
/// after.
@Suite("Engine list discovery for a Bonjour peer", .serialized)
@MainActor
struct BonjourEngineListDiscoveryTests {
    private static let inertConfiguration = RuntimeEngineManagerConfiguration(
        advertisesOverBonjour: false,
        sharesEnginesWithPeers: false,
        launchesSystemEngines: false,
        reconnectsInjectedEngines: false,
    )

    @Test("a peer that went away while its engine list was being asked for leaves nothing behind")
    func departedPeerLeavesNothingBehind() async throws {
        let manager = RuntimeEngineManager(configuration: Self.inertConfiguration, startupHandler: { _ in })
        // Never connected and not among the manager's Bonjour engines: a peer
        // terminated before its discovery finished, as far as the manager can tell.
        let departedEngine = RuntimeEngine(
            source: .bonjour(name: "Peer", identifier: .init(rawValue: "6D1C2B7A-9E3F-4A5B-8C0D-1E2F3A4B5C6D"), role: .client),
            hostInfo: RuntimeHostInfo(hostID: "6D1C2B7A-9E3F-4A5B-8C0D-1E2F3A4B5C6D", hostName: "peer")
        )
        #expect(!manager.bonjourRuntimeEngines.contains { $0 === departedEngine })

        await manager.discoverEngineList(of: departedEngine, endpointName: "Peer")

        #expect(!manager.directBonjourEngines.contains(ObjectIdentifier(departedEngine)))
        #expect(manager.bonjourHeartbeatTasks[ObjectIdentifier(departedEngine)] == nil)
        manager.bonjourHeartbeatTasks.values.forEach { $0.cancel() }
    }
}

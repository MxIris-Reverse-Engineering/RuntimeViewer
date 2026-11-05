#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import HelperCommunication
import HelperPeer
import HelperClient
import InjectedEndpointRegistryServiceInterface

/// XPC client connection for the main application side.
///
/// Backed by `HelperPeerClient`. Two construction modes:
///
/// - **Initial handshake** (`init(identifier:modifier:)`): connect to the
///   privileged helper, register own listener endpoint under `identifier`,
///   wait for the server's `ServerLaunched` notification (which lib handles
///   internally) to populate the peer connection.
/// - **Direct reconnect** (`init(identifier:serverEndpoint:modifier:)`): used
///   when the Host restarts and already knows the server's listener endpoint
///   (e.g. from the injected-endpoint registry). The lib peer opens its own
///   listener, direct-connects to the server endpoint, and sends
///   `ClientReconnected` so the server swaps its peer connection.
final class RuntimeXPCMachServiceClientConnection: RuntimeXPCMachServiceConnection, @unchecked Sendable {
    // IMPORTANT: the order `init lib peer → super.init → modifier → peer.activate()`
    // is load-bearing. The modifier wires business message handlers onto the
    // peer's listener; `peer.activate()` then activates the listener and
    // registers the endpoint with the broker, so the server can only reach
    // us once handlers are in place. Collapsing the handshake into the lib
    // peer's init races against handler installation — see Catalyst connection
    // regression fixed by the two-phase split.
    init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCMachServiceConnection) async throws -> Void)? = nil) async throws {
        let peer = try await HelperPeerClient(
            machServiceName: RuntimeViewerMachServiceName,
            isPrivilegedHelperTool: true,
            identifier: identifier.rawValue
        )
        await super.init(identifier: identifier, peer: peer)
        try await modifier?(self)
        try await peer.activate()
    }

    /// Creates a client connection by directly connecting to a known server endpoint.
    ///
    /// Used for reconnecting to an already-injected app whose endpoint was retrieved
    /// from the Mach Service injected endpoint registry. Bypasses the normal handshake.
    init(identifier: RuntimeSource.Identifier, serverEndpoint: HelperPeerEndpoint, modifier: ((RuntimeXPCMachServiceConnection) async throws -> Void)? = nil) async throws {
        let peer = try await HelperPeerClient(
            machServiceName: RuntimeViewerMachServiceName,
            isPrivilegedHelperTool: true,
            identifier: identifier.rawValue,
            serverEndpoint: serverEndpoint
        )
        await super.init(identifier: identifier, peer: peer)
        try await modifier?(self)
        try await peer.activate()
    }
}

#endif

#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import HelperCommunication
import HelperPeer
import HelperClient
import InjectedEndpointRegistryServiceInterface

/// XPC server connection for the service provider side.
///
/// Backed by `HelperPeerServer`. The lib peer fetches the client's endpoint
/// from the broker, opens a direct reverse connection, sends `ServerLaunched`
/// to populate the client's peer connection, and — for injected servers —
/// registers its own listener endpoint so the host can later reconnect
/// directly. A `ClientReconnected` handler is installed on the listener so
/// subsequent host reconnects swap the peer connection in place.
final class RuntimeXPCMachServiceServerConnection: RuntimeXPCMachServiceConnection, @unchecked Sendable {
    // IMPORTANT: the modifier MUST run before `peer.activate()`. The modifier
    // installs the engine's server-side handlers (imageList, loadImage,
    // runtimeObjectsInImage, …) on the peer's listener; `peer.activate()`
    // then sends `ServerLaunchedNotification` to the host. If the lib peer
    // sent ServerLaunched inside its own init, the host would start firing
    // business requests before this side's handlers existed — code-injection
    // regression fixed by the two-phase split.
    init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCMachServiceConnection) async throws -> Void)? = nil) async throws {
        let peer = try await HelperPeerServer(
            machServiceName: RuntimeViewerMachServiceName,
            isPrivilegedHelperTool: true,
            identifier: identifier.rawValue
        )
        await super.init(identifier: identifier, peer: peer)
        try await modifier?(self)
        try await peer.activate()
        if Self.shouldAnnounceListenerEndpoint(identifier: identifier) {
            await announceListenerEndpoint()
        }
    }

    /// Whether this server belongs in the injected-endpoint registry.
    ///
    /// The registry means "an injected app the host cannot relaunch — keep its
    /// endpoint so the host can reconnect after a restart". The Mac Catalyst
    /// helper is the opposite: the host launches it fresh on every start, and
    /// the two always ship in the same bundle.
    ///
    /// Announcing the helper is not merely redundant, it is what produced the
    /// phantom "RuntimeViewerCatalystHelper" engine entry. The host's
    /// reconnect pass runs in the same launch, right after the helper
    /// connects, so it fetched the helper's just-announced endpoint, treated
    /// it as an injected app, and opened a direct connection — whose
    /// `ClientReconnected` handling swapped the helper's single peer slot away
    /// from the engine the launch sequence had just built. The
    /// "My Mac (Mac Catalyst)" entry died on the spot and an attached entry
    /// named after the helper process took its place. No orphaned process is
    /// required; a clean quit and relaunch reproduced it.
    static func shouldAnnounceListenerEndpoint(identifier: RuntimeSource.Identifier) -> Bool {
        identifier != .macCatalyst
    }

    /// Announce this server's listener endpoint to the Mach Service injected-endpoint
    /// registry so the host can reconnect directly after restart, bypassing the broker
    /// handshake. Failures are logged but never propagated: a successful peer activation
    /// must not be torn down just because the registry is unreachable — the host can
    /// still rediscover this process via the broker.
    private func announceListenerEndpoint() async {
        do {
            let helperClient = HelperClient()
            try await helperClient.connectToTool(
                machServiceName: RuntimeViewerMachServiceName,
                isPrivilegedHelperTool: true
            )
            try await helperClient.sendToTool(request: RegisterInjectedEndpointRequest(
                pid: ProcessInfo.processInfo.processIdentifier,
                appName: Self.injectedAppName,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                endpoint: cachedListenerEndpoint
            ))
            #log(.info, "Registered injected endpoint with Mach Service (PID: \(ProcessInfo.processInfo.processIdentifier))")
        } catch {
            #log(.error, "Failed to register injected endpoint: \(error, privacy: .public)")
        }
    }

    private static var injectedAppName: String {
        if let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String {
            return displayName
        }
        if let bundleName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String {
            return bundleName
        }
        return ProcessInfo.processInfo.processName
    }
}

#endif

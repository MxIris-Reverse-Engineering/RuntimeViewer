#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import HelperCommunication
import HelperPeer
import HelperClient
import InjectedEndpointRegistryServiceInterface

// MARK: - RuntimeXPCConnection

/// XPC-based connection for cross-process communication on macOS.
///
/// `RuntimeXPCConnection` is a thin adapter over `HelperPeer.HelperPeerClient`
/// / `HelperPeerServer`. It delegates the entire handshake, reconnect, and
/// state-stream lifecycle to the brokered peer and exposes the result as a
/// `RuntimeConnection`. Subclasses choose which peer role to bring up.
///
/// ## Architecture
///
/// - The lib peer owns the anonymous `XPCListener`, the privileged-tool
///   `serviceConnection`, and the bidirectional `peerConnection`. It performs
///   `ServerLaunched` / `ClientReconnected` signalling internally.
/// - This adapter bridges the peer's `AsyncStream<PeerConnectionState>` to a
///   Combine `CurrentValueSubject<RuntimeConnectionState, Never>` for
///   compatibility with the rest of `RuntimeEngine`.
/// - The peer's listener endpoint is cached at init time so server-side
///   self-registration (see `RuntimeXPCServerConnection`) is synchronous.
///
/// ## Use Cases
///
/// - Communication between main app and Mac Catalyst helper
/// - Privileged operations requiring elevated permissions
/// - Reconnection to already-injected apps after Host restart
///
/// - Note: For code injection into sandboxed apps, use `RuntimeLocalSocketConnection`
///   instead, as XPC requires the target process to explicitly participate.
@Loggable(.fileprivate)
class RuntimeXPCConnection: RuntimeConnection, @unchecked Sendable {
    fileprivate let identifier: RuntimeSource.Identifier

    fileprivate let peer: any PeerConnection

    fileprivate let cachedListenerEndpoint: HelperPeerEndpoint

    fileprivate let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    fileprivate let stateBridgeTask: Task<Void, Never>

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    fileprivate init(identifier: RuntimeSource.Identifier, peer: any PeerConnection) async {
        self.identifier = identifier
        self.peer = peer
        self.cachedListenerEndpoint = await peer.listenerEndpoint
        let stateSubject = self.stateSubject
        let stateStream = peer.stateStream
        self.stateBridgeTask = Task { [weak stateSubject] in
            for await peerState in stateStream {
                guard let stateSubject else { return }
                switch peerState {
                case .connecting:
                    stateSubject.send(.connecting)
                case .connected:
                    stateSubject.send(.connected)
                case .disconnected(let error):
                    stateSubject.send(.disconnected(error: .xpcError(error.localizedDescription)))
                case .cancelled:
                    stateSubject.send(.disconnected(error: nil))
                }
            }
        }
        #log(.info, "RuntimeXPCConnection adapter created for identifier: \(self.identifier.rawValue, privacy: .public)")
    }

    deinit {
        stateBridgeTask.cancel()
    }

    func stop() {
        stateBridgeTask.cancel()
        let peer = peer
        Task { await peer.cancel() }
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "RuntimeXPCConnection stopped for identifier: \(self.identifier.rawValue, privacy: .public)")
    }

    // MARK: - Typed RPC

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        try await peer.send(request)
    }

    func sendMessage<Request: RuntimeRequest>(request: Request, timeout: TimeInterval?) async throws -> Request.Response {
        // XPC has no per-request deadline; ignore timeout.
        try await peer.send(request)
    }

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type = Request.self, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        peer.setMessageHandler(requestType) { request in
            try await handler(request)
        }
    }

    // MARK: - Untyped (name-based) RPC

    func sendMessage(name: String) async throws {
        try await peer.sendMessage(name: name)
    }

    func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        try await peer.sendMessage(name: name, request: request)
    }

    func sendMessage<Response: Codable>(name: String) async throws -> Response {
        try await peer.sendMessage(name: name)
    }

    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        try await peer.sendMessage(name: name, request: request)
    }

    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        peer.setMessageHandler(name: name, handler: handler)
    }

    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        peer.setMessageHandler(name: name, handler: handler)
    }

    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        peer.setMessageHandler(name: name, handler: handler)
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        peer.setMessageHandler(name: name, handler: handler)
    }
}

// MARK: - RuntimeXPCClientConnection

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
final class RuntimeXPCClientConnection: RuntimeXPCConnection, @unchecked Sendable {
    // IMPORTANT: the order `init lib peer → super.init → modifier → peer.activate()`
    // is load-bearing. The modifier wires business message handlers onto the
    // peer's listener; `peer.activate()` then activates the listener and
    // registers the endpoint with the broker, so the server can only reach
    // us once handlers are in place. Collapsing the handshake into the lib
    // peer's init races against handler installation — see Catalyst connection
    // regression fixed by the two-phase split.
    init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
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
    init(identifier: RuntimeSource.Identifier, serverEndpoint: HelperPeerEndpoint, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
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

// MARK: - RuntimeXPCServerConnection

/// XPC server connection for the service provider side.
///
/// Backed by `HelperPeerServer`. The lib peer fetches the client's endpoint
/// from the broker, opens a direct reverse connection, sends `ServerLaunched`
/// to populate the client's peer connection, and registers its own listener
/// endpoint so the host can later reconnect directly. A `ClientReconnected`
/// handler is installed on the listener so subsequent host reconnects swap
/// the peer connection in place.
final class RuntimeXPCServerConnection: RuntimeXPCConnection, @unchecked Sendable {
    // IMPORTANT: the modifier MUST run before `peer.activate()`. The modifier
    // installs the engine's server-side handlers (imageList, loadImage,
    // runtimeObjectsInImage, …) on the peer's listener; `peer.activate()`
    // then sends `ServerLaunchedNotification` to the host. If the lib peer
    // sent ServerLaunched inside its own init, the host would start firing
    // business requests before this side's handlers existed — code-injection
    // regression fixed by the two-phase split.
    init(identifier: RuntimeSource.Identifier, modifier: ((RuntimeXPCConnection) async throws -> Void)? = nil) async throws {
        let peer = try await HelperPeerServer(
            machServiceName: RuntimeViewerMachServiceName,
            isPrivilegedHelperTool: true,
            identifier: identifier.rawValue
        )
        await super.init(identifier: identifier, peer: peer)
        try await modifier?(self)
        try await peer.activate()
        await announceListenerEndpoint()
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

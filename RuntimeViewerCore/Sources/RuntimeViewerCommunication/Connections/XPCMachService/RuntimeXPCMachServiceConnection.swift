#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import HelperCommunication
import HelperPeer
import HelperClient
import InjectedEndpointRegistryServiceInterface

// MARK: - RuntimeXPCMachServiceConnection

/// XPC-based connection for cross-process communication on macOS.
///
/// `RuntimeXPCMachServiceConnection` is a thin adapter over `HelperPeer.HelperPeerClient`
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
///   self-registration (see `RuntimeXPCMachServiceServerConnection`) is synchronous.
///
/// ## Use Cases
///
/// - Communication between main app and Mac Catalyst helper
/// - Privileged operations requiring elevated permissions
/// - Reconnection to already-injected apps after Host restart
///
/// - Note: For code injection into sandboxed apps, use `RuntimeLocalSocketConnection`
///   instead, as XPC requires the target process to explicitly participate.
@Loggable(.internal)
class RuntimeXPCMachServiceConnection: RuntimeConnection, @unchecked Sendable {
    let identifier: RuntimeSource.Identifier

    let peer: any PeerConnection

    let cachedListenerEndpoint: HelperPeerEndpoint

    let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    let stateBridgeTask: Task<Void, Never>

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    init(identifier: RuntimeSource.Identifier, peer: any PeerConnection) async {
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
        #log(.info, "RuntimeXPCMachServiceConnection adapter created for identifier: \(self.identifier.rawValue, privacy: .public)")
    }

    deinit {
        stateBridgeTask.cancel()
    }

    func stop() {
        stateBridgeTask.cancel()
        let peer = peer
        Task { await peer.cancel() }
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "RuntimeXPCMachServiceConnection stopped for identifier: \(self.identifier.rawValue, privacy: .public)")
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

#endif

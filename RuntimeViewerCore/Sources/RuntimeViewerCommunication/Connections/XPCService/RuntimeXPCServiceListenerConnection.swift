#if os(macOS)

public import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

/// The service's end: an `XPCListener` whose handlers answer the client, and
/// whichever accepted connection last spoke as the peer that pushes go to.
///
/// An embedded service has exactly one client — the app that ships it — so a
/// single peer slot is enough, and a second connection (the app reconnecting)
/// simply replaces the first. The client's `hello` is what gets it adopted;
/// the listener reports `.connected` at that point, which is the service
/// host's cue to push its current data.
///
/// An accepted connection looks the listener's handlers up when a message
/// arrives (SwiftyXPC 0.5.106 and later), so a handler installed after
/// `activate()` reaches a client already attached. Every handler must still
/// be in place before the first message that needs it: the local runtime
/// service installs all of them before it activates, and a service that
/// learns what to serve from the first `hello` installs them in its launch
/// handler, before that `hello` is answered — see `setLaunchHandler(_:)`.
/// `activate()` on an embedded-service listener is `xpc_main` and never
/// returns; call it last.
@Loggable(.private)
public final class RuntimeXPCServiceListenerConnection: RuntimeXPCServiceConnection, @unchecked Sendable {
    private let listener: SwiftyXPC.XPCListener

    private let peerLock = NSLock()

    private var peer: XPCConnection?

    /// The connection adopted last, kept after an unknown message emptied
    /// the peer slot: its closing is the client's departure.
    private weak var lastAdoptedConnection: XPCConnection?

    /// See `setClientDepartureHandler(_:)`.
    private var clientDepartureHandler: (@Sendable () -> Void)?

    private let launchLock = NSLock()

    /// What the first `hello` carrying a payload starts. See
    /// `setLaunchHandler(_:)`.
    private var launchHandler: (@Sendable (Data) async throws -> Void)?

    /// The launch, once a payload arrived. Every later `hello` waits for the
    /// same outcome: one instance serves one payload.
    private var launchTask: Task<Void, any Error>?

    private init(listener: SwiftyXPC.XPCListener) {
        self.listener = listener
        super.init()
        listener.errorHandler = { [weak self] connection, error in
            self?.handlePeerError(on: connection, error)
        }
        // `installHandler` adopts the sender before the body runs; the body
        // only has to start what a payload asks for.
        installHandler(name: Self.helloMessageName) { [weak self] payload in
            try await self?.launchIfNeeded(with: payload)
            return Data()
        }
    }

    /// Runs `handler` with the payload of the first `hello` that carries one,
    /// before that `hello` is answered: what a dedicated instance must know
    /// before it can serve. A throwing handler fails that `hello` and every
    /// later one. Handlers installed meanwhile reach the client already
    /// attached, so the launch handler is where such a service installs its
    /// command table. Set it before `activate()`.
    public func setLaunchHandler(_ handler: @escaping @Sendable (Data) async throws -> Void) {
        launchLock.locked { launchHandler = handler }
    }

    /// Runs `handler` when the client adopted last closes its connection for
    /// good — it cancelled the connection, or its process went away. A
    /// message the listener has no handler for empties the peer slot as well,
    /// but that is no departure: the client is still there, and its next
    /// known message is adopted again. Nor is a connection a newer one
    /// replaced. A dedicated instance's service exits here: nobody else can
    /// ever reach it.
    public func setClientDepartureHandler(_ handler: @escaping @Sendable () -> Void) {
        peerLock.locked { clientDepartureHandler = handler }
    }

    private func launchIfNeeded(with payload: Data) async throws {
        guard !payload.isEmpty else { return }
        let task = launchLock.locked { () -> Task<Void, any Error>? in
            if let launchTask { return launchTask }
            guard let launchHandler else { return nil }
            let task = Task { try await launchHandler(payload) }
            launchTask = task
            return task
        }
        try await task?.value
    }

    /// The listener of the XPC service this process *is*. Its `activate()` is
    /// `xpc_main`.
    public static func embeddedService() throws -> RuntimeXPCServiceListenerConnection {
        RuntimeXPCServiceListenerConnection(listener: try SwiftyXPC.XPCListener(type: .service, codeSigningRequirement: nil))
    }

    /// An anonymous listener plus the endpoint a client in the same process
    /// (or any process handed the endpoint) connects to. The test seam.
    public static func anonymous() throws -> (connection: RuntimeXPCServiceListenerConnection, endpoint: RuntimeXPCServiceEndpoint) {
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        return (RuntimeXPCServiceListenerConnection(listener: listener), RuntimeXPCServiceEndpoint(listener.endpoint))
    }

    /// Starts accepting connections. Every handler must already be installed.
    public func activate() {
        #log(.info, "XPC service listener activating")
        listener.activate()
    }

    public override func stop() {
        let peer = peerLock.locked {
            defer { self.peer = nil }
            return self.peer
        }
        peer?.cancel()
        // An embedded-service listener cannot be cancelled (SwiftyXPC traps);
        // dropping the peer is all the teardown it gets. The process exits
        // when launchd decides it is idle.
        if case .anonymous = listener.type {
            listener.cancel()
        }
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "XPC service listener connection stopped")
    }

    override func sendFrame(name: String, payload: Data) async throws -> Data {
        guard let peer = peerLock.locked({ self.peer }) else {
            throw RuntimeXPCServiceConnectionError.noClientAttached
        }
        let reply: RuntimeXPCServiceReplyFrame
        do {
            reply = try await peer.sendMessage(name: name, request: payload)
        } catch {
            throw RuntimeXPCServiceConnectionError.mapping(error)
        }
        return try RuntimeXPCServiceMessaging.unwrap(reply)
    }

    override func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
        listener.setMessageHandler(name: name) { [weak self] (connection: XPCConnection, payload: Data) async throws -> RuntimeXPCServiceReplyFrame in
            self?.adopt(connection)
            return await RuntimeXPCServiceMessaging.replying { try await body(payload) }
        }
    }

    /// Makes `connection` the peer pushes go to. A client's first message —
    /// its `hello` — is what gets it here. Every newly adopted peer is
    /// reported as `.connected`, a replaced one included: the host pushes its
    /// current data on that transition, and a client that just attached
    /// needs it whether or not somebody else was attached before.
    private func adopt(_ connection: XPCConnection) {
        let (isNewPeer, replaced): (Bool, XPCConnection?) = peerLock.locked {
            guard peer !== connection else { return (false, nil) }
            defer {
                peer = connection
                lastAdoptedConnection = connection
            }
            return (true, peer)
        }
        guard isNewPeer else { return }
        if let replaced {
            #log(.info, "A new client attached; replacing the previous peer connection")
            replaced.cancel()
        }
        stateSubject.send(.connected)
    }

    private func handlePeerError(on connection: XPCConnection, _ error: any Error) {
        let isTransportClosure: Bool
        switch error as? XPCError {
        case .connectionInvalid, .connectionInterrupted:
            isTransportClosure = true
        default:
            isTransportClosure = false
        }
        let (wasPeer, departureHandler) = peerLock.locked { () -> (Bool, (@Sendable () -> Void)?) in
            let departed = isTransportClosure && lastAdoptedConnection === connection
            if departed {
                lastAdoptedConnection = nil
            }
            guard peer === connection else { return (false, departed ? clientDepartureHandler : nil) }
            peer = nil
            return (true, departed ? clientDepartureHandler : nil)
        }
        if let departureHandler {
            #log(.info, "The client closed its connection: \(error.localizedDescription, privacy: .public)")
            departureHandler()
        }
        guard wasPeer else {
            #log(.debug, "A non-peer connection reported: \(error.localizedDescription, privacy: .public)")
            return
        }
        #log(.info, "Peer connection went away: \(error.localizedDescription, privacy: .public)")
        stateSubject.send(.disconnected(error: .xpcError(error.localizedDescription)))
    }
}

#endif

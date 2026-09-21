#if os(macOS)

public import Foundation
import FoundationToolbox
public import Combine
import SwiftyXPC

// MARK: - Target

/// Where an XPC-service client connects to.
///
/// An embedded XPC service is reached by bundle identifier: launchd looks it
/// up in the calling process's own bundle, which is why only the app itself
/// can reach the one it ships. The anonymous-listener case exists for tests,
/// where both ends of a `RuntimeXPCServiceClientConnection` /
/// `RuntimeXPCServiceListenerConnection` pair live in one `xctest` process.
public enum RuntimeXPCServiceTarget: Sendable {
    /// The embedded service with this bundle identifier, launched on demand
    /// by launchd from the calling process's bundle.
    case bundleIdentifier(String)

    /// An anonymous listener some process opened and handed over its endpoint.
    case anonymousListener(RuntimeXPCServiceEndpoint)
}

/// A reference to an anonymous `XPCListener`, opaque outside this module so
/// SwiftyXPC stays an implementation detail of the connection layer.
public struct RuntimeXPCServiceEndpoint: @unchecked Sendable {
    let underlying: SwiftyXPC.XPCEndpoint

    init(_ underlying: SwiftyXPC.XPCEndpoint) {
        self.underlying = underlying
    }
}

// MARK: - Errors

public enum RuntimeXPCServiceConnectionError: Error, LocalizedError, Sendable, Equatable {
    /// The service process exited while this connection was open — a crash,
    /// or launchd tearing it down. The connection itself stays usable: the
    /// next message relaunches the service.
    case serviceExited

    /// The connection can never be used again: it was cancelled, or the
    /// service could not be found in the calling process's bundle.
    case connectionInvalid

    /// The listener side has not been reached by any client yet, so there is
    /// nobody to push to.
    case noClientAttached

    /// The handler on the other side threw. Only its description crosses the
    /// wire; the concrete error type stays in the process that produced it.
    case remoteFailure(String)

    public var errorDescription: String? {
        switch self {
        case .serviceExited:
            return "The local runtime exited while handling this request."
        case .connectionInvalid:
            return "The connection to the local runtime is no longer valid."
        case .noClientAttached:
            return "No client is attached to the local runtime service."
        case .remoteFailure(let description):
            return description
        }
    }

    /// Maps SwiftyXPC's transport errors onto this module's vocabulary and
    /// leaves every other error untouched.
    static func mapping(_ error: any Error) -> any Error {
        guard let xpcError = error as? XPCError else { return error }
        switch xpcError {
        case .connectionInterrupted:
            return RuntimeXPCServiceConnectionError.serviceExited
        case .connectionInvalid:
            return RuntimeXPCServiceConnectionError.connectionInvalid
        case .terminationImminent, .invalidCodeSignatureRequirement, .unknown:
            return error
        }
    }
}

// MARK: - Wire frames

/// Every message on an XPC-service connection carries one `Data` payload in,
/// and one of these out. The payloads are JSON — the same encoding every other
/// `RuntimeConnection` uses — so a value that crosses a socket today crosses
/// XPC unchanged, and a handler failure travels as a description instead of
/// relying on SwiftyXPC's error registry, which only round-trips registered
/// error types.
struct RuntimeXPCServiceReplyFrame: Codable, Sendable {
    let payload: Data
    let failure: String?

    static func success(_ payload: Data) -> Self {
        Self(payload: payload, failure: nil)
    }

    static func failure(_ error: any Error) -> Self {
        Self(payload: Data(), failure: error.localizedDescription)
    }
}

enum RuntimeXPCServiceMessaging {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from payload: Data) throws -> Value {
        try JSONDecoder().decode(type, from: payload)
    }

    /// Runs a handler body and folds its outcome into a reply frame, so the
    /// sending side always gets a frame back and never a transport-level
    /// error it would have to decode.
    static func replying(_ body: () async throws -> Data) async -> RuntimeXPCServiceReplyFrame {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// Unwraps a reply frame: a carried failure becomes a thrown
    /// `RuntimeXPCServiceConnectionError.remoteFailure`.
    static func unwrap(_ frame: RuntimeXPCServiceReplyFrame) throws -> Data {
        if let failure = frame.failure {
            throw RuntimeXPCServiceConnectionError.remoteFailure(failure)
        }
        return frame.payload
    }
}

// MARK: - Locking

extension NSLock {
    /// `NSLock.withLock(_:)` needs macOS 13; this module still declares 10.15.
    fileprivate func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Shared connection surface

/// The `RuntimeConnection` surface both ends of an XPC-service connection
/// share. Subclasses provide the two transport primitives — send one frame,
/// install one named handler — and everything typed is derived from those.
public class RuntimeXPCServiceConnection: RuntimeConnection, @unchecked Sendable {
    /// The transport's own message. A client sends it when it connects and
    /// again after the service was relaunched; the listener answers it with
    /// nothing, adopts the sender as its peer and reports `.connected`. It
    /// belongs to this layer, not to the engine: what it establishes is
    /// "this connection has a live service behind it", nothing about images.
    static let helloMessageName = "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeXPCServiceConnection.hello"

    fileprivate let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    public var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    public var state: RuntimeConnectionState {
        stateSubject.value
    }

    fileprivate init() {}

    public func stop() {
        fatalError("Subclasses must override stop()")
    }

    // MARK: Transport primitives

    fileprivate func sendFrame(name: String, payload: Data) async throws -> Data {
        fatalError("Subclasses must override sendFrame(name:payload:)")
    }

    fileprivate func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
        fatalError("Subclasses must override installHandler(name:body:)")
    }

    // MARK: Untyped (name-based) RPC

    public func sendMessage(name: String) async throws {
        _ = try await sendFrame(name: name, payload: Data())
    }

    public func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        _ = try await sendFrame(name: name, payload: try RuntimeXPCServiceMessaging.encode(request))
    }

    public func sendMessage<Response: Codable>(name: String) async throws -> Response {
        let payload = try await sendFrame(name: name, payload: Data())
        return try RuntimeXPCServiceMessaging.decode(Response.self, from: payload)
    }

    public func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        let payload = try await sendFrame(name: name, payload: try RuntimeXPCServiceMessaging.encode(request))
        return try RuntimeXPCServiceMessaging.decode(Response.self, from: payload)
    }

    // MARK: Typed RPC

    public func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: Request.identifier, request: request)
    }

    public func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type = Request.self, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        setMessageHandler(name: Request.identifier) { (request: Request) -> Request.Response in
            try await handler(request)
        }
    }

    // MARK: Handlers

    public func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        installHandler(name: name) { _ in
            try await handler()
            return Data()
        }
    }

    public func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        installHandler(name: name) { payload in
            try await handler(try RuntimeXPCServiceMessaging.decode(Request.self, from: payload))
            return Data()
        }
    }

    public func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        installHandler(name: name) { _ in
            try RuntimeXPCServiceMessaging.encode(try await handler())
        }
    }

    public func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        installHandler(name: name) { payload in
            try RuntimeXPCServiceMessaging.encode(try await handler(try RuntimeXPCServiceMessaging.decode(Request.self, from: payload)))
        }
    }
}

// MARK: - Client

/// The app's end: one `XPCConnection` to the service, kept for the life of
/// the engine that owns it.
///
/// The service exiting is not the end of the connection. SwiftyXPC reports
/// it as `XPCError.connectionInterrupted` and documents the connection as
/// still live — the next message makes launchd relaunch the service — so
/// this type reports `.disconnected(error:)` and then reattaches on its own:
/// a `hello` after 1 s, 2 s and 4 s, and once those are spent, one more
/// `hello` in front of the next message. The round trip completing is what
/// marks the relaunched service reachable, so `.connected` follows the
/// `hello` that gets through. Only `stop()` and `XPCError.connectionInvalid`
/// are terminal.
///
/// The owner sees none of this beyond `statePublisher`: an engine on this
/// connection goes `.disconnected` and then `.connected` again, exactly as
/// it would on any transport that came back.
@Loggable(.private)
public final class RuntimeXPCServiceClientConnection: RuntimeXPCServiceConnection, @unchecked Sendable {
    /// Delays before each automatic `hello` after the service went away.
    /// Three tries; afterwards the next message tries once more on its own.
    static let defaultReattachDelaysInNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

    private let xpcConnection: XPCConnection

    private let lifecycleLock = NSLock()

    /// `stop()` was called; later transport errors are the cancellation
    /// itself and must not be reported as failures.
    private var isCancelled = false

    /// `XPC_ERROR_CONNECTION_INVALID` arrived; nothing sent on this
    /// connection will ever be answered again.
    private var isInvalid = false

    /// The automatic reattach in flight after an interruption, if any. One
    /// at a time; `stop()` cancels it.
    private var reattachTask: Task<Void, Never>?

    private var reattachDelaysInNanoseconds = RuntimeXPCServiceClientConnection.defaultReattachDelaysInNanoseconds

    /// Test seam: every `hello` fails with this until it is cleared, which
    /// stands in for a service that dies again while being relaunched.
    private var helloFailureForTesting: (any Error)?

    /// Whether this connection can still carry messages. `false` once it
    /// was cancelled or invalidated; an interruption does not clear it.
    public var isUsable: Bool {
        lifecycleLock.locked { !isCancelled && !isInvalid }
    }

    /// Whether an automatic reattach is running. Test seam.
    var isReattaching: Bool {
        lifecycleLock.locked { reattachTask != nil }
    }

    public init(
        target: RuntimeXPCServiceTarget,
        modifier: ((RuntimeXPCServiceClientConnection) async throws -> Void)? = nil
    ) async throws {
        switch target {
        case .bundleIdentifier(let bundleIdentifier):
            xpcConnection = try XPCConnection(type: .remoteService(bundleID: bundleIdentifier))
            #log(.info, "XPC service client created for bundle identifier \(bundleIdentifier, privacy: .public)")
        case .anonymousListener(let endpoint):
            xpcConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint.underlying))
            #log(.info, "XPC service client created for an anonymous listener endpoint")
        }
        super.init()
        xpcConnection.errorHandler = { [weak self] _, error in
            self?.handleTransportError(error)
        }
        // Handlers first, activation last: SwiftyXPC dispatches inbound
        // messages as soon as the connection is active, and the service
        // pushes its data the moment the hello below reaches it.
        try await modifier?(self)
        xpcConnection.activate()
        // Activation never confirms the service exists; the hello does — for
        // an embedded service this round trip is the launch itself. A
        // service that cannot be reached fails the connection here, before
        // any owner takes it.
        try await sendHello()
    }

    public override func stop() {
        let (alreadyCancelled, reattachTask) = lifecycleLock.locked { () -> (Bool, Task<Void, Never>?) in
            defer {
                isCancelled = true
                self.reattachTask = nil
            }
            return (isCancelled, self.reattachTask)
        }
        guard !alreadyCancelled else { return }
        reattachTask?.cancel()
        xpcConnection.cancel()
        stateSubject.send(.disconnected(error: nil))
        #log(.info, "XPC service client connection stopped")
    }

    // MARK: Test seams

    /// Shortens the automatic reattach schedule. Takes effect on the next
    /// interruption.
    func setReattachDelays(inNanoseconds delays: [UInt64]) {
        lifecycleLock.locked { reattachDelaysInNanoseconds = delays }
    }

    /// Makes every `hello` fail with `error` (`nil` restores the real one).
    func setHelloFailureForTesting(_ error: (any Error)?) {
        lifecycleLock.locked { helloFailureForTesting = error }
    }

    /// Reports the interruption a real service exit would, without one: the
    /// state goes `.disconnected` and the reattach schedule starts. Against
    /// an anonymous listener in the same process the schedule's `hello`
    /// then simply succeeds.
    func simulateInterruptionForTesting() {
        handleTransportError(XPCError.connectionInterrupted)
    }

    // MARK: Transport

    fileprivate override func sendFrame(name: String, payload: Data) async throws -> Data {
        guard isUsable else { throw RuntimeXPCServiceConnectionError.connectionInvalid }
        // A message while detached would reach a relaunched service that has
        // not adopted this client yet, so its data would land after the
        // reply instead of before it. Saying hello first keeps that order,
        // and is the one on-demand try left once the schedule is spent.
        if !stateSubject.value.isConnected, name != Self.helloMessageName {
            try await sendHello()
        }
        return try await roundTrip(name: name, payload: payload)
    }

    fileprivate override func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
        xpcConnection.setMessageHandler(name: name) { (_: XPCConnection, payload: Data) async throws -> RuntimeXPCServiceReplyFrame in
            await RuntimeXPCServiceMessaging.replying { try await body(payload) }
        }
    }

    private func roundTrip(name: String, payload: Data) async throws -> Data {
        let reply: RuntimeXPCServiceReplyFrame
        do {
            reply = try await xpcConnection.sendMessage(name: name, request: payload)
        } catch {
            throw RuntimeXPCServiceConnectionError.mapping(error)
        }
        // A round trip completing is the only proof the service is alive —
        // activation never confirms the service exists, and after an
        // interruption this is what marks the relaunched service reachable.
        if !stateSubject.value.isConnected, isUsable {
            stateSubject.send(.connected)
        }
        return try RuntimeXPCServiceMessaging.unwrap(reply)
    }

    private func sendHello() async throws {
        if let failure = lifecycleLock.locked({ helloFailureForTesting }) {
            throw failure
        }
        _ = try await roundTrip(name: Self.helloMessageName, payload: Data())
    }

    // MARK: Interruption and reattach

    private func handleTransportError(_ error: any Error) {
        let isCancelled = lifecycleLock.locked { self.isCancelled }
        guard !isCancelled else { return }
        switch error as? XPCError {
        case .connectionInterrupted:
            #log(.error, "XPC service exited; the connection stays live and reattaches to the relaunched service")
            stateSubject.send(.disconnected(error: .xpcError(RuntimeXPCServiceConnectionError.serviceExited.localizedDescription)))
            scheduleReattach()
        case .connectionInvalid:
            #log(.error, "XPC service connection became invalid")
            lifecycleLock.locked { isInvalid = true }
            stateSubject.send(.disconnected(error: .xpcError(RuntimeXPCServiceConnectionError.connectionInvalid.localizedDescription)))
        default:
            #log(.error, "XPC service connection reported: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts the bounded automatic reattach: one `hello` per delay in the
    /// schedule, stopping at the first that gets through.
    private func scheduleReattach() {
        let scheduled: Bool = lifecycleLock.locked {
            guard !isCancelled, !isInvalid, reattachTask == nil else { return false }
            let delays = reattachDelaysInNanoseconds
            reattachTask = Task { [weak self] in
                defer { self?.reattachDidFinish() }
                for (attemptIndex, delay) in delays.enumerated() {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled, let self, self.isUsable else { return }
                    if await self.attemptHello(attempt: attemptIndex + 1) {
                        return
                    }
                }
            }
            return true
        }
        if scheduled {
            #log(.info, "Reattach scheduled: \(self.reattachDelaysInNanoseconds.count, privacy: .public) attempts")
        }
    }

    private func attemptHello(attempt: Int) async -> Bool {
        do {
            try await sendHello()
            #log(.info, "Reattached to the relaunched XPC service (attempt \(attempt, privacy: .public))")
            return true
        } catch {
            #log(.error, "Reattach attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func reattachDidFinish() {
        let stillDetached = lifecycleLock.locked {
            reattachTask = nil
            return !stateSubject.value.isConnected && !isCancelled && !isInvalid
        }
        if stillDetached {
            #log(.error, "Automatic reattach gave up; the next message tries once more")
        }
    }
}

// MARK: - Listener

/// The service's end: an `XPCListener` whose handlers answer the client, and
/// whichever accepted connection last spoke as the peer that pushes go to.
///
/// An embedded service has exactly one client — the app that ships it — so a
/// single peer slot is enough, and a second connection (the app reconnecting)
/// simply replaces the first. The client's `hello` is what gets it adopted;
/// the listener reports `.connected` at that point, which is the service
/// host's cue to push its current data.
///
/// SwiftyXPC copies a listener's handlers onto each accepted connection *at
/// accept time*, so every `setMessageHandler` must precede `activate()`.
/// `activate()` on an embedded-service listener is `xpc_main` and never
/// returns; call it last.
@Loggable(.private)
public final class RuntimeXPCServiceListenerConnection: RuntimeXPCServiceConnection, @unchecked Sendable {
    private let listener: SwiftyXPC.XPCListener

    private let peerLock = NSLock()

    private var peer: XPCConnection?

    private init(listener: SwiftyXPC.XPCListener) {
        self.listener = listener
        super.init()
        listener.errorHandler = { [weak self] connection, error in
            self?.handlePeerError(on: connection, error)
        }
        // Answering the hello is all it takes: `installHandler` adopts the
        // sender before the body runs.
        installHandler(name: Self.helloMessageName) { _ in Data() }
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

    fileprivate override func sendFrame(name: String, payload: Data) async throws -> Data {
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

    fileprivate override func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
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
            defer { peer = connection }
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
        let wasPeer = peerLock.locked {
            guard peer === connection else { return false }
            peer = nil
            return true
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

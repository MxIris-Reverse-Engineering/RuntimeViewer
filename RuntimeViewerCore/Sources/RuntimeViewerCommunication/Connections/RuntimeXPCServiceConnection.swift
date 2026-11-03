#if os(macOS)

public import Foundation
import FoundationToolbox
public import Combine
import SwiftyXPC
public import HelperCommunication

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

    /// A process of its own for this connection: launchd starts a new
    /// instance of the embedded service, which declares `_MultipleInstances`
    /// in its `Info.plist`, and the connection's first `hello` hands the
    /// instance `launchPayload` — what it has to know before it can serve,
    /// such as the file an offline engine reads. An instance that went away
    /// is never relaunched, so reattaching starts another one, with the same
    /// payload, behind a new connection.
    case dedicatedInstance(bundleIdentifier: String, launchPayload: Data)

    /// An anonymous listener some process opened and handed over its endpoint.
    case anonymousListener(RuntimeXPCServiceEndpoint)
}

/// A reference to an anonymous `XPCListener`, opaque outside this module so
/// SwiftyXPC stays an implementation detail of the connection layer.
public struct RuntimeXPCServiceEndpoint: @unchecked Sendable {
    let underlying: SwiftyXPC.XPCEndpoint

    /// Test seam: a client connecting here behaves as one to a dedicated
    /// instance — its hellos carry this payload, and it reattaches behind a
    /// new connection. `nil` for a plain endpoint.
    let launchPayload: Data?

    init(_ underlying: SwiftyXPC.XPCEndpoint, launchPayload: Data? = nil) {
        self.underlying = underlying
        self.launchPayload = launchPayload
    }

    /// Test seam: this endpoint, reached the way a dedicated instance is.
    /// See ``launchPayload``.
    func carryingLaunchPayload(_ payload: Data) -> RuntimeXPCServiceEndpoint {
        RuntimeXPCServiceEndpoint(underlying, launchPayload: payload)
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
        // Worded for any embedded service: the local runtime and the Mac
        // Catalyst runtime both run in one, and these texts reach the user.
        case .serviceExited:
            return "The runtime service exited while handling this request."
        case .connectionInvalid:
            return "The connection to the runtime service is no longer valid."
        case .noClientAttached:
            return "No client is attached to the runtime service."
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
    /// again after the service was relaunched; the listener adopts the sender
    /// as its peer, reports `.connected` and answers it with nothing. It
    /// belongs to this layer, not to the engine: what it establishes is
    /// "this connection has a live service behind it", nothing about images.
    /// A dedicated instance's `hello` also carries its launch payload, which
    /// the listener hands its launch handler before answering.
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

/// The app's end: one `XPCConnection` to the service at a time, kept for the
/// life of the engine that owns it.
///
/// The service exiting is not the end of the connection. Behind an embedded
/// service, SwiftyXPC reports it as `XPCError.connectionInterrupted` and
/// documents the connection as still live — the next message makes launchd
/// relaunch the service. A dedicated instance is never relaunched: its
/// connection reports `XPCError.connectionInvalid` right after the
/// interruption, so this type puts a new connection, and with it a new
/// instance, in its place, answering every message the owner installed a
/// handler for. Either way this type reports `.disconnected(error:)` and then
/// reattaches on its own: a `hello` after 1 s, 2 s and 4 s, and once those
/// are spent, one more `hello` in front of the next message. The round trip
/// completing is what marks the service reachable, so `.connected` follows
/// the `hello` that gets through. Only `stop()`, and
/// `XPCError.connectionInvalid` behind an embedded service, are terminal.
///
/// The owner sees none of this beyond `statePublisher`: an engine on this
/// connection goes `.disconnected` and then `.connected` again, exactly as
/// it would on any transport that came back.
@Loggable(.private)
public final class RuntimeXPCServiceClientConnection: RuntimeXPCServiceConnection, @unchecked Sendable {
    /// Delays before each automatic `hello` after the service went away.
    /// Three tries; afterwards the next message tries once more on its own.
    static let defaultReattachDelaysInNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

    /// Where each underlying XPC connection leads.
    private enum Destination {
        /// Relaunched by launchd behind the same connection.
        case service(bundleIdentifier: String)
        /// A new process for every connection, never relaunched.
        case serviceInstance(bundleIdentifier: String)
        case anonymousListener(SwiftyXPC.XPCEndpoint)
    }

    private let destination: Destination

    /// What every `hello` carries: a dedicated instance's launch payload,
    /// empty for anything else.
    private let helloPayload: Data

    /// Whether a service that went away comes back only behind a new
    /// connection — a dedicated instance — rather than behind this one.
    private let reattachesBehindNewConnection: Bool

    private let lifecycleLock = NSLock()

    /// The connection messages go out on. Replaced once a dedicated
    /// instance behind it went away.
    private var xpcConnection: XPCConnection

    /// The instance behind `xpcConnection` is gone for good, or declined its
    /// payload; the next attach puts a new connection in its place.
    private var needsNewConnection = false

    /// Every handler the owner installed, so a new connection answers the
    /// same messages as the one it replaces.
    private var installedHandlers: [String: @Sendable (Data) async throws -> Data] = [:]

    /// How many connections replaced the first one. Test seam.
    private var connectionReplacements = 0

    /// `stop()` was called; later transport errors are the cancellation
    /// itself and must not be reported as failures.
    private var isCancelled = false

    /// `XPC_ERROR_CONNECTION_INVALID` arrived behind an embedded service;
    /// nothing sent on this connection will ever be answered again.
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

    /// How many connections replaced the first one. Test seam.
    var connectionReplacementCount: Int {
        lifecycleLock.locked { connectionReplacements }
    }

    private var currentConnection: XPCConnection {
        lifecycleLock.locked { xpcConnection }
    }

    public init(
        target: RuntimeXPCServiceTarget,
        modifier: ((RuntimeXPCServiceClientConnection) async throws -> Void)? = nil
    ) async throws {
        switch target {
        case .bundleIdentifier(let bundleIdentifier):
            destination = .service(bundleIdentifier: bundleIdentifier)
            helloPayload = Data()
            reattachesBehindNewConnection = false
            #log(.info, "XPC service client created for bundle identifier \(bundleIdentifier, privacy: .public)")
        case .dedicatedInstance(let bundleIdentifier, let launchPayload):
            destination = .serviceInstance(bundleIdentifier: bundleIdentifier)
            helloPayload = launchPayload
            reattachesBehindNewConnection = true
            #log(.info, "XPC service client created for a dedicated instance of \(bundleIdentifier, privacy: .public)")
        case .anonymousListener(let endpoint):
            destination = .anonymousListener(endpoint.underlying)
            helloPayload = endpoint.launchPayload ?? Data()
            reattachesBehindNewConnection = endpoint.launchPayload != nil
            #log(.info, "XPC service client created for an anonymous listener endpoint")
        }
        xpcConnection = try Self.makeXPCConnection(to: destination)
        super.init()
        observeErrors(on: xpcConnection)
        // Handlers first, activation last: SwiftyXPC dispatches inbound
        // messages as soon as the connection is active, and the service
        // pushes its data the moment the hello below reaches it.
        try await modifier?(self)
        xpcConnection.activate()
        // Activation never confirms the service exists; the hello does — for
        // an embedded service this round trip is the launch itself. A
        // service that cannot be reached, or an instance that cannot start
        // what its payload names, fails the connection here, before any
        // owner takes it; the connection is cancelled so no instance is
        // left running for it.
        do {
            try await sendHello()
        } catch {
            stop()
            throw error
        }
    }

    public override func stop() {
        let (alreadyCancelled, reattachTask, connection) = lifecycleLock.locked { () -> (Bool, Task<Void, Never>?, XPCConnection) in
            defer {
                isCancelled = true
                self.reattachTask = nil
            }
            return (isCancelled, self.reattachTask, xpcConnection)
        }
        guard !alreadyCancelled else { return }
        reattachTask?.cancel()
        connection.cancel()
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
    /// an anonymous listener in this process the schedule's `hello` then
    /// simply succeeds.
    func simulateInterruptionForTesting() {
        handleTransportError(XPCError.connectionInterrupted, on: currentConnection)
    }

    /// Reports what a dedicated instance's exit looks like — an
    /// interruption, then the connection becoming invalid — without one.
    func simulateInstanceExitForTesting() {
        let connection = currentConnection
        handleTransportError(XPCError.connectionInterrupted, on: connection)
        handleTransportError(XPCError.connectionInvalid, on: connection)
    }

    // MARK: Transport

    fileprivate override func sendFrame(name: String, payload: Data) async throws -> Data {
        guard isUsable else { throw RuntimeXPCServiceConnectionError.connectionInvalid }
        // A message while detached would reach a relaunched service that has
        // not adopted this client yet, so its data would land after the
        // reply instead of before it. Saying hello first keeps that order,
        // and is the one on-demand try left once the schedule is spent.
        if !stateSubject.value.isConnected, name != Self.helloMessageName {
            try await reattach()
        }
        return try await roundTrip(name: name, payload: payload)
    }

    fileprivate override func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
        let connection = lifecycleLock.locked { () -> XPCConnection in
            installedHandlers[name] = body
            return xpcConnection
        }
        Self.install(name: name, body: body, on: connection)
    }

    private static func install(name: String, body: @escaping @Sendable (Data) async throws -> Data, on connection: XPCConnection) {
        connection.setMessageHandler(name: name) { (_: XPCConnection, payload: Data) async throws -> RuntimeXPCServiceReplyFrame in
            await RuntimeXPCServiceMessaging.replying { try await body(payload) }
        }
    }

    private static func makeXPCConnection(to destination: Destination) throws -> XPCConnection {
        switch destination {
        case .service(let bundleIdentifier):
            return try XPCConnection(type: .remoteService(bundleID: bundleIdentifier))
        case .serviceInstance(let bundleIdentifier):
            return try XPCConnection(type: .remoteServiceInstance(bundleID: bundleIdentifier, instance: UUID().uuid))
        case .anonymousListener(let endpoint):
            return try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
        }
    }

    private func observeErrors(on connection: XPCConnection) {
        connection.errorHandler = { [weak self] erroredConnection, error in
            self?.handleTransportError(error, on: erroredConnection)
        }
    }

    private func roundTrip(name: String, payload: Data) async throws -> Data {
        let connection = currentConnection
        let reply: RuntimeXPCServiceReplyFrame
        do {
            reply = try await connection.sendMessage(name: name, request: payload)
        } catch {
            throw RuntimeXPCServiceConnectionError.mapping(error)
        }
        // A round trip completing is the only proof the service is alive —
        // activation never confirms the service exists, and after an
        // interruption this is what marks the relaunched service reachable.
        // Except a `hello` the service declined: an instance that could not
        // start what its payload names serves nothing.
        let provesServiceAlive = name != Self.helloMessageName || reply.failure == nil
        if provesServiceAlive, !stateSubject.value.isConnected, isUsable, connection === currentConnection {
            stateSubject.send(.connected)
        }
        return try RuntimeXPCServiceMessaging.unwrap(reply)
    }

    private func sendHello() async throws {
        do {
            if let failure = lifecycleLock.locked({ helloFailureForTesting }) {
                throw failure
            }
            _ = try await roundTrip(name: Self.helloMessageName, payload: helloPayload)
        } catch let error as RuntimeXPCServiceConnectionError {
            // An instance that declined its payload stays declined; the next
            // try starts a fresh one, which reads the payload again — the
            // file may have come back.
            if case .remoteFailure = error, reattachesBehindNewConnection {
                lifecycleLock.locked { needsNewConnection = true }
            }
            throw error
        }
    }

    /// Says hello again — behind a new connection first, when the instance
    /// behind the current one is gone.
    private func reattach() async throws {
        try replaceConnectionIfNeeded()
        try await sendHello()
    }

    /// Puts a new connection, and so a new instance, in place of one whose
    /// instance is gone, with every handler the owner installed. The old
    /// connection is cancelled: an instance that declined its payload exits
    /// with it, and its last events are dropped as history.
    private func replaceConnectionIfNeeded() throws {
        let replacement = try lifecycleLock.locked { () -> (new: XPCConnection, old: XPCConnection)? in
            guard needsNewConnection, !isCancelled else { return nil }
            let newConnection = try Self.makeXPCConnection(to: destination)
            for (name, body) in installedHandlers {
                Self.install(name: name, body: body, on: newConnection)
            }
            let oldConnection = xpcConnection
            xpcConnection = newConnection
            needsNewConnection = false
            connectionReplacements += 1
            return (newConnection, oldConnection)
        }
        guard let replacement else { return }
        observeErrors(on: replacement.new)
        replacement.new.activate()
        replacement.old.cancel()
        #log(.info, "Started a new service instance behind a new connection")
    }

    // MARK: Interruption and reattach

    private func handleTransportError(_ error: any Error, on connection: XPCConnection) {
        let (isCancelled, isCurrent) = lifecycleLock.locked { (self.isCancelled, connection === xpcConnection) }
        // A replaced connection's last events — the invalidation that follows
        // an instance's exit, the cancellation of the connection — are history.
        guard !isCancelled, isCurrent else { return }
        switch error as? XPCError {
        case .connectionInterrupted:
            #log(.error, "XPC service exited; reattaching")
            if reattachesBehindNewConnection {
                lifecycleLock.locked { needsNewConnection = true }
            }
            stateSubject.send(.disconnected(error: .xpcError(RuntimeXPCServiceConnectionError.serviceExited.localizedDescription)))
            scheduleReattach()
        case .connectionInvalid where reattachesBehindNewConnection:
            // A dedicated instance is never relaunched: its connection turns
            // invalid right after the interruption, or alone when the
            // instance could not start. Another instance starts behind a new
            // connection.
            let alreadyDetached = lifecycleLock.locked { () -> Bool in
                defer { needsNewConnection = true }
                return needsNewConnection
            }
            if !alreadyDetached {
                #log(.error, "Dedicated XPC service instance went away; starting another")
                stateSubject.send(.disconnected(error: .xpcError(RuntimeXPCServiceConnectionError.serviceExited.localizedDescription)))
            }
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
                    if await self.attemptReattach(attempt: attemptIndex + 1) {
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

    private func attemptReattach(attempt: Int) async -> Bool {
        do {
            try await reattach()
            #log(.info, "Reattached to the XPC service (attempt \(attempt, privacy: .public))")
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

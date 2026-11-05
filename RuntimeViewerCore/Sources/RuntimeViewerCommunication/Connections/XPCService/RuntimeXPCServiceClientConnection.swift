#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

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

    override func sendFrame(name: String, payload: Data) async throws -> Data {
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

    override func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
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

#endif

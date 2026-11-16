import Foundation
import FoundationToolbox
import Combine

/// Socket client connection for use in **injected code** running inside sandboxed apps.
///
/// ## Role Clarification
///
/// | Aspect | This Class |
/// |--------|------------|
/// | Socket Role | **Client** (connect to server) |
/// | Business Role | **Server** (handles queries, returns data) |
/// | Runs In | Injected dylib inside target (sandboxed) app |
/// | Counterpart | `RuntimeLocalSocketServerConnection` in main app |
///
/// ## Why Socket Client for Business Server?
///
/// This class uses socket client (`connect()`) because:
/// 1. Injected code runs inside sandboxed apps (e.g., Numbers, Pages)
/// 2. Sandboxed apps cannot call `bind()` - returns EPERM
/// 3. `connect()` is allowed even in sandboxed environments
///
/// The main app (RuntimeViewer) creates the socket server, and this class
/// connects to it. Despite being the socket client, this side handles
/// runtime queries and returns data (business server role).
///
/// ## Usage in Injected Code
///
/// ```swift
/// @_cdecl("injected_entry")
/// func injectedEntry() {
///     Task {
///         // Connect to the socket server created by main app
///         let connection = try await RuntimeLocalSocketClientConnection(
///             identifier: "com.myapp.runtime-\(getpid())"
///         )
///
///         // Handle queries from main app (business server role)
///         connection.setMessageHandler(requestType: GetClassesRequest.self) { request in
///             return GetClassesResponse(classes: objc_copyClassList()...)
///         }
///     }
/// }
/// ```
///
/// - Note: The identifier must match what the main app used when creating
///   `RuntimeLocalSocketServerConnection`. Both sides use the same identifier
///   to compute the deterministic port number.
@Loggable
final class RuntimeLocalSocketClientConnection: RuntimeHandlerReplayingConnection, @unchecked Sendable {
    var underlyingConnection: RuntimeLocalSocketConnection? { _underlyingConnection }

    private var _underlyingConnection: RuntimeLocalSocketConnection?

    private let identifier: String

    /// The address this side dials, and keeps dialing: the reconnection loop
    /// reuses it, which is what lets an injected payload survive the host
    /// restarting without being injected again.
    private let host: String
    private let port: UInt16

    /// Stable state subject that survives underlying connection replacement.
    /// State is orchestrated manually: `.connected` is only sent once
    /// `connection.start()` succeeds, and disconnects feed the reconnection loop.
    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    let messageHandlerReplay = RuntimeMessageHandlerReplay<RuntimeLocalSocketConnection>()

    /// Subscription for observing connection state changes.
    ///
    /// `observeUnderlyingConnectionState` reassigns this from the reconnection
    /// `Task`, while `stop()` may nil it from an unrelated caller context, so
    /// cancel-and-replace must happen atomically under the lock.
    @Mutex
    private var connectionStateCancellable: AnyCancellable?

    /// Whether this connection has been explicitly stopped.
    @Mutex
    private var isStopped: Bool = false

    /// Whether a reconnection loop is already running.
    @Mutex
    private var isReconnecting: Bool = false

    /// Retry interval for reconnection attempts (in nanoseconds).
    private static let reconnectInterval: UInt64 = 500_000_000 // 500ms

    /// Creates a client connection using deterministic port calculation.
    ///
    /// - Parameters:
    ///   - identifier: Unique identifier matching the server's identifier.
    ///   - timeout: Maximum time to wait for server to be ready (default: 10 seconds).
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(identifier: String, timeout: TimeInterval = 10) async throws {
        self.identifier = identifier
        self.host = RuntimeLocalSocketAddress.loopback
        self.port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)

        // Retry connection until server is ready or timeout
        let startTime = Date()
        var lastError: Error?

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let connection = try RuntimeLocalSocketConnection(host: host, port: port)
                self._underlyingConnection = connection
                messageHandlerReplay.apply(to: connection)
                observeUnderlyingConnectionState(connection)
                try connection.start()
                stateSubject.send(.connected)
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        throw lastError ?? RuntimeLocalSocketError.connectFailed(errno: ETIMEDOUT, host: host, port: port)
    }

    /// Creates a client connection to a known port on the local machine.
    ///
    /// - Parameters:
    ///   - port: The server port to connect to.
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(port: UInt16) throws {
        self.identifier = ""
        self.host = RuntimeLocalSocketAddress.loopback
        self.port = port

        let connection = try RuntimeLocalSocketConnection(host: host, port: port)
        self._underlyingConnection = connection
        messageHandlerReplay.apply(to: connection)
        observeUnderlyingConnectionState(connection)
        try connection.start()
        stateSubject.send(.connected)
    }

    /// Creates a client connection to a host at a known address and port.
    ///
    /// The injected-payload case. The address and port are not derived from the
    /// identifier the way ``init(identifier:timeout:)`` derives the port: the
    /// host is listening before the payload exists, so it chooses both and hands
    /// them over. The identifier it also hands over is the claim token, which
    /// this side only has to present.
    ///
    /// **Never gives up.** If the first window of attempts fails it keeps trying
    /// in the background rather than throwing, and this returns a connection
    /// that is not connected yet.
    ///
    /// That is not caution, it is the only correct behaviour here: an injected
    /// payload gets exactly one chance to run. It is started by its
    /// `__attribute__((constructor))`, which dyld runs once, and a second
    /// `dlopen` of an image already in the process returns the existing handle
    /// without running anything. So a payload that gives up leaves the target
    /// permanently unusable — measured on a device, where a target that had
    /// failed once then accepted injection after injection, each reporting
    /// success, while nothing ran and nothing connected.
    ///
    /// The first window exists only so that the common case — the host is
    /// already listening, which it is, because it listens before injecting —
    /// reports `.connected` to the caller instead of `.connecting`.
    ///
    /// - Parameters:
    ///   - host: The host's address, as reached from this machine.
    ///   - port: The port the host is listening on.
    ///   - identifier: The claim token to present; carried for diagnostics, and
    ///     not used to compute anything.
    ///   - firstAttemptWindow: How long to keep trying before handing over to
    ///     the background retry loop.
    init(host: String, port: UInt16, identifier: String, firstAttemptWindow: TimeInterval = 10) async throws {
        self.identifier = identifier
        self.host = host
        self.port = port

        let startTime = Date()

        repeat {
            do {
                let connection = try RuntimeLocalSocketConnection(host: host, port: port)
                self._underlyingConnection = connection
                messageHandlerReplay.apply(to: connection)
                observeUnderlyingConnectionState(connection)
                try connection.start()
                stateSubject.send(.connected)
                return
            } catch RuntimeLocalSocketError.invalidHostAddress(let host) {
                // The one failure retrying cannot fix: a string that is not an
                // address will not become one. Thrown, so the payload falls back
                // to advertising itself instead of dialling nothing forever.
                throw RuntimeLocalSocketError.invalidHostAddress(host)
            } catch {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        } while Date().timeIntervalSince(startTime) < firstAttemptWindow

        #log(.info, "No answer on \(host, privacy: .public):\(port, privacy: .public) yet; retrying in the background rather than giving up")
        startReconnecting()
    }

    // MARK: - Connection Lifecycle

    /// Observes the underlying connection state and triggers reconnection on disconnect.
    private func observeUnderlyingConnectionState(_ connection: RuntimeLocalSocketConnection) {
        let newCancellable = connection.statePublisher
            .sink { [weak self] state in
                guard let self, !isStopped else { return }
                if state.isDisconnected {
                    #log(.info, "Underlying connection disconnected on port \(self.port, privacy: .public), triggering reconnection")
                    stateSubject.send(state)
                    startReconnecting()
                }
            }
        _connectionStateCancellable.withLock { current in
            current?.cancel()
            current = newCancellable
        }
    }

    /// Starts the reconnection loop in the background.
    private func startReconnecting() {
        let shouldStart = _isReconnecting.withLock { isReconnecting in
            guard !isReconnecting else { return false }
            isReconnecting = true
            return true
        }
        guard shouldStart, !isStopped else { return }
        #log(.info, "Starting reconnection loop for port \(self.port, privacy: .public)")
        stateSubject.send(.connecting)
        Task { [weak self] in
            await self?.reconnectionLoop()
        }
    }

    /// Periodically attempts to reconnect to the same port until successful or stopped.
    private func reconnectionLoop() async {
        defer { isReconnecting = false }
        while !isStopped {
            do {
                try await Task.sleep(nanoseconds: Self.reconnectInterval)
            } catch {
                return // Task cancelled
            }

            guard !isStopped else { return }

            do {
                let newConnection = try RuntimeLocalSocketConnection(host: host, port: port)
                self._underlyingConnection?.stop()
                self._underlyingConnection = newConnection
                messageHandlerReplay.apply(to: newConnection)
                observeUnderlyingConnectionState(newConnection)
                try newConnection.start()
                #log(.info, "Reconnected successfully to port \(self.port, privacy: .public)")
                stateSubject.send(.connected)
                return // Reconnected successfully
            } catch {
                #log(.debug, "Reconnection attempt failed for port \(self.port, privacy: .public): \(error, privacy: .public)")
                // Retry on next iteration
                continue
            }
        }
    }

    func stop() {
        #log(.info, "Stopping local socket client connection on port \(self.port, privacy: .public)")
        isStopped = true
        _connectionStateCancellable.withLock { current in
            current?.cancel()
            current = nil
        }
        _underlyingConnection?.stop()
        stateSubject.send(.disconnected(error: nil))
    }

    deinit {
        stop()
    }
}

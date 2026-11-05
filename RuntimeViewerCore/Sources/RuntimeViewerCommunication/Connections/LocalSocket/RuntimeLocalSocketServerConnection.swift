import Foundation
import FoundationToolbox
import Combine

/// Socket server connection for use in the **main app** (RuntimeViewer).
///
/// ## Role Clarification
///
/// | Aspect | This Class |
/// |--------|------------|
/// | Socket Role | **Server** (bind/listen/accept) |
/// | Business Role | **Client** (sends queries, receives data) |
/// | Runs In | Main RuntimeViewer app (non-sandboxed) |
/// | Counterpart | `RuntimeLocalSocketClientConnection` in injected code |
///
/// ## Why Socket Server for Business Client?
///
/// This class uses socket server (`bind()`/`listen()`) because:
/// 1. The main app (RuntimeViewer) has full network permissions
/// 2. The counterpart (injected code) runs in sandboxed apps that cannot `bind()`
/// 3. By hosting the socket server here, the injected code only needs `connect()`
///
/// Despite being the socket server, this side sends runtime queries and
/// receives data (business client role).
///
/// ## Port Discovery
///
/// The port is computed deterministically from the identifier using a hash
/// algorithm. Both this class and `RuntimeLocalSocketClientConnection` use
/// the same algorithm, so no file-based port discovery is needed.
///
/// ## Usage in Main App
///
/// ```swift
/// // 1. Create and start socket server before injecting code
/// let connection = RuntimeLocalSocketServerConnection(
///     identifier: "com.myapp.runtime-\(targetPID)"
/// )
/// try await connection.start()
///
/// // 2. Inject dylib into target process
/// // The injected code will connect using RuntimeLocalSocketClientConnection
///
/// // 3. Send queries to injected code (business client role)
/// let classes = try await connection.sendMessage(request: GetClassesRequest())
/// ```
///
/// - Note: The identifier must match what the injected code uses when creating
///   `RuntimeLocalSocketClientConnection`. Both sides use the same identifier
///   to compute the deterministic port number.
@Loggable
final class RuntimeLocalSocketServerConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

    private var _underlyingConnection: RuntimeLocalSocketConnection?

    private var serverSocketFD: Int32 = -1
    private let identifier: String

    /// The address this side binds.
    ///
    /// Loopback for the localhost case. For an injected payload on another
    /// machine it is the host's own address on the route the payload was told to
    /// take — binding exactly that, rather than every interface, turns an
    /// address the device could never have reached into an immediate local
    /// failure instead of a payload that quietly never arrives.
    private let bindAddress: String

    /// Pending message handlers to apply to new connections.
    ///
    /// Mirrors `RuntimeLocalSocketClientConnection`: public `setMessageHandler`
    /// overloads (caller contexts) append while the background accept loop
    /// iterates via `applyPendingHandlers`. `@Mutex` serializes the append
    /// against that iteration — without it the concurrent array access is
    /// memory-unsafe despite `@unchecked Sendable`.
    @Mutex
    private var pendingHandlers: [@Sendable (RuntimeLocalSocketConnection) -> Void] = []

    /// Subscription for observing connection state changes.
    ///
    /// Reassigned from the background accept loop and nil'd from `stop()` on an
    /// unrelated caller context, so cancel-and-replace must be atomic.
    @Mutex
    private var connectionStateCancellable: AnyCancellable?

    /// The port the server is listening on (available after `start()` is called).
    private(set) var port: UInt16 = 0

    /// Stable state subject that survives underlying connection replacement.
    /// State is orchestrated manually: underlying disconnects are surfaced and
    /// then the accept loop restarts, bridging state across client reconnections.
    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    /// Creates a server connection with deterministic port calculation.
    ///
    /// - Parameter identifier: Unique identifier used to compute the port.
    init(identifier: String) {
        self.identifier = identifier
        self.bindAddress = RuntimeLocalSocketAddress.loopback
        self.port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
    }

    /// Creates a server connection on a specific port.
    ///
    /// - Parameter port: The port to listen on (0 for auto-assign).
    init(port: UInt16 = 0) {
        self.identifier = ""
        self.bindAddress = RuntimeLocalSocketAddress.loopback
        self.port = port
    }

    /// Creates a server connection on a specific address and port.
    ///
    /// The injected-payload case: the payload cannot bind, so this side does,
    /// and it has to be reachable from the device rather than from loopback.
    ///
    /// - Parameters:
    ///   - bindAddress: The local address to bind, which is also the address the
    ///     payload was told to dial.
    ///   - port: The port to listen on (0 for auto-assign).
    init(bindAddress: String, port: UInt16) {
        self.identifier = ""
        self.bindAddress = bindAddress
        self.port = port
    }

    // MARK: - Message Handler Replay

    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
                try await handler()
                return RuntimeMessageNull.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = _underlyingConnection {
            setupHandler(connection)
        }
    }

    func setMessageHandler<Request>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) where Request: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                try await handler(request)
                return RuntimeMessageNull.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = _underlyingConnection {
            setupHandler(connection)
        }
    }

    func setMessageHandler<Response>(name: String, handler: @escaping @Sendable () async throws -> Response) where Response: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
                return try await handler()
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = _underlyingConnection {
            setupHandler(connection)
        }
    }

    func setMessageHandler<Request>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) where Request: RuntimeRequest {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler { @Sendable (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = _underlyingConnection {
            setupHandler(connection)
        }
    }

    func setMessageHandler<Request, Response>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) where Request: Codable, Response: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = _underlyingConnection {
            setupHandler(connection)
        }
    }

    /// Applies all pending handlers to a connection.
    ///
    /// Snapshots the array inside the lock so user-supplied handler closures run
    /// outside the critical section.
    private func applyPendingHandlers(to connection: RuntimeLocalSocketConnection) {
        let snapshot = _pendingHandlers.withLock { $0 }
        for handler in snapshot {
            handler(connection)
        }
    }

    /// Starts listening for connections.
    ///
    /// After this method returns, the server is ready to accept connections
    /// and the port file has been written for client discovery.
    /// Connections are accepted asynchronously in the background.
    func start() async throws {
        #log(.info, "Starting local socket server on \(self.bindAddress, privacy: .public):\(self.port, privacy: .public) for identifier: \(self.identifier, privacy: .public)")
        errno = 0
        serverSocketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocketFD >= 0 else {
            throw RuntimeLocalSocketError.socketCreationFailed(errno: errno)
        }

        var reuseAddr: Int32 = 1
        setsockopt(serverSocketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // See the note on `connect(toHost:port:)`: `inet_addr` would turn a
        // malformed address into a bind on the broadcast address.
        guard inet_pton(AF_INET, bindAddress, &addr.sin_addr) == 1 else {
            close(serverSocketFD)
            serverSocketFD = -1
            throw RuntimeLocalSocketError.invalidHostAddress(bindAddress)
        }

        errno = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let bindErrno = errno

        guard bindResult == 0 else {
            close(serverSocketFD)
            serverSocketFD = -1
            throw RuntimeLocalSocketError.bindFailed(errno: bindErrno, host: bindAddress, port: port)
        }

        errno = 0
        guard listen(serverSocketFD, 5) == 0 else {
            let listenErrno = errno
            close(serverSocketFD)
            serverSocketFD = -1
            throw RuntimeLocalSocketError.listenFailed(errno: listenErrno)
        }

        #log(.info, "Server listening on \(self.bindAddress, privacy: .public):\(self.port, privacy: .public)")

        // Start accepting connections in background (non-blocking)
        startAcceptingConnections()
    }

    /// Starts accepting connections asynchronously in background.
    private func startAcceptingConnections() {
        stateSubject.send(.connecting)
        #log(.info, "Waiting for local socket client connection on port \(self.port, privacy: .public)...")
        DispatchQueue.global().async { [weak self] in
            self?.acceptConnectionLoop()
        }
    }

    /// Continuously accepts client connections.
    private func acceptConnectionLoop() {
        guard serverSocketFD >= 0 else {
            #log(.error, "Accept loop aborted: server socket is invalid (fd=\(self.serverSocketFD, privacy: .public))")
            return
        }

        #log(.debug, "Blocking on accept() for port \(self.port, privacy: .public)...")

        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(serverSocketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            let acceptErrno = errno
            #log(.info, "Accept returned -1 (errno=\(acceptErrno, privacy: .public)), server likely stopped")
            return
        }

        #log(.info, "Accepted local socket client connection (fd=\(clientFD, privacy: .public)) on port \(self.port, privacy: .public)")

        // The accepting end needs these as much as the dialling end does — more,
        // in fact: on a device injection this is the end that outlives the peer.
        RuntimeLocalSocketConnection.configureSocketOptions(clientFD)

        let socketConnection = RuntimeLocalSocketConnection(socketFD: clientFD)
        self._underlyingConnection = socketConnection

        // Apply all pending message handlers to the new connection
        applyPendingHandlers(to: socketConnection)

        // Observe connection state to restart accepting when disconnected.
        // Cancel-and-replace atomically under the lock so a stale subscription
        // can't leak if `stop()` races from another context.
        let newCancellable = socketConnection.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                #log(.info, "Local socket connection state: \(String(describing: state), privacy: .public)")
                if state.isConnected {
                    stateSubject.send(.connected)
                } else if state.isDisconnected {
                    #log(.info, "Local socket client disconnected, waiting for new connection...")
                    stateSubject.send(state)
                    startAcceptingConnections()
                }
            }
        _connectionStateCancellable.withLock { current in
            current?.cancel()
            current = newCancellable
        }

        do {
            try socketConnection.start()
            #log(.info, "Local socket connection started successfully")
        } catch {
            #log(.error, "Failed to start local socket connection: \(error, privacy: .public), retrying accept...")
            // Try accepting again
            startAcceptingConnections()
        }
    }

    /// Stops the server and cleans up resources.
    func stop() {
        #log(.info, "Stopping local socket server on port \(self.port, privacy: .public)")
        _connectionStateCancellable.withLock { current in
            current?.cancel()
            current = nil
        }
        _underlyingConnection?.stop()
        if serverSocketFD >= 0 {
            // shutdown() before close() to unblock accept() on the background accept loop.
            shutdown(serverSocketFD, SHUT_RDWR)
            close(serverSocketFD)
            serverSocketFD = -1
        }
        stateSubject.send(.disconnected(error: nil))
    }

    deinit {
        stop()
    }
}

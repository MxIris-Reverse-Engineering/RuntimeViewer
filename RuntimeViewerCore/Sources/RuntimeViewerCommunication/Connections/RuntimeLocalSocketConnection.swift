import Foundation
import FoundationToolbox
import Combine

// MARK: - RuntimeLocalSocketConnection

/// A bidirectional communication channel over TCP localhost socket.
///
/// `RuntimeLocalSocketConnection` provides a universal IPC mechanism that works
/// across all scenarios including sandboxed apps and code injection, without
/// requiring any special entitlements or Info.plist configuration.
///
/// ## Why TCP Localhost?
///
/// | Method | Sandbox Compatible | No Config Required |
/// |--------|-------------------|-------------------|
/// | XPC Mach Service | ❌ | ✅ |
/// | Bonjour/Network | ❌ (needs NSBonjourServices) | ❌ |
/// | Unix Domain Socket | ❌ (path restrictions) | ✅ |
/// | **TCP Localhost** | **✅** | **✅** |
///
/// ## Role Inversion: Why Socket Roles Are Swapped
///
/// In a typical design, the "server" (data provider) would create a socket server,
/// and the "client" (data consumer) would connect to it. However, sandboxed apps
/// have restrictions on `bind()` system calls, while `connect()` is generally allowed.
///
/// Since the **injected code runs inside sandboxed target apps** (e.g., Numbers, Pages),
/// it cannot create a socket server. Therefore, we **invert the socket roles**:
///
/// | Component | Business Role | Socket Role | Reason |
/// |-----------|---------------|-------------|--------|
/// | Main App (RuntimeViewer) | Client (sends queries) | **Server** (bind/listen) | Has network permissions |
/// | Injected Code | Server (handles queries) | **Client** (connect) | Runs in sandbox, connect() OK |
///
/// ```
/// ┌─────────────────────────┐                    ┌─────────────────────────┐
/// │  RuntimeViewer          │                    │  Target Process         │
/// │  (Main App)             │                    │  (Sandboxed)            │
/// │                         │                    │                         │
/// │  Business: Client       │   1. start server  │                         │
/// │  Socket: SERVER         │   2. inject dylib  │                         │
/// │  (bind/listen OK)       │ ──────────────────>│  Business: Server       │
/// │                         │                    │  Socket: CLIENT         │
/// │                         │ <──── connect ─────│  (connect OK in sandbox)│
/// │                         │                    │                         │
/// │  sendMessage(request)   │ ──── request ─────>│  handleMessage(request) │
/// │  receive(response)      │ <─── response ─────│  return response        │
/// └─────────────────────────┘                    └─────────────────────────┘
/// ```
///
/// ## Port Discovery: Deterministic Hash-Based Calculation
///
/// Since sandboxed apps cannot share files via `/tmp` or other directories,
/// we use a deterministic hash algorithm to compute the port number from the
/// identifier. Both sides independently calculate the same port:
///
/// ```swift
/// port = djb2_hash(identifier) % 16383 + 49152  // Range: 49152-65535
/// ```
///
/// This eliminates the need for file-based port discovery entirely.
///
/// ## Example: Main App (Socket Server, Business Client)
///
/// ```swift
/// // Main app creates socket server before injecting code
/// let connection = RuntimeLocalSocketServerConnection(
///     identifier: "com.myapp.runtime-\(targetPID)"
/// )
/// try await connection.start()
///
/// // Inject dylib into target process...
/// // Injected code will connect as socket client
///
/// // Send queries to injected code (business client role)
/// let classes = try await connection.sendMessage(request: GetClassListRequest())
/// ```
///
/// ## Example: Injected Code (Socket Client, Business Server)
///
/// ```swift
/// @_cdecl("injected_entry")
/// func injectedEntry() {
///     Task {
///         // Connect to main app's socket server
///         let connection = try await RuntimeLocalSocketClientConnection(
///             identifier: "com.myapp.runtime-\(getpid())"
///         )
///
///         // Handle queries from main app (business server role)
///         connection.setMessageHandler(requestType: GetClassListRequest.self) { request in
///             return GetClassListResponse(classes: objc_copyClassList()...)
///         }
///     }
/// }
/// ```
///
@Loggable
final class RuntimeLocalSocketConnection: RuntimeUnderlyingConnection, @unchecked Sendable {
    let id = UUID()

    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    private var socketFD: Int32 = -1
    private let messageChannel = RuntimeMessageChannel()

    private var isStarted = false

    private let readQueue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeLocalSocketConnection.readQueue")
    private let writeQueue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeLocalSocketConnection.writeQueue")

    // MARK: - Initialization

    init(socketFD: Int32) {
        self.socketFD = socketFD
    }

    /// Connects to a host's listening socket.
    ///
    /// - Parameter host: The address to dial. ``RuntimeLocalSocketAddress/loopback``
    ///   for the localhost case this class was written for; a host's address on
    ///   the network for the injected-payload case, which is the same inversion
    ///   over a route that leaves the machine.
    init(host: String, port: UInt16) throws {
        #log(.info, "Creating connection to \(host, privacy: .public):\(port, privacy: .public)")
        try connect(toHost: host, port: port)
    }

    private func connect(toHost host: String, port: UInt16) throws {
        errno = 0
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RuntimeLocalSocketError.socketCreationFailed(errno: errno)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // `inet_pton`, not `inet_addr`: the latter reports failure as
        // 0xFFFFFFFF, which is also a valid broadcast address, so a typo in a
        // host address would become a connection attempt rather than an error.
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(socketFD)
            socketFD = -1
            throw RuntimeLocalSocketError.invalidHostAddress(host)
        }

        errno = 0
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectErrno = errno

        guard result == 0 else {
            close(socketFD)
            socketFD = -1
            throw RuntimeLocalSocketError.connectFailed(errno: connectErrno, host: host, port: port)
        }

        Self.configureSocketOptions(socketFD)

        #log(.info, "Connected to \(host, privacy: .public):\(port, privacy: .public)")
    }

    /// Applies the options every connected socket here wants, whichever end
    /// opened it.
    ///
    /// **Keepalive is the load-bearing one, and it is not an optimisation.**
    /// A peer that closes its socket sends a FIN and `recv` returns 0, which is
    /// how a disconnect is normally noticed. A peer that *vanishes* sends
    /// nothing at all — a powered-off virtual machine, a link that goes away, a
    /// process killed in a way whose last packets never arrive. Without
    /// keepalive the kernel holds that half-open connection indefinitely:
    /// `recv` blocks forever, no state change is ever published, and the engine
    /// stays in the list looking connected. Measured exactly that way — with
    /// the guest powered off, this Mac still held
    /// `169.254.46.29:60121->169.254.21.214:49351 (ESTABLISHED)` to a machine
    /// that no longer existed, and its injected engine was still listed.
    ///
    /// The system default idle is two hours, which is indistinguishable from
    /// never for this purpose. The values below declare a peer dead in roughly
    /// twenty-five seconds, which suits a link-local connection to a device on
    /// the same desk.
    ///
    /// Done at the socket layer rather than as a protocol heartbeat on purpose:
    /// the probes are the kernel's on both ends, so a payload built before this
    /// existed answers them without knowing anything about it. A heartbeat
    /// would have needed both sides rebuilt.
    static func configureSocketOptions(_ socketFD: Int32) {
        // Disable Nagle algorithm for lower latency
        var noDelay: Int32 = 1
        setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var keepAlive: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
        // Seconds of idle before the first probe. Darwin spells this
        // `TCP_KEEPALIVE`; the name `TCP_KEEPIDLE` is the Linux one and does
        // not exist here.
        var idleSeconds = Self.keepAliveIdleSeconds
        setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPALIVE, &idleSeconds, socklen_t(MemoryLayout<Int32>.size))
        var intervalSeconds = Self.keepAliveIntervalSeconds
        setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPINTVL, &intervalSeconds, socklen_t(MemoryLayout<Int32>.size))
        var probeCount = Self.keepAliveProbeCount
        setsockopt(socketFD, IPPROTO_TCP, TCP_KEEPCNT, &probeCount, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Idle seconds before the first keepalive probe.
    static let keepAliveIdleSeconds: Int32 = 10
    /// Seconds between probes once they start.
    static let keepAliveIntervalSeconds: Int32 = 5
    /// Unanswered probes before the connection is declared dead.
    static let keepAliveProbeCount: Int32 = 3

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }
        guard socketFD >= 0 else { throw RuntimeLocalSocketError.notConnected }
        isStarted = true

        setupReceiver()
        observeIncomingMessages()

        stateSubject.send(.connected)
        #log(.info, "Connection started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        if socketFD >= 0 {
            // shutdown() before close() to reliably unblock recv() on readQueue.
            // close() alone has undefined behavior for blocked syscalls on another thread (BSD).
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
            socketFD = -1
        }
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: nil))

        #log(.info, "Connection stopped")
    }

    func stop(with error: RuntimeConnectionError) {
        guard isStarted else { return }
        isStarted = false

        if socketFD >= 0 {
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
            socketFD = -1
        }
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: error))

        #log(.info, "Connection stopped with error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Receiving

    private func setupReceiver() {
        readQueue.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)

            while self.isStarted && self.socketFD >= 0 {
                let bytesRead = recv(self.socketFD, &buffer, buffer.count, 0)

                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    #log(.debug, "Received \(bytesRead, privacy: .public) bytes")
                    self.messageChannel.appendReceivedData(data)
                } else if bytesRead == 0 {
                    #log(.info, "Connection closed by peer")
                    self.messageChannel.finishReceiving()
                    DispatchQueue.main.async {
                        self.stop(with: .peerClosed)
                    }
                    break
                } else {
                    let recvErrno = errno
                    // EINTR: the syscall was interrupted by a signal (not rare in
                    // an injected process) — retry rather than tear the connection
                    // down. EAGAIN/EWOULDBLOCK: no data yet on a (non-blocking)
                    // socket — also just retry.
                    if recvErrno == EINTR || recvErrno == EAGAIN || recvErrno == EWOULDBLOCK {
                        continue
                    }
                    #log(.error, "Receive error, errno=\(recvErrno, privacy: .public)")
                    self.messageChannel.finishReceiving()
                    DispatchQueue.main.async {
                        self.stop(with: .socketError("Receive error: errno=\(recvErrno)"))
                    }
                    break
                }
            }
        }
    }

    private func observeIncomingMessages() {
        // Centralized dispatch (see `RuntimeMessageChannel.beginDispatch`):
        // inline response routing, ordered fire-and-forget, concurrent
        // request handlers, and error replies for unknown handlers / throws.
        messageChannel.beginDispatch { [weak self] data in
            guard let self else { throw RuntimeMessageChannelError.notConnected }
            try await self.sendRaw(data: data)
        }
    }

    // MARK: - RuntimeUnderlyingConnection

    func send(requestData: RuntimeRequestData) async throws {
        let data = try JSONEncoder().encode(requestData)
        try await messageChannel.send(data: data) { [weak self] dataToSend in
            guard let self else { throw RuntimeLocalSocketError.notConnected }
            try await self.sendRaw(data: dataToSend)
        }
        #log(.debug, "Sent request: \(requestData.identifier, privacy: .public)")
    }

    func send<Response: Codable>(requestData: RuntimeRequestData, timeout: TimeInterval?) async throws -> Response {
        try await messageChannel.sendRequest(requestData: requestData, timeout: timeout) { [weak self] data in
            guard let self else { throw RuntimeLocalSocketError.notConnected }
            try await self.sendRaw(data: data)
        }
    }

    func send<Request: RuntimeRequest>(request: Request, timeout: TimeInterval?) async throws -> Request.Response {
        let requestData = try RuntimeRequestData(request: request)
        return try await send(requestData: requestData, timeout: timeout)
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        messageChannel.setMessageHandler(name: name, handler: handler)
    }

    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        messageChannel.setMessageHandler(handler)
    }

    // MARK: - Private

    private func sendRaw(data: Data) async throws {
        guard socketFD >= 0 else { throw RuntimeLocalSocketError.notConnected }

        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, Error>) in
            guard let self, self.socketFD >= 0 else {
                continuation.resume(throwing: RuntimeLocalSocketError.notConnected)
                return
            }

            self.writeQueue.async { [weak self] in
                guard let self, self.socketFD >= 0 else {
                    continuation.resume(throwing: RuntimeLocalSocketError.notConnected)
                    return
                }

                data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        continuation.resume(throwing: RuntimeLocalSocketError.notConnected)
                        return
                    }

                    var totalSent = 0
                    while totalSent < data.count {
                        let sent = Darwin.send(self.socketFD, baseAddress.advanced(by: totalSent), data.count - totalSent, 0)
                        if sent < 0 {
                            let sendErrno = errno
                            continuation.resume(throwing: RuntimeLocalSocketError.sendFailed(errno: sendErrno))
                            return
                        }
                        totalSent += sent
                    }
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - RuntimeLocalSocketError

/// Errors that can occur during local socket communication.
enum RuntimeLocalSocketError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case notConnected
    case receiveFailed
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32, host: String, port: UInt16)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case connectFailed(errno: Int32, host: String, port: UInt16)
    case invalidHostAddress(String)
    case sendFailed(errno: Int32)
    case portFileNotFound(path: String, timeout: TimeInterval)
    case invalidPortFile(path: String, content: String?)

    var description: String {
        switch self {
        case .notConnected:
            return "RuntimeLocalSocketError.notConnected: Socket is not connected"
        case .receiveFailed:
            return "RuntimeLocalSocketError.receiveFailed: Failed to receive data from socket"
        case .socketCreationFailed(let errno):
            return "RuntimeLocalSocketError.socketCreationFailed: Failed to create socket - \(Self.errnoDescription(errno))"
        case .bindFailed(let errno, let host, let port):
            return "RuntimeLocalSocketError.bindFailed: Failed to bind to \(host):\(port) - \(Self.errnoDescription(errno))"
        case .listenFailed(let errno):
            return "RuntimeLocalSocketError.listenFailed: Failed to listen on socket - \(Self.errnoDescription(errno))"
        case .acceptFailed(let errno):
            return "RuntimeLocalSocketError.acceptFailed: Failed to accept connection - \(Self.errnoDescription(errno))"
        case .connectFailed(let errno, let host, let port):
            return "RuntimeLocalSocketError.connectFailed: Failed to connect to \(host):\(port) - \(Self.errnoDescription(errno))"
        case .invalidHostAddress(let host):
            return "RuntimeLocalSocketError.invalidHostAddress: '\(host)' is not an IPv4 address this connection can dial"
        case .sendFailed(let errno):
            return "RuntimeLocalSocketError.sendFailed: Failed to send data - \(Self.errnoDescription(errno))"
        case .portFileNotFound(let path, let timeout):
            return "RuntimeLocalSocketError.portFileNotFound: Port file not found at '\(path)' after \(timeout)s timeout"
        case .invalidPortFile(let path, let content):
            return "RuntimeLocalSocketError.invalidPortFile: Invalid port file at '\(path)', content: '\(content ?? "nil")'"
        }
    }

    var errorDescription: String? { description }

    private static func errnoDescription(_ errno: Int32) -> String {
        let name = errnoName(errno)
        let message = String(cString: strerror(errno))
        return "errno=\(errno) (\(name)): \(message)"
    }

    private static func errnoName(_ errno: Int32) -> String {
        switch errno {
        case EPERM: return "EPERM"
        case ENOENT: return "ENOENT"
        case ESRCH: return "ESRCH"
        case EINTR: return "EINTR"
        case EIO: return "EIO"
        case ENXIO: return "ENXIO"
        case E2BIG: return "E2BIG"
        case ENOEXEC: return "ENOEXEC"
        case EBADF: return "EBADF"
        case ECHILD: return "ECHILD"
        case EDEADLK: return "EDEADLK"
        case ENOMEM: return "ENOMEM"
        case EACCES: return "EACCES"
        case EFAULT: return "EFAULT"
        case EBUSY: return "EBUSY"
        case EEXIST: return "EEXIST"
        case EXDEV: return "EXDEV"
        case ENODEV: return "ENODEV"
        case ENOTDIR: return "ENOTDIR"
        case EISDIR: return "EISDIR"
        case EINVAL: return "EINVAL"
        case ENFILE: return "ENFILE"
        case EMFILE: return "EMFILE"
        case ENOTTY: return "ENOTTY"
        case ETXTBSY: return "ETXTBSY"
        case EFBIG: return "EFBIG"
        case ENOSPC: return "ENOSPC"
        case ESPIPE: return "ESPIPE"
        case EROFS: return "EROFS"
        case EMLINK: return "EMLINK"
        case EPIPE: return "EPIPE"
        case EDOM: return "EDOM"
        case ERANGE: return "ERANGE"
        case EAGAIN: return "EAGAIN"
        case EINPROGRESS: return "EINPROGRESS"
        case EALREADY: return "EALREADY"
        case ENOTSOCK: return "ENOTSOCK"
        case EDESTADDRREQ: return "EDESTADDRREQ"
        case EMSGSIZE: return "EMSGSIZE"
        case EPROTOTYPE: return "EPROTOTYPE"
        case ENOPROTOOPT: return "ENOPROTOOPT"
        case EPROTONOSUPPORT: return "EPROTONOSUPPORT"
        case ENOTSUP: return "ENOTSUP"
        case EAFNOSUPPORT: return "EAFNOSUPPORT"
        case EADDRINUSE: return "EADDRINUSE"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case ENETDOWN: return "ENETDOWN"
        case ENETUNREACH: return "ENETUNREACH"
        case ENETRESET: return "ENETRESET"
        case ECONNABORTED: return "ECONNABORTED"
        case ECONNRESET: return "ECONNRESET"
        case ENOBUFS: return "ENOBUFS"
        case EISCONN: return "EISCONN"
        case ENOTCONN: return "ENOTCONN"
        case ETIMEDOUT: return "ETIMEDOUT"
        case ECONNREFUSED: return "ECONNREFUSED"
        case ELOOP: return "ELOOP"
        case ENAMETOOLONG: return "ENAMETOOLONG"
        case EHOSTDOWN: return "EHOSTDOWN"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENOTEMPTY: return "ENOTEMPTY"
        case ENOLCK: return "ENOLCK"
        case ENOSYS: return "ENOSYS"
        default: return "UNKNOWN"
        }
    }
}

// MARK: - RuntimeLocalSocketAddress

/// The addresses these connections dial and bind.
enum RuntimeLocalSocketAddress {
    /// The only address this family used before an injected payload had to
    /// reach a host across a network. Spelled once so the localhost case and
    /// the injected case are visibly the same code with a different address.
    static let loopback = "127.0.0.1"
}

// MARK: - RuntimeLocalSocketPortDiscovery

/// Handles port discovery using deterministic port calculation.
///
/// Since sandboxed apps cannot share files via `/tmp` or other directories,
/// we use a hash-based algorithm to compute a deterministic port number
/// from the identifier. Both server and client can independently calculate
/// the same port without any file I/O.
@Loggable
enum RuntimeLocalSocketPortDiscovery {

    /// Dynamic/private port range (IANA recommendation)
    private static let portRangeStart: UInt16 = 49152
    private static let portRangeEnd: UInt16 = 65535
    private static let portRangeSize: UInt16 = portRangeEnd - portRangeStart

    /// Computes a deterministic port number from the identifier.
    ///
    /// Uses a simple hash function to map the identifier to a port
    /// in the dynamic/private range (49152-65535).
    ///
    /// - Parameter identifier: Unique identifier for the connection.
    /// - Returns: A port number in the range 49152-65535.
    static func computePort(for identifier: String) -> UInt16 {
        // Use a simple hash: sum of character values with mixing
        var hash: UInt64 = 5381
        for char in identifier.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char) // hash * 33 + char
        }

        let port = UInt16(hash % UInt64(portRangeSize)) + portRangeStart
        #log(.info, "Computed port \(port, privacy: .public) for identifier '\(identifier, privacy: .public)'")
        return port
    }
}

// MARK: - RuntimeLocalSocketClientConnection

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
final class RuntimeLocalSocketClientConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

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

    /// Pending message handlers to apply to new connections.
    ///
    /// Accessed concurrently from public `setMessageHandler` overloads (caller
    /// contexts) and from the reconnection `Task` via `applyPendingHandlers`.
    /// `@Mutex` serializes `append` via the generated `_modify` accessor and
    /// lets iterators take a snapshot via `_pendingHandlers.withLock { $0 }`.
    @Mutex
    private var pendingHandlers: [@Sendable (RuntimeLocalSocketConnection) -> Void] = []

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
                applyPendingHandlers(to: connection)
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
        applyPendingHandlers(to: connection)
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
                applyPendingHandlers(to: connection)
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

    // MARK: - Connection Lifecycle

    /// Applies all pending handlers to a connection.
    ///
    /// Snapshots the array inside the lock so user-supplied handler closures
    /// are invoked outside the critical section.
    private func applyPendingHandlers(to connection: RuntimeLocalSocketConnection) {
        let snapshot = _pendingHandlers.withLock { $0 }
        for handler in snapshot {
            handler(connection)
        }
    }

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
                applyPendingHandlers(to: newConnection)
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

// MARK: - RuntimeLocalSocketServerConnection

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

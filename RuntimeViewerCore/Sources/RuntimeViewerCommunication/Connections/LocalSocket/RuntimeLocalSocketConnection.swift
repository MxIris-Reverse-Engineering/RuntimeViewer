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
    ///
    /// **`SO_NOSIGPIPE` is not an optimisation either.** Once the peer has
    /// reset the connection — the user detaching while a large reply is still
    /// being read, a device process killed, keepalive giving up — the next
    /// `send` fails with `EPIPE`, and without this option the kernel raises
    /// `SIGPIPE` first, whose default action ends the process. That is the
    /// host app on one end and, on the other, whatever process the payload was
    /// injected into. Nothing here ignores the signal process-wide, and a
    /// payload must not change its host process's signal dispositions, so it
    /// is set on the socket.
    static func configureSocketOptions(_ socketFD: Int32) {
        var noSignalOnBrokenPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignalOnBrokenPipe, socklen_t(MemoryLayout<Int32>.size))

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

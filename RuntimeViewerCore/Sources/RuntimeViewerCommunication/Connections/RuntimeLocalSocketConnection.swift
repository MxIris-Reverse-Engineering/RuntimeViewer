import Foundation
import FoundationToolbox
import OSLog
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
final class RuntimeLocalSocketConnection: RuntimeUnderlyingConnection, @unchecked Sendable {
    let id = UUID()

    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
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

    init(port: UInt16) throws {
        Self.logger.info("Creating connection to localhost:\(port, privacy: .public)")
        try connectToLocalhost(port: port)
    }

    private func connectToLocalhost(port: UInt16) throws {
        errno = 0
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RuntimeLocalSocketError.socketCreationFailed(errno: errno)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

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
            throw RuntimeLocalSocketError.connectFailed(errno: connectErrno, port: port)
        }

        // Disable Nagle algorithm for lower latency
        var noDelay: Int32 = 1
        setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        Self.logger.info("Connected to localhost:\(port, privacy: .public)")
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }
        guard socketFD >= 0 else { throw RuntimeLocalSocketError.notConnected }
        isStarted = true

        setupReceiver()
        observeIncomingMessages()

        stateSubject.send(.connected)
        Self.logger.info("Connection started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: nil))

        Self.logger.info("Connection stopped")
    }

    func stop(with error: RuntimeConnectionError) {
        guard isStarted else { return }
        isStarted = false

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: error))

        Self.logger.info("Connection stopped with error: \(error.localizedDescription, privacy: .public)")
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
                    self.logger.debug("Received \(bytesRead, privacy: .public) bytes")
                    self.messageChannel.appendReceivedData(data)
                } else if bytesRead == 0 {
                    self.logger.info("Connection closed by peer")
                    self.messageChannel.finishReceiving()
                    DispatchQueue.main.async {
                        self.stop(with: .peerClosed)
                    }
                    break
                } else {
                    let recvErrno = errno
                    if recvErrno != EAGAIN && recvErrno != EWOULDBLOCK {
                        self.logger.error("Receive error, errno=\(recvErrno, privacy: .public)")
                        self.messageChannel.finishReceiving()
                        DispatchQueue.main.async {
                            self.stop(with: .socketError("Receive error: errno=\(recvErrno)"))
                        }
                        break
                    }
                }
            }
        }
    }

    private func observeIncomingMessages() {
        Task {
            do {
                guard let stream = messageChannel.receivedMessages() else { return }
                for try await data in stream {
                    do {
                        let requestData = try JSONDecoder().decode(RuntimeRequestData.self, from: data)

                        // Check if this is a response to a pending request
                        if messageChannel.deliverToPendingRequest(identifier: requestData.identifier, data: data) {
                            continue
                        }

                        guard let handler = messageChannel.handler(for: requestData.identifier) else {
                            logger.warning("No handler for: \(requestData.identifier, privacy: .public)")
                            continue
                        }

                        logger.debug("Handling request: \(requestData.identifier, privacy: .public)")
                        let responseData = try await handler.closure(requestData.data)

                        if handler.responseType != RuntimeMessageNull.self {
                            let response = RuntimeRequestData(identifier: requestData.identifier, data: responseData)
                            try await send(requestData: response)
                        }
                    } catch {
                        logger.error("Handler error: \(error, privacy: .public)")
                        let errorResponse = RuntimeNetworkRequestError(message: "\(error)")
                        if let errorData = try? JSONEncoder().encode(errorResponse) {
                            try? await sendRaw(data: errorData + RuntimeMessageChannel.endMarkerData)
                        }
                    }
                }
            } catch {
                logger.error("Message observation error: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - RuntimeUnderlyingConnection

    func send(requestData: RuntimeRequestData) async throws {
        let data = try JSONEncoder().encode(requestData)
        try await messageChannel.send(data: data) { [weak self] dataToSend in
            try await self?.sendRaw(data: dataToSend)
        }
        logger.debug("Sent request: \(requestData.identifier, privacy: .public)")
    }

    func send<Response: Codable>(requestData: RuntimeRequestData) async throws -> Response {
        try await messageChannel.sendRequest(requestData: requestData) { [weak self] data in
            try await self?.sendRaw(data: data)
        }
    }

    func send<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        let requestData = try RuntimeRequestData(request: request)
        return try await send(requestData: requestData)
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
    case bindFailed(errno: Int32, port: UInt16)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case connectFailed(errno: Int32, port: UInt16)
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
        case .bindFailed(let errno, let port):
            return "RuntimeLocalSocketError.bindFailed: Failed to bind to 127.0.0.1:\(port) - \(Self.errnoDescription(errno))"
        case .listenFailed(let errno):
            return "RuntimeLocalSocketError.listenFailed: Failed to listen on socket - \(Self.errnoDescription(errno))"
        case .acceptFailed(let errno):
            return "RuntimeLocalSocketError.acceptFailed: Failed to accept connection - \(Self.errnoDescription(errno))"
        case .connectFailed(let errno, let port):
            return "RuntimeLocalSocketError.connectFailed: Failed to connect to 127.0.0.1:\(port) - \(Self.errnoDescription(errno))"
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

// MARK: - RuntimeLocalSocketPortDiscovery

/// Handles port discovery using deterministic port calculation.
///
/// Since sandboxed apps cannot share files via `/tmp` or other directories,
/// we use a hash-based algorithm to compute a deterministic port number
/// from the identifier. Both server and client can independently calculate
/// the same port without any file I/O.
enum RuntimeLocalSocketPortDiscovery: Loggable {

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
        logger.info("Computed port \(port, privacy: .public) for identifier '\(identifier, privacy: .public)'")
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
final class RuntimeLocalSocketClientConnection: RuntimeConnectionBase<RuntimeLocalSocketConnection>, @unchecked Sendable {
    private let identifier: String

    /// Creates a client connection using deterministic port calculation.
    ///
    /// - Parameters:
    ///   - identifier: Unique identifier matching the server's identifier.
    ///   - timeout: Maximum time to wait for server to be ready (default: 10 seconds).
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(identifier: String, timeout: TimeInterval = 10) async throws {
        self.identifier = identifier
        super.init()

        // Compute port deterministically (same algorithm as server)
        let port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)

        // Retry connection until server is ready or timeout
        let startTime = Date()
        var lastError: Error?

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let connection = try RuntimeLocalSocketConnection(port: port)
                self.underlyingConnection = connection
                try connection.start()
                return
            } catch {
                lastError = error
                // Wait before retry
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        throw lastError ?? RuntimeLocalSocketError.connectFailed(errno: ETIMEDOUT, port: port)
    }

    /// Creates a client connection to a known port.
    ///
    /// - Parameters:
    ///   - port: The server port to connect to.
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(port: UInt16) throws {
        self.identifier = ""
        super.init()

        let connection = try RuntimeLocalSocketConnection(port: port)
        self.underlyingConnection = connection
        try connection.start()
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
final class RuntimeLocalSocketServerConnection: RuntimeConnectionBase<RuntimeLocalSocketConnection>, @unchecked Sendable {
    private var serverSocketFD: Int32 = -1
    private let identifier: String

    /// Pending message handlers to apply to new connections.
    private var pendingHandlers: [@Sendable (RuntimeLocalSocketConnection) -> Void] = []

    /// Subscription for observing connection state changes.
    private var connectionStateCancellable: AnyCancellable?

    /// The port the server is listening on (available after `start()` is called).
    private(set) var port: UInt16 = 0

    /// Creates a server connection with deterministic port calculation.
    ///
    /// - Parameter identifier: Unique identifier used to compute the port.
    init(identifier: String) {
        self.identifier = identifier
        self.port = RuntimeLocalSocketPortDiscovery.computePort(for: identifier)
        super.init()
    }

    /// Creates a server connection on a specific port.
    ///
    /// - Parameter port: The port to listen on (0 for auto-assign).
    init(port: UInt16 = 0) {
        self.identifier = ""
        self.port = port
        super.init()
    }

    // MARK: - Message Handler Overrides

    override func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: NullPayload) in
                try await handler()
                return NullPayload.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) where Request: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                try await handler(request)
                return NullPayload.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Response>(name: String, handler: @escaping @Sendable () async throws -> Response) where Response: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: NullPayload) in
                return try await handler()
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) where Request: RuntimeRequest {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler { @Sendable (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request, Response>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) where Request: Codable, Response: Codable {
        let setupHandler: @Sendable (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = underlyingConnection {
            setupHandler(connection)
        }
    }

    /// Applies all pending handlers to a connection.
    private func applyPendingHandlers(to connection: RuntimeLocalSocketConnection) {
        for handler in pendingHandlers {
            handler(connection)
        }
    }

    /// Starts listening for connections.
    ///
    /// After this method returns, the server is ready to accept connections
    /// and the port file has been written for client discovery.
    /// Connections are accepted asynchronously in the background.
    func start() async throws {
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
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

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
            throw RuntimeLocalSocketError.bindFailed(errno: bindErrno, port: port)
        }

        errno = 0
        guard listen(serverSocketFD, 5) == 0 else {
            let listenErrno = errno
            close(serverSocketFD)
            serverSocketFD = -1
            throw RuntimeLocalSocketError.listenFailed(errno: listenErrno)
        }

        logger.info("Server listening on 127.0.0.1:\(self.port, privacy: .public)")

        // Start accepting connections in background (non-blocking)
        startAcceptingConnections()
    }

    /// Starts accepting connections asynchronously in background.
    private func startAcceptingConnections() {
        DispatchQueue.global().async { [weak self] in
            self?.acceptConnectionLoop()
        }
    }

    /// Continuously accepts client connections.
    private func acceptConnectionLoop() {
        guard serverSocketFD >= 0 else { return }

        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(serverSocketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            // Accept failed, likely server was stopped
            return
        }

        // Disable Nagle algorithm for lower latency
        var noDelay: Int32 = 1
        setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        let socketConnection = RuntimeLocalSocketConnection(socketFD: clientFD)
        self.underlyingConnection = socketConnection

        // Apply all pending message handlers to the new connection
        applyPendingHandlers(to: socketConnection)

        // Observe connection state to restart accepting when disconnected
        connectionStateCancellable = socketConnection.statePublisher
            .filter { $0.isDisconnected }
            .sink { [weak self] _ in
                self?.startAcceptingConnections()
            }

        do {
            try socketConnection.start()
        } catch {
            logger.error("Failed to start connection: \(error, privacy: .public)")
            // Try accepting again
            startAcceptingConnections()
        }
    }

    /// Stops the server and cleans up resources.
    override func stop() {
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        underlyingConnection?.stop()
        if serverSocketFD >= 0 {
            close(serverSocketFD)
            serverSocketFD = -1
        }
    }

    deinit {
        stop()
    }
}

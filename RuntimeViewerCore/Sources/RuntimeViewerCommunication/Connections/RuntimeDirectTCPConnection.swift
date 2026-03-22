#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

// MARK: - RuntimeDirectTCPConnection

/// A bidirectional TCP connection that doesn't require Bonjour or any special permissions.
///
/// `RuntimeDirectTCPConnection` provides direct TCP communication using Apple's
/// Network framework. Unlike Bonjour-based connections, this doesn't require
/// `NSBonjourServices` configuration - just a known host and port.
///
/// ## Why Direct TCP?
///
/// | Method | iOS Permissions Required |
/// |--------|-------------------------|
/// | Bonjour Browse | `NSBonjourServices` + `NSLocalNetworkUsageDescription` |
/// | Bonjour Advertise | `NSLocalNetworkUsageDescription` |
/// | **Direct TCP** | **None** (just needs host:port) |
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  Client App         │                    │  Server App         │
/// │                     │                    │                     │
/// │  User inputs or     │   TCP Connect      │  Displays IP:Port   │
/// │  scans QR code      │ ──────────────────>│  or generates QR    │
/// │  for host:port      │                    │                     │
/// │                     │                    │  NWListener         │
/// │  NWConnection       │ ═══ Messages ══════│  (listens on port)  │
/// └─────────────────────┘                    └─────────────────────┘
/// ```
///
/// ## Message Protocol
///
/// Messages are JSON-encoded `RuntimeRequestData` with `\nOK` terminator:
/// ```
/// {"identifier":"com.example.Request","data":"base64..."}\nOK
/// ```
///
/// ## Example: Server (Advertiser)
///
/// ```swift
/// let server = try await RuntimeDirectTCPServerConnection(port: 0)  // Auto-assign port
/// print("Server listening on \(server.host):\(server.port)")
///
/// server.setMessageHandler(requestType: GetClassListRequest.self) { request in
///     return GetClassListResponse(classes: [...])
/// }
/// ```
///
/// ## Example: Client (Connector)
///
/// ```swift
/// let client = try await RuntimeDirectTCPClientConnection(
///     host: "192.168.1.100",
///     port: 12345
/// )
///
/// let response = try await client.sendMessage(request: GetClassListRequest())
/// ```
@Loggable
final class RuntimeDirectTCPConnection: RuntimeUnderlyingConnection, @unchecked Sendable {
    let id = UUID()

    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    private let connection: NWConnection
    private let messageChannel = RuntimeMessageChannel()

    private var isStarted = false
    private let queue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeDirectTCPConnection")

    // MARK: - Initialization

    /// Creates an outgoing connection to the specified host and port.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address to connect to.
    ///   - port: The port number to connect to.
    init(host: String, port: UInt16) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )

        #log(.info, "Created outgoing connection to \(host, privacy: .public):\(port, privacy: .public)")
    }

    /// Creates a connection from an accepted NWConnection.
    ///
    /// - Parameter connection: The accepted connection from NWListener.
    init(connection: NWConnection) {
        self.connection = connection
        #log(.info, "Created incoming connection: \(connection.debugDescription, privacy: .public)")
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }
        isStarted = true

        setupStateHandler()
        setupReceiver()
        observeIncomingMessages()

        connection.start(queue: queue)
        #log(.info, "Connection started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        connection.stateUpdateHandler = nil
        connection.cancel()
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: nil))

        #log(.info, "Connection stopped")
    }

    func stop(with error: RuntimeConnectionError) {
        guard isStarted else { return }
        isStarted = false

        connection.stateUpdateHandler = nil
        connection.cancel()
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: error))

        #log(.info, "Connection stopped with error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - State Handling

    private func setupStateHandler() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.handleStateChange(state)
        }
    }

    private func handleStateChange(_ nwState: NWConnection.State) {
        switch nwState {
        case .setup:
            #log(.debug, "Connection is setup")
        case .waiting(let error):
            #log(.default, "Connection is waiting: \(error, privacy: .public)")
            stop(with: .networkError("Connection waiting: \(error.localizedDescription)"))
        case .preparing:
            #log(.debug, "Connection is preparing")
        case .ready:
            #log(.info, "Connection is ready")
            stateSubject.send(.connected)
        case .failed(let error):
            #log(.error, "Connection failed: \(error, privacy: .public)")
            stop(with: .networkError("Connection failed: \(error.localizedDescription)"))
        case .cancelled:
            #log(.info, "Connection cancelled")
        @unknown default:
            break
        }
    }

    // MARK: - Receiving

    private func setupReceiver() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                #log(.error, "Receive error: \(error, privacy: .public)")
                self.messageChannel.finishReceiving(throwing: error)
                self.stop()
            } else if isComplete {
                #log(.debug, "Receive complete")
                self.messageChannel.finishReceiving()
                self.stop()
            } else if let data {
                #log(.debug, "Received \(data.count, privacy: .public) bytes")
                self.messageChannel.appendReceivedData(data)
                self.setupReceiver()
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
                            #log(.default, "No handler for: \(requestData.identifier, privacy: .public)")
                            continue
                        }

                        #log(.debug, "Handling request: \(requestData.identifier, privacy: .public)")
                        let responseData = try await handler.closure(requestData.data)

                        if handler.responseType != RuntimeMessageNull.self {
                            let response = RuntimeRequestData(identifier: requestData.identifier, data: responseData)
                            try await send(requestData: response)
                        }
                    } catch {
                        #log(.error, "Handler error: \(error, privacy: .public)")
                        let errorResponse = RuntimeNetworkRequestError(message: "\(error)")
                        if let errorData = try? JSONEncoder().encode(errorResponse) {
                            try? await sendRaw(data: errorData + RuntimeMessageChannel.endMarkerData)
                        }
                    }
                }
            } catch {
                #log(.error, "Message observation error: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - RuntimeUnderlyingConnection

    func send(requestData: RuntimeRequestData) async throws {
        let data = try JSONEncoder().encode(requestData)
        try await messageChannel.send(data: data) { [weak self] dataToSend in
            try await self?.sendRaw(data: dataToSend)
        }
        #log(.debug, "Sent request: \(requestData.identifier, privacy: .public)")
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

// MARK: - RuntimeDirectTCPClientConnection

/// Client connection that connects directly to a known host and port.
///
/// Use this when you have the server's IP address and port, either from:
/// - User input
/// - QR code scan
/// - Configuration file
///
/// ## Usage
///
/// ```swift
/// let client = try await RuntimeDirectTCPClientConnection(
///     host: "192.168.1.100",
///     port: 12345
/// )
///
/// let classes = try await client.sendMessage(request: GetClassListRequest())
/// ```
@Loggable
final class RuntimeDirectTCPClientConnection: RuntimeConnectionBase<RuntimeDirectTCPConnection>, @unchecked Sendable {
    private var connectionStateCancellable: AnyCancellable?

    /// Creates a client connection to the specified host and port.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the server.
    ///   - port: The port number the server is listening on.
    ///   - timeout: Maximum time to wait for connection (default: 10 seconds).
    init(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        super.init()

        #log(.info, "Connecting to direct TCP server at \(host, privacy: .public):\(port, privacy: .public) (timeout: \(timeout, privacy: .public)s)")

        let connection = RuntimeDirectTCPConnection(host: host, port: port)
        self.underlyingConnection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let didResume = Mutex<Bool>(false)

            // Observe connection state
            self.connectionStateCancellable = connection.statePublisher
                .sink { state in
                    #log(.info, "Direct TCP client connection state: \(String(describing: state), privacy: .public)")
                    if state.isConnected {
                        let shouldResume = didResume.withLock { val -> Bool in
                            guard !val else { return false }
                            val = true
                            return true
                        }
                        if shouldResume {
                            #log(.info, "Direct TCP client connected to \(host, privacy: .public):\(port, privacy: .public)")
                            continuation.resume()
                        }
                    } else if state.isDisconnected {
                        let shouldResume = didResume.withLock { val -> Bool in
                            guard !val else { return false }
                            val = true
                            return true
                        }
                        if shouldResume {
                            if case .disconnected(let error) = state, let error {
                                #log(.error, "Direct TCP client connection failed: \(error.localizedDescription, privacy: .public)")
                                continuation.resume(throwing: error)
                            } else {
                                #log(.error, "Direct TCP client connection failed (no error)")
                                continuation.resume(throwing: RuntimeDirectTCPError.connectionFailed)
                            }
                        }
                    }
                }

            do {
                try connection.start()
            } catch {
                let shouldResume = didResume.withLock { val -> Bool in
                    guard !val else { return false }
                    val = true
                    return true
                }
                if shouldResume {
                    #log(.error, "Failed to start direct TCP client: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let shouldResume = didResume.withLock { val -> Bool in
                    guard !val else { return false }
                    val = true
                    return true
                }
                if shouldResume {
                    #log(.error, "Direct TCP client connection timed out after \(timeout, privacy: .public)s")
                    connection.stop(with: .timeout)
                    continuation.resume(throwing: RuntimeDirectTCPError.timeout)
                }
            }
        }
    }

    override func stop() {
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        underlyingConnection?.stop()
    }
}

// MARK: - RuntimeDirectTCPServerConnection

/// Server connection that listens on a specified port for incoming connections.
///
/// The server can listen on:
/// - Port 0: System assigns an available port (recommended)
/// - Specific port: Use a known port number
///
/// ## Usage
///
/// ```swift
/// let server = try await RuntimeDirectTCPServerConnection(port: 0)
/// print("Listening on \(server.host):\(server.port)")
///
/// // Display this info to user or generate QR code
/// server.setMessageHandler(requestType: GetClassListRequest.self) { request in
///     return GetClassListResponse(classes: [...])
/// }
/// ```
@Loggable
final class RuntimeDirectTCPServerConnection: RuntimeConnectionBase<RuntimeDirectTCPConnection>, @unchecked Sendable {
    private var listener: NWListener?
    private var connectionStateCancellable: AnyCancellable?
    private let listenerParameters: NWParameters

    /// Stable state subject that bridges state from underlying connections across reconnections.
    private let ownStateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    override var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        ownStateSubject.eraseToAnyPublisher()
    }

    override var state: RuntimeConnectionState {
        ownStateSubject.value
    }

    /// The host address the server is listening on.
    private(set) var host: String = ""

    /// The port the server is listening on (available after initialization).
    private(set) var port: UInt16 = 0

    override var connectionInfo: RuntimeConnectionInfo? {
        RuntimeConnectionInfo(host: host, port: port)
    }

    /// Creates a server that listens on the specified port.
    ///
    /// - Parameters:
    ///   - port: The port to listen on (0 for auto-assign).
    ///   - waitForConnection: If `true` (default), waits until a client connects before returning.
    ///     If `false`, returns as soon as the listener is ready (port assigned), accepting connections asynchronously.
    init(port: UInt16 = 0, waitForConnection: Bool = true) async throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        self.listenerParameters = parameters

        super.init()

        #log(.info, "Creating direct TCP server on port \(port, privacy: .public) (0 = auto-assign)")

        let listener = if port == 0 {
            try NWListener(using: parameters)
        } else {
            try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        }

        self.listener = listener

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let didResume = Mutex<Bool>(false)

            listener.stateUpdateHandler = { [weak self] listenerState in
                guard let self else { return }

                #log(.info, "Direct TCP listener state: \(String(describing: listenerState), privacy: .public)")

                switch listenerState {
                case .ready:
                    if let port = listener.port {
                        self.port = port.rawValue
                        self.host = Self.getLocalIPAddress() ?? "127.0.0.1"
                        #log(.info, "Server listening on \(self.host, privacy: .public):\(self.port, privacy: .public)")
                    }
                    if !waitForConnection {
                        let shouldResume = didResume.withLock { val -> Bool in
                            guard !val else { return false }
                            val = true
                            return true
                        }
                        if shouldResume {
                            #log(.info, "Server ready (not waiting for connection)")
                            continuation.resume()
                        }
                    }
                case .failed(let error):
                    let shouldResume = didResume.withLock { val -> Bool in
                        guard !val else { return false }
                        val = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] newConnection in
                guard let self else { return }

                #log(.info, "Accepted new direct TCP connection: \(newConnection.debugDescription, privacy: .public)")

                let tcpConnection = RuntimeDirectTCPConnection(connection: newConnection)
                self.underlyingConnection = tcpConnection

                // Observe connection state
                self.connectionStateCancellable = tcpConnection.statePublisher
                    .sink { [weak self] state in
                        #log(.info, "Direct TCP connection state: \(String(describing: state), privacy: .public)")
                        if state.isConnected {
                            #log(.info, "Direct TCP client connected")
                            self?.ownStateSubject.send(.connected)
                            let shouldResume = didResume.withLock { val -> Bool in
                                guard !val else { return false }
                                val = true
                                return true
                            }
                            if shouldResume {
                                #log(.info, "Initial direct TCP connection ready")
                                continuation.resume()
                            }
                        } else if state.isDisconnected {
                            let shouldResume = didResume.withLock { val -> Bool in
                                guard !val else { return false }
                                val = true
                                return true
                            }
                            if shouldResume {
                                // Connection failed before becoming ready
                                if case .disconnected(let error) = state, let error {
                                    #log(.error, "Direct TCP connection failed before ready: \(error.localizedDescription, privacy: .public)")
                                    continuation.resume(throwing: error)
                                } else {
                                    #log(.error, "Direct TCP connection disconnected before ready without error")
                                    continuation.resume(throwing: RuntimeDirectTCPError.connectionFailed)
                                }
                            } else {
                                // Connection was ready and then disconnected, restart listening
                                #log(.info, "Direct TCP connection disconnected, restarting listener...")
                                self?.ownStateSubject.send(state)
                                Task { [weak self] in
                                    do {
                                        try await self?.restartListening()
                                    } catch {
                                        #log(.error, "Failed to restart listening: \(error, privacy: .public)")
                                    }
                                }
                            }
                        }
                    }

                do {
                    try tcpConnection.start()
                } catch {
                    #log(.error, "Failed to start direct TCP connection: \(error, privacy: .public)")
                    Task { [weak self] in
                        do {
                            try await self?.restartListening()
                        } catch {
                            #log(.error, "Failed to restart listening: \(error, privacy: .public)")
                        }
                    }
                }

                listener.newConnectionHandler = nil
                listener.cancel()
            }

            listener.start(queue: .main)
        }
    }

    private func restartListening() async throws {
        #log(.info, "Restarting direct TCP listener on \(self.host, privacy: .public):\(self.port, privacy: .public)...")
        ownStateSubject.send(.connecting)

        let newListener = try NWListener(using: listenerParameters, on: NWEndpoint.Port(rawValue: self.port)!)
        self.listener = newListener

        newListener.stateUpdateHandler = { [weak self] state in
            #log(.info, "Restarted direct TCP listener state: \(String(describing: state), privacy: .public)")
            if case .failed(let error) = state {
                #log(.error, "Restarted direct TCP listener failed: \(error, privacy: .public)")
                self?.listener = nil
            }
        }

        newListener.newConnectionHandler = { [weak self] newConnection in
            guard let self else { return }

            #log(.info, "Accepted new direct TCP connection after restart: \(newConnection.debugDescription, privacy: .public)")

            let tcpConnection = RuntimeDirectTCPConnection(connection: newConnection)
            self.underlyingConnection = tcpConnection

            self.connectionStateCancellable = tcpConnection.statePublisher
                .sink { [weak self] state in
                    #log(.info, "Direct TCP reconnected connection state: \(String(describing: state), privacy: .public)")
                    if state.isConnected {
                        self?.ownStateSubject.send(.connected)
                    } else if state.isDisconnected {
                        #log(.info, "Direct TCP reconnected connection disconnected, restarting listener...")
                        self?.ownStateSubject.send(state)
                        Task { [weak self] in
                            do {
                                try await self?.restartListening()
                            } catch {
                                #log(.error, "Failed to restart listening: \(error, privacy: .public)")
                            }
                        }
                    }
                }

            do {
                try tcpConnection.start()
            } catch {
                #log(.error, "Failed to start direct TCP connection on restart: \(error, privacy: .public)")
            }

            newListener.newConnectionHandler = nil
            newListener.cancel()
        }

        newListener.start(queue: .main)
    }

    /// Stops the server and closes all connections.
    override func stop() {
        #log(.info, "Stopping direct TCP server on \(self.host, privacy: .public):\(self.port, privacy: .public)")
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        underlyingConnection?.stop()
        listener?.cancel()
        listener = nil
        ownStateSubject.send(.disconnected(error: nil))
    }

    deinit {
        stop()
    }

    /// Gets the local IP address of the device.
    private static func getLocalIPAddress() -> String? {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)

                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }
        }

        return address
    }
}

// MARK: - RuntimeDirectTCPError

/// Errors that can occur during direct TCP operations.
enum RuntimeDirectTCPError: Error, LocalizedError {
    case connectionFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to establish connection"
        case .timeout:
            return "Connection timed out"
        }
    }
}

#endif

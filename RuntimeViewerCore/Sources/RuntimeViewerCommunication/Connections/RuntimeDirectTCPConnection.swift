#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import os.log

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
final class RuntimeDirectTCPConnection: RuntimeUnderlyingConnection, @unchecked Sendable {
    let id = UUID()

    var didStop: ((RuntimeDirectTCPConnection) -> Void)?
    var didReady: ((RuntimeDirectTCPConnection) -> Void)?

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

        Self.logger.info("Created outgoing connection to \(host, privacy: .public):\(port, privacy: .public)")
    }

    /// Creates a connection from an accepted NWConnection.
    ///
    /// - Parameter connection: The accepted connection from NWListener.
    init(connection: NWConnection) {
        self.connection = connection
        Self.logger.info("Created incoming connection: \(connection.debugDescription, privacy: .public)")
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }
        isStarted = true

        setupStateHandler()
        setupReceiver()
        observeIncomingMessages()

        connection.start(queue: queue)
        Self.logger.info("Connection started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        connection.stateUpdateHandler = nil
        connection.cancel()
        messageChannel.finishReceiving()
        didStop?(self)
        didStop = nil

        Self.logger.info("Connection stopped")
    }

    // MARK: - State Handling

    private func setupStateHandler() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.handleStateChange(state)
        }
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .setup:
            logger.debug("Connection is setup")
        case .waiting(let error):
            logger.warning("Connection is waiting: \(error, privacy: .public)")
            stop()
        case .preparing:
            logger.debug("Connection is preparing")
        case .ready:
            logger.info("Connection is ready")
            didReady?(self)
            didReady = nil
        case .failed(let error):
            logger.error("Connection failed: \(error, privacy: .public)")
            stop()
        case .cancelled:
            logger.info("Connection cancelled")
        @unknown default:
            break
        }
    }

    // MARK: - Receiving

    private func setupReceiver() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("Receive error: \(error, privacy: .public)")
                self.messageChannel.finishReceiving(throwing: error)
                self.stop()
            } else if isComplete {
                self.logger.debug("Receive complete")
                self.messageChannel.finishReceiving()
                self.stop()
            } else if let data {
                self.logger.debug("Received \(data.count, privacy: .public) bytes")
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
final class RuntimeDirectTCPClientConnection: RuntimeConnectionBase<RuntimeDirectTCPConnection>, @unchecked Sendable {
    /// Creates a client connection to the specified host and port.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the server.
    ///   - port: The port number the server is listening on.
    ///   - timeout: Maximum time to wait for connection (default: 10 seconds).
    init(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        super.init()

        let connection = RuntimeDirectTCPConnection(host: host, port: port)
        self.underlyingConnection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let didResume = Mutex<Bool>(false)

            connection.didReady = { _ in
                if didResume.withLock({ !$0 }) {
                    didResume.withLock { $0 = true }
                    continuation.resume()
                }
            }

            connection.didStop = { _ in
                if didResume.withLock({ !$0 }) {
                    didResume.withLock { $0 = true }
                    continuation.resume(throwing: RuntimeDirectTCPError.connectionFailed)
                }
            }

            do {
                try connection.start()
            } catch {
                if didResume.withLock({ !$0 }) {
                    didResume.withLock { $0 = true }
                    continuation.resume(throwing: error)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if didResume.withLock({ !$0 }) {
                    didResume.withLock { $0 = true }
                    connection.stop()
                    continuation.resume(throwing: RuntimeDirectTCPError.timeout)
                }
            }
        }
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
final class RuntimeDirectTCPServerConnection: RuntimeConnectionBase<RuntimeDirectTCPConnection>, @unchecked Sendable {
    private var listener: NWListener?

    /// The host address the server is listening on.
    private(set) var host: String = ""

    /// The port the server is listening on (available after initialization).
    private(set) var port: UInt16 = 0

    /// Creates a server that listens on the specified port.
    ///
    /// - Parameter port: The port to listen on (0 for auto-assign).
    init(port: UInt16 = 0) async throws {
        super.init()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        }

        self.listener = listener

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let didResume = Mutex<Bool>(false)

            listener.stateUpdateHandler = { [weak self] listenerState in
                guard let self else { return }

                switch listenerState {
                case .ready:
                    if let port = listener.port {
                        self.port = port.rawValue
                        self.host = Self.getLocalIPAddress() ?? "127.0.0.1"
                        Self.logger.info("Server listening on \(self.host, privacy: .public):\(self.port, privacy: .public)")
                    }
                case .failed(let error):
                    if didResume.withLock({ !$0 }) {
                        didResume.withLock { $0 = true }
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] newConnection in
                guard let self else { return }

                Self.logger.info("Accepted new connection")

                let tcpConnection = RuntimeDirectTCPConnection(connection: newConnection)
                self.underlyingConnection = tcpConnection

                tcpConnection.didReady = { _ in
                    if didResume.withLock({ !$0 }) {
                        didResume.withLock { $0 = true }
                        continuation.resume()
                    }
                }

                tcpConnection.didStop = { [weak self] _ in
                    Task { [weak self] in
                        try await self?.restartListening()
                    }
                }

                do {
                    try tcpConnection.start()
                } catch {
                    Self.logger.error("Failed to start connection: \(error, privacy: .public)")
                    Task { [weak self] in
                        try await self?.restartListening()
                    }
                }
            }

            listener.start(queue: .main)
        }
    }

    private func restartListening() async throws {
        listener?.newConnectionHandler = { [weak self] newConnection in
            guard let self else { return }

            Self.logger.info("Accepted new connection")

            let tcpConnection = RuntimeDirectTCPConnection(connection: newConnection)
            self.underlyingConnection = tcpConnection

            tcpConnection.didStop = { [weak self] _ in
                Task { [weak self] in
                    try await self?.restartListening()
                }
            }

            do {
                try tcpConnection.start()
            } catch {
                Self.logger.error("Failed to start connection: \(error, privacy: .public)")
            }
        }
    }

    /// Stops the server and closes all connections.
    func stop() {
        underlyingConnection?.stop()
        listener?.cancel()
        listener = nil
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

#if canImport(Network)

import Foundation
import Network
import os.log

// MARK: - RuntimeNetworkConnection

/// A bidirectional communication channel over the network using Apple's Network framework.
///
/// `RuntimeNetworkConnection` enables communication between devices on the same local
/// network, typically used for iOS device to Mac communication via Bonjour service discovery.
///
/// ## Architecture
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  iOS Device         │                    │  Mac                │
/// │                     │                    │                     │
/// │  RuntimeViewer App  │   Bonjour Browse   │  RuntimeViewer App  │
/// │                     │ ──────────────────>│                     │
/// │                     │                    │  NWListener         │
/// │  NetworkClient      │ <── TCP Connect ───│  (Advertises)       │
/// │                     │                    │                     │
/// │                     │ ═══ Messages ══════│  NetworkServer      │
/// └─────────────────────┘                    └─────────────────────┘
/// ```
///
/// ## Message Protocol
///
/// Messages are JSON-encoded `RuntimeRequestData` with `\nOK` terminator:
/// ```
/// {"identifier":"com.example.MyRequest","data":"base64..."}\nOK
/// ```
///
/// ## Features
///
/// - Automatic Bonjour service discovery
/// - TCP keepalive for connection health monitoring
/// - Peer-to-peer communication support
/// - Async/await message handling
///
/// ## Use Cases
///
/// - Inspecting iOS app runtime from a Mac
/// - Cross-device debugging and development
/// - Remote runtime exploration
///
/// - Note: Requires both devices to be on the same local network.
///   For sandboxed app injection, use `RuntimeLocalSocketConnection` instead.
final class RuntimeNetworkConnection: RuntimeUnderlyingConnection, @unchecked Sendable, Loggable {
    let id = UUID()

    var didStop: ((RuntimeNetworkConnection) -> Void)?
    var didReady: ((RuntimeNetworkConnection) -> Void)?

    private let connection: NWConnection
    private let messageChannel = RuntimeMessageChannel()

    private var isStarted = false
    private let queue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeNetworkConnection")

    // MARK: - Initialization

    /// Creates an outgoing connection to the specified endpoint.
    ///
    /// - Parameter endpoint: The Bonjour-discovered endpoint to connect to.
    init(endpoint: NWEndpoint) throws {
        Self.logger.info("Creating outgoing connection to: \(endpoint.debugDescription, privacy: .public)")

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        self.connection = NWConnection(to: endpoint, using: parameters)
        try start()
    }

    /// Creates a connection from an accepted NWConnection.
    ///
    /// - Parameter connection: The accepted connection from NWListener.
    init(connection: NWConnection) throws {
        Self.logger.info("Creating incoming connection: \(connection.debugDescription, privacy: .public)")
        self.connection = connection
        try start()
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

// MARK: - RuntimeNetworkClientConnection

/// Network client that connects to a Bonjour-discovered server.
///
/// Use this to connect to a `RuntimeNetworkServerConnection` that was discovered
/// via Bonjour service browsing.
///
/// ## Usage
///
/// ```swift
/// // After discovering endpoint via Bonjour browser
/// let client = try RuntimeNetworkClientConnection(endpoint: discoveredEndpoint)
///
/// // Send requests
/// let classes = try await client.sendMessage(request: GetClassListRequest())
/// ```
///
/// - Note: The endpoint is typically obtained from `RuntimeNetworkBrowser`.
final class RuntimeNetworkClientConnection: RuntimeConnectionBase<RuntimeNetworkConnection>, @unchecked Sendable {
    /// Creates a client connection to the specified network endpoint.
    ///
    /// - Parameter endpoint: The Bonjour-discovered endpoint to connect to.
    /// - Throws: `RuntimeNetworkError` if connection cannot be established.
    init(endpoint: RuntimeNetworkEndpoint) throws {
        super.init()
        self.underlyingConnection = try RuntimeNetworkConnection(endpoint: endpoint.endpoint)
    }
}

// MARK: - RuntimeNetworkServerConnection

/// Network server that advertises via Bonjour and accepts incoming connections.
///
/// Use this to create a server that can be discovered by `RuntimeNetworkClientConnection`
/// on other devices via Bonjour.
///
/// ## Usage
///
/// ```swift
/// let server = try await RuntimeNetworkServerConnection(name: "My Mac")
///
/// // Register handlers for incoming requests
/// server.setMessageHandler(requestType: GetClassListRequest.self) { request in
///     return GetClassListResponse(classes: objc_copyClassList()...)
/// }
/// ```
///
/// - Note: The server automatically restarts listening after a client disconnects.
final class RuntimeNetworkServerConnection: RuntimeConnectionBase<RuntimeNetworkConnection>, @unchecked Sendable, Loggable {
    private var listener: NWListener?

    init(name: String) async throws {
        super.init()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: name, type: RuntimeNetworkBonjour.type)
        self.listener = listener

        try await waitForConnection(listener: listener)
    }

    private func waitForConnection(listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Use a class to safely track resume state across concurrent callbacks
            final class ResumeState: @unchecked Sendable {
                private var _didResume = false
                private let lock = NSLock()

                var didResume: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return _didResume
                }

                func tryResume() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if _didResume { return false }
                    _didResume = true
                    return true
                }
            }
            let state = ResumeState()

            listener.newConnectionHandler = { [weak self] newConnection in
                guard let self, !state.didResume else { return }

                Self.logger.info("Accepted new connection")

                do {
                    let connection = try RuntimeNetworkConnection(connection: newConnection)
                    self.underlyingConnection = connection

                    connection.didReady = { _ in
                        if state.tryResume() {
                            continuation.resume()
                        }
                    }

                    connection.didStop = { [weak self] _ in
                        Task { [weak self] in
                            try await self?.restartListening()
                        }
                    }
                } catch {
                    if state.tryResume() {
                        continuation.resume(throwing: error)
                    }
                }

                listener.newConnectionHandler = nil
                listener.cancel()
            }

            listener.start(queue: .main)
        }
    }

    private func restartListening() async throws {
        guard let listener else { return }

        listener.newConnectionHandler = { [weak self] newConnection in
            guard let self else { return }

            Self.logger.info("Accepted new connection")

            do {
                let connection = try RuntimeNetworkConnection(connection: newConnection)
                self.underlyingConnection = connection

                connection.didStop = { [weak self] _ in
                    Task { [weak self] in
                        try await self?.restartListening()
                    }
                }
            } catch {
                Self.logger.error("Failed to create connection: \(error, privacy: .public)")
            }
        }
    }
}

#endif

#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

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
@Loggable
final class RuntimeNetworkConnection: RuntimeUnderlyingConnection, @unchecked Sendable {
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
    private var waitingTimeoutWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeNetworkConnection")

    // MARK: - Initialization

    /// Creates an outgoing connection to the specified endpoint.
    ///
    /// - Parameter endpoint: The Bonjour-discovered endpoint to connect to.
    init(endpoint: NWEndpoint) throws {
        #log(.info, "Creating outgoing connection to: \(endpoint.debugDescription, privacy: .public)")

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
        #log(.info, "Creating incoming connection: \(connection.debugDescription, privacy: .public)")
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
        #log(.info, "Connection started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        waitingTimeoutWork?.cancel()
        waitingTimeoutWork = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        messageChannel.finishReceiving()
        stateSubject.send(.disconnected(error: nil))

        #log(.info, "Connection stopped")
    }

    func stop(with error: RuntimeConnectionError) {
        guard isStarted else { return }
        isStarted = false

        waitingTimeoutWork?.cancel()
        waitingTimeoutWork = nil
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
            // Start tolerance window — allow transient .waiting during permission
            // negotiation, DNS resolution, or brief network transitions
            if waitingTimeoutWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isStarted else { return }
                    #log(.error, "Connection waiting timeout exceeded, stopping")
                    self.stop(with: .networkError("Connection waiting timeout: \(error.localizedDescription)"))
                }
                waitingTimeoutWork = work
                queue.asyncAfter(deadline: .now() + 10, execute: work)
            }
        case .preparing:
            #log(.debug, "Connection is preparing")
        case .ready:
            #log(.info, "Connection is ready")
            waitingTimeoutWork?.cancel()
            waitingTimeoutWork = nil
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
        messageChannel.onMessageReceived = { [weak self] data in
            guard let self else { return }
            Task { await self.handleReceivedMessage(data) }
        }
    }

    private func handleReceivedMessage(_ data: Data) async {
        do {
            let requestData = try JSONDecoder().decode(RuntimeRequestData.self, from: data)

            // Check if this is a response to a pending request
            if messageChannel.deliverToPendingRequest(identifier: requestData.identifier, data: data) {
                return
            }

            guard let handler = messageChannel.handler(for: requestData.identifier) else {
                #log(.default, "No handler for: \(requestData.identifier, privacy: .public)")
                return
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
@Loggable
final class RuntimeNetworkServerConnection: RuntimeConnectionBase<RuntimeNetworkConnection>, @unchecked Sendable {
    private var listener: NWListener?
    private var connectionStateCancellable: AnyCancellable?
    private let serviceName: String
    private let listenerParameters: NWParameters

    /// Stable state subject that bridges state from underlying connections across reconnections.
    /// This ensures subscribers (e.g., RuntimeEngine) always receive state updates,
    /// even when the underlying connection is replaced after a client reconnects.
    private let ownStateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    override var statePublisher: AnyPublisher<RuntimeConnectionState, Never> {
        ownStateSubject.eraseToAnyPublisher()
    }

    override var state: RuntimeConnectionState {
        ownStateSubject.value
    }

    init(name: String) async throws {
        self.serviceName = name

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        self.listenerParameters = parameters

        super.init()

        #log(.info, "Creating Bonjour server with name: \(name, privacy: .public), service type: \(RuntimeNetworkBonjour.type, privacy: .public)")

        let listener = try NWListener(using: parameters)
        listener.service = RuntimeNetworkBonjour.makeService(name: name)
        self.listener = listener

        #log(.info, "Waiting for incoming Bonjour connection...")
        try await waitForConnection(listener: listener)
        #log(.info, "Bonjour server connection established for name: \(name, privacy: .public)")
    }

    private func waitForConnection(listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in

            let didResume = Mutex<Bool>(false)
            // Guard against multiple NWConnections from different network paths
            // (IPv6 link-local, IPv4, AWDL) — only the first one should be accepted.
            let hasAccepted = Mutex<Bool>(false)

            listener.stateUpdateHandler = { state in
                #log(.info, "Bonjour listener state: \(String(describing: state), privacy: .public)")
                switch state {
                case .failed(let error):
                    let shouldResume = didResume.withLock { val -> Bool in
                        guard !val else { return false }
                        val = true
                        return true
                    }
                    if shouldResume {
                        #log(.error, "Bonjour listener failed: \(error, privacy: .public)")
                        continuation.resume(throwing: RuntimeConnectionError.networkError("Listener failed: \(error.localizedDescription)"))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] newConnection in
                let isFirstAccept = hasAccepted.withLock { accepted -> Bool in
                    guard !accepted else { return false }
                    accepted = true
                    return true
                }
                guard isFirstAccept else {
                    #log(.info, "Rejecting duplicate Bonjour connection from another network path: \(newConnection.debugDescription, privacy: .public)")
                    newConnection.cancel()
                    return
                }
                guard let self else { return }

                // Stop accepting new connections immediately
                listener.newConnectionHandler = nil
                listener.cancel()

                #log(.info, "Accepted new Bonjour connection: \(newConnection.debugDescription, privacy: .public)")

                do {
                    let connection = try RuntimeNetworkConnection(connection: newConnection)
                    self.underlyingConnection = connection

                    // Observe connection state
                    self.connectionStateCancellable = connection.statePublisher
                        .sink { [weak self] state in
                            #log(.info, "Bonjour connection state changed: \(String(describing: state), privacy: .public)")
                            if state.isConnected {
                                let shouldResume = didResume.withLock { val -> Bool in
                                    guard !val else { return false }
                                    val = true
                                    return true
                                }
                                if shouldResume {
                                    #log(.info, "Initial Bonjour connection ready")
                                    self?.ownStateSubject.send(.connected)
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
                                        #log(.error, "Bonjour connection failed before ready: \(error.localizedDescription, privacy: .public)")
                                        continuation.resume(throwing: error)
                                    } else {
                                        #log(.error, "Bonjour connection disconnected before ready without error")
                                        continuation.resume(throwing: RuntimeConnectionError.peerClosed)
                                    }
                                } else {
                                    // Connection was ready and then disconnected, restart listening
                                    #log(.info, "Bonjour connection disconnected, restarting listener...")
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
                } catch {
                    #log(.error, "Failed to create Bonjour connection: \(error, privacy: .public)")
                    let shouldResume = didResume.withLock { val -> Bool in
                        guard !val else { return false }
                        val = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: error)
                    }
                }
            }

            listener.start(queue: .main)
        }
    }

    private func restartListening() async throws {
        #log(.info, "Restarting Bonjour listener with new instance...")
        ownStateSubject.send(.connecting)

        let newListener = try NWListener(using: listenerParameters)
        newListener.service = RuntimeNetworkBonjour.makeService(name: serviceName)
        self.listener = newListener

        newListener.stateUpdateHandler = { [weak self] state in
            #log(.info, "Restarted Bonjour listener state: \(String(describing: state), privacy: .public)")
            if case .failed(let error) = state {
                #log(.error, "Restarted Bonjour listener failed: \(error, privacy: .public), will not accept new connections")
                self?.listener = nil
            }
        }

        let hasAccepted = Mutex<Bool>(false)

        newListener.newConnectionHandler = { [weak self] newConnection in
            let isFirstAccept = hasAccepted.withLock { accepted -> Bool in
                guard !accepted else { return false }
                accepted = true
                return true
            }
            guard isFirstAccept else {
                #log(.info, "Rejecting duplicate Bonjour connection from another network path after restart: \(newConnection.debugDescription, privacy: .public)")
                newConnection.cancel()
                return
            }
            guard let self else { return }

            // Stop accepting new connections immediately
            newListener.newConnectionHandler = nil
            newListener.cancel()

            #log(.info, "Accepted new Bonjour connection after restart: \(newConnection.debugDescription, privacy: .public)")

            do {
                let connection = try RuntimeNetworkConnection(connection: newConnection)
                self.underlyingConnection = connection

                self.connectionStateCancellable = connection.statePublisher
                    .sink { [weak self] state in
                        #log(.info, "Bonjour reconnected connection state: \(String(describing: state), privacy: .public)")
                        if state.isConnected {
                            self?.ownStateSubject.send(.connected)
                        } else if state.isDisconnected {
                            #log(.info, "Bonjour reconnected connection disconnected, restarting listener...")
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
            } catch {
                #log(.error, "Failed to create Bonjour connection on restart: \(error, privacy: .public)")
            }
        }

        newListener.start(queue: .main)
    }

    override func stop() {
        #log(.info, "Stopping Bonjour server connection")
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        underlyingConnection?.stop()
        listener?.cancel()
        listener = nil
        ownStateSubject.send(.disconnected(error: nil))
    }
}

#endif

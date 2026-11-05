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

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    private let connection: NWConnection
    private let messageChannel = RuntimeMessageChannel()

    private var isStarted = false
    private var waitingTimeoutWork: DispatchWorkItem?
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
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .responsiveData

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
            // `.waiting` is transient: DNS resolution, route changes, and — even
            // for a direct LAN IP on iOS 14+ — the local-network permission
            // prompt all surface here before the connection recovers. Tear down
            // only if it fails to recover within a tolerance window (matching
            // `RuntimeNetworkConnection`), not on the first `.waiting`.
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
                return
            }

            // Consume any delivered bytes BEFORE acting on `isComplete`.
            // NWConnection can deliver the peer's final chunk together with the
            // FIN (`data` non-nil and `isComplete == true` in the same callback).
            // Checking `isComplete` first would drop that trailing message.
            if let data, !data.isEmpty {
                #log(.debug, "Received \(data.count, privacy: .public) bytes")
                self.messageChannel.appendReceivedData(data)
            }

            if isComplete {
                #log(.debug, "Receive complete")
                self.messageChannel.finishReceiving()
                self.stop()
            } else {
                self.setupReceiver()
            }
        }
    }

    private func observeIncomingMessages() {
        // Dispatch is centralized in `RuntimeMessageChannel.beginDispatch`:
        // responses route inline (no nested-round-trip deadlock), fire-and-forget
        // handlers run in order, response-producing handlers run concurrently,
        // and unknown-handler / handler-throw replies surface as errors instead
        // of hanging the caller.
        messageChannel.beginDispatch { [weak self] data in
            guard let self else { throw RuntimeMessageChannelError.notConnected }
            try await self.sendRaw(data: data)
        }
    }

    // MARK: - RuntimeUnderlyingConnection

    func send(requestData: RuntimeRequestData) async throws {
        let data = try JSONEncoder().encode(requestData)
        try await messageChannel.send(data: data) { [weak self] dataToSend in
            guard let self else { throw RuntimeMessageChannelError.notConnected }
            try await self.sendRaw(data: dataToSend)
        }
        #log(.debug, "Sent request: \(requestData.identifier, privacy: .public)")
    }

    func send<Response: Codable>(requestData: RuntimeRequestData, timeout: TimeInterval?) async throws -> Response {
        try await messageChannel.sendRequest(requestData: requestData, timeout: timeout) { [weak self] data in
            guard let self else { throw RuntimeMessageChannelError.notConnected }
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

#endif

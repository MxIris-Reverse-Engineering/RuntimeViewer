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
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .responsiveData

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

    /// This process's IPv4 address on the path this connection actually took.
    ///
    /// Read off the live path rather than derived from the machine's interface
    /// list, which is the point — see `RuntimeConnection.localAddressSeenByPeer`.
    ///
    /// IPv4 only, because the socket transport the answer feeds is `AF_INET`.
    /// Answering with an IPv6 address would produce a rendezvous the payload
    /// cannot dial, which is worse than answering nothing: the caller handles
    /// `nil` by saying so, and would handle an unusable address by timing out.
    var localAddressSeenByPeer: RuntimeLocalAddressReachability {
        guard let path = connection.currentPath else {
            return .unknown(reason: "that connection reports no network path yet, which usually means it has only just come up or has already dropped")
        }
        guard let localEndpoint = path.localEndpoint else {
            return .unknown(reason: "that connection's network path names no local endpoint")
        }
        guard case .hostPort(let host, _) = localEndpoint else {
            return .unknown(reason: "that connection's local endpoint is not an address and port but \(localEndpoint)")
        }

        switch host {
        case .ipv4(let address):
            // `IPv4Address.debugDescription` is the dotted quad. Its
            // `CustomDebugStringConvertible` conformance is the documented way
            // to render one; there is no other accessor.
            return .reachableAt(address.debugDescription)

        case .ipv6(let address):
            // The ordinary case, not an edge one. Measured against a device on
            // a virtual network interface: Bonjour settles on IPv6 link-local,
            // while the injected payload's socket is `AF_INET`.
            //
            // The address itself is unusable twice over — the payload dials
            // IPv4, and a link-local address is scoped to *this* machine's
            // interface index, which means nothing in the device's own
            // numbering. What survives is the interface, and that is the part
            // worth keeping: it was observed on the live path rather than
            // picked out of this machine's interface list.
            guard let interface = address.interface else {
                return .unknown(reason: "that connection runs over \(host), which names no interface to find an IPv4 address on")
            }
            guard let ipv4Address = RuntimeInterfaceAddresses.ipv4Address(ofInterfaceNamed: interface.name) else {
                return .unknown(reason: "that connection runs over \(interface.name), and that interface has no IPv4 address for an injected payload to dial")
            }
            return .reachableAt(ipv4Address)

        default:
            return .unknown(reason: "that connection's local endpoint is \(host), which is neither an IPv4 nor an IPv6 address")
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
                return
            }

            // Consume any delivered bytes BEFORE acting on `isComplete`.
            // NWConnection coalesces the peer's final chunk with the FIN, so the
            // closing callback can carry both `data` and `isComplete == true`.
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
        // Centralized dispatch (see `RuntimeMessageChannel.beginDispatch`).
        // Draining through the channel's stream from a cooperative-pool task —
        // instead of spawning a Task per message inside the NWConnection
        // receive callback — also keeps frame ordering and avoids piling Task
        // creation frames onto the dispatch-queue stack under a burst.
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

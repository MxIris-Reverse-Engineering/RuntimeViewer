#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

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
final class RuntimeNetworkServerConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

    private var _underlyingConnection: RuntimeNetworkConnection?

    private var listener: NWListener?
    private var connectionStateCancellable: AnyCancellable?
    private let serviceName: String
    private let listenerParameters: NWParameters

    /// Stable state subject that survives underlying connection replacement.
    /// Underlying states are filtered so the pre-ready handshake and listener
    /// restarts surface as a stable connecting → connected → disconnected sequence.
    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    private static let maxListenerRetries = 3
    private static let listenerRetryDelay: UInt64 = 2_000_000_000 // 2 seconds

    init(name: String) async throws {
        self.serviceName = name

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .responsiveData
        self.listenerParameters = parameters

        #log(.info, "Creating Bonjour server with name: \(name, privacy: .public), service type: \(RuntimeNetworkBonjour.type, privacy: .public)")

        try await startListeningWithRetry()
    }

    /// Attempts to start listening with automatic retries when the NWListener
    /// remains in `.waiting` state (e.g. during the local network permission prompt).
    /// After the user grants permission, a retried listener should enter `.ready` immediately.
    private func startListeningWithRetry() async throws {
        var lastError: Error = RuntimeConnectionError.listenerWaiting
        for attempt in 0..<Self.maxListenerRetries {
            let newListener = try NWListener(using: listenerParameters)
            newListener.service = await RuntimeNetworkBonjour.makeService(name: serviceName)
            self.listener = newListener

            if attempt > 0 {
                #log(.info, "Retrying Bonjour listener (attempt \(attempt + 1)/\(Self.maxListenerRetries, privacy: .public))...")
            } else {
                #log(.info, "Waiting for incoming Bonjour connection...")
            }

            do {
                try await waitForConnection(listener: newListener)
                #log(.info, "Bonjour server connection established for name: \(self.serviceName, privacy: .public)")
                return
            } catch let error as RuntimeConnectionError where error == .listenerWaiting {
                #log(.info, "Bonjour listener timed out in waiting state, will retry...")
                newListener.cancel()
                self.listener = nil
                lastError = error
                if attempt < Self.maxListenerRetries - 1 {
                    try await Task.sleep(nanoseconds: Self.listenerRetryDelay)
                }
            }
        }
        throw lastError
    }

    private func waitForConnection(listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in

            let didResume = Mutex<Bool>(false)
            // Guard against multiple NWConnections from different network paths
            // (IPv6 link-local, IPv4, AWDL) — only the first one should be accepted.
            let hasAccepted = Mutex<Bool>(false)

            // Track whether a .waiting timeout has been scheduled to avoid duplicates.
            let waitingTimeoutScheduled = Mutex<Bool>(false)

            listener.stateUpdateHandler = { state in
                #log(.info, "Bonjour listener state: \(String(describing: state), privacy: .public)")
                switch state {
                case .waiting(let error):
                    // On iOS, .waiting occurs when the local network permission prompt is shown.
                    // After the user grants permission, the listener should transition to .ready.
                    // If it doesn't recover within the timeout, we cancel and retry with a new listener.
                    #log(.info, "Bonjour listener waiting (may require local network permission): \(error, privacy: .public)")
                    let shouldSchedule = waitingTimeoutScheduled.withLock { scheduled -> Bool in
                        guard !scheduled else { return false }
                        scheduled = true
                        return true
                    }
                    if shouldSchedule {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                            let shouldResume = didResume.withLock { val -> Bool in
                                guard !val else { return false }
                                val = true
                                return true
                            }
                            if shouldResume {
                                #log(.error, "Bonjour listener waiting timeout exceeded, cancelling for retry")
                                listener.cancel()
                                continuation.resume(throwing: RuntimeConnectionError.listenerWaiting)
                            }
                        }
                    }
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
                case .cancelled:
                    // If we already accepted a connection, this cancellation was self-initiated
                    // (we call listener.cancel() in newConnectionHandler). In that case, let the
                    // connection state monitoring handle the continuation — do NOT resume with error.
                    let alreadyAccepted = hasAccepted.withLock { $0 }
                    guard !alreadyAccepted else {
                        #log(.info, "Bonjour listener cancelled after accepting connection (expected)")
                        break
                    }
                    // Prevent hung continuation if the listener is cancelled externally
                    let shouldResume = didResume.withLock { val -> Bool in
                        guard !val else { return false }
                        val = true
                        return true
                    }
                    if shouldResume {
                        #log(.error, "Bonjour listener cancelled unexpectedly")
                        continuation.resume(throwing: RuntimeConnectionError.networkError("Listener cancelled"))
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
                    self._underlyingConnection = connection

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
                                    self?.stateSubject.send(.connected)
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
                                    self?.stateSubject.send(state)
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
        stateSubject.send(.connecting)

        let newListener = try NWListener(using: listenerParameters)
        newListener.service = await RuntimeNetworkBonjour.makeService(name: serviceName)
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
                self._underlyingConnection = connection

                self.connectionStateCancellable = connection.statePublisher
                    .sink { [weak self] state in
                        #log(.info, "Bonjour reconnected connection state: \(String(describing: state), privacy: .public)")
                        if state.isConnected {
                            self?.stateSubject.send(.connected)
                        } else if state.isDisconnected {
                            #log(.info, "Bonjour reconnected connection disconnected, restarting listener...")
                            self?.stateSubject.send(state)
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

    func stop() {
        #log(.info, "Stopping Bonjour server connection")
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        _underlyingConnection?.stop()
        listener?.cancel()
        listener = nil
        stateSubject.send(.disconnected(error: nil))
    }
}

#endif

#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

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
final class RuntimeDirectTCPServerConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

    private var _underlyingConnection: RuntimeDirectTCPConnection?

    private var listener: NWListener?
    private var connectionStateCancellable: AnyCancellable?
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

    /// The host address the server is listening on.
    private(set) var host: String = ""

    /// The port the server is listening on (available after initialization).
    private(set) var port: UInt16 = 0

    var connectionInfo: RuntimeConnectionInfo? {
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
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .responsiveData
        self.listenerParameters = parameters

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
                self._underlyingConnection = tcpConnection

                // Observe connection state
                self.connectionStateCancellable = tcpConnection.statePublisher
                    .sink { [weak self] state in
                        #log(.info, "Direct TCP connection state: \(String(describing: state), privacy: .public)")
                        if state.isConnected {
                            #log(.info, "Direct TCP client connected")
                            self?.stateSubject.send(.connected)
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
        stateSubject.send(.connecting)

        // Re-bind the SAME port the client already knows. If the port was never
        // assigned (listener never reached `.ready`), there's nothing to restart
        // on — re-binding port 0 would silently move to a new random port and
        // strand the client's saved address, so bail instead.
        guard self.port != 0, let restartPort = NWEndpoint.Port(rawValue: self.port) else {
            #log(.error, "Cannot restart direct TCP listener: no assigned port")
            stateSubject.send(.disconnected(error: .networkError("Listener has no assigned port to restart on")))
            return
        }

        let newListener = try NWListener(using: listenerParameters, on: restartPort)
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
            self._underlyingConnection = tcpConnection

            self.connectionStateCancellable = tcpConnection.statePublisher
                .sink { [weak self] state in
                    #log(.info, "Direct TCP reconnected connection state: \(String(describing: state), privacy: .public)")
                    if state.isConnected {
                        self?.stateSubject.send(.connected)
                    } else if state.isDisconnected {
                        #log(.info, "Direct TCP reconnected connection disconnected, restarting listener...")
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
    func stop() {
        #log(.info, "Stopping direct TCP server on \(self.host, privacy: .public):\(self.port, privacy: .public)")
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        _underlyingConnection?.stop()
        listener?.cancel()
        listener = nil
        stateSubject.send(.disconnected(error: nil))
    }

    deinit {
        stop()
    }

    /// Gets the local IPv4 address other devices can reach this server on.
    ///
    /// Prefers the primary Wi-Fi/Ethernet interfaces (`en0`/`en1`) but falls
    /// back to any other up, non-loopback IPv4 interface — USB/Thunderbolt
    /// bridges, tethering, and VPNs all surface under different names (`en2+`,
    /// `bridge0`, `utun*`, …), and without the fallback the server would report
    /// `127.0.0.1` and a scanned/typed connection from another device fails.
    private static func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var preferredAddress: String?
        var fallbackAddress: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            // Skip interfaces that are down or are the loopback.
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            let address = String(cString: hostname)

            if name == "en0" || name == "en1" {
                preferredAddress = address
                break
            } else if fallbackAddress == nil {
                fallbackAddress = address
            }
        }

        return preferredAddress ?? fallbackAddress
    }
}

#endif

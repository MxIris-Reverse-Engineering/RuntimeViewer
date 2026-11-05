#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

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
final class RuntimeDirectTCPClientConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

    private var _underlyingConnection: RuntimeDirectTCPConnection?

    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    /// Bridges underlying connection state into `stateSubject`; kept alive for
    /// the connection's lifetime (not cancelled in `stop()`) so subscribers
    /// still observe the final `.disconnected` emitted while stopping.
    private var underlyingStateCancellable: AnyCancellable?

    private var connectionStateCancellable: AnyCancellable?

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    /// Creates a client connection to the specified host and port.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the server.
    ///   - port: The port number the server is listening on.
    ///   - timeout: Maximum time to wait for connection (default: 10 seconds).
    init(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        #log(.info, "Connecting to direct TCP server at \(host, privacy: .public):\(port, privacy: .public) (timeout: \(timeout, privacy: .public)s)")

        let connection = RuntimeDirectTCPConnection(host: host, port: port)
        self._underlyingConnection = connection
        self.underlyingStateCancellable = connection.statePublisher
            .sink { [weak self] connectionState in
                self?.stateSubject.send(connectionState)
            }

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

    func stop() {
        connectionStateCancellable?.cancel()
        connectionStateCancellable = nil
        _underlyingConnection?.stop()
    }
}

#endif

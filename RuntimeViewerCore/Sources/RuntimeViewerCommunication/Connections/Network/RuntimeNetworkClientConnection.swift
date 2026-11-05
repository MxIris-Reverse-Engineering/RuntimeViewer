#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

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
final class RuntimeNetworkClientConnection: RuntimeForwardingConnection, @unchecked Sendable {
    var underlyingConnection: (some RuntimeUnderlyingConnection)? { _underlyingConnection }

    private var _underlyingConnection: RuntimeNetworkConnection?

    private let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    /// Bridges underlying connection state into `stateSubject`; kept alive for
    /// the connection's lifetime so subscribers still observe the final
    /// `.disconnected` emitted while stopping.
    private var underlyingStateCancellable: AnyCancellable?

    var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    var state: RuntimeConnectionState {
        stateSubject.value
    }

    /// Forwarded from the transport: this is the one connection in the project
    /// that can answer, being the only one that crosses a route to a device.
    var localAddressSeenByPeer: RuntimeLocalAddressReachability {
        _underlyingConnection?.localAddressSeenByPeer
            ?? .unknown(reason: "that connection has no transport under it")
    }

    /// Creates a client connection to the specified network endpoint.
    ///
    /// - Parameter endpoint: The Bonjour-discovered endpoint to connect to.
    /// - Throws: `RuntimeNetworkError` if connection cannot be established.
    init(endpoint: RuntimeNetworkEndpoint) throws {
        let connection = try RuntimeNetworkConnection(endpoint: endpoint.endpoint)
        self._underlyingConnection = connection
        self.underlyingStateCancellable = connection.statePublisher
            .sink { [weak self] connectionState in
                self?.stateSubject.send(connectionState)
            }
    }
}

#endif

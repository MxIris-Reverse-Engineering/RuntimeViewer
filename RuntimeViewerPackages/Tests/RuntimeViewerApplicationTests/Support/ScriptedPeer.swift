#if canImport(Network)

import Foundation
import RuntimeViewerCommunication
@testable import RuntimeViewerCore

/// The far end of a TCP connection that serves only the commands a test
/// hands it — every other request is answered "No handler registered for …"
/// — and the client engine connected to it. A test holds a request in flight
/// with it for as long as it likes, or drops the connection under one.
struct ScriptedPeer {
    let connection: any RuntimeConnection
    let client: RuntimeEngine

    static func make(label: String) async throws -> ScriptedPeer {
        let connection = try await RuntimeCommunicator().connect(
            to: .directTCP(name: "\(label).peer", host: nil, port: 0, role: .server),
            waitForConnection: false
        )
        guard let port = connection.connectionInfo?.port else {
            throw ScriptedPeerUnavailable(label: label, reason: "the peer was given no port")
        }
        let client = RuntimeEngine(
            source: .directTCP(name: "\(label).client", host: "127.0.0.1", port: port, role: .client),
            engineID: "\(label).client"
        )
        try await client.connect()
        // A TCP server has no connection to mount handlers on until its peer
        // has connected, and the client's `connect()` returns as soon as its
        // own socket is up.
        let deadline = ContinuousClock.now + .seconds(5)
        while !connection.state.isConnected {
            guard ContinuousClock.now < deadline else {
                throw ScriptedPeerUnavailable(label: label, reason: "the client never reached the peer")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return ScriptedPeer(connection: connection, client: client)
    }

    /// Answers every `command` request with what `handler` returns, whatever
    /// the request says.
    func serve<Response: Codable>(_ command: RuntimeEngine.CommandName, with handler: @escaping @Sendable () async throws -> Response) {
        connection.setMessageHandler(name: command.commandName) { (_: IgnoredRequest) async throws -> Response in
            try await handler()
        }
    }

    func stop() async {
        await client.stop()
        connection.stop()
    }

    /// Any request; what it says is not read.
    private struct IgnoredRequest: Codable {}
}

struct ScriptedPeerUnavailable: Swift.Error, CustomStringConvertible {
    let label: String
    let reason: String

    var description: String { "\(label): \(reason)" }
}

/// Requests a peer holds instead of answering, until the test lets them go.
actor HeldRequests {
    private(set) var arrivedCount = 0

    private var isReleased = false

    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once `release()` is called, at once after it.
    func hold() async {
        arrivedCount += 1
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

#endif

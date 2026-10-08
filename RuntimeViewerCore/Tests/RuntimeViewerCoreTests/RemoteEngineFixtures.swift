#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// A client engine and the engine it forwards to, joined by a real
/// connection, both in this process: what a request crosses on its way from
/// the app to the process that owns the images.
///
/// Two transports, because they deliver messages differently. Over XPC every
/// message — a push, a cancellation — is a round trip handled in a task of its
/// own. Over a socket a message without a reply runs on the receiving
/// channel's ordered handler tail while each request runs in a task of its
/// own, and a reply waits for the pushes sent before it.
struct RemoteEnginePair: Sendable {
    enum Transport: String, CaseIterable, Sendable, CustomStringConvertible {
        /// The app's "My Mac": a `.local` engine forwarding to the embedded
        /// local-runtime service, here an anonymous listener.
        case xpcService
        /// A mirrored engine or an injected app: a client engine over a TCP
        /// connection to a peer serving the shared command table.
        case socket

        var description: String { rawValue }
    }

    let client: RuntimeEngine

    let serving: RuntimeEngine

    /// The connection the serving side answers on, for a test that replaces
    /// one of its handlers.
    let servingConnection: any RuntimeConnection

    private let stopConnection: @Sendable () async -> Void

    /// An in-process engine to serve from, with `imagePaths` loaded. Indexing
    /// a framework the size of Foundation takes seconds of every core, so a
    /// suite makes one and serves it to each pair it connects.
    static func makeServingEngine(label: String, loading imagePaths: [String]) async throws -> RuntimeEngine {
        let serving = RuntimeEngine(source: .local, engineID: "\(label).serving")
        try await serving.connect()
        for imagePath in imagePaths {
            try await serving.loadImage(at: imagePath)
        }
        return serving
    }

    /// Connects a client to `serving` over `transport`. The pair owns the
    /// client and the connection, not `serving`. `configureServing` runs once
    /// the serving side's command table is installed and before the client
    /// sends anything, so a handler it sets replaces the table's.
    static func make(
        _ transport: Transport,
        label: String,
        serving: RuntimeEngine,
        configureServing: (@Sendable (any RuntimeConnection) -> Void)? = nil
    ) async throws -> RemoteEnginePair {
        switch transport {
        case .xpcService:
            let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
            let host = RuntimeLocalRuntimeServiceHost(engine: serving, connection: listener)
            try await host.start()
            // SwiftyXPC copies a listener's handlers onto each connection it
            // accepts, so a replacement has to precede the activation.
            configureServing?(listener)
            host.activate()
            let client = RuntimeEngine(source: .local, engineID: "\(label).client")
            try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
            // Kept for the pair's life: it holds the push relays. Never
            // touched from another task, only released.
            nonisolated(unsafe) let retainedHost = host
            return RemoteEnginePair(client: client, serving: serving, servingConnection: listener) {
                await client.stop()
                // Not `host.stop()`, which stops the engine it serves.
                withExtendedLifetime(retainedHost) {
                    listener.stop()
                }
            }
        case .socket:
            let servingConnection = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
            let client = RuntimeEngine(
                source: .directTCP(name: "\(label).client", host: "127.0.0.1", port: servingConnection.port, role: .client),
                engineID: "\(label).client"
            )
            // The TCP server has no connection to mount handlers on until a
            // peer connects, and the client's connect returns as soon as the
            // socket is up.
            try await client.connect()
            try await waitUntilConnected(servingConnection)
            RuntimeEngine.registerSharedHandlers(on: servingConnection, engine: serving)
            configureServing?(servingConnection)
            return RemoteEnginePair(client: client, serving: serving, servingConnection: servingConnection) {
                await client.stop()
                servingConnection.stop()
            }
        }
    }

    func stop() async {
        await stopConnection()
    }

    /// Spins until `connection` reports `.connected`, failing past the deadline.
    private static func waitUntilConnected(_ connection: some RuntimeConnection, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while connection.state != .connected {
            guard ContinuousClock.now < deadline else { throw RemoteEngineFixtureTimeout(what: "the serving connection") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Support

struct RemoteEngineFixtureTimeout: Swift.Error, CustomStringConvertible {
    let what: String

    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` until it holds or `timeout` passes; returns whether it held.
func waitForCondition(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Counts events from any task and remembers whether they started after a
/// moment the test marks.
final class MarkedEventCounter: @unchecked Sendable {
    private let lock = NSLock()

    private var eventCount = 0

    private var eventCountAfterMark = 0

    private var isMarked = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCount
    }

    var countAfterMark: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCountAfterMark
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        eventCount += 1
        if isMarked {
            eventCountAfterMark += 1
        }
    }

    /// From now on every event counts as one after the mark.
    func mark() {
        lock.lock()
        defer { lock.unlock() }
        isMarked = true
    }
}

#endif

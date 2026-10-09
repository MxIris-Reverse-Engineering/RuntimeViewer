#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// A peer older than a command, as a caller sees it.
///
/// Since 2.1.0 a peer answers a command it has no handler for with
/// "No handler registered for …", and nothing else, so that text is the one
/// way to tell "the peer predates this" from a failure of the work — whether
/// the caller reaches the old peer directly or through a relay of this build
/// that forwards to it (PR121.37).
@Suite("Remote unknown command", .serialized)
struct RemoteUnknownCommandTests {
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// Serves no command at all: what a peer older than the corpus commands
    /// is, as far as they go.
    private static func makeOlderPeer() async throws -> RuntimeDirectTCPServerConnection {
        try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
    }

    private static func makeClient(_ engineID: String, connectingTo port: UInt16) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .directTCP(name: engineID, host: "127.0.0.1", port: port, role: .client), engineID: engineID)
        try await engine.connect()
        return engine
    }

    @Test("A peer that predates a command answers in a way the caller recognises")
    func olderPeerIsRecognised() async throws {
        let olderPeer = try await Self.makeOlderPeer()
        let client = try await Self.makeClient("remote-unknown-command.direct", connectingTo: olderPeer.port)
        defer { Task { await client.stop(); olderPeer.stop() } }

        let error = await #expect(throws: RuntimeNetworkRequestError.self) {
            _ = try await client.buildInterfaceCorpus(for: Self.libobjcPath, transformer: .default)
        }
        #expect(error?.isUnknownCommand == true, "the caller got \(String(describing: error))")
    }

    @Test("Through a relay of this build, a peer that predates a command is still recognised")
    func olderPeerIsRecognisedThroughRelay() async throws {
        let olderPeer = try await Self.makeOlderPeer()
        let relayEngine = try await Self.makeClient("remote-unknown-command.relay", connectingTo: olderPeer.port)
        let relayConnection = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let connectingClient = Task {
            try await Self.makeClient("remote-unknown-command.behind-relay", connectingTo: relayConnection.port)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while relayConnection.state != .connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        RuntimeEngine.registerSharedHandlers(on: relayConnection, engine: relayEngine)
        let client = try await connectingClient.value
        defer { Task { await client.stop(); relayConnection.stop(); await relayEngine.stop(); olderPeer.stop() } }

        let error = await #expect(throws: RuntimeNetworkRequestError.self) {
            _ = try await client.buildInterfaceCorpus(for: Self.libobjcPath, transformer: .default)
        }
        #expect(error?.isUnknownCommand == true, "the caller behind the relay got \(String(describing: error))")
    }
}

#endif

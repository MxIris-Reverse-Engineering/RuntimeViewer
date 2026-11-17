import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// The local socket server's accept loop used to end at the first `accept`
/// that failed, leaving a server that listened on and never took a client
/// again: an injected process whose connection dropped could not dial back.
/// `accept` fails without the server being stopped when a signal interrupts it
/// (`EINTR`), when a client gives up before it is accepted (`ECONNABORTED`) and
/// when the process is out of descriptors (`EMFILE`). The codebase audit's CA.18.
@Suite("Local socket accept retry", .serialized)
struct RuntimeLocalSocketAcceptRetryTests {
    @Test("The server keeps accepting after an accept fails", arguments: [
        [ECONNABORTED],
        [EINTR],
        [EMFILE, ECONNABORTED],
    ])
    func serverKeepsAcceptingAfterFailedAccept(errorNumbers: [Int32]) async throws {
        let identifier = "test-accept-retry-\(UUID().uuidString)"
        let systemCalls = ScriptedSocketSystemCalls()
        systemCalls.failNextAccepts(with: errorNumbers)
        let server = RuntimeLocalSocketServerConnection(identifier: identifier, systemCalls: systemCalls)
        try await server.start()
        defer { server.stop() }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        defer { client.stop() }

        #expect(await Self.waitUntilConnected(server, timeout: 5), "The server never accepted the client after accept failed with \(errorNumbers).")
    }

    /// Stopping the server shuts its socket down, which fails the `accept`
    /// blocked in it with `ECONNABORTED` — the same error a retry is made for.
    /// The loop must tell the two apart and end instead of spinning.
    @Test("Stopping the server ends the accept loop")
    func stoppingServerEndsAcceptLoop() async throws {
        let identifier = "test-accept-stop-\(UUID().uuidString)"
        let systemCalls = ScriptedSocketSystemCalls()
        let server = RuntimeLocalSocketServerConnection(identifier: identifier, systemCalls: systemCalls)
        try await server.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        server.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let acceptCallsAfterStopping = systemCalls.acceptCalls
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(systemCalls.acceptCalls == acceptCallsAfterStopping, "The accept loop kept calling accept after the server stopped.")
    }

    private static func waitUntilConnected(_ server: RuntimeLocalSocketServerConnection, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if server.state == .connected { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return server.state == .connected
    }
}

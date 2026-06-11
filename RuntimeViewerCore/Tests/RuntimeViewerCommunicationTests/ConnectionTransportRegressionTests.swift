import Testing
import Foundation
@testable import RuntimeViewerCommunication

// MARK: - Test Support

/// Races `operation` against a wall-clock deadline WITHOUT awaiting the loser.
///
/// `withThrowingTaskGroup` is unusable here: its implicit await-all at scope
/// exit would block on a deadlocked / nil-timeout `sendMessage` (which is not
/// cancellation-aware), defeating the watchdog. Instead we resume a single
/// continuation from whichever of the two unstructured tasks finishes first
/// and let the loser leak — fine for a test process.
private struct TransportTimeoutError: Error {}

private final class ResumeOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

private func withTransportTimeout<T: Sendable>(
    _ seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let flag = ResumeOnceFlag()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        Task {
            do {
                let value = try await operation()
                if flag.tryResume() { continuation.resume(returning: value) }
            } catch {
                if flag.tryResume() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if flag.tryResume() { continuation.resume(throwing: TransportTimeoutError()) }
        }
    }
}

private enum TransportTestError: Error {
    case marked(String)
}

/// Spins until the server reports `.connected` or the deadline passes.
private func waitUntilConnected(_ connection: some RuntimeConnection, timeout: TimeInterval = 2.0) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while connection.state != .connected, Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: - #2 Head-of-line blocking / nested round-trip deadlock

/// The receive dispatch loop processes one message at a time with an inline
/// `await handler.closure(...)`. A handler that itself awaits a response over
/// the SAME connection can never observe that response: the loop is parked in
/// the handler and never reaches `deliverToPendingRequest` for the reply.
@Suite("Transport Regression: dispatch-loop deadlock", .serialized)
struct TransportDispatchDeadlockTests {

    @Test("LocalSocket: nested round-trip inside a handler does not deadlock")
    func testLocalSocketNestedRoundTripNoDeadlock() async throws {
        let identifier = "test-nested-deadlock-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // While handling "outer", the server calls back to the client and
        // awaits the "inner" response over the same connection.
        server.setMessageHandler(name: "outer") { [weak server] (_: String) -> String in
            guard let server else { return "no-server" }
            let inner: String = try await server.sendMessage(name: "inner", request: "ping")
            return "outer(\(inner))"
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        client.setMessageHandler(name: "inner") { (_: String) -> String in
            return "pong"
        }

        try await waitUntilConnected(server)

        let result = try await withTransportTimeout(4.0) {
            let response: String = try await client.sendMessage(name: "outer", request: "go")
            return response
        }
        #expect(result == "outer(pong)")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    @Test("Stdio: nested round-trip inside a handler does not deadlock")
    func testStdioNestedRoundTripNoDeadlock() async throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()

        let server = try RuntimeStdioServerConnection(
            inputHandle: clientToServer.fileHandleForReading,
            outputHandle: serverToClient.fileHandleForWriting
        )
        let client = try RuntimeStdioClientConnection(
            inputHandle: serverToClient.fileHandleForReading,
            outputHandle: clientToServer.fileHandleForWriting
        )

        defer {
            server.stop()
            client.stop()
            try? clientToServer.fileHandleForWriting.close()
            try? serverToClient.fileHandleForWriting.close()
        }

        server.setMessageHandler(name: "outer") { [weak server] (_: String) -> String in
            guard let server else { return "no-server" }
            let inner: String = try await server.sendMessage(name: "inner", request: "ping")
            return "outer(\(inner))"
        }
        client.setMessageHandler(name: "inner") { (_: String) -> String in
            return "pong"
        }

        let result = try await withTransportTimeout(4.0) {
            let response: String = try await client.sendMessage(name: "outer", request: "go")
            return response
        }
        #expect(result == "outer(pong)")
    }

    /// Even without nesting, a slow handler must not delay an unrelated fast
    /// request that arrives behind it. With a strictly serial dispatch loop the
    /// fast request waits out the slow handler.
    @Test("LocalSocket: a slow handler does not stall a fast request behind it")
    func testLocalSocketSlowHandlerDoesNotStallFastRequest() async throws {
        let identifier = "test-hol-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(name: "slow") { (_: String) -> String in
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return "slow-done"
        }
        server.setMessageHandler(name: "fast") { (_: String) -> String in
            return "fast-done"
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        try await waitUntilConnected(server)

        // Fire the slow request, then the fast one right after.
        async let slow: String = client.sendMessage(name: "slow", request: "x")
        try await Task.sleep(nanoseconds: 100_000_000)

        let fastStart = Date()
        let fast: String = try await withTransportTimeout(1.0) {
            try await client.sendMessage(name: "fast", request: "y")
        }
        let fastElapsed = Date().timeIntervalSince(fastStart)

        #expect(fast == "fast-done")
        #expect(fastElapsed < 0.8, "fast request waited \(fastElapsed)s behind the slow handler — dispatch loop is head-of-line blocked")

        _ = try? await slow
        serverTask.cancel()
        client.stop()
        server.stop()
    }
}

// MARK: - #3 Unknown handler must not hang the caller

/// A request for a command with no registered handler is currently dropped
/// silently. Combined with the default `nil` timeout the caller waits forever.
@Suite("Transport Regression: unknown handler", .serialized)
struct TransportUnknownHandlerTests {

    @Test("LocalSocket: request to an unregistered handler fails fast instead of hanging")
    func testLocalSocketUnknownHandlerDoesNotHang() async throws {
        let identifier = "test-unknown-handler-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        // Intentionally register NO handler for "ghost".

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        try await waitUntilConnected(server)

        let start = Date()
        do {
            // No explicit timeout — relies on the server replying with an error
            // for the unknown command. If it silently drops, this hangs and the
            // watchdog converts it into a TransportTimeoutError.
            let _: String = try await withTransportTimeout(3.0) {
                try await client.sendMessage(name: "ghost", request: "x")
            }
            Issue.record("expected an error for an unknown handler, got a value")
        } catch is TransportTimeoutError {
            Issue.record("request to unknown handler hung — server silently dropped it")
        } catch {
            // Expected: the server replied with an error envelope, surfaced here.
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.5, "unknown-handler request took \(elapsed)s — should fail fast")

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}

// MARK: - #6 Handler errors must surface, not decode-fail

/// When a server handler throws, the failure is wrapped in
/// `RuntimeNetworkRequestError` and shipped in the response envelope's `data`.
/// The caller must surface that error message rather than blindly decoding the
/// payload as `Response` (which yields an opaque `DecodingError`, or — worse —
/// a bogus "success" if `Response` has all-optional fields).
@Suite("Transport Regression: handler error propagation", .serialized)
struct TransportHandlerErrorTests {

    @Test("LocalSocket: a throwing handler surfaces its message to the caller")
    func testLocalSocketHandlerErrorSurfaces() async throws {
        let identifier = "test-handler-error-\(UUID().uuidString)"
        let marker = "MARKER-\(UUID().uuidString.prefix(8))"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        server.setMessageHandler(name: "boom") { (_: String) -> String in
            throw TransportTestError.marked(String(marker))
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        try await waitUntilConnected(server)

        do {
            let _: String = try await withTransportTimeout(3.0) {
                try await client.sendMessage(name: "boom", request: "x")
            }
            Issue.record("expected the handler error to propagate")
        } catch is TransportTimeoutError {
            Issue.record("handler-error request hung")
        } catch {
            let description = "\(error)"
            #expect(
                description.contains(String(marker)),
                "caller received an opaque error that loses the handler's message: \(description)"
            )
        }

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}

// MARK: - Ordering guard for fire-and-forget pushes

/// The dispatch fix runs response-producing handlers concurrently but keeps
/// fire-and-forget handlers on a serial queue, because state-sync pushes
/// (`imageList` → `imageNodes` → `dataDidChange`) must be applied in send order.
/// This pins that ordering guarantee so a future "just spawn a Task per message"
/// simplification can't silently reintroduce reordering.
@Suite("Transport Regression: fire-and-forget ordering", .serialized)
struct TransportOrderingTests {

    private actor OrderRecorder {
        private(set) var values: [Int] = []
        func record(_ value: Int) { values.append(value) }
    }

    @Test("LocalSocket: fire-and-forget pushes are handled in send order")
    func testFireAndForgetOrdering() async throws {
        let identifier = "test-ordering-\(UUID().uuidString)"
        let pushCount = 300

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let recorder = OrderRecorder()
        client.setMessageHandler(name: "tick") { (value: Int) in
            await recorder.record(value)
        }
        try await waitUntilConnected(server)

        for index in 0 ..< pushCount {
            try await server.sendMessage(name: "tick", request: index)
        }

        // Allow the serial handler tail to drain.
        let deadline = Date().addingTimeInterval(3.0)
        while await recorder.values.count < pushCount, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let received = await recorder.values
        #expect(received.count == pushCount, "expected \(pushCount) pushes, got \(received.count)")
        #expect(received == Array(0 ..< pushCount), "fire-and-forget pushes were reordered")

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}

// MARK: - #1 NWConnection final-chunk-with-FIN must not be dropped

/// `NWConnection.receive` can deliver the last bytes together with
/// `isComplete == true` when the peer's data and FIN coalesce. If the receive
/// callback checks `isComplete` before consuming `data`, that trailing message
/// is dropped.
///
/// To target the *client-side* drop deterministically (rather than racing a
/// server-side premature close), the server pushes a message, **awaits the
/// send completing** so the bytes are handed to TCP, and only then closes — so
/// the data and FIN reliably coalesce in one client receive callback.
@Suite("Transport Regression: NWConnection trailing chunk", .serialized)
struct TransportTrailingChunkTests {

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    @Test("DirectTCP: a message flushed right before close is still delivered")
    func testDirectTCPTrailingMessageNotDropped() async throws {
        #if canImport(Network)
        var drops = 0
        let trials = 12

        for _ in 0 ..< trials {
            let server = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
            let port = server.port
            #expect(port > 0)

            let client = try await RuntimeDirectTCPClientConnection(host: "127.0.0.1", port: port)
            let gotTail = Flag()
            client.setMessageHandler(name: "tail") { (_: String) in
                await gotTail.set()
            }

            // The DirectTCP server only has an `underlyingConnection` to mount
            // handlers on once a client is connected — register after that, the
            // way `RuntimeEngineProxyServer` does on its `.connected` callback.
            try await waitUntilConnected(server)

            // On "go", push "tail" (awaiting the flush) then immediately close.
            server.setMessageHandler(name: "go") { [weak server] (_: String) in
                guard let server else { return }
                try? await server.sendMessage(name: "tail", request: "payload")
                server.stop()
            }

            try await client.sendMessage(name: "go", request: "")

            // Wait for the trailing push to arrive or the trial to time out.
            let deadline = Date().addingTimeInterval(1.5)
            while await !gotTail.isSet, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if await !gotTail.isSet {
                drops += 1
            }

            client.stop()
            server.stop()
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        #expect(drops == 0, "\(drops)/\(trials) trailing messages were dropped (coalesced data+FIN bug)")
        #endif
    }
}

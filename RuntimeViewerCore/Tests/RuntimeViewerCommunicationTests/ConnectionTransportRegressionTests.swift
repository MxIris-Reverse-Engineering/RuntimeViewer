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

// MARK: - Pushes sent before a reply are handled before the request returns

/// A serving peer writes every push a request produces — progress, search
/// results — before it writes the reply. The receiving channel runs pushes on
/// its serial fire-and-forget tail but used to hand the reply to the waiting
/// request inline, so the request returned while pushes sent ahead of it were
/// still queued; the engine then removed the request's progress route and
/// those pushes were dropped. Over XPC every push is a round trip, so there a
/// reply can never overtake the pushes before it.
@Suite("Transport Regression: pushes sent before a reply", .serialized)
struct TransportReplyOrderingTests {

    private actor HandledValues {
        private(set) var values: [Int] = []
        func record(_ value: Int) { values.append(value) }
    }

    @Test("LocalSocket: pushes sent before a reply are handled before the request returns")
    func testPushesAreHandledBeforeTheReplyReturns() async throws {
        let identifier = "test-reply-barrier-\(UUID().uuidString)"
        let pushCount = 5

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.setMessageHandler(name: "work") { [weak server] (count: Int) -> Int in
            guard let server else { return 0 }
            for index in 0 ..< count {
                try await server.sendMessage(name: "tick", request: index)
            }
            return count
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let handledValues = HandledValues()
        client.setMessageHandler(name: "tick") { (value: Int) in
            // A consumer slower than the wire, like a Find window applying a batch.
            try await Task.sleep(nanoseconds: 20_000_000)
            await handledValues.record(value)
        }
        try await waitUntilConnected(server)

        let returned: Int = try await withTransportTimeout(5.0) {
            try await client.sendMessage(name: "work", request: pushCount)
        }
        let handled = await handledValues.values
        #expect(returned == pushCount)
        #expect(handled == Array(0 ..< pushCount), "the reply overtook the pushes sent before it; handled \(handled)")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    @Test("LocalSocket: pushes sent before a failure reply are handled before the error surfaces")
    func testPushesAreHandledBeforeAFailureReplySurfaces() async throws {
        let identifier = "test-reply-barrier-failure-\(UUID().uuidString)"
        let pushCount = 5

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.setMessageHandler(name: "work") { [weak server] (count: Int) -> Int in
            guard let server else { return 0 }
            for index in 0 ..< count {
                try await server.sendMessage(name: "tick", request: index)
            }
            throw TransportTestError.marked("failed after its pushes")
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let handledValues = HandledValues()
        client.setMessageHandler(name: "tick") { (value: Int) in
            try await Task.sleep(nanoseconds: 20_000_000)
            await handledValues.record(value)
        }
        try await waitUntilConnected(server)

        do {
            let _: Int = try await withTransportTimeout(5.0) {
                try await client.sendMessage(name: "work", request: pushCount)
            }
            Issue.record("expected the handler's failure to propagate")
        } catch is TransportTimeoutError {
            Issue.record("the failing request hung")
        } catch {
            // Expected: the server's failure, surfaced after the pushes.
        }
        let handled = await handledValues.values
        #expect(handled == Array(0 ..< pushCount), "the failure overtook the pushes sent before it; handled \(handled)")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    @Test("LocalSocket: a push handler that sends a request over the same connection still completes")
    func testPushHandlerRequestDoesNotDeadlockOnTheBarrier() async throws {
        let identifier = "test-reply-barrier-nested-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.setMessageHandler(name: "echo") { (value: Int) -> Int in value }
        server.setMessageHandler(name: "work") { [weak server] (value: Int) -> Int in
            guard let server else { return 0 }
            try await server.sendMessage(name: "tick", request: value)
            return value
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let handledValues = HandledValues()
        client.setMessageHandler(name: "tick") { [weak client] (value: Int) in
            guard let client else { return }
            // The reply to this request arrives while this very handler is
            // the tail; waiting for the tail here would wait for itself.
            let echoed: Int = try await client.sendMessage(name: "echo", request: value)
            await handledValues.record(echoed)
        }
        try await waitUntilConnected(server)

        let returned: Int = try await withTransportTimeout(4.0) {
            try await client.sendMessage(name: "work", request: 7)
        }
        #expect(returned == 7)
        #expect(await handledValues.values == [7])

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    @Test("LocalSocket: a push handler waiting on a task that sends a request over the same connection still completes")
    func testPushHandlerTaskRequestDoesNotDeadlockOnTheBarrier() async throws {
        let identifier = "test-reply-barrier-task-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.setMessageHandler(name: "echo") { (value: Int) -> Int in value }
        server.setMessageHandler(name: "work") { [weak server] (value: Int) -> Int in
            guard let server else { return 0 }
            try await server.sendMessage(name: "tick", request: value)
            return value
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        let handledValues = HandledValues()
        client.setMessageHandler(name: "tick") { [weak client] (value: Int) in
            guard let client else { return }
            // A task the handler starts and waits for: it inherits the
            // handler's task-local context, so its request skips the barrier
            // just like one sent from the handler itself.
            let echoTask = Task { () -> Int in
                try await client.sendMessage(name: "echo", request: value)
            }
            let echoed = try await echoTask.value
            await handledValues.record(echoed)
        }
        try await waitUntilConnected(server)

        let returned: Int = try await withTransportTimeout(4.0) {
            try await client.sendMessage(name: "work", request: 11)
        }
        #expect(returned == 11)
        #expect(await handledValues.values == [11])

        serverTask.cancel()
        client.stop()
        server.stop()
    }
}

// MARK: - A reply that arrives after its request gave up

/// A request that times out leaves the pending table, but its reply can still
/// arrive. A frame that matches no pending request used to be taken for a new
/// request: the requester, which has no handler for its own command, answered
/// with an error envelope under the same nonce; the serving peer has that
/// handler, took the envelope for a request and ran it again, and its reply
/// went the same way — the two peers echoed each other until the connection
/// closed. The Bonjour heartbeat's `engineList` request is one with a timeout,
/// and its handler decodes an empty payload, which an error envelope decodes
/// as just as well.
@Suite("Transport Regression: reply after timeout", .serialized)
struct TransportLateReplyTests {

    private struct EmptyRequest: Codable {}

    private actor InvocationCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private actor WrittenFrames {
        private(set) var frames: [Data] = []
        func record(_ frame: Data) { frames.append(frame) }
    }

    @Test("LocalSocket: a reply that arrives after its request timed out is dropped, not answered")
    func testLateReplyIsNotAnswered() async throws {
        let identifier = "test-late-reply-\(UUID().uuidString)"

        let server = RuntimeLocalSocketServerConnection(identifier: identifier)
        let serverTask = Task { try await server.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let invocations = InvocationCounter()
        server.setMessageHandler(name: "slow") { (_: EmptyRequest) -> Int in
            await invocations.increment()
            try await Task.sleep(nanoseconds: 300_000_000)
            return 1
        }

        let client = try await RuntimeLocalSocketClientConnection(identifier: identifier, timeout: 5)
        try await waitUntilConnected(server)

        await #expect(throws: RuntimeMessageChannelError.requestTimeout) {
            let _: Int = try await client.sendMessage(name: "slow", request: EmptyRequest(), timeout: 0.1)
        }
        // Long enough for the late reply to arrive and for several rounds of an echo loop.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let invocationCount = await invocations.count
        #expect(invocationCount == 1, "the late reply was answered, and the server ran its handler \(invocationCount) times")

        serverTask.cancel()
        client.stop()
        server.stop()
    }

    /// What a peer built before the late-reply rule still does with a late
    /// reply of ours: it answers it once, with an error envelope. That
    /// envelope must end the exchange here instead of being run as a request.
    @Test("An error envelope that matches no pending request is never handed to a handler")
    func testUnmatchedErrorEnvelopeIsNotHandled() async throws {
        let channel = RuntimeMessageChannel()
        let invocations = InvocationCounter()
        channel.setMessageHandler(name: "slow") { (_: EmptyRequest) -> Int in
            await invocations.increment()
            return 1
        }
        let writtenFrames = WrittenFrames()
        channel.beginDispatch { frame in
            await writtenFrames.record(frame)
        }

        let errorPayload = try JSONEncoder().encode(RuntimeNetworkRequestError(message: "No handler registered for slow"))
        let errorEnvelope = RuntimeRequestData(identifier: "slow", data: errorPayload, nonce: UUID().uuidString, isError: true)
        channel.appendReceivedData(try JSONEncoder().encode(errorEnvelope) + RuntimeMessageChannel.endMarkerData)

        // Give the dispatch loop, and a handler it might wrongly start, time to run.
        try await Task.sleep(nanoseconds: 300_000_000)

        let invocationCount = await invocations.count
        let writtenFrameCount = await writtenFrames.frames.count
        #expect(invocationCount == 0, "an error envelope was run as a request")
        #expect(writtenFrameCount == 0, "an error envelope was answered")
        channel.finishReceiving()
    }
}

import Foundation
import FoundationToolbox
import Semaphore
import Asynchrone

// MARK: - RuntimeMessageHandler

/// Encapsulates a message handler that processes requests and returns responses.
///
/// This class handles the JSON encoding/decoding of requests and responses,
/// allowing handlers to work with typed Swift objects.
///
/// - Note: Uses `@unchecked Sendable` because the stored metatypes (`requestType`, `responseType`)
///   are immutable and inherently thread-safe, but `any Codable.Type` doesn't conform to `Sendable`.
final class RuntimeMessageHandler: @unchecked Sendable {
    typealias RawHandler = @Sendable (Data) async throws -> Data

    /// The wrapped handler that processes raw Data.
    let closure: RawHandler

    /// The type of the request this handler expects.
    let requestType: any Codable.Type

    /// The type of the response this handler returns.
    let responseType: any Codable.Type

    /// Creates a message handler with typed request and response.
    ///
    /// - Parameter closure: The handler closure that receives a typed request
    ///   and returns a typed response.
    init<Request: Codable, Response: Codable>(closure: @escaping @Sendable (Request) async throws -> Response) {
        self.requestType = Request.self
        self.responseType = Response.self

        self.closure = { request in
            let request = try JSONDecoder().decode(Request.self, from: request)
            let response = try await closure(request)
            return try JSONEncoder().encode(response)
        }
    }
}

// MARK: - RuntimeMessageNull

/// A null message type used when no payload is needed.
struct RuntimeMessageNull: Codable, Sendable {
    static let null = RuntimeMessageNull()
}

// MARK: - RuntimeMessageProtocol

/// Protocol defining the message framing and processing logic.
///
/// Implementations handle the low-level details of reading/writing data,
/// while the protocol provides the common message framing logic.
protocol RuntimeMessageProtocol: Sendable {
    /// The end marker used to delimit messages.
    static var endMarkerData: Data { get }
}

extension RuntimeMessageProtocol {
    /// Default end marker: `\nOK`
    static var endMarkerData: Data {
        "\nOK".data(using: .utf8)!
    }
}

// MARK: - RuntimeMessageChannel

/// A bidirectional message channel that handles framing, encoding, and dispatching.
///
/// `RuntimeMessageChannel` provides the common infrastructure for message-based
/// communication, including:
/// - Message framing with `\nOK` delimiter
/// - JSON encoding/decoding of requests and responses
/// - Async message handler registration and dispatch
/// - Thread-safe send/receive with semaphore
///
/// ## Usage
///
/// ```swift
/// let channel = RuntimeMessageChannel()
///
/// // Register handlers
/// channel.setMessageHandler(name: "echo") { (input: String) -> String in
///     return "Echo: \(input)"
/// }
///
/// // Process incoming data
/// channel.appendReceivedData(data)
///
/// // Send messages
/// try await channel.send(data: encodedMessage, writer: { data in
///     // Write data to underlying transport
/// })
/// ```
@Loggable
final class RuntimeMessageChannel: @unchecked Sendable, RuntimeMessageProtocol {
    /// Unique identifier for this channel.
    let id = UUID()

    /// Set while a fire-and-forget handler runs on `orderedHandlerTail`.
    ///
    /// A request sent from there does not wait for the pushes that preceded
    /// its reply (see `sendRequest`): that wait is for the tail, and the
    /// sender is part of the tail, so it would wait for itself. Tasks a
    /// handler starts inherit the flag, which only gives up the ordering
    /// guarantee for their requests. It is not per channel, so that handlers
    /// of two channels waiting on requests over each other cannot deadlock
    /// either.
    ///
    /// What still deadlocks: a handler that waits for work sending a request
    /// over this channel from outside the handler's task tree — a
    /// `Task.detached`, a dispatch queue, a completion handler. That request
    /// waits for the tail, and the tail waits for the handler. Don't.
    @TaskLocal static var isRunningOnOrderedHandlerTail = false

    /// Called when a complete message is received.
    /// - Note: This callback is called from a locked context; avoid long-running operations.
    var onMessageReceived: (@Sendable (Data) -> Void)?

    /// Message handlers keyed by message identifier.
    private let messageHandlers = Mutex<[String: RuntimeMessageHandler]>([:])

    /// In-flight request bookkeeping keyed by request identifier. The entry holds both
    /// the awaited continuation and the optional timeout `Task` so the success and
    /// writer-error paths can cancel the timer before it fires — without that, an
    /// orphaned timer from a finished request can wake later and incorrectly time out
    /// a *different* request that happened to be registered under the same identifier.
    private let pendingRequests = Mutex<[String: PendingRequest]>([:])

    /// Nonces of requests this side stopped waiting for, oldest first; see
    /// `rememberAbandonedRequest(nonce:)`. Bounded, because a reply that never
    /// comes leaves an entry that only ages out.
    private let abandonedRequestNonces = Mutex<[String]>([])

    private static let maximumAbandonedRequestNonceCount = 256

    /// Buffer for incoming data, plus how far it has already been scanned for an
    /// end-marker. Persisting the scan offset across appends keeps a large
    /// message that arrives in many chunks at O(n) total instead of O(n²) — the
    /// old code re-walked the whole accumulated buffer on every chunk.
    private struct ReceiveBuffer {
        var data = Data()
        /// Bytes `[0, scannedPrefix)` are known not to begin a complete marker.
        var scannedPrefix = 0
    }

    private let receivingData = Mutex<ReceiveBuffer>(ReceiveBuffer())

    /// Stream for received messages.
    private var receivedDataStream: SharedAsyncSequence<AsyncThrowingStream<Data, Error>>?

    /// Continuation for yielding received messages.
    private let receivedDataContinuation = Mutex<AsyncThrowingStream<Data, Error>.Continuation?>(nil)

    /// Semaphore for serializing send operations.
    private let sendSemaphore = AsyncSemaphore(value: 1)

    init() {
        setupStreams()
        #log(.debug, "RuntimeMessageChannel initialized with id: \(self.id, privacy: .public)")
    }

    // MARK: - Stream Setup

    private func setupStreams() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.receivedDataStream = stream.shared()
        self.receivedDataContinuation.withLock { $0 = continuation }
    }

    // MARK: - Handler Registration

    /// Registers a handler for messages with no payload and no response.
    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
            try await handler()
            return RuntimeMessageNull.null
        }
    }

    /// Registers a handler for messages with a payload but no response.
    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        setMessageHandler(name: name) { @Sendable (request: Request) in
            try await handler(request)
            return RuntimeMessageNull.null
        }
    }

    /// Registers a handler for messages with no payload but expecting a response.
    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
            return try await handler()
        }
    }

    /// Registers a handler for messages with both request payload and response.
    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        messageHandlers.withLock { $0[name] = RuntimeMessageHandler(closure: handler) }
        #log(.debug, "Registered message handler for: \(name, privacy: .public)")
    }

    /// Registers a handler for typed requests with associated responses.
    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        setMessageHandler(name: Request.identifier, handler: handler)
    }

    /// Returns the handler for the given message identifier.
    func handler(for identifier: String) -> RuntimeMessageHandler? {
        messageHandlers.withLock { $0[identifier] }
    }

    /// Looks up a pending request by routing key and delivers the response.
    ///
    /// `routingKey` is the per-round-trip `nonce` when the envelope carries
    /// one, otherwise the legacy `identifier` (command name). The new
    /// `sendRequest<Response>` always stamps + registers under `nonce` so
    /// concurrent in-flight requests sharing the same command name route
    /// correctly; envelope-decode paths fall back to `identifier` only when
    /// a peer doesn't echo a nonce (e.g. legacy wire interop).
    /// - Parameters:
    ///   - routingKey: Lookup key — typically `envelope.nonce ?? envelope.identifier`.
    ///   - data: The response data to deliver.
    /// - Returns: `true` if the data was delivered to a pending request, `false` otherwise.
    func deliverToPendingRequest(routingKey: String, data: Data) -> Bool {
        guard let pending = pendingRequests.withLock({ $0.removeValue(forKey: routingKey) }) else {
            return false
        }
        #log(.debug, "Delivered response to pending request: \(routingKey, privacy: .public)")
        pending.cancelTimeoutTask()
        // Frames are dispatched in arrival order, so every fire-and-forget
        // message that arrived before this reply is on the tail by now. The
        // requester waits for them before it continues; see `sendRequest`.
        let precedingHandlers = orderedHandlerTail.withLock { $0 }
        pending.continuation.resume(returning: ReceivedReply(data: data, precedingHandlers: precedingHandlers))
        return true
    }

    // MARK: - Receiving Data

    /// Appends data to the receiving buffer and processes complete messages.
    func appendReceivedData(_ data: Data) {
        receivingData.withLock { $0.data.append(data) }
        processReceivedData()
    }

    /// Processes the receiving buffer and extracts complete messages.
    private func processReceivedData() {
        var extractedMessages: [Data] = []
        var remainingBufferSize = 0
        let marker = Self.endMarkerData
        let markerCount = marker.count

        receivingData.withLock { state in
            // Resume scanning where the previous pass stopped, backing up by
            // `markerCount - 1` so a marker straddling the old/new boundary is
            // still found.
            var searchStart = max(0, state.scannedPrefix - (markerCount - 1))
            var consumedUpTo = 0
            while searchStart <= state.data.count - markerCount {
                guard let endRange = state.data.range(of: marker, in: searchStart ..< state.data.count) else {
                    break
                }
                let messageData = state.data.subdata(in: consumedUpTo ..< endRange.lowerBound)
                extractedMessages.append(messageData)
                consumedUpTo = endRange.upperBound
                searchStart = endRange.upperBound
            }

            if consumedUpTo > 0 {
                state.data = consumedUpTo < state.data.count
                    ? state.data.subdata(in: consumedUpTo ..< state.data.count)
                    : Data()
                state.scannedPrefix = 0
            } else {
                // No complete message this round — remember how far we scanned so
                // the next append doesn't re-walk the whole buffer.
                state.scannedPrefix = max(0, state.data.count - (markerCount - 1))
            }
            remainingBufferSize = state.data.count
        }

        let hasContinuation = receivedDataContinuation.withLock { $0 != nil }
        if extractedMessages.isEmpty {
            #log(.debug, "[MessageChannel] processReceivedData: no end marker found (buffer=\(remainingBufferSize, privacy: .public) bytes, continuation=\(hasContinuation, privacy: .public))")
        }
        for messageData in extractedMessages {
            #log(.debug, "[MessageChannel] processReceivedData: yielding message (\(messageData.count, privacy: .public) bytes, continuation=\(hasContinuation, privacy: .public))")
            _ = receivedDataContinuation.withLock { $0?.yield(messageData) }
            _ = dispatchContinuation.withLock { $0?.yield(messageData) }
            onMessageReceived?(messageData)
        }
    }

    /// Finishes the received data stream and resumes any in-flight pending requests with an error.
    ///
    /// When the underlying transport closes or errors out, we must not only terminate the
    /// received-data stream but also unblock every caller currently awaiting a response via
    /// `sendRequest`. Otherwise the `withCheckedThrowingContinuation` registered in `pendingRequests`
    /// is never resumed and the calling task hangs indefinitely.
    func finishReceiving(throwing error: (any Error)? = nil) {
        if let error {
            #log(.default, "finishReceiving: with error: \(String(describing: error), privacy: .public)")
        } else {
            #log(.info, "finishReceiving: stream closed normally")
        }
        receivedDataContinuation.withLock { continuation in
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
            continuation = nil
        }

        // Finish the dispatch stream too. Any frames yielded before this call
        // (e.g. a final message that arrived coalesced with the FIN) are still
        // delivered to the dispatch consumer first — `AsyncStream` drains its
        // buffer ahead of the terminal event.
        dispatchContinuation.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }

        // Drain any pending requests that were waiting for a response on the now-dead channel
        // and resume each with an error so the `await` in `sendRequest` unblocks.
        let drainedRequests: [PendingRequest] = pendingRequests.withLock { pending in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        if !drainedRequests.isEmpty {
            #log(.info, "finishReceiving: draining \(drainedRequests.count, privacy: .public) pending request(s)")
        }
        let resumeError: any Error = error ?? RuntimeMessageChannelError.notConnected
        for pending in drainedRequests {
            pending.cancelTimeoutTask()
            pending.continuation.resume(throwing: resumeError)
        }
    }

    /// Returns the current size of the receiving buffer.
    var receivingBufferSize: Int {
        receivingData.withLock { $0.data.count }
    }

    // MARK: - Sending Data

    /// Sends data using the provided writer closure.
    ///
    /// This method serializes send operations using a semaphore to prevent
    /// interleaving of messages.
    func send(data: Data, writer: @Sendable (Data) async throws -> Void) async throws {
        await sendSemaphore.wait()
        defer { sendSemaphore.signal() }

        let dataToSend = data + Self.endMarkerData
        #log(.debug, "Sending \(dataToSend.count, privacy: .public) bytes")
        try await writer(dataToSend)
    }

    /// Sends a request and waits for a response.
    ///
    /// Concurrency model: `sendSemaphore` now guards only the on-wire write,
    /// **not** the wait for the response. A slow peer handler (e.g. 20 s of
    /// section parsing on the background indexer) no longer monopolizes the
    /// semaphore for its entire round trip, so other `sendRequest`s can
    /// leave the local outbox immediately. Each in-flight request is keyed
    /// in `pendingRequests` by a freshly minted per-round-trip nonce
    /// (`RuntimeRequestData.nonce`) so concurrent requests sharing the same
    /// command name (e.g. multiple `isImageLoaded`) route their responses
    /// without collision; the peer must echo the nonce verbatim in its
    /// response envelope.
    ///
    /// Ordering: when this returns, every fire-and-forget message the peer
    /// sent before the reply has been handled — the reply is delivered inline
    /// but this waits for the handler tail as it stood when the reply arrived.
    /// A request sent from a handler on that tail skips the wait; see
    /// `isRunningOnOrderedHandlerTail`.
    ///
    /// - Parameters:
    ///   - requestData: The request payload framed by `RuntimeRequestData`.
    ///     If `nonce` is `nil` a fresh `UUID` is stamped before sending.
    ///   - timeout: Optional deadline (seconds). When non-nil, if no response arrives within
    ///     the deadline the call throws `RuntimeMessageChannelError.requestTimeout`, the
    ///     pending entry is removed and its nonce remembered as abandoned, so a late
    ///     response is dropped rather than taken for a request. When `nil` the call
    ///     waits indefinitely (the historical behaviour) and only unblocks when the response
    ///     arrives, the writer fails, or `finishReceiving` is invoked.
    ///   - writer: Async closure that performs the actual transport write.
    func sendRequest<Response: Codable>(
        requestData: RuntimeRequestData,
        timeout: TimeInterval? = nil,
        writer: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Response {
        // Stamp a nonce so concurrent same-`identifier` requests don't collide
        // in `pendingRequests`. Honor any caller-supplied nonce (internal
        // echo paths) but allocate one otherwise.
        let nonce = requestData.nonce ?? UUID().uuidString
        let stamped: RuntimeRequestData = (requestData.nonce == nil)
            ? RuntimeRequestData(identifier: requestData.identifier, data: requestData.data, nonce: nonce)
            : requestData

        #log(.debug, "Sending request: \(stamped.identifier, privacy: .public) [nonce \(nonce, privacy: .public)]")
        let data = try JSONEncoder().encode(stamped)
        let dataToSend = data + Self.endMarkerData

        // Register pending request before sending
        let reply: ReceivedReply = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingRequest(continuation: continuation)
            pendingRequests.withLock { $0[nonce] = pending }

            // Spawn the timeout task before the writer task so the entry is fully wired
            // up — including its cancel handle — before any code path that resolves the
            // continuation can run. The success/writer-error paths cancel the timer so
            // it cannot wake later and incorrectly time out a re-used identifier.
            if let timeout {
                let identifier = stamped.identifier
                let timeoutTask = Task { [nonce] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if Task.isCancelled { return }
                    if let pending = self.pendingRequests.withLock({ $0.removeValue(forKey: nonce) }) {
                        #log(.error, "Request \(identifier, privacy: .public) [nonce \(nonce, privacy: .public)] timed out after \(timeout, privacy: .public)s")
                        self.rememberAbandonedRequest(nonce: nonce)
                        pending.continuation.resume(throwing: RuntimeMessageChannelError.requestTimeout)
                    }
                }
                pending.setTimeoutTask(timeoutTask)
            }

            Task { [identifier = stamped.identifier, nonce] in
                // Acquire the semaphore here, inside the write Task, so the
                // outer await (`withCheckedThrowingContinuation`) doesn't
                // hold it for the full round trip. The semaphore still
                // serializes adjacent writes so length-prefixed envelopes
                // don't interleave on the wire; once `writer` returns the
                // slot frees immediately even though we keep waiting on
                // `continuation` for the response.
                await self.sendSemaphore.wait()
                do {
                    try await writer(dataToSend)
                    self.sendSemaphore.signal()
                } catch {
                    self.sendSemaphore.signal()
                    // Remove pending request and resume with error
                    if let pending = self.pendingRequests.withLock({ $0.removeValue(forKey: nonce) }) {
                        #log(.error, "Failed to send request \(identifier, privacy: .public) [nonce \(nonce, privacy: .public)]: \(String(describing: error), privacy: .public)")
                        pending.cancelTimeoutTask()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }
        }

        // The pushes the peer sent before this reply — this request's own
        // progress, the state syncs ahead of it — are handled before the
        // caller continues, as they are over XPC, where every push is a round
        // trip. Without this wait the reply overtakes them: a request that
        // drops its progress route on return drops with it the pushes still
        // queued on the tail.
        if !Self.isRunningOnOrderedHandlerTail {
            await reply.precedingHandlers.value
        }
        #log(.debug, "Received response for: \(stamped.identifier, privacy: .public) [nonce \(nonce, privacy: .public)]")
        let response = try JSONDecoder().decode(RuntimeRequestData.self, from: reply.data)
        // A peer that couldn't service the request (handler threw, or no handler
        // was registered) flags the envelope and ships a `RuntimeNetworkRequestError`
        // in `data`. Surface that as the thrown error instead of blindly decoding
        // it as `Response` — which would otherwise yield an opaque `DecodingError`
        // or, for an all-optional `Response`, a bogus "success".
        if response.isError == true {
            if let remoteError = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: response.data) {
                #log(.error, "Request \(stamped.identifier, privacy: .public) [nonce \(nonce, privacy: .public)] failed remotely: \(remoteError.message, privacy: .public)")
                throw remoteError
            }
            throw RuntimeMessageChannelError.receiveFailed
        }
        return try JSONDecoder().decode(Response.self, from: response.data)
    }

    /// Sends a request with no expected response.
    func sendRequest(
        requestData: RuntimeRequestData,
        writer: @Sendable (Data) async throws -> Void
    ) async throws {
        await sendSemaphore.wait()
        defer { sendSemaphore.signal() }

        #log(.debug, "Sending fire-and-forget request: \(requestData.identifier, privacy: .public)")
        let data = try JSONEncoder().encode(requestData)
        let dataToSend = data + Self.endMarkerData
        try await writer(dataToSend)
    }

    /// Waits for and returns the next received message.
    func receiveData() async throws -> Data {
        guard let receivedDataStream else {
            #log(.error, "Attempted to receive data but channel is not connected")
            throw RuntimeMessageChannelError.notConnected
        }

        for try await data in receivedDataStream {
            if let error = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data) {
                #log(.default, "Received error response: \(String(describing: error), privacy: .public)")
                throw error
            } else {
                #log(.debug, "Received \(data.count, privacy: .public) bytes")
                return data
            }
        }

        #log(.error, "Receive failed - stream ended unexpectedly")
        throw RuntimeMessageChannelError.receiveFailed
    }

    /// Returns an async sequence of received messages.
    func receivedMessages() -> SharedAsyncSequence<AsyncThrowingStream<Data, Error>>? {
        receivedDataStream
    }

    // MARK: - Dispatch

    /// Serial tail for fire-and-forget handler execution. Each enqueued unit of
    /// work `await`s its predecessor, so push handlers run in submission order
    /// (e.g. `imageList` → `imageNodes` → `dataDidChange`) even though they run
    /// off the receive loop. A reply carries the tail as it stood when the
    /// reply arrived, and `sendRequest` waits for it.
    private let orderedHandlerTail = Mutex<Task<Void, Never>>(Task {})

    /// Long-lived task draining the dedicated dispatch stream below.
    private let dispatchTask = Mutex<Task<Void, Never>?>(nil)

    /// Continuation feeding `beginDispatch`'s consumer. A dedicated, unbounded,
    /// non-`shared` `AsyncStream` is used (rather than `receivedDataStream`) so
    /// that frames yielded just before `finishReceiving()` are still delivered:
    /// `AsyncStream` guarantees buffered elements drain before the terminal
    /// event. That is what stops "peer sent its final message, then closed" from
    /// dropping that last message.
    private let dispatchContinuation = Mutex<AsyncStream<Data>.Continuation?>(nil)

    /// Drives the receive → dispatch pipeline for a connection. Centralizes the
    /// logic that previously lived (duplicated, and subtly divergent) in every
    /// transport's `dispatchReceivedMessage` / `handleReceivedMessage`.
    ///
    /// Design guarantees:
    /// - **Responses route inline.** `deliverToPendingRequest` runs on the drain
    ///   loop itself, so a response is never queued behind handler execution.
    ///   This is what prevents a nested round trip (a handler awaiting a reply
    ///   over the same connection) from deadlocking the loop.
    /// - **Fire-and-forget handlers preserve order.** They run on a serial tail
    ///   so state-sync pushes are applied in the order they were sent.
    /// - **A request returns after the pushes sent before its reply.** The
    ///   reply is delivered inline but its requester waits for the tail as it
    ///   stood when the reply arrived (`sendRequest`), so a reply never
    ///   overtakes the progress or results pushed ahead of it.
    /// - **Response-producing handlers run concurrently.** A slow handler can no
    ///   longer head-of-line block unrelated requests; each reply is routed by
    ///   its nonce.
    /// - **Unknown handler / handler throw replies with an error envelope** when
    ///   (and only when) the sender carries a nonce, i.e. is awaiting a response.
    ///   That unblocks the caller instead of leaving it to hang on a `nil`
    ///   timeout, while staying silent for fire-and-forget to avoid an error
    ///   ping-pong.
    /// - **A reply nobody waits for is dropped, never handled.** An error
    ///   envelope, or the late reply to a request that timed out, matches no
    ///   pending request; taken for a request, it would be answered, and the
    ///   answer answered back.
    ///
    /// - Parameter rawWriter: Performs the actual on-wire write for replies.
    ///   Framing (`\nOK`) and send-serialization are added by `send(data:writer:)`.
    func beginDispatch(rawWriter: @escaping @Sendable (Data) async throws -> Void) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        dispatchContinuation.withLock { existing in
            existing?.finish()
            existing = continuation
        }
        let task = Task { [weak self] in
            for await data in stream {
                guard let self else { return }
                self.dispatchReceived(data, rawWriter: rawWriter)
            }
        }
        dispatchTask.withLock { existing in
            existing?.cancel()
            existing = task
        }
    }

    private func dispatchReceived(_ data: Data, rawWriter: @escaping @Sendable (Data) async throws -> Void) {
        let requestData: RuntimeRequestData
        do {
            requestData = try JSONDecoder().decode(RuntimeRequestData.self, from: data)
        } catch {
            // Envelope decode failure → no identifier, no safe way to route an
            // error response. Swallow rather than echo, otherwise both peers
            // loop on each other's malformed errors.
            #log(.error, "Envelope decode failed, swallowing to avoid ping-pong: \(error, privacy: .public)")
            return
        }

        // Route by nonce when present (new wire form), fall back to identifier
        // for legacy peers. Responses are delivered inline so handler execution
        // never blocks them.
        let routingKey = requestData.nonce ?? requestData.identifier
        if deliverToPendingRequest(routingKey: routingKey, data: data) {
            return
        }

        // A reply nobody waits for any more must not be taken for a request:
        // answering it sends the peer an envelope of its own command, which the
        // peer runs and answers in turn, and the two echo each other until the
        // connection closes. An error envelope is only ever a reply; any other
        // frame is one when its nonce names a request this side gave up on.
        if requestData.isError == true || takeAbandonedRequest(nonce: requestData.nonce) {
            #log(.debug, "Dropped a reply nobody waits for: \(requestData.identifier, privacy: .public)")
            return
        }

        guard let handler = handler(for: requestData.identifier) else {
            if requestData.nonce != nil {
                #log(.error, "No handler for: \(requestData.identifier, privacy: .public); replying with error so the caller doesn't hang")
                sendErrorReply(for: requestData, message: RuntimeNetworkRequestError.unknownCommandMessagePrefix + requestData.identifier, rawWriter: rawWriter)
            } else {
                #log(.default, "No handler for fire-and-forget: \(requestData.identifier, privacy: .public)")
            }
            return
        }

        #log(.debug, "Handling request: \(requestData.identifier, privacy: .public)")
        if handler.responseType == RuntimeMessageNull.self {
            // Fire-and-forget: preserve submission order on the serial tail.
            enqueueOrdered { [weak self] in
                do {
                    _ = try await handler.closure(requestData.data)
                } catch {
                    self?.logHandlerFailure(requestData.identifier, error: error)
                }
            }
        } else {
            // Response-producing: run concurrently so a slow handler doesn't
            // head-of-line block other in-flight requests.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let responseData = try await handler.closure(requestData.data)
                    let response = RuntimeRequestData(identifier: requestData.identifier, data: responseData, nonce: requestData.nonce)
                    let encoded = try JSONEncoder().encode(response)
                    try await self.send(data: encoded, writer: rawWriter)
                } catch {
                    self.logHandlerFailure(requestData.identifier, error: error)
                    self.sendErrorReply(for: requestData, message: Self.replyMessage(for: error), rawWriter: rawWriter)
                }
            }
        }
    }

    /// Records that this side stopped waiting for the request with `nonce`.
    /// Its reply can still arrive, and has to be recognised as a reply then
    /// (`dispatchReceived`). Every path that gives up on a request before its
    /// reply arrives must call this — today only the timeout does; a new early
    /// return (a cancellation, a shorter deadline) has to as well.
    private func rememberAbandonedRequest(nonce: String) {
        abandonedRequestNonces.withLock { nonces in
            nonces.append(nonce)
            let overflowCount = nonces.count - Self.maximumAbandonedRequestNonceCount
            if overflowCount > 0 {
                nonces.removeFirst(overflowCount)
            }
        }
    }

    /// Whether `nonce` names a request this side abandoned, forgetting it:
    /// a request has one reply.
    private func takeAbandonedRequest(nonce: String?) -> Bool {
        guard let nonce else { return false }
        return abandonedRequestNonces.withLock { nonces in
            guard let index = nonces.firstIndex(of: nonce) else { return false }
            nonces.remove(at: index)
            return true
        }
    }

    /// Appends `work` to the serial fire-and-forget tail, preserving order.
    private func enqueueOrdered(_ work: @escaping @Sendable () async -> Void) {
        orderedHandlerTail.withLock { tail in
            let previous = tail
            tail = Task {
                await previous.value
                await Self.$isRunningOnOrderedHandlerTail.withValue(true) {
                    await work()
                }
            }
        }
    }

    /// Sends a nonce-routed error envelope so the peer's awaiting `sendRequest`
    /// resolves with the failure. No-op when the sender didn't supply a nonce
    /// (fire-and-forget) — replying there would risk an error ping-pong since
    /// the peer has no pending request to absorb it.
    private func sendErrorReply(for requestData: RuntimeRequestData, message: String, rawWriter: @escaping @Sendable (Data) async throws -> Void) {
        guard requestData.nonce != nil else { return }
        Task { [weak self] in
            guard let self,
                  let payload = try? JSONEncoder().encode(RuntimeNetworkRequestError(message: message)) else { return }
            let envelope = RuntimeRequestData(identifier: requestData.identifier, data: payload, nonce: requestData.nonce, isError: true)
            guard let encoded = try? JSONEncoder().encode(envelope) else { return }
            do {
                try await self.send(data: encoded, writer: rawWriter)
            } catch {
                #log(.error, "Failed to send error reply for \(requestData.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// What an error reply says about `error`. A failure that is itself an
    /// error reply from further along — a relay whose own forwarded request
    /// failed — goes on in the words it arrived in, so the caller reads what
    /// the peer that produced it wrote: "No handler registered for …" from a
    /// peer behind the relay stays recognisable (`isUnknownCommand`) instead
    /// of arriving wrapped in this type's description.
    private static func replyMessage(for error: any Error) -> String {
        if let remoteError = error as? RuntimeNetworkRequestError {
            return remoteError.message
        }
        return "\(error)"
    }

    private func logHandlerFailure(_ identifier: String, error: any Error) {
        #log(.error, "Handler \(identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}

// MARK: - PendingRequest

/// A reply as `sendRequest` receives it: the envelope, and the tail of
/// fire-and-forget handlers as it stood when the reply arrived — the pushes
/// the peer sent before it.
private struct ReceivedReply: Sendable {
    let data: Data
    let precedingHandlers: Task<Void, Never>
}

/// Bookkeeping for a single in-flight request. Owns the continuation that `sendRequest`
/// is awaiting and an optional timeout `Task` whose handle is held under a lock so the
/// success and writer-error paths can cancel it before it has a chance to fire against a
/// later request that registered under the same identifier.
private final class PendingRequest: @unchecked Sendable {
    let continuation: CheckedContinuation<ReceivedReply, Error>
    private let timeoutTask = Mutex<Task<Void, Never>?>(nil)

    init(continuation: CheckedContinuation<ReceivedReply, Error>) {
        self.continuation = continuation
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        timeoutTask.withLock { $0 = task }
    }

    func cancelTimeoutTask() {
        timeoutTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }
}

// MARK: - RuntimeMessageChannelError

/// Errors that can occur during message channel operations.
enum RuntimeMessageChannelError: Error, LocalizedError, Sendable {
    case notConnected
    case receiveFailed
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Message channel is not connected"
        case .receiveFailed:
            return "Failed to receive message"
        case .requestTimeout:
            return "Request timed out before a response arrived"
        }
    }
}

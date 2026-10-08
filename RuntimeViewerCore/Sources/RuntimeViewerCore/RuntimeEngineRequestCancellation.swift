import Foundation
import FoundationToolbox

// MARK: - Wire

/// The payload of `RuntimeEngine.CommandNames.cancelRequest`: the identifier
/// the requesting peer minted for a request it no longer wants.
struct RuntimeEngineRequestCancellation: Codable, Sendable {
    let requestIdentifier: String
}

// MARK: - Serving side

/// The requests one connection is serving that their sender can withdraw,
/// keyed by the identifier the sender put in their
/// `RuntimeEngineProgressEnvelope`.
///
/// Each runs in a task this registry holds a handle to, because the
/// transports run a handler in a task nobody does: SwiftyXPC handles every
/// message in a task of its own, and so does the socket channel for every
/// request it answers.
///
/// A `cancelRequest` and the request it names are separate messages, and the
/// transports run their handlers in no particular order relative to each
/// other: over a socket the cancellation, which expects no reply, waits its
/// turn on the channel's ordered handler tail while the request runs in a
/// task of its own; over XPC both are tasks of their own. A cancellation whose
/// request has not registered yet is therefore remembered, and applied the
/// moment the request registers. The memory is bounded: a cancellation that
/// arrives after its request ended leaves an entry nothing claims, which only
/// ages out.
actor RuntimeEngineInboundRequests {
    static let maximumEarlyCancellationCount = 256

    private var cancellationsByRequestIdentifier: [String: @Sendable () -> Void] = [:]

    /// Identifiers cancelled before their request registered, oldest first.
    private var earlyCancelledRequestIdentifiers: [String] = []

    init() {}

    /// Runs `operation` as the request its sender named `requestIdentifier`,
    /// in a task that `cancel(_:)` for that identifier cancels.
    nonisolated func run<Response: Sendable>(
        _ requestIdentifier: String,
        operation: @escaping @Sendable () async throws -> Response
    ) async throws -> Response {
        let work = Task { try await operation() }
        await register(requestIdentifier) { work.cancel() }
        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        await unregister(requestIdentifier)
        return try result.get()
    }

    /// Cancels the request its sender named `requestIdentifier` — now, or the
    /// moment it registers when it has not yet.
    func cancel(_ requestIdentifier: String) {
        if let cancellation = cancellationsByRequestIdentifier.removeValue(forKey: requestIdentifier) {
            cancellation()
            return
        }
        earlyCancelledRequestIdentifiers.append(requestIdentifier)
        let overflowCount = earlyCancelledRequestIdentifiers.count - Self.maximumEarlyCancellationCount
        if overflowCount > 0 {
            earlyCancelledRequestIdentifiers.removeFirst(overflowCount)
        }
    }

    private func register(_ requestIdentifier: String, cancellation: @escaping @Sendable () -> Void) {
        if let index = earlyCancelledRequestIdentifiers.firstIndex(of: requestIdentifier) {
            earlyCancelledRequestIdentifiers.remove(at: index)
            cancellation()
            return
        }
        cancellationsByRequestIdentifier[requestIdentifier] = cancellation
    }

    private func unregister(_ requestIdentifier: String) {
        cancellationsByRequestIdentifier[requestIdentifier] = nil
    }
}

// MARK: - Requesting side

/// One request forwarded to the serving peer, whose caller gets whichever
/// comes first: the peer's reply, or its own cancellation.
///
/// A transport cannot interrupt a request it has sent — SwiftyXPC's send and
/// the socket channel's both wait for the reply, whatever becomes of the task
/// that sent it — so the send runs in a task of its own, and a cancelled
/// caller stops waiting for it. That task still ends with the reply, which
/// the serving peer sends once the withdrawal reaches it; on the transport no
/// request is given up early, so no reply arrives that nothing waits for.
final class RuntimeEngineForwardedRequest<Response: Sendable>: Sendable {
    private enum Stage {
        case unsent
        case awaitingReply(CheckedContinuation<Response, Swift.Error>)
        case answered
        case cancelled
    }

    private let stage = Mutex<Stage>(.unsent)

    init() {}

    /// Whether the caller cancelled. Read by the request's progress route: a
    /// push that lands after the cancellation belongs to work nobody waits
    /// for any more.
    var isCancelled: Bool {
        stage.withLock { stage in
            if case .cancelled = stage { return true }
            return false
        }
    }

    /// Sends the request with `send` and returns the reply — or throws
    /// `CancellationError` as soon as `cancel()` is called, without sending
    /// at all when it was called first.
    func response(sending send: @escaping @Sendable () async throws -> Response) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            let isSending = stage.withLock { stage -> Bool in
                guard case .unsent = stage else { return false }
                stage = .awaitingReply(continuation)
                return true
            }
            guard isSending else {
                continuation.resume(throwing: CancellationError())
                return
            }
            Task {
                let result: Result<Response, Swift.Error>
                do {
                    result = .success(try await send())
                } catch {
                    result = .failure(error)
                }
                self.answer(with: result)
            }
        }
    }

    /// Stops the caller waiting. Returns whether the request was out and
    /// still unanswered — whether the serving peer has anything to withdraw.
    @discardableResult
    func cancel() -> Bool {
        let continuation = stage.withLock { stage -> CheckedContinuation<Response, Swift.Error>? in
            switch stage {
            case .unsent:
                stage = .cancelled
                return nil
            case .awaitingReply(let continuation):
                stage = .cancelled
                return continuation
            case .answered,
                 .cancelled:
                return nil
            }
        }
        guard let continuation else { return false }
        continuation.resume(throwing: CancellationError())
        return true
    }

    private func answer(with result: Result<Response, Swift.Error>) {
        let continuation = stage.withLock { stage -> CheckedContinuation<Response, Swift.Error>? in
            guard case .awaitingReply(let continuation) = stage else { return nil }
            stage = .answered
            return continuation
        }
        continuation?.resume(with: result)
    }
}

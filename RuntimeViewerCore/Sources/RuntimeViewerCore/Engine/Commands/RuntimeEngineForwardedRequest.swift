import Foundation
import FoundationToolbox

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

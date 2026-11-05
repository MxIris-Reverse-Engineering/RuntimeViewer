import Foundation
import FoundationToolbox

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

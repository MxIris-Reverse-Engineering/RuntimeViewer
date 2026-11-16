import Combine
import Foundation
import RuntimeViewerCore

/// Calls back on the main actor each time an engine becomes ready again — a
/// new process behind it: the local service relaunched, a peer reconnected,
/// the engine's first connection — and never for the state replayed on
/// subscribing.
///
/// Keyed on `isReady`, not on a particular state: an in-process engine goes
/// `.localOnly` rather than `.connected`, and a test can drive the same edge
/// with `stop()` followed by `connect()`. Observing ends when the observer is
/// released.
@MainActor
final class RuntimeEngineReadinessEdgeObserver {
    /// Whether the engine was ready when last heard from, so a `false → true`
    /// edge can be told from the state replayed on subscribing.
    private var wasReady: Bool

    private var subscription: AnyCancellable?

    init(engine: RuntimeEngine, onBecameReadyAgain: @escaping @MainActor (RuntimeEngine) -> Void) {
        wasReady = engine.state.isReady
        subscription = engine.statePublisher
            .map(\.isReady)
            .sink { [weak self, weak engine] isReady in
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine else { return }
                    let becameReadyAgain = isReady && !wasReady
                    wasReady = isReady
                    if becameReadyAgain {
                        onBecameReadyAgain(engine)
                    }
                }
            }
    }
}

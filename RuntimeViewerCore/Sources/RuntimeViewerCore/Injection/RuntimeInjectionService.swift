public import Foundation

/// The machine-local half of process injection, supplied by whoever can actually
/// perform it.
///
/// `RuntimeViewerCore` holds none of the implementation on purpose. Injecting
/// needs MachInjector linked into the process on iOS and the privileged helper
/// daemon on macOS, while this module also builds for watchOS, tvOS and
/// visionOS, where neither exists. The engine only forwards a request to
/// whatever was registered and reports the honest answer when nothing was — see
/// ``RuntimeInjectionAvailability/withoutInjectionService``.
///
/// This mirrors how ``RuntimeEngine/engineListProvider`` is wired: a capability
/// the engine serves on request but does not own.
public protocol RuntimeInjectionService: Sendable {
    /// Whether this machine can inject at all, and when it cannot, why.
    ///
    /// Must answer without attempting anything: it drives a toolbar item's
    /// enabled state, so it is called on paths where a failure would have
    /// nowhere to go.
    func injectionAvailability() async -> RuntimeInjectionAvailability

    /// Every process on this machine, each carrying its own injectability.
    ///
    /// Implementations enumerate rather than filter — a target that cannot be
    /// injected is still listed, marked, and shown disabled, because a list that
    /// silently omits things cannot answer "why is it not there?".
    func processList() async throws -> [RuntimeProcess]

    /// Loads the payload into the process with this identifier.
    ///
    /// Returns a result rather than throwing: the caller branches on *which*
    /// failure it was, and that distinction does not survive being flattened
    /// into an error. Implementations should verify the target is alive before
    /// concluding anything about permissions.
    func inject(intoProcessWithIdentifier processIdentifier: pid_t) async -> RuntimeProcessInjectionResult
}

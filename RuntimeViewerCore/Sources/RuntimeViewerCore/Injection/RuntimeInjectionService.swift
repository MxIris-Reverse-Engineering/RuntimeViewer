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

    /// The icons of these application bundles, as the PNG bytes in them, keyed
    /// by the bundle path asked for.
    ///
    /// Fetched by bundle rather than carried by ``RuntimeProcess`` so that the
    /// several processes of one application — its app extensions included,
    /// which resolve to their host — cost one icon between them, and so the
    /// process list stays as cheap as it was for every caller that wants no
    /// icons.
    ///
    /// A bundle with no icon is simply absent from the result. There is nothing
    /// to report about it: plenty of bundles ship their icon only inside a
    /// compiled asset catalogue, and the caller's answer is the same as for a
    /// daemon either way.
    ///
    /// **The paths come from the caller, which on a device means over the
    /// network.** An implementation must accept nothing but application bundle
    /// paths and must read nothing out of one but the icon file names that
    /// bundle's own `Info.plist` declares — otherwise this is an arbitrary file
    /// read primitive with a network interface. See
    /// `RuntimeDeviceApplicationIconLocator`.
    ///
    /// Defaulted to nothing, which is the honest answer for macOS: the host
    /// lists its own processes there and gets their icons from `NSWorkspace`
    /// without asking anyone.
    func applicationIcons(forBundlesAtPaths applicationBundlePaths: [String]) async -> [String: Data]

    /// Loads the payload into the process with this identifier.
    ///
    /// Returns a result rather than throwing: the caller branches on *which*
    /// failure it was, and that distinction does not survive being flattened
    /// into an error. Implementations should verify the target is alive before
    /// concluding anything about permissions.
    ///
    /// - Parameter rendezvous: Where the payload should report in, to be handed
    ///   to it along with the payload itself. An implementation whose payload
    ///   can advertise itself may ignore it; one injecting into a process on a
    ///   real iOS device cannot, because the target's sandbox denies the
    ///   listener. See ``RuntimePayloadRendezvous``.
    func inject(
        intoProcessWithIdentifier processIdentifier: pid_t,
        rendezvous: RuntimePayloadRendezvous?,
    ) async -> RuntimeProcessInjectionResult

    /// Releases whatever this machine was doing to keep an injected process
    /// able to run, because nothing needs it any more.
    ///
    /// Defaulted to nothing, which is the honest answer for every
    /// implementation but one. On macOS an injected process is an ordinary
    /// process that the system never suspends; on a real iOS device it is
    /// suspended within about a second of leaving the foreground, so the
    /// device implementation holds a RunningBoard assertion from the injection
    /// until this call.
    ///
    /// Must be safe to call for a process that was never kept awake, and more
    /// than once: the host sends it when it tears down an injected engine, and
    /// that happens on paths where the injection never succeeded in the first
    /// place.
    func stopKeepingProcessAwake(withIdentifier processIdentifier: pid_t) async
}

extension RuntimeInjectionService {
    public func stopKeepingProcessAwake(withIdentifier processIdentifier: pid_t) async {}

    public func applicationIcons(forBundlesAtPaths applicationBundlePaths: [String]) async -> [String: Data] { [:] }
}

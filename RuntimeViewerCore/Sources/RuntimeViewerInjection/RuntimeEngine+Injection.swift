// `public import` because `pid_t` crosses the public API here, and this module
// builds with `InternalImportsByDefault` — a plain `import Foundation` would
// make `pid_t` internal to this file and the public methods below unspellable.
public import Foundation
// Re-exports OSToolbox, where the `#log` macro lives.
import FoundationToolbox
public import RuntimeViewerCore

/// Log host for this file.
///
/// `RuntimeEngine` carries `@Loggable(.private)`, which scopes its `logger` to
/// the file that declares it — so `#log` cannot be used from an extension in
/// another file, let alone another module. Rather than widen that access, or
/// hand-roll an `os.Logger` against the project's convention, this file gets a
/// logger of its own.
@Loggable(.private)
private enum InjectionCommandLog {
    static func capabilityQueryFailed(_ error: any Error) {
        #log(.default, "Injection capability query failed, treating as unavailable: \(error.localizedDescription, privacy: .public)")
    }

    static func applicationIconsQueryFailed(_ error: any Error) {
        #log(.default, "Could not fetch application icons from this engine's machine, so its processes will show the generic icon: \(error.localizedDescription, privacy: .public)")
    }

    static func stopKeepingAwakeFailed(_ processIdentifier: pid_t, _ error: any Error) {
        #log(.default, "Could not tell the peer to stop keeping process \(processIdentifier, privacy: .public) awake; it may hold its assertion until that process exits: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Where this engine's targets live

extension RuntimeEngine {
    /// Whether the processes this engine could attach to run on the machine
    /// Runtime Viewer itself is running on.
    ///
    /// This is the fork in the attach flow, and the reason it exists is that the
    /// host already has a working, instant answer for its own machine. Routing
    /// that case through ``injectionAvailability()`` and ``processList()`` for
    /// the sake of one code path would add a round trip, a spinner and a new
    /// failure mode to a picker that currently opens filled — and the round trip
    /// would be this process asking itself.
    ///
    /// Reading it off the source rather than probing is deliberate: it is a
    /// property of *where the connection goes*, known before anything is sent.
    ///
    /// - `local` is this process.
    /// - `remote` is XPC, which only reaches a service inside this app's own
    ///   bundle — today the Mac Catalyst helper.
    /// - `localSocket` is a process on this machine that Runtime Viewer has
    ///   already injected, the iOS Simulator included.
    /// - `bonjour` and `directTCP` cross a network interface. Even when that
    ///   interface is loopback, the peer decides what its process table is, so
    ///   the host must ask rather than assume.
    /// - `injectedTCP` is a payload already running inside a process on a
    ///   device. It looks like `localSocket` — same transport, same role
    ///   inversion — and answers the opposite way, which is the whole reason
    ///   this switch has no `default`: the address is what differs, and the
    ///   processes at that address are the device's.
    /// `nonisolated`, like the `source` it reads: the attach flow has to pick a branch
    /// before it can show anything, and making the UI `await` the engine to learn which
    /// path it is on would reintroduce exactly the latency this property exists to avoid.
    public nonisolated var injectionTargetsRunOnThisMachine: Bool {
        switch source {
        case .local, .remote, .localSocket:
            return true
        case .bonjour, .directTCP, .injectedTCP:
            return false
        }
    }
}

// MARK: - Callers

extension RuntimeEngine {
    /// Whether the machine this engine belongs to can inject, and when it
    /// cannot, why.
    ///
    /// **Does not throw.** This drives whether a control is enabled, and every
    /// caller would turn a thrown error into the same thing — "treat as
    /// unavailable" — so it is done once, here. A peer built before these
    /// commands existed has no handler for this one and fails the dispatch,
    /// which is indistinguishable from, and means the same as, a peer that
    /// cannot inject. A peer that simply forgot to call
    /// ``RuntimeInjection/install(service:)`` is indistinguishable from both —
    /// which is the one cost of installing these commands from outside Core.
    public func injectionAvailability() async -> RuntimeInjectionAvailability {
        do {
            return try await dispatch(RuntimeInjection.InjectionCapabilityCommand())
        } catch {
            InjectionCommandLog.capabilityQueryFailed(error)
            return .unsupported(reason: "Could not ask this engine whether it supports injection.")
        }
    }

    /// The process table of the machine this engine belongs to.
    ///
    /// Throws, unlike ``injectionAvailability()``: by the time this is called
    /// the gate has already said yes, so a failure here is a real one the user
    /// needs to see rather than a state to render.
    public func processList() async throws -> [RuntimeProcess] {
        try await dispatch(RuntimeInjection.ProcessListCommand())
    }

    /// The icons of these application bundles on the machine this engine
    /// belongs to, as PNG bytes keyed by the bundle path asked for.
    ///
    /// **Does not throw**, for the reason ``injectionAvailability()`` does not:
    /// a peer built before this command existed has no handler and fails the
    /// dispatch, which means "this machine has no icons to give" and must not
    /// take the process picker down with it. A picker with no icons is the
    /// state this whole command exists to improve on — it is not a failure.
    ///
    /// Asking for nothing answers nothing without a round trip, because the
    /// common case on a device is a process table that is nearly all daemons
    /// and the empty request is worth not sending at all.
    public func applicationIcons(forBundlesAtPaths applicationBundlePaths: [String]) async -> [String: Data] {
        guard !applicationBundlePaths.isEmpty else { return [:] }
        do {
            return try await dispatch(RuntimeInjection.ApplicationIconsCommand(applicationBundlePaths: applicationBundlePaths))
        } catch {
            InjectionCommandLog.applicationIconsQueryFailed(error)
            return [:]
        }
    }

    /// Loads the payload into a process on the machine this engine belongs to.
    ///
    /// Throwing and the returned result mean different things: a throw is the
    /// request not arriving, the result is the injection itself ending one way
    /// or another. Both reach the user, but only the second has a remedy worth
    /// naming.
    ///
    /// - Parameter rendezvous: Where the payload should connect back to, and the
    ///   token it should present. `nil` leaves the payload advertising itself
    ///   over Bonjour — see ``RuntimePayloadRendezvous`` for why a device cannot
    ///   rely on that. Deliberately **not** defaulted: a caller that forgets it
    ///   would get the path that silently does nothing on most device targets,
    ///   so the compiler asks instead.
    public func inject(
        intoProcessWithIdentifier processIdentifier: pid_t,
        rendezvous: RuntimePayloadRendezvous?,
    ) async throws -> RuntimeProcessInjectionResult {
        try await dispatch(
            RuntimeInjection.InjectIntoProcessCommand(
                processIdentifier: processIdentifier,
                rendezvous: rendezvous,
            )
        )
    }

    /// Lets the machine this engine belongs to stop keeping an injected process
    /// able to run.
    ///
    /// **Does not throw**, for the same reason ``injectionAvailability()`` does
    /// not: it is sent on teardown paths that have nowhere to report to, and a
    /// peer built before this command exists has no handler and fails the
    /// dispatch — which is the same outcome as a peer that was never keeping
    /// anything awake. Either way there is nothing to tell the user.
    public func stopKeepingProcessAwake(withIdentifier processIdentifier: pid_t) async {
        do {
            _ = try await dispatch(RuntimeInjection.StopKeepingProcessAwakeCommand(processIdentifier: processIdentifier))
        } catch {
            InjectionCommandLog.stopKeepingAwakeFailed(processIdentifier, error)
        }
    }
}

// `public import` because `pid_t` crosses the public API here, and this module
// builds with `InternalImportsByDefault` — a plain `import Foundation` would
// make `pid_t` internal to this file and the public methods below unspellable.
public import Foundation
// Re-exports OSToolbox, where the `#log` macro lives.
import FoundationToolbox
import RuntimeViewerCommunication

/// Log host for this file.
///
/// `RuntimeEngine` carries `@Loggable(.private)`, which scopes its `logger` to
/// the file that declares it — so `#log` cannot be used from an extension in
/// another file. Rather than widen that access, or hand-roll an `os.Logger`
/// against the project's convention, this file gets a logger of its own.
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

// MARK: - Injection

/// The commands that let a host act on the machine an engine belongs to rather
/// than on its own.
///
/// They are one feature in parts, and the split is deliberate:
/// ``RuntimeEngine/InjectionCapabilityRequest`` is cheap and answers a gate,
/// ``RuntimeEngine/ProcessListRequest`` is the expensive enumeration,
/// ``RuntimeEngine/InjectIntoProcessRequest`` is the act, and
/// ``RuntimeEngine/StopKeepingProcessAwakeRequest`` is how the host gives back
/// whatever the act had to hold. A host asks the first before offering the
/// others, so an unavailable peer is never enumerated.
///
/// All of them go through `registerSharedHandlers`, so `RuntimeEngineProxyServer`
/// forwards them for free. A mirrored engine therefore reports the capability of
/// the machine at the *far* end of the chain, which is the only answer that is
/// ever useful — no per-hop special casing is needed to get that.
extension RuntimeEngine {
    /// Whether the machine this engine belongs to can inject, and when not, why.
    ///
    /// Registered by **every** engine, not only ones that can inject. An engine
    /// that answers `unavailable` is still the one that has to answer, because
    /// it is the only party that knows its own platform and configuration.
    struct InjectionCapabilityRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.injectionCapability.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeInjectionAvailability {
            guard let injectionService = RuntimeEngine.injectionService else {
                return .withoutInjectionService
            }
            return await injectionService.injectionAvailability()
        }
    }

    /// The process table of the machine this engine belongs to.
    ///
    /// Never mixed with the asking host's own processes. Offering local pids for
    /// a remote machine would let a user pick a target on the wrong machine, and
    /// the two lists are not distinguishable once merged.
    struct ProcessListRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.processList.commandName }

        func perform(on engine: RuntimeEngine) async throws -> [RuntimeProcess] {
            guard let injectionService = RuntimeEngine.injectionService else { return [] }
            return try await injectionService.processList()
        }
    }

    /// The icons of a named set of application bundles on the machine this
    /// engine belongs to.
    ///
    /// Separate from ``RuntimeEngine/ProcessListRequest`` rather than folded
    /// into it, for two reasons that are both about what the list costs: the
    /// several processes of one application share one icon, and every caller
    /// that wants no icons keeps the list it has today.
    ///
    /// The host decides which bundles to ask about, from the
    /// ``RuntimeProcess/applicationBundlePath`` of the list it already has — so
    /// the paths in this request are always paths the far end itself reported.
    /// That does not make validating them unnecessary at the far end; see
    /// ``RuntimeInjectionService/applicationIcons(forBundlesAtPaths:)``.
    struct ApplicationIconsRequest: RuntimeEngineRequest {
        let applicationBundlePaths: [String]

        static var commandName: String { CommandNames.applicationIcons.commandName }

        func perform(on engine: RuntimeEngine) async throws -> [String: Data] {
            guard let injectionService = RuntimeEngine.injectionService else { return [:] }
            return await injectionService.applicationIcons(forBundlesAtPaths: applicationBundlePaths)
        }
    }

    /// Loads the payload into a process on the machine this engine belongs to.
    ///
    /// The response reports how it ended; it does not carry the injected
    /// engine's identity. The host learns that from the connection the payload
    /// makes — by claim token when it was given a rendezvous, and off the
    /// Bonjour advertisement when it was not — so an injection stays the same
    /// shape to the host however it was performed.
    struct InjectIntoProcessRequest: RuntimeEngineRequest {
        let processIdentifier: pid_t

        /// Where the payload should report in, and as what.
        ///
        /// Optional, and the absence is a real case rather than a default: it is
        /// what the simulator path sends, where the payload advertising itself
        /// works and is already verified. It is also the compatibility point in
        /// both directions — an injector built before this sends no such key and
        /// a peer built before this ignores one it does not know, so either
        /// mixture falls back to advertising instead of failing.
        let rendezvous: RuntimePayloadRendezvous?

        static var commandName: String { CommandNames.injectIntoProcess.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeProcessInjectionResult {
            guard let injectionService = RuntimeEngine.injectionService else {
                return .failed(
                    code: 0,
                    reason: "No injection service is registered in the process that owns this engine.",
                )
            }
            return await injectionService.inject(
                intoProcessWithIdentifier: processIdentifier,
                rendezvous: rendezvous,
            )
        }
    }

    /// Tells the machine this engine belongs to that an injected process no
    /// longer needs to be kept able to run.
    ///
    /// Returns nothing, and cannot report a failure, because there is nothing a
    /// caller could do about one: it is sent while tearing an engine down, and
    /// the machine releasing a little early or not at all is not a state the
    /// user can act on. What it *is* is the counterpart to the device holding a
    /// RunningBoard assertion across the whole life of an injected engine —
    /// without it, an injected app would stay awake until it exited.
    struct StopKeepingProcessAwakeRequest: RuntimeEngineRequest {
        let processIdentifier: pid_t

        static var commandName: String { CommandNames.stopKeepingProcessAwake.commandName }

        func perform(on engine: RuntimeEngine) async throws -> Bool {
            guard let injectionService = RuntimeEngine.injectionService else { return false }
            await injectionService.stopKeepingProcessAwake(withIdentifier: processIdentifier)
            return true
        }
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
    /// cannot inject.
    public func injectionAvailability() async -> RuntimeInjectionAvailability {
        do {
            return try await dispatch(InjectionCapabilityRequest())
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
        try await dispatch(ProcessListRequest())
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
            return try await dispatch(ApplicationIconsRequest(applicationBundlePaths: applicationBundlePaths))
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
            InjectIntoProcessRequest(
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
            _ = try await dispatch(StopKeepingProcessAwakeRequest(processIdentifier: processIdentifier))
        } catch {
            InjectionCommandLog.stopKeepingAwakeFailed(processIdentifier, error)
        }
    }
}

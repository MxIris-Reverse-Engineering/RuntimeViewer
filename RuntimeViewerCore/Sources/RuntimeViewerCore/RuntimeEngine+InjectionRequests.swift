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
}

// MARK: - Injection

/// The three commands that let a host act on the machine an engine belongs to
/// rather than on its own.
///
/// They are one feature in three parts, and the split is deliberate:
/// ``RuntimeEngine/InjectionCapabilityRequest`` is cheap and answers a gate,
/// ``RuntimeEngine/ProcessListRequest`` is the expensive enumeration, and
/// ``RuntimeEngine/InjectIntoProcessRequest`` is the act. A host asks the first
/// before offering the other two, so an unavailable peer is never enumerated.
///
/// All three go through `registerSharedHandlers`, so `RuntimeEngineProxyServer`
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

    /// Loads the payload into a process on the machine this engine belongs to.
    ///
    /// The response reports how it ended; it does not carry the injected
    /// engine's identity. The injected server announces itself over Bonjour and
    /// the host picks it up there, so an injection stays the same shape to the
    /// host however it was performed.
    struct InjectIntoProcessRequest: RuntimeEngineRequest {
        let processIdentifier: pid_t

        static var commandName: String { CommandNames.injectIntoProcess.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeProcessInjectionResult {
            guard let injectionService = RuntimeEngine.injectionService else {
                return .failed(
                    code: 0,
                    reason: "No injection service is registered in the process that owns this engine.",
                )
            }
            return await injectionService.inject(intoProcessWithIdentifier: processIdentifier)
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

    /// Loads the payload into a process on the machine this engine belongs to.
    ///
    /// Throwing and the returned result mean different things: a throw is the
    /// request not arriving, the result is the injection itself ending one way
    /// or another. Both reach the user, but only the second has a remedy worth
    /// naming.
    public func inject(intoProcessWithIdentifier processIdentifier: pid_t) async throws -> RuntimeProcessInjectionResult {
        try await dispatch(InjectIntoProcessRequest(processIdentifier: processIdentifier))
    }
}

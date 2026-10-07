// `public import` because `pid_t` crosses the public API here, and this module
// builds with `InternalImportsByDefault` — a plain `import Foundation` would
// make `pid_t` internal to this file and the public members below unspellable.
public import Foundation
import RuntimeViewerCore

// MARK: - Injection

/// The commands that let a host act on the machine an engine belongs to rather
/// than on its own.
///
/// They are one feature in parts, and the split is deliberate:
/// ``RuntimeInjection/InjectionCapabilityCommand`` is cheap and answers a gate,
/// ``RuntimeInjection/ProcessListCommand`` is the expensive enumeration,
/// ``RuntimeInjection/InjectIntoProcessCommand`` is the act, and
/// ``RuntimeInjection/StopKeepingProcessAwakeCommand`` is how the host gives
/// back whatever the act had to hold. A host asks the first before offering the
/// others, so an unavailable peer is never enumerated.
///
/// They are installed by ``RuntimeInjection/install(service:)`` as one command
/// extension, which every connection picks up — `RuntimeEngineProxyServer`
/// included, so it forwards them for free. A mirrored engine therefore reports
/// the capability of the machine at the *far* end of the chain, which is the
/// only answer that is ever useful — no per-hop special casing is needed to get
/// that.
///
/// Nested under ``RuntimeInjection`` rather than under `RuntimeEngine`: a module
/// filling Core's own type with nested types it does not own would, repeated a
/// few times, leave `RuntimeEngine`'s namespace full of other modules' things.
/// This is the first command extension, so it sets the shape for the next.
extension RuntimeInjection {
    /// Whether the machine this engine belongs to can inject, and when not, why.
    ///
    /// Registered by **every** engine, not only ones that can inject. An engine
    /// that answers `unavailable` is still the one that has to answer, because
    /// it is the only party that knows its own platform and configuration.
    struct InjectionCapabilityCommand: RuntimeEngineCommand {
        static var commandName: String { RuntimeEngine.CommandName.injectionCapability.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeInjectionAvailability {
            guard let injectionService = RuntimeInjection.service else {
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
    struct ProcessListCommand: RuntimeEngineCommand {
        static var commandName: String { RuntimeEngine.CommandName.processList.commandName }

        func perform(on engine: RuntimeEngine) async throws -> [RuntimeProcess] {
            guard let injectionService = RuntimeInjection.service else { return [] }
            return try await injectionService.processList()
        }
    }

    /// The icons of a named set of application bundles on the machine this
    /// engine belongs to.
    ///
    /// Separate from ``RuntimeInjection/ProcessListCommand`` rather than folded
    /// into it, for two reasons that are both about what the list costs: the
    /// several processes of one application share one icon, and every caller
    /// that wants no icons keeps the list it has today.
    ///
    /// The host decides which bundles to ask about, from the
    /// ``RuntimeProcess/applicationBundlePath`` of the list it already has — so
    /// the paths in this request are always paths the far end itself reported.
    /// That does not make validating them unnecessary at the far end; see
    /// ``RuntimeInjectionService/applicationIcons(forBundlesAtPaths:)``.
    struct ApplicationIconsCommand: RuntimeEngineCommand {
        let applicationBundlePaths: [String]

        static var commandName: String { RuntimeEngine.CommandName.applicationIcons.commandName }

        func perform(on engine: RuntimeEngine) async throws -> [String: Data] {
            guard let injectionService = RuntimeInjection.service else { return [:] }
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
    struct InjectIntoProcessCommand: RuntimeEngineCommand {
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

        static var commandName: String { RuntimeEngine.CommandName.injectIntoProcess.commandName }

        func perform(on engine: RuntimeEngine) async throws -> RuntimeProcessInjectionResult {
            guard let injectionService = RuntimeInjection.service else {
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
    struct StopKeepingProcessAwakeCommand: RuntimeEngineCommand {
        let processIdentifier: pid_t

        static var commandName: String { RuntimeEngine.CommandName.stopKeepingProcessAwake.commandName }

        func perform(on engine: RuntimeEngine) async throws -> Bool {
            guard let injectionService = RuntimeInjection.service else { return false }
            await injectionService.stopKeepingProcessAwake(withIdentifier: processIdentifier)
            return true
        }
    }
}

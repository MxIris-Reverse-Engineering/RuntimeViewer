#if os(macOS)
import Foundation
import RuntimeViewerCommunication
import RuntimeViewerHelperClient

/// Which engines may borrow the shared cache images My Mac and My Mac (Mac
/// Catalyst) keep: the ones whose process maps the cache this process maps.
///
/// The process is never asked. An injected payload of an earlier release,
/// reached over a Mach service, takes a command it does not know for its
/// client going away, and the kernel lets no other process read a target's
/// shared region. What decides the cache can be read from outside, though:
/// dyld picks the cache file by its own architecture, and dyld is arm64e for
/// every native process on Apple Silicon. So a process on this Mac maps this
/// process's cache unless it runs translated by Rosetta — the x86_64 cache —
/// or its environment points dyld at a private one.
///
/// Built from two probes so that the rules can be tested without the
/// processes they describe.
struct RuntimeSharedCacheEligibility: Sendable {
    /// Whether a process runs translated; `nil` when the kernel has no such
    /// process.
    var isTranslated: @Sendable (pid_t) -> Bool?

    /// A process's environment; `nil` when it cannot be read, which another
    /// user's process does not allow.
    var environment: @Sendable (pid_t) -> [String: String]?

    static let live = RuntimeSharedCacheEligibility(
        isTranslated: { ProcessTranslationProbe.isTranslated(processIdentifier: $0) },
        environment: { ProcessEnvironmentProbe.environment(ofProcess: $0) }
    )

    /// The variables that make dyld map a shared cache other than the
    /// system's, which only a developer sets.
    static let privateSharedCacheVariables = ["DYLD_SHARED_REGION", "DYLD_SHARED_CACHE_DIR"]

    /// Whether engines in this process can share its shared cache at all: on
    /// Apple Silicon, with this process running natively — an Intel Mac picks
    /// between two caches by CPU, and Rosetta maps the x86_64 one.
    func sharesThisProcessSharedCache() -> Bool {
        #if arch(arm64)
        isTranslated(getpid()) == false
        #else
        false
        #endif
    }

    /// Whether the engine on `source` serves a process attached on this Mac
    /// that maps this process's shared cache. A process whose environment
    /// cannot be read counts as mapping it: only a developer sets a private
    /// cache, and only for processes of their own.
    func isEligible(_ source: RuntimeSource) -> Bool {
        guard let processIdentifier = Self.attachedProcessIdentifier(of: source),
              isTranslated(processIdentifier) == false
        else { return false }
        if let environment = environment(processIdentifier),
           Self.privateSharedCacheVariables.contains(where: { environment[$0] != nil }) {
            return false
        }
        return true
    }

    /// The process identifier of a process attached on this Mac — injected
    /// and reached over its Mach service or a local socket — from its
    /// engine's source; `nil` for every other source, the Mac Catalyst
    /// helper's among them.
    static func attachedProcessIdentifier(of source: RuntimeSource) -> pid_t? {
        switch source {
        case .remote(_, let identifier, .client) where identifier != .macCatalyst,
             .localSocket(_, let identifier, .client):
            pid_t(identifier.rawValue)
        default:
            nil
        }
    }
}
#endif

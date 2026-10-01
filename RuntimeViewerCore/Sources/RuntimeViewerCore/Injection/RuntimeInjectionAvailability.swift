// Plain `import`: nothing here exposes a Foundation type publicly — unlike
// `RuntimeProcess` and `RuntimeInjectionService`, whose `pid_t` / `uid_t` do.
import Foundation

/// Whether the peer answering this can inject a payload into another process on
/// its own machine, and when it cannot, why.
///
/// Deliberately not a `Bool`. "This device runs the variant that cannot inject"
/// and "this platform has no such path at all" are different things to a user:
/// the first has a remedy, the second does not. A gate that can only say yes or
/// no cannot tell them apart, so the reason travels with the answer.
///
/// **Every engine answers this**, including ones whose injection targets are
/// processes on the host — a peer mirroring this engine asks it the same
/// question, and the answer it needs is about *this* machine.
public enum RuntimeInjectionAvailability: Codable, Hashable, Sendable {
    /// This machine can inject. Whether a *particular* target can be injected
    /// is a separate question, answered per process by
    /// ``RuntimeProcess/injectability``.
    case available

    /// iOS, running the variant without the injection entitlements: it can
    /// inspect its own process and nothing else.
    ///
    /// Distinct from ``unsupported(reason:)`` because it is the one unavailable
    /// case with an action attached — install the variant that can.
    case requiresJailbrokenVariant

    /// macOS, where injection goes through a privileged helper daemon that is
    /// not installed yet.
    case helperDaemonNotInstalled

    /// No injection path exists here. The reason is written to be shown to the
    /// user verbatim, so it must name the actual obstacle rather than restate
    /// the case.
    case unsupported(reason: String)

    public var isAvailable: Bool {
        switch self {
        case .available:
            return true
        case .requiresJailbrokenVariant,
             .helperDaemonNotInstalled,
             .unsupported:
            return false
        }
    }
}

extension RuntimeInjectionAvailability {
    /// What a process that registered no ``RuntimeInjectionService`` answers.
    ///
    /// The platforms differ in what "no service" *means*, which is why this is
    /// not one constant:
    ///
    /// - On iOS it is the expected state of the variant that ships without the
    ///   injection entitlements. That variant registers no service precisely
    ///   because it has no path, so the answer carries the remedy.
    /// - On macOS and Mac Catalyst the app always registers a service, and that
    ///   service reports ``helperDaemonNotInstalled`` itself when the daemon is
    ///   missing. Reaching this value there means nobody wired the service up —
    ///   a programming error, reported as such rather than mislabelled as a
    ///   missing daemon, which would send the user to reinstall something that
    ///   would not help.
    /// - Everywhere else there is genuinely no implementation.
    public static var withoutInjectionService: RuntimeInjectionAvailability {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return .unsupported(reason: "No injection service is registered in this process.")
        #elseif os(iOS)
        return .requiresJailbrokenVariant
        #else
        return .unsupported(reason: "Runtime Viewer does not implement process injection on this platform.")
        #endif
    }
}

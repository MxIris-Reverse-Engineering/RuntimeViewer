public import Foundation

/// A process on the machine whose engine answered the request.
///
/// **Filled in by that machine, injectability included.** Only it knows its own
/// uid, its entitlements and its daemon state, so a host that worked the answer
/// out itself would offer targets that are certain to fail — and, worse, would
/// offer them for the wrong machine the moment the selected engine is not the
/// local one.
public struct RuntimeProcess: Codable, Hashable, Sendable {
    /// Whether the machine that listed this process can inject into it.
    public enum Injectability: Codable, Hashable, Sendable {
        /// Nothing the lister could check rules this target out. **Not a
        /// promise** — it is also what an unknown ``userIdentifier`` produces,
        /// because pre-screening is an optimization that keeps doomed targets
        /// out of the picker, not a correctness gate. The injection attempt
        /// returns the real answer either way.
        case injectable

        /// The target runs as root and the injector does not.
        ///
        /// Measured: a uid 501 app cannot obtain the task port of a uid 0
        /// process no matter which entitlements it carries. Covering root
        /// targets needs an injector running as root, which is a separate
        /// piece of work.
        case requiresRootOnTarget

        /// Anything else, with a reason fit to show the user verbatim.
        ///
        /// Processes that cannot be injected are still listed: hiding them
        /// leaves "why can I not see it?" unanswerable.
        case notInjectable(reason: String)

        public var isInjectable: Bool {
            switch self {
            case .injectable:
                return true
            case .requiresRootOnTarget,
                 .notInjectable:
                return false
            }
        }
    }

    public let processIdentifier: pid_t
    public let name: String

    /// The executable's path, when the lister could read it. `nil` means
    /// "could not tell", not "none" — a process whose path is unreadable can
    /// still be a valid target.
    public let executablePath: String?

    /// The owning uid, when the lister could read it.
    ///
    /// Optional for the same reason ``executablePath`` is: "could not tell" is a
    /// real state. On iOS it comes from `sysctl(KERN_PROC_PID)` — `libproc`'s
    /// `proc_pidinfo` route needs `struct proc_bsdinfo`, and `<sys/proc_info.h>`
    /// is absent from the iOS SDK, while `<sys/sysctl.h>` ships with
    /// `struct kinfo_proc` — and whether that call is permitted to every
    /// unsandboxed process on every jailbroken device is **not** measured.
    ///
    /// A `nil` here must not be read as "not injectable". It means the lister
    /// could not pre-screen this target, so the injection attempt is the
    /// authority — see ``Injectability/injectable``.
    public let userIdentifier: uid_t?

    /// The app bundle this process belongs to, when it belongs to one.
    ///
    /// `nil` for every daemon, which is most of a device's process table. An app
    /// extension reports its *host* app's bundle rather than its own `.appex`,
    /// because the `.appex` carries no icon of its own.
    ///
    /// **A path, not the icon.** The icon is fetched separately, by bundle, so
    /// that the several processes of one app cost one icon between them and the
    /// process list itself stays as cheap as it was — see
    /// ``RuntimeInjectionService/applicationIcons(forBundlesAtPaths:)``.
    ///
    /// Optional for the compatibility it buys as much as for the daemons: a
    /// lister built before this change omits the key, the synthesized decoder
    /// reads that as `nil`, and the host asks for no icons instead of failing
    /// to decode the list.
    public let applicationBundlePath: String?

    public let injectability: Injectability

    public init(
        processIdentifier: pid_t,
        name: String,
        executablePath: String?,
        userIdentifier: uid_t?,
        applicationBundlePath: String?,
        injectability: Injectability,
    ) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.executablePath = executablePath
        self.userIdentifier = userIdentifier
        self.applicationBundlePath = applicationBundlePath
        self.injectability = injectability
    }
}

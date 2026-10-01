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

    public let userIdentifier: uid_t
    public let injectability: Injectability

    public init(
        processIdentifier: pid_t,
        name: String,
        executablePath: String?,
        userIdentifier: uid_t,
        injectability: Injectability,
    ) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.executablePath = executablePath
        self.userIdentifier = userIdentifier
        self.injectability = injectability
    }
}

/// How an injection attempt ended.
///
/// A response rather than a thrown error, on purpose. The two failures a caller
/// acts on differently — no task port versus the target declining the image —
/// have to survive the wire, and an `NSError`'s `userInfo` does not cross XPC
/// (MachInjector's proposal 0002 documents that loss, which is why its own error
/// codes exist).
public enum RuntimeProcessInjectionResult: Codable, Hashable, Sendable {
    /// The payload is loaded. The injected server advertises itself over
    /// Bonjour; the host discovers it there rather than being told here, so
    /// that an injection performed by any means looks the same to the host.
    case injected

    /// `task_for_pid` was refused, or the target was already gone
    /// (MachInjector `MIMachInjectorErrorTaskPortUnavailable`, 3).
    ///
    /// **Confirm the target is still alive before reading this as a permission
    /// problem.** That exact misdiagnosis has been made here once: an injection
    /// failure blamed on uid turned out to be a process that had exited, and
    /// only a control attempt returning a *different* code exposed it.
    case taskPortUnavailable(reason: String)

    /// The injection mechanism worked and the target's `dlopen` declined the
    /// image (MachInjector `MIMachInjectorErrorTargetRefusedToLoadDylib`, 18).
    /// Usually a code-signing or library-validation refusal, which no amount of
    /// retrying changes.
    case targetRefusedPayload(reason: String)

    /// Any other failure, carrying the injector's own code verbatim so the
    /// published enumeration stays the authority on what it means.
    case failed(code: Int, reason: String)

    public var isInjected: Bool {
        switch self {
        case .injected:
            return true
        case .taskPortUnavailable,
             .targetRefusedPayload,
             .failed:
            return false
        }
    }
}

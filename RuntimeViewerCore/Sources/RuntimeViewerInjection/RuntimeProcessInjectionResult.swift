import Foundation

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

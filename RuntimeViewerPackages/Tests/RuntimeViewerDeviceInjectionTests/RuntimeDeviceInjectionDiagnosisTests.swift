import Testing
import Foundation
@testable import RuntimeViewerDeviceInjection

/// What a failed injection tells the user.
///
/// History, in two steps. A target that was merely suspended first reported
/// MachInjector's own `injection timed out` and nothing else — measured, the
/// most common failure on a device, because iOS suspends every app that is not
/// in the foreground — and the message named neither the cause nor anything the
/// user could do, so the only reading available was "it is broken". The wording
/// was then written to explain suspension and to say what to do about it.
///
/// Suspension is now prevented outright: the injection takes a RunningBoard
/// assertion on the target and confirms it is running before loading anything.
/// So the advice that message carried is the thing this code now does for the
/// user, and repeating it would send them off to do it again by hand. These
/// tests pin the message to its *current* job — ruling suspension out and
/// naming what is left.
@Suite("Device injection diagnosis")
struct RuntimeDeviceInjectionDiagnosisTests {
    @Test("The timeout says what is unknown, and rules suspension out rather than blaming it")
    func timedOutReasonRulesOutSuspension() {
        let reason = RuntimeDeviceInjectionDiagnosis.timedOutReason
        // It must not claim the payload loaded. A timeout means the target
        // reported nothing, so whether it loaded is precisely what is unknown —
        // measured on `backboardd`, where it had not.
        #expect(reason.lowercased().contains("unknown"))
        #expect(reason.lowercased().contains("suspend"))
        // It must not read as the bare restatement it replaced.
        #expect(reason != "injection timed out")
        #expect(reason.count > 100)
    }

    /// The regression this guards is a stale instruction, which is worse than a
    /// vague one: it sends the user to the device to bring a target forward,
    /// when the code has already held that target awake and verified it. Should
    /// the assertion ever be removed, this test is the reminder that the
    /// wording has to come back with it.
    @Test("The timeout no longer tells the user to bring the target to the foreground")
    func timedOutReasonDoesNotAskForTheForeground() {
        let reason = RuntimeDeviceInjectionDiagnosis.timedOutReason.lowercased()
        #expect(!reason.contains("foreground"))
        #expect(!reason.contains("try again"))
    }

    /// Whatever else it says, it has to point somewhere the user can look. The
    /// two places that have ever answered this are the device log and the
    /// target's resident memory.
    @Test("The timeout names somewhere to look")
    func timedOutReasonNamesEvidence() {
        let reason = RuntimeDeviceInjectionDiagnosis.timedOutReason.lowercased()
        #expect(reason.contains("log"))
        #expect(reason.contains("memory"))
    }

    /// Ruling suspension out and *claiming to have confirmed* the target was
    /// running are different statements, and only the first one is earned.
    ///
    /// The check before the injection rejects `.suspended` and lets
    /// `.unknown` through — deliberately, because asking RunningBoard about
    /// another process needs `com.apple.runningboard.process-state` and a build
    /// without it reads as `.unknown` for every target, so refusing on
    /// `.unknown` would make such a build unable to inject anything while the
    /// injection itself does not need that answer. The consequence is that the
    /// state may never have been read at all, and a message asserting the
    /// target "was confirmed to be running" then sends the user looking at the
    /// payload and the target for a cause that may well be suspension.
    @Test("The timeout does not claim a running state it may never have read")
    func timedOutReasonDoesNotOverstateWhatWasChecked() {
        let reason = RuntimeDeviceInjectionDiagnosis.timedOutReason.lowercased()
        #expect(!reason.contains("confirmed"))
        #expect(!reason.contains("is not the explanation"))
        // What *is* earned: the assertion is held for the whole injection.
        #expect(reason.contains("held"))
    }
}

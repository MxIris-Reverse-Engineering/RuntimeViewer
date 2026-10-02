import Testing
import Foundation
@testable import RuntimeViewerDeviceInjection

/// What a failed injection tells the user.
///
/// History: a target that was merely suspended reported MachInjector's own
/// `injection timed out` and nothing else. Measured, that is the most common
/// failure on a device — iOS suspends every app that is not in the foreground —
/// and the message named neither the cause nor anything the user could do, so
/// the only reading available was "it is broken".
@Suite("Device injection diagnosis")
struct RuntimeDeviceInjectionDiagnosisTests {
    @Test("The timeout says the target was probably not running, and what to do")
    func timedOutReasonExplainsSuspension() {
        let reason = RuntimeDeviceInjectionDiagnosis.timedOutReason
        #expect(reason.lowercased().contains("suspend"))
        #expect(reason.lowercased().contains("foreground"))
        // It must not read as the bare restatement it replaced.
        #expect(reason != "injection timed out")
        #expect(reason.count > 100)
    }

    /// A daemon is never suspended, so the suspension explanation would be a
    /// dead end for exactly the targets this feature is most used on. The
    /// message has to say where to look instead.
    @Test("The timeout also covers the target that cannot have been suspended")
    func timedOutReasonCoversDaemons() {
        let reason = RuntimeDeviceInjectionDiagnosis.timedOutReason
        #expect(reason.lowercased().contains("daemon"))
        #expect(reason.lowercased().contains("log"))
    }
}

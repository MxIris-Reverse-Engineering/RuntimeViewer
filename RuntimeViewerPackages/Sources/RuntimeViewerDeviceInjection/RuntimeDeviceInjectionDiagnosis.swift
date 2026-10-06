import Foundation

/// What the injector's terse codes mean, in words meant to be read as-is.
///
/// Not gated on iOS although only the device injection service uses it, for the
/// same reason `RuntimePayloadStaging` is not: these strings are what a user
/// sees when an injection fails, and a wrong one sends them off to fix something
/// that is not broken. On this side of the gate they can be pinned by tests on
/// the platform that has a test runner.
public enum RuntimeDeviceInjectionDiagnosis {
    /// What MachInjector's own words — "injection timed out" — leave out.
    ///
    /// The injector creates a mach thread in the target and waits for it to
    /// report what its `dlopen` did. A suspended process has no thread
    /// scheduled, so that report never comes however long the wait is, and
    /// widening the wait does not help.
    ///
    /// **That used to be the whole message, and it no longer is.** Suspension
    /// was by far the most common cause — iOS suspends every app that is not in
    /// the foreground — so the wording told the user to bring the target
    /// forward. The injection now takes a RunningBoard assertion on the target
    /// first, and the two ways *that* can fail say so in their own words, so
    /// repeating the old advice would send the user to do something that has
    /// already been done for them.
    ///
    /// **It does not say the target was confirmed to be running, because that
    /// is not always established.** The check before the injection refuses a
    /// target RunningBoard reports as suspended and lets
    /// ``RuntimeDeviceRunningState/unknown(reason:)`` through — asking about
    /// another process needs `com.apple.runningboard.process-state`, so a build
    /// without that entitlement reads as `.unknown` for every target, and
    /// refusing on it would leave such a build unable to inject anything even
    /// though the injection does not need the answer. So the assertion being
    /// held is the earned claim; the state having been read is not, and
    /// asserting it would send the user hunting in the payload and the target
    /// for a cause that may be suspension after all.
    public static let timedOutReason = """
        The thread that loads the payload never reported what happened, so whether the payload loaded at all is unknown.

        An assertion asking the system to keep the target running is held for as long as the injection lasts, and the target was not reported suspended when it started — though on a build that cannot read another process's run state, that is unknown rather than ruled out. Three things could explain the silence.

        The target may have been suspended anyway, which is what this looks like when the run state could not be read: a suspended process schedules no thread, so the report never comes however long the wait.

        The payload may have failed to start: look in the device's log for its startup lines around the moment of the injection.

        Or the target may be refusing to load it without reporting why. That is measured behaviour on backboardd, where the injection reports success, the payload never runs, and the target's resident memory does not move — the most reliable signal here, because a loaded payload adds 15 to 25 MB.
        """
}

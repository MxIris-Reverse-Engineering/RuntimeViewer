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
    /// scheduled, so that report never comes however long the wait is: measured
    /// on iOS apps sitting in jetsam band 0 with near-zero CPU, which is the
    /// ordinary state of a backgrounded app. Widening the wait does not help,
    /// which is why the wording was fixed instead.
    public static let timedOutReason = """
        The thread that loads the payload never reported what happened, so whether the payload loaded at all is unknown.

        On a device this almost always means the target was not running. iOS suspends an app that is not in the foreground, and a suspended process has no thread scheduled to run the injected code in — the wait cannot succeed however long it is. Bring the target to the foreground on the device and try again.

        A daemon, which is never suspended this way, failing here instead points at the payload itself: check the device's log for its startup lines.
        """
}

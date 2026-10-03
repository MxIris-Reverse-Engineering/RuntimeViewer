import Foundation
import FoundationToolbox

#if RUNTIME_VIEWER_JAILBROKEN
import RuntimeViewerDeviceInjection
#endif

/// Stops iOS suspending this process when it leaves the foreground, in the
/// variant that is allowed to ask.
///
/// Why it is wanted: iOS suspends an app within about a second of it leaving
/// the foreground (measured: `running-suspended`, jetsam priority down to 0),
/// and a suspended app answers nothing. Without this, every attach from the Mac
/// requires the variant to be the app on the device's screen first — the Mac's
/// window focus has nothing to do with it, so the user has to go and bring it
/// forward by hand before each one.
///
/// **Already-injected targets never needed this.** The payload lives in the
/// target process and keeps its own connection to the Mac, so it is unaffected
/// by this app being suspended; what was unavailable while suspended was
/// serving *new* requests.
///
/// Held for the process's whole life, with no switch. The variant is a
/// debugging tool rather than something to live on a phone, so there is nothing
/// to save by giving it back — and "when exactly is it on" is its own category
/// of bug, which not having a condition removes entirely.
///
/// Like `InjectionServiceRegistrar`, the whole body is behind
/// `RUNTIME_VIEWER_JAILBROKEN` and the file is in the group all three app
/// targets share, so an ordinary build compiles it to nothing.
@Loggable
enum SuspensionPreventionRegistrar {
    #if RUNTIME_VIEWER_JAILBROKEN
    /// Keeps the assertion alive for the life of the process.
    ///
    /// The promise *is* this reference: RunningBoard gives an assertion back
    /// when the object holding it goes away, so a local variable here would
    /// have ended the exemption on the next line.
    private static var assertion: RuntimeDeviceSuspensionAssertion?
    #endif

    static func registerIfAvailable() {
        #if RUNTIME_VIEWER_JAILBROKEN
        do {
            assertion = try RuntimeDeviceSuspensionAssertion.preventingSuspension(
                ofProcessWithIdentifier: getpid(),
                explanation: "Runtime Viewer serves process inspection requests from a host Mac",
            )
            #log(.info, "Holding a RunningBoard assertion against suspension; this variant will keep answering in the background")
        } catch {
            // Degraded, not fatal, and deliberately not an alert. Everything
            // that worked before this existed still works — the user just has
            // to bring the app to the foreground on the device before
            // attaching, which is what the guide used to require of them.
            switch error {
            case .refused(let reason):
                #log(
                    .error,
                    "Not allowed to prevent suspension, so this variant will stop answering when it leaves the foreground; it needs com.apple.runningboard.primitiveattribute. RunningBoard said: \(reason, privacy: .public)"
                )
            case .runningBoardUnavailable(let reason):
                #log(
                    .error,
                    "Could not reach RunningBoard to prevent suspension, so the interface this was built against is not the one on this device: \(reason, privacy: .public)"
                )
            }
        }
        #endif
    }
}

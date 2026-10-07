public import Foundation
import RuntimeViewerRunningBoardSupport

/// Something that is keeping one process awake for as long as it is alive.
///
/// Exists so `RuntimeDeviceSuspensionController` can be driven by a test
/// double: the controller owns the reference counting, which is where the bugs
/// are, and should not need a real RunningBoard to be tested.
public protocol RuntimeDeviceSuspensionAssertionHolding: AnyObject {
    /// Gives the promise back ahead of deallocation. Calling it twice is fine.
    func invalidate()
}

/// A held promise that RunningBoard will not suspend one process.
///
/// **Its lifetime is the promise.** RunningBoard invalidates an assertion when
/// the object that acquired it goes away, so holding this value is what keeps
/// the target awake and releasing it is what lets the target be suspended
/// again. There is no separate release step to forget — but equally, dropping
/// this on the floor silently un-does the whole thing.
///
/// Why any of this is necessary: iOS suspends a process that is not in the
/// foreground within about a second, and a suspended process has no thread
/// scheduled to run injected code in, so an injection into one waits out its
/// whole verdict budget and then reports a timeout. Measured, plus the gate
/// each call below passes through:
/// `Documentations/Evolutions/draft-device-process-assertions.md`.
public final class RuntimeDeviceSuspensionAssertion: RuntimeDeviceSuspensionAssertionHolding {
    /// Why an assertion could not be had.
    ///
    /// The two cases are kept apart because they call for opposite actions, and
    /// conflating them would produce a confidently wrong instruction. Every
    /// measurement behind this file was taken on iOS 26.3.1 while the device
    /// this runs on is 26.6.2, so "the interface moved" is a real possibility
    /// and must not be reported as "you need to reinstall with more
    /// entitlements".
    public enum AcquisitionFailure: Error, Equatable {
        /// `RunningBoardServices` is absent, or present without the interface
        /// this was built against. Nothing the user can grant fixes it.
        case runningBoardUnavailable(reason: String)

        /// RunningBoard was reached and said no. `reason` carries its own
        /// words, which name the missing entitlement when that is the cause.
        case refused(reason: String)
    }

    private let assertion: any RuntimeViewerRunningBoardAssertion

    private init(assertion: any RuntimeViewerRunningBoardAssertion) {
        self.assertion = assertion
    }

    /// Acquires an assertion that stops the given process being suspended.
    ///
    /// - Parameter processIdentifier: the process to keep awake. This process's
    ///   own identifier is supported and is how the variant keeps itself alive
    ///   in the background.
    /// - Parameter explanation: appears in RunningBoard's state dumps, so it
    ///   should name this application and what it is doing.
    public static func preventingSuspension(
        ofProcessWithIdentifier processIdentifier: pid_t,
        explanation: String,
    ) throws(AcquisitionFailure) -> RuntimeDeviceSuspensionAssertion {
        var constructionError: NSError?
        guard let assertion = RuntimeViewerRunningBoardMakeSuspensionPreventingAssertion(
            processIdentifier,
            explanation,
            &constructionError,
        ) else {
            // Construction only fails over the framework or the interface;
            // a refusal happens at acquisition, below.
            throw .runningBoardUnavailable(
                reason: constructionError?.localizedFailureReason
                    ?? constructionError?.localizedDescription
                    ?? "RunningBoard gave no reason.",
            )
        }

        do {
            // `acquireWithError:` arrives in Swift as a throwing call, so the
            // refusal comes back as an error rather than a false return.
            try assertion.acquire()
        } catch {
            let acquisitionError = error as NSError
            throw .refused(
                reason: acquisitionError.localizedFailureReason
                    ?? acquisitionError.localizedDescription,
            )
        }
        return RuntimeDeviceSuspensionAssertion(assertion: assertion)
    }

    public func invalidate() {
        assertion.invalidate()
    }

    deinit {
        // RunningBoard would drop it anyway once the object is gone, but saying
        // so explicitly means the promise ends at a point in the code rather
        // than whenever the last reference happens to go.
        assertion.invalidate()
    }
}

/// Whether RunningBoard considers a process able to run code right now.
public enum RuntimeDeviceRunningState: Equatable, Sendable {
    /// Scheduled: injected code in it will run.
    case running

    /// Suspended: no thread is scheduled, so injected code in it will not run
    /// and anything waiting for it to report will wait forever.
    case suspended

    /// RunningBoard could not be asked.
    ///
    /// **Not a synonym for suspended.** Asking about another process needs
    /// `com.apple.runningboard.process-state`, so a build without that
    /// entitlement lands here for every target — and reporting that as
    /// "suspended" would blame the target for a permission problem.
    case unknown(reason: String)

    /// RunningBoard's answer for one process.
    public static func ofProcess(withIdentifier processIdentifier: pid_t) -> RuntimeDeviceRunningState {
        var error: NSError?
        switch RuntimeViewerRunningBoardRunningStateOfProcess(processIdentifier, &error) {
        case .running:
            return .running
        case .suspended:
            return .suspended
        default:
            return .unknown(
                reason: error?.localizedFailureReason
                    ?? error?.localizedDescription
                    ?? "RunningBoard did not answer.",
            )
        }
    }
}

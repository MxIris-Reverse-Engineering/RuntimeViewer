#if os(iOS) && !targetEnvironment(macCatalyst)

public import Foundation
public import RuntimeViewerCore
import MachInjector

/// Injection performed from inside the device, in this process.
///
/// The macOS counterpart (`RuntimeViewerHelperClient`) delegates to a
/// privileged helper daemon, because a Mac app cannot take another process's
/// task port. On iOS an app that has escaped its sandbox can, so there is no
/// daemon, no XPC and no installation step — measured, and the reason this
/// module is a fraction of the size of its macOS sibling.
///
/// What the hosting app must carry, all three of them, and all three of which a
/// jailbreak installer grants as a matter of course:
///
/// ```xml
/// <key>com.apple.private.security.no-sandbox</key><true/>
/// <key>com.apple.private.security.no-container</key><true/>
/// <key>task_for_pid-allow</key><true/>
/// ```
///
/// The split between them is not cosmetic. The sandbox escape is what makes
/// *listing* possible at all — a containerized process gets `EPERM` from
/// `proc_listallpids` however it is otherwise entitled — and
/// `task_for_pid-allow` is what makes *injecting* possible on top of that.
/// Measured: Apple's own `com.apple.system-task-ports` and
/// `platform-application` do **not** substitute for the last one.
public final class RuntimeDeviceInjectionService: RuntimeInjectionService {
    /// Where the payload is copied before injection, and what goes with it.
    private let staging: RuntimePayloadStaging

    private let fileManager: FileManager

    /// Keeps the targets awake for as long as the host still needs them.
    ///
    /// Owned here rather than passed in because the lifetime it manages is
    /// exactly this service's: a target is kept awake from the injection until
    /// the host tears the resulting engine down. See
    /// ``RuntimeDeviceSuspensionController``.
    private let suspensionController: RuntimeDeviceSuspensionController

    public init(
        payloadURL: URL,
        dependencyDirectoryURL: URL,
        stagingDirectoryURL: URL = URL(fileURLWithPath: "/private/var/tmp/RuntimeViewerPayload", isDirectory: true),
        fileManager: FileManager = .default,
        suspensionController: RuntimeDeviceSuspensionController = RuntimeDeviceSuspensionController(),
    ) {
        self.suspensionController = suspensionController
        self.staging = RuntimePayloadStaging(
            payloadURL: payloadURL,
            dependencyDirectoryURL: dependencyDirectoryURL,
            stagingDirectoryURL: stagingDirectoryURL,
            fileManager: fileManager,
        )
        self.fileManager = fileManager
    }

    // MARK: - RuntimeInjectionService

    /// Probes the one capability that can be probed without a target.
    ///
    /// Listing processes is the measured proxy for the sandbox escape, and it
    /// costs one syscall. `task_for_pid-allow` cannot be probed the same way —
    /// confirming it needs a live target to take the port of — so a process
    /// that can list is reported as available and a missing task-port
    /// entitlement surfaces as `taskPortUnavailable` on the first attempt.
    /// Claiming unavailability we have not established would be worse: it
    /// disables the feature on a device where it may well work.
    public func injectionAvailability() async -> RuntimeInjectionAvailability {
        // A variant with the right entitlements and no payload can list and
        // not inject, which is its own failure and not the one below. Said
        // plainly rather than folded into the entitlement message, which would
        // send someone to reinstall over a build-phase problem.
        guard fileManager.fileExists(atPath: staging.payloadURL.path) else {
            return .unsupported(
                reason: "This build is missing the runtime server payload it would inject, so it has nothing to load into another process.",
            )
        }
        do {
            _ = try RuntimeDeviceProcessEnumerator.processIdentifiers()
            return .available
        } catch {
            return .unsupported(
                reason: """
                This build cannot list other processes, which means it is still \
                confined to its container. Injection needs an install that \
                grants no-sandbox, no-container and task_for_pid-allow.
                """,
            )
        }
    }

    public func processList() async throws -> [RuntimeProcess] {
        try RuntimeDeviceProcessEnumerator.processList(injectorUserIdentifier: getuid())
    }

    public func inject(
        intoProcessWithIdentifier processIdentifier: pid_t,
        rendezvous: RuntimePayloadRendezvous?,
    ) async -> RuntimeProcessInjectionResult {
        // Confirm the target is alive first. Without this a target that exited
        // between being listed and being picked fails with the same code as a
        // permission problem, and that ambiguity has already cost one wrong
        // conclusion: an injection failure read as a uid restriction turned out
        // to be a process that had gone, and only a control attempt returning a
        // *different* code exposed it.
        guard isAlive(processIdentifier: processIdentifier) else {
            return .failed(
                code: 0,
                reason: "Process \(processIdentifier) is no longer running.",
            )
        }

        let stagedURL: URL
        do {
            stagedURL = try staging.stage(rendezvous: rendezvous)
        } catch {
            return .failed(code: 0, reason: "Could not stage the payload: \(error.localizedDescription)")
        }

        // Keeping the target awake comes before injecting, because a suspended
        // target has no thread to run the injected code in: the injector would
        // create its mach thread, wait out the whole verdict budget and report
        // a timeout. Measured on every app target, which is why injecting an
        // app was impossible before this.
        do {
            try suspensionController.retainAwake(
                processWithIdentifier: processIdentifier,
                explanation: "Runtime Viewer is inspecting this process",
            )
        } catch {
            return .failed(code: 0, reason: Self.reason(forSuspensionFailure: error))
        }

        // Only worth checking once the assertion is held: before that every
        // backgrounded app reads as suspended, which says nothing.
        if case .suspended = RuntimeDeviceRunningState.ofProcess(withIdentifier: processIdentifier) {
            suspensionController.releaseAwake(processWithIdentifier: processIdentifier)
            return .failed(code: 0, reason: Self.stillSuspendedReason)
        }

        do {
            let injection = try await MachInjectorAsync.inject(
                pid: processIdentifier,
                dylibPath: stagedURL.path,
                timeout: Self.verdictTimeout,
            )
            guard injection.success else {
                // Rolled back: nothing came of the injection, so nothing needs
                // this target awake. Leaving it held would keep an app running
                // in the background with no engine to show for it.
                suspensionController.releaseAwake(processWithIdentifier: processIdentifier)
                return result(for: injection.error as NSError?, remoteMessage: injection.remoteErrorMessage)
            }
            // Deliberately *not* released on success: the reference is handed
            // over to the engine's lifetime and given back by
            // `stopKeepingProcessAwake(withIdentifier:)`.
            return .injected
        } catch let error as NSError {
            suspensionController.releaseAwake(processWithIdentifier: processIdentifier)
            return result(for: error, remoteMessage: error.userInfo[MachInjector.remoteErrorMessageKey] as? String)
        }
    }

    public func stopKeepingProcessAwake(withIdentifier processIdentifier: pid_t) async {
        suspensionController.releaseAwake(processWithIdentifier: processIdentifier)
    }

    /// What a failed assertion means, in the words the two causes deserve.
    ///
    /// The distinction is the whole point: this build's measurements come from
    /// iOS 26.3.1, so "the interface moved" is a real possibility, and
    /// reporting it as a missing entitlement would send the user to reinstall
    /// over something a reinstall cannot fix.
    private static func reason(forSuspensionFailure error: any Error) -> String {
        guard let failure = error as? RuntimeDeviceSuspensionAssertion.AcquisitionFailure else {
            return "Could not keep the target running long enough to inject into it: \(error.localizedDescription)"
        }
        switch failure {
        case .refused(let reason):
            return """
                This build is not allowed to stop the target being suspended, and a suspended process \
                cannot run the injected code.

                Keeping another process awake needs the com.apple.runningboard.process-state \
                entitlement, which this install does not grant. Daemons are unaffected — the system \
                does not suspend them — so this only blocks app targets.

                RunningBoard said: \(reason)
                """
        case .runningBoardUnavailable(let reason):
            return """
                Could not reach the system service that decides whether a process may run, so there is no \
                way to stop the target being suspended.

                This is not a permissions problem and reinstalling will not fix it: the interface this was \
                built against is not the one on this device.

                Details: \(reason)
                """
        }
    }

    /// Held the assertion and the target is *still* suspended.
    ///
    /// Worth failing early on rather than injecting anyway: the injection would
    /// wait out its whole verdict budget and then report a timeout, which says
    /// nothing about why.
    private static let stillSuspendedReason = """
        The target is still suspended after being told to stay running, so the injected code would have \
        no thread to run in.

        This is unexpected: holding a CPU-access assertion is what stops a process being suspended. Either \
        something else is holding the target suspended, or the assertion was not honoured.
        """

    /// How long to wait for the target to report what its `dlopen` did.
    ///
    /// The asynchronous injector waits on a mach port in the target rather than
    /// polling a fixed budget, so this is a real deadline rather than a race:
    /// the verdict arrives when it arrives, and only a target that never
    /// produces one costs the whole wait.
    ///
    /// Generous on purpose. The payload is an 81 MB image and `dlopen` of it is
    /// not instant, and the failure this exists to catch — measured on
    /// `backboardd` — is a load that reports *nothing*. The synchronous path
    /// polled for a verdict and reported success when none arrived in time,
    /// which is how an injection that never loaded anything was reported to the
    /// host as having worked.
    ///
    /// The cost is paid only by targets that never report: a suspended app now
    /// takes this long to say so, where it used to say it in 210 ms and say it
    /// about the wrong thing.
    private static let verdictTimeout: TimeInterval = 20

    private func isAlive(processIdentifier: pid_t) -> Bool {
        // Signal 0 performs the permission and existence checks and delivers
        // nothing. EPERM means it exists and belongs to someone else, which is
        // still alive; only ESRCH means gone.
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Error mapping

    /// Maps MachInjector's published codes onto the outcomes a caller acts on
    /// differently, passing anything else through verbatim.
    ///
    /// Only these are singled out, because only these have distinct remedies:
    /// no task port means the entitlements or the target's uid, a refused image
    /// means code signing and will not change on a retry, and a timeout means
    /// the target was almost certainly not running.
    private func result(for error: NSError?, remoteMessage: String?) -> RuntimeProcessInjectionResult {
        guard let error else {
            // A result that is neither a success nor an error. Reported rather
            // than mapped to anything, because inventing a cause here is what
            // the synchronous path did and why `backboardd` looked like it
            // worked.
            return .failed(
                code: 0,
                reason: remoteMessage ?? "The injector reported neither success nor a reason.",
            )
        }
        // Both dlopen paths publish the same codes with the same meanings —
        // their own headers say so — so one mapping serves both domains.
        guard error.domain == MachInjector.errorDomain || error.domain == MachInjectorAsync.errorDomain else {
            return .failed(code: error.code, reason: error.localizedDescription)
        }

        switch error.code {
        case MachInjector.Error.taskPortUnavailable.rawValue:
            return .taskPortUnavailable(reason: remoteMessage ?? error.localizedDescription)
        case MachInjector.Error.targetRefusedToLoadDylib.rawValue:
            return .targetRefusedPayload(reason: remoteMessage ?? error.localizedDescription)
        case MachInjector.Error.timedOut.rawValue:
            // The code stays `MachInjector`'s; only the wording is ours, and it
            // lives outside this file's platform gate so a test can pin it.
            return .failed(code: error.code, reason: RuntimeDeviceInjectionDiagnosis.timedOutReason)
        default:
            return .failed(code: error.code, reason: remoteMessage ?? error.localizedDescription)
        }
    }
}

#endif

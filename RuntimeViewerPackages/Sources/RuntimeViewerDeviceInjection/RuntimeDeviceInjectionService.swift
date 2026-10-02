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

    public init(
        payloadURL: URL,
        dependencyDirectoryURL: URL,
        stagingDirectoryURL: URL = URL(fileURLWithPath: "/private/var/tmp/RuntimeViewerPayload", isDirectory: true),
        fileManager: FileManager = .default,
    ) {
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
            stagedURL = try staging.stage()
        } catch {
            return .failed(code: 0, reason: "Could not stage the payload: \(error.localizedDescription)")
        }

        do {
            try MachInjector.inject(pid: processIdentifier, dylibPath: stagedURL.path)
            return .injected
        } catch let error as NSError {
            return result(for: error)
        }
    }

    private func isAlive(processIdentifier: pid_t) -> Bool {
        // Signal 0 performs the permission and existence checks and delivers
        // nothing. EPERM means it exists and belongs to someone else, which is
        // still alive; only ESRCH means gone.
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Error mapping

    /// Maps MachInjector's published codes onto the two outcomes a caller acts
    /// on differently, passing anything else through verbatim.
    ///
    /// Only these two are singled out because only these two have distinct
    /// remedies: no task port means the entitlements or the target's uid, while
    /// a refused image means code signing and will not change on a retry.
    private func result(for error: NSError) -> RuntimeProcessInjectionResult {
        guard error.domain == MachInjector.errorDomain else {
            return .failed(code: error.code, reason: error.localizedDescription)
        }

        // The target's own `dlerror` text, when the injector captured it. It is
        // the only thing that distinguishes a library-validation refusal from a
        // sandbox one, so it is worth surfacing rather than summarizing.
        let remoteMessage = error.userInfo[MachInjector.remoteErrorMessageKey] as? String

        switch error.code {
        case MachInjector.Error.taskPortUnavailable.rawValue:
            return .taskPortUnavailable(reason: remoteMessage ?? error.localizedDescription)
        case MachInjector.Error.targetRefusedToLoadDylib.rawValue:
            return .targetRefusedPayload(reason: remoteMessage ?? error.localizedDescription)
        default:
            return .failed(code: error.code, reason: remoteMessage ?? error.localizedDescription)
        }
    }
}

#endif

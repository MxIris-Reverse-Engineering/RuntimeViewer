public import Foundation
public import RuntimeViewerCore
import RuntimeViewerProcessEnumerationSupport

/// Lists the processes on the machine it runs on, each annotated with whether
/// this process could inject into it.
///
/// Cross-platform on purpose, even though only the iOS variant ships it: the
/// BSD calls underneath are identical on macOS, so the buffer sizing, the
/// name/path resolution and the injectability rules are all exercised by tests
/// on a Mac. An iOS-only implementation would have no test at all — the device
/// has neither a test runner nor a way to fail a build.
public enum RuntimeDeviceProcessEnumerator {
    public enum EnumerationError: Error, Equatable {
        /// `proc_listallpids` was refused.
        ///
        /// `EPERM` here means the caller is containerized, and no task-port
        /// entitlement changes that — the sandbox escape is the prerequisite
        /// for *listing*, separately from `task_for_pid-allow` being the
        /// prerequisite for injecting.
        case processListRefused(errorNumber: Int32)

        /// The kernel reported a capacity of zero or less, so there is nothing
        /// to size a buffer from.
        case processListEmpty
    }

    /// Every process this one can see.
    ///
    /// - Parameter injectorUserIdentifier: the uid the injection would run as.
    ///   Passed in rather than read from `getuid()` so the injectability rules
    ///   are testable without being root.
    public static func processList(injectorUserIdentifier: uid_t) throws -> [RuntimeProcess] {
        let identifiers = try processIdentifiers()
        let ownIdentifier = getpid()
        return identifiers.compactMap { processIdentifier in
            // pid 0 comes back in the list and is the kernel, not a process.
            guard processIdentifier > 0 else { return nil }
            return describe(
                processIdentifier: processIdentifier,
                injectorUserIdentifier: injectorUserIdentifier,
                ownProcessIdentifier: ownIdentifier,
            )
        }
    }

    // MARK: - The pid set

    /// The raw pid list.
    ///
    /// `proc_listallpids(nil, 0)` answers a **capacity hint**, not a count: it
    /// is an upper bound the kernel is willing to promise, and the real number
    /// only comes from the second call's return value. Treating the hint as the
    /// count reads uninitialized tail entries as pids.
    static func processIdentifiers() throws -> [pid_t] {
        let capacityHint = proc_listallpids(nil, 0)
        guard capacityHint > 0 else {
            if capacityHint < 0 { throw EnumerationError.processListRefused(errorNumber: errno) }
            throw EnumerationError.processListEmpty
        }

        var identifiers = [pid_t](repeating: 0, count: Int(capacityHint))
        let bytesWritten = identifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesWritten > 0 else {
            if bytesWritten < 0 { throw EnumerationError.processListRefused(errorNumber: errno) }
            throw EnumerationError.processListEmpty
        }

        // Integer division on purpose: the kernel has been observed to return a
        // byte count that is not a whole multiple of the entry size, and a
        // partial trailing entry is not a pid.
        let count = min(Int(bytesWritten) / MemoryLayout<pid_t>.size, identifiers.count)
        return Array(identifiers[0 ..< count])
    }

    // MARK: - Per process

    private static func describe(
        processIdentifier: pid_t,
        injectorUserIdentifier: uid_t,
        ownProcessIdentifier: pid_t,
    ) -> RuntimeProcess {
        let path = executablePath(ofProcessWithIdentifier: processIdentifier)
        let userIdentifier = userIdentifier(ofProcessWithIdentifier: processIdentifier)
        return RuntimeProcess(
            processIdentifier: processIdentifier,
            // A process whose `p_comm` is unreadable still has a pid worth
            // showing, so fall back to the executable's last path component and
            // then to the pid itself rather than dropping the row.
            name: name(ofProcessWithIdentifier: processIdentifier)
                ?? path.map { ($0 as NSString).lastPathComponent }
                ?? "pid \(processIdentifier)",
            executablePath: path,
            userIdentifier: userIdentifier,
            injectability: injectability(
                ofProcessWithIdentifier: processIdentifier,
                userIdentifier: userIdentifier,
                injectorUserIdentifier: injectorUserIdentifier,
                ownProcessIdentifier: ownProcessIdentifier,
            ),
        )
    }

    static func name(ofProcessWithIdentifier processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(RuntimeViewerProcessNameMaximumLength))
        let length = proc_name(processIdentifier, &buffer, RuntimeViewerProcessNameMaximumLength)
        guard length > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    static func executablePath(ofProcessWithIdentifier processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(RuntimeViewerProcessPathMaximumLength))
        let length = proc_pidpath(processIdentifier, &buffer, RuntimeViewerProcessPathMaximumLength)
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// The owning uid, via `sysctl`.
    ///
    /// Not `proc_pidinfo`: that needs `struct proc_bsdinfo` from
    /// `<sys/proc_info.h>`, which the iOS SDK does not ship, so it would mean
    /// copying a kernel struct layout by hand. `<sys/sysctl.h>` does ship and
    /// carries `struct kinfo_proc`, so this route needs no copied ABI.
    ///
    /// `nil` means "could not tell" and is a supported outcome — whether this
    /// call is permitted to every unsandboxed process on every jailbroken
    /// device is not measured. See ``RuntimeProcess/userIdentifier``.
    static func userIdentifier(ofProcessWithIdentifier processIdentifier: pid_t) -> uid_t? {
        var selector: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&selector, UInt32(selector.count), &info, &length, nil, 0)
        // A zero length means the call succeeded but filled nothing, which
        // happens for a pid that exited between the listing and this call.
        guard result == 0, length > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    // MARK: - Injectability

    /// Whether this process could inject into that one.
    ///
    /// Pre-screening only. It exists to keep targets that are certain to fail
    /// out of the picker, not to promise the rest will succeed — the injection
    /// attempt remains the authority, and anything unknown resolves to
    /// `.injectable` so the attempt is what reports it.
    static func injectability(
        ofProcessWithIdentifier processIdentifier: pid_t,
        userIdentifier: uid_t?,
        injectorUserIdentifier: uid_t,
        ownProcessIdentifier: pid_t,
    ) -> RuntimeProcess.Injectability {
        if processIdentifier == ownProcessIdentifier {
            // The variant that lists processes is the one already serving its
            // own runtime as an engine; injecting into itself would be a second
            // server in the same process.
            return .notInjectable(reason: "This is Runtime Viewer itself, which already serves its own runtime.")
        }
        if processIdentifier == 1 {
            // Measured as the general root rule below, but named explicitly:
            // launchd is the one target a user is most likely to try, and
            // "needs root" explains less than saying what it is.
            return .notInjectable(reason: "launchd is the system's first process and cannot be injected into.")
        }
        // Measured: a uid 501 process cannot obtain the task port of a uid 0
        // process however it is entitled. Root targets need a root injector,
        // which is separate work.
        if let userIdentifier, userIdentifier == 0, injectorUserIdentifier != 0 {
            return .requiresRootOnTarget
        }
        return .injectable
    }
}

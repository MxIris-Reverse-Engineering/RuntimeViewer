#if os(macOS) || targetEnvironment(macCatalyst)

import Foundation
import RuntimeViewerCoreObjC

/// Runtime probe deciding whether a process's sandbox forces the localhost-socket
/// transport instead of the XPC Mach-service transport.
///
/// The choice between `RuntimeXPCConnection` (XPC Mach service) and
/// `RuntimeLocalSocketConnection` (localhost socket) hinges on a single question:
/// can the target process look up the RuntimeViewer helper's Mach service? Two
/// unrelated sandbox mechanisms answer "no":
///
/// - **App Sandbox** apps (`com.apple.security.app-sandbox`) run under a
///   `(deny default)` profile whose `mach-lookup` allowlist excludes our service.
/// - **Seatbelt-profiled system daemons** (e.g. `rapportd`, via a
///   `seatbelt-profiles` entitlement + a `.sb` profile) are equally `(deny default)`
///   with an allowlist of only Apple's own services — but carry *no*
///   `com.apple.security.app-sandbox` entitlement, so entitlement sniffing misses
///   them entirely.
///
/// Probing `sandbox_check` directly covers both, plus any future sandbox flavor,
/// and lets the host (probing the target pid) and the injected server (probing
/// `getpid()`) reach the same decision about the same process.
public enum SandboxProbe {
    /// Whether `pid`'s sandbox would deny a `mach-lookup` of `globalName`.
    ///
    /// Returns `false` for an unsandboxed process, and also on probe failure so the
    /// XPC default is preserved. Accepts any pid, including `getpid()`.
    ///
    /// `pid` is a `pid_t` (an `Int32`); it is spelled `Int32` here because the module's
    /// `import Foundation` is internal (`.internalImportsByDefault`), which would make the
    /// `pid_t` typealias too inaccessible for a `public` signature.
    public static func isMachLookupBlocked(pid: Int32, globalName: String) -> Bool {
        let result = globalName.withCString { globalNamePointer in
            "mach-lookup".withCString { operationPointer in
                RVSandboxCheckGlobalName(pid, operationPointer, globalNamePointer)
            }
        }
        // `sandbox_check` returns 0 when allowed (or unsandboxed), a positive value
        // when denied, and -1 on error. Only an explicit denial routes to the
        // socket fallback; errors keep the previous XPC default.
        return result > 0
    }

    /// Convenience over ``isMachLookupBlocked(pid:globalName:)`` for the RuntimeViewer
    /// helper Mach service (``RuntimeViewerMachServiceName``).
    public static func isRuntimeViewerServiceMachLookupBlocked(pid: Int32) -> Bool {
        isMachLookupBlocked(pid: pid, globalName: RuntimeViewerMachServiceName)
    }

    /// Whether `pid`'s sandbox would deny mapping `path` as executable — i.e.
    /// whether a `dlopen(path)` inside that process would be refused by seatbelt
    /// at the `file-map-executable` predicate.
    ///
    /// This is the decisive question for picking between the dlopen and
    /// mach_vm_remap injection paths: strict seatbelt daemons (sharingd,
    /// rapportd, and their kin) `(deny default)` `file-map-executable` for
    /// anything outside a hard-coded system whitelist, and no sandbox extension
    /// unlocks that predicate. Only the remap path bypasses it, so any target
    /// that answers `true` here must be attached via remap.
    ///
    /// Returns `false` for an unsandboxed process, and also on probe failure so
    /// the dlopen default is preserved.
    public static func isFileMapExecutableBlocked(pid: Int32, path: String) -> Bool {
        let result = path.withCString { pathPointer in
            "file-map-executable".withCString { operationPointer in
                RVSandboxCheckPath(pid, operationPointer, pathPointer)
            }
        }
        return result > 0
    }
}

#endif

#if os(macOS)
import Foundation

/// Reads whether a process runs translated by Rosetta.
///
/// Exists to tell which dyld shared cache a process maps: dyld picks the cache
/// file by its own architecture, so every native process on Apple Silicon —
/// arm64 and arm64e alike — maps `dyld_shared_cache_arm64e`, and a translated
/// one the x86_64 cache. The kernel answers for any process, another user's
/// and root's included, without the task port nothing but the helper daemon
/// could get.
public enum ProcessTranslationProbe {
    /// `P_TRANSLATED` from `<sys/proc.h>`, which Swift does not import.
    private static let translatedFlag: Int32 = 0x0002_0000

    /// Whether `processIdentifier` runs translated, or `nil` when the kernel
    /// has no such process.
    public static func isTranslated(processIdentifier: pid_t) -> Bool? {
        var information = kinfo_proc()
        var informationSize = MemoryLayout<kinfo_proc>.stride
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), &information, &informationSize, nil, 0) == 0,
              informationSize > 0
        else { return nil }
        return information.kp_proc.p_flag & translatedFlag != 0
    }
}
#endif

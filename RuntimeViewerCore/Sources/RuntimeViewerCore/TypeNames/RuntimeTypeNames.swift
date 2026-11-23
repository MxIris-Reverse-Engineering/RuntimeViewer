import Foundation
import FoundationToolbox
import MachOKit
#if os(macOS)
import SwiftTypeNameResolution
import TypeIndexing
#endif

/// The switch for resolving imported type names with the SDK type index
/// (`RuntimeTypeIndex`) in this process.
///
/// **Off unless a process turns it on.** The processes that print for the
/// app's engines on a Mac — the local, Mac Catalyst, file and framework
/// services — and the command-line host call `enableInThisProcess()` at their
/// entry points, before any engine connects. Every other process leaves it
/// off: the app itself (its engines forward to the services), an injected
/// payload and a device (no SDK there), and a test, which then prints `__C.`
/// names and never reads an SDK or writes the shared cache. Forgetting the
/// call breaks nothing — the process only prints `__C.` names.
public enum RuntimeTypeNames {
    /// Turns the type index on for this process.
    public static func enableInThisProcess() {
        isEnabled.withLock { $0 = true }
    }

    static var isEnabledInThisProcess: Bool {
        isEnabled.withLock { $0 }
    }

    private static let isEnabled = Mutex(false)

    /// The SDK platform the type index reads for `machO`, by its raw value
    /// (`macosx`, `maccatalyst`, …): that of the image's first
    /// `LC_BUILD_VERSION`. `nil` for an image naming no platform an SDK
    /// covers, and anywhere the type index does not run.
    static func platformName(of machO: some MachORepresentable) -> String? {
        #if os(macOS)
        guard #available(macOS 13.0, *) else { return nil }
        for loadCommand in machO.loadCommands {
            if case .buildVersion(let buildVersionCommand) = loadCommand {
                return SDKPlatform(buildVersionCommand.platform)?.rawValue
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}

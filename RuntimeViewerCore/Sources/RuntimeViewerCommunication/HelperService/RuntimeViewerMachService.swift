import Foundation
import OSLog

#if DEBUG

/// In debug builds the helper-daemon mach-service identity is chosen by `runtimeViewerIsARM64EVariant`,
/// which each executable entry point (app / daemon / injected server / Catalyst helper) flips on for
/// the Debug-arm64e variant via `#if RUNTIMEVIEWER_ARM64E`. The arm64e variant cannot be detected
/// inside this SwiftPM package: custom build conditions don't reach package targets, and the
/// running architecture isn't a reliable signal (the app slice stays arm64 while the daemon /
/// injected slices are arm64e). Release is a fixed compile-time constant.
///
/// **The flip has to happen before anything reads ``RuntimeViewerMachServiceName``.** A reader is
/// free to keep the name it was handed: `SMAppServiceDaemonInstaller` builds an `SMAppService` from
/// it once and holds that object for the life of the process. Flipping afterwards leaves such a
/// reader pinned to the other variant's daemon while every later read returns the right name, so
/// the mismatch only surfaces at the one operation that goes through the stored object. Writing a
/// different value after the first read therefore reports through
/// ``runtimeViewerLateVariantSelectionHandler``, which asserts by default.
/// See `Documentations/ResolvedIssues/2026-09-18-arm64e-variant-selected-after-window-restoration.md`.
public var runtimeViewerIsARM64EVariant: Bool {
    get { withRuntimeViewerVariantSelection { $0.selectedIsARM64EVariant } }
    set {
        // The handler runs outside the lock: its default traps, and a trap while holding a lock
        // makes the resulting report harder to read than it already is.
        let diagnosticMessage = withRuntimeViewerVariantSelection { $0.select(isARM64EVariant: newValue) }
        if let diagnosticMessage {
            runtimeViewerLateVariantSelectionHandler(diagnosticMessage)
        }
    }
}

/// Mach service name shared by the app (client) and the helper daemon (server).
public var RuntimeViewerMachServiceName: String {
    withRuntimeViewerVariantSelection { $0.readMachServiceName() }
}

/// Reports a ``runtimeViewerIsARM64EVariant`` write that lands after ``RuntimeViewerMachServiceName``
/// has already been read as the other variant's name. Asserts by default; a test replaces it to
/// observe the diagnostic instead of trapping.
nonisolated(unsafe) public var runtimeViewerLateVariantSelectionHandler: @Sendable (String) -> Void = { diagnosticMessage in
    assertionFailure(diagnosticMessage)
}

/// Process-wide selection. A value type so the ordering rule can be exercised in a test without
/// touching this global.
///
/// Locked because reading the name now writes to it — every reader marks the name as handed out —
/// so the unsynchronised access the flag used to get would let two threads racing on the first read
/// lose the mark, and with it the detection.
nonisolated(unsafe) private var runtimeViewerVariantSelection = RuntimeViewerVariantSelection()

private let runtimeViewerVariantSelectionLock = NSLock()

private func withRuntimeViewerVariantSelection<Result>(
    _ body: (inout RuntimeViewerVariantSelection) -> Result
) -> Result {
    runtimeViewerVariantSelectionLock.lock()
    defer { runtimeViewerVariantSelectionLock.unlock() }
    return body(&runtimeViewerVariantSelection)
}

#else

/// Mach service name shared by the app (client) and the helper daemon (server).
public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"

#endif

/// Protocol version shared between the app and the helper service daemon.
/// Bump this whenever the service binary changes in a way that requires reinstallation.
public let RuntimeViewerServiceVersion: String = "1.9.0"

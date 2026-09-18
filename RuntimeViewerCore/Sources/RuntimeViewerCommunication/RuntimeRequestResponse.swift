import Foundation
import OSLog
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public import HelperCommunication
#endif

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

/// Which variant's helper daemon this executable talks to, plus whether the name has been handed
/// out yet — the two facts the ordering rule above is stated in terms of.
struct RuntimeViewerVariantSelection {
    private var isARM64EVariant: Bool = false

    private var machServiceNameHasBeenRead: Bool = false

    var selectedIsARM64EVariant: Bool { isARM64EVariant }

    /// Hands out the mach service name and records that a reader now holds it.
    mutating func readMachServiceName() -> String {
        machServiceNameHasBeenRead = true
        return Self.machServiceName(isARM64EVariant: isARM64EVariant)
    }

    /// Applies a variant selection. Returns a diagnostic when it arrives too late to be safe — the
    /// name was already handed out as the other variant's — and `nil` otherwise, which includes
    /// re-selecting the value that is already in effect.
    mutating func select(isARM64EVariant newValue: Bool) -> String? {
        let previousName = Self.machServiceName(isARM64EVariant: isARM64EVariant)
        let arrivesTooLate = machServiceNameHasBeenRead && newValue != isARM64EVariant
        isARM64EVariant = newValue
        guard arrivesTooLate else { return nil }
        return """
            runtimeViewerIsARM64EVariant was set to \(newValue) after RuntimeViewerMachServiceName \
            had already been read as "\(previousName)". Whoever read it may still be holding that \
            name — SMAppServiceDaemonInstaller stores the SMAppService built from it — and is now \
            pinned to the other variant's helper daemon. Select the variant from the executable's \
            entry point, before AppKit starts or any dependency is resolved.
            """
    }

    static func machServiceName(isARM64EVariant: Bool) -> String {
        isARM64EVariant
            ? "dev.arm64e.mxiris.runtimeviewer.service"
            : "dev.mxiris.runtimeviewer.service"
    }
}

#else

/// Mach service name shared by the app (client) and the helper daemon (server).
public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"

#endif

/// Protocol version shared between the app and the helper service daemon.
/// Bump this whenever the service binary changes in a way that requires reinstallation.
public let RuntimeViewerServiceVersion: String = "1.8.0"

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

/// On macOS, `RuntimeRequest` is a refinement of `HelperCommunication.Request` so that any
/// daemon-bound business request can be mounted directly onto a lib `HelperService` /
/// `HelperPeerClient` / `HelperPeerServer`. The `RuntimeResponse: Codable & Sendable`
/// constraint is what lets the inherited `associatedtype Response: Codable & Sendable`
/// from `HelperCommunication.Request` be satisfied.
///
/// Business request types (now defined in swift-helper-service) gain `RuntimeRequest`
/// conformance retroactively — see `Requests+RuntimeRequest.swift`.
public protocol RuntimeRequest: HelperCommunication.Request where Response: RuntimeResponse {}

#else

public protocol RuntimeRequest: Codable, Sendable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

#endif

public protocol RuntimeResponse: Codable, Sendable {}

#if !(canImport(AppKit) && !targetEnvironment(macCatalyst))

/// Non-macOS platforms keep a local `VoidResponse`. On macOS the daemon-bound request
/// types use `HelperCommunication.VoidResponse` from swift-helper-service instead.
public struct VoidResponse: RuntimeResponse {
    public init() {}

    public static let empty: VoidResponse = .init()
}

#endif

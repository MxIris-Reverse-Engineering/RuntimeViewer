#if os(macOS)

import RuntimeViewerInjection

/// Whether Attach to Process can do anything for the engine currently selected, and when
/// it cannot, what to say about it.
///
/// A disabled control carrying its reason in a tooltip, rather than an enabled control
/// that reports the obstacle after being clicked: an action that cannot be performed is an
/// action whose control is off, and the user should not have to try it to find out. The
/// explanation is written to be read verbatim.
public struct AttachAvailability: Equatable {
    public let isEnabled: Bool
    public let explanation: String

    public static let probing = AttachAvailability(
        isEnabled: false,
        explanation: "Checking whether this device can attach to its own processes…",
    )

    /// Attaching needs SIP off, but only when the target is a process on *this* Mac. A
    /// device on the other end of the connection does its own injecting and could not care
    /// less about this machine's SIP state, which is why this is not a gate on the button
    /// as a whole.
    public static let systemIntegrityProtectionEnabled = AttachAvailability(
        isEnabled: false,
        explanation: "Attaching to a process on this Mac needs System Integrity Protection disabled.",
    )

    /// An engine reached through another Mac. The hop exists and the commands would very
    /// likely be forwarded, but that has not been measured, so the entry says so instead
    /// of offering an action that may fail in a way nobody has seen yet.
    public static let mirroredEngine = AttachAvailability(
        isEnabled: false,
        explanation: "Attaching to a process on an engine shared by another Mac is not supported yet.",
    )

    public static let attachable = AttachAvailability(
        isEnabled: true,
        explanation: "Attach to a running process and inspect its runtime",
    )

    public init(isEnabled: Bool, explanation: String) {
        self.isEnabled = isEnabled
        self.explanation = explanation
    }

    /// Maps what the far end said about itself.
    public init(remoteAvailability: RuntimeInjectionAvailability) {
        switch remoteAvailability {
        case .available:
            self = .attachable
        case .requiresJailbrokenVariant:
            self.init(
                isEnabled: false,
                explanation: "This device is running the App Store build of Runtime Viewer, which cannot attach to other processes. The jailbroken build can.",
            )
        case .helperDaemonNotInstalled:
            self.init(
                isEnabled: false,
                explanation: "Attaching on that Mac needs its Runtime Viewer helper installed.",
            )
        case .unsupported(let reason):
            self.init(isEnabled: false, explanation: reason)
        }
    }
}

#endif

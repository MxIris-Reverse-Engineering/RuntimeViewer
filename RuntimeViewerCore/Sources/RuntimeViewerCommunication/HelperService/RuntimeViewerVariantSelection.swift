#if DEBUG

/// Which variant's helper daemon this executable talks to, plus whether the name has been handed
/// out yet — the two facts the ordering rule on ``runtimeViewerIsARM64EVariant`` is stated in terms of.
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

#endif

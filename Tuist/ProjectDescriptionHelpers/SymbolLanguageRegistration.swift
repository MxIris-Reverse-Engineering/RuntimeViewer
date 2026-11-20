import ProjectDescription

/// MachOSwiftSection's SwiftSymbolsRegistration and MachOObjCSection's MachOObjCSectionC register the
/// Swift and Objective-C symbol languages with MachOKitExtensions from a load-time constructor, in a C
/// file that defines no symbol anything refers to. The native workspaces link each package target
/// whole, so the constructor always runs. Tuist links the packages as static frameworks, from which the
/// linker loads only the members something refers to, and -ObjC does not load these two either:
/// without loading both frameworks whole, a binary's symbol language registry stays empty.
///
/// A target that links neither framework must not get the flags: -force_load fails on a file that was
/// never built. The targets that do are the ones whose dependencies reach MachOSwiftSection.
public enum SymbolLanguageRegistration {
    /// Linker flags that load both frameworks whole.
    public static let linkerFlags: [String] = [
        "-Wl,-force_load,$(BUILT_PRODUCTS_DIR)/SwiftSymbolsRegistration.framework/SwiftSymbolsRegistration",
        "-Wl,-force_load,$(BUILT_PRODUCTS_DIR)/MachOObjCSectionC.framework/MachOObjCSectionC",
    ]

    /// The local packages' test targets that link MachOSwiftSection (from the generated projects'
    /// link phases, 2026-11-20).
    public static let testTargetNames: Set<String> = [
        "RuntimeViewerCoreTests",
        "RuntimeViewerInjectionTests",
        "RuntimeViewerCrossReferencesTests",
        "RuntimeViewerSettingsTests",
        "RuntimeViewerDeviceInjectionTests",
        "RuntimeViewerEngineManagementTests",
        "RuntimeViewerAppCoreTests",
        "RuntimeViewerAppUITests",
        "RuntimeViewerMCPBridgeTests",
        "RuntimeViewerCommandLineTests",
    ]
}

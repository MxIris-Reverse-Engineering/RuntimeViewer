import ProjectDescription

/// The four local packages Tuist/Package.swift declares by path: RuntimeViewerCore,
/// RuntimeViewerPackages, RuntimeViewerMCP and RuntimeViewerCommandLine. Their targets stay source in
/// RuntimeViewer-Tuist.xcworkspace, while every third-party dependency comes out of the binary cache.
///
/// Tuist.swift keeps its own copy of `targetNames` for the cache profile, because that manifest
/// cannot import ProjectDescriptionHelpers. `./TuistScript.sh check` keeps both copies in step with
/// the packages' manifests.
public enum LocalPackages {
    /// The packages' non-test targets, by the names their manifests give them.
    public static let sourceTargetNames: [String] = [
        // RuntimeViewerCore
        "RuntimeViewerObjC",
        "RuntimeViewerCore",
        "RuntimeViewerCommunication",
        "RuntimeViewerInjection",
        "RuntimeViewerUtilities",
        // RuntimeViewerPackages
        "RuntimeViewerArchitectures",
        "RuntimeViewerUI",
        "RuntimeViewerSettings",
        "RuntimeViewerSettingsUI",
        "RuntimeViewerSimulatorInstaller",
        "RuntimeViewerApplication",
        "RuntimeViewerService",
        "RuntimeViewerServiceHelper",
        "RuntimeViewerHelperClient",
        "RuntimeViewerDeviceInjection",
        "RuntimeViewerProcessEnumerationSupport",
        "RuntimeViewerRunningBoardSupport",
        "RuntimeViewerCatalystExtensions",
        "RuntimeViewerEngineManagement",
        // RuntimeViewerMCP
        "RuntimeViewerMCPBridge",
        // RuntimeViewerCommandLine
        "RuntimeViewerCommandLineInterface",
    ]

    /// The bundle target Tuist generates, named `<package>_<target>`, for each of those targets that
    /// declares resources.
    public static let resourceBundleTargetNames: [String] = [
        "RuntimeViewerPackages_RuntimeViewerSettingsUI",
    ]

    /// Every target of the packages that is not a test target.
    public static let targetNames: [String] = sourceTargetNames + resourceBundleTargetNames

    /// The library products of RuntimeViewerPackages, RuntimeViewerMCP and RuntimeViewerCommandLine.
    /// In this workspace only the macOS app and what it embeds for macOS consume them; RuntimeViewerCore's
    /// products also go into the iOS Simulator payload, so they are not listed.
    public static let macOSOnlyProductNames: [String] = [
        // RuntimeViewerPackages
        "RuntimeViewerUI",
        "RuntimeViewerArchitectures",
        "RuntimeViewerApplication",
        "RuntimeViewerService",
        "RuntimeViewerServiceHelper",
        "RuntimeViewerHelperClient",
        "RuntimeViewerDeviceInjection",
        "RuntimeViewerEngineManagement",
        "RuntimeViewerSettings",
        "RuntimeViewerSettingsUI",
        "RuntimeViewerSimulatorInstaller",
        "RuntimeViewerCatalystExtensions",
        // RuntimeViewerMCP
        "RuntimeViewerMCPBridge",
        // RuntimeViewerCommandLine
        "RuntimeViewerCommandLineInterface",
    ]

    /// The packages' test targets, by package directory.
    public static let testTargetNames: [(package: String, targets: [String])] = [
        ("RuntimeViewerCore", [
            "RuntimeViewerCoreTests",
            "RuntimeViewerCommunicationTests",
            "RuntimeViewerInjectionTests",
        ]),
        ("RuntimeViewerPackages", [
            "RuntimeViewerArchitecturesTests",
            "RuntimeViewerSettingsTests",
            "RuntimeViewerDeviceInjectionTests",
            "RuntimeViewerHelperClientTests",
            "RuntimeViewerEngineManagementTests",
            "RuntimeViewerApplicationTests",
        ]),
        ("RuntimeViewerMCP", [
            "RuntimeViewerMCPBridgeTests",
        ]),
        ("RuntimeViewerCommandLine", [
            "RuntimeViewerCommandLineTests",
        ]),
    ]
}

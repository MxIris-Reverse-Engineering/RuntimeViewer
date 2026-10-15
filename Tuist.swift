import ProjectDescription

// The targets of the four local packages, which the development cache profile keeps as source while
// every third-party dependency comes out of the binary cache. Cache-profile exceptions match target
// names exactly, and this manifest cannot import ProjectDescriptionHelpers, so the list is written
// out here as well as in Tuist/ProjectDescriptionHelpers/LocalPackages.swift; `./TuistScript.sh check`
// keeps both in step with the packages' manifests.
let localPackageTargetNames = [
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
    "RuntimeViewerPackages_RuntimeViewerSettingsUI",
    // RuntimeViewerMCP
    "RuntimeViewerMCPBridge",
    // RuntimeViewerCommandLine
    "RuntimeViewerCommandLineInterface",
]

// No fullHandle: the binary cache stays on this machine and nothing is uploaded.
let tuist = Tuist(
    project: .tuist(
        cacheOptions: .options(
            profiles: .profiles(
                ["development": .profile(.onlyExternal, except: localPackageTargetNames.map { .named($0) })],
                default: "development"
            )
        )
    )
)

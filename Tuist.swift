import ProjectDescription

// The targets of the four local packages, which the development cache profile keeps as source while
// every other third-party dependency comes out of the binary cache. Cache-profile exceptions match
// target names exactly, and this manifest cannot import ProjectDescriptionHelpers, so the list is
// written out here as well as in Tuist/ProjectDescriptionHelpers/LocalPackages.swift;
// `./TuistScript.sh check` keeps both in step with the packages' manifests.
let localPackageTargetNames = [
    // RuntimeViewerCore
    "RuntimeViewerObjC",
    "RuntimeViewerCore",
    "RuntimeViewerCommunication",
    "RuntimeViewerInjection",
    "RuntimeViewerCrossReferences",
    "RuntimeViewerUtilities",
    "RuntimeViewerService",
    // RuntimeViewerPackages
    "RuntimeViewerArchitectures",
    "RuntimeViewerUI",
    "RuntimeViewerSettings",
    "RuntimeViewerSettingsUI",
    "RuntimeViewerSimulatorInstaller",
    "RuntimeViewerApplication",
    "RuntimeViewerAppCore",
    "RuntimeViewerAppUI",
    "RuntimeViewerServiceHelper",
    "RuntimeViewerHelperClient",
    "RuntimeViewerDeviceInjection",
    "RuntimeViewerProcessEnumerationSupport",
    "RuntimeViewerRunningBoardSupport",
    "RuntimeViewerCatalystExtensions",
    "RuntimeViewerEngineManagement",
    "RuntimeViewerAppTestingSupport",
    "RuntimeViewerPackages_RuntimeViewerSettingsUI",
    // RuntimeViewerMCP
    "RuntimeViewerMCPBridge",
    // RuntimeViewerCommandLine
    "RuntimeViewerCommandLineInterface",
]

// The library and macro targets of four third-party packages that change often alongside this
// repository — MachOKitExtensions, MachOObjCSection, MachOSwiftSection and swift-semantic-string —
// which the profile keeps as source as well, so moving one of their pins never sends the binary cache
// to be warmed again, and their sources stay in the workspace. No other third-party package depends
// on them, so the rest of the cache is unaffected. Names match every package's targets alike, so
// `./TuistScript.sh check` (SOURCE_DEPENDENCIES there) also keeps this list in step with the four
// packages' manifests and reports a name another dependency's target shares.
let sourceDependencyTargetNames = [
    // MachOKitExtensions
    "MachOKitExtensions",
    // MachOObjCSection
    "MachOObjCSection",
    "MachOObjCSectionC",
    "ObjCMetadataSource",
    "ObjCDeclarationRendering",
    "ObjCIndexing",
    "ObjCOutputTransformer",
    "ObjCDiffing",
    "ObjCInterface",
    // MachOSwiftSection
    "Utilities",
    "ARM64InstructionDecoding",
    "SwiftOutputTransformer",
    "MachOCaches",
    "MachODependencies",
    "MachOReading",
    "MachOResolving",
    "MachOSymbols",
    "MachOPointers",
    "MachOBase",
    "MachOFoundation",
    "MachOSwiftSectionC",
    "MachOSwiftSection",
    "SwiftInspection",
    "SwiftObjCInterop",
    "SwiftLayout",
    "SwiftDeclarationRendering",
    "SwiftThunkAnalysis",
    "CrossReferenceAnalysis",
    "SwiftDump",
    "SwiftDeclaration",
    "SwiftAttributeInference",
    "SwiftDiffing",
    "SwiftIndexing",
    "SwiftPrivateDiscriminators",
    "SwiftPrinting",
    "SwiftSpecialization",
    "SwiftInterface",
    "TypeIndexing",
    "SwiftSectionKit",
    "MachOFixtureSupport",
    "MachOTestingSupport",
    "MachOTestingSupportC",
    "MachOMacros",
    // swift-semantic-string
    "Semantic",
    "OutputTransformer",
]

// No fullHandle: the binary cache stays on this machine and nothing is uploaded.
let tuist = Tuist(
    project: .tuist(
        cacheOptions: .options(
            profiles: .profiles(
                ["development": .profile(
                    .onlyExternal,
                    except: (localPackageTargetNames + sourceDependencyTargetNames).map { .named($0) }
                )],
                default: "development"
            )
        )
    )
)

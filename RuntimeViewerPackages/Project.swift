import ProjectDescription

// All third-party dependencies of this package resolve through Tuist's external
// integration and are therefore cacheable — none of them has a local checkout.
// (Only RuntimeViewerCore consumes the locally checked-out reverse-engineering
// libraries; see Tuist/Package.swift.)
//
// RuntimeViewerCore and RuntimeViewerCommunication come from the sibling Tuist
// project rather than as packages.

let destinations: Destinations = [.mac, .iPhone, .iPad, .macCatalyst, .appleTv, .appleVision]

let deploymentTargets: DeploymentTargets = .multiplatform(
    iOS: "18.0",
    macOS: "15.0",
    tvOS: "18.0",
    visionOS: "2.0"
)

/// Mirrors `appkitPlatforms` / `uikitPlatforms` in Package.swift.
let appKitOnly: PlatformCondition? = .when([.macos])
let uiKitOnly: PlatformCondition? = .when([.ios, .tvos, .visionos])

let corePath: Path = "../RuntimeViewerCore"

/// `Package.swift` sets `USING_SYSTEM_UXKIT` by default, which both defines the
/// compilation condition and selects the system UXKit products over the OpenUXKit
/// ones. Flip both together if that default ever changes.
let usingSystemUXKit = true

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "5",
    // Sources use Swift's `package` access level, whose scope is delimited by the
    // compiler's -package-name flag. SwiftPM passes it automatically; a generated
    // Xcode target does not get it, and such declarations then fail to resolve.
    "SWIFT_PACKAGE_NAME": "RuntimeViewerPackages",
]

let uxKitSettings: SettingsDictionary = usingSystemUXKit
    ? baseSettings.merging(["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) USING_SYSTEM_UXKIT"]) { _, new in new }
    : baseSettings

let project = Project(
    name: "RuntimeViewerPackages",
    settings: .settings(
        base: baseSettings,
        configurations: [
            .debug(name: "Debug"),
            .debug(name: "Debug-arm64e"),
            .release(name: "Release"),
            .release(name: "Distribution"),
        ]
    ),
    targets: [
        .target(
            name: "RuntimeViewerArchitectures",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerArchitectures",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerArchitectures/**"],
            dependencies: [
                .external(name: "RxSwift"),
                .external(name: "RxCocoa"),
                .external(name: "RxSwiftPlus"),
                .external(name: "RxDefaultsPlus"),
                .external(name: "RxCombine"),
                .external(name: "RxEnumKit"),
                .external(name: "RxConcurrency"),
                .external(name: "Dependencies"),
                .external(name: "DependenciesMacros"),
                .external(name: "SwiftNavigation"),
                .external(name: "RxAppKit", condition: appKitOnly),
                .external(name: "CocoaCoordinator", condition: appKitOnly),
                .external(name: "RxCocoaCoordinator", condition: appKitOnly),
                .external(name: usingSystemUXKit ? "UXKitCoordinator" : "OpenUXKitCoordinator", condition: appKitOnly),
                .external(name: "RxUIKit", condition: uiKitOnly),
                .external(name: "XCoordinator", condition: uiKitOnly),
                .external(name: "XCoordinatorRx", condition: uiKitOnly),
            ],
            settings: .settings(base: uxKitSettings)
        ),
        .target(
            name: "RuntimeViewerUI",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerUI",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerUI/**"],
            dependencies: [
                .external(name: "UIFoundation"),
                .external(name: "UIFoundationToolbox"),
                .external(name: "SnapKit"),
                .external(name: "SFSymbols"),
                .external(name: "LateResponders"),
                .external(name: usingSystemUXKit ? "UXKit" : "OpenUXKit", condition: appKitOnly),
                .external(name: "Rearrange", condition: appKitOnly),
                .external(name: "RunningApplicationKit", condition: appKitOnly),
                .external(name: "KeyboardShortcuts", condition: appKitOnly),
                .external(name: "SystemHUD", condition: appKitOnly),
            ],
            settings: .settings(base: uxKitSettings)
        ),
        .target(
            name: "RuntimeViewerSettings",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerSettings",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerSettings/**"],
            dependencies: [
                .project(target: "RuntimeViewerCore", path: corePath),
                .external(name: "Dependencies"),
                .external(name: "DependenciesMacros"),
                .external(name: "UIFoundationSettings", condition: appKitOnly),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerSimulatorInstaller",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerSimulatorInstaller",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerSimulatorInstaller/**"],
            dependencies: [
                .external(name: "Dependencies"),
                .external(name: "DependenciesMacros"),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerServiceHelper",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerServiceHelper",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerServiceHelper/**"],
            // Objective-C target: SwiftPM treats Sources/<target>/include as the
            // public headers directory by convention; a generated Xcode target
            // needs it declared, otherwise the .m cannot find its own header.
            headers: .headers(public: ["Sources/RuntimeViewerServiceHelper/include/**"]),
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerCatalystExtensions",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerCatalystExtensions",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerCatalystExtensions/**"],
            dependencies: [
                .project(target: "RuntimeViewerCommunication", path: corePath),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerHelperClient",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerHelperClient",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerHelperClient/**"],
            dependencies: [
                .target(name: "RuntimeViewerServiceHelper"),
                .project(target: "RuntimeViewerCommunication", path: corePath),
                .external(name: "Dependencies"),
                .external(name: "DependenciesMacros"),
                .external(name: "HelperCommunication", condition: appKitOnly),
                .external(name: "HelperClient", condition: appKitOnly),
                .external(name: "ApplicationsServiceInterface", condition: appKitOnly),
                .external(name: "FilesServiceInterface", condition: appKitOnly),
                .external(name: "InjectionServiceInterface", condition: appKitOnly),
                .external(name: "InjectedEndpointRegistryServiceInterface", condition: appKitOnly),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerService",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerService",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerService/**"],
            dependencies: [
                .project(target: "RuntimeViewerCommunication", path: corePath),
                .external(name: "HelperCommunication", condition: appKitOnly),
                .external(name: "HelperService", condition: appKitOnly),
                .external(name: "HelperServer", condition: appKitOnly),
                .external(name: "ApplicationsServiceImplementation", condition: appKitOnly),
                .external(name: "FilesServiceImplementation", condition: appKitOnly),
                .external(name: "InjectionServiceImplementation", condition: appKitOnly),
                .external(name: "InjectedEndpointRegistryServiceImplementation", condition: appKitOnly),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerSettingsUI",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerSettingsUI",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerSettingsUI/**"],
            resources: ["Sources/RuntimeViewerSettingsUI/Resources/**"],
            dependencies: [
                .target(name: "RuntimeViewerUI"),
                .target(name: "RuntimeViewerSettings"),
                .target(name: "RuntimeViewerHelperClient", condition: appKitOnly),
                .target(name: "RuntimeViewerSimulatorInstaller", condition: appKitOnly),
                .external(name: "Dependencies"),
                .external(name: "DependenciesMacros"),
                .external(name: "UIFoundationSettings", condition: appKitOnly),
                .external(name: "UIFoundationSettingsUI", condition: appKitOnly),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerApplication",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerApplication",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerApplication/**"],
            dependencies: [
                .target(name: "RuntimeViewerUI"),
                .target(name: "RuntimeViewerArchitectures"),
                .target(name: "RuntimeViewerSettings"),
                .target(name: "RuntimeViewerSettingsUI", condition: appKitOnly),
                .target(name: "RuntimeViewerHelperClient", condition: appKitOnly),
                .target(name: "RuntimeViewerCatalystExtensions", condition: appKitOnly),
                .project(target: "RuntimeViewerCore", path: corePath),
                .external(name: "DependenciesMacros"),
                .external(name: "MemberwiseInit"),
                .external(name: "IfritStatic"),
                .external(name: "FuzzySearch"),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerArchitecturesTests",
            destinations: destinations,
            product: .unitTests,
            bundleId: "com.MxIris.RuntimeViewerArchitecturesTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/RuntimeViewerArchitecturesTests/**"],
            dependencies: [
                .target(name: "RuntimeViewerArchitectures"),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerSettingsTests",
            destinations: destinations,
            product: .unitTests,
            bundleId: "com.MxIris.RuntimeViewerSettingsTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/RuntimeViewerSettingsTests/**"],
            dependencies: [
                .target(name: "RuntimeViewerSettings"),
                .external(name: "UIFoundationSettings", condition: appKitOnly),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerApplicationTests",
            destinations: destinations,
            product: .unitTests,
            bundleId: "com.MxIris.RuntimeViewerApplicationTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/RuntimeViewerApplicationTests/**"],
            dependencies: [
                .target(name: "RuntimeViewerApplication"),
                .target(name: "RuntimeViewerUI"),
                .project(target: "RuntimeViewerCore", path: corePath),
            ],
            settings: .settings(base: baseSettings)
        ),
    ]
)

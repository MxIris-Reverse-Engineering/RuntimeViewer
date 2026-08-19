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

let systemUXKitDeploymentTargets: DeploymentTargets = .macOS("11.0")

/// Mirrors `appkitPlatforms` / `uikitPlatforms` in Package.swift.
let appKitOnly: PlatformCondition? = .when([.macos])
let uiKitOnly: PlatformCondition? = .when([.ios, .tvos, .visionos])

let corePath: Path = "../RuntimeViewerCore"

let systemUXKitSourceRoot = "../Tuist/.build/checkouts/OpenUXKit/Sources/UXKit"
let systemUXKitCoordinatorSourceRoot = "../Tuist/.build/checkouts/UXKitCoordinator/Sources/UXKitCoordinator"
let systemUXKitStubPath = "$(SRCROOT)/\(systemUXKitSourceRoot)/UXKit.tbd"

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
    ? baseSettings.merging(
        [
            "OTHER_LDFLAGS": "$(inherited) \"\(systemUXKitStubPath)\"",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) USING_SYSTEM_UXKIT",
        ]
    ) { _, newValue in newValue }
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
        // Tuist's external package converter follows Sources/UXKit/include to
        // OpenUXKit's symlinked headers and incorrectly adds OpenUXKit as a
        // dependency. Mapping the two lightweight system-UXKit targets here
        // preserves the package's .tbd shim without exposing both Clang modules.
        .target(
            name: "UXKit",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "com.MxIris.RuntimeViewerTuistSupport.UXKit",
            deploymentTargets: systemUXKitDeploymentTargets,
            infoPlist: .default,
            sources: ["\(systemUXKitSourceRoot)/NSViewController+UXKitFixups.m"],
            headers: .onlyHeaders(
                from: ["TuistSupport/UXKit/**"],
                umbrella: "TuistSupport/UXKit/UXKit.h"
            ),
            dependencies: [
                .sdk(name: "AppKit", type: .framework),
            ],
            settings: .settings(
                base: [
                    "HEADER_SEARCH_PATHS": "$(inherited) \"$(SRCROOT)/\(systemUXKitSourceRoot)/include\"",
                    "OTHER_LDFLAGS": "$(inherited) \"\(systemUXKitStubPath)\"",
                ]
            )
        ),
        .target(
            name: "UXKitCoordinator",
            destinations: [.mac],
            product: .staticFramework,
            bundleId: "com.MxIris.RuntimeViewerTuistSupport.UXKitCoordinator",
            deploymentTargets: systemUXKitDeploymentTargets,
            infoPlist: .default,
            sources: ["\(systemUXKitCoordinatorSourceRoot)/**"],
            dependencies: [
                .target(name: "UXKit"),
                .external(name: "CocoaCoordinator"),
                .sdk(name: "AppKit", type: .framework),
            ],
            settings: .settings(base: baseSettings)
        ),
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
                .target(name: "UXKitCoordinator", condition: appKitOnly),
                .sdk(name: "AppKit", type: .framework, condition: appKitOnly),
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
                .target(name: "UXKit", condition: appKitOnly),
                .sdk(name: "AppKit", type: .framework, condition: appKitOnly),
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
            // SwiftPM synthesizes a Clang module from the public include directory.
            // The generated framework needs an explicit umbrella header to emit the
            // module map imported by RuntimeViewerHelperClient.
            headers: .onlyHeaders(
                from: ["Sources/RuntimeViewerServiceHelper/include/**"],
                umbrella: "Sources/RuntimeViewerServiceHelper/include/RuntimeViewerServiceHelper.h"
            ),
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
                // RuntimeViewerApplication imports UIFoundation directly.
                // SwiftPM makes it visible through RuntimeViewerUI, while a
                // generated dynamic framework must link the static products
                // that provide those symbols itself.
                .external(name: "UIFoundation"),
                .external(name: "UIFoundationToolbox"),
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

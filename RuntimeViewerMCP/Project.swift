import ProjectDescription

// RuntimeViewerCore and RuntimeViewerPackages come from their sibling Tuist
// projects. Third-party dependencies resolve through Tuist's external package
// integration so they remain eligible for binary caching.

let deploymentTargets: DeploymentTargets = .macOS("15.0")
let corePath: Path = "../RuntimeViewerCore"
let packagesPath: Path = "../RuntimeViewerPackages"

/// `Package.swift` declares `swiftLanguageModes: [.v5]`.
let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "5",
    "SWIFT_PACKAGE_NAME": "RuntimeViewerMCP",
]

let project = Project(
    name: "RuntimeViewerMCP",
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
            name: "RuntimeViewerMCPBridge",
            destinations: [.mac],
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerMCPBridge",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerMCPBridge/**"],
            dependencies: [
                .project(target: "RuntimeViewerCore", path: corePath),
                .project(target: "RuntimeViewerApplication", path: packagesPath),
                .project(target: "RuntimeViewerSettings", path: packagesPath),
                .external(name: "SwiftMCP"),
                // These modules are imported directly by the bridge sources.
                // SwiftPM exposes them through transitive products, while the
                // generated dynamic framework must declare them explicitly.
                .external(name: "MemberwiseInit"),
                .external(name: "FoundationToolbox"),
                .external(name: "Dependencies"),
                .external(name: "DependenciesMacros"),
                .external(name: "SwiftNavigation"),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerMCPBridgeTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "com.MxIris.RuntimeViewerMCPBridgeTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/RuntimeViewerMCPBridgeTests/**"],
            dependencies: [
                .target(name: "RuntimeViewerMCPBridge"),
                .project(target: "RuntimeViewerCore", path: corePath),
                .external(name: "Dependencies"),
            ],
            settings: .settings(base: baseSettings)
        ),
    ]
)

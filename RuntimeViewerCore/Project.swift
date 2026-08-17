import ProjectDescription

// Every dependency — including the reverse-engineering libraries that may be
// checked out next to this repository — resolves through Tuist's external
// integration. The local-checkout switch lives in Tuist/Package.swift, which
// rewrites those to `file://` source-control dependencies when
// USING_LOCAL_DEPENDENCIES is set. Keeping a single resolver is what prevents
// the same package from being built twice; see proposal 0012.

let destinations: Destinations = [.mac, .iPhone, .iPad, .macCatalyst, .appleWatch, .appleTv, .appleVision]

let deploymentTargets: DeploymentTargets = .multiplatform(
    iOS: "13.0",
    macOS: "10.15",
    watchOS: "6.0",
    tvOS: "13.0",
    visionOS: "1.0"
)

/// `Package.swift` declares `swiftLanguageModes: [.v5]`.
let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "5",
]

/// The two upcoming features the Swift targets opt into in `Package.swift`.
let upcomingFeatureSettings: SettingsDictionary = baseSettings.merging([
    "OTHER_SWIFT_FLAGS": "$(inherited) -enable-upcoming-feature InternalImportsByDefault -enable-upcoming-feature ImmutableWeakCaptures",
]) { _, new in new }

let project = Project(
    name: "RuntimeViewerCore",
    settings: .settings(
        base: [
            // Sources use Swift's `package` access level (e.g. `package enum DyldUtilities`).
            // Its scope is one Swift package, delimited by the compiler's `-package-name`
            // flag, which SwiftPM passes automatically but a generated Xcode target does
            // not get. Without this the declarations resolve as inaccessible — the
            // compiler reports them as `fileprivate`. Every target that participates in
            // this package must share the same value.
            "SWIFT_PACKAGE_NAME": "RuntimeViewerCore",
        ],
        configurations: [
            .debug(name: "Debug"),
            .debug(name: "Debug-arm64e"),
            .release(name: "Release"),
            .release(name: "Distribution"),
        ]
    ),
    targets: [
        .target(
            name: "RuntimeViewerCoreObjC",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerCoreObjC",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerCoreObjC/**"],
            headers: .headers(public: ["Sources/RuntimeViewerCoreObjC/include/**"]),
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerUtilities",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerUtilities",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerUtilities/**"],
            dependencies: [
                .external(name: "SwiftMobileGestalt"),
                .external(name: "LaunchServicesPrivate"),
                // SwiftPM links system frameworks implicitly; a generated Xcode
                // target must declare them.
                .sdk(name: "Security", type: .framework),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerCommunication",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerCommunication",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerCommunication/**"],
            dependencies: [
                .target(name: "RuntimeViewerCoreObjC"),
                // swift-helper-service is macOS-only, matching the
                // `.when(platforms: [.macOS])` conditions in Package.swift.
                .external(name: "HelperCommunication", condition: .when([.macos])),
                .external(name: "HelperPeer", condition: .when([.macos])),
                .external(name: "HelperClient", condition: .when([.macos])),
                .external(name: "ApplicationsServiceInterface", condition: .when([.macos])),
                .external(name: "FilesServiceInterface", condition: .when([.macos])),
                .external(name: "InjectionServiceInterface", condition: .when([.macos])),
                .external(name: "InjectedEndpointRegistryServiceInterface", condition: .when([.macos])),
                .external(name: "Asynchrone"),
                .external(name: "Semaphore"),
                .external(name: "MemberwiseInit"),
                .external(name: "Version"),
                .external(name: "FoundationToolbox"),
                .external(name: "MetaCodable"),
                // SwiftPM links system frameworks implicitly; a generated Xcode
                // target must declare them. Network carries NWEndpoint, which
                // appears in RuntimeConnectionCredential's layout.
                .sdk(name: "Network", type: .framework),
                .sdk(name: "SystemConfiguration", type: .framework, condition: .when([.macos, .ios, .catalyst])),
            ],
            settings: .settings(base: upcomingFeatureSettings)
        ),
        .target(
            name: "RuntimeViewerCore",
            destinations: destinations,
            product: .framework,
            bundleId: "com.MxIris.RuntimeViewerCore",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Sources/RuntimeViewerCore/**"],
            dependencies: [
                .target(name: "RuntimeViewerCoreObjC"),
                .target(name: "RuntimeViewerCommunication"),
                .external(name: "MachOKit"),
                .external(name: "MachOObjCSection"),
                .external(name: "ObjCDeclarationRendering"),
                .external(name: "ObjCIndexing"),
                .external(name: "ObjCInterface"),
                .external(name: "ObjCOutputTransformer"),
                .external(name: "MachOSwiftSection"),
                .external(name: "SwiftOutputTransformer"),
                .external(name: "SwiftDeclaration"),
                .external(name: "SwiftDeclarationRendering"),
                .external(name: "SwiftIndexing"),
                .external(name: "SwiftPrinting"),
                .external(name: "SwiftSpecialization"),
                .external(name: "SwiftInterface"),
                .external(name: "OutputTransformer"),
                .external(name: "MetaCodable"),
                .external(name: "Semaphore"),
                .external(name: "DequeModule"),
                // RuntimeConnectionCredential's layout embeds NWEndpoint, so this
                // target links Network too, not just RuntimeViewerCommunication.
                .sdk(name: "Network", type: .framework),
            ],
            settings: .settings(base: upcomingFeatureSettings)
        ),
        .target(
            name: "RuntimeViewerCoreTests",
            destinations: destinations,
            product: .unitTests,
            bundleId: "com.MxIris.RuntimeViewerCoreTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/RuntimeViewerCoreTests/**"],
            dependencies: [
                .target(name: "RuntimeViewerCore"),
                .target(name: "RuntimeViewerCommunication"),
            ],
            settings: .settings(base: baseSettings)
        ),
        .target(
            name: "RuntimeViewerCommunicationTests",
            destinations: destinations,
            product: .unitTests,
            bundleId: "com.MxIris.RuntimeViewerCommunicationTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["Tests/RuntimeViewerCommunicationTests/**"],
            dependencies: [
                .target(name: "RuntimeViewerCommunication"),
            ],
            settings: .settings(base: baseSettings)
        ),
    ]
)

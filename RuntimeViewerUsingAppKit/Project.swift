import ProjectDescription

// RuntimeViewer-Tuist.xcodeproj: the macOS app and everything it embeds, for the development-only
// Tuist workspace (Documentations/Guides/TuistDevelopment.md). It is generated beside
// RuntimeViewerUsingAppKit.xcodeproj so that $(SRCROOT) names the same directory in both projects,
// and every target takes its build settings from the same files under Configurations/ as its
// native counterpart. This manifest says only what Tuist cannot read from those files, or does
// differently; `./TuistScript.sh check` verifies that both projects stay wired to the same files.
//
// Target names match the native ones, so that `check` can pair them up.

/// The settings Tuist derives from the manifest and writes at the target level, handed back to the
/// xcconfig files: a target-level setting outranks the target's xcconfig, so Tuist's derived values
/// would otherwise win over the configuration both projects share. Tuist derives SDKROOT from the
/// destinations of every target, and the device-family keys from those of an iOS target. The
/// deployment targets would be derived too, which is why no target passes `deploymentTargets`. Every
/// target passes `$(inherited)` as its bundle identifier, which Tuist writes as it is.
///
/// The reference is spelled `${inherited}` on purpose. Xcode reads it exactly like `$(inherited)`,
/// but Tuist merges a value containing `$(inherited)` with the one it derived — SDKROOT would become
/// `$(inherited) macosx` — and replaces it only when the value does not.
let inheritedFromConfigurationFiles = "${inherited}"
let valuesFromConfigurationFiles: SettingsDictionary = [
    "SDKROOT": .string(inheritedFromConfigurationFiles),
    "TARGETED_DEVICE_FAMILY": .string(inheritedFromConfigurationFiles),
    "SUPPORTS_MACCATALYST": .string(inheritedFromConfigurationFiles),
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": .string(inheritedFromConfigurationFiles),
    "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": .string(inheritedFromConfigurationFiles),
]

/// Tuist warns about every target whose product name holds a variable, so a target whose name is
/// the same in every configuration states it as its `productName` instead, and Tuist writes that.
/// The app (RuntimeViewer-Debug, RuntimeViewer-Debug-arm64e, RuntimeViewer) and the daemon (the
/// configuration's RUNTIME_VIEWER_SERVICE_NAME) take theirs from the xcconfig.
let productNameFromConfigurationFiles: SettingsDictionary = [
    "PRODUCT_NAME": .string(inheritedFromConfigurationFiles),
]

/// Tuist links every package as a static library, from which the linker loads only the members
/// something refers to by symbol; Xcode's own integration, which the native projects use, links each
/// package target whole. Code the runtime looks up by name then goes missing: RxCocoa's DelegateProxy
/// finds its Objective-C superclass, _RXDelegateProxy, that way, and realizing any DelegateProxy
/// subclass aborts. -ObjC also loads every member that defines an Objective-C class or category or a
/// Swift type or extension. Tuist/Package.swift gives the local packages' test bundles the same flag.
let packageLinkingSettings: SettingsDictionary = [
    "OTHER_LDFLAGS": ["$(inherited)", "-ObjC"],
]

/// The targets the `RuntimeViewer macOS` scheme builds in a fixed order; see the scheme.
let manuallyOrderedTargetSettings: SettingsDictionary = [
    "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
]

/// A target's settings, configuration by configuration, from the files in
/// `Configurations/<directory>`: each configuration's own file where the native target has one,
/// `Shared.xcconfig` otherwise, plus `packageLinkingSettings`. `additionalSettings` apply to every
/// configuration, `debugAdditionalSettings` to Debug and Debug-arm64e only.
func targetSettings(
    directory: String,
    configurationsWithOwnFile: Set<String> = ["Debug", "Debug-arm64e", "Release"],
    additionalSettings: SettingsDictionary = [:],
    debugAdditionalSettings: SettingsDictionary = [:]
) -> Settings {
    func file(_ configuration: String) -> Path {
        let fileName = configurationsWithOwnFile.contains(configuration) ? configuration : "Shared"
        return .relativeToManifest("../Configurations/\(directory)/\(fileName).xcconfig")
    }
    return .settings(
        base: valuesFromConfigurationFiles
            .merging(packageLinkingSettings) { $1 }
            .merging(additionalSettings) { $1 },
        configurations: [
            .debug(name: "Debug", settings: debugAdditionalSettings, xcconfig: file("Debug")),
            .debug(name: "Debug-arm64e", settings: debugAdditionalSettings, xcconfig: file("Debug-arm64e")),
            .release(name: "Release", xcconfig: file("Release")),
        ],
        defaultSettings: .none
    )
}

/// Shared with the native project's build phase of the same name.
let generateLaunchDaemonPlist: TargetScript = .post(
    script: "\"${SRCROOT}/BuildPhases/GenerateLaunchDaemonPlist.sh\"",
    name: "Generate LaunchDaemon plist",
    basedOnDependencyAnalysis: false
)

/// The daemon is named after the configuration being built, and a Copy Files reference to its
/// product resolves the file name in the default configuration only — Debug-arm64e and Release
/// would embed the Debug daemon. The native project copies a file reference whose path is
/// $(RUNTIME_VIEWER_SERVICE_NAME), which Tuist cannot express, so here it is a build phase.
let embedLaunchDaemon: TargetScript = .post(
    script: """
    set -e
    sourcePath="${BUILT_PRODUCTS_DIR}/${RUNTIME_VIEWER_SERVICE_NAME}"
    destinationDirectory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchServices"
    mkdir -p "$destinationDirectory"
    /usr/bin/ditto "$sourcePath" "$destinationDirectory/${RUNTIME_VIEWER_SERVICE_NAME}"
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY}" ]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$destinationDirectory/${RUNTIME_VIEWER_SERVICE_NAME}"
    fi
    """,
    name: "Embed LaunchServices",
    inputPaths: ["$(BUILT_PRODUCTS_DIR)/$(RUNTIME_VIEWER_SERVICE_NAME)"],
    outputPaths: ["$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchServices/$(RUNTIME_VIEWER_SERVICE_NAME)"]
)

let project = Project(
    name: "RuntimeViewer-Tuist",
    options: .options(
        automaticSchemesOptions: .disabled,
        disableBundleAccessors: true,
        disableSynthesizedResourceAccessors: true
    ),
    settings: .settings(
        configurations: [
            .debug(name: "Debug", xcconfig: "../Configurations/RuntimeViewerUsingAppKitProject/Debug.xcconfig"),
            .debug(name: "Debug-arm64e", xcconfig: "../Configurations/RuntimeViewerUsingAppKitProject/Debug-arm64e.xcconfig"),
            .release(name: "Release", xcconfig: "../Configurations/RuntimeViewerUsingAppKitProject/Release.xcconfig"),
        ],
        defaultSettings: .none
    ),
    targets: [
        .target(
            name: "RuntimeViewerUsingAppKit",
            destinations: .macOS,
            product: .app,
            productName: "RuntimeViewer",
            bundleId: "$(inherited)",
            infoPlist: nil,
            resources: [
                "../Resources/AppIcon.icon",
                "../Resources/AppIconBeta.icon",
                "../Resources/AppIconXcode26.icon",
                "../Resources/AppIconBetaXcode26.icon",
            ],
            buildableFolders: [
                .folder("RuntimeViewerUsingAppKit", exceptions: .exceptions([.exception(excluded: ["Info.plist"])])),
            ],
            copyFiles: [
                .wrapper(
                    name: "Embed RuntimeViewerCLI",
                    subpath: "Contents/Applications",
                    files: [.buildProduct(name: "RuntimeViewerCommandLineTool", codeSignOnCopy: true)]
                ),
                // The two injection payloads are copied, never linked, and neither is a
                // dependency: Tuist embeds every framework an app can reach in Frameworks/, whatever
                // the link status, and an iOS Simulator framework there fails validation. Xcode
                // finds the macOS payload through this phase as an implicit dependency; the
                // simulator one, of another platform, is built first by the scheme instead.
                .resources(
                    name: "Embed RuntimeViewerServer Framework",
                    files: [.buildProduct(name: "RuntimeViewerServer", codeSignOnCopy: true)]
                ),
                .resources(
                    name: "Embed RuntimeViewerMobileServer Framework",
                    files: [.buildProduct(name: "RuntimeViewerSimulatorServer", codeSignOnCopy: true)]
                ),
                .wrapper(
                    name: "Embed Catalyst Helpers",
                    subpath: "Contents/Applications",
                    files: [.buildProduct(name: "RuntimeViewerCatalystHelper", codeSignOnCopy: true)]
                ),
            ],
            scripts: [
                generateLaunchDaemonPlist,
                embedLaunchDaemon,
            ],
            dependencies: [
                .target(name: "RuntimeViewerCommandLineTool"),
                .target(name: "com.mxiris.runtimeviewer.service"),
                .target(name: "RuntimeViewerCatalystHelper"),
                // Tuist embeds these two itself, in PlugIns and XPCServices.
                .target(name: "RuntimeViewerSourceEditorBridge"),
                .target(name: "RuntimeViewerLocalRuntimeService"),
                .external(name: "RuntimeViewerApplication"),
                .external(name: "RuntimeViewerCatalystExtensions"),
                .external(name: "RuntimeViewerMCPBridge"),
                .external(name: "RuntimeViewerCommandLineInterface"),
                .external(name: "RuntimeViewerInjection"),
                .external(name: "RuntimeViewerUtilities"),
                .external(name: "Sparkle"),
            ],
            settings: targetSettings(
                directory: "RuntimeViewerUsingAppKit",
                additionalSettings: manuallyOrderedTargetSettings.merging(productNameFromConfigurationFiles) { $1 }
            )
        ),
        // A Mac Catalyst app, declared for macOS because Tuist's graph linter refuses a macOS app
        // that depends on an iOS-platform target. Its xcconfig pins the real platform
        // (SDKROOT = macosx, SDK_VARIANT = iosmac), as it does for the native target.
        .target(
            name: "RuntimeViewerCatalystHelper",
            destinations: .macOS,
            product: .app,
            productName: "RuntimeViewerCatalystHelper",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("RuntimeViewerCatalystHelper", exceptions: .exceptions([.exception(excluded: ["Info.plist"])])),
            ],
            copyFiles: [
                .plugins(
                    name: "Embed PlugIns",
                    files: [.buildProduct(name: "RuntimeViewerCatalystHelperPlugin", codeSignOnCopy: true)]
                ),
            ],
            settings: targetSettings(directory: "RuntimeViewerCatalystHelper")
        ),
        // The macOS bundle the Catalyst helper loads. Tuist never links static products into a
        // .bundle, so it is declared as a framework that keeps the .bundle extension; the helper
        // loads it by path either way. Not a dependency of the helper: with the binary cache on,
        // Tuist drops such a dependency, so the scheme builds it first instead.
        .target(
            name: "RuntimeViewerCatalystHelperPlugin",
            destinations: .macOS,
            product: .framework,
            productName: "RuntimeViewerCatalystHelperPlugin",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder(
                    "RuntimeViewerCatalystHelperPlugin",
                    exceptions: .exceptions([.exception(target: "RuntimeViewerCatalystHelper", included: ["AppKitPlugin.swift"])])
                ),
            ],
            dependencies: [
                .external(name: "RuntimeViewerCore"),
                .external(name: "RuntimeViewerCommunication"),
                .external(name: "RuntimeViewerCatalystExtensions"),
                .external(name: "RuntimeViewerInjection"),
            ],
            settings: targetSettings(
                directory: "RuntimeViewerCatalystHelperPlugin",
                configurationsWithOwnFile: [],
                additionalSettings: manuallyOrderedTargetSettings.merging([
                    // Nothing imports the plugin; as a framework it would otherwise carry a module
                    // and a generated header the native bundle does not have.
                    "SWIFT_INSTALL_MODULE": "NO",
                    "SWIFT_INSTALL_OBJC_HEADER": "NO",
                ]) { $1 },
                // The native plugin builds every architecture even in Debug. Its packages here are
                // ordinary targets, built once for the architectures the app asks for (the active
                // one in Debug); a dependent asking for x86_64 as well gets the same targets built
                // twice into one products directory, and its x86_64 compile reads a generated header
                // that holds arm64 only. SwiftPM packages in the native workspaces are specialized
                // per dependent instead.
                debugAdditionalSettings: ["ONLY_ACTIVE_ARCH": "YES"]
            )
        ),
        // The iOS Simulator injection payload. Its xcconfig pins SDKROOT = iphonesimulator.
        .target(
            name: "RuntimeViewerSimulatorServer",
            destinations: [.iPhone, .iPad],
            product: .framework,
            productName: "RuntimeViewerMobileServer",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("../RuntimeViewerServer/RuntimeViewerServer"),
            ],
            dependencies: [
                .external(name: "RuntimeViewerCore"),
                .external(name: "RuntimeViewerInjection"),
                .external(name: "RuntimeViewerUtilities"),
            ],
            settings: targetSettings(
                directory: "RuntimeViewerSimulatorServer",
                configurationsWithOwnFile: [],
                additionalSettings: manuallyOrderedTargetSettings
            )
        ),
        // The macOS injection payload; from RuntimeViewerServer.xcodeproj in the native workspaces.
        .target(
            name: "RuntimeViewerServer",
            destinations: .macOS,
            product: .framework,
            productName: "RuntimeViewerServer",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("../RuntimeViewerServer/RuntimeViewerServer"),
            ],
            dependencies: [
                .external(name: "RuntimeViewerCore"),
                .external(name: "RuntimeViewerInjection"),
                .external(name: "RuntimeViewerUtilities"),
            ],
            settings: targetSettings(directory: "RuntimeViewerServer")
        ),
        // The privileged helper daemon, named after the configuration's RUNTIME_VIEWER_SERVICE_NAME
        // (PRODUCT_NAME comes from the xcconfig). `productName` names only the product reference,
        // which nothing copies: the app embeds the daemon with a build phase.
        .target(
            name: "com.mxiris.runtimeviewer.service",
            destinations: .macOS,
            product: .commandLineTool,
            productName: "com.mxiris.runtimeviewer.service",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("RuntimeViewerService"),
            ],
            dependencies: [
                .external(name: "RuntimeViewerService"),
            ],
            settings: targetSettings(directory: "LaunchDaemon", additionalSettings: productNameFromConfigurationFiles)
        ),
        .target(
            name: "RuntimeViewerLocalRuntimeService",
            destinations: .macOS,
            product: .xpc,
            productName: "RuntimeViewerLocalRuntimeService",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("RuntimeViewerLocalRuntimeService", exceptions: .exceptions([.exception(excluded: ["Info.plist"])])),
            ],
            dependencies: [
                .external(name: "RuntimeViewerCore"),
                .external(name: "RuntimeViewerCommunication"),
                .external(name: "RuntimeViewerInjection"),
            ],
            settings: targetSettings(directory: "RuntimeViewerLocalRuntimeService")
        ),
        .target(
            name: "RuntimeViewerCommandLineTool",
            destinations: .macOS,
            product: .commandLineTool,
            productName: "runtime-viewer-cli",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("runtime-viewer-cli"),
            ],
            dependencies: [
                .external(name: "RuntimeViewerCommandLineInterface"),
                .external(name: "RuntimeViewerInjection"),
            ],
            settings: targetSettings(directory: "RuntimeViewerCommandLineTool", configurationsWithOwnFile: [])
        ),
        .target(
            name: "RuntimeViewerSourceEditorBridge",
            destinations: .macOS,
            product: .bundle,
            productName: "RuntimeViewerSourceEditorBridge",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder(
                    "RuntimeViewerSourceEditorBridge",
                    exceptions: .exceptions([
                        // The protocol the app talks to the bridge through.
                        .exception(target: "RuntimeViewerUsingAppKit", included: ["SourceEditorBridging.swift"]),
                        .exception(target: "RuntimeViewerSourceEditorBridgeTests", included: ["SourceEditorBridging.swift"]),
                    ])
                ),
            ],
            settings: targetSettings(directory: "RuntimeViewerSourceEditorBridge", configurationsWithOwnFile: ["Debug-arm64e"])
        ),
        // Loads the bridge bundle from beside itself in the products directory. Tuist does not let a
        // test target depend on a bundle, so the test scheme in Workspace.swift builds the bridge.
        .target(
            name: "RuntimeViewerSourceEditorBridgeTests",
            destinations: .macOS,
            product: .unitTests,
            productName: "RuntimeViewerSourceEditorBridgeTests",
            bundleId: "$(inherited)",
            infoPlist: nil,
            buildableFolders: [
                .folder("RuntimeViewerSourceEditorBridgeTests"),
            ],
            settings: targetSettings(directory: "RuntimeViewerSourceEditorBridgeTests", configurationsWithOwnFile: ["Debug-arm64e"])
        ),
    ],
    schemes: [
        // The only scheme that builds the app here. The two products of another platform than the
        // app's — the simulator payload and the Catalyst helper's plugin — are not dependencies of
        // anything (see their targets), so this scheme builds them first, in a fixed order. Building
        // the app target on its own leaves them unbuilt and its copy phases fail.
        .scheme(
            name: "RuntimeViewer macOS",
            buildAction: .buildAction(
                targets: ["RuntimeViewerSimulatorServer", "RuntimeViewerCatalystHelperPlugin", "RuntimeViewerUsingAppKit"],
                buildOrder: .manual
            ),
            runAction: .runAction(configuration: "Debug", executable: "RuntimeViewerUsingAppKit")
        ),
    ]
)

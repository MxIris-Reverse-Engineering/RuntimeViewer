// swift-tools-version: 6.2
import PackageDescription

// The dependencies of RuntimeViewer-Tuist.xcworkspace, the development-only Tuist workspace
// (Documentations/Guides/TuistDevelopment.md). The four local packages are declared by path, so
// their own Package.swift files stay the only definition of their targets and dependencies.

#if TUIST
    import ProjectDescription
    import ProjectDescriptionHelpers

    // Tuist suppresses warnings in every package; Xcode does so for remote packages only, so the
    // local packages' targets get theirs back.
    let localPackageWarnings: [String: Settings] = Dictionary(
        uniqueKeysWithValues: LocalPackages.sourceTargetNames.map { targetName in
            (targetName, .settings(base: ["SWIFT_SUPPRESS_WARNINGS": "NO", "GCC_WARN_INHIBIT_ALL_WARNINGS": "NO"]))
        }
    )

    // Tuist drops a package setting whose only condition is a trait. MachOSwiftSection enables
    // swift-capstone's AARCH64 trait, which defines CAPSTONE_HAS_AARCH64 for both the Swift wrapper
    // and the C library this way. Without it the wrapper does not compile, and the C library would
    // compile but support no architecture at all. `./TuistScript.sh check` looks for any other
    // trait-only definition an enabled trait would need.
    let restatedTraitDefinitions: [String: Settings] = [
        "Capstone": .settings(base: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "CAPSTONE_HAS_AARCH64"],
            "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "CAPSTONE_HAS_AARCH64=1"],
        ]),
        "Ccapstone": .settings(base: [
            "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "CAPSTONE_HAS_AARCH64=1"],
        ]),
    ]

    // The local packages' test bundles, which SwiftPM builds differently in two ways:
    // - It links each package target whole, where Tuist links packages as static libraries and the
    //   linker loads only the members something refers to by symbol. Code the runtime looks up by
    //   name then goes missing: RxCocoa's DelegateProxy finds its Objective-C superclass,
    //   _RXDelegateProxy, that way, and realizing any of its subclasses aborts. -ObjC also loads every
    //   member that defines an Objective-C class or category or a Swift type or extension. The app's
    //   targets get the same flag in RuntimeViewerUsingAppKit/Project.swift.
    // - It builds a test target for at least the macOS version XCTest and Swift Testing require
    //   (14.0 with Xcode 26 and 27), whatever its package declares; Tuist uses the package's own
    //   minimum, which for RuntimeViewerCore (10.15) leaves its tests without APIs such as Duration.
    //   The other three packages declare macOS 15 already.
    let localTestTargetSettings: [String: Settings] = Dictionary(
        uniqueKeysWithValues: LocalPackages.testTargetNames.flatMap { entry in
            entry.targets.map { targetName in
                var settings: SettingsDictionary = ["OTHER_LDFLAGS": ["$(inherited)", "-ObjC"]]
                if entry.package == "RuntimeViewerCore" {
                    settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
                }
                return (targetName, Settings.settings(base: settings))
            }
        }
    )

    // Tuist turns every package into ordinary Xcode targets. Each setting below restores something
    // Xcode's own SwiftPM integration, which the native workspaces use, does differently.
    let packageSettings = PackageSettings(
        // AppKit re-exports Apple's private UIFoundation.framework; a static framework of the same
        // name on the search path captures that re-export at link time, and the app's link then
        // misses every AppKit text symbol (NSFont, the attribute names). A product's type reaches its
        // whole in-package closure, so the two Objective-C targets are pinned back by target name: as
        // static libraries their headers go to the shared include/ directory, which the binary cache
        // then packs into both of their XCFrameworks.
        productTypes: [
            "UIFoundation": .staticLibrary,
            "UIFoundationAppleInternalObjC": .staticFramework,
            "UIFoundationCarbonInternal": .staticFramework,
        ],
        // A package that declares no limits counts as supporting every platform. Tuist then gives a
        // local package's test target the union of its dependencies' platforms, which includes iOS as
        // soon as RuntimeViewerCore's products are built for the iOS Simulator payload, and rejects
        // every test that also depends on a macOS-only target. Narrowing the products of the three
        // packages only the macOS app uses narrows their tests with them.
        productDestinations: Dictionary(
            uniqueKeysWithValues: LocalPackages.macOSOnlyProductNames.map { productName in (productName, .macOS) }
        ),
        baseSettings: .settings(
            base: [
                // Xcode's own integration copies a package's .strings files without validating them,
                // and KeyboardShortcuts 2.4.0 ships one that does not validate.
                "VALIDATE_STRINGS_FILES_WHILE_COPYING": "NO",
            ],
            // In Debug-arm64e and Release the helper daemon and the macOS payload are arm64e, so the
            // packages they link need that slice too. The native workspaces build a package once for
            // each target that links it, with that target's settings; here a package is one target
            // shared by every dependent, so it builds the extra slice for all of them.
            configurations: [
                .debug(name: "Debug"),
                .debug(name: "Debug-arm64e", settings: ["ENABLE_POINTER_AUTHENTICATION": "YES"]),
                .release(name: "Release", settings: ["ENABLE_POINTER_AUTHENTICATION": "YES"]),
            ]
        ),
        targetSettings: localPackageWarnings
            .merging(restatedTraitDefinitions) { $1 }
            .merging(localTestTargetSettings) { $1 },
        includeLocalPackageTestTargets: true
    )
#endif

let package = Package(
    name: "RuntimeViewerTuistDependencies",
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        .package(path: "../RuntimeViewerPackages"),
        .package(path: "../RuntimeViewerMCP"),
        .package(path: "../RuntimeViewerCommandLine"),
        // Stands in for swift-syntax in every macro package, as it does as a member of the native
        // workspaces: SwiftPM matches it by package identity.
        .package(path: "../RuntimeViewerPrecompiledLibraries/swift-syntax"),
        // The app's only dependency that none of the local packages declares.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
    ]
)

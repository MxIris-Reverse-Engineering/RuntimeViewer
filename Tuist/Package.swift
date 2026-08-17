// swift-tools-version: 6.2

import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    // The app projects build under four configurations. External dependency
    // projects must expose the same set, otherwise a build under, say,
    // `Debug-arm64e` finds no matching configuration in them.
    baseSettings: .settings(
        configurations: [
            .debug(name: "Debug"),
            .debug(name: "Debug-arm64e"),
            .release(name: "Release"),
            .release(name: "Distribution"),
        ]
    )
)
#endif

// Aggregated remote dependencies of RuntimeViewerCore, RuntimeViewerPackages and
// RuntimeViewerMCP. Each package keeps its own Package.swift (see proposal 0012);
// this manifest exists so Tuist can resolve the same graph through its external
// integration and make it eligible for binary caching.
//
// Version constraints are the *intersection* of what the three manifests declare.
// Where they disagreed, the stricter bound wins and is noted inline.
let package = Package(
    name: "RuntimeViewerDependencies",
    dependencies: [
        // MARK: - Reverse engineering core (RuntimeViewerCore)

        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachOKit", exact: "0.52.101"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachOObjCSection", exact: "0.8.105"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection", exact: "0.15.2"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/swift-semantic-string", from: "0.3.0"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/LaunchServicesPrivate", from: "0.1.0"),

        // MARK: - Shared infrastructure

        .package(url: "https://github.com/MxIris-Library-Forks/Asynchrone", from: "0.23.0-fork.1"),
        .package(url: "https://github.com/MxIris-Library-Forks/Semaphore", from: "0.1.1"),
        .package(url: "https://github.com/MxIris-Library-Forks/swift-mobile-gestalt", from: "0.5.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.5.1"),
        .package(url: "https://github.com/Mx-Iris/FrameworkToolbox", from: "0.7.1"),
        .package(url: "https://github.com/mxcl/Version", from: "2.2.1"),
        .package(url: "https://github.com/SwiftyLab/MetaCodable", from: "1.6.0"),
        .package(url: "https://github.com/gohanlon/swift-memberwise-init-macro", from: "0.6.0"),
        // RuntimeViewerCore requires >= 0.3.1, RuntimeViewerPackages only >= 0.1.5.
        // The stricter Core bound governs.
        .package(url: "https://github.com/Mx-Iris/swift-helper-service", from: "0.3.1"),

        // MARK: - UI stack (RuntimeViewerPackages)

        .package(
            url: "https://github.com/Mx-Iris/UIFoundation",
            from: "0.17.0",
            traits: [
                "AppleInternal",
                "FilterUI",
                "IDEIcons",
                "NSAttributedStringBuilder",
                "QuickActionBar",
                "Settings",
                "TabBar",
            ]
        ),
        .package(url: "https://github.com/Mx-Iris/CocoaCoordinator", from: "0.5.0"),
        .package(url: "https://github.com/MxIris-Library-Forks/XCoordinator", from: "3.0.0-beta.1"),
        .package(url: "https://github.com/OpenUXKit/UXKitCoordinator", branch: "main"),
        .package(url: "https://github.com/OpenUXKit/OpenUXKit", branch: "main"),
        .package(url: "https://github.com/SnapKit/SnapKit", from: "6.0.0"),
        .package(url: "https://github.com/Mx-Iris/SFSymbols", from: "0.3.0"),
        .package(url: "https://github.com/Mx-Iris/SystemHUD", from: "0.1.0"),
        .package(url: "https://github.com/Mx-Iris/RunningApplicationKit", from: "0.5.0"),
        .package(url: "https://github.com/MxIris-Library-Forks/LateResponders", from: "1.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        .package(url: "https://github.com/ChimeHQ/Rearrange", from: "2.1.1"),

        // MARK: - Rx stack

        .package(url: "https://github.com/ReactiveX/RxSwift", from: "6.10.2"),
        .package(url: "https://github.com/Mx-Iris/RxAppKit", from: "0.5.4"),
        .package(url: "https://github.com/Mx-Iris/RxUIKit", from: "0.1.2"),
        .package(url: "https://github.com/Mx-Iris/RxSwiftPlus", from: "0.2.3"),
        .package(url: "https://github.com/CombineCommunity/RxCombine", from: "2.0.1"),
        .package(url: "https://github.com/gringoireDM/RxEnumKit", from: "2.0.0"),
        .package(url: "https://github.com/TrGiLong/RxConcurrency", from: "0.1.1"),

        // MARK: - Search / state

        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.13.1"),
        .package(url: "https://github.com/MxIris-Library-Forks/swift-navigation", from: "2.8.100"),
        .package(url: "https://github.com/ukushu/Ifrit", from: "4.0.0"),
        .package(url: "https://github.com/MxIris-Library-Forks/fuzzy-search", from: "0.1.0"),

        // MARK: - MCP (RuntimeViewerMCP)

        .package(
            url: "https://github.com/Cocoanetics/SwiftMCP",
            from: "1.9.0",
            traits: ["Client", "OpenAPI", "Server"]
        ),
    ]
)

// NOTE: This manifest intentionally diverges from the one in the main checkout,
// for the same reason RuntimeViewerCore/Package.swift does (see a540f4fe):
// SwiftPM keys its manifest-evaluation cache on file content, and the main
// checkout and this worktree resolve relative local-dependency candidates to
// different paths. Identical bytes on both sides let one be served the other's
// cached evaluation, which shows up as local path dependencies silently
// degrading to remote tags. Keep this trailing comment.

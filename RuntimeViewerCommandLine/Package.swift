// swift-tools-version: 6.2

import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: #filePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "RuntimeViewerCommandLine",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RuntimeViewerCommandLineInterface",
            targets: ["RuntimeViewerCommandLineInterface"]
        ),
        .executable(
            name: "runtime-viewer-cli",
            targets: ["runtime-viewer-cli"]
        ),
    ],
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        // Engine management (all runtime sources, attach) and the helper
        // client it needs. Only the UI-free products are linked.
        .package(path: "../RuntimeViewerPackages"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // Same range as RuntimeViewerPackages, whose `@Dependency` entries the
        // headless host overrides at its entry point.
        .package(url: "https://github.com/pointfreeco/swift-dependencies", "1.13.1" ..< "1.16.0"),
        // RuntimeViewerCore pins FrameworkToolbox exactly; a floor here resolves
        // to the same version and keeps working once that pin is lifted.
        .package(url: "https://github.com/Mx-Iris/FrameworkToolbox", from: "0.9.0"),
        // Test-only: a controllable clock for the host's idle timer.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "RuntimeViewerCommandLineInterface",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerEngineManagement", package: "RuntimeViewerPackages"),
                .product(name: "RuntimeViewerHelperClient", package: "RuntimeViewerPackages"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .executableTarget(
            name: "runtime-viewer-cli",
            dependencies: [
                "RuntimeViewerCommandLineInterface",
            ]
        ),
        .testTarget(
            name: "RuntimeViewerCommandLineTests",
            dependencies: [
                "RuntimeViewerCommandLineInterface",
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerEngineManagement", package: "RuntimeViewerPackages"),
                .product(name: "RuntimeViewerHelperClient", package: "RuntimeViewerPackages"),
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

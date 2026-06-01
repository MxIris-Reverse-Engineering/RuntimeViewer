// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let localEnvironment: [String: String] = {
    let localEnvironmentFilePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(".package.env")
        .path
    guard FileManager.default.fileExists(atPath: localEnvironmentFilePath),
          let contents = try? String(contentsOfFile: localEnvironmentFilePath, encoding: .utf8)
    else {
        return [:]
    }
    var environment: [String: String] = [:]
    for line in contents.components(separatedBy: .newlines) {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
            continue
        }
        let parts = trimmedLine.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        environment[key] = value
    }
    return environment
}()

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = localEnvironment[key] ?? Context.environment[key]
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

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS, .macCatalyst, .watchOS]

let package = Package(
    name: "RuntimeViewerCore",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .macCatalyst(.v13), .watchOS(.v6), .tvOS(.v13), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "RuntimeViewerCore",
            targets: ["RuntimeViewerCore"],
        ),
        .library(
            name: "RuntimeViewerCommunication",
            targets: ["RuntimeViewerCommunication"],
        ),
        .library(
            name: "RuntimeViewerUtilities",
            targets: ["RuntimeViewerUtilities"],
        ),
    ],
    dependencies: [
        .package(
            local: .package(
                path: "../../MachOKit",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOKit",
                from: "0.50.100",
            ),
        ),
        .package(
            local: .package(
                path: "../../MachOObjCSection",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOObjCSection",
                from: "0.6.101",
            ),
        ),
        .package(
            local: .package(
                path: "../../MachOSwiftSection",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection",
                exact: "0.12.0-beta.2",
            ),
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/Asynchrone",
            from: "0.23.0-fork",
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/Semaphore",
            from: "0.1.0",
        ),
        .package(
            url: "https://github.com/apple/swift-collections",
            from: "1.1.0",
        ),
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox",
            from: "0.5.5",
        ),
        .package(
            local: .package(
                path: "../../../../Personal/Library/macOS/swift-helper-service",
                isRelative: true,
            ),
            .package(
                path: "../../swift-helper-service",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/swift-helper-service",
                from: "0.1.2",
            ),
        ),
        .package(
            url: "https://github.com/gohanlon/swift-memberwise-init-macro",
            from: "0.6.0",
        ),
        .package(
            url: "https://github.com/mxcl/Version",
            from: "2.2.0",
        ),
        .package(
            url: "https://github.com/SwiftyLab/MetaCodable",
            from: "1.6.0",
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/swift-mobile-gestalt",
            from: "0.5.0",
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/LaunchServicesPrivate",
            from: "0.1.0",
        ),
//        .package(
//            url: "https://github.com/CheekyGhost-Labs/OSLogClient",
//            from: "2.0.0"
//        ),
    ],
    targets: [
        .target(
            name: "RuntimeViewerCoreObjC",
        ),
        .target(
            name: "RuntimeViewerCore",
            dependencies: [
                "RuntimeViewerCoreObjC",
                "RuntimeViewerCommunication",
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "MachOSwiftSection", package: "MachOSwiftSection"),
                .product(name: "SwiftInterface", package: "MachOSwiftSection"),
                .product(name: "MetaCodable", package: "MetaCodable"),
                .product(name: "Semaphore", package: "Semaphore"),
                .product(name: "DequeModule", package: "swift-collections"),
            ],
            swiftSettings: [
                .internalImportsByDefault,
                .immutableWeakCaptures,
            ],
        ),
        .target(
            name: "RuntimeViewerCommunication",
            dependencies: [
                .product(name: "HelperCommunication", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "HelperPeer", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "HelperClient", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "ApplicationsServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "FilesServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "InjectionServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "InjectedEndpointRegistryServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Asynchrone", package: "Asynchrone"),
                .product(name: "Semaphore", package: "Semaphore"),
                .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
                .product(name: "Version", package: "Version"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
                .product(name: "MetaCodable", package: "MetaCodable"),
            ],
            swiftSettings: [
                .internalImportsByDefault,
                .immutableWeakCaptures,
            ],
        ),
        .target(
            name: "RuntimeViewerUtilities",
            dependencies: [
                .product(name: "SwiftMobileGestalt", package: "swift-mobile-gestalt"),
                .product(name: "LaunchServicesPrivate", package: "LaunchServicesPrivate"),
            ],
        ),
        .testTarget(
            name: "RuntimeViewerCoreTests",
            dependencies: [
                "RuntimeViewerCore",
                "RuntimeViewerCommunication",
            ],
        ),
        .testTarget(
            name: "RuntimeViewerCommunicationTests",
            dependencies: [
                "RuntimeViewerCommunication",
            ],
        ),
    ],
    swiftLanguageModes: [.v5],
)

extension SwiftSetting {
    static let existentialAny: Self = .enableUpcomingFeature("ExistentialAny") // SE-0335, Swift 5.6,  SwiftPM 5.8+
    static let internalImportsByDefault: Self = .enableUpcomingFeature("InternalImportsByDefault") // SE-0409, Swift 6.0,  SwiftPM 6.0+
    static let memberImportVisibility: Self = .enableUpcomingFeature("MemberImportVisibility") // SE-0444, Swift 6.1,  SwiftPM 6.1+
    static let inferIsolatedConformances: Self = .enableUpcomingFeature("InferIsolatedConformances") // SE-0470, Swift 6.2,  SwiftPM 6.2+
    static let nonisolatedNonsendingByDefault: Self = .enableUpcomingFeature("NonisolatedNonsendingByDefault") // SE-0461, Swift 6.2,  SwiftPM 6.2+
    static let immutableWeakCaptures: Self = .enableUpcomingFeature("ImmutableWeakCaptures") // SE-0481, Swift 6.2,  SwiftPM 6.2+
}

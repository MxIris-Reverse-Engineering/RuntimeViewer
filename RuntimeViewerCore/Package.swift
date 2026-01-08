// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool)
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: #filePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path)
                }
            }
        }
        return remote
    }
}



let package = Package(
    name: "Core",
    platforms: [
        .iOS(.v13), .macOS(.v10_15), .macCatalyst(.v13), .watchOS(.v6), .tvOS(.v13), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "RuntimeViewerCore",
            targets: ["RuntimeViewerCore"]
        ),
        .library(
            name: "RuntimeViewerCommunication",
            targets: ["RuntimeViewerCommunication"]
        ),

    ],
    dependencies: [
        .package(
            local: .package(
                path: "../../MachOKit",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOKit.git",
                branch: "main"
            ),
        ),
        .package(
            local: .package(
                path: "../../MachOObjCSection",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOObjCSection.git",
                branch: "main"
            ),
        ),
        .package(
            local: .package(
                path: "../../MachOSwiftSection",
                isRelative: true,
                isEnabled: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection",
//                from: "0.6.0"
                branch: "feature/in-process",
            )
        ),
        .package(
            url: "https://github.com/apple/swift-collections",
            from: "1.2.0"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/Asynchrone",
            from: "0.23.0-fork"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/Semaphore",
            branch: "main"
        ),
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            branch: "main"
        ),
        .package(
            url: "https://github.com/apple/swift-log",
            from: "1.6.3"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/swift-memberwise-init-macro",
            from: "0.5.3-fork"
        ),
    ],
    targets: [
        .target(
            name: "RuntimeViewerObjC"
        ),
        .target(
            name: "RuntimeViewerCore",
            dependencies: [
                "RuntimeViewerObjC",
                "RuntimeViewerCommunication",
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "SwiftInterface", package: "MachOSwiftSection"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
            ],
            swiftSettings: [
                .internalImportsByDefault
            ],
        ),
        .target(
            name: "RuntimeViewerCommunication",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Asynchrone", package: "Asynchrone"),
                .product(name: "Semaphore", package: "Semaphore"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
            ],
            swiftSettings: [
                .internalImportsByDefault
            ],
        ),
    ],
    swiftLanguageModes: [.v5]
)

extension SwiftSetting {
    static let existentialAny: Self = .enableUpcomingFeature("ExistentialAny")                                    // SE-0335, Swift 5.6,  SwiftPM 5.8+
    static let internalImportsByDefault: Self = .enableUpcomingFeature("InternalImportsByDefault")                // SE-0409, Swift 6.0,  SwiftPM 6.0+
    static let memberImportVisibility: Self = .enableUpcomingFeature("MemberImportVisibility")                    // SE-0444, Swift 6.1,  SwiftPM 6.1+
    static let inferIsolatedConformances: Self = .enableUpcomingFeature("InferIsolatedConformances")              // SE-0470, Swift 6.2,  SwiftPM 6.2+
    static let nonisolatedNonsendingByDefault: Self = .enableUpcomingFeature("NonisolatedNonsendingByDefault")    // SE-0461, Swift 6.2,  SwiftPM 6.2+
    static let immutableWeakCaptures: Self = .enableUpcomingFeature("ImmutableWeakCaptures")                      // SE-0481, Swift 6.2,  SwiftPM 6.2+
}

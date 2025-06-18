// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

extension Package.Dependency {
    
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool)
    }
    
    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative):
                let url = if isRelative, let resolvedURL = URL(string: path, relativeTo: URL(fileURLWithPath: #filePath)) {
                    resolvedURL
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
        .iOS(.v14), .macOS(.v12), .macCatalyst(.v14), .tvOS(.v14), .watchOS(.v6), .visionOS(.v1),
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
                path: "../../../../Fork/Library/ClassDumpRuntime",
                isRelative: true
            ),
            .package(
                path: "../../ClassDumpRuntime",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/ClassDumpRuntime",
                branch: "master"
            )
        ),
        .package(
            local: .package(
                path: "../../../../Personal/Library/macOS/MachOSwiftSection",
                isRelative: true
            ),
            .package(
                path: "../../TestingLibraries/MachOSwiftSection",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection",
                from: "0.4.0"
            )
        ),
        .package(
            url: "https://github.com/apple/swift-collections",
            from: "1.2.0"
        ),
        .package(
            url: "https://github.com/reddavis/Asynchrone",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/groue/Semaphore",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox.git",
            from: "0.2.0"
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            branch: "main"
        ),
    ],
    targets: [
        .target(
            name: "RuntimeViewerCore",
            dependencies: [
                .target(name: "RuntimeViewerCommunication"),
                .product(name: "ClassDumpRuntime", package: "ClassDumpRuntime"),
                .product(name: "ClassDumpRuntimeSwift", package: "ClassDumpRuntime"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
                .product(name: "MachOSwiftSection", package: "MachOSwiftSection"),
                .product(name: "SwiftDump", package: "MachOSwiftSection"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .target(
            name: "RuntimeViewerCommunication",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Asynchrone", package: "Asynchrone"),
                .product(name: "Semaphore", package: "Semaphore"),
            ]
        ),
    ]
)

// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

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
            url: "https://github.com/MxIris-Reverse-Engineering/ClassDumpRuntime",
            branch: "master"
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
            branch: "main"
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

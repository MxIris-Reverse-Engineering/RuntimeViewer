// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeViewerMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RuntimeViewerMCPBridge",
            targets: ["RuntimeViewerMCPBridge"]
        ),
    ],
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        .package(path: "../RuntimeViewerPackages"),
        .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "RuntimeViewerMCPBridge",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerApplication", package: "RuntimeViewerPackages"),
                .product(name: "RuntimeViewerSettings", package: "RuntimeViewerPackages"),
                .product(name: "SwiftMCP", package: "SwiftMCP"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

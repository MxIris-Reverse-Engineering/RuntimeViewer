// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeViewerMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RuntimeViewerMCPShared",
            targets: ["RuntimeViewerMCPShared"]
        ),
        .library(
            name: "RuntimeViewerMCPBridge",
            targets: ["RuntimeViewerMCPBridge"]
        ),
    ],
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        .package(path: "../RuntimeViewerPackages"),
    ],
    targets: [
        .target(
            name: "RuntimeViewerMCPShared"
        ),
        .target(
            name: "RuntimeViewerMCPBridge",
            dependencies: [
                "RuntimeViewerMCPShared",
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerApplication", package: "RuntimeViewerPackages"),
                .product(name: "RuntimeViewerSettings", package: "RuntimeViewerPackages"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

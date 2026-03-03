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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "RuntimeViewerMCPBridge",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "RuntimeViewerApplication", package: "RuntimeViewerPackages"),
                .product(name: "RuntimeViewerSettings", package: "RuntimeViewerPackages"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

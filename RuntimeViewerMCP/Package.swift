// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeViewerMCP",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RuntimeViewerMCPShared",
            targets: ["RuntimeViewerMCPShared"]
        ),
        .library(
            name: "RuntimeViewerMCPService",
            targets: ["RuntimeViewerMCPService"]
        ),
        .executable(
            name: "RuntimeViewerMCPServer",
            targets: ["RuntimeViewerMCPServer"]
        ),
    ],
    dependencies: [
        .package(path: "../RuntimeViewerCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "RuntimeViewerMCPShared"
        ),
        .target(
            name: "RuntimeViewerMCPService",
            dependencies: [
                "RuntimeViewerMCPShared",
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
            ]
        ),
        .executableTarget(
            name: "RuntimeViewerMCPServer",
            dependencies: [
                "RuntimeViewerMCPShared",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

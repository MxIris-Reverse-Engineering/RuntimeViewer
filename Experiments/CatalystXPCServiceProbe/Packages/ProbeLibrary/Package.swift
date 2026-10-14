// swift-tools-version: 6.0
// Stands in for RuntimeViewerCore and the other packages the simulator payload
// links: an SDKROOT = auto dependency that has to be built for whatever
// platform its consumer is built for.

import PackageDescription

let package = Package(
    name: "ProbeLibrary",
    platforms: [.macOS(.v14), .iOS(.v17), .macCatalyst(.v17)],
    products: [
        .library(name: "ProbeLibrary", targets: ["ProbeLibrary"]),
    ],
    targets: [
        .target(name: "ProbeLibrary"),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// Tooling for working on RuntimeViewer from Xcode, not part of the app: nothing depends on this
// package. It sits in the three workspaces only so that its command plugins can be run from the
// Project navigator — right-click RuntimeViewerTools and pick the command.
let package = Package(
    name: "RuntimeViewerTools",
    platforms: [.macOS(.v14)],
    products: [
        .plugin(name: "UpdatePackages", targets: ["UpdatePackages"]),
    ],
    targets: [
        .plugin(
            name: "UpdatePackages",
            capability: .command(
                intent: .custom(
                    verb: "update-packages",
                    description: "Update the package pins of the RuntimeViewer workspaces to the newest versions their manifests allow."
                )
            )
        ),
    ]
)

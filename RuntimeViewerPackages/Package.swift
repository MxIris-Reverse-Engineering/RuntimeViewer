// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

let usingSystemUXKit = true

var sharedSwiftSettings: [SwiftSetting] = []

if usingSystemUXKit {
    sharedSwiftSettings.append(.define("USING_SYSTEM_UXKIT"))
}

let package = Package(
    name: "RuntimeViewerPackages",
    platforms: [
        .iOS(.v17), .macOS(.v14), .macCatalyst(.v17), .tvOS(.v17), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "RuntimeViewerUI",
            targets: ["RuntimeViewerUI"]
        ),
        .library(
            name: "RuntimeViewerArchitectures",
            targets: ["RuntimeViewerArchitectures"]
        ),
        .library(
            name: "RuntimeViewerApplication",
            targets: ["RuntimeViewerApplication"]
        ),
        .library(
            name: "RuntimeViewerService",
            targets: ["RuntimeViewerService"]
        ),
    ],
    dependencies: [
        .package(
            path: "../Core"
        ),
        .package(
            url: "https://github.com/ChimeHQ/Rearrange.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/Mx-Iris/UIFoundation",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/XCoordinator",
            branch: "master"
        ),
        .package(
            url: "https://github.com/Mx-Iris/CocoaCoordinator",
            branch: "main"
        ),
        .package(
            url: "https://github.com/SnapKit/SnapKit",
            from: "5.0.0"
        ),
        .package(
            url: "https://github.com/ReactiveX/RxSwift",
            from: "6.0.0"
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxSwiftPlus",
            from: "0.2.0"
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxAppKit",
            branch: "main"
        ),
        .package(
            url: "https://github.com/OpenUXKit/OpenUXKit",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/NSAttributedStringBuilder",
            branch: "master"
        ),
        .package(
            url: "https://github.com/Mx-Iris/SFSymbols",
            branch: "main"
        ),
        .package(
            url: "https://github.com/CombineCommunity/RxCombine",
            from: "2.0.1"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/ide-icons",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/gringoireDM/RxEnumKit",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxUIKit",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/filter-ui",
            branch: "main"
        ),
        .package(
            url: "https://github.com/TrGiLong/RxConcurrency",
            from: "0.1.1"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachInjector",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            branch: "main"
        ),
        .package(
            url: "https://github.com/Mx-Iris/RunningApplicationKit",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/swift-memberwise-init-macro",
            from: "0.5.3-fork"
        ),
        .package(
            url: "https://github.com/dagronf/DSFInspectorPanes",
            from: "3.0.0"
        ),
    ],
    targets: [
        .target(
            name: "RuntimeViewerArchitectures",
            dependencies: [
                .product(name: "RxSwift", package: "RxSwift"),
                .product(name: "RxCocoa", package: "RxSwift"),
                .product(name: "RxSwiftPlus", package: "RxSwiftPlus"),
                .product(name: "RxDefaultsPlus", package: "RxSwiftPlus"),
                .product(name: "RxAppKit", package: "RxAppKit", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RxUIKit", package: "RxUIKit", condition: .when(platforms: uikitPlatforms)),
                .product(name: "RxCombine", package: "RxCombine"),
                .product(name: "RxEnumKit", package: "RxEnumKit"),
                .product(name: "RxConcurrency", package: "RxConcurrency"),
                .product(name: "XCoordinator", package: "XCoordinator", condition: .when(platforms: uikitPlatforms)),
                .product(name: "XCoordinatorRx", package: "XCoordinator", condition: .when(platforms: uikitPlatforms)),
                .product(name: "CocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RxCocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: usingSystemUXKit ? "UXKitCoordinator" : "OpenUXKitCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
            ],
            swiftSettings: sharedSwiftSettings,
        ),
        .target(
            name: "RuntimeViewerUI",
            dependencies: [
                .product(name: "UIFoundation", package: "UIFoundation"),
                .product(name: "UIFoundationToolbox", package: "UIFoundation"),
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: usingSystemUXKit ? "UXKit" : "OpenUXKit", package: "OpenUXKit", condition: .when(platforms: appkitPlatforms)),
                .product(name: "NSAttributedStringBuilder", package: "NSAttributedStringBuilder"),
                .product(name: "SFSymbols", package: "SFSymbols"),
                .product(name: "IDEIcons", package: "ide-icons"),
                .product(name: "FilterUI", package: "filter-ui", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Rearrange", package: "Rearrange", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RunningApplicationKit", package: "RunningApplicationKit", condition: .when(platforms: appkitPlatforms)),
                .product(name: "UIFoundationAppleInternal", package: "UIFoundation"),
            ],
            swiftSettings: sharedSwiftSettings,
        ),
        .target(
            name: "RuntimeViewerApplication",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "Core"),
                "RuntimeViewerUI",
                "RuntimeViewerArchitectures",
                .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
            ]
        ),

        .target(
            name: "RuntimeViewerService",
            dependencies: [
                .product(name: "RuntimeViewerCommunication", package: "Core"),
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "MachInjector", package: "MachInjector", condition: .when(platforms: appkitPlatforms)),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

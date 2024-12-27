// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

let package = Package(
    name: "RuntimeViewerPackages",
    platforms: [
        .iOS(.v14), .macOS(.v12), .macCatalyst(.v14), .tvOS(.v14), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "RuntimeViewerCore",
            targets: ["RuntimeViewerCore"]
        ),
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
            url: "https://github.com/ChimeHQ/Rearrange.git",
            .upToNextMajor(from: "1.6.0")
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
            url: "https://github.com/MxIris-Reverse-Engineering/ClassDumpRuntime",
            branch: "master"
        ),
//        .package(
//            path: "/Volumes/Repositories/Private/Fork/Library/ClassDumpRuntime"
//        ),
        .package(
            url: "https://github.com/SnapKit/SnapKit",
            .upToNextMajor(from: "5.0.0")
        ),
        .package(
            url: "https://github.com/ReactiveX/RxSwift",
            .upToNextMajor(from: "6.0.0")
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxSwiftPlus",
            branch: "main"
        ),
//        .package(
//            url: "https://github.com/RxSwiftCommunity/RxSwiftExt.git",
//            .upToNextMajor(from: "6.0.0")
//        ),
//        .package(
//            path: "/Volumes/Repositories/Private/Personal/Library/Multi/RxSwiftPlus"
//        ),
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
            url: "https://github.com/Mx-Iris/SFSymbol",
            branch: "main"
        ),
//        .package(path: "/Volumes/Code/Personal/SFSymbol"),
        .package(
            url: "https://github.com/CombineCommunity/RxCombine",
            .upToNextMajor(from: "2.0.0")
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/ide-icons",
            branch: "main"
        ),
//            .package(path: "/Volumes/Code/Personal/ide-icons"),
//        .package(
//            url: "https://github.com/krzyzanowskim/STTextView",
//            from: "0.9.5"
//        ),
        .package(
            url: "https://github.com/gringoireDM/RxEnumKit",
            branch: "master"
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxUIKit",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            branch: "main"
        ),
//        .package(
//            path: "/Volumes/Repositories/Private/Fork/Library/SwiftyXPC"
//        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/filter-ui",
            branch: "main"
        ),
        .package(
            url: "https://github.com/TrGiLong/RxConcurrency",
            branch: "main"
        ),
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachInjector",
            branch: "main"
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
//                .product(name: "RxSwiftExt", package: "RxSwiftExt"),
                .product(name: "XCoordinator", package: "XCoordinator", condition: .when(platforms: uikitPlatforms)),
                .product(name: "XCoordinatorRx", package: "XCoordinator", condition: .when(platforms: uikitPlatforms)),
                .product(name: "CocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RxCocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: "OpenUXKitCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
//                .product(name: "UXKitCoordinator", package: "CocoaCoordinator", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "RuntimeViewerCore",
            dependencies: [
                .target(name: "RuntimeViewerCommunication", condition: .when(platforms: appkitPlatforms)),
                .product(name: "ClassDumpRuntime", package: "ClassDumpRuntime"),
                .product(name: "ClassDumpRuntimeSwift", package: "ClassDumpRuntime"),
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ]
        ),
        .target(
            name: "RuntimeViewerUI",
            dependencies: [
                .product(name: "UIFoundation", package: "UIFoundation"),
                .product(name: "UIFoundationToolbox", package: "UIFoundation"),
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: "OpenUXKit", package: "OpenUXKit", condition: .when(platforms: appkitPlatforms)),
//                .product(name: "UXKit", package: "OpenUXKit"),
                .product(name: "NSAttributedStringBuilder", package: "NSAttributedStringBuilder"),
                .product(name: "SFSymbol", package: "SFSymbol"),
                .product(name: "IDEIcons", package: "ide-icons"),
                .product(name: "FilterUI", package: "filter-ui", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Rearrange", package: "Rearrange", condition: .when(platforms: appkitPlatforms)),
                .product(name: "MachInjectorUI", package: "MachInjector", condition: .when(platforms: appkitPlatforms)),
            ]
        ),
        .target(
            name: "RuntimeViewerApplication",
            dependencies: [
                "RuntimeViewerCore",
                "RuntimeViewerUI",
                "RuntimeViewerArchitectures",
            ]
        ),
        .target(
            name: "RuntimeViewerService",
            dependencies: [
                "RuntimeViewerCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "MachInjector", package: "MachInjector", condition: .when(platforms: appkitPlatforms)),
            ]
        ),
        .target(
            name: "RuntimeViewerCommunication",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
            ]
        ),
    ]
)

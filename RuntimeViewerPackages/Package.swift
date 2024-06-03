// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RuntimeViewerPackages",
    platforms: [
        .iOS(.v14), .macOS(.v11),
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
            name: "RxRuntimeViewer",
            targets: ["RxRuntimeViewer"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Mx-Iris/UIFoundation",
            branch: "main"
        ),
        .package(
            url: "https://github.com/QuickBirdEng/XCoordinator",
            .upToNextMajor(from: "2.0.0")
        ),
        .package(
            url: "https://github.com/Mx-Iris/CocoaCoordinator",
            branch: "main"
        ),
        .package(
            url: "https://github.com/leptos-null/ClassDumpRuntime",
            branch: "master"
        ),
        .package(
            url: "https://github.com/Mx-Iris/ViewHierarchyBuilder",
            branch: "main"
        ),
        .package(
            url: "https://github.com/SnapKit/SnapKit",
            .upToNextMajor(from: "5.0.0")
        ),
        .package(
            url: "https://github.com/ReactiveX/RxSwift",
            .upToNextMajor(from: "6.0.0")
        ),
        .package(
            url: "https://github.com/RxSwiftCommunity/RxSwiftExt.git",
            .upToNextMajor(from: "6.0.0")
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxSwiftPlus",
            branch: "main"
        ),
        .package(
            url: "https://github.com/Mx-Iris/RxAppKit",
            branch: "main"
        ),
    ],
    targets: [
        .target(
            name: "RxRuntimeViewer",
            dependencies: [
                .product(name: "RxSwift", package: "RxSwift"),
                .product(name: "RxCocoa", package: "RxSwift"),
                .product(name: "RxSwiftExt", package: "RxSwiftExt"),
                .product(name: "RxSwiftPlus", package: "RxSwiftPlus"),
                .product(name: "RxAppKit", package: "RxAppKit"),
                .product(name: "XCoordinator", package: "XCoordinator", condition: .when(platforms: [.iOS, .tvOS, .watchOS, .macCatalyst])),
                .product(name: "CocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: [.macOS])),
                .product(name: "RxCocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "RuntimeViewerCore",
            dependencies: [
                .product(name: "ClassDumpRuntime", package: "ClassDumpRuntime"),
            ]
        ),
        .target(
            name: "RuntimeViewerUI",
            dependencies: [
                .product(name: "UIFoundation", package: "UIFoundation"),
                .product(name: "UIFoundationToolbox", package: "UIFoundation"),
                .product(name: "ViewHierarchyBuilder", package: "ViewHierarchyBuilder"),
                .product(name: "SnapKit", package: "SnapKit"),
            ]
        ),
    ]
)

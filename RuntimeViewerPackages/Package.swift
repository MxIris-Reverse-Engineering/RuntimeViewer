// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

let usingSystemUXKit = true

var sharedSwiftSettings: [SwiftSetting] = []

if usingSystemUXKit {
    sharedSwiftSettings.append(.define("USING_SYSTEM_UXKIT"))
}

enum MxIrisStudioWorkspace {
    static let relativeForkDirectory = "../../../../Fork"

    static let relativePersonalDirectory = "../../../../Personal"
}

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool)
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled):
                guard isEnabled else { continue }
                let url = if isRelative, let resolvedURL = URL(string: path, relativeTo: URL(fileURLWithPath: #filePath)) {
                    resolvedURL
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "RuntimeViewerPackages",
    platforms: [
        .iOS(.v18), .macOS(.v15), .macCatalyst(.v18), .tvOS(.v18), .visionOS(.v2),
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
            path: "../RuntimeViewerCore"
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
            local: .package(
                path: "\(MxIrisStudioWorkspace.relativePersonalDirectory)/Library/macOS/CocoaCoordinator",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/CocoaCoordinator",
                branch: "main"
            )
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
            local: .package(
                path: "\(MxIrisStudioWorkspace.relativePersonalDirectory)/Library/macOS/RxAppKit",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxAppKit",
                branch: "main"
            ),
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
            local: .package(
                path: "\(MxIrisStudioWorkspace.relativeForkDirectory)/Library/filter-ui",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-macOS-Library-Forks/filter-ui",
                branch: "main"
            ),
        ),
        .package(
            url: "https://github.com/TrGiLong/RxConcurrency",
            from: "0.1.1"
        ),
        .package(
            local: .package(
                path: "../../MachInjector",
                isRelative: true,
                isEnabled: true
            ),
            .package(
                path: "\(MxIrisStudioWorkspace.relativePersonalDirectory)/Library/macOS/MachInjector",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachInjector",
                from: "0.1.0"
            )
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            branch: "main"
        ),
        .package(
            local: .package(
                path: "\(MxIrisStudioWorkspace.relativePersonalDirectory)/Library/macOS/RunningApplicationKit",
                isRelative: true,
                isEnabled: true
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RunningApplicationKit",
                from: "0.1.1"
            )
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/swift-memberwise-init-macro",
            from: "0.5.3-fork"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies",
            from: "1.9.4"
        ),
//        .package(
//            url: "https://github.com/dagronf/DSFInspectorPanes",
//            from: "3.0.0"
//        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/LateResponders",
            branch: "develop"
        ),
        .package(
            url: "https://github.com/ukushu/Ifrit",
            from: "3.0.0"
        ),
        .package(
            url: "https://github.com/database-utility/fuzzy-search.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/AppKitUI",
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
                .product(name: "XCoordinator", package: "XCoordinator", condition: .when(platforms: uikitPlatforms)),
                .product(name: "XCoordinatorRx", package: "XCoordinator", condition: .when(platforms: uikitPlatforms)),
                .product(name: "CocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RxCocoaCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: usingSystemUXKit ? "UXKitCoordinator" : "OpenUXKitCoordinator", package: "CocoaCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            swiftSettings: sharedSwiftSettings
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
                .product(name: "LateResponders", package: "LateResponders"),
                .product(name: "AppKitUI", package: "AppKitUI", condition: .when(platforms: appkitPlatforms))
//                .product(name: "DSFInspectorPanes", package: "DSFInspectorPanes", condition: .when(platforms: appkitPlatforms)),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "RuntimeViewerApplication",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                "RuntimeViewerUI",
                "RuntimeViewerArchitectures",
                .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
                .product(name: "IfritStatic", package: "Ifrit"),
                .product(name: "FuzzySearch", package: "fuzzy-search"),
            ]
        ),

        .target(
            name: "RuntimeViewerService",
            dependencies: [
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "MachInjector", package: "MachInjector", condition: .when(platforms: appkitPlatforms)),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

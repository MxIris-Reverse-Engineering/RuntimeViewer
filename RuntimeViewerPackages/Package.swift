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

struct MxIrisStudioWorkspace: RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue value: String) {
        self.rawValue = value
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let forkDirectory: MxIrisStudioWorkspace = "../../../../Fork"

    static let forkLibraryDirectory: MxIrisStudioWorkspace = "../../../../Fork/Library"

    static let personalDirectory: MxIrisStudioWorkspace = "../../../../Personal"

    static let personalLibraryDirectory: MxIrisStudioWorkspace = "../../../../Personal/Library"

    static let personalLibraryMacOSDirectory: MxIrisStudioWorkspace = "../../../../Personal/Library/macOS"

    static let personalLibraryIOSDirectory: MxIrisStudioWorkspace = "../../../../Personal/Library/iOS"

    static let personalLibraryMuiltplePlatfromDirectory: MxIrisStudioWorkspace = "../../../../Personal/Library/Multi"

    var description: String {
        rawValue
    }

    func libraryPath(_ libraryName: String) -> String {
        "\(rawValue)/\(libraryName)"
    }
}

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative, let resolvedURL = URL(string: path, relativeTo: URL(fileURLWithPath: #filePath)) {
                    resolvedURL
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "RuntimeViewerPackages",
    platforms: [
        .macOS(.v15), .iOS(.v18), .macCatalyst(.v18), .tvOS(.v18), .visionOS(.v2),
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
        .library(
            name: "RuntimeViewerServiceHelper",
            targets: ["RuntimeViewerServiceHelper"]
        ),
        .library(
            name: "RuntimeViewerHelperClient",
            targets: ["RuntimeViewerHelperClient"]
        ),
        .library(
            name: "RuntimeViewerSettings",
            targets: ["RuntimeViewerSettings"]
        ),
        .library(
            name: "RuntimeViewerSettingsUI",
            targets: ["RuntimeViewerSettingsUI"]
        ),
        .library(
            name: "RuntimeViewerCatalystExtensions",
            targets: ["RuntimeViewerCatalystExtensions"]
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
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMuiltplePlatfromDirectory.libraryPath("UIFoundation"),
                isRelative: true,
                isEnabled: true,
                traits: ["AppleInternal"],
            ),
            .package(
                path: "../../UIFoundation",
                isRelative: true,
                isEnabled: true,
                traits: ["AppleInternal"],
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/UIFoundation",
                from: "0.4.0",
                traits: ["AppleInternal"],
            )
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.forkLibraryDirectory.libraryPath("XCoordinator"),
                isRelative: true,
                isEnabled: false
            ),
            .package(
                path: "../../XCoordinator",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-Library-Forks/XCoordinator",
                from: "3.0.0-beta"
            )
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("CocoaCoordinator"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/CocoaCoordinator",
                from: "0.4.1"
            )
        ),
        .package(
            url: "https://github.com/OpenUXKit/UXKitCoordinator",
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
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMuiltplePlatfromDirectory.libraryPath("RxSwiftPlus"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxSwiftPlus",
                from: "0.2.2"
            )
        ),
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("OpenUXKit"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/OpenUXKit/OpenUXKit",
                branch: "main"
            )
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/NSAttributedStringBuilder",
            from: "0.4.2"
        ),
        .package(
            url: "https://github.com/Mx-Iris/SFSymbols",
            from: "0.2.0"
        ),
        .package(
            url: "https://github.com/CombineCommunity/RxCombine",
            from: "2.0.1"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/ide-icons",
            exact: "0.1.1"
        ),
        .package(
            url: "https://github.com/gringoireDM/RxEnumKit",
            from: "2.0.0"
        ),
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("RxAppKit"),
                isRelative: true,
                isEnabled: true
            ),
            .package(
                path: "../../RxAppKit",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxAppKit",
                from: "0.3.0"
            )
        ),
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryIOSDirectory.libraryPath("RxUIKit"),
                isRelative: true,
                isEnabled: false
            ),
            .package(
                path: "../../RxUIKit",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxUIKit",
                from: "0.1.1"
            )
        ),
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.forkLibraryDirectory.libraryPath("filter-ui"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-macOS-Library-Forks/filter-ui",
                from: "0.1.2"
            )
        ),
        .package(
            url: "https://github.com/TrGiLong/RxConcurrency",
            from: "0.1.1"
        ),
        .package(
            local: .package(
                path: "../../MachInjector",
                isRelative: true,
                isEnabled: false
            ),
            .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("MachInjector"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachInjector",
                from: "0.1.0"
            )
        ),
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            from: "0.5.100"
        ),
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("RunningApplicationKit"),
                isRelative: true,
                isEnabled: false
            ),
            .package(
                path: "../../RunningApplicationKit",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RunningApplicationKit",
                from: "0.2.0"
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
        .package(
            url: "https://github.com/MxIris-Library-Forks/LateResponders",
            from: "1.1.0"
        ),
        .package(
            url: "https://github.com/ukushu/Ifrit",
            from: "3.0.0"
        ),
        .package(
            url: "https://github.com/MxIris-Library-Forks/fuzzy-search",
            from: "0.1.0"
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            from: "2.4.0"
        ),
        .package(
            local: .package(
                path: "../../DSFQuickActionBar",
                isRelative: true,
                isEnabled: false
            ),
            .package(
                path: MxIrisStudioWorkspace.forkLibraryDirectory.libraryPath("DSFQuickActionBar"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-macOS-Library-Forks/DSFQuickActionBar",
                from: "6.2.100"
            )
        ),
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("SystemHUD"),
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/SystemHUD",
                from: "0.1.0"
            )
        ),
        .package(
            url: "https://github.com/Aeastr/SettingsKit",
            from: "2.0.1"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-navigation",
            from: "2.7.0"
        ),
        .package(
            url: "https://github.com/siteline/swiftui-introspect",
            from: "26.0.0"
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
                .product(name: usingSystemUXKit ? "UXKitCoordinator" : "OpenUXKitCoordinator", package: "UXKitCoordinator", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SwiftNavigation", package: "swift-navigation"),
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
                .product(name: "LateResponders", package: "LateResponders"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts", condition: .when(platforms: appkitPlatforms)),
                .product(name: "DSFQuickActionBar", package: "DSFQuickActionBar", condition: .when(platforms: appkitPlatforms)),
                .product(name: "SystemHUD", package: "SystemHUD", condition: .when(platforms: appkitPlatforms)),

            ],
            swiftSettings: sharedSwiftSettings
        ),

        .target(
            name: "RuntimeViewerSettings",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),

        .target(
            name: "RuntimeViewerSettingsUI",
            dependencies: [
                "RuntimeViewerUI",
                "RuntimeViewerSettings",
                .target(name: "RuntimeViewerHelperClient", condition: .when(platforms: appkitPlatforms)),
                .product(name: "SettingsKit", package: "SettingsKit"),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),

        .target(
            name: "RuntimeViewerApplication",
            dependencies: [
                "RuntimeViewerUI",
                "RuntimeViewerArchitectures",
                .target(name: "RuntimeViewerSettings", condition: .when(platforms: appkitPlatforms)),
                .target(name: "RuntimeViewerSettingsUI", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
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

        .target(
            name: "RuntimeViewerServiceHelper"
        ),

        .target(
            name: "RuntimeViewerHelperClient",
            dependencies: [
                "RuntimeViewerServiceHelper",
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
                .product(name: "SwiftyXPC", package: "SwiftyXPC", condition: .when(platforms: appkitPlatforms)),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .target(
            name: "RuntimeViewerCatalystExtensions",
            dependencies: [
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
            ]
        ),

    ],
    swiftLanguageModes: [.v5]
)

extension SwiftSetting {
    static let existentialAny: Self = .enableUpcomingFeature("ExistentialAny") // SE-0335, Swift 5.6,  SwiftPM 5.8+
    static let internalImportsByDefault: Self = .enableUpcomingFeature("InternalImportsByDefault") // SE-0409, Swift 6.0,  SwiftPM 6.0+
    static let memberImportVisibility: Self = .enableUpcomingFeature("MemberImportVisibility") // SE-0444, Swift 6.1,  SwiftPM 6.1+
    static let inferIsolatedConformances: Self = .enableUpcomingFeature("InferIsolatedConformances") // SE-0470, Swift 6.2,  SwiftPM 6.2+
    static let nonisolatedNonsendingByDefault: Self = .enableUpcomingFeature("NonisolatedNonsendingByDefault") // SE-0461, Swift 6.2,  SwiftPM 6.2+
    static let immutableWeakCaptures: Self = .enableUpcomingFeature("ImmutableWeakCaptures") // SE-0481, Swift 6.2,  SwiftPM 6.2+
}

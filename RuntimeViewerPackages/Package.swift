// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let localEnvironment: [String: String] = {
    let localEnvironmentFilePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(".package.env")
        .path
    guard FileManager.default.fileExists(atPath: localEnvironmentFilePath),
          let contents = try? String(contentsOfFile: localEnvironmentFilePath, encoding: .utf8)
    else {
        return [:]
    }
    var environment: [String: String] = [:]
    for line in contents.components(separatedBy: .newlines) {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
            continue
        }
        let parts = trimmedLine.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        environment[key] = value
    }
    return environment
}()

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = localEnvironment[key] ?? Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
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
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
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

let appkitPlatforms: [Platform] = [.macOS]

let uikitPlatforms: [Platform] = [.iOS, .tvOS, .visionOS]

let usingSystemUXKit = envEnable("USING_SYSTEM_UXKIT", default: true)

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

var sharedSwiftSettings: [SwiftSetting] = []

let UIFoundationTraits: Set<PackageDescription.Package.Dependency.Trait> = ["AppleInternal", "FilterUI", "IDEIcons", "QuickActionBar", "NSAttributedStringBuilder"]

if usingSystemUXKit {
    sharedSwiftSettings.append(.define("USING_SYSTEM_UXKIT"))
}

let package = Package(
    name: "RuntimeViewerPackages",
    platforms: [
        .macOS(.v15), .iOS(.v18), .macCatalyst(.v18), .tvOS(.v18), .visionOS(.v2),
    ],
    products: [
        .library(
            name: "RuntimeViewerUI",
            targets: ["RuntimeViewerUI"],
        ),
        .library(
            name: "RuntimeViewerArchitectures",
            targets: ["RuntimeViewerArchitectures"],
        ),
        .library(
            name: "RuntimeViewerApplication",
            targets: ["RuntimeViewerApplication"],
        ),
        .library(
            name: "RuntimeViewerService",
            targets: ["RuntimeViewerService"],
        ),
        .library(
            name: "RuntimeViewerServiceHelper",
            targets: ["RuntimeViewerServiceHelper"],
        ),
        .library(
            name: "RuntimeViewerHelperClient",
            targets: ["RuntimeViewerHelperClient"],
        ),
        .library(
            name: "RuntimeViewerSettings",
            targets: ["RuntimeViewerSettings"],
        ),
        .library(
            name: "RuntimeViewerSettingsUI",
            targets: ["RuntimeViewerSettingsUI"],
        ),
        .library(
            name: "RuntimeViewerCatalystExtensions",
            targets: ["RuntimeViewerCatalystExtensions"],
        ),

    ],
    dependencies: [
        .package(
            path: "../RuntimeViewerCore",
        ),
        
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMuiltplePlatfromDirectory.libraryPath("UIFoundation"),
                isRelative: true,
                traits: UIFoundationTraits,
            ),
            .package(
                path: "../../UIFoundation",
                isRelative: true,
                traits: UIFoundationTraits,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/UIFoundation",
                from: "0.8.2",
                traits: UIFoundationTraits,
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.forkLibraryDirectory.libraryPath("XCoordinator"),
                isRelative: true,
            ),
            .package(
                path: "../../XCoordinator",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Library-Forks/XCoordinator",
                from: "3.0.0-beta",
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("CocoaCoordinator"),
                isRelative: true,
            ),
            .package(
                path: "../../CocoaCoordinator",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/CocoaCoordinator",
                from: "0.4.1",
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("UXKitCoordinator"),
                isRelative: true,
            ),
            .package(
                path: "../../UXKitCoordinator",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/OpenUXKit/UXKitCoordinator",
                branch: "main",
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMuiltplePlatfromDirectory.libraryPath("RxSwiftPlus"),
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxSwiftPlus",
                from: "0.2.2",
            ),
        ),
        
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("OpenUXKit"),
                isRelative: true,
            ),
            .package(
                path: "../../OpenUXKit",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/OpenUXKit/OpenUXKit",
                branch: "main",
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("RxAppKit"),
                isRelative: true,
            ),
            .package(
                path: "../../RxAppKit",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxAppKit",
                from: "0.3.0",
            ),
        ),
        
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryIOSDirectory.libraryPath("RxUIKit"),
                isRelative: true,
            ),
            .package(
                path: "../../RxUIKit",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RxUIKit",
                from: "0.1.1",
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("swift-helper-service"),
                isRelative: true,
            ),
            .package(
                path: "../../swift-helper-service",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/swift-helper-service",
                from: "0.1.2",
            ),
        ),
        
        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("RunningApplicationKit"),
                isRelative: true,
            ),
            .package(
                path: "../../RunningApplicationKit",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/RunningApplicationKit",
                from: "0.3.3",
            ),
        ),

        .package(
            local: .package(
                path: MxIrisStudioWorkspace.personalLibraryMacOSDirectory.libraryPath("SystemHUD"),
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/SystemHUD",
                from: "0.1.0",
            ),
        ),

        .package(
            url: "https://github.com/SnapKit/SnapKit",
            from: "5.0.0",
        ),
        
        .package(
            url: "https://github.com/ReactiveX/RxSwift",
            from: "6.0.0",
        ),
        
        .package(
            url: "https://github.com/Mx-Iris/SFSymbols",
            from: "0.2.0",
        ),
        
        .package(
            url: "https://github.com/CombineCommunity/RxCombine",
            from: "2.0.1",
        ),
        
        .package(
            url: "https://github.com/gringoireDM/RxEnumKit",
            from: "2.0.0",
        ),
        
        .package(
            url: "https://github.com/TrGiLong/RxConcurrency",
            from: "0.1.1",
        ),
        
        .package(
            url: "https://github.com/gohanlon/swift-memberwise-init-macro",
            from: "0.6.0",
        ),
        
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies",
            from: "1.9.4",
        ),
        
        .package(
            url: "https://github.com/MxIris-Library-Forks/LateResponders",
            from: "1.1.0",
        ),
        
        .package(
            url: "https://github.com/ukushu/Ifrit",
            from: "3.0.0",
        ),
        
        .package(
            url: "https://github.com/MxIris-Library-Forks/fuzzy-search",
            from: "0.1.0",
        ),
        
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            from: "2.4.0",
        ),
        
        .package(
            url: "https://github.com/MxIris-Library-Forks/swift-navigation",
            from: "2.8.100",
        ),
        
        .package(
            url: "https://github.com/siteline/swiftui-introspect",
            from: "26.0.0",
        ),

        .package(
            url: "https://github.com/ChimeHQ/Rearrange",
            from: "2.0.0",
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
            swiftSettings: sharedSwiftSettings,
        ),

        .target(
            name: "RuntimeViewerUI",
            dependencies: [
                .product(name: "UIFoundation", package: "UIFoundation"),
                .product(name: "UIFoundationToolbox", package: "UIFoundation"),
                .product(name: "SnapKit", package: "SnapKit"),
                .product(name: usingSystemUXKit ? "UXKit" : "OpenUXKit", package: "OpenUXKit", condition: .when(platforms: appkitPlatforms)),
                .product(name: "SFSymbols", package: "SFSymbols"),
                .product(name: "Rearrange", package: "Rearrange", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RunningApplicationKit", package: "RunningApplicationKit", condition: .when(platforms: appkitPlatforms)),
                .product(name: "LateResponders", package: "LateResponders"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts", condition: .when(platforms: appkitPlatforms)),
                .product(name: "SystemHUD", package: "SystemHUD", condition: .when(platforms: appkitPlatforms)),

            ],
            swiftSettings: sharedSwiftSettings,
        ),

        .target(
            name: "RuntimeViewerSettings",
            dependencies: [
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
        ),

        .target(
            name: "RuntimeViewerSettingsUI",
            dependencies: [
                "RuntimeViewerUI",
                "RuntimeViewerSettings",
                .target(name: "RuntimeViewerHelperClient", condition: .when(platforms: appkitPlatforms)),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
            ],
            resources: [
                .process("Resources"),
            ],
        ),

        .target(
            name: "RuntimeViewerApplication",
            dependencies: [
                "RuntimeViewerUI",
                "RuntimeViewerArchitectures",
                .target(name: "RuntimeViewerSettings", condition: .when(platforms: appkitPlatforms)),
                .target(name: "RuntimeViewerSettingsUI", condition: .when(platforms: appkitPlatforms)),
                .target(name: "RuntimeViewerHelperClient", condition: .when(platforms: appkitPlatforms)),
                .target(name: "RuntimeViewerCatalystExtensions", condition: .when(platforms: appkitPlatforms)),
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
                .product(name: "MemberwiseInit", package: "swift-memberwise-init-macro"),
                .product(name: "IfritStatic", package: "Ifrit"),
                .product(name: "FuzzySearch", package: "fuzzy-search"),
            ],
        ),

        .target(
            name: "RuntimeViewerService",
            dependencies: [
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
                .product(name: "HelperCommunication", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "HelperService", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "HelperServer", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "ApplicationsServiceImplementation", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "FilesServiceImplementation", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "InjectionServiceImplementation", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "InjectedEndpointRegistryServiceImplementation", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
            ],
        ),

        .target(
            name: "RuntimeViewerServiceHelper",
        ),

        .target(
            name: "RuntimeViewerHelperClient",
            dependencies: [
                "RuntimeViewerServiceHelper",
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "HelperCommunication", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "HelperClient", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "ApplicationsServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "FilesServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "InjectionServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
                .product(name: "InjectedEndpointRegistryServiceInterface", package: "swift-helper-service", condition: .when(platforms: appkitPlatforms)),
            ],
        ),
        .target(
            name: "RuntimeViewerCatalystExtensions",
            dependencies: [
                .product(name: "RuntimeViewerCommunication", package: "RuntimeViewerCore"),
            ],
        ),

        .testTarget(
            name: "RuntimeViewerArchitecturesTests",
            dependencies: ["RuntimeViewerArchitectures"],
        ),

        .testTarget(
            name: "RuntimeViewerSettingsTests",
            dependencies: ["RuntimeViewerSettings"],
        ),

        .testTarget(
            name: "RuntimeViewerApplicationTests",
            dependencies: [
                "RuntimeViewerApplication",
                .product(name: "RuntimeViewerCore", package: "RuntimeViewerCore"),
            ],
        ),

    ],
    swiftLanguageModes: [.v5],
)

extension SwiftSetting {
    static let existentialAny: Self = .enableUpcomingFeature("ExistentialAny") // SE-0335, Swift 5.6,  SwiftPM 5.8+
    static let internalImportsByDefault: Self = .enableUpcomingFeature("InternalImportsByDefault") // SE-0409, Swift 6.0,  SwiftPM 6.0+
    static let memberImportVisibility: Self = .enableUpcomingFeature("MemberImportVisibility") // SE-0444, Swift 6.1,  SwiftPM 6.1+
    static let inferIsolatedConformances: Self = .enableUpcomingFeature("InferIsolatedConformances") // SE-0470, Swift 6.2,  SwiftPM 6.2+
    static let nonisolatedNonsendingByDefault: Self = .enableUpcomingFeature("NonisolatedNonsendingByDefault") // SE-0461, Swift 6.2,  SwiftPM 6.2+
    static let immutableWeakCaptures: Self = .enableUpcomingFeature("ImmutableWeakCaptures") // SE-0481, Swift 6.2,  SwiftPM 6.2+
}

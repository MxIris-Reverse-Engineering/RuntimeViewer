import Foundation
import RxDefaultsPlus
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies

@dynamicMemberLookup
public final class AppDefaults {
    public static let shared = AppDefaults()

    @UserDefault(key: "isInitialSetupSplitView", defaultValue: true)
    public var isInitialSetupSplitView: Bool

    @UserDefault(key: "generationOptions", defaultValue: .init())
    public var options: RuntimeObjectInterface.GenerationOptions

    @UserDefault(key: "themeProfile", defaultValue: XcodePresentationTheme())
    public var themeProfile: XcodePresentationTheme

    public static subscript<Value>(dynamicMember keyPath: ReferenceWritableKeyPath<AppDefaults, Value>) -> Value {
        set {
            shared[keyPath: keyPath] = newValue
        }
        get {
            shared[keyPath: keyPath]
        }
    }

    public static subscript<Value>(keyPath: KeyPath<AppDefaults, Value>) -> Value {
        shared[keyPath: keyPath]
    }
}

private enum AppDefaultsKey: DependencyKey {
    static let liveValue: AppDefaults = .shared
    static let testValue: AppDefaults = .shared
}

extension DependencyValues {
    public var appDefaults: AppDefaults {
        get { self[AppDefaultsKey.self] }
        set { self[AppDefaultsKey.self] = newValue }
    }
}

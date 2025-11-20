import Foundation
import RxDefaultsPlus
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies


public final class AppDefaults {
    fileprivate static let shared = AppDefaults()

    @UserDefault(key: "isInitialSetupSplitView", defaultValue: true)
    public var isInitialSetupSplitView: Bool

    @UserDefault(key: "generationOptions", defaultValue: .init())
    public var options: RuntimeObjectInterface.GenerationOptions

    @UserDefault(key: "themeProfile", defaultValue: XcodePresentationTheme())
    public var themeProfile: XcodePresentationTheme
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

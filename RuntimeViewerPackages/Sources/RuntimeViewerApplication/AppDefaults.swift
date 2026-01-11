import Foundation
import RxDefaultsPlus
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies

public final class AppDefaults {
    fileprivate static let shared = AppDefaults()

    private init() {}
    
    @UserDefault(key: "generationOptions", defaultValue: .init())
    public var options: RuntimeObjectInterface.GenerationOptions

    @UserDefault(key: "themeProfile", defaultValue: XcodePresentationTheme())
    public var themeProfile: XcodePresentationTheme
    
    @UserDefault(key: "filterMode", defaultValue: nil)
    public var filterMode: FilterMode?
    
    @FileStorage("imageBookmarks", directory: .applicationSupportDirectory)
    public var imageBookmarks: [RuntimeImageBookmark] = []
    
    @FileStorage("objectBookmarks", directory: .applicationSupportDirectory)
    public var objectBookmarks: [RuntimeObjectBookmark] = []
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

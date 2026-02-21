import Foundation
import RxDefaultsPlus
import RuntimeViewerCommunication
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies
import OrderedCollections

public final class AppDefaults {
    fileprivate static let shared = AppDefaults()

    private static let bookmarkMigrationKey = "bookmarkMigrationCompleted"

    private init() {
        guard !UserDefaults.standard.bool(forKey: Self.bookmarkMigrationKey) else { return }

        // One-time migration from old flat storage to new structured storage
        let oldImageBookmarks = _imageBookmarks.wrappedValue
        if !oldImageBookmarks.isEmpty {
            var dict: [RuntimeSource: [RuntimeImageBookmark]] = [:]
            for bookmark in oldImageBookmarks {
                dict[bookmark.source, default: []].append(bookmark)
            }
            self.imageBookmarksByRuntimeSource = dict
        }

        let oldObjectBookmarks = _objectBookmarks.wrappedValue
        if !oldObjectBookmarks.isEmpty {
            var dict: [RuntimeSource: [String: [RuntimeObjectBookmark]]] = [:]
            for bookmark in oldObjectBookmarks {
                dict[bookmark.source, default: [:]][bookmark.object.imagePath, default: []].append(bookmark)
            }
            self.objectBookmarksBySourceAndImagePath = dict
        }

        UserDefaults.standard.set(true, forKey: Self.bookmarkMigrationKey)
    }
    
    @UserDefault(key: "generationOptions", defaultValue: .init())
    public var options: RuntimeObjectInterface.GenerationOptions

    @UserDefault(key: "themeProfile", defaultValue: XcodePresentationTheme())
    public var themeProfile: XcodePresentationTheme
    
    @UserDefault(key: "filterMode", defaultValue: nil)
    public var filterMode: FilterMode?
    
    @available(*, deprecated, renamed: "imageBookmarksByRuntimeSource")
    @FileStorage("imageBookmarks", directory: .applicationSupportDirectory)
    public var imageBookmarks: [RuntimeImageBookmark] = []
    
    @available(*, deprecated, renamed: "objectBookmarksBySourceAndImagePath")
    @FileStorage("objectBookmarks", directory: .applicationSupportDirectory)
    public var objectBookmarks: [RuntimeObjectBookmark] = []
    
    @FileStorage("imageBookmarksByRuntimeSource", directory: .applicationSupportDirectory)
    public var imageBookmarksByRuntimeSource: [RuntimeSource: [RuntimeImageBookmark]] = [:]
    
    @FileStorage("objectBookmarksBySourceAndImagePath", directory: .applicationSupportDirectory)
    public var objectBookmarksBySourceAndImagePath: [RuntimeSource: [String: [RuntimeObjectBookmark]]] = [:]
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

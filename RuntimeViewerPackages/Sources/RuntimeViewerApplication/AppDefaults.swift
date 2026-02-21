import Foundation
import RxDefaultsPlus
import RuntimeViewerCommunication
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies
import OrderedCollections

public final class AppDefaults {
    fileprivate static let shared = AppDefaults()

    private init() {
        
        var imageBookmarksByRuntimeSource: [RuntimeSource: [RuntimeImageBookmark]] = [:]
        for bookmarks in _imageBookmarks.wrappedValue {
            imageBookmarksByRuntimeSource[bookmarks.source, default: []].append(bookmarks)
        }
        
        _imageBookmarksByRuntimeSource = .init(wrappedValue: imageBookmarksByRuntimeSource, "imageBookmarksByRuntimeSource", directory: .applicationSupportDirectory)
        
        var objectBookmarksBySourceAndImagePath: [RuntimeSource: [String: [RuntimeObjectBookmark]]] = [:]
        for objectBookmarks in _objectBookmarks.wrappedValue {
            objectBookmarksBySourceAndImagePath[objectBookmarks.source, default: [:]][objectBookmarks.object.imagePath, default: []].append(objectBookmarks)
        }
        _objectBookmarksBySourceAndImagePath = .init(wrappedValue: objectBookmarksBySourceAndImagePath, "objectBookmarksBySourceAndImagePath", directory: .applicationSupportDirectory)
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

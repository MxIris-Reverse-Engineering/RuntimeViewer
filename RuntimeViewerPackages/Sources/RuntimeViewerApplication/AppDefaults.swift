import Foundation
import RxDefaultsPlus
import RuntimeViewerCommunication
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies
import DependenciesMacros
import OrderedCollections

public final class AppDefaults {
    fileprivate static let shared = AppDefaults()

    private init() {
        guard !bookmarkMigrationCompleted else { return }

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

        // Defer setting the flag to allow FileStorage barrier writes to complete
        DispatchQueue.main.async {
            self.bookmarkMigrationCompleted = true
        }
    }
    
    @UserDefault(key: "generationOptions", defaultValue: .init())
    public var options: RuntimeObjectInterface.GenerationOptions

    @UserDefault(key: "filterMode", defaultValue: nil)
    public var filterMode: FilterMode?

    @UserDefault(key: "bookmarkMigrationCompleted", defaultValue: false)
    private var bookmarkMigrationCompleted: Bool
    
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

extension DependencyValues {
    @DependencyEntry(liveValue: AppDefaults.shared)
    public var appDefaults = AppDefaults.shared
}

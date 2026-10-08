import Foundation
import RxDefaultsPlus
import RuntimeViewerCommunication
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Dependencies
import DependenciesMacros
import OrderedCollections

/// `@unchecked` rather than a real conformance because the safety lives in the
/// property wrappers, where the compiler cannot see it: `@UserDefault` goes
/// through `UserDefaults`, which is thread-safe, and both `@FileStorage` and
/// `@ResilientFileStorage` serialize every read and write through a concurrent
/// queue with barriers. The class itself adds no mutable state of its own.
/// Reads already come from background schedulers all over the Rx pipelines, so
/// this states an existing fact rather than granting new access.
public final class AppDefaults: @unchecked Sendable {
    fileprivate static let shared = AppDefaults(storageDirectoryURL: applicationSupportStorageDirectoryURL)

    /// The store handed out when `\.appDefaults` is resolved from a test
    /// context without an explicit `withDependencies` override — typically a
    /// cell ViewModel that a sidebar pipeline builds on a GCD thread, where no
    /// task-local override can reach. Lives in a throwaway temporary directory
    /// and an isolated user defaults namespace, so a stray test access can
    /// never touch the user's files or the test process's standard defaults.
    fileprivate static let testFallback = AppDefaults(
        storageDirectoryURL: makeTemporaryStorageDirectoryURL(label: "test-fallback"),
        userDefaultsNamespace: .makeIsolated()
    )

    /// `~/Library/Application Support/AppStorage`, the directory the app has
    /// always kept its bookmark files in. `nil` only when the search path
    /// cannot be resolved, in which case the wrappers fall back to their
    /// defaults exactly as before.
    private static var applicationSupportStorageDirectoryURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppStorage", isDirectory: true)
    }

    /// A fresh, unique directory under the temporary directory. Backs the
    /// test fallback above and the isolated instances the package's tests
    /// build for themselves.
    static func makeTemporaryStorageDirectoryURL(label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewer.AppDefaults.\(label).\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates a defaults store whose bookmark files live under
    /// `storageDirectoryURL` and whose other values live in
    /// `userDefaultsNamespace`.
    ///
    /// Production only ever uses the single Application Support instance
    /// behind `DependencyValues.appDefaults`, on the standard defaults. The
    /// initializer is `internal` so the package's tests can build isolated
    /// instances that point at a directory the app never reads: the storage
    /// path is not scoped by bundle identifier and the app is not sandboxed,
    /// so a test that resolved the shared instance would read and overwrite
    /// the user's real bookmark files. The one-time migrations read their
    /// legacy files from the same directory, so an isolated instance migrates
    /// nothing.
    ///
    /// The namespace matters as much as the directory. `$options` observes a
    /// single user defaults key, so instances sharing the standard defaults
    /// hear each other's writes — a Find session in one test searched again
    /// whenever another test changed the Generation Options — and every write
    /// stayed in the test process's defaults for the next run to read.
    init(storageDirectoryURL: URL?, userDefaultsNamespace: UserDefaultsNamespace = .standard) {
        self.userDefaultsNamespace = userDefaultsNamespace
        let userDefaults = userDefaultsNamespace.userDefaults
        _options = UserDefault(key: userDefaultsNamespace.key("generationOptions"), defaultValue: .init(), suite: userDefaults)
        _filterMode = UserDefault(key: userDefaultsNamespace.key("filterMode"), defaultValue: nil, suite: userDefaults)
        _bookmarkMigrationCompleted = UserDefault(key: userDefaultsNamespace.key("bookmarkMigrationCompleted"), defaultValue: false, suite: userDefaults)
        _bookmarkScopeMigrationCompleted = UserDefault(key: userDefaultsNamespace.key("bookmarkScopeMigrationCompleted"), defaultValue: false, suite: userDefaults)

        if let storageDirectoryURL {
            _imageBookmarksByScope = ResilientFileStorage(wrappedValue: [:], "imageBookmarksByScope", directoryURL: storageDirectoryURL)
            _objectBookmarksByScopeAndImagePath = ResilientFileStorage(wrappedValue: [:], "objectBookmarksByScopeAndImagePath", directoryURL: storageDirectoryURL)
        } else {
            _imageBookmarksByScope = ResilientFileStorage(wrappedValue: [:], "imageBookmarksByScope", directory: .applicationSupportDirectory)
            _objectBookmarksByScopeAndImagePath = ResilientFileStorage(wrappedValue: [:], "objectBookmarksByScopeAndImagePath", directory: .applicationSupportDirectory)
        }

        // Not a bookmark concern, but it belongs to the same one-time rekeying
        // and has to happen before a sidebar writes under its new key — which
        // it does shortly after this type is first resolved, since the sidebar
        // ViewModels reach for `@Dependency(\.appDefaults)` on the way up.
        //
        // Only on the standard defaults: that is where `StatefulOutlineView`
        // writes the autosave entries this removes, so an isolated instance
        // has none, and running it there would leave the cleanup flag in the
        // test process's standard defaults.
        if case .standard = userDefaultsNamespace {
            SidebarAutosaveKeyCleanup.runIfNeeded(flagKey: Self.sidebarAutosaveCleanupFlagKey)
        }

        guard let storageDirectoryURL else { return }
        migrateFlatBookmarkArraysIfNeeded(in: storageDirectoryURL)
        migrateBookmarksToScopeKeysIfNeeded(in: storageDirectoryURL)
    }

    /// An isolated namespace belongs to this instance alone, so it goes with
    /// it. The standard defaults are left as they are.
    deinit {
        userDefaultsNamespace.removeIsolatedValues()
    }

    static let sidebarAutosaveCleanupFlagKey = "sidebarAutosaveKeyCleanupCompleted"

    /// Where the four values below live; see `init`.
    let userDefaultsNamespace: UserDefaultsNamespace

    @UserDefault
    public var options: RuntimeObjectInterface.GenerationOptions

    @UserDefault
    public var filterMode: FilterMode?

    @UserDefault
    private var bookmarkMigrationCompleted: Bool

    @UserDefault
    private var bookmarkScopeMigrationCompleted: Bool

    /// Bookmarked images, keyed by ``RuntimeBookmarkScope/bookmarkKey``.
    ///
    /// A `[String: …]` dictionary encodes as a plain JSON object. The previous
    /// `[RuntimeSource: …]` form could not: a non-string key forces the
    /// key/value-alternating array encoding, whose keys carried a display name
    /// that `RuntimeSource.==` ignores — so two keys differing only in that
    /// name compared equal on the way back in, and the later one silently
    /// overwrote the earlier. Renaming a peer could destroy bookmarks at load
    /// time with nothing logged.
    @ResilientFileStorage
    public var imageBookmarksByScope: [String: [RuntimeImageBookmark]]

    /// Bookmarked objects, keyed by ``RuntimeBookmarkScope/bookmarkKey`` and
    /// then by image path.
    @ResilientFileStorage
    public var objectBookmarksByScopeAndImagePath: [String: [String: [RuntimeObjectBookmark]]]
}

// MARK: - Bookmark migrations

extension AppDefaults {
    /// Stage one, from before scopes existed: a flat array of bookmarks, each
    /// carrying its own source, grouped into a per-source dictionary.
    ///
    /// Superseded by stage two but still reachable — a user upgrading across
    /// several releases arrives here first — so it now writes the *scope*-keyed
    /// dictionaries directly rather than the intermediate per-source ones,
    /// which no longer exist.
    ///
    /// Reads the file rather than a stored property: the flat entries each
    /// carry a source, and `RuntimeImageBookmark` no longer has a field to
    /// decode one into.
    private func migrateFlatBookmarkArraysIfNeeded(in directoryURL: URL) {
        guard !bookmarkMigrationCompleted else { return }
        defer { bookmarkMigrationCompleted = true }

        if let flatImageBookmarks = BookmarkScopeMigration.flatEntries(
            ofElement: BookmarkScopeMigration.LegacyFlatImageBookmark.self,
            inArchiveAt: directoryURL.appendingPathComponent("imageBookmarks.json")
        ) {
            let entries = flatImageBookmarks.map {
                BookmarkScopeMigration.Entry(source: $0.source, payload: [RuntimeImageBookmark(imageNode: $0.imageNode)])
            }
            let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: entries)
            _imageBookmarksByScope.setSynchronously(
                merged(outcome.migrated, into: _imageBookmarksByScope.wrappedValue, by: BookmarkScopeMigration.deduplicatedUnion)
            )
        }

        if let flatObjectBookmarks = BookmarkScopeMigration.flatEntries(
            ofElement: BookmarkScopeMigration.LegacyFlatObjectBookmark.self,
            inArchiveAt: directoryURL.appendingPathComponent("objectBookmarks.json")
        ) {
            let entries = flatObjectBookmarks.map {
                BookmarkScopeMigration.Entry(
                    source: $0.source,
                    payload: [$0.object.imagePath: [RuntimeObjectBookmark(object: $0.object)]]
                )
            }
            let outcome = BookmarkScopeMigration.migrateObjectBookmarks(from: entries)
            _objectBookmarksByScopeAndImagePath.setSynchronously(
                merged(outcome.migrated, into: _objectBookmarksByScopeAndImagePath.wrappedValue, by: mergedByImagePath)
            )
        }
    }

    /// Stage two: per-source keys become scope keys.
    ///
    /// Reads the old files directly instead of through a property wrapper.
    /// Decoding them as `[RuntimeSource: …]` would lose entries before the
    /// migration ever saw them, for the reason spelled out on
    /// ``imageBookmarksByScope``, and would also throw away the disk order the
    /// merge rule depends on.
    private func migrateBookmarksToScopeKeysIfNeeded(in directoryURL: URL) {
        guard !bookmarkScopeMigrationCompleted else { return }
        defer { bookmarkScopeMigrationCompleted = true }

        if let entries = BookmarkScopeMigration.entries(
            ofPayload: [RuntimeImageBookmark].self,
            inKeyedArchiveAt: directoryURL.appendingPathComponent("imageBookmarksByRuntimeSource.json")
        ) {
            let outcome = BookmarkScopeMigration.migrateImageBookmarks(from: entries)
            _imageBookmarksByScope.setSynchronously(
                merged(outcome.migrated, into: _imageBookmarksByScope.wrappedValue, by: BookmarkScopeMigration.deduplicatedUnion)
            )
        }

        if let entries = BookmarkScopeMigration.entries(
            ofPayload: [String: [RuntimeObjectBookmark]].self,
            inKeyedArchiveAt: directoryURL.appendingPathComponent("objectBookmarksBySourceAndImagePath.json")
        ) {
            let outcome = BookmarkScopeMigration.migrateObjectBookmarks(from: entries)
            _objectBookmarksByScopeAndImagePath.setSynchronously(
                merged(outcome.migrated, into: _objectBookmarksByScopeAndImagePath.wrappedValue, by: mergedByImagePath)
            )
        }
    }

    /// Folds a migration's output into whatever is already stored.
    ///
    /// Both stages can run in the same launch, and a scope reached by stage one
    /// must not be flattened by stage two.
    private func merged<Payload>(
        _ incoming: [String: Payload],
        into existing: [String: Payload],
        by merge: (Payload, Payload) -> Payload
    ) -> [String: Payload] {
        existing.merging(incoming, uniquingKeysWith: merge)
    }

    private func mergedByImagePath(
        _ existing: [String: [RuntimeObjectBookmark]],
        _ incoming: [String: [RuntimeObjectBookmark]]
    ) -> [String: [RuntimeObjectBookmark]] {
        existing.merging(incoming, uniquingKeysWith: BookmarkScopeMigration.deduplicatedUnion)
    }
}

extension DependencyValues {
    /// The property initializer becomes the key's `testValue`. It must never
    /// be `AppDefaults.shared`: that let any test resolving this key silently
    /// read and write the user's real bookmark files (see
    /// `AppDefaults.init(storageDirectoryURL:userDefaultsNamespace:)`). Tests that assert on stored
    /// bookmarks still inject their own instance through `withDependencies`;
    /// the fallback only covers accesses no override can reach.
    @DependencyEntry(liveValue: AppDefaults.shared)
    public var appDefaults = AppDefaults.testFallback
}

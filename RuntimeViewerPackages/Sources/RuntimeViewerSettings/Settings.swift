import Foundation
import FoundationToolbox
import MetaCodable
import Observation
import UIFoundationSettings

@Observable
@Codable
@Loggable
public final class Settings {
    @Default(General.default)
    public var general: General = .init()

    @Default(Editor.default)
    public var editor: Editor = .init()

    @Default(Notifications.default)
    public var notifications: Notifications = .init()

    @Default(TransformerSettings.default)
    public var transformer: TransformerSettings = .init()

    @Default(MCP.default)
    public var mcp: MCP = .init()

    @Default(Indexing.default)
    public var indexing: Indexing = .init()

    @Default(Search.default)
    public var search: Search = .init()

    @Default(Update.default)
    public var update: Update = .init()

    @Default(Theme.default)
    public var theme: Theme = .init()

    @Default(Developer.default)
    public var developer: Developer = .init()

    @Default(File.default)
    public var file: File = .init()

    internal init() {}

    /// The directory under Application Support the application keeps its
    /// files in: `RuntimeViewer-Debug` for a Debug build, so a Debug app
    /// running beside the released one never shares a file with it. On iOS
    /// Application Support is inside the app's container, but the jailbroken
    /// variant may be installed without one, so the split matters there too.
    #if DEBUG
    public static let applicationDirectoryName = "RuntimeViewer-Debug"
    #else
    public static let applicationDirectoryName = "RuntimeViewer"
    #endif

    /// `~/Library/Application Support/<applicationDirectoryName>`.
    public static var applicationDirectoryURL: URL {
        URL.applicationSupportDirectory.appending(path: applicationDirectoryName, directoryHint: .isDirectory)
    }

    @MainActor
    public static let store = SettingsStore(
        defaultValue: Settings(),
        storage: FileSystemSettingsStorage(
            applicationDirectoryName: applicationDirectoryName,
            fileName: "settings.json"
        )
    )
}

extension Settings: PersistentSettings {
    /// Reads every encoded top-level property so `SettingsStore` can register
    /// one persistence observer without collapsing business observation onto a
    /// synthetic root value.
    @MainActor
    public func accessPersistedValues() {
        _ = general
        _ = editor
        _ = notifications
        _ = transformer
        _ = mcp
        _ = indexing
        _ = search
        _ = update
        _ = theme
        _ = developer
        _ = file
    }
}

/// RuntimeViewer's dependency-injection boundary over the single settings
/// store owned by ``Settings``.
///
/// The dynamic-member surface preserves existing `settings.theme` call sites
/// while every read and write still reaches the current `@Observable Settings`
/// object owned by the store. Observation therefore retains the model's
/// top-level property granularity.
@MainActor
@Loggable
@dynamicMemberLookup
public final class SettingsAccess {
    fileprivate static let shared = SettingsAccess(store: Settings.store)

    private let store: SettingsStore<Settings>

    init(store: SettingsStore<Settings>) {
        self.store = store
    }

    /// Reads the stored settings into the model and runs the one-shot data
    /// migrations behind it. The macOS app calls this once at launch, before
    /// anything reads a value.
    ///
    /// Nothing else starts this. Loading used to be a side effect of building
    /// the shared instance, which made "have the user's settings been read?"
    /// depend on whichever service happened to touch `\.settings` first — so
    /// reordering launch could have left every page showing defaults, and the
    /// first edit would then have written those defaults over the stored file.
    public func load() async {
        logLoadOutcome(await store.load())
        runMigrations()
    }

    /// The same read and migrations as ``load()``, finished before the call
    /// returns.
    ///
    /// The iOS app calls this first thing at launch: its first scene
    /// connects right after `application(_:didFinishLaunchingWithOptions:)`
    /// returns and reads settings as it does, which can be before a task
    /// started there to call ``load()`` has run.
    public func loadSynchronously() {
        // Resolves to the store's synchronous load() overload — this method
        // is not async, so the compiler cannot pick the async one.
        logLoadOutcome(store.load())
        runMigrations()
    }

    private func logLoadOutcome(_ outcome: SettingsStore<Settings>.LoadOutcome) {
        switch outcome {
        case .loaded:
            #log(.debug, "Settings loaded successfully.")
        case .noStoredData:
            #log(.debug, "No saved settings found, using defaults.")
        case .failed(let error):
            #log(.debug, "Failed to load settings, using defaults. (\(error, privacy: .public))")
        }
    }

    private func runMigrations() {
        migrateLegacyThemeProfileIfNeeded()
        migrateResidentLimitDefaultsIfNeeded()
    }

    /// Writes pending changes immediately instead of waiting out the store's
    /// auto-save delay, and cancels the pending write — without suspending.
    ///
    /// The macOS app calls this from `applicationShouldTerminate(_:)`, before
    /// replying `.terminateNow`; the iOS app as it enters the background and
    /// when it is about to terminate. Auto-save debounces by a second and
    /// every edit restarts that timer, so changing a value and quitting
    /// straight away otherwise loses the change.
    ///
    /// Synchronous on purpose — the write must not be deferred behind
    /// `.terminateLater`: the replying task is a main-queue job, and when
    /// `terminate(_:)` was itself invoked from a main-queue block — the
    /// helper-reinstall relaunch does exactly that — AppKit's nested
    /// wait-for-reply run loop cannot drain the main queue, so the reply
    /// never arrives and the app can only be force-quit.
    public func flushSynchronously() {
        do {
            // Resolves to the store's synchronous save() overload — this
            // method is not async, so the compiler cannot pick the async one.
            try store.save()
        } catch {
            #log(.debug, "Failed to flush settings: \(error, privacy: .public)")
        }
    }

    /// Brings the two resident limits to the defaults of
    /// `Settings.Search.currentResidentLimitDefaultsRevision`, once: a limit
    /// still at the old default of 256 MB is taken for one the user never
    /// changed and moved to 64 MB (proposal
    /// `on-demand-corpora-and-cross-references`); any other value stays. The
    /// revision is stored with the limits, so a file that has been through
    /// this is left alone, and a limit set back to 256 afterwards stays.
    private func migrateResidentLimitDefaultsIfNeeded() {
        let currentRevision = Settings.Search.currentResidentLimitDefaultsRevision
        guard store.value.search.residentLimitDefaultsRevision < currentRevision else { return }
        var search = store.value.search
        let defaults = Settings.Search.default
        if search.residentByteLimitMegabytes == Settings.Search.legacyResidentLimitMegabytes {
            search.residentByteLimitMegabytes = defaults.residentByteLimitMegabytes
        }
        if search.crossReferenceResidentByteLimitMegabytes == Settings.Search.legacyResidentLimitMegabytes {
            search.crossReferenceResidentByteLimitMegabytes = defaults.crossReferenceResidentByteLimitMegabytes
        }
        search.residentLimitDefaultsRevision = currentRevision
        store.value.search = search
        #log(.info, "Brought the resident limits to revision \(currentRevision, privacy: .public) of their defaults: \(search.residentByteLimitMegabytes, privacy: .public) MB for interfaces, \(search.crossReferenceResidentByteLimitMegabytes, privacy: .public) MB for cross references")
    }

    /// One-shot migration from the pre-data-driven theme storage. Earlier
    /// builds persisted `XcodePresentationTheme` under the UserDefaults key
    /// `themeProfile`, which carried the user's customized font size. Pulls
    /// that font size into the new `theme.fontSize` slot exactly once.
    ///
    /// Whether the migration has run is tracked by a dedicated
    /// `didMigrateLegacyThemeProfile` flag rather than by comparing
    /// `theme.fontSize` against the default value — otherwise a user who
    /// explicitly sets the new font size back to the default would have it
    /// silently overwritten by the legacy value on the next launch.
    ///
    /// Writes through `store`, the same one ``load()`` just populated, so an
    /// injected store migrates itself rather than the process-wide one.
    private func migrateLegacyThemeProfileIfNeeded() {
        let legacyKey = "themeProfile"
        let migrationFlagKey = "didMigrateLegacyThemeProfile"
        let defaults = UserDefaults.standard

        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        // Mark the migration as attempted unconditionally so a malformed
        // blob does not retry on every launch; the legacy data itself is
        // only removed once we have successfully consumed it.
        defer { defaults.set(true, forKey: migrationFlagKey) }

        guard let legacyData = defaults.data(forKey: legacyKey) else { return }

        struct LegacyThemeProfile: Decodable {
            let fontSize: Double
        }
        guard let legacy = try? JSONDecoder().decode(LegacyThemeProfile.self, from: legacyData) else {
            // Decode failed: leave the legacy blob in place so a future
            // build that extends `LegacyThemeProfile` can still recover it.
            return
        }

        if legacy.fontSize >= 8.0, legacy.fontSize <= 32.0 {
            store.value.theme.fontSize = legacy.fontSize
        }
        defaults.removeObject(forKey: legacyKey)
    }

    public var current: Settings {
        get { store.value }
        set { store.value = newValue }
    }

    public subscript<Value>(dynamicMember keyPath: ReferenceWritableKeyPath<Settings, Value>) -> Value {
        get { current[keyPath: keyPath] }
        set { current[keyPath: keyPath] = newValue }
    }

    /// A throwaway instance that persists nowhere.
    ///
    /// Backs the dependency's preview value. Without one, a preview resolves
    /// the live value, which attaches the real settings file — so touching a
    /// control in a rendered settings page would write to the developer's own
    /// stored settings once the auto-save delay elapsed.
    package static var preview: SettingsAccess {
        SettingsAccess(store: SettingsStore(defaultValue: Settings(), storage: InMemorySettingsStorage()))
    }
}

import Dependencies
import DependenciesMacros

extension DependencyValues {
    @DependencyEntry(
        liveValue: MainActor.assumeIsolated { SettingsAccess.shared },
        previewValue: MainActor.assumeIsolated { SettingsAccess.preview },
    )
    public var settings: SettingsAccess
}

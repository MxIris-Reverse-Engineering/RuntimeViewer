import Foundation
import FoundationToolbox
import MetaCodable
import Observation
#if os(macOS)
import UIFoundationSettings
#endif

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

    @Default(Update.default)
    public var update: Update = .init()

    @Default(Theme.default)
    public var theme: Theme = .init()

    internal init() {}

    #if os(macOS)
    #if DEBUG
    private static let applicationDirectoryName = "RuntimeViewer-Debug"
    #else
    private static let applicationDirectoryName = "RuntimeViewer"
    #endif

    @MainActor
    public static let store = SettingsStore(
        defaultValue: Settings(),
        storage: FileSystemSettingsStorage(
            applicationDirectoryName: applicationDirectoryName,
            fileName: "settings.json"
        )
    )

    #endif
}

#if os(macOS)
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
        _ = update
        _ = theme
    }
}
#endif

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
    #if os(macOS)
    fileprivate static let shared = SettingsAccess(store: Settings.store)

    private let store: SettingsStore<Settings>

    init(store: SettingsStore<Settings>) {
        self.store = store
    }
    #else
    fileprivate static let shared = SettingsAccess()

    private var value = Settings()

    init() {}
    #endif

    /// Reads the stored settings into the model and runs the one-shot data
    /// migration behind it. Call once at launch, before anything reads a value.
    ///
    /// Nothing else starts this. Loading used to be a side effect of building
    /// the shared instance, which made "have the user's settings been read?"
    /// depend on whichever service happened to touch `\.settings` first — so
    /// reordering launch could have left every page showing defaults, and the
    /// first edit would then have written those defaults over the stored file.
    ///
    /// A no-op off macOS, where there is no file to read from.
    public func load() async {
        #if os(macOS)
        switch await store.load() {
        case .loaded:
            #log(.debug, "Settings loaded successfully.")
        case .noStoredData:
            #log(.debug, "No saved settings found, using defaults.")
        case .failed(let error):
            #log(.debug, "Failed to load settings, using defaults. (\(error, privacy: .public))")
        }
        migrateLegacyThemeProfileIfNeeded()
        #endif
    }

    /// Writes pending changes immediately instead of waiting out the store's
    /// auto-save delay, and cancels the pending write.
    ///
    /// Call when the app is about to terminate. Auto-save debounces by a
    /// second and every edit restarts that timer, so changing a value and
    /// quitting straight away otherwise loses the change.
    ///
    /// A no-op off macOS, where there is nothing to write to.
    public func flush() async {
        #if os(macOS)
        do {
            try await store.save()
        } catch {
            #log(.debug, "Failed to flush settings: \(error, privacy: .public)")
        }
        #endif
    }

    #if os(macOS)
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
    #endif

    public var current: Settings {
        get {
            #if os(macOS)
            store.value
            #else
            value
            #endif
        }
        set {
            #if os(macOS)
            store.value = newValue
            #else
            value = newValue
            #endif
        }
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
    static var preview: SettingsAccess {
        #if os(macOS)
        SettingsAccess(store: SettingsStore(defaultValue: Settings(), storage: InMemorySettingsStorage()))
        #else
        SettingsAccess()
        #endif
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

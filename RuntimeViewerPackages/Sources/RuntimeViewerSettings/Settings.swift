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

    @MainActor
    fileprivate static func load() async {
        let outcome = await store.load()
        switch outcome {
        case .loaded:
            #log(.debug, "Settings loaded successfully.")
        case .noStoredData:
            #log(.debug, "No saved settings found, using defaults.")
        case .failed(let error):
            #log(.debug, "Failed to load settings, using defaults. (\(error, privacy: .public))")
        }
        migrateLegacyThemeProfileIfNeeded()
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
    @MainActor
    private static func migrateLegacyThemeProfileIfNeeded() {
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
}

#if os(macOS)
extension Settings: PersistentSettings {
    /// Reads every encoded top-level property so `SettingsStore` can register
    /// one persistence observer without collapsing business observation onto a
    /// synthetic root value.
    @MainActor
    public func accessPersistedValues() {
        _ = general
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
@dynamicMemberLookup
public final class SettingsAccess {
    fileprivate static let shared = SettingsAccess()

    #if os(macOS)
    private let store: SettingsStore<Settings>
    #else
    private var value = Settings()
    #endif

    private init() {
        #if os(macOS)
        store = Settings.store
        Task {
            await Settings.load()
        }
        #endif
    }

    #if os(macOS)
    init(store: SettingsStore<Settings>) {
        self.store = store
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
}

import Dependencies
import DependenciesMacros

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { SettingsAccess.shared })
    public var settings: SettingsAccess
}

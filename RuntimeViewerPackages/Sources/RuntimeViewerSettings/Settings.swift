import Foundation
import FoundationToolbox
import Observation
import MetaCodable

@Observable
@Codable
@Loggable
public final class Settings {
    fileprivate static let shared = Settings()

    private static var storage: SettingsStorageStrategy = SettingsFileSystemStorage()

    @Default(General.default)
    public var general: General = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(Notifications.default)
    public var notifications: Notifications = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(TransformerSettings.default)
    public var transformer: TransformerSettings = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(MCP.default)
    public var mcp: MCP = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(Indexing.default)
    public var indexing: Indexing = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(Update.default)
    public var update: Update = .init() {
        didSet { scheduleAutoSave() }
    }

    @Default(Theme.default)
    public var theme: Theme = .init() {
        didSet { scheduleAutoSave() }
    }

    @IgnoreCoding
    @ObservationIgnored
    private var saveTask: Task<Void, Error>?

    internal init() {
        Task {
            await load()
        }
    }

    private func scheduleAutoSave() {
        saveTask?.cancel()

        saveTask = Task {
            try await Task.sleep(for: .seconds(1))

            await saveNow()
        }
    }

    private func saveNow() async {
        do {
            let data = try JSONEncoder().encode(self)
            try await Self.storage.save(data)
            #log(.debug, "Settings auto-saved successfully.")
        } catch {
            #log(.debug, "Failed to save settings: \(error, privacy: .public)")
        }
    }

    private func load() async {
        do {
            let data = try await Self.storage.load()
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            general = decoded.general
            notifications = decoded.notifications
            transformer = decoded.transformer
            mcp = decoded.mcp
            indexing = decoded.indexing
            update = decoded.update
            theme = decoded.theme
            #log(.debug, "Settings loaded successfully.")
        } catch {
            #log(.debug, "No saved settings found or load failed, using defaults. (\(error, privacy: .public))")
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
            theme.fontSize = legacy.fontSize
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

import Dependencies

private enum SettingsKey: DependencyKey {
    static let liveValue = Settings.shared
    static let previewValue = Settings()
}

extension DependencyValues {
    public var settings: Settings {
        get { self[SettingsKey.self] }
        set { self[SettingsKey.self] = newValue }
    }
}

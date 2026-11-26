import Foundation
import Testing
import RuntimeViewerCore
import UIFoundationSettings

@testable import RuntimeViewerSettings

/// The Generation Options earlier builds kept in user defaults under `generationOptions` move into
/// `generationOptions.global` once (proposal `generation-options-image-overrides`). Every case runs
/// on a user defaults suite of its own, never the standard defaults.
@Suite("Legacy Generation Options migration")
@MainActor
struct LegacyGenerationOptionsMigrationTests {
    private static let legacyKey = "generationOptions"
    private static let migrationFlagKey = "didMigrateLegacyGenerationOptions"

    private static var legacyOptions: RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.printFieldOffset = true
        options.objcHeaderOptions.stripOverrides = true
        return options
    }

    /// A user defaults suite that goes away with the test.
    private final class IsolatedUserDefaults {
        let suiteName = "RuntimeViewerSettingsTests.LegacyGenerationOptions.\(UUID().uuidString)"
        let userDefaults: UserDefaults

        init() {
            userDefaults = UserDefaults(suiteName: suiteName)!
        }

        deinit {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
    }

    private static func settingsAccess(
        storing storedSettings: Settings? = nil,
        legacyUserDefaults: UserDefaults
    ) throws -> (SettingsAccess, InMemorySettingsStorage) {
        let storage = InMemorySettingsStorage()
        if let storedSettings {
            try storage.save(JSONEncoder().encode(storedSettings))
        }
        let store = SettingsStore(defaultValue: Settings(), storage: storage, autoSaveDelay: .seconds(60))
        return (SettingsAccess(store: store, legacyUserDefaults: legacyUserDefaults), storage)
    }

    @Test("the old options move into the global ones once, and the old key stays")
    func legacyUserDefaultsOptionsMigrateIntoGlobalOnce() async throws {
        let isolated = IsolatedUserDefaults()
        isolated.userDefaults.set(try JSONEncoder().encode(Self.legacyOptions), forKey: Self.legacyKey)
        let (settingsAccess, storage) = try Self.settingsAccess(legacyUserDefaults: isolated.userDefaults)

        await settingsAccess.load()

        #expect(settingsAccess.generationOptions.global == Self.legacyOptions)
        #expect(isolated.userDefaults.bool(forKey: Self.migrationFlagKey))
        #expect(isolated.userDefaults.data(forKey: Self.legacyKey) != nil, "kept for a build from before")
        settingsAccess.flushSynchronously()
        #expect(try storage.decodedSettings()?.generationOptions.global == Self.legacyOptions)

        // A second launch after the user reset the global options does not bring the old ones back.
        settingsAccess.generationOptions.global = RuntimeObjectInterface.GenerationOptions()
        settingsAccess.flushSynchronously()
        let (relaunchedSettingsAccess, _) = try Self.settingsAccess(storing: try storage.decodedSettings(), legacyUserDefaults: isolated.userDefaults)
        await relaunchedSettingsAccess.load()
        #expect(relaunchedSettingsAccess.generationOptions.global == RuntimeObjectInterface.GenerationOptions())
    }

    @Test("the synchronous load the iOS app uses migrates the same way")
    func synchronousLoadMigrates() throws {
        let isolated = IsolatedUserDefaults()
        isolated.userDefaults.set(try JSONEncoder().encode(Self.legacyOptions), forKey: Self.legacyKey)
        let (settingsAccess, _) = try Self.settingsAccess(legacyUserDefaults: isolated.userDefaults)

        settingsAccess.loadSynchronously()

        #expect(settingsAccess.generationOptions.global == Self.legacyOptions)
    }

    @Test("old options that no longer decode leave the defaults and keep the old value")
    func unreadableLegacyOptionsLeaveDefaultsAndKeepTheOldValue() async throws {
        let isolated = IsolatedUserDefaults()
        let unreadable = Data("not json".utf8)
        isolated.userDefaults.set(unreadable, forKey: Self.legacyKey)
        let (settingsAccess, _) = try Self.settingsAccess(legacyUserDefaults: isolated.userDefaults)

        await settingsAccess.load()

        #expect(settingsAccess.generationOptions.global == RuntimeObjectInterface.GenerationOptions())
        #expect(isolated.userDefaults.data(forKey: Self.legacyKey) == unreadable)
        #expect(isolated.userDefaults.bool(forKey: Self.migrationFlagKey), "tried once")
    }

    @Test("the old options never replace global options already changed in the settings")
    func legacyOptionsDoNotOverwriteAGlobalAlreadyChanged() async throws {
        let isolated = IsolatedUserDefaults()
        isolated.userDefaults.set(try JSONEncoder().encode(Self.legacyOptions), forKey: Self.legacyKey)
        let storedSettings = Settings()
        storedSettings.generationOptions.global.swiftInterfaceOptions.expandsMacros = true
        let (settingsAccess, _) = try Self.settingsAccess(storing: storedSettings, legacyUserDefaults: isolated.userDefaults)

        await settingsAccess.load()

        #expect(settingsAccess.generationOptions.global == storedSettings.generationOptions.global)
    }

    @Test("without old options there is nothing to move")
    func noLegacyOptionsLeavesTheDefaults() async throws {
        let isolated = IsolatedUserDefaults()
        let (settingsAccess, _) = try Self.settingsAccess(legacyUserDefaults: isolated.userDefaults)

        await settingsAccess.load()

        #expect(settingsAccess.generationOptions.global == RuntimeObjectInterface.GenerationOptions())
    }
}

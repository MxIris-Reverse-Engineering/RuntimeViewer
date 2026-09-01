#if os(macOS)

import Foundation
import Observation
import Testing
import UIFoundationSettings

@testable import RuntimeViewerSettings

private final class SettingsObservationChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChangeCount = 0

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedChangeCount
    }

    func recordChange() {
        lock.lock()
        recordedChangeCount += 1
        lock.unlock()
    }
}

@MainActor
private func waitUntilSettingsAreSaved(
    storage: InMemorySettingsStorage,
    maximumAttempts: Int = 300
) async -> Bool {
    for _ in 0 ..< maximumAttempts {
        if (try? storage.decodedSettings()) != nil { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? storage.decodedSettings()) != nil
}

/// One top-level persisted property, with a change to make to it and a way to
/// recognise that change in a copy decoded back out of storage.
private struct PersistedProperty: Sendable {
    /// The key this property occupies in the encoded payload. Checked against
    /// the real encoded schema by `coverageMatchesEncodedSchema`.
    let encodedKey: String
    let apply: @MainActor @Sendable (SettingsAccess) -> Void
    let matches: @Sendable (Settings) -> Bool
}

/// Every property `Settings.accessPersistedValues()` is required to read.
///
/// `SettingsStore` registers one observer over exactly the properties that
/// method touches, so a property missing from it still gets *encoded* whenever
/// some other property triggers a write — but a session that changes only the
/// missing property never schedules one, and the edit is lost on quit. That is
/// invisible in casual testing, which is what these two tests exist to catch.
private let persistedProperties: [PersistedProperty] = [
    PersistedProperty(
        encodedKey: "general",
        apply: { $0.general.sidebarMaxExpansionDepth = 7 },
        matches: { $0.general.sidebarMaxExpansionDepth == 7 }
    ),
    PersistedProperty(
        encodedKey: "editor",
        apply: { $0.editor.usesSourceEditor = true },
        matches: { $0.editor.usesSourceEditor }
    ),
    PersistedProperty(
        encodedKey: "notifications",
        apply: { $0.notifications.showOnDisconnect.toggle() },
        matches: { $0.notifications.showOnDisconnect != Settings.Notifications().showOnDisconnect }
    ),
    PersistedProperty(
        encodedKey: "transformer",
        apply: { settingsAccess in
            var transformer = settingsAccess.transformer
            transformer.objc.cType.isEnabled.toggle()
            settingsAccess.transformer = transformer
        },
        matches: { $0.transformer.objc.cType.isEnabled != Settings.TransformerSettings().objc.cType.isEnabled }
    ),
    PersistedProperty(
        encodedKey: "mcp",
        apply: { $0.mcp.fixedPort = 12_345 },
        matches: { $0.mcp.fixedPort == 12_345 }
    ),
    PersistedProperty(
        encodedKey: "indexing",
        apply: { $0.indexing.maxConcurrency = 11 },
        matches: { $0.indexing.maxConcurrency == 11 }
    ),
    PersistedProperty(
        encodedKey: "update",
        apply: { $0.update.includePrereleases.toggle() },
        matches: { $0.update.includePrereleases != Settings.Update().includePrereleases }
    ),
    PersistedProperty(
        encodedKey: "theme",
        apply: { $0.theme.fontSize = 17 },
        matches: { $0.theme.fontSize == 17 }
    ),
]

@MainActor
@Suite("Settings persistence adoption")
struct SettingsPersistenceTests {
    @Test("transformer observation ignores theme changes")
    func transformerObservationIsFineGrained() {
        let storage = InMemorySettingsStorage()
        let store = SettingsStore(defaultValue: Settings(), storage: storage)
        let settingsAccess = SettingsAccess(store: store)
        let changeRecorder = SettingsObservationChangeRecorder()

        withObservationTracking {
            _ = settingsAccess.transformer
        } onChange: {
            changeRecorder.recordChange()
        }

        settingsAccess.theme.fontSize = 17
        #expect(changeRecorder.changeCount == 0)

        var transformer = settingsAccess.transformer
        transformer.objc.cType.isEnabled.toggle()
        settingsAccess.transformer = transformer
        #expect(changeRecorder.changeCount == 1)
    }

    @Test("legacy payloads retain stored values and default newer fields")
    func legacyPayloadDecoding() throws {
        let data = Data(
            """
            {
              "general": {
                "appearance": "dark"
              },
              "notifications": {
                "isEnabled": false,
                "showOnConnect": false,
                "showOnDisconnect": true
              }
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(Settings.self, from: data)

        #expect(settings.general.appearance == .dark)
        #expect(settings.general.sidebarMaxExpansionDepth == 3)
        #expect(settings.general.terminatesAfterLastWindowClosed == false)
        #expect(settings.notifications.isEnabled == false)
        #expect(settings.notifications.showOnConnect == false)
        #expect(settings.notifications.showOnDisconnect == true)
        #expect(settings.mcp.fixedPort == 9277)
        #expect(settings.theme.selectedPresetID == Settings.Theme.builtinXcodePresetID)
    }

    @Test("dependency access writes through the UIFoundation store")
    func dependencyAccessWritesAndAutoSaves() async throws {
        let storage = InMemorySettingsStorage()
        let store = SettingsStore(
            defaultValue: Settings(),
            storage: storage,
            autoSaveDelay: .milliseconds(40)
        )
        let settingsAccess = SettingsAccess(store: store)

        settingsAccess.theme.fontSize = 17
        settingsAccess.mcp.fixedPort = 12_345

        #expect(store.value.theme.fontSize == 17)
        #expect(store.value.mcp.fixedPort == 12_345)
        #expect(
            await waitUntilSettingsAreSaved(storage: storage),
            "The dynamic-member write never reached persistent storage."
        )
        let persistedSettings = try storage.decodedSettings()
        #expect(persistedSettings?.theme.fontSize == 17)
        #expect(persistedSettings?.mcp.fixedPort == 12_345)
    }

    @Test("a synchronous flush persists pending edits before returning")
    func synchronousFlushOutrunsDebounce() throws {
        let storage = InMemorySettingsStorage()
        // A debounce far longer than the test, so only the synchronous flush
        // can be the writer.
        let store = SettingsStore(
            defaultValue: Settings(),
            storage: storage,
            autoSaveDelay: .seconds(60)
        )
        let settingsAccess = SettingsAccess(store: store)

        settingsAccess.theme.fontSize = 17
        settingsAccess.flushSynchronously()

        // Asserted synchronously on purpose: `applicationShouldTerminate`
        // relies on the write being finished when the call returns, because
        // nothing async gets to run once it replies `.terminateNow`.
        let persistedSettings = try storage.decodedSettings()
        #expect(persistedSettings?.theme.fontSize == 17)
    }

    @Test("changing one property on its own is enough to persist it")
    func eachPersistedPropertyPersistsOnItsOwn() async throws {
        for property in persistedProperties {
            let storage = InMemorySettingsStorage()
            let store = SettingsStore(
                defaultValue: Settings(),
                storage: storage,
                autoSaveDelay: .milliseconds(40)
            )
            let settingsAccess = SettingsAccess(store: store)

            // Guards the case itself: a change that matches the default value
            // would schedule nothing and the assertions below would pass for
            // the wrong reason.
            #expect(
                !property.matches(store.value),
                "The `\(property.encodedKey)` case does not change anything — pick a value the default does not already hold."
            )

            property.apply(settingsAccess)

            #expect(
                await waitUntilSettingsAreSaved(storage: storage),
                "Changing only `\(property.encodedKey)` never reached storage — `Settings.accessPersistedValues()` most likely does not read it."
            )
            let persistedSettings = try storage.decodedSettings()
            #expect(
                persistedSettings.map(property.matches) == true,
                "`\(property.encodedKey)` scheduled a save but did not round-trip through storage."
            )
        }
    }

    @Test("the persistence coverage list matches the encoded schema")
    func coverageMatchesEncodedSchema() throws {
        let encodedDefaults = try JSONEncoder().encode(Settings())
        let payload = try #require(
            try JSONSerialization.jsonObject(with: encodedDefaults) as? [String: Any]
        )

        #expect(
            Set(payload.keys) == Set(persistedProperties.map(\.encodedKey)),
            """
            The encoded schema and the coverage list above have diverged. \
            A new persisted property needs a case in `persistedProperties` here \
            *and* a read in `Settings.accessPersistedValues()`; without the \
            latter, a session that changes only that property never writes.
            """
        )
    }
}

#endif

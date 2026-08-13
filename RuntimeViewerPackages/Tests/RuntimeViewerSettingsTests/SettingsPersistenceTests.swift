#if os(macOS)

import Foundation
import Observation
import Testing
import UIFoundationSettings

@testable import RuntimeViewerSettings

private actor InMemorySettingsStorage: SettingsStorage {
    private var storedData: Data?

    func save(_ data: Data) async throws {
        storedData = data
    }

    func load() async throws -> Data {
        guard let storedData else {
            throw FileSystemSettingsStorage.LoadError.noStoredData
        }
        return storedData
    }

    func decodedSettings() throws -> Settings? {
        guard let storedData else { return nil }
        return try JSONDecoder().decode(Settings.self, from: storedData)
    }
}

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
        if (try? await storage.decodedSettings()) != nil { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await storage.decodedSettings()) != nil
}

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
        let persistedSettings = try await storage.decodedSettings()
        #expect(persistedSettings?.theme.fontSize == 17)
        #expect(persistedSettings?.mcp.fixedPort == 12_345)
    }
}

#endif

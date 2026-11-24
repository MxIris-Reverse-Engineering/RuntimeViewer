import Foundation
import Testing
import UIFoundationSettings

@testable import RuntimeViewerSettings

/// `SettingsAccess.didFindStoredSettingsOnLoad` tells a first launch apart: only someone who has
/// used the app has stored settings, readable or not (proposal `onboarding-pages`).
@Suite("Stored settings detection")
@MainActor
struct SettingsStoredSettingsDetectionTests {
    enum StoredPayload: Sendable, CaseIterable, CustomTestStringConvertible {
        case nothing
        case readableSettings
        case unreadableData

        var testDescription: String {
            switch self {
            case .nothing: "no stored settings"
            case .readableSettings: "readable stored settings"
            case .unreadableData: "unreadable stored data"
            }
        }

        var isExpectedToBeFound: Bool {
            switch self {
            case .nothing: false
            case .readableSettings, .unreadableData: true
            }
        }
    }

    @Test("Loading records whether stored settings were found", arguments: StoredPayload.allCases)
    func loadingRecordsWhetherStoredSettingsWereFound(_ storedPayload: StoredPayload) async throws {
        let settingsAccess = try Self.settingsAccess(storing: storedPayload)
        #expect(settingsAccess.didFindStoredSettingsOnLoad == false)

        await settingsAccess.load()

        #expect(settingsAccess.didFindStoredSettingsOnLoad == storedPayload.isExpectedToBeFound)
    }

    /// The iOS app loads synchronously at launch; it has to record the same.
    @Test("Loading synchronously records whether stored settings were found", arguments: StoredPayload.allCases)
    func synchronousLoadingRecordsWhetherStoredSettingsWereFound(_ storedPayload: StoredPayload) throws {
        let settingsAccess = try Self.settingsAccess(storing: storedPayload)

        settingsAccess.loadSynchronously()

        #expect(settingsAccess.didFindStoredSettingsOnLoad == storedPayload.isExpectedToBeFound)
    }

    @Test("A save after loading nothing does not change what the load found")
    func saveAfterLoadingNothingKeepsTheLoadResult() async throws {
        let settingsAccess = try Self.settingsAccess(storing: .nothing)
        await settingsAccess.load()

        settingsAccess.general.showsWelcomeWindowAtLaunch.toggle()
        settingsAccess.flushSynchronously()

        #expect(settingsAccess.didFindStoredSettingsOnLoad == false)
    }

    /// A settings access over in-memory storage holding the given payload; a debounce far longer
    /// than the test, so nothing is written but an explicit flush.
    private static func settingsAccess(storing storedPayload: StoredPayload) throws -> SettingsAccess {
        let storage = InMemorySettingsStorage()
        switch storedPayload {
        case .nothing:
            break
        case .readableSettings:
            try storage.save(JSONEncoder().encode(Settings()))
        case .unreadableData:
            try storage.save(Data("not settings".utf8))
        }
        let store = SettingsStore(defaultValue: Settings(), storage: storage, autoSaveDelay: .seconds(60))
        return SettingsAccess(store: store)
    }
}

#if os(macOS)

import Foundation
import Testing
import UIFoundationSettings

@testable import RuntimeViewerSettings

/// The two resident limits went from 256 to 64 MB by default (proposal
/// `on-demand-corpora-and-cross-references`). Every save writes every value, so a file from
/// before holds 256 whether or not the user ever touched the limits; loading it moves a limit
/// still at 256 to 64 once, and leaves every other value — and every later one — as it is.
@Suite("Resident limit defaults migration")
@MainActor
struct SettingsResidentLimitMigrationTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// What the stored file holds; `nil` revision for a file that predates it.
        let stored: (interfaces: Int, crossReferences: Int, revision: Int?)?
        let loaded: (interfaces: Int, crossReferences: Int)

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "limits at the old default move to the new one", stored: (256, 256, nil), loaded: (64, 64)),
        Case(name: "limits the user changed stay", stored: (512, 128, nil), loaded: (512, 128)),
        Case(name: "one limit changed, the other at the old default", stored: (256, 1024, nil), loaded: (64, 1024)),
        Case(name: "a file already brought to the new defaults keeps a 256 set since", stored: (256, 256, 1), loaded: (256, 256)),
        Case(name: "no stored file takes the new defaults", stored: nil, loaded: (64, 64)),
    ]

    @Test("Loading brings limits still at the old default to the new one, once", arguments: cases)
    func loadingMigratesTheOldDefaults(_ testCase: Case) async throws {
        let storage = InMemorySettingsStorage()
        if let stored = testCase.stored {
            try storage.save(Self.payload(interfaces: stored.interfaces, crossReferences: stored.crossReferences, revision: stored.revision))
        }
        let store = SettingsStore(defaultValue: Settings(), storage: storage, autoSaveDelay: .seconds(60))
        let settingsAccess = SettingsAccess(store: store)

        await settingsAccess.load()

        #expect(settingsAccess.search.residentByteLimitMegabytes == testCase.loaded.interfaces)
        #expect(settingsAccess.search.crossReferenceResidentByteLimitMegabytes == testCase.loaded.crossReferences)
        #expect(settingsAccess.search.residentLimitDefaultsRevision == Settings.Search.currentResidentLimitDefaultsRevision)

        settingsAccess.flushSynchronously()
        let persisted = try #require(try storage.decodedSettings())
        #expect(persisted.search.residentLimitDefaultsRevision == Settings.Search.currentResidentLimitDefaultsRevision, "recorded, so it does not run again")
    }

    /// The settings file as a build from before the revision wrote it, with the two limits given,
    /// or as a build since wrote it when `revision` is set.
    private static func payload(interfaces: Int, crossReferences: Int, revision: Int?) throws -> Data {
        let encoded = try JSONEncoder().encode(Settings())
        var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var search = try #require(root["search"] as? [String: Any])
        search["residentByteLimitMegabytes"] = interfaces
        search["crossReferenceResidentByteLimitMegabytes"] = crossReferences
        search["residentLimitDefaultsRevision"] = revision
        root["search"] = search
        return try JSONSerialization.data(withJSONObject: root)
    }
}

#endif

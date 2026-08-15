#if os(macOS)

import Foundation
import UIFoundationSettings

/// A `SettingsStorage` that keeps the payload in memory and never touches the
/// file system.
///
/// Backs the `\.settings` dependency's preview value, so rendering a settings
/// page in a preview — or resolving the dependency in a context that forgot to
/// stub it — cannot read or overwrite the developer's real
/// `~/Library/Application Support/RuntimeViewer[-Debug]/settings.json`.
/// Tests use it for the same reason.
actor InMemorySettingsStorage: SettingsStorage {
    private var storedData: Data?

    init() {}

    func save(_ data: Data) async throws {
        storedData = data
    }

    func load() async throws -> Data {
        guard let storedData else {
            // The store treats this specific error as "nothing written yet"
            // and keeps its default value, rather than reporting a failure.
            throw FileSystemSettingsStorage.LoadError.noStoredData
        }
        return storedData
    }

    /// What `save(_:)` last wrote, for tests that assert persistence happened.
    func decodedSettings() throws -> Settings? {
        guard let storedData else { return nil }
        return try JSONDecoder().decode(Settings.self, from: storedData)
    }
}

#endif
